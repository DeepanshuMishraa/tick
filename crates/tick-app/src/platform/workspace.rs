//! NSWorkspace, NSApplication, and Foundation conveniences.

use objc2::AnyThread;
use objc2::rc::Retained;
use objc2_app_kit::{
    NSApplication, NSApplicationActivationPolicy, NSBitmapImageFileType, NSBitmapImageRep,
    NSHapticFeedbackManager, NSHapticFeedbackPattern, NSHapticFeedbackPerformanceTime,
    NSHapticFeedbackPerformer, NSImage, NSRunningApplication, NSWorkspace,
};
use objc2_foundation::{
    MainThreadMarker, NSAppleScript, NSDictionary, NSPoint, NSRect, NSSize, NSString, NSURL,
};

pub fn open_url(url: &str) {
    let string = NSString::from_str(url);
    if let Some(url) = NSURL::URLWithString(&string) {
        NSWorkspace::sharedWorkspace().openURL(&url);
    }
}

/// Selects `path` in a Finder window.
pub fn reveal_in_finder(path: &std::path::Path) {
    let path = NSString::from_str(&path.to_string_lossy());
    NSWorkspace::sharedWorkspace()
        .selectFile_inFileViewerRootedAtPath(Some(&path), &NSString::from_str(""));
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FrontmostApp {
    pub bundle_id: String,
    pub name: String,
}

pub fn frontmost_app() -> Option<FrontmostApp> {
    let app = NSWorkspace::sharedWorkspace().frontmostApplication()?;
    Some(FrontmostApp {
        bundle_id: app.bundleIdentifier()?.to_string(),
        name: app.localizedName()?.to_string(),
    })
}

pub fn own_bundle_id() -> Option<String> {
    objc2_foundation::NSBundle::mainBundle()
        .bundleIdentifier()
        .map(|id| id.to_string())
}

/// Runs AppleScript, returning its string result.
pub fn run_apple_script(source: &str) -> Result<Option<String>, String> {
    let source = NSString::from_str(source);
    let Some(script) = NSAppleScript::initWithSource(NSAppleScript::alloc(), &source) else {
        return Err("AppleScript could not be compiled".into());
    };
    let mut error: Option<Retained<NSDictionary<NSString, objc2::runtime::AnyObject>>> = None;
    // SAFETY: `error` is a valid out-parameter for the duration of the call.
    let result = unsafe { script.executeAndReturnError(Some(&mut error)) };
    if let Some(error) = error {
        return Err(format!("{error:?}"));
    }
    Ok(result.stringValue().map(|s| s.to_string()))
}

/// PNG data of an app's icon at `size` points (2× pixels).
pub fn app_icon_png(bundle_id: &str, size: f64) -> Option<Vec<u8>> {
    let workspace = NSWorkspace::sharedWorkspace();
    let id = NSString::from_str(bundle_id);
    let image: Retained<NSImage> =
        NSRunningApplication::runningApplicationsWithBundleIdentifier(&id)
            .firstObject()
            .and_then(|app| app.icon())
            .or_else(|| {
                workspace
                    .URLForApplicationWithBundleIdentifier(&id)
                    .and_then(|url| url.path())
                    .map(|path| workspace.iconForFile(&path))
            })?;
    image_png(&image, size)
}

pub fn image_png(image: &NSImage, size: f64) -> Option<Vec<u8>> {
    // Rasterize only the one size needed. `TIFFRepresentation` encodes every
    // representation (up to 1024 px) and blocked the main thread for ~0.6 s on
    // each recording start with some app icons.
    let pixels = size * 2.0;
    let mut rect = NSRect::new(NSPoint::new(0.0, 0.0), NSSize::new(pixels, pixels));
    // SAFETY: `rect` is a valid in/out pointer for the duration of the call.
    let cg_image = unsafe { image.CGImageForProposedRect_context_hints(&mut rect, None, None) }?;
    let rep = NSBitmapImageRep::initWithCGImage(NSBitmapImageRep::alloc(), &cg_image);
    // SAFETY: an empty properties dictionary is valid.
    let png = unsafe {
        rep.representationUsingType_properties(NSBitmapImageFileType::PNG, &NSDictionary::new())
    }?;
    Some(png.to_vec())
}

/// The user's first name for greetings.
pub fn user_first_name() -> String {
    let full = objc2_foundation::NSFullUserName().to_string();
    let source = if full.trim().is_empty() {
        objc2_foundation::NSUserName().to_string()
    } else {
        full
    };
    source
        .split_whitespace()
        .next()
        .unwrap_or("there")
        .to_string()
}

/// Shows or hides the Dock icon.
pub fn set_dock_icon_visible(visible: bool) {
    let Some(mtm) = MainThreadMarker::new() else {
        return;
    };
    let policy = if visible {
        NSApplicationActivationPolicy::Regular
    } else {
        NSApplicationActivationPolicy::Accessory
    };
    NSApplication::sharedApplication(mtm).setActivationPolicy(policy);
}

pub fn activate_app() {
    let Some(mtm) = MainThreadMarker::new() else {
        return;
    };
    #[allow(deprecated)]
    NSApplication::sharedApplication(mtm).activateIgnoringOtherApps(true);
}

/// Whether the app was opened as a login item.
pub fn launched_at_login() -> bool {
    std::env::args().any(|arg| arg == "--login")
}

#[derive(Debug, Clone, Copy)]
pub enum Haptic {
    /// A crisp detent: recording armed, a toggle landing.
    Alignment,
    /// A softer tick: stop, selection change.
    Level,
}

/// Trackpad haptic; silently does nothing on hardware without Force Touch.
pub fn haptic(kind: Haptic) {
    let pattern = match kind {
        Haptic::Alignment => NSHapticFeedbackPattern::Alignment,
        Haptic::Level => NSHapticFeedbackPattern::LevelChange,
    };
    NSHapticFeedbackManager::defaultPerformer()
        .performFeedbackPattern_performanceTime(pattern, NSHapticFeedbackPerformanceTime::Now);
}

pub fn quit() {
    let Some(mtm) = MainThreadMarker::new() else {
        return;
    };
    NSApplication::sharedApplication(mtm).terminate(None);
}

/// Calls `callback` on the main thread whenever the Mac or its displays wake.
pub fn on_wake(callback: impl Fn() + 'static) {
    use objc2_app_kit::{NSWorkspaceDidWakeNotification, NSWorkspaceScreensDidWakeNotification};
    let center = NSWorkspace::sharedWorkspace().notificationCenter();
    let block = block2::RcBlock::new(
        move |_: std::ptr::NonNull<objc2_foundation::NSNotification>| callback(),
    );
    // SAFETY: the notification names are AppKit statics; the observer tokens
    // are leaked on purpose because the observation lasts for the app's life.
    for name in unsafe {
        [
            NSWorkspaceDidWakeNotification,
            NSWorkspaceScreensDidWakeNotification,
        ]
    } {
        let token = unsafe {
            center.addObserverForName_object_queue_usingBlock(Some(name), None, None, &block)
        };
        std::mem::forget(token);
    }
}

/// Forces the app's native appearance (window chrome, menus) to light or
/// dark, or lets it follow the system.
pub fn set_app_appearance(mode: tick_core::settings::AppearanceMode) {
    use objc2_app_kit::{NSAppearance, NSAppearanceNameAqua, NSAppearanceNameDarkAqua};
    use tick_core::settings::AppearanceMode;
    let Some(mtm) = MainThreadMarker::new() else {
        return;
    };
    // SAFETY: the appearance names are AppKit constants.
    let name = unsafe {
        match mode {
            AppearanceMode::System => None,
            AppearanceMode::Light => Some(NSAppearanceNameAqua),
            AppearanceMode::Dark => Some(NSAppearanceNameDarkAqua),
        }
    };
    let appearance = name.and_then(NSAppearance::appearanceNamed);
    NSApplication::sharedApplication(mtm).setAppearance(appearance.as_deref());
}
