//! Microphone, Accessibility, and Input Monitoring permission checks.

use std::sync::atomic::{AtomicBool, Ordering};

use block2::RcBlock;
use core_foundation::base::TCFType;
use core_foundation::boolean::CFBoolean;
use core_foundation::dictionary::CFDictionary;
use core_foundation::string::CFString;
use objc2::runtime::Bool;
use objc2_av_foundation::{AVAuthorizationStatus, AVCaptureDevice, AVMediaTypeAudio};

use super::sys::*;
use crate::native::{self, PermissionPane};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PermissionStatus {
    NotDetermined,
    Granted,
    Denied,
}

impl PermissionStatus {
    pub fn is_granted(self) -> bool {
        self == Self::Granted
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Permissions {
    pub microphone: PermissionStatus,
    pub accessibility: PermissionStatus,
    pub input_monitoring: PermissionStatus,
}

impl Permissions {
    pub fn all_granted(&self) -> bool {
        self.microphone.is_granted() && self.hotkeys_granted()
    }

    pub fn hotkeys_granted(&self) -> bool {
        self.accessibility.is_granted() && self.input_monitoring.is_granted()
    }

    /// Accessibility and Input Monitoring are granted as one step in the UI.
    pub fn combined_hotkey_status(&self) -> PermissionStatus {
        if self.hotkeys_granted() {
            PermissionStatus::Granted
        } else if self.accessibility == PermissionStatus::Denied || self.input_monitoring == PermissionStatus::Denied {
            PermissionStatus::Denied
        } else {
            PermissionStatus::NotDetermined
        }
    }
}

static INPUT_MONITORING: AtomicBool = AtomicBool::new(false);

/// Cached for the event-tap callback, refreshed by `current`.
pub fn input_monitoring_granted() -> bool {
    INPUT_MONITORING.load(Ordering::Relaxed)
}

pub fn accessibility_trusted() -> bool {
    let key = CFString::new("AXTrustedCheckOptionPrompt");
    let options = CFDictionary::from_CFType_pairs(&[(key, CFBoolean::false_value())]);
    // SAFETY: the dictionary lives across the call.
    unsafe { AXIsProcessTrustedWithOptions(options.as_concrete_TypeRef().cast()) }
}

fn input_monitoring() -> PermissionStatus {
    // SAFETY: plain query.
    match unsafe { IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) } {
        kIOHIDAccessTypeGranted => PermissionStatus::Granted,
        kIOHIDAccessTypeDenied => PermissionStatus::Denied,
        _ => PermissionStatus::NotDetermined,
    }
}

pub fn microphone() -> PermissionStatus {
    // SAFETY: AVMediaTypeAudio is a constant NSString.
    let status = unsafe { AVCaptureDevice::authorizationStatusForMediaType(AVMediaTypeAudio.expect("AVMediaTypeAudio is defined")) };
    match status {
        AVAuthorizationStatus::Authorized => PermissionStatus::Granted,
        AVAuthorizationStatus::NotDetermined => PermissionStatus::NotDetermined,
        _ => PermissionStatus::Denied,
    }
}

pub fn current() -> Permissions {
    let input_monitoring = input_monitoring();
    INPUT_MONITORING.store(input_monitoring.is_granted(), Ordering::Relaxed);
    Permissions {
        microphone: microphone(),
        accessibility: if accessibility_trusted() { PermissionStatus::Granted } else { PermissionStatus::Denied },
        input_monitoring,
    }
}

/// Shows the system microphone prompt; `done` runs on an arbitrary thread.
pub fn request_microphone(done: impl Fn(bool) + Send + 'static) {
    let block = RcBlock::new(move |granted: Bool| done(granted.as_bool()));
    // SAFETY: the block is retained by AVFoundation until it runs.
    unsafe {
        AVCaptureDevice::requestAccessForMediaType_completionHandler(
            AVMediaTypeAudio.expect("AVMediaTypeAudio is defined"),
            &block,
        )
    };
}

/// Raises the trust prompt and opens the drag-to-authorize panel.
pub fn request_accessibility() {
    native::open_permission_panel(PermissionPane::Accessibility);
}

pub fn request_input_monitoring() -> bool {
    // SAFETY: plain calls.
    let granted = unsafe { CGPreflightListenEventAccess() || CGRequestListenEventAccess() };
    if !granted {
        native::open_permission_panel(PermissionPane::InputMonitoring);
    }
    granted
}

pub fn open_microphone_settings() {
    super::workspace::open_url("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone");
}

pub fn dismiss_panels() {
    native::dismiss_permission_panel();
}
