//! Screen Recording permission and display screenshots through
//! ScreenCaptureKit, for walkthrough keyframes.

use image::RgbaImage;
use screencapturekit::prelude::*;
use screencapturekit::screenshot_manager::{CGImageExt, SCScreenshotManager};

use super::sys::{CGPreflightScreenCaptureAccess, CGRequestScreenCaptureAccess};

/// Widest keyframe kept, in pixels; Retina displays are captured below
/// their native resolution past this.
const MAX_WIDTH: f64 = 2560.0;

pub fn recording_granted() -> bool {
    // SAFETY: plain query.
    unsafe { CGPreflightScreenCaptureAccess() }
}

/// Shows the system prompt once, then opens the Screen Recording pane.
pub fn request_recording() {
    // SAFETY: plain call; macOS prompts only the first time.
    let granted = unsafe { CGRequestScreenCaptureAccess() };
    if !granted {
        super::workspace::open_url(
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
        );
    }
}

/// A display to capture, in global points with the origin at the top-left
/// of the main display (the coordinate space of mouse events).
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Display {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
    pub scale: f64,
}

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum CaptureError {
    #[error("ScreenCaptureKit could not list displays ({0}); Screen Recording may be off for Tick")]
    Content(String),
    #[error("the display being recorded was disconnected")]
    DisplayGone,
    #[error("the screenshot failed: {0}")]
    Screenshot(String),
}

/// Screenshots `display`. Tick's own windows are hidden from it, except
/// `keep_window` (the ink overlay, so drawings appear in keyframes).
/// Blocks for tens of milliseconds; call it off the main thread.
pub fn capture(display: &Display, keep_window: Option<u32>) -> Result<RgbaImage, CaptureError> {
    let content =
        SCShareableContent::get().map_err(|error| CaptureError::Content(format!("{error:?}")))?;
    let target = content
        .displays()
        .into_iter()
        .find(|candidate| {
            let frame = candidate.frame();
            (frame.origin.x - display.x).abs() < 1.0 && (frame.origin.y - display.y).abs() < 1.0
        })
        .ok_or(CaptureError::DisplayGone)?;
    let pid = std::process::id() as i32;
    let own: Vec<SCWindow> = content
        .windows()
        .into_iter()
        .filter(|window| {
            Some(window.window_id()) != keep_window
                && window
                    .owning_application()
                    .is_some_and(|app| app.process_id() == pid)
        })
        .collect();
    let excluded: Vec<&SCWindow> = own.iter().collect();
    let filter = SCContentFilter::create()
        .with_display(&target)
        .with_excluding_windows(&excluded)
        .build()
        .map_err(|error| CaptureError::Screenshot(format!("{error:?}")))?;
    let scale = display
        .scale
        .min(MAX_WIDTH / display.width.max(1.0))
        .max(0.5);
    let (width, height) = (
        (display.width * scale).round() as u32,
        (display.height * scale).round() as u32,
    );
    let config = SCStreamConfiguration::new()
        .with_width(width)
        .with_height(height)
        .with_shows_cursor(true);
    let image = SCScreenshotManager::capture_image(&filter, &config)
        .map_err(|error| CaptureError::Screenshot(format!("{error:?}")))?;
    let (width, height) = (image.width() as u32, image.height() as u32);
    let pixels = image
        .rgba_data()
        .map_err(|error| CaptureError::Screenshot(format!("{error:?}")))?;
    RgbaImage::from_raw(width, height, pixels).ok_or_else(|| {
        CaptureError::Screenshot(format!(
            "{width}×{height} image had the wrong number of bytes"
        ))
    })
}
