//! Global keyboard/mouse monitoring through a CGEvent tap, plus synthetic
//! key posting for paste and keyboard commands.
//!
//! The tap runs on the main run loop. Its handler decides synchronously
//! whether to swallow an event; anything slower is forwarded to the app.

use std::ffi::c_void;

use tick_core::hotkey::{InputEvent, Key, KeyEvent, ModifierKind, Modifiers, MouseEvent, MousePhase};

use super::sys::*;

const FN_KEY_CODE: i64 = 63;

/// Returns true to swallow the event.
pub type Handler = Box<dyn FnMut(InputEvent) -> bool>;

struct TapState {
    handler: Handler,
    fn_pressed: bool,
    port: CFMachPortRef,
}

/// An installed event tap. Dropping it removes the tap.
pub struct EventTap {
    port: CFMachPortRef,
    source: CFRunLoopSourceRef,
    state: *mut TapState,
}

impl EventTap {
    /// Installs the tap. Fails without Accessibility trust.
    pub fn install(handler: Handler) -> Option<EventTap> {
        let mask = [
            kCGEventKeyDown,
            kCGEventKeyUp,
            kCGEventFlagsChanged,
            kCGEventLeftMouseDown,
            kCGEventLeftMouseDragged,
            kCGEventLeftMouseUp,
            kCGEventRightMouseDown,
            kCGEventOtherMouseDown,
        ]
        .iter()
        .fold(0u64, |mask, kind| mask | (1u64 << kind));
        let state = Box::into_raw(Box::new(TapState { handler, fn_pressed: false, port: std::ptr::null_mut() }));
        // SAFETY: the callback receives `state`, which lives until `Drop`.
        let port = unsafe {
            CGEventTapCreate(kCGHIDEventTap, kCGHeadInsertEventTap, kCGEventTapOptionDefault, mask, tap_callback, state.cast())
        };
        if port.is_null() {
            // SAFETY: never handed to a live tap.
            drop(unsafe { Box::from_raw(state) });
            return None;
        }
        // SAFETY: `port` is a valid mach port; the source is added to the main loop.
        unsafe {
            (*state).port = port;
            let source = CFMachPortCreateRunLoopSource(std::ptr::null(), port, 0);
            CFRunLoopAddSource(CFRunLoopGetMain(), source, kCFRunLoopCommonModes);
            CGEventTapEnable(port, true);
            Some(EventTap { port, source, state })
        }
    }

    /// Re-enables a tap macOS disabled after a slow callback.
    pub fn ensure_enabled(&self) {
        // SAFETY: `port` stays valid for the tap's lifetime.
        unsafe {
            if !CGEventTapIsEnabled(self.port) {
                tracing::warn!(target: "keyboard", "event tap was disabled; re-enabling");
                CGEventTapEnable(self.port, true);
            }
        }
    }
}

impl Drop for EventTap {
    fn drop(&mut self) {
        // SAFETY: tear down in reverse order of `install`.
        unsafe {
            CGEventTapEnable(self.port, false);
            CFRunLoopRemoveSource(CFRunLoopGetMain(), self.source, kCFRunLoopCommonModes);
            CFMachPortInvalidate(self.port);
            CFRelease(self.source.cast_const());
            CFRelease(self.port.cast_const());
            drop(Box::from_raw(self.state));
        }
    }
}

extern "C" fn tap_callback(_proxy: CGEventTapProxy, kind: u32, event: CGEventRef, user_info: *mut c_void) -> CGEventRef {
    // SAFETY: `user_info` is the `TapState` installed with this tap, and the
    // callback runs on the main run loop, never concurrently with itself.
    let state = unsafe { &mut *user_info.cast::<TapState>() };
    if kind == kCGEventTapDisabledByTimeout || kind == kCGEventTapDisabledByUserInput {
        // SAFETY: the port belongs to this tap.
        unsafe { CGEventTapEnable(state.port, true) };
        return event;
    }
    if !super::permissions::input_monitoring_granted() {
        return event;
    }
    // SAFETY: `event` is the live event passed to this callback.
    let flags = unsafe { CGEventGetFlags(event) };
    let phase = if kind == kCGEventLeftMouseDown || kind == kCGEventRightMouseDown || kind == kCGEventOtherMouseDown {
        Some(MousePhase::Down)
    } else if kind == kCGEventLeftMouseDragged {
        Some(MousePhase::Dragged)
    } else if kind == kCGEventLeftMouseUp {
        Some(MousePhase::Up)
    } else {
        None
    };
    if let Some(phase) = phase {
        // SAFETY: as above.
        let location = unsafe { CGEventGetLocation(event) };
        let mouse = MouseEvent { phase, x: location.x, y: location.y, modifiers: Modifiers::from_event_flags(flags) };
        let swallowed = (state.handler)(InputEvent::Mouse(mouse));
        return if swallowed { std::ptr::null_mut() } else { event };
    }
    // SAFETY: as above.
    let key_code = unsafe { CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode) };
    if kind == kCGEventFlagsChanged && key_code == FN_KEY_CODE {
        state.fn_pressed = flags & kCGEventFlagMaskSecondaryFn != 0;
    }
    let mut modifiers = Modifiers::from_event_flags(flags);
    if !state.fn_pressed {
        modifiers = modifiers.removing(ModifierKind::Fn);
    }
    let key_code = u16::try_from(key_code).unwrap_or(0);
    let (key, text) = if kind == kCGEventKeyDown {
        (key_for_code(key_code), event_text(event))
    } else {
        (None, None)
    };
    let swallowed = (state.handler)(InputEvent::Keyboard(KeyEvent { key, modifiers, text, is_key_down: kind == kCGEventKeyDown }));
    if swallowed { std::ptr::null_mut() } else { event }
}

