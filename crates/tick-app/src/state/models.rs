//! Speech model catalog/downloads and the on-device AI model lifecycle.

use std::sync::atomic::Ordering;
use std::time::Duration;

use gpui_kit::Context;
use tick_core::models::{
    self, CuratedModel, PARAKEET_UNIFIED_ENGLISH, ParakeetModel, curated_models,
};
use tick_core::settings::AiPostProcessingMode;

use super::AppState;
use crate::intelligence::{self, DownloadControl};
use crate::native;
use crate::platform::workspace;
use crate::sound::Cue;
use crate::speech::{self, gguf::GgufModel};
use crate::storage;

#[derive(Debug, Clone, PartialEq)]
pub struct CuratedEntry {
    pub model: CuratedModel,
    pub downloaded: bool,
}

#[derive(Debug, Clone, PartialEq, Default)]
pub enum SpeechDownload {
    #[default]
    Idle,
    Downloading {
        model: String,
        progress: f64,
    },
}

#[derive(Default)]
pub struct ModelState {
    /// Whether the selected model is on disk and dictation can start.
    pub ready: bool,
    pub curated: Vec<CuratedEntry>,
    pub available: Vec<(String, bool)>,
    pub show_all: bool,
    pub loading: bool,
    pub download: SpeechDownload,
    pub error: Option<String>,
    cancel: Option<speech::CancelHandle>,
}

impl ModelState {
    pub fn any_downloaded(&self) -> bool {
        self.available.iter().any(|(_, downloaded)| *downloaded)
            || self.curated.iter().any(|e| e.downloaded)
    }

    pub fn is_downloading(&self) -> bool {
        !matches!(self.download, SpeechDownload::Idle)
    }

    pub fn downloading(&self, model: &str) -> Option<f64> {
        match &self.download {
            SpeechDownload::Downloading {
                model: current,
                progress,
            } if current == model => Some(*progress),
            _ => None,
        }
    }
}

#[derive(Default)]
pub struct AiModelState {
    pub downloaded: bool,
    pub size: Option<u64>,
    pub downloading: bool,
    pub progress: f64,
    pub warming: bool,
    pub error: Option<String>,
    control: Option<DownloadControl>,
}

impl AppState {
    pub(super) fn refresh_model_readiness(&mut self, cx: &mut Context<Self>) {
        let model = self.settings.selected_model.clone();
        if model.is_empty() {
            self.models.ready = false;
            return;
        }
        cx.spawn(async move |this, cx| {
            let ready = speech::is_downloaded(&model).await;
            let _ = this.update(cx, |state, cx| {
                if state.settings.selected_model == model {
                    state.models.ready = ready;
                    cx.notify();
                }
            });
        })
        .detach();
    }

    pub(super) fn fetch_catalog(&mut self, cx: &mut Context<Self>) {
        if self.models.loading {
            return;
        }
        self.models.loading = true;
        cx.spawn(async move |this, cx| {
            let catalog = speech::catalog().await;
            let _ = this.update(cx, |state, cx| {
                state.models.loading = false;
                let (recommended, mut available) = match catalog {
                    Ok(catalog) => (
                        catalog.recommended,
                        catalog
                            .models
                            .into_iter()
                            .map(|m| (m.name, m.downloaded))
                            .collect::<Vec<_>>(),
                    ),
                    Err(error) => {
                        tracing::error!(target: "models", "could not list models: {error}");
                        (String::new(), Vec::new())
                    }
                };
                for parakeet in ParakeetModel::ALL.iter().rev() {
                    if !available
                        .iter()
                        .any(|(name, _)| name == parakeet.identifier())
                    {
                        available.insert(0, (parakeet.identifier().to_string(), false));
                    }
                }
                if let Some(unified) = GgufModel::from_identifier(PARAKEET_UNIFIED_ENGLISH) {
                    available.insert(0, (unified.identifier.to_string(), unified.is_downloaded()));
                }
                let preferred = state.preferred_parakeet();
                let recommended = if available.iter().any(|(n, _)| n == preferred) {
                    preferred.to_string()
                } else {
                    recommended
                };
                if state.settings.selected_model.contains(['*', '?']) {
                    if let Some(resolved) =
                        models::resolve_pattern(&state.settings.selected_model, &available)
                    {
                        state.update_settings(cx, |s| s.selected_model = resolved);
                    }
                }
                state.models.curated = curated_models()
                    .into_iter()
                    .map(|model| {
                        let downloaded = available.iter().any(|(name, d)| {
                            *d && models::glob_matches(&model.internal_name, name)
                        });
                        CuratedEntry { model, downloaded }
                    })
                    .collect();
                state.models.available = available;
                if !state.models.any_downloaded()
                    && !state.settings.has_completed_model_bootstrap
                    && !recommended.is_empty()
                {
                    state.update_settings(cx, |s| s.selected_model = recommended);
                }
                state.models.ready = state.selected_model_downloaded();
                cx.notify();
            });
        })
        .detach();
    }

