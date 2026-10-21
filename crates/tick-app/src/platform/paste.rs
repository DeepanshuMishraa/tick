//! Delivering text into the focused field: Accessibility insertion first,
//! then a clipboard + ⌘V fallback that restores the user's clipboard.

use std::time::{Duration, Instant};

use core_foundation::base::{CFType, TCFType};
use core_foundation::string::CFString;
use objc2::rc::Retained;
use objc2_app_kit::{NSPasteboard, NSPasteboardItem, NSPasteboardTypePNG, NSPasteboardTypeString};
use objc2_foundation::{NSArray, NSData, NSString};

use super::sys::*;
use super::{keyboard, workspace};

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PasteResult {
    /// Inserted; `after` is the field value right after insertion when the
    /// editor exposes it (the dictionary-learning baseline).
    Pasted {
        before: Option<String>,
        after: Option<String>,
    },
    NoFocusedInput,
    Failed,
}

const GHOSTTY: &str = "com.mitchellh.ghostty";

struct AxElement(AXUIElementRef);

impl Drop for AxElement {
    fn drop(&mut self) {
        // SAFETY: owned +1 reference.
        unsafe { CFRelease(self.0.cast_const()) }
    }
}

fn focused_element() -> Option<AxElement> {
    // SAFETY: system-wide element is +1; the copied value is checked for type.
    unsafe {
        let system = AxElement(AXUIElementCreateSystemWide());
        let mut value: CFTypeRef = std::ptr::null();
        let attribute = CFString::new("AXFocusedUIElement");
        let error = AXUIElementCopyAttributeValue(
            system.0,
            attribute.as_concrete_TypeRef().cast(),
            &mut value,
        );
        if error != kAXErrorSuccess || value.is_null() {
            return None;
        }
        if CFGetTypeID(value) != AXUIElementGetTypeID() {
            CFRelease(value);
            return None;
        }
        Some(AxElement(value as AXUIElementRef))
    }
}

fn copy_attribute(element: &AxElement, name: &str) -> Option<CFType> {
    let attribute = CFString::new(name);
    let mut value: CFTypeRef = std::ptr::null();
    // SAFETY: `value` is a +1 reference on success, wrapped under the create rule.
    unsafe {
        (AXUIElementCopyAttributeValue(
            element.0,
            attribute.as_concrete_TypeRef().cast(),
            &mut value,
        ) == kAXErrorSuccess
            && !value.is_null())
        .then(|| CFType::wrap_under_create_rule(value))
    }
}

fn string_attribute(element: &AxElement, name: &str) -> Option<String> {
    copy_attribute(element, name)?
        .downcast::<CFString>()
        .map(|s| s.to_string())
}

fn set_attribute(element: &AxElement, name: &str, value: CFTypeRef) -> bool {
    let attribute = CFString::new(name);
    // SAFETY: `value` is a live CF object for the duration of the call.
    unsafe {
        AXUIElementSetAttributeValue(element.0, attribute.as_concrete_TypeRef().cast(), value)
            == kAXErrorSuccess
    }
}

fn selected_range(element: &AxElement) -> Option<CFRange> {
    let value = copy_attribute(element, "AXSelectedTextRange")?;
    // SAFETY: type-checked before reading an AXValue.
    unsafe {
        if CFGetTypeID(value.as_CFTypeRef()) != AXValueGetTypeID() {
            return None;
        }
        let mut range = CFRange::default();
        AXValueGetValue(
            value.as_CFTypeRef() as AXValueRef,
            kAXValueCFRangeType,
            (&mut range as *mut CFRange).cast(),
        )
        .then_some(range)
    }
}

/// The focused field's complete value; `None` when it exposes none.
pub fn focused_text() -> Option<String> {
    string_attribute(&focused_element()?, "AXValue")
}

pub fn focused_selected_text() -> Option<String> {
    string_attribute(&focused_element()?, "AXSelectedText")
}

pub fn focused_input_available() -> bool {
    focused_element().is_some_and(|element| {
        copy_attribute(&element, "AXValue").is_some()
            || copy_attribute(&element, "AXSelectedText").is_some()
    })
}

