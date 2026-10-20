//! UI bootstrap: theme, menus, the main window, overlays, and the menu bar.

pub mod components;
pub mod icons;
mod ink;
pub mod main_view;
mod overlay;
mod pages;
mod status_item;
pub mod theme;
mod wordmark;

use std::time::Duration;

use gpui_kit::{
    actions, point, px, size, App, AppContext as _, Entity, Global, KeyBinding, Menu, MenuItem, TitlebarOptions,
    WindowBackgroundAppearance, WindowBounds, WindowKind, WindowOptions,
};
use objc2::MainThreadMarker;

use crate::platform::workspace;
use crate::state::AppState;
use main_view::MainView;
use status_item::{MenuCommand, MenuModel, StatusItem};

actions!(tick, [Quit, OpenSettings, CheckForUpdates, HideApp, ToggleSidebar]);

struct MainWindow(Option<gpui_kit::AnyWindowHandle>);

impl Global for MainWindow {}

pub fn start(state: &Entity<AppState>, cx: &mut App) {
    theme::register_fonts(cx);
    let (theme_color, appearance_mode) = { let s = &state.read(cx).settings; (s.theme_color, s.appearance_mode) };
    apply_theme(cx);
    cx.set_global(MainWindow(None));

    cx.bind_keys([
        KeyBinding::new("cmd-q", Quit, None),
        KeyBinding::new("cmd-,", OpenSettings, None),
        KeyBinding::new("cmd-h", HideApp, None),
        KeyBinding::new("cmd-b", ToggleSidebar, None),
    ]);
    cx.on_action(|_: &Quit, cx| quit(cx));
    cx.on_action(|_: &OpenSettings, cx| open_main_window(cx));
    cx.on_action(|_: &CheckForUpdates, _| crate::native::updater::check());
    cx.on_action(|_: &HideApp, cx| cx.hide());
    cx.on_action(|_: &ToggleSidebar, cx| AppState::global(cx).update(cx, |state, cx| state.toggle_sidebar(cx)));
    cx.set_menus([Menu {
        name: "Tick".into(),
        items: vec![
            MenuItem::action("Check for Updates…", CheckForUpdates),
            MenuItem::action("Settings…", OpenSettings),
            MenuItem::separator(),
            MenuItem::action("Hide Tick", HideApp),
            MenuItem::action("Quit Tick", Quit),
        ],
        disabled: false,
    }]);

    // Theme color and appearance follow settings and the system.
    let mut last = (theme_color, appearance_mode);
    cx.observe(state, move |state, cx| {
        let current = { let s = &state.read(cx).settings; (s.theme_color, s.appearance_mode) };
        if current != last {
            last = current;
            apply_theme(cx);
        }
    })
    .detach();

    overlay::Overlays::install(state, cx);
    install_status_item(state, cx);
    workspace::set_dock_icon_visible(state.read(cx).settings.show_dock_icon);

    let silent_launch = workspace::launched_at_login() && !state.read(cx).settings.show_dock_icon;
    if !silent_launch {
        open_main_window(cx);
    }
    let shutdown_state = state.clone();
    cx.on_app_quit(move |cx| {
        shutdown_state.update(cx, |state, _| state.shutdown());
        async {}
    })
    .detach();
}

/// Applies the appearance setting natively, then rebuilds the palette.
fn apply_theme(cx: &mut App) {
    let (color, mode) = { let s = &AppState::global(cx).read(cx).settings; (s.theme_color, s.appearance_mode) };
    workspace::set_app_appearance(mode);
    // Read after the override is set or cleared, so "System" sees macOS.
    theme::apply(cx.window_appearance(), mode, color, cx);
}

fn quit(cx: &mut App) {
    AppState::global(cx).update(cx, |state, _| state.shutdown());
    cx.quit();
}

