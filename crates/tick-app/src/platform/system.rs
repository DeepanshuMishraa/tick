//! Power assertions, login item registration, and display geometry.

use core_foundation::base::TCFType;
use core_foundation::string::CFString;
use objc2_app_kit::NSScreen;
use objc2_foundation::MainThreadMarker;
use objc2_service_management::SMAppService;

use super::sys::{IOPMAssertionCreateWithName, IOPMAssertionRelease};

/// Keeps the display awake while held.
pub struct SleepAssertion(u32);

impl SleepAssertion {
    pub fn prevent(reason: &str) -> Option<SleepAssertion> {
        let kind = CFString::new("NoDisplaySleepAssertion");
        let reason = CFString::new(reason);
        let mut id = 0u32;
        const LEVEL_ON: u32 = 255;
        // SAFETY: CF strings outlive the call; `id` is a valid out-pointer.
        let status = unsafe {
            IOPMAssertionCreateWithName(
                kind.as_concrete_TypeRef().cast(),
                LEVEL_ON,
                reason.as_concrete_TypeRef().cast(),
                &mut id,
            )
        };
        (status == 0).then_some(SleepAssertion(id))
    }
}

impl Drop for SleepAssertion {
    fn drop(&mut self) {
        // SAFETY: releases the assertion created in `prevent`.
        unsafe { IOPMAssertionRelease(self.0) };
    }
}

/// Registers or unregisters the app as a login item.
pub fn set_open_on_login(enabled: bool) -> Result<(), String> {
    // SAFETY: SMAppService.mainApp is always available on macOS 13+.
    let service = unsafe { SMAppService::mainAppService() };
    // SAFETY: plain Objective-C calls.
    let result = unsafe {
        if enabled {
            service.registerAndReturnError()
        } else {
            service.unregisterAndReturnError()
        }
    };
    result.map_err(|error| error.localizedDescription().to_string())
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct ScreenGeometry {
    /// Screen frame in global AppKit coordinates (origin bottom-left).
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
    /// Width of the camera housing, or `None` on a screen without a notch.
    pub notch_width: Option<f64>,
    pub notch_height: f64,
    /// Bottom of the area above the Dock.
    pub visible_y: f64,
    /// Pixels per point.
    pub scale: f64,
    /// Height of the main display, which anchors both coordinate systems.
    pub main_height: f64,
}

impl ScreenGeometry {
    /// Top-left corner in global display coordinates, whose origin is the
    /// top-left of the main display (mouse events and ScreenCaptureKit).
    pub fn display_origin(&self) -> (f64, f64) {
        (self.x, self.main_height - (self.y + self.height))
    }
}

/// The screen under the mouse pointer, where the indicator appears.
pub fn active_screen() -> Option<ScreenGeometry> {
    let mtm = MainThreadMarker::new()?;
    let mouse = objc2_app_kit::NSEvent::mouseLocation();
    let screens = NSScreen::screens(mtm);
    let screen = screens
        .iter()
        .find(|screen| {
            let frame = screen.frame();
            mouse.x >= frame.origin.x
                && mouse.x <= frame.origin.x + frame.size.width
                && mouse.y >= frame.origin.y
                && mouse.y <= frame.origin.y + frame.size.height
        })
        .or_else(|| NSScreen::mainScreen(mtm))?;
    let frame = screen.frame();
    let main_height = screens
        .iter()
        .next()
        .map_or(frame.size.height, |main| main.frame().size.height);
    let (left, right) = (
        screen.auxiliaryTopLeftArea(),
        screen.auxiliaryTopRightArea(),
    );
    let notch = (left.size.width > 0.0 && right.size.width > 0.0).then(|| {
        let width = right.origin.x - (left.origin.x + left.size.width);
        let height = left.size.height.max(right.size.height).max(32.0);
        (width, height)
    });
    Some(ScreenGeometry {
        x: frame.origin.x,
        y: frame.origin.y,
        width: frame.size.width,
        height: frame.size.height,
        notch_width: notch.map(|(width, _)| width),
        notch_height: notch.map_or(32.0, |(_, height)| height),
        visible_y: screen.visibleFrame().origin.y,
        scale: screen.backingScaleFactor(),
        main_height,
    })
}
