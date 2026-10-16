//! The application model. One `AppState` entity owns settings, history,
//! permissions, the dictation pipeline, and model management; views read it
//! and call its methods.

mod dictation;
mod history;
mod models;
mod permissions;

use std::sync::Arc;
use std::time::{Duration, Instant};

use futures::StreamExt;
use gpui_kit::{App, AppContext as _, Context, Entity, Global, Image, ImageFormat, Task};
use tick_core::history::History;
use tick_core::hotkey::{HotKey, Key, Modifiers};
use tick_core::models::{languages, Language};
use tick_core::settings::Settings;

use crate::audio::devices::DeviceSnapshot;
use crate::audio::recorder::{Recorder, RecorderConfig};
use crate::hotkeys::{CaptureTarget, HotkeyEvent, Hotkeys};
use crate::platform::keyboard::EventTap;
use crate::platform::permissions::Permissions;
use crate::platform::system::SleepAssertion;
use crate::platform::{system, workspace};
use crate::sound::{ClipHandle, Cue, Sound};
use crate::storage;

pub use dictation::{Feedback, Phase, PasteFailure};
pub use models::{AiModelState, ModelState};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Tab {
    Home,
    Insights,
    Dictionary,
    Snippets,
    Style,
    Settings,
    Help,
}

impl Tab {
    pub fn title(self) -> &'static str {
        match self {
            Tab::Home => "Home",
            Tab::Insights => "Insights",
            Tab::Dictionary => "Dictionary",
            Tab::Snippets => "Snippets",
            Tab::Style => "Style",
            Tab::Settings => "Settings",
            Tab::Help => "Help",
        }
    }
}

/// Visible state of a feedback notice, with its countdown.
#[derive(Debug, Clone, PartialEq)]
pub struct Notice {
    pub feedback: Feedback,
    pub shown_at: Instant,
    pub duration: Duration,
}

pub struct AppState {
    pub settings: Settings,
    pub history: History,
    pub permissions: Permissions,
    /// Onboarding finished but a permission was revoked.
    pub repair_mode: bool,
    pub devices: DeviceSnapshot,
    pub tab: Tab,
    pub phase: Phase,
    pub locked: bool,
    pub notice: Option<Notice>,
    /// Icon of the app being dictated into, for the notch.
    pub source_icon: Option<Arc<Image>>,
    /// Rendered app icons by bundle id; rendering one costs a few milliseconds.
    icon_cache: std::collections::HashMap<String, Arc<Image>>,
    pub source_name: Option<String>,
    pub models: ModelState,
    pub ai: AiModelState,
    pub groq_key: String,
    pub capture: Option<CaptureTarget>,
    pub capture_modifiers: Modifiers,
    pub flash_model_section: bool,
    pub playing: Option<(tick_core::id::SwiftUuid, ClipHandle)>,
    pub languages: Vec<Language>,
    pub user_name: String,
    pub wizard_open: bool,

    pub(crate) recorder: Recorder,
    pub(crate) sound: Sound,
    pub(crate) hotkeys: Hotkeys,
    tap: Option<EventTap>,
    sleep: Option<SleepAssertion>,
    dictation: dictation::Session,
    tasks: Tasks,
}

#[derive(Default)]
struct Tasks {
    transcription: Option<Task<()>>,
    correction: Option<Task<()>>,
    correction_settle: Option<Task<()>>,
    dictionary_debounce: Option<Task<()>>,
    notice: Option<Task<()>>,
    speech_download: Option<Task<()>>,
    ai_download: Option<Task<()>>,
    playback: Option<Task<()>>,
    flash: Option<Task<()>>,
    background: Vec<Task<()>>,
}

/// Global handle to the app state entity.
pub struct AppStateGlobal(pub Entity<AppState>);

impl Global for AppStateGlobal {}

impl AppState {
    pub fn global(cx: &App) -> Entity<AppState> {
        cx.global::<AppStateGlobal>().0.clone()
    }

    pub fn new(cx: &mut Context<AppState>) -> AppState {
        let settings = storage::load_settings();
        let history = storage::load_history();
        let sound = Sound::start();
        sound.configure(settings.sound_effects_enabled, settings.sound_effects_volume);

        let (device_sender, mut device_receiver) = futures::channel::mpsc::unbounded::<DeviceSnapshot>();
        let recorder = Recorder::spawn(recorder_config(&settings), move |snapshot| {
            let _ = device_sender.unbounded_send(snapshot);
        });
        let (hotkey_sender, mut hotkey_receiver) = futures::channel::mpsc::unbounded::<HotkeyEvent>();
        let hotkeys = Hotkeys::new(&settings, hotkey_sender);

        let mut tasks = Tasks::default();
        tasks.background.push(cx.spawn(async move |this, cx| {
            while let Some(event) = hotkey_receiver.next().await {
                if this.update(cx, |state, cx| state.handle_hotkey(event, cx)).is_err() {
                    break;
                }
            }
        }));
        tasks.background.push(cx.spawn(async move |this, cx| {
            while let Some(snapshot) = device_receiver.next().await {
                if this.update(cx, |state, cx| {
                    state.devices = snapshot;
                    cx.notify();
                })
                .is_err()
                {
                    break;
                }
            }
        }));

        let state = AppState {
            permissions: crate::platform::permissions::current(),
            repair_mode: false,
            devices: DeviceSnapshot::default(),
            tab: Tab::Home,
            phase: Phase::Idle,
            locked: false,
            notice: None,
            source_icon: None,
            icon_cache: Default::default(),
            source_name: None,
            models: ModelState::default(),
            ai: AiModelState::default(),
            groq_key: crate::intelligence::groq_key().unwrap_or_default(),
            capture: None,
            capture_modifiers: Modifiers::empty(),
            flash_model_section: false,
            playing: None,
            languages: languages(),
            user_name: workspace::user_first_name(),
            wizard_open: false,
            recorder,
            sound,
            hotkeys,
            tap: None,
            sleep: None,
            dictation: dictation::Session::default(),
            tasks,
            settings,
            history,
        };
        state
    }

