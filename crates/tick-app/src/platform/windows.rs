//! Native window adjustments GPUI does not expose: overlay levels, mouse
//! pass-through, all-Spaces behavior, and frames in AppKit coordinates.

use objc2::rc::Retained;
use objc2::runtime::AnyObject;
use objc2::msg_send;
use objc2_app_kit::{NSView, NSWindow, NSWindowCollectionBehavior, NSWindowStyleMask};
use objc2_foundation::{NSPoint, NSRect, NSSize};
use raw_window_handle::{HasWindowHandle, RawWindowHandle};

#[link(name = "CoreGraphics", kind = "framework")]
unsafe extern "C" {
    fn CGShieldingWindowLevel() -> i32;
}

/// The NSWindow behind a GPUI window.
pub fn ns_window(window: &gpui_kit::Window) -> Option<Retained<NSWindow>> {
    let handle = HasWindowHandle::window_handle(window).ok()?;
    let RawWindowHandle::AppKit(appkit) = handle.as_raw() else { return None };
    // SAFETY: GPUI hands out its live NSView pointer for this window.
    let view: &NSView = unsafe { appkit.ns_view.cast::<NSView>().as_ref() };
    view.window()
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OverlayLevel {
    /// Above the menu bar, for the notch indicator.
    StatusBar,
    /// Above everything, for floating pills.
    Shielding,
}

/// Configures an overlay that never takes focus and follows every Space.
pub fn configure_overlay(window: &NSWindow, level: OverlayLevel, click_through: bool) {
    let level = match level {
        OverlayLevel::StatusBar => 25,
        // SAFETY: plain CoreGraphics query.
        OverlayLevel::Shielding => (unsafe { CGShieldingWindowLevel() }) as isize,
    };
    // GPUI opens pop-ups as titled panels: macOS rounds their corners and
    // keeps them below the menu bar. Overlays are borderless instead.
    window.setStyleMask(NSWindowStyleMask::Borderless | NSWindowStyleMask::NonactivatingPanel);
    window.setLevel(level);
    window.setIgnoresMouseEvents(click_through);
    window.setHasShadow(false);
    // GPUI pop-ups are NSPanels, which AppKit hides whenever Tick is not the
    // active app — i.e. exactly while the user dictates into another app.
    window.setHidesOnDeactivate(false);
    window.setCollectionBehavior(
        NSWindowCollectionBehavior::CanJoinAllSpaces
            | NSWindowCollectionBehavior::FullScreenAuxiliary
            | NSWindowCollectionBehavior::Stationary
            | NSWindowCollectionBehavior::IgnoresCycle,
    );
}

/// Moves the window to a frame given in AppKit screen coordinates.
pub fn set_frame(window: &NSWindow, x: f64, y: f64, width: f64, height: f64) {
    window.setFrame_display(NSRect::new(NSPoint::new(x, y), NSSize::new(width, height)), true);
}

pub fn show(window: &NSWindow) {
    window.orderFrontRegardless();
}

pub fn hide(window: &NSWindow) {
    // SAFETY: `orderOut:` accepts a nil sender.
    let _: () = unsafe { msg_send![window, orderOut: std::ptr::null::<AnyObject>()] };
}

pub fn is_visible(window: &NSWindow) -> bool {
    window.isVisible()
}
