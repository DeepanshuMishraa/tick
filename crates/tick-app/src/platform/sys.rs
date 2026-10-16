//! Raw declarations for the handful of C APIs not covered by the objc2
//! crates: event taps, Accessibility, TIS keyboard layouts, IOKit power and
//! HID access. Kept private to `platform`; callers use the safe wrappers.

#![allow(non_upper_case_globals, non_snake_case, clippy::upper_case_acronyms)]

use std::ffi::c_void;

pub type CFTypeRef = *const c_void;
pub type CFStringRef = *const c_void;
pub type CFDictionaryRef = *const c_void;
pub type CFMachPortRef = *mut c_void;
pub type CFRunLoopSourceRef = *mut c_void;
pub type CFRunLoopRef = *mut c_void;
pub type CGEventRef = *mut c_void;
pub type CGEventSourceRef = *mut c_void;
pub type CGEventTapProxy = *mut c_void;
pub type AXUIElementRef = *mut c_void;
pub type AXValueRef = *mut c_void;
pub type AXError = i32;
pub type TISInputSourceRef = *mut c_void;
pub type CFDataRef = *const c_void;

pub const kAXErrorSuccess: AXError = 0;
pub const kAXValueCFRangeType: u32 = 4;

pub type CGEventTapCallBack =
    extern "C" fn(proxy: CGEventTapProxy, kind: u32, event: CGEventRef, user_info: *mut c_void) -> CGEventRef;

pub const kCGHIDEventTap: u32 = 0;
pub const kCGHeadInsertEventTap: u32 = 0;
pub const kCGEventTapOptionDefault: u32 = 0;

pub const kCGEventLeftMouseDown: u32 = 1;
pub const kCGEventRightMouseDown: u32 = 3;
pub const kCGEventKeyDown: u32 = 10;
pub const kCGEventKeyUp: u32 = 11;
pub const kCGEventFlagsChanged: u32 = 12;
pub const kCGEventOtherMouseDown: u32 = 25;
pub const kCGEventTapDisabledByTimeout: u32 = 0xFFFF_FFFE;
pub const kCGEventTapDisabledByUserInput: u32 = 0xFFFF_FFFF;

pub const kCGKeyboardEventKeycode: u32 = 9;
pub const kCGEventSourceStateCombinedSessionState: i32 = 0;

pub const kCGEventFlagMaskCommand: u64 = 0x0010_0000;
pub const kCGEventFlagMaskSecondaryFn: u64 = 0x0080_0000;

pub const kIOHIDRequestTypeListenEvent: u32 = 1;
pub const kIOHIDAccessTypeGranted: u32 = 0;
pub const kIOHIDAccessTypeDenied: u32 = 1;

#[repr(C)]
#[derive(Debug, Clone, Copy, Default)]
pub struct CFRange {
    pub location: isize,
    pub length: isize,
}

#[link(name = "CoreFoundation", kind = "framework")]
unsafe extern "C" {
    pub fn CFMachPortCreateRunLoopSource(allocator: *const c_void, port: CFMachPortRef, order: isize) -> CFRunLoopSourceRef;
    pub fn CFMachPortInvalidate(port: CFMachPortRef);
    pub fn CFRunLoopGetMain() -> CFRunLoopRef;
    pub fn CFRunLoopAddSource(rl: CFRunLoopRef, source: CFRunLoopSourceRef, mode: CFStringRef);
    pub fn CFRunLoopRemoveSource(rl: CFRunLoopRef, source: CFRunLoopSourceRef, mode: CFStringRef);
    pub fn CFRelease(value: CFTypeRef);
    pub fn CFGetTypeID(value: CFTypeRef) -> usize;
    pub fn CFDataGetBytePtr(data: CFDataRef) -> *const u8;
    pub static kCFRunLoopCommonModes: CFStringRef;
}

#[link(name = "CoreGraphics", kind = "framework")]
unsafe extern "C" {
    pub fn CGEventTapCreate(
        tap: u32,
        place: u32,
        options: u32,
        events_of_interest: u64,
        callback: CGEventTapCallBack,
        user_info: *mut c_void,
    ) -> CFMachPortRef;
    pub fn CGEventTapEnable(tap: CFMachPortRef, enable: bool);
    pub fn CGEventTapIsEnabled(tap: CFMachPortRef) -> bool;
    pub fn CGEventGetIntegerValueField(event: CGEventRef, field: u32) -> i64;
    pub fn CGEventGetFlags(event: CGEventRef) -> u64;
    pub fn CGEventSetFlags(event: CGEventRef, flags: u64);
    pub fn CGEventKeyboardGetUnicodeString(
        event: CGEventRef,
        max_len: usize,
        actual_len: *mut usize,
        buffer: *mut u16,
    );
    pub fn CGEventSourceCreate(state: i32) -> CGEventSourceRef;
    pub fn CGEventCreateKeyboardEvent(source: CGEventSourceRef, key: u16, down: bool) -> CGEventRef;
    pub fn CGEventPost(tap: u32, event: CGEventRef);
    pub fn CGPreflightListenEventAccess() -> bool;
    pub fn CGRequestListenEventAccess() -> bool;
}

#[link(name = "ApplicationServices", kind = "framework")]
unsafe extern "C" {
    pub fn AXIsProcessTrustedWithOptions(options: CFDictionaryRef) -> bool;
    pub fn AXUIElementCreateSystemWide() -> AXUIElementRef;
    pub fn AXUIElementCopyAttributeValue(element: AXUIElementRef, attribute: CFStringRef, value: *mut CFTypeRef) -> AXError;
    pub fn AXUIElementSetAttributeValue(element: AXUIElementRef, attribute: CFStringRef, value: CFTypeRef) -> AXError;
    pub fn AXUIElementGetTypeID() -> usize;
    pub fn AXValueGetTypeID() -> usize;
    pub fn AXValueCreate(kind: u32, value: *const c_void) -> AXValueRef;
    pub fn AXValueGetValue(value: AXValueRef, kind: u32, out: *mut c_void) -> bool;
}

#[link(name = "Carbon", kind = "framework")]
unsafe extern "C" {
    pub fn TISCopyCurrentKeyboardLayoutInputSource() -> TISInputSourceRef;
    pub fn TISCopyCurrentASCIICapableKeyboardLayoutInputSource() -> TISInputSourceRef;
    pub fn TISGetInputSourceProperty(source: TISInputSourceRef, key: CFStringRef) -> *const c_void;
    pub fn LMGetKbdType() -> u8;
    pub fn UCKeyTranslate(
        layout: *const c_void,
        key_code: u16,
        action: u16,
        modifier_state: u32,
        keyboard_type: u32,
        options: u32,
        dead_key_state: *mut u32,
        max_len: usize,
        actual_len: *mut usize,
        chars: *mut u16,
    ) -> i32;
    pub static kTISPropertyUnicodeKeyLayoutData: CFStringRef;
}

#[link(name = "IOKit", kind = "framework")]
unsafe extern "C" {
    pub fn IOHIDCheckAccess(request: u32) -> u32;
    pub fn IOPMAssertionCreateWithName(kind: CFStringRef, level: u32, name: CFStringRef, id: *mut u32) -> i32;
    pub fn IOPMAssertionRelease(id: u32) -> i32;
}