    /// Launch work: hotkeys, permissions, model readiness, warm-ups.
    pub fn start(&mut self, cx: &mut Context<Self>) {
        self.recorder.warm_up();
        self.start_permission_monitor(cx);
        self.refresh_model_readiness(cx);
        self.fetch_catalog(cx);
        self.refresh_ai_model(cx);
        self.purge_expired_recordings();
        self.warm_models(cx);
        crate::native::updater::start();
        if self.settings.open_on_login {
            let _ = system::set_open_on_login(true);
        }
    }

    pub fn set_tab(&mut self, tab: Tab, cx: &mut Context<Self>) {
        if self.tab != tab {
            self.tab = tab;
            self.sound.play(Cue::Navigate);
            // The style picker opens once, on the first visit to Style.
            let seen = storage::app_support().join(".style-picker-seen");
            if tab == Tab::Style && !seen.exists() {
                let _ = std::fs::write(&seen, b"");
                self.wizard_open = true;
            }
            cx.notify();
        }
    }

    /// Applies a settings edit, persists it, and reconfigures services.
    pub fn toggle_sidebar(&mut self, cx: &mut Context<Self>) {
        self.update_settings(cx, |s| s.sidebar_collapsed = !s.sidebar_collapsed);
    }

    pub fn update_settings(&mut self, cx: &mut Context<Self>, edit: impl FnOnce(&mut Settings)) {
        let before = self.settings.clone();
        edit(&mut self.settings);
        self.settings.normalize();
        if self.settings == before {
            return;
        }
        storage::save_settings(&self.settings);
        self.hotkeys.configure(&self.settings);
        self.sound.configure(self.settings.sound_effects_enabled, self.settings.sound_effects_volume);
        let recorder_changed = recorder_config(&before) != recorder_config(&self.settings);
        if recorder_changed {
            self.recorder.configure(recorder_config(&self.settings));
        }
        if before.super_fast_mode_enabled != self.settings.super_fast_mode_enabled {
            self.recorder.warm_up();
        }
        if before.show_dock_icon != self.settings.show_dock_icon {
            workspace::set_dock_icon_visible(self.settings.show_dock_icon);
        }
        if before.open_on_login != self.settings.open_on_login {
            if let Err(error) = system::set_open_on_login(self.settings.open_on_login) {
                tracing::error!(target: "settings", "login item update failed: {error}");
            }
        }
        if before.selected_ai_model != self.settings.selected_ai_model {
            self.refresh_ai_model(cx);
        }
        if before.ai_post_processing_mode != self.settings.ai_post_processing_mode {
            self.warm_ai(cx);
        }
        cx.notify();
    }

    pub fn save_history(&self) {
        storage::save_history(&self.history);
    }

    // MARK: Hotkey capture in Settings

    pub fn begin_capture(&mut self, target: CaptureTarget, cx: &mut Context<Self>) {
        self.capture = Some(target);
        self.capture_modifiers = Modifiers::empty();
        self.hotkeys.set_capture(Some(target));
        self.sound.play(Cue::Open);
        cx.notify();
    }

    pub fn end_capture(&mut self, cx: &mut Context<Self>) {
        self.capture = None;
        self.capture_modifiers = Modifiers::empty();
        self.hotkeys.set_capture(None);
        cx.notify();
    }

    fn handle_capture(&mut self, event: tick_core::hotkey::KeyEvent, cx: &mut Context<Self>) {
        let Some(target) = self.capture else { return };
        if event.key == Some(Key::Escape) {
            self.sound.play(Cue::Close);
            self.end_capture(cx);
            return;
        }
        let modifiers = event.modifiers.union(&self.capture_modifiers);
        self.capture_modifiers = modifiers.clone();
        cx.notify();
        if target == CaptureTarget::PasteLast && event.key.is_some() && modifiers.is_empty() {
            return;
        }
        if let Some(key) = event.key {
            let hotkey = HotKey::new(Some(key), modifiers.erasing_sides());
            self.update_settings(cx, |settings| match target {
                CaptureTarget::Recording => settings.hotkey = hotkey,
                CaptureTarget::PasteLast => settings.paste_last_transcript_hotkey = Some(hotkey),
            });
            self.sound.play(Cue::Success);
            workspace::haptic(workspace::Haptic::Alignment);
            self.end_capture(cx);
            return;
        }
        if target == CaptureTarget::Recording && event.modifiers.is_empty() && !modifiers.is_empty() {
            let hotkey = HotKey::new(None, modifiers.erasing_sides());
            self.update_settings(cx, |settings| settings.hotkey = hotkey);
            self.sound.play(Cue::Success);
            workspace::haptic(workspace::Haptic::Alignment);
            self.end_capture(cx);
        }
    }

