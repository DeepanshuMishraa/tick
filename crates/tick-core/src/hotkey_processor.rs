//! Press-and-hold / double-tap-lock hotkey state machine.
//!
//! See `docs/hotkey-semantics.md`. Time is passed in explicitly as seconds on
//! any monotonic clock so the machine is deterministic under test.

use crate::constants::{DEFAULT_MINIMUM_KEY_TIME, DOUBLE_TAP_WINDOW, MODIFIER_ONLY_MINIMUM_DURATION, PRESS_AND_HOLD_CANCEL_WINDOW};
use crate::hotkey::{HotKey, Key, KeyEvent};

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum ProcessorState {
    Idle,
    PressAndHold { started_at: f64 },
    DoubleTapLock,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ProcessorOutput {
    StartRecording,
    StopRecording,
    /// Explicit ESC cancellation (plays the cancel cue).
    Cancel,
    /// Silent discard of an accidental activation.
    Discard,
}

#[derive(Debug, Clone)]
pub struct HotKeyProcessor {
    pub hotkey: HotKey,
    /// Only effective for key+modifier hotkeys with the lock enabled.
    pub use_double_tap_only: bool,
    pub double_tap_lock_enabled: bool,
    pub minimum_key_time: f64,
    state: ProcessorState,
    last_tap_at: Option<f64>,
    is_dirty: bool,
}

impl HotKeyProcessor {
    pub fn new(hotkey: HotKey) -> Self {
        Self {
            hotkey,
            use_double_tap_only: false,
            double_tap_lock_enabled: true,
            minimum_key_time: DEFAULT_MINIMUM_KEY_TIME,
            state: ProcessorState::Idle,
            last_tap_at: None,
            is_dirty: false,
        }
    }

    pub fn state(&self) -> ProcessorState {
        self.state
    }

    pub fn is_matched(&self) -> bool {
        self.state != ProcessorState::Idle
    }

    pub fn process(&mut self, event: &KeyEvent, now: f64) -> Option<ProcessorOutput> {
        if event.key == Some(Key::Escape) && self.state != ProcessorState::Idle {
            self.is_dirty = true;
            self.reset_to_idle();
            return Some(ProcessorOutput::Cancel);
        }

        if self.is_dirty {
            if Self::fully_released(event) {
                self.is_dirty = false;
            } else {
                return None;
            }
        }

        if self.chord_matches(event) {
            self.handle_matching(now)
        } else {
            if self.chord_is_dirty(event) {
                self.is_dirty = true;
            }
            self.handle_nonmatching(event, now)
        }
    }

    /// Mouse clicks cancel only young modifier-only recordings, which avoids
    /// stealing Option+click and similar OS gestures.
    pub fn process_mouse_click(&mut self, now: f64) -> Option<ProcessorOutput> {
        if self.hotkey.key.is_some() {
            return None;
        }
        match self.state {
            ProcessorState::PressAndHold { started_at } => {
                if now - started_at < self.modifier_only_minimum() {
                    self.is_dirty = true;
                    self.reset_to_idle();
                    Some(ProcessorOutput::Discard)
                } else {
                    None
                }
            }
            ProcessorState::Idle | ProcessorState::DoubleTapLock => None,
        }
    }

    fn modifier_only_minimum(&self) -> f64 {
        self.minimum_key_time.max(MODIFIER_ONLY_MINIMUM_DURATION)
    }

    fn double_tap_only_active(&self) -> bool {
        self.use_double_tap_only && self.double_tap_lock_enabled && self.hotkey.key.is_some()
    }

    fn handle_matching(&mut self, now: f64) -> Option<ProcessorOutput> {
        match self.state {
            ProcessorState::Idle => {
                if self.double_tap_only_active() {
                    self.last_tap_at = Some(now);
                    None
                } else {
                    self.state = ProcessorState::PressAndHold { started_at: now };
                    Some(ProcessorOutput::StartRecording)
                }
            }
            ProcessorState::PressAndHold { .. } => None,
            ProcessorState::DoubleTapLock => {
                self.reset_to_idle();
                Some(ProcessorOutput::StopRecording)
            }
        }
    }

    fn handle_nonmatching(&mut self, event: &KeyEvent, now: f64) -> Option<ProcessorOutput> {
        match self.state {
            ProcessorState::Idle => {
                if self.double_tap_only_active() && Self::fully_released(event) {
                    if let Some(previous) = self.last_tap_at {
                        if now - previous < DOUBLE_TAP_WINDOW {
                            self.state = ProcessorState::DoubleTapLock;
                            return Some(ProcessorOutput::StartRecording);
                        }
                        self.last_tap_at = None;
                    }
                }
                None
            }
            ProcessorState::PressAndHold { started_at } => {
                if self.is_release(event) {
                    if self.double_tap_lock_enabled
                        && self.last_tap_at.is_some_and(|previous| now - previous < DOUBLE_TAP_WINDOW)
                    {
                        self.state = ProcessorState::DoubleTapLock;
                        return None;
                    }
                    self.state = ProcessorState::Idle;
                    self.last_tap_at = self.double_tap_lock_enabled.then_some(now);
                    return Some(ProcessorOutput::StopRecording);
                }
                let elapsed = now - started_at;
                if self.hotkey.key.is_none() {
                    if elapsed < self.modifier_only_minimum() {
                        self.is_dirty = true;
                        self.reset_to_idle();
                        Some(ProcessorOutput::Discard)
                    } else {
                        None
                    }
                } else if elapsed < PRESS_AND_HOLD_CANCEL_WINDOW {
                    self.is_dirty = true;
                    self.reset_to_idle();
                    Some(if elapsed < self.minimum_key_time {
                        ProcessorOutput::Discard
                    } else {
                        ProcessorOutput::StopRecording
                    })
                } else {
                    None
                }
            }
            ProcessorState::DoubleTapLock => {
                if self.double_tap_only_active() && Self::fully_released(event) {
                    self.reset_to_idle();
                    Some(ProcessorOutput::StopRecording)
                } else {
                    None
                }
            }
        }
    }

    fn chord_matches(&self, event: &KeyEvent) -> bool {
        event.key == self.hotkey.key && event.modifiers.matches_exactly(&self.hotkey.modifiers)
    }

    fn chord_is_dirty(&self, event: &KeyEvent) -> bool {
        let is_subset = event.modifiers.is_subset_of(&self.hotkey.modifiers);
        match self.hotkey.key {
            None => event.key.is_some() || !is_subset,
            Some(key) => !is_subset || event.key.is_some_and(|pressed| pressed != key),
        }
    }

    fn fully_released(event: &KeyEvent) -> bool {
        event.key.is_none() && event.modifiers.is_empty()
    }

    fn is_release(&self, event: &KeyEvent) -> bool {
        match self.hotkey.key {
            // Key hotkeys release when the key lifts, even if a modifier went
            // first, provided no new modifier appeared.
            Some(_) => event.key.is_none() && event.modifiers.is_subset_of(&self.hotkey.modifiers),
            None => event.key.is_none() && !self.hotkey.modifiers.is_subset_of(&event.modifiers),
        }
    }

    fn reset_to_idle(&mut self) {
        self.state = ProcessorState::Idle;
        self.last_tap_at = None;
    }
}

/// Whether a stopped recording is long enough to transcribe.
pub fn should_transcribe(hotkey: &HotKey, minimum_key_time: f64, elapsed: f64) -> bool {
    if hotkey.key.is_some() {
        return true;
    }
    elapsed >= minimum_key_time.max(MODIFIER_ONLY_MINIMUM_DURATION)
}