pub fn open_main_window(cx: &mut App) {
    if let Some(handle) = cx.global::<MainWindow>().0 {
        if handle.update(cx, |_, window, _| window.activate_window()).is_ok() {
            cx.activate(true);
            return;
        }
    }
    let state = AppState::global(cx);
    let options = WindowOptions {
        window_bounds: Some(WindowBounds::centered(size(px(700.), px(560.)), cx)),
        titlebar: Some(TitlebarOptions { title: Some("Tick".into()), appears_transparent: true, traffic_light_position: Some(point(px(16.), px(18.))) }),
        focus: true,
        show: true,
        kind: WindowKind::Normal,
        is_movable: true,
        is_resizable: true,
        is_minimizable: true,
        window_background: WindowBackgroundAppearance::Opaque,
        window_min_size: Some(size(px(640.), px(520.))),
        ..WindowOptions::default()
    };
    let opened = gpui_kit::open_window(options, cx, move |window, cx| {
        window.observe_window_appearance(|_, cx| apply_theme(cx))
        .detach();
        cx.new(|cx| MainView::new(state, window, cx))
    });
    match opened {
        Ok((handle, _)) => {
            cx.global_mut::<MainWindow>().0 = Some(handle);
            cx.activate(true);
        }
        Err(error) => tracing::error!(target: "app", "could not open the main window: {error}"),
    }
}

fn menu_model(state: &AppState) -> MenuModel {
    let paste_shortcut = state.settings.paste_last_transcript_hotkey.as_ref().and_then(|hotkey| {
        use objc2_app_kit::NSEventModifierFlags as Flags;
        use tick_core::hotkey::ModifierKind;
        let key = hotkey.key?;
        let label = key.label().to_lowercase();
        (label.chars().count() == 1).then(|| {
            let mut flags = Flags::empty();
            for (kind, flag) in [
                (ModifierKind::Command, Flags::Command),
                (ModifierKind::Option, Flags::Option),
                (ModifierKind::Shift, Flags::Shift),
                (ModifierKind::Control, Flags::Control),
            ] {
                if hotkey.modifiers.contains_kind(kind) {
                    flags |= flag;
                }
            }
            (label, flags)
        })
    });
    MenuModel {
        last_transcript: state.history.history.first().map(|t| t.text.clone()),
        paste_shortcut,
        microphones: state.devices.devices.iter().map(|d| (d.id.clone(), d.name.clone())).collect(),
        unavailable_bluetooth: state.devices.unavailable_bluetooth.iter().map(|d| d.name.clone()).collect(),
        selected_microphone: state.settings.selected_microphone_id.clone(),
        default_microphone: state.devices.default_name.clone(),
        can_check_updates: crate::native::updater::can_check(),
    }
}

fn install_status_item(state: &Entity<AppState>, cx: &mut App) {
    let Some(mtm) = MainThreadMarker::new() else { return };
    let (mut item, receiver) = StatusItem::install(mtm);
    item.update_menu(menu_model(state.read(cx)));
    cx.set_global(item);
    status_item::run_commands(receiver, cx);
    cx.observe(state, |state, cx| {
        let model = menu_model(state.read(cx));
        cx.global_mut::<StatusItem>().update_menu(model);
    })
    .detach();
    // Animate the menu bar mark while recording; idle costs nothing.
    let state = state.clone();
    cx.spawn(async move |cx| {
        let mut phase = 0.0f32;
        loop {
            cx.background_executor().timer(Duration::from_millis(150)).await;
            let recording = cx
                .update(|cx| state.read(cx).phase.recording_since().is_some());
            if recording {
                phase = (phase + 0.35) % std::f32::consts::TAU;
            }
            let _ = cx.update(|cx| cx.global_mut::<StatusItem>().set_recording(recording.then_some(phase)));
        }
    })
    .detach();
}

pub(crate) fn handle_menu_command(command: MenuCommand, cx: &mut App) {
    let state = AppState::global(cx);
    match command {
        MenuCommand::CheckForUpdates => crate::native::updater::check(),
        MenuCommand::PasteLast => state.update(cx, |state, cx| state.paste_last_transcript(cx)),
        MenuCommand::Microphone(id) => state.update(cx, |state, cx| state.update_settings(cx, |s| s.selected_microphone_id = id)),
        MenuCommand::OpenSettings => {
            open_main_window(cx);
            state.update(cx, |state, cx| state.set_tab(crate::state::Tab::Settings, cx));
        }
        MenuCommand::Quit => quit(cx),
    }
}