    fn preferred_parakeet(&self) -> &'static str {
        let english = self
            .settings
            .output_language
            .as_deref()
            .is_some_and(|l| l.to_lowercase().starts_with("en"));
        if english {
            PARAKEET_UNIFIED_ENGLISH
        } else {
            ParakeetModel::MultilingualV3.identifier()
        }
    }

    fn selected_model_downloaded(&self) -> bool {
        let selected = &self.settings.selected_model;
        self.models
            .available
            .iter()
            .any(|(name, downloaded)| *downloaded && name == selected)
            || self
                .models
                .curated
                .iter()
                .any(|e| e.downloaded && e.model.is_selected(selected))
    }

    pub fn select_model(&mut self, model: &str, cx: &mut Context<Self>) {
        let resolved = models::resolve_pattern(model, &self.models.available)
            .unwrap_or_else(|| model.to_string());
        self.update_settings(cx, |s| s.selected_model = resolved);
        self.models.ready = self.selected_model_downloaded();
        self.sound.play(Cue::Select);
        self.warm_models(cx);
        cx.notify();
    }

    pub fn download_model(&mut self, model: &str, cx: &mut Context<Self>) {
        if !matches!(self.models.download, SpeechDownload::Idle) {
            return;
        }
        self.select_model(model, cx);
        let model = self.settings.selected_model.clone();
        self.models.error = None;
        self.models.download = SpeechDownload::Downloading {
            model: model.clone(),
            progress: 0.0,
        };
        self.sound.play(Cue::Loading);
        let (progress_tx, mut progress_rx) = futures::channel::mpsc::unbounded::<f64>();
        let download = speech::download(&model, move |fraction| {
            let _ = progress_tx.unbounded_send(fraction);
        });
        self.models.cancel = Some(download.cancel_handle());
        let progress_task = cx.spawn(async move |this, cx| {
            use futures::StreamExt;
            while let Some(fraction) = progress_rx.next().await {
                let _ = this.update(cx, |state, cx| {
                    if let SpeechDownload::Downloading { progress, .. } = &mut state.models.download
                    {
                        *progress = fraction.clamp(0.0, 1.0);
                        cx.notify();
                    }
                });
            }
        });
        self.tasks.speech_download = Some(cx.spawn(async move |this, cx| {
            let result = download.finish().await;
            drop(progress_task);
            let _ = this.update(cx, |state, cx| {
                state.models.download = SpeechDownload::Idle;
                state.models.cancel = None;
                match result {
                    Ok(()) => {
                        for (name, downloaded) in &mut state.models.available {
                            if *name == model {
                                *downloaded = true;
                            }
                        }
                        for entry in &mut state.models.curated {
                            if entry.model.is_selected(&model) {
                                entry.downloaded = true;
                            }
                        }
                        state.update_settings(cx, |s| s.has_completed_model_bootstrap = true);
                        state.models.ready = state.selected_model_downloaded();
                        state.sound.play(Cue::Success);
                    }
                    Err(speech::NativeError::Cancelled) => {
                        state.models.error = Some("Download cancelled".into());
                    }
                    Err(error) => {
                        state.models.error = Some(error.to_string());
                        state.sound.play(Cue::Error);
                    }
                }
                cx.notify();
            });
        }));
        cx.notify();
    }

    pub fn cancel_model_download(&mut self, cx: &mut Context<Self>) {
        if let Some(cancel) = self.models.cancel.take() {
            cancel.cancel();
        }
        self.models.download = SpeechDownload::Idle;
        self.models.error = Some("Download cancelled".into());
        self.models.ready = false;
        self.sound.play(Cue::Close);
        cx.notify();
    }

    pub fn delete_model(&mut self, model: &str, cx: &mut Context<Self>) {
        self.select_model(model, cx);
        self.models.ready = false;
        let model = self.settings.selected_model.clone();
        cx.spawn(async move |this, cx| {
            let result = speech::delete(&model).await;
            let _ = this.update(cx, |state, cx| {
                if let Err(error) = result {
                    state.models.error = Some(error.to_string());
                }
                state.sound.play(Cue::Close);
                state.fetch_catalog(cx);
            });
        })
        .detach();
    }

    pub fn reveal_models(&self) {
        workspace::reveal_in_finder(&storage::speech_models());
    }

    pub fn toggle_all_models(&mut self, cx: &mut Context<Self>) {
        self.models.show_all = !self.models.show_all;
        self.sound.play(if self.models.show_all {
            Cue::Open
        } else {
            Cue::Close
        });
        cx.notify();
    }

    /// Loads Core ML before MLX: compiling both at once contends badly.
    pub(super) fn warm_models(&mut self, cx: &mut Context<Self>) {
        let model = self.settings.selected_model.clone();
        let ai = (self.settings.ai_post_processing_mode == AiPostProcessingMode::On)
            .then_some(self.settings.selected_ai_model);
        cx.spawn(async move |_, _| {
            if let Err(error) = speech::warm(&model).await {
                tracing::error!(target: "transcription", "speech model warm-up failed: {error}");
            }
            if let Some(model) = ai.filter(|m| intelligence::is_model_downloaded(*m)) {
                if let Err(error) = native::llm::warm(&storage::ai_model(model)).await {
                    tracing::error!(target: "transcription", "AI warm-up failed: {error}");
                }
            }
        })
        .detach();
    }

    // MARK: On-device AI model

    pub(super) fn refresh_ai_model(&mut self, cx: &mut Context<Self>) {
        let model = self.settings.selected_ai_model;
        cx.spawn(async move |this, cx| {
            let (downloaded, size) = cx
                .background_executor()
                .spawn(async move {
                    (
                        intelligence::is_model_downloaded(model),
                        intelligence::model_size(model),
                    )
                })
                .await;
            let _ = this.update(cx, |state, cx| {
                if state.settings.selected_ai_model != model {
                    return;
                }
                state.ai.downloaded = downloaded;
                state.ai.size = size;
                if downloaded {
                    state.ai.error = None;
                    state.ai.progress = 1.0;
                }
                state.warm_ai(cx);
                cx.notify();
            });
        })
        .detach();
    }

    pub(super) fn warm_ai(&mut self, cx: &mut Context<Self>) {
        if self.settings.ai_post_processing_mode != AiPostProcessingMode::On
            || !self.ai.downloaded
            || self.ai.warming
        {
            return;
        }
        self.ai.warming = true;
        let directory = storage::ai_model(self.settings.selected_ai_model);
        cx.spawn(async move |this, cx| {
            let result = native::llm::warm(&directory).await;
            let _ = this.update(cx, |state, cx| {
                state.ai.warming = false;
                if let Err(error) = result {
                    tracing::error!(target: "transcription", "AI warm-up failed: {error}");
                    state.ai.error = Some(error.to_string());
                }
                cx.notify();
            });
        })
        .detach();
    }

    pub fn download_ai_model(&mut self, cx: &mut Context<Self>) {
        if self.ai.downloading {
            return;
        }
        let model = self.settings.selected_ai_model;
        let control = DownloadControl::default();
        self.ai.downloading = true;
        self.ai.error = None;
        self.ai.progress = 0.0;
        self.ai.control = Some(control.clone());
        self.sound.play(Cue::Loading);
        let total = intelligence::total_bytes(model) as f64;
        let poll_control = control.clone();
        let poller = cx.spawn(async move |this, cx| {
            loop {
                cx.background_executor()
                    .timer(Duration::from_millis(100))
                    .await;
                let fraction = poll_control.completed.load(Ordering::Relaxed) as f64 / total;
                if this
                    .update(cx, |state, cx| {
                        state.ai.progress = fraction.clamp(0.0, 1.0);
                        cx.notify();
                    })
                    .is_err()
                {
                    break;
                }
            }
        });
        self.tasks.ai_download = Some(cx.spawn(async move |this, cx| {
            let result = cx
                .background_executor()
                .spawn(async move { intelligence::download_model(model, &control) })
                .await;
            drop(poller);
            let _ = this.update(cx, |state, cx| {
                state.ai.downloading = false;
                state.ai.control = None;
                match result {
                    Ok(()) => {
                        state.ai.downloaded = true;
                        state.ai.progress = 1.0;
                        state.sound.play(Cue::Success);
                        state.refresh_ai_model(cx);
                    }
                    Err(intelligence::DownloadError::Cancelled) => {
                        state.ai.progress = 0.0;
                        state.ai.error = Some("Download cancelled".into());
                    }
                    Err(error) => {
                        state.ai.downloaded = false;
                        state.ai.progress = 0.0;
                        state.ai.error = Some(error.to_string());
                        state.sound.play(Cue::Error);
                    }
                }
                cx.notify();
            });
        }));
        cx.notify();
    }

    pub fn cancel_ai_download(&mut self, cx: &mut Context<Self>) {
        if let Some(control) = self.ai.control.take() {
            control.cancelled.store(true, Ordering::Relaxed);
        }
        self.sound.play(Cue::Close);
        cx.notify();
    }

    pub fn delete_ai_model(&mut self, cx: &mut Context<Self>) {
        if self.ai.downloading {
            return;
        }
        let model = self.settings.selected_ai_model;
        self.ai.downloaded = false;
        self.ai.size = None;
        self.ai.progress = 0.0;
        cx.spawn(async move |this, cx| {
            let result = cx
                .background_executor()
                .spawn(async move { intelligence::delete_model(model) })
                .await;
            let _ = this.update(cx, |state, cx| {
                state.ai.error = result
                    .err()
                    .map(|e| format!("The model could not be deleted: {e}"));
                state.sound.play(Cue::Close);
                state.refresh_ai_model(cx);
            });
        })
        .detach();
    }

    pub fn set_groq_key(&mut self, key: String, cx: &mut Context<Self>) {
        intelligence::set_groq_key(Some(key.trim()).filter(|k| !k.is_empty()));
        self.groq_key = key;
        cx.notify();
    }
}
