//! Permission polling and requests. Polling also keeps the event tap alive:
//! it is installed once Accessibility and Input Monitoring are granted.

use std::time::Duration;

use gpui_kit::Context;

use super::AppState;
use crate::platform::permissions::{self as system, PermissionStatus};
use crate::sound::Cue;

impl AppState {
    pub(super) fn start_permission_monitor(&mut self, cx: &mut Context<Self>) {
        let permissions = system::current();
        self.set_permissions(permissions, cx);
        self.tasks.background.push(cx.spawn(async move |this, cx| {
            loop {
                cx.background_executor()
                    .timer(Duration::from_millis(500))
                    .await;
                let permissions = system::current();
                if this
                    .update(cx, |state, cx| state.set_permissions(permissions, cx))
                    .is_err()
                {
                    break;
                }
            }
        }));
    }

    pub fn request_microphone(&mut self, cx: &mut Context<Self>) {
        self.sound.play(Cue::Tap);
        if self.permissions.microphone == PermissionStatus::Denied {
            system::open_microphone_settings();
            return;
        }
        let (sender, receiver) = futures::channel::oneshot::channel();
        let sender = parking_lot::Mutex::new(Some(sender));
        system::request_microphone(move |granted| {
            if let Some(sender) = sender.lock().take() {
                let _ = sender.send(granted);
            }
        });
        cx.spawn(async move |this, cx| {
            let granted = receiver.await.unwrap_or(false);
            let _ = this.update(cx, |state, cx| {
                state
                    .sound
                    .play(if granted { Cue::Success } else { Cue::Warning });
                state.set_permissions(system::current(), cx);
            });
        })
        .detach();
    }

    /// Requests whichever hotkey permission is still missing; the helper
    /// panel shows one pane at a time.
    pub fn request_hotkey_permissions(&mut self, cx: &mut Context<Self>) {
        self.sound.play(Cue::Tap);
        if !self.permissions.accessibility.is_granted() {
            system::request_accessibility();
        } else if !self.permissions.input_monitoring.is_granted() {
            system::request_input_monitoring();
        }
        self.set_permissions(system::current(), cx);
    }

    pub fn complete_onboarding(&mut self, cx: &mut Context<Self>) {
        if !self.permissions.all_granted() {
            self.sound.play(Cue::Warning);
            self.set_permissions(system::current(), cx);
            return;
        }
        self.sound.play(Cue::Success);
        self.update_settings(cx, |s| s.has_completed_welcome_onboarding = true);
        self.repair_mode = false;
        cx.notify();
    }
}
