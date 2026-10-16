//! Transcript history actions: playback, copy, deletion, and retention.

use std::time::Duration;

use gpui_kit::Context;
use tick_core::history::{expired_audio, is_known_audio};
use tick_core::id::{SwiftDate, SwiftUuid};
use tick_core::settings::RecordingRetention;

use super::{AppState, Feedback};
use crate::platform::paste;
use crate::sound::Cue;
use crate::storage;

impl AppState {
    pub fn toggle_playback(&mut self, id: SwiftUuid, cx: &mut Context<Self>) {
        if let Some((playing, handle)) = self.playing.take() {
            handle.stop();
            self.tasks.playback = None;
            if playing == id {
                cx.notify();
                return;
            }
        }
        let Some(transcript) = self.history.history.iter().find(|t| t.id == id) else { return };
        // Retention may have removed the audio while keeping the text.
        if !transcript.has_audio || !transcript.audio_path.0.exists() {
            self.sound.play(Cue::Warning);
            return;
        }
        let handle = self.sound.play_clip(transcript.audio_path.0.clone());
        self.playing = Some((id, handle.clone()));
        self.tasks.playback = Some(cx.spawn(async move |this, cx| {
            while !handle.is_finished() {
                cx.background_executor().timer(Duration::from_millis(100)).await;
            }
            let _ = this.update(cx, |state, cx| {
                if state.playing.as_ref().is_some_and(|(playing, _)| *playing == id) {
                    state.playing = None;
                    cx.notify();
                }
            });
        }));
        cx.notify();
    }

    pub fn copy_transcript(&self, text: &str) {
        paste::copy(text);
        self.sound.play(Cue::Tap);
    }

    pub fn delete_transcript(&mut self, id: SwiftUuid, cx: &mut Context<Self>) {
        if self.playing.as_ref().is_some_and(|(playing, _)| *playing == id) {
            if let Some((_, handle)) = self.playing.take() {
                handle.stop();
            }
        }
        if let Some(removed) = self.history.remove(id) {
            let _ = std::fs::remove_file(&removed.audio_path.0);
            self.save_history();
            self.sound.play(Cue::Close);
            cx.notify();
        }
    }

    pub fn delete_all_transcripts(&mut self, cx: &mut Context<Self>) {
        if let Some((_, handle)) = self.playing.take() {
            handle.stop();
        }
        for transcript in std::mem::take(&mut self.history.history) {
            let _ = std::fs::remove_file(&transcript.audio_path.0);
        }
        self.save_history();
        self.sound.play(Cue::Close);
        cx.notify();
    }

    /// Turning history off deletes everything already saved.
    pub fn set_save_history(&mut self, enabled: bool, cx: &mut Context<Self>) {
        self.update_settings(cx, |s| s.save_transcription_history = enabled);
        if !enabled {
            self.delete_all_transcripts(cx);
        }
    }

    pub fn set_retention(&mut self, retention: RecordingRetention, cx: &mut Context<Self>) {
        self.update_settings(cx, |s| s.recording_retention = retention);
        self.purge_expired_recordings();
        cx.notify();
    }

    /// Deletes expired audio (never transcript text) and orphaned recordings.
    pub(super) fn purge_expired_recordings(&mut self) {
        let retention = self.settings.recording_retention;
        if retention == RecordingRetention::Forever {
            return;
        }
        let now = SwiftDate::now();
        let expired = expired_audio(&self.history, retention, now);
        for (_, path) in &expired {
            let _ = std::fs::remove_file(path);
        }
        let ids: Vec<SwiftUuid> = expired.iter().map(|(id, _)| *id).collect();
        if let (Some(max_age), Ok(entries)) = (retention.max_age(), std::fs::read_dir(storage::recordings())) {
            for entry in entries.flatten() {
                let path = entry.path();
                if path.extension().is_some_and(|e| e == "wav") && !is_known_audio(&self.history, &path) {
                    let old = entry
                        .metadata()
                        .and_then(|m| m.created())
                        .ok()
                        .and_then(|created| created.elapsed().ok())
                        .is_none_or(|age| age.as_secs_f64() > max_age);
                    if old {
                        let _ = std::fs::remove_file(&path);
                    }
                }
            }
        }
        if !ids.is_empty() {
            self.history.mark_audio_deleted(&ids);
            self.save_history();
            tracing::info!(target: "history", "retention removed {} recording(s); transcripts kept", ids.len());
        }
    }

    pub fn copy_and_confirm(&mut self, text: &str, cx: &mut Context<Self>) {
        paste::copy(text);
        self.sound.play(Cue::Success);
        self.show_notice(Feedback::Copied, cx);
    }
}