/// Replaces the selection through Accessibility and puts the caret after it.
fn insert_at_cursor(text: &str) -> bool {
    let Some(element) = focused_element() else {
        return false;
    };
    if let (Some(current), Some(range)) = (
        string_attribute(&element, "AXValue"),
        selected_range(&element),
    ) {
        let units: Vec<u16> = current.encode_utf16().collect();
        let start = usize::try_from(range.location).ok();
        let length = usize::try_from(range.length).ok();
        if let (Some(start), Some(length)) = (start, length) {
            if start + length <= units.len() {
                let mut updated: Vec<u16> = units[..start].to_vec();
                updated.extend(text.encode_utf16());
                updated.extend_from_slice(&units[start + length..]);
                let updated = CFString::new(&String::from_utf16_lossy(&updated));
                if set_attribute(&element, "AXValue", updated.as_CFTypeRef()) {
                    let caret = CFRange {
                        location: range.location + text.encode_utf16().count() as isize,
                        length: 0,
                    };
                    // SAFETY: AXValueCreate copies the range; released below.
                    unsafe {
                        let value =
                            AXValueCreate(kAXValueCFRangeType, (&caret as *const CFRange).cast());
                        if !value.is_null() {
                            set_attribute(&element, "AXSelectedTextRange", value.cast_const());
                            CFRelease(value.cast_const());
                        }
                    }
                    return true;
                }
            }
        }
    }
    // Some editors accept a selected-text write without a writable value.
    if copy_attribute(&element, "AXSelectedText").is_none() {
        return false;
    }
    let text = CFString::new(text);
    set_attribute(&element, "AXSelectedText", text.as_CFTypeRef())
}

/// A copy of every pasteboard item so a temporary paste can be undone.
struct Snapshot(Vec<Vec<(Retained<NSString>, Retained<NSData>)>>);

impl Snapshot {
    fn capture(pasteboard: &NSPasteboard) -> Snapshot {
        let items = pasteboard
            .pasteboardItems()
            .map(|items| items.to_vec())
            .unwrap_or_default();
        Snapshot(
            items
                .iter()
                .map(|item| {
                    item.types()
                        .iter()
                        .filter_map(|kind| item.dataForType(&kind).map(|data| (kind.clone(), data)))
                        .collect()
                })
                .collect(),
        )
    }

    fn restore(&self, pasteboard: &NSPasteboard) {
        pasteboard.clearContents();
        let items: Vec<Retained<NSPasteboardItem>> = self
            .0
            .iter()
            .map(|entries| {
                let item = NSPasteboardItem::new();
                for (kind, data) in entries {
                    item.setData_forType(data, kind);
                }
                item
            })
            .collect();
        if !items.is_empty() {
            let objects: Vec<
                &objc2::runtime::ProtocolObject<dyn objc2_app_kit::NSPasteboardWriting>,
            > = items
                .iter()
                .map(|item| objc2::runtime::ProtocolObject::from_ref(&**item))
                .collect();
            pasteboard.writeObjects(&NSArray::from_slice(&objects));
        }
    }
}

pub fn copy(text: &str) {
    let pasteboard = NSPasteboard::generalPasteboard();
    pasteboard.clearContents();
    // SAFETY: NSPasteboardTypeString is a constant.
    pasteboard.setString_forType(&NSString::from_str(text), unsafe { NSPasteboardTypeString });
}

/// Places text on the clipboard, posts ⌘V, then restores the clipboard
/// unless the user changed it in the meantime. Must run on the main thread;
/// `sleep` yields to the run loop between steps.
async fn paste_through_clipboard(
    text: &str,
    before: Option<String>,
    sleep: &dyn Fn(Duration) -> futures::future::BoxFuture<'static, ()>,
) -> PasteResult {
    let pasteboard = NSPasteboard::generalPasteboard();
    let snapshot = Snapshot::capture(&pasteboard);
    pasteboard.clearContents();
    // SAFETY: NSPasteboardTypeString is a constant.
    if !pasteboard.setString_forType(&NSString::from_str(text), unsafe { NSPasteboardTypeString }) {
        snapshot.restore(&pasteboard);
        return PasteResult::Failed;
    }
    let temporary = pasteboard.changeCount();
    // Let the pasteboard server commit before posting ⌘V.
    sleep(Duration::from_millis(20)).await;
    let posted = keyboard::post_command_v();
    // Web views, Electron, terminals and Ghostty read the pasteboard after
    // the event returns; keep the temporary item for that window.
    sleep(Duration::from_millis(180)).await;
    if pasteboard.changeCount() == temporary {
        snapshot.restore(&pasteboard);
    }
    if posted {
        PasteResult::Pasted {
            before,
            after: None,
        }
    } else {
        PasteResult::Failed
    }
}

