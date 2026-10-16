//! The menu bar item: a three-bar mark that animates while recording, and
//! a menu for updates, the last transcript, microphone choice, Settings and
//! Quit. Menu actions travel over a channel into the GPUI app.

use std::cell::RefCell;

use futures::channel::mpsc::{unbounded, UnboundedSender};
use futures::StreamExt;
use objc2::rc::Retained;
use objc2::runtime::{AnyObject, Sel};
use objc2::{define_class, msg_send, sel, AllocAnyThread, MainThreadMarker, MainThreadOnly};
use objc2_app_kit::{
    NSBitmapImageRep, NSEventModifierFlags, NSImage, NSMenu, NSMenuItem, NSStatusBar, NSStatusItem,
    NSVariableStatusItemLength,
};
use objc2_foundation::{NSObject, NSSize, NSString};

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum MenuCommand {
    CheckForUpdates,
    PasteLast,
    Microphone(Option<String>),
    OpenSettings,
    Quit,
}

thread_local! {
    static COMMANDS: RefCell<Vec<MenuCommand>> = const { RefCell::new(Vec::new()) };
    static SENDER: RefCell<Option<UnboundedSender<MenuCommand>>> = const { RefCell::new(None) };
}

define_class!(
    #[unsafe(super(NSObject))]
    #[thread_kind = MainThreadOnly]
    #[name = "TickMenuTarget"]
    struct MenuTarget;

    impl MenuTarget {
        #[unsafe(method(perform:))]
        fn perform(&self, sender: &NSMenuItem) {
            let tag = sender.tag();
            let command = COMMANDS.with(|commands| usize::try_from(tag).ok().and_then(|i| commands.borrow().get(i).cloned()));
            if let Some(command) = command {
                SENDER.with(|sender| {
                    if let Some(sender) = sender.borrow().as_ref() {
                        let _ = sender.unbounded_send(command);
                    }
                });
            }
        }
    }
);

impl MenuTarget {
    fn new(mtm: MainThreadMarker) -> Retained<Self> {
        // SAFETY: NSObject's init.
        unsafe { msg_send![Self::alloc(mtm), init] }
    }
}

/// Snapshot of what the menu shows.
#[derive(Debug, Clone, PartialEq)]
pub struct MenuModel {
    pub last_transcript: Option<String>,
    pub paste_shortcut: Option<(String, NSEventModifierFlags)>,
    pub microphones: Vec<(String, String)>,
    pub unavailable_bluetooth: Vec<String>,
    pub selected_microphone: Option<String>,
    pub default_microphone: Option<String>,
    pub can_check_updates: bool,
}

pub struct StatusItem {
    item: Retained<NSStatusItem>,
    target: Retained<MenuTarget>,
    model: Option<MenuModel>,
    recording_phase: Option<f32>,
}

impl gpui_kit::Global for StatusItem {}

impl StatusItem {
    /// Creates the item; commands arrive on the returned receiver.
    pub fn install(mtm: MainThreadMarker) -> (StatusItem, futures::channel::mpsc::UnboundedReceiver<MenuCommand>) {
        let (sender, receiver) = unbounded();
        SENDER.with(|slot| *slot.borrow_mut() = Some(sender));
        let item = NSStatusBar::systemStatusBar().statusItemWithLength(NSVariableStatusItemLength);
        let status = StatusItem { item, target: MenuTarget::new(mtm), model: None, recording_phase: None };
        status.set_icon(None);
        (status, receiver)
    }

    /// Redraws the mark; `Some(phase)` animates the recording bars.
    pub fn set_recording(&mut self, phase: Option<f32>) {
        if self.recording_phase != phase {
            self.recording_phase = phase;
            self.set_icon(phase);
        }
    }

    fn set_icon(&self, phase: Option<f32>) {
        let Some(mtm) = MainThreadMarker::new() else { return };
        if let Some(button) = self.item.button(mtm) {
            if let Some(image) = mark_image(phase) {
                button.setImage(Some(&image));
            }
        }
    }