fn event_text(event: CGEventRef) -> Option<String> {
    let mut buffer = [0u16; 8];
    let mut length = 0usize;
    // SAFETY: buffer/length describe a writable buffer of 8 UTF-16 units.
    unsafe { CGEventKeyboardGetUnicodeString(event, buffer.len(), &mut length, buffer.as_mut_ptr()) };
    (length > 0).then(|| String::from_utf16_lossy(&buffer[..length.min(buffer.len())]))
}

/// Character the active keyboard layout types for `key_code`, if printable.
fn layout_character(key_code: u16) -> Option<String> {
    // SAFETY: TIS returns a +1 input source we release; the layout data is a
    // CFData owned by that source and only read while it is alive.
    unsafe {
        let source = TISCopyCurrentKeyboardLayoutInputSource();
        let source = if source.is_null() { TISCopyCurrentASCIICapableKeyboardLayoutInputSource() } else { source };
        if source.is_null() {
            return None;
        }
        let data = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData);
        let result = if data.is_null() {
            None
        } else {
            let layout = CFDataGetBytePtr(data.cast()).cast::<c_void>();
            let mut dead = 0u32;
            let mut chars = [0u16; 4];
            let mut length = 0usize;
            const KEY_ACTION_DISPLAY: u16 = 3;
            const NO_DEAD_KEYS: u32 = 1;
            let status = UCKeyTranslate(
                layout,
                key_code,
                KEY_ACTION_DISPLAY,
                0,
                u32::from(LMGetKbdType()),
                NO_DEAD_KEYS,
                &mut dead,
                chars.len(),
                &mut length,
                chars.as_mut_ptr(),
            );
            (status == 0 && length > 0)
                .then(|| String::from_utf16_lossy(&chars[..length.min(chars.len())]))
                .filter(|text| text.chars().all(|c| !c.is_control()))
        };
        CFRelease(source.cast_const());
        result
    }
}

/// Layout-aware key lookup, falling back to the QWERTY position.
pub fn key_for_code(key_code: u16) -> Option<Key> {
    layout_character(key_code)
        .and_then(|character| Key::from_character(&character, key_code))
        .or_else(|| Key::from_qwerty_key_code(key_code))
}

/// Virtual key code that types `key` in the active layout.
pub fn code_for_key(key: Key) -> u16 {
    (0u16..128).find(|code| key_for_code(*code) == Some(key)).unwrap_or_else(|| key.qwerty_key_code())
}

fn post_key(source: CGEventSourceRef, code: u16, down: bool, flags: Option<u64>) {
    // SAFETY: the created event is posted then released.
    unsafe {
        let event = CGEventCreateKeyboardEvent(source, code, down);
        if event.is_null() {
            return;
        }
        if let Some(flags) = flags {
            CGEventSetFlags(event, flags);
        }
        CGEventPost(kCGHIDEventTap, event);
        CFRelease(event.cast_const());
    }
}

/// Posts ⌘V.
pub fn post_command_v() -> bool {
    // SAFETY: the source is released after posting.
    let source = unsafe { CGEventSourceCreate(kCGEventSourceStateCombinedSessionState) };
    if source.is_null() {
        return false;
    }
    let v = code_for_key(Key::V);
    post_key(source, 55, true, None);
    post_key(source, v, true, Some(kCGEventFlagMaskCommand));
    post_key(source, v, false, Some(kCGEventFlagMaskCommand));
    post_key(source, 55, false, None);
    // SAFETY: created above.
    unsafe { CFRelease(source.cast_const()) };
    true
}
