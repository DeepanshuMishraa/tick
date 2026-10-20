//! Bridges the global event tap to the app. Intercept decisions are made
//! synchronously in the tap callback (they must be); everything else is
//! forwarded as `HotkeyEvent`s to the app's foreground task.

use std::sync::Arc;
use std::time::Instant;

use futures::channel::mpsc::UnboundedSender;
use parking_lot::Mutex;
use tick_core::hotkey::{HotKey, InputEvent, Key, KeyEvent, ModifierKind, Modifiers, MouseEvent, MousePhase};
use tick_core::hotkey_processor::{HotKeyProcessor, ProcessorOutput, ProcessorState};
use tick_core::settings::Settings;

use crate::platform::keyboard::EventTap;

/// What a captured key event is recorded into in Settings.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CaptureTarget {
    Recording,
    PasteLast,
    Walkthrough,
}

/// What the tap intercepts for a walkthrough.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WalkthroughTap {
    Off,
    /// Recording: ⇧-drags draw instead of reaching apps, and ⌘Z undoes the
    /// last mark while there is one.
    Recording { undoable: bool },
}

#[derive(Debug, Clone, PartialEq)]
pub enum WalkthroughInput {
    Toggle,
    Undo,
    /// A ⇧-held stroke starting, extending or ending at a global point.
    Ink(MousePhase, f64, f64),
    /// A plain click at a global point.
    Click(f64, f64),
}

#[derive(Debug, Clone, PartialEq)]
pub enum HotkeyEvent {
    Pressed,
    Released,
    StartLocked,
    Cancel,
    Discard,
    Locked(bool),
    /// Key-down forwarded while dictionary learning watches an insertion.
    Key(KeyEvent),
    MouseClick,
    PasteLast,
    Capture(KeyEvent),
    Walkthrough(WalkthroughInput),
}

struct Bridge {
    processor: HotKeyProcessor,
    paste_last: Option<HotKey>,
    walkthrough_hotkey: Option<HotKey>,
    walkthrough: WalkthroughTap,
    /// A ⇧-drag began while recording a walkthrough; its events are swallowed.
    drawing: bool,
    capture: Option<CaptureTarget>,
    tracking_corrections: bool,
    epoch: Instant,
}

/// Shared handle used by the app to keep the tap's view of settings fresh.
#[derive(Clone)]
pub struct Hotkeys {
    bridge: Arc<Mutex<Bridge>>,
    events: UnboundedSender<HotkeyEvent>,
}

impl Hotkeys {
    pub fn new(settings: &Settings, events: UnboundedSender<HotkeyEvent>) -> Hotkeys {
        let hotkeys = Hotkeys {
            bridge: Arc::new(Mutex::new(Bridge {
                processor: HotKeyProcessor::new(settings.hotkey.clone()),
                paste_last: None,
                walkthrough_hotkey: None,
                walkthrough: WalkthroughTap::Off,
                drawing: false,
                capture: None,
                tracking_corrections: false,
                epoch: Instant::now(),
            })),
            events,
        };
        hotkeys.configure(settings);
        hotkeys
    }

    pub fn configure(&self, settings: &Settings) {
        let mut bridge = self.bridge.lock();
        bridge.processor.hotkey = settings.hotkey.clone();
        bridge.processor.double_tap_lock_enabled = settings.double_tap_lock_enabled;
        bridge.processor.use_double_tap_only = settings.effective_double_tap_only();
        bridge.processor.minimum_key_time = settings.minimum_key_time;
        bridge.paste_last = settings.paste_last_transcript_hotkey.clone();
        bridge.walkthrough_hotkey = settings.walkthrough_hotkey.clone();
    }

    pub fn set_capture(&self, target: Option<CaptureTarget>) {
        self.bridge.lock().capture = target;
    }

    pub fn set_walkthrough(&self, tap: WalkthroughTap) {
        let mut bridge = self.bridge.lock();
        bridge.walkthrough = tap;
        if tap == WalkthroughTap::Off {
            bridge.drawing = false;
        }
    }

    pub fn set_tracking_corrections(&self, tracking: bool) {
        self.bridge.lock().tracking_corrections = tracking;
    }

    /// Installs the tap; `None` until Accessibility is granted.
    pub fn install(&self) -> Option<EventTap> {
        let bridge = self.bridge.clone();
        let events = self.events.clone();
        EventTap::install(Box::new(move |event| handle(&mut bridge.lock(), &events, event)))
    }
}