/// Pastes a walkthrough into the frontmost app as two ⌘V presses: the
/// contact sheet, then the summary. Terminals get the sheet's path instead
/// of the image, which agent CLIs attach as an image. Restores the user's
/// clipboard afterwards unless they changed it.
pub async fn paste_walkthrough(
    sheet: &std::path::Path,
    summary: &str,
    sleep: &dyn Fn(Duration) -> futures::future::BoxFuture<'static, ()>,
) -> PasteResult {
    let frontmost = workspace::frontmost_app();
    let own = workspace::own_bundle_id();
    let target = frontmost
        .filter(|app| Some(&app.bundle_id) != own.as_ref() && app.bundle_id != "com.apple.finder");
    let Some(target) = target else {
        return PasteResult::NoFocusedInput;
    };
    let terminal = target.bundle_id == GHOSTTY
        || tick_core::app_context::AppCategory::from_bundle_id(&target.bundle_id)
            == tick_core::app_context::AppCategory::Terminal;
    let pasteboard = NSPasteboard::generalPasteboard();
    let snapshot = Snapshot::capture(&pasteboard);
    pasteboard.clearContents();
    let image = if terminal {
        None
    } else {
        std::fs::read(sheet).ok()
    };
    // SAFETY: the pasteboard type names are constants.
    let staged = match image {
        Some(bytes) => pasteboard.setData_forType(Some(&NSData::with_bytes(&bytes)), unsafe {
            NSPasteboardTypePNG
        }),
        None => pasteboard
            .setString_forType(&NSString::from_str(&sheet.to_string_lossy()), unsafe {
                NSPasteboardTypeString
            }),
    };
    if !staged {
        snapshot.restore(&pasteboard);
        return PasteResult::Failed;
    }
    sleep(Duration::from_millis(20)).await;
    let mut posted = keyboard::post_command_v();
    // The target reads the pasteboard after the event returns.
    sleep(Duration::from_millis(250)).await;
    pasteboard.clearContents();
    // SAFETY: as above.
    if !pasteboard.setString_forType(&NSString::from_str(summary), unsafe {
        NSPasteboardTypeString
    }) {
        snapshot.restore(&pasteboard);
        return PasteResult::Failed;
    }
    let temporary = pasteboard.changeCount();
    sleep(Duration::from_millis(20)).await;
    posted &= keyboard::post_command_v();
    sleep(Duration::from_millis(200)).await;
    if pasteboard.changeCount() == temporary {
        snapshot.restore(&pasteboard);
    }
    if posted {
        PasteResult::Pasted {
            before: None,
            after: None,
        }
    } else {
        PasteResult::Failed
    }
}

/// Inserts `text` into the focused field of the frontmost app.
pub async fn paste(
    text: &str,
    sleep: &dyn Fn(Duration) -> futures::future::BoxFuture<'static, ()>,
) -> PasteResult {
    let frontmost = workspace::frontmost_app();
    // A fresh process's first AX queries can fail transiently; poll briefly.
    let deadline = Instant::now() + Duration::from_millis(80);
    let mut focused = focused_input_available();
    while !focused && Instant::now() < deadline {
        sleep(Duration::from_millis(40)).await;
        focused = focused_input_available();
    }
    if !focused {
        // Chromium/Electron editors often hold focus without exposing it.
        let own = workspace::own_bundle_id();
        return match frontmost {
            Some(app)
                if Some(&app.bundle_id) != own.as_ref() && app.bundle_id != "com.apple.finder" =>
            {
                tracing::info!(target: "pasteboard", "no AX focus; blind clipboard paste into {}", app.bundle_id);
                paste_through_clipboard(text, None, sleep).await
            }
            _ => PasteResult::NoFocusedInput,
        };
    }
    let before = focused_text();
    if frontmost
        .as_ref()
        .is_some_and(|app| app.bundle_id == GHOSTTY)
    {
        return paste_through_clipboard(text, before, sleep).await;
    }
    if insert_at_cursor(text) {
        let after = focused_text();
        return PasteResult::Pasted { before, after };
    }
    paste_through_clipboard(text, before, sleep).await
}