    pub fn update_menu(&mut self, model: MenuModel) {
        if self.model.as_ref() == Some(&model) {
            return;
        }
        let Some(mtm) = MainThreadMarker::new() else { return };
        let mut commands = Vec::new();
        let menu = NSMenu::new(mtm);
        let add = |menu: &NSMenu, commands: &mut Vec<MenuCommand>, title: &str, key: &str, command: Option<MenuCommand>, checked: bool| {
            let selector: Option<Sel> = command.as_ref().map(|_| sel!(perform:));
            // SAFETY: standard NSMenuItem initializer.
            let item = unsafe {
                NSMenuItem::initWithTitle_action_keyEquivalent(NSMenuItem::alloc(mtm), &NSString::from_str(title), selector, &NSString::from_str(key))
            };
            if let Some(command) = command {
                item.setTag(commands.len() as isize);
                commands.push(command);
                // SAFETY: the target outlives the menu (owned by StatusItem).
                unsafe { item.setTarget(Some(&self.target as &AnyObject)) };
            } else {
                item.setEnabled(false);
            }
            if checked {
                item.setState(1);
            }
            menu.addItem(&item);
            item
        };

        add(&menu, &mut commands, "Check for Updates…", "", model.can_check_updates.then_some(MenuCommand::CheckForUpdates), false);
        let preview = model.last_transcript.as_deref().map(|text| {
            let trimmed = text.trim();
            let snippet: String = trimmed.chars().take(40).collect();
            if trimmed.chars().count() > 40 { format!("{snippet}…") } else { snippet }
        });
        let paste_title = match &preview {
            Some(preview) if !preview.is_empty() => format!("Paste Last Transcript ({preview})"),
            _ => "Paste Last Transcript".to_string(),
        };
        let (key, flags) = model.paste_shortcut.clone().unwrap_or((String::new(), NSEventModifierFlags::empty()));
        let paste = add(&menu, &mut commands, &paste_title, &key, model.last_transcript.as_ref().map(|_| MenuCommand::PasteLast), false);
        paste.setKeyEquivalentModifierMask(flags);

        let microphones = NSMenu::new(mtm);
        let default_title = match &model.default_microphone {
            Some(name) => format!("System Default ({name})"),
            None => "System Default".into(),
        };
        add(&microphones, &mut commands, &default_title, "", Some(MenuCommand::Microphone(None)), model.selected_microphone.is_none());
        if model.microphones.is_empty() {
            add(&microphones, &mut commands, "No microphones found", "", None, false);
        } else {
            microphones.addItem(&NSMenuItem::separatorItem(mtm));
            for (id, name) in &model.microphones {
                let selected = model.selected_microphone.as_deref() == Some(id.as_str());
                add(&microphones, &mut commands, name, "", Some(MenuCommand::Microphone(Some(id.clone()))), selected);
            }
        }
        if !model.unavailable_bluetooth.is_empty() {
            microphones.addItem(&NSMenuItem::separatorItem(mtm));
            for name in &model.unavailable_bluetooth {
                add(&microphones, &mut commands, &format!("{name} (mic profile unavailable)"), "", None, false);
            }
        }
        let microphone_item = add(&menu, &mut commands, "Microphone", "", None, false);
        microphone_item.setEnabled(true);
        microphone_item.setSubmenu(Some(&microphones));

        add(&menu, &mut commands, "Settings…", ",", Some(MenuCommand::OpenSettings), false);
        menu.addItem(&NSMenuItem::separatorItem(mtm));
        add(&menu, &mut commands, "Quit Tick", "q", Some(MenuCommand::Quit), false);

        COMMANDS.with(|slot| *slot.borrow_mut() = commands);
        self.item.setMenu(Some(&menu));
        self.model = Some(model);
    }
}

/// An 18 pt template image of three square bars (36 px for Retina).
fn mark_image(phase: Option<f32>) -> Option<Retained<NSImage>> {
    const PIXELS: usize = 36;
    let heights: [f32; 3] = match phase {
        None => [8.5, 15.0, 11.0],
        Some(phase) => [0.0, 0.7, 1.4].map(|offset| 4.0 + (0.5 + 0.5 * (phase + offset).sin()) * 10.0),
    };
    let mut rgba = vec![0u8; PIXELS * PIXELS * 4];
    for (index, height) in heights.iter().enumerate() {
        let x0 = ((2.5 + index as f32 * 5.0) * 2.0) as usize;
        let h = (height * 2.0) as usize;
        let y0 = (PIXELS - h) / 2;
        for y in y0..(y0 + h).min(PIXELS) {
            for x in x0..(x0 + 6).min(PIXELS) {
                let offset = (y * PIXELS + x) * 4;
                rgba[offset..offset + 4].copy_from_slice(&[0, 0, 0, 255]);
            }
        }
    }
    let color_space = NSString::from_str("NSDeviceRGBColorSpace");
    // SAFETY: a null plane array makes AppKit allocate the bitmap, which is
    // then filled through `bitmapData` before use.
    let rep = unsafe {
        NSBitmapImageRep::initWithBitmapDataPlanes_pixelsWide_pixelsHigh_bitsPerSample_samplesPerPixel_hasAlpha_isPlanar_colorSpaceName_bytesPerRow_bitsPerPixel(
            NSBitmapImageRep::alloc(),
            std::ptr::null_mut(),
            PIXELS as isize,
            PIXELS as isize,
            8,
            4,
            true,
            false,
            &color_space,
            (PIXELS * 4) as isize,
            32,
        )
    }?;
    // SAFETY: the rep owns a PIXELS×PIXELS×4 buffer.
    unsafe {
        let data = rep.bitmapData();
        if data.is_null() {
            return None;
        }
        std::ptr::copy_nonoverlapping(rgba.as_ptr(), data, rgba.len());
    }
    let image = NSImage::initWithSize(NSImage::alloc(), NSSize::new(18.0, 18.0));
    image.addRepresentation(&rep);
    image.setTemplate(true);
    Some(image)
}

/// Spawns the GPUI loop that executes menu commands.
pub fn run_commands(mut receiver: futures::channel::mpsc::UnboundedReceiver<MenuCommand>, cx: &mut gpui_kit::App) {
    cx.spawn(async move |cx| {
        while let Some(command) = receiver.next().await {
            let _ = cx.update(|cx| super::handle_menu_command(command, cx));
        }
    })
    .detach();
}