fn handle(bridge: &mut Bridge, events: &UnboundedSender<HotkeyEvent>, event: InputEvent) -> bool {
    let send = |event: HotkeyEvent| {
        let _ = events.unbounded_send(event);
    };
    let now = bridge.epoch.elapsed().as_secs_f64();
    let intercept = match event {
        InputEvent::Keyboard(key_event) => {
            if bridge.capture.is_some() {
                send(HotkeyEvent::Capture(key_event));
                return false;
            }
            if bridge.tracking_corrections && key_event.is_key_down {
                send(HotkeyEvent::Key(key_event.clone()));
            }
            if matches_shortcut(&key_event, bridge.walkthrough_hotkey.as_ref()) {
                send(HotkeyEvent::Walkthrough(WalkthroughInput::Toggle));
                return true;
            }
            if bridge.walkthrough == (WalkthroughTap::Recording { undoable: true })
                && key_event.key == Some(Key::Z)
                && key_event.modifiers.matches_exactly(&Modifiers::of(&[ModifierKind::Command]))
            {
                send(HotkeyEvent::Walkthrough(WalkthroughInput::Undo));
                return true;
            }
            let paste_last = matches_shortcut(&key_event, bridge.paste_last.as_ref());
            if paste_last {
                send(HotkeyEvent::PasteLast);
            }
            let processed = process_key(bridge, &key_event, now, &send);
            paste_last || processed
        }
        InputEvent::Mouse(mouse) => {
            if mouse.phase != MousePhase::Down {
                // Drags arrive constantly; only a walkthrough cares about them.
                return walkthrough_mouse(bridge, &mouse, &send);
            }
            send(HotkeyEvent::MouseClick);
            match bridge.processor.process_mouse_click(now) {
                Some(ProcessorOutput::Cancel) => send(HotkeyEvent::Cancel),
                Some(ProcessorOutput::Discard) => send(HotkeyEvent::Discard),
                _ => {}
            }
            walkthrough_mouse(bridge, &mouse, &send)
        }
    };
    send(HotkeyEvent::Locked(bridge.processor.state() == ProcessorState::DoubleTapLock));
    intercept
}

fn matches_shortcut(event: &KeyEvent, shortcut: Option<&HotKey>) -> bool {
    shortcut.is_some_and(|hotkey| {
        event.key.is_some() && event.key == hotkey.key && event.modifiers.matches_exactly(&hotkey.modifiers)
    })
}

/// Turns mouse events into walkthrough input; true swallows the event.
fn walkthrough_mouse(bridge: &mut Bridge, mouse: &MouseEvent, send: &dyn Fn(HotkeyEvent)) -> bool {
    if bridge.walkthrough == WalkthroughTap::Off {
        return false;
    }
    let ink = |phase| HotkeyEvent::Walkthrough(WalkthroughInput::Ink(phase, mouse.x, mouse.y));
    match mouse.phase {
        MousePhase::Down => {
            bridge.drawing = mouse.modifiers.matches_exactly(&Modifiers::of(&[ModifierKind::Shift]));
            send(if bridge.drawing { ink(MousePhase::Down) } else { HotkeyEvent::Walkthrough(WalkthroughInput::Click(mouse.x, mouse.y)) });
            bridge.drawing
        }
        MousePhase::Dragged if bridge.drawing => {
            send(ink(MousePhase::Dragged));
            true
        }
        MousePhase::Up if bridge.drawing => {
            bridge.drawing = false;
            send(ink(MousePhase::Up));
            true
        }
        MousePhase::Dragged | MousePhase::Up => false,
    }
}

fn process_key(bridge: &mut Bridge, event: &KeyEvent, now: f64, send: &dyn Fn(HotkeyEvent)) -> bool {
    if event.key == Some(Key::Escape) && event.modifiers.is_empty() && bridge.processor.state() == ProcessorState::Idle {
        send(HotkeyEvent::Cancel);
        return false;
    }
    let double_tap_only = bridge.processor.use_double_tap_only;
    match bridge.processor.process(event, now) {
        Some(ProcessorOutput::StartRecording) => {
            if bridge.processor.state() == ProcessorState::DoubleTapLock {
                send(HotkeyEvent::StartLocked);
            } else {
                send(HotkeyEvent::Pressed);
            }
            // A modifier-only chord must keep reaching other apps.
            double_tap_only || event.key.is_some()
        }
        Some(ProcessorOutput::StopRecording) => {
            send(HotkeyEvent::Released);
            false
        }
        Some(ProcessorOutput::Cancel) => {
            send(HotkeyEvent::Cancel);
            true
        }
        Some(ProcessorOutput::Discard) => {
            send(HotkeyEvent::Discard);
            false
        }
        None => {
            // Swallow auto-repeats of a held key hotkey.
            let hotkey = &bridge.processor.hotkey;
            event.key.is_some() && event.key == hotkey.key && event.modifiers == hotkey.modifiers
        }
    }
}