    fn handle_hotkey(&mut self, event: HotkeyEvent, cx: &mut Context<Self>) {
        match event {
            HotkeyEvent::Pressed => {
                if self.phase == Phase::Transcribing {
                    self.cancel(cx);
                }
                self.start_recording(false, cx);
            }
            HotkeyEvent::StartLocked => self.start_recording(true, cx),
            HotkeyEvent::Released => {
                if matches!(self.phase, Phase::Recording { .. }) {
                    self.stop_recording(cx);
                }
            }
            HotkeyEvent::Cancel => self.cancel(cx),
            HotkeyEvent::Discard => self.discard(cx),
            HotkeyEvent::Locked(locked) => {
                if self.locked != locked && matches!(self.phase, Phase::Recording { .. }) {
                    self.locked = locked;
                    if locked {
                        workspace::haptic(workspace::Haptic::Alignment);
                    }
                    cx.notify();
                }
            }
            HotkeyEvent::Key(key) => self.correction_key(key, cx),
            HotkeyEvent::MouseClick => self.correction_click(cx),
            HotkeyEvent::PasteLast => self.paste_last_transcript(cx),
            HotkeyEvent::Capture(key) => self.handle_capture(key, cx),
        }
    }

    // MARK: Notices

    pub fn show_notice(&mut self, feedback: Feedback, cx: &mut Context<Self>) {
        let duration = match feedback {
            Feedback::Copied => Duration::from_millis(1800),
            Feedback::DictionaryAdded(_) => Duration::from_secs(5),
            Feedback::PasteUnavailable { .. } => Duration::from_secs(4),
        };
        self.notice = Some(Notice { feedback, shown_at: Instant::now(), duration });
        self.tasks.notice = Some(cx.spawn(async move |this, cx| {
            cx.background_executor().timer(duration).await;
            let _ = this.update(cx, |state, cx| {
                state.notice = None;
                cx.notify();
            });
        }));
        cx.notify();
    }

    /// The notice's "Copy" action for an undeliverable transcript.
    pub fn copy_notice_text(&mut self, cx: &mut Context<Self>) {
        let Some(Notice { feedback: Feedback::PasteUnavailable { text, .. }, .. }) = &self.notice else { return };
        crate::platform::paste::copy(text);
        self.sound.play(Cue::Success);
        self.show_notice(Feedback::Copied, cx);
    }

    pub fn play_sound(&self, cue: Cue) {
        self.sound.play(cue);
    }

    /// Releases audio state; called on quit.
    pub fn shutdown(&mut self) {
        self.recorder.cleanup();
        self.sleep = None;
        self.tap = None;
    }

    fn set_permissions(&mut self, permissions: Permissions, cx: &mut Context<Self>) {
        let all_before = self.permissions.all_granted();
        let changed = self.permissions != permissions;
        self.permissions = permissions;
        if permissions.hotkeys_granted() {
            match &self.tap {
                Some(tap) => tap.ensure_enabled(),
                None => {
                    self.tap = self.hotkeys.install();
                    if self.tap.is_some() {
                        tracing::info!(target: "hotkey", "keyboard monitoring active");
                    }
                }
            }
        } else if self.tap.is_some() {
            tracing::warn!(target: "hotkey", "hotkey permissions revoked; suspending the event tap");
            self.tap = None;
        }
        if self.settings.has_completed_welcome_onboarding {
            let all = permissions.all_granted();
            if !all && !self.repair_mode {
                self.repair_mode = true;
                workspace::activate_app();
            } else if all && self.repair_mode {
                self.repair_mode = false;
                crate::platform::permissions::dismiss_panels();
            }
        }
        if !all_before && permissions.all_granted() {
            crate::platform::permissions::dismiss_panels();
        }
        if changed {
            cx.notify();
        }
    }
}

fn recorder_config(settings: &Settings) -> RecorderConfig {
    RecorderConfig {
        super_fast: settings.super_fast_mode_enabled,
        microphone: settings.selected_microphone_id.clone(),
        audio_behavior: settings.recording_audio_behavior,
    }
}

pub fn png_image(bytes: Vec<u8>) -> Arc<Image> {
    Arc::new(Image::from_bytes(ImageFormat::Png, bytes))
}

pub fn init(cx: &mut App) -> Entity<AppState> {
    let state = cx.new(AppState::new);
    cx.set_global(AppStateGlobal(state.clone()));
    state.update(cx, |state, cx| state.start(cx));
    state
}
