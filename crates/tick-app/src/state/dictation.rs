//! Recording → transcription → formatting → paste, plus dictionary learning
//! from corrections the user makes to inserted text.

use std::path::PathBuf;
use std::time::{Duration, Instant};

use futures::FutureExt;
use futures::future::BoxFuture;
use gpui_kit::{AsyncApp, Context, WeakEntity};
use tick_core::ai;
use tick_core::app_context::{AppCategory, AppContext, browser_url_script};
use tick_core::history::{FileUrl, Transcript, recording_file_name};
use tick_core::hotkey::KeyEvent;
use tick_core::hotkey_processor::should_transcribe;
use tick_core::id::{SwiftDate, SwiftUuid};
use tick_core::settings::{AiPostProcessingMode, Settings};
use tick_core::text::{self, KeystrokeTracker, WordCorrection, WordRemapping};

use super::{AppState, Tab, png_image};
use crate::intelligence::{self, PostProcess};
use crate::platform::paste::{self, PasteResult};
use crate::platform::system::SleepAssertion;
use crate::platform::workspace::{self, Haptic};
use crate::sound::Cue;
use crate::speech;
use crate::storage;

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Phase {
    Idle,
    Recording {
        started: Instant,
    },
    /// Recording a walkthrough: screen, voice and marks.
    Walkthrough {
        started: Instant,
    },
    /// From key release (or a finished walkthrough) until the text is in the
    /// target app.
    Transcribing,
}

