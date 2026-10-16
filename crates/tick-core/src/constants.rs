//! Timing thresholds tuned against macOS shortcut behavior.
//! See `docs/hotkey-semantics.md` before changing any of these.

/// Maximum gap between two taps that counts as a double-tap.
pub const DOUBLE_TAP_WINDOW: f64 = 0.3;

/// Modifier-only hotkeys must be held at least this long, so Option+click and
/// similar OS gestures never start a dictation.
pub const MODIFIER_ONLY_MINIMUM_DURATION: f64 = 0.3;

/// A different key within this window of a key+modifier press is treated as
/// an accidental chord.
pub const PRESS_AND_HOLD_CANCEL_WINDOW: f64 = 1.0;

pub const DEFAULT_MINIMUM_KEY_TIME: f64 = 0.2;

/// Ceiling for cue volume; the user setting scales within it.
pub const BASE_SOUND_EFFECTS_VOLUME: f64 = 0.2;