impl Phase {
    /// When the current recording of either kind began.
    pub fn recording_since(self) -> Option<Instant> {
        match self {
            Phase::Recording { started } | Phase::Walkthrough { started } => Some(started),
            Phase::Idle | Phase::Transcribing => None,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PasteFailure {
    NoFocusedInput,
    Rejected,
}

#[derive(Debug, Clone, PartialEq)]
pub enum Feedback {
    DictionaryAdded(Vec<WordCorrection>),
    PasteUnavailable {
        text: String,
        reason: PasteFailure,
    },
    Copied,
    /// A walkthrough began; `finish` is the shortcut that ends it.
    WalkthroughStarted {
        finish: String,
    },
    ScreenRecordingNeeded,
    WalkthroughFailed(String),
}

#[derive(Default)]
pub(super) struct Session {
    source_bundle: Option<String>,
    source_name: Option<String>,
    context: Option<AppContext>,
    tracker: Option<KeystrokeTracker>,
    pending: Vec<WordCorrection>,
    released_at: Option<Instant>,
}

/// Lets platform code wait on the GPUI timer without owning a context.
pub(super) fn sleeper(cx: &AsyncApp) -> impl Fn(Duration) -> BoxFuture<'static, ()> + use<> {
    let executor = cx.background_executor().clone();
    move |duration| executor.timer(duration).boxed()
}

impl AppState {
    /// Copies the stream's latest words onto the overlay about 25 times a second.
    fn watch_live_text(&mut self, cx: &mut Context<Self>) {
        self.tasks.live = Some(cx.spawn(async move |this, cx| {
            loop {
                cx.background_executor()
                    .timer(Duration::from_millis(40))
                    .await;
                let keep = this.update(cx, |state, cx| {
                    if !matches!(state.phase, Phase::Recording { .. }) {
                        return false;
                    }
                    let next = speech::partial();
                    if next != state.live {
                        state.live = next;
                        cx.notify();
                    }
                    true
                });
                if !keep.unwrap_or(false) {
                    break;
                }
            }
        }));
    }
}

fn app_context(bundle_id: &str, name: &str) -> AppContext {
    let url = (AppCategory::from_bundle_id(bundle_id) == AppCategory::Browser)
        .then(|| browser_url_script(bundle_id))
        .flatten()
        .and_then(|script| workspace::run_apple_script(script).ok().flatten());
    AppContext {
        bundle_id: bundle_id.to_string(),
        app_name: name.to_string(),
        url,
    }
}

impl AppState {
    /// False, after pointing the user at the model picker, when no speech
    /// model is usable.
    pub(super) fn require_model(&mut self, cx: &mut Context<Self>) -> bool {
        if self.models.ready {
            return true;
        }
        self.sound.play(Cue::Warning);
        self.tab = Tab::Settings;
        self.flash_model_section = true;
        workspace::activate_app();
        self.tasks.flash = Some(cx.spawn(async move |this, cx| {
            cx.background_executor().timer(Duration::from_secs(2)).await;
            let _ = this.update(cx, |state, cx| {
                state.flash_model_section = false;
                cx.notify();
            });
        }));
        cx.notify();
        false
    }

    pub(super) fn start_recording(&mut self, locked: bool, cx: &mut Context<Self>) {
        if !self.require_model(cx) {
            return;
        }
        self.notice = None;
        self.dictation = Session::default();
        self.tasks.correction = None;
        self.tasks.correction_settle = None;
        self.tasks.dictionary_debounce = None;
        self.hotkeys.set_tracking_corrections(false);
        self.phase = Phase::Recording {
            started: Instant::now(),
        };
        self.live = speech::LiveText::default();
        self.locked = locked;
        self.sound.press(if locked { Cue::Lock } else { Cue::Talk });
        workspace::haptic(Haptic::Alignment);

        let frontmost = workspace::frontmost_app();
        self.dictation.source_bundle = frontmost.as_ref().map(|app| app.bundle_id.clone());
        self.dictation.source_name = frontmost.as_ref().map(|app| app.name.clone());
        self.source_name = self.dictation.source_name.clone();
        self.source_icon = frontmost.as_ref().and_then(|app| {
            if let Some(icon) = self.icon_cache.get(&app.bundle_id) {
                return Some(icon.clone());
            }
            let icon = png_image(workspace::app_icon_png(&app.bundle_id, 40.0)?);
            self.icon_cache.insert(app.bundle_id.clone(), icon.clone());
            Some(icon)
        });
        if self.settings.prevent_system_sleep {
            self.sleep = SleepAssertion::prevent("Tick voice recording");
        }
        cx.notify();
        self.watch_live_text(cx);

        let model = self.settings.selected_model.clone();
        let recorder = self.recorder.clone();
        let frontmost_for_context = frontmost.clone();
        let task = cx.spawn(async move |this, cx| {
            // Browser URLs come from AppleScript, which can take a moment.
            if let Some(app) = frontmost_for_context {
                let context = cx
                    .background_executor()
                    .spawn(async move { app_context(&app.bundle_id, &app.name) })
                    .await;
                let _ = this.update(cx, |state, _| state.dictation.context = Some(context));
            }
            match speech::start_streaming(&model).await {
                Ok(true) => recorder.set_streaming(true),
                Ok(false) => {}
                Err(error) => tracing::error!(target: "transcription", "streaming setup failed ({error}); batch transcription remains available"),
            }
            let started = cx.background_executor().spawn(async move { recorder.start() }).await;
            if let Err(error) = started {
                tracing::error!(target: "recording", "recording failed to start: {error}");
                let _ = this.update(cx, |state, cx| state.fail(&error, None, cx));
            }
        });
        self.tasks.transcription = Some(task);
    }

    pub(super) fn stop_recording(&mut self, cx: &mut Context<Self>) {
        let Phase::Recording { started } = self.phase else {
            return;
        };
        let was_locked = self.locked;
        self.locked = false;
        self.sleep = None;
        let elapsed = started.elapsed().as_secs_f64();
        let proceed = should_transcribe(
            &self.settings.hotkey,
            self.settings.minimum_key_time,
            elapsed,
        );
        tracing::info!(target: "transcription", "recording stopped after {elapsed:.3}s; transcribe={proceed}");
        let recorder = self.recorder.clone();
        if !proceed {
            self.phase = Phase::Idle;
            cx.notify();
            let previous = self.tasks.transcription.take();
            self.tasks.transcription = Some(cx.spawn(async move |_, cx| {
                drop(previous);
                let path = cx
                    .background_executor()
                    .spawn(async move { stop_recorder(&recorder) })
                    .await;
                speech::cancel_streaming();
                remove_file(path);
            }));
            return;
        }
        self.phase = Phase::Transcribing;
        self.live = speech::LiveText::default();
        self.dictation.released_at = Some(Instant::now());
        self.sound
            .release(if was_locked { Cue::Lock } else { Cue::Talk });
        workspace::haptic(Haptic::Level);
        cx.notify();

        let model = self.settings.selected_model.clone();
        let language = self.settings.output_language.clone();
        let previous = self.tasks.transcription.take();
        self.tasks.transcription = Some(cx.spawn(async move |this, cx| {
            // Let the start task finish so the recorder holds the session.
            if let Some(previous) = previous {
                previous.await;
            }
            let path = cx.background_executor().spawn(async move { stop_recorder(&recorder) }).await;
            let Some(path) = path else {
                let _ = this.update(cx, |state, cx| state.fail("No audio was captured.", None, cx));
                return;
            };
            let streamed = match speech::finish_streaming().await {
                Ok(text) => text.filter(|t| !t.trim().is_empty()),
                Err(error) => {
                    tracing::error!(target: "transcription", "streaming flush failed ({error}); using batch transcription");
                    speech::cancel_streaming();
                    None
                }
            };
            let result = match streamed {
                Some(text) => Ok(text),
                None => speech::transcribe(&path, &model, language.as_deref()).await,
            };
            match result {
                Ok(text) => process_result(this, text, path, cx).await,
                Err(error) => {
                    let _ = this.update(cx, |state, cx| state.fail(&error.to_string(), Some(path), cx));
                }
            }
        }));
    }

    /// Explicit cancel (ESC): stops everything with the close cue.
    pub(super) fn cancel(&mut self, cx: &mut Context<Self>) {
        if self.phase == Phase::Idle {
            return;
        }
        self.tasks.transcription = None;
        self.discard_walkthrough(cx);
        self.phase = Phase::Idle;
        self.live = speech::LiveText::default();
        self.locked = false;
        self.sleep = None;
        self.sound.play(Cue::Close);
        self.recorder.set_streaming(false);
        speech::cancel_streaming();
        let recorder = self.recorder.clone();
        cx.background_executor()
            .spawn(async move { remove_file(stop_recorder(&recorder)) })
            .detach();
        cx.notify();
    }

    /// Silent discard of an accidental activation.
    pub(super) fn discard(&mut self, cx: &mut Context<Self>) {
        if !matches!(self.phase, Phase::Recording { .. }) {
            return;
        }
        self.tasks.transcription = None;
        self.phase = Phase::Idle;
        self.live = speech::LiveText::default();
        self.locked = false;
        self.sleep = None;
        speech::cancel_streaming();
        let recorder = self.recorder.clone();
        cx.background_executor()
            .spawn(async move { remove_file(stop_recorder(&recorder)) })
            .detach();
        cx.notify();
    }

    fn fail(&mut self, message: &str, path: Option<PathBuf>, cx: &mut Context<Self>) {
        tracing::error!(target: "transcription", "dictation failed: {message}");
        self.phase = Phase::Idle;
        self.locked = false;
        self.sleep = None;
        remove_file(path);
        self.sound.play(Cue::Error);
        cx.notify();
    }

    fn finish_paste(&mut self, cx: &mut Context<Self>) {
        self.phase = Phase::Idle;
        if let Some(released) = self.dictation.released_at.take() {
            tracing::info!(target: "transcription", "key release to paste {}ms", released.elapsed().as_millis());
        }
        cx.notify();
    }

    fn persist_transcript(&mut self, text: String, audio: PathBuf, duration: f64) {
        if !self.settings.save_transcription_history {
            remove_file(Some(audio));
            return;
        }
        let now = SwiftDate::now();
        let destination = storage::recordings().join(recording_file_name(now));
        let audio_path = match std::fs::rename(&audio, &destination)
            .or_else(|_| std::fs::copy(&audio, &destination).map(|_| ()))
        {
            Ok(()) => {
                let _ = std::fs::remove_file(&audio);
                destination
            }
            Err(error) => {
                tracing::error!(target: "history", "could not keep the recording: {error}");
                audio
            }
        };
        let transcript = Transcript {
            id: SwiftUuid::new(),
            timestamp: now,
            text,
            audio_path: FileUrl(audio_path),
            duration,
            source_app_bundle_id: self.dictation.source_bundle.clone(),
            source_app_name: self.dictation.source_name.clone(),
            has_audio: true,
        };
        for evicted in self
            .history
            .insert(transcript, self.settings.max_history_entries)
        {
            let _ = std::fs::remove_file(&evicted.audio_path.0);
        }
        self.purge_expired_recordings();
        self.save_history();
    }

    // MARK: Paste last transcript

    pub fn paste_last_transcript(&mut self, cx: &mut Context<Self>) {
        let Some(text) = self.history.history.first().map(|t| t.text.clone()) else {
            return;
        };
        cx.spawn(async move |this, cx| {
            let sleep = sleeper(cx);
            let result = paste::paste(&text, &sleep).await;
            let _ = this.update(cx, |state, cx| match result {
                PasteResult::Pasted { .. } => state.sound.play(Cue::Ready),
                PasteResult::NoFocusedInput => state.show_notice(
                    Feedback::PasteUnavailable {
                        text,
                        reason: PasteFailure::NoFocusedInput,
                    },
                    cx,
                ),
                PasteResult::Failed => state.show_notice(
                    Feedback::PasteUnavailable {
                        text,
                        reason: PasteFailure::Rejected,
                    },
                    cx,
                ),
            });
        })
        .detach();
    }

    // MARK: Dictionary learning

    fn begin_correction_monitoring(
        &mut self,
        before: Option<String>,
        baseline: Option<String>,
        inserted: String,
        cx: &mut Context<Self>,
    ) {
        self.dictation.pending.clear();
        // Keystrokes are only a fallback for editors that hide their value;
        // with a complete AX baseline, typing elsewhere must not teach words.
        self.dictation.tracker = baseline.is_none().then(|| KeystrokeTracker::new(&inserted));
        self.hotkeys
            .set_tracking_corrections(self.dictation.tracker.is_some());
        self.tasks.correction = Some(cx.spawn(async move |this, cx| {
            const SETTLE: Duration = Duration::from_millis(700);
            const WINDOW: Duration = Duration::from_secs(60);
            let started = Instant::now();
            let mut baseline =
                baseline.filter(|value| text::contains_inserted_text(value, &inserted));
            let mut last_seen = baseline.clone();
            let mut last_evaluated: Option<String> = None;
            let mut last_change = Instant::now();
            while started.elapsed() < WINDOW {
                let interval = if started.elapsed() < Duration::from_secs(10) {
                    150
                } else {
                    500
                };
                cx.background_executor()
                    .timer(Duration::from_millis(interval))
                    .await;
                let Some(current) = paste::focused_text() else {
                    continue;
                };
                // AX can briefly return the pre-paste value.
                if baseline.is_none() && Some(&current) == before.as_ref() {
                    continue;
                }
                if baseline.is_none() && text::contains_inserted_text(&current, &inserted) {
                    baseline = Some(current.clone());
                    last_seen = Some(current);
                    last_change = Instant::now();
                    continue;
                }
                if Some(&current) != last_seen.as_ref() {
                    last_seen = Some(current);
                    last_change = Instant::now();
                    let _ = this.update(cx, |state, cx| state.correction_editing_continued(cx));
                    continue;
                }
                if Some(&current) == last_evaluated.as_ref() || last_change.elapsed() < SETTLE {
                    continue;
                }
                last_evaluated = Some(current.clone());
                if baseline.as_ref() == Some(&current) {
                    continue;
                }
                let corrections = text::detect_observed_corrections(
                    before.as_deref(),
                    baseline.as_deref(),
                    &current,
                    &inserted,
                );
                if !corrections.is_empty() {
                    let _ =
                        this.update(cx, |state, cx| state.corrections_detected(corrections, cx));
                }
            }
            let _ = this.update(cx, |state, _| {
                state.dictation.tracker = None;
                state.hotkeys.set_tracking_corrections(false);
                state.tasks.correction_settle = None;
            });
        }));
    }

    pub(super) fn correction_key(&mut self, event: KeyEvent, cx: &mut Context<Self>) {
        let Some(tracker) = self.dictation.tracker.as_mut() else {
            return;
        };
        if !tracker.apply(event.key, event.text.as_deref(), &event.modifiers) {
            return;
        }
        self.correction_editing_continued(cx);
        self.tasks.correction_settle = Some(cx.spawn(async move |this, cx| {
            cx.background_executor()
                .timer(Duration::from_millis(700))
                .await;
            let _ = this.update(cx, |state, cx| {
                let corrections = state
                    .dictation
                    .tracker
                    .as_ref()
                    .map(KeystrokeTracker::corrections)
                    .unwrap_or_default();
                if !corrections.is_empty() {
                    state.corrections_detected(corrections, cx);
                }
            });
        }));
    }

    pub(super) fn correction_click(&mut self, cx: &mut Context<Self>) {
        if self.dictation.tracker.is_none() {
            return;
        }
        cx.spawn(async move |this, cx| {
            cx.background_executor()
                .timer(Duration::from_millis(100))
                .await;
            let selected = paste::focused_selected_text();
            let _ = this.update(cx, |state, _| {
                if let (Some(selected), Some(tracker)) =
                    (selected, state.dictation.tracker.as_mut())
                {
                    tracker.select_word(&selected);
                }
            });
        })
        .detach();
    }

    fn correction_editing_continued(&mut self, cx: &mut Context<Self>) {
        if !self.dictation.pending.is_empty() {
            self.schedule_dictionary_feedback(cx);
        }
    }

    fn corrections_detected(&mut self, corrections: Vec<WordCorrection>, cx: &mut Context<Self>) {
        let mut added = Vec::new();
        self.update_settings(cx, |settings| {
            for correction in corrections {
                if correction.match_text.to_lowercase() == correction.replacement.to_lowercase() {
                    continue;
                }
                match settings
                    .word_remappings
                    .iter_mut()
                    .find(|r| r.match_text.to_lowercase() == correction.match_text.to_lowercase())
                {
                    Some(existing) => {
                        if existing.is_enabled
                            && existing.replacement.to_lowercase()
                                == correction.replacement.to_lowercase()
                        {
                            continue;
                        }
                        existing.is_enabled = true;
                        existing.replacement = correction.replacement.clone();
                    }
                    None => settings.word_remappings.push(WordRemapping::new(
                        correction.match_text.clone(),
                        correction.replacement.clone(),
                    )),
                }
                added.push(correction);
            }
        });
        if added.is_empty() {
            return;
        }
        for correction in added {
            tracing::info!(target: "transcription", "learned a dictionary correction");
            if !self.dictation.pending.contains(&correction) {
                self.dictation.pending.push(correction);
            }
        }
        self.schedule_dictionary_feedback(cx);
    }

    fn schedule_dictionary_feedback(&mut self, cx: &mut Context<Self>) {
        self.tasks.dictionary_debounce = Some(cx.spawn(async move |this, cx| {
            cx.background_executor()
                .timer(Duration::from_millis(900))
                .await;
            let _ = this.update(cx, |state, cx| {
                if state.dictation.pending.is_empty() {
                    return;
                }
                let learned = std::mem::take(&mut state.dictation.pending);
                state.sound.play(Cue::Success);
                state.show_notice(Feedback::DictionaryAdded(learned), cx);
            });
        }));
    }
}

pub(super) fn stop_recorder(recorder: &crate::audio::recorder::Recorder) -> Option<PathBuf> {
    recorder.set_streaming(false);
    recorder.stop()
}

pub(super) fn remove_file(path: Option<PathBuf>) {
    if let Some(path) = path {
        let _ = std::fs::remove_file(path);
    }
}

/// Deterministic text stages: removals, dictionary, snippets.
pub(super) fn apply_text_rules(raw: &str, settings: &Settings) -> String {
    let mut output = raw.to_string();
    if settings.word_removals_enabled {
        output = text::apply_removals(&output, &settings.word_removals);
    }
    output = text::apply_remappings(&output, &settings.word_remappings);
    text::apply_snippets(&output, &settings.snippets)
}

async fn process_result(
    this: WeakEntity<AppState>,
    raw: String,
    audio: PathBuf,
    cx: &mut AsyncApp,
) {
    if text::is_force_quit_command(&raw) {
        tracing::warn!(target: "transcription", "force quit voice command recognized");
        remove_file(Some(audio));
        let _ = cx.update(|_| workspace::quit());
        return;
    }
    let Ok(Some((processed, request))) = this.update(cx, |state, cx| {
        if raw.is_empty() {
            state.finish_paste(cx);
            return None;
        }
        let processed = apply_text_rules(&raw, &state.settings);
        if processed.is_empty() {
            state.finish_paste(cx);
            return None;
        }
        let ai_on = state.settings.ai_post_processing_mode == AiPostProcessingMode::On;
        let request = ai_on.then(|| PostProcess {
            text: processed.clone(),
            context: state.dictation.context.clone(),
            style: state.settings.writing_style(),
            groq_model: state.settings.selected_groq_model,
            model: state.settings.selected_ai_model,
        });
        Some((processed, request))
    }) else {
        remove_file(Some(audio));
        return;
    };

    let final_text = match request {
        Some(request) => match intelligence::post_process(request).await {
            Ok(text) => text,
            Err(error) => {
                tracing::error!(target: "transcription", "AI post-processing failed ({error}); using the deterministic cleanup");
                let cleaned = ai::normalize(&processed);
                if cleaned.is_empty() {
                    processed.clone()
                } else {
                    cleaned
                }
            }
        },
        None => processed,
    };
    if final_text.trim().is_empty() {
        let _ = this.update(cx, |state, cx| {
            state.fail("The formatted transcript was empty.", Some(audio), cx)
        });
        return;
    }

    let sleep = sleeper(cx);
    let result = paste::paste(&final_text, &sleep).await;
    let _ = this.update(cx, |state, cx| {
        // Spoken duration for WPM stats, measured from the audio itself.
        let recording_seconds = hound::WavReader::open(&audio)
            .map(|r| f64::from(r.duration()) / f64::from(r.spec().sample_rate))
            .unwrap_or(0.0);
        if matches!(result, PasteResult::Pasted { .. }) {
            state.sound.play(Cue::Ready);
        }
        state.persist_transcript(final_text.clone(), audio, recording_seconds);
        state.finish_paste(cx);
        match result {
            PasteResult::Pasted { before, after } => {
                state.begin_correction_monitoring(before, after, final_text, cx)
            }
            PasteResult::NoFocusedInput => state.show_notice(
                Feedback::PasteUnavailable {
                    text: final_text,
                    reason: PasteFailure::NoFocusedInput,
                },
                cx,
            ),
            PasteResult::Failed => state.show_notice(
                Feedback::PasteUnavailable {
                    text: final_text,
                    reason: PasteFailure::Rejected,
                },
                cx,
            ),
        }
    });
}
