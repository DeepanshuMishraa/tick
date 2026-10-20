//! Settings, grouped by what the user is adjusting: permissions, model,
//! language, hotkey, microphone, sound, intelligence, general, history.

use std::rc::Rc;
use std::time::Duration;

use gpui_kit::base::{h_flex, v_flex};
use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::input::Input;
use gpui_kit::component::menu::{DropdownMenu as _, PopupMenuItem};
use gpui_kit::component::slider::Slider;
use gpui_kit::component::Sizable as _;
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    div, px, Animation, AnimationExt as _, AnyElement, App, Context, Entity, FontWeight, InteractiveElement as _,
    IntoElement, ParentElement as _, SharedString, StatefulInteractiveElement as _, Styled as _, Window,
};
use tick_core::hotkey::{ModifierKind, ModifierSide};
use tick_core::settings::{
    AiPostProcessingMode, AppearanceMode, GroqModel, OnDeviceAiModel, RecordingAudioBehavior, RecordingIndicatorStyle,
    RecordingRetention, ThemeColor,
};

use crate::hotkeys::CaptureTarget;
use crate::platform::permissions::PermissionStatus;
use crate::sound::Cue;
use crate::state::AppState;
use crate::ui::components::{
    body, button, cue, drawn_check, eyebrow, icon, keycap, muted, palette, progress_line, radio, rating, row, section,
    title, toggle, Tone,
};
use crate::ui::icons::Icon;
use crate::ui::main_view::MainView;
use crate::ui::theme::{size, space, swatch};
use crate::storage::format_bytes;

type Handler = Rc<dyn Fn(&mut App)>;

/// A dropdown showing the current option, with a check beside it.
fn picker(id: impl Into<SharedString>, current: impl Into<SharedString>, options: Vec<(SharedString, bool, Handler)>) -> impl IntoElement {
    let id: SharedString = id.into();
    Button::new(id)
        .outline()
        .small()
        .label(current.into())
        .dropdown_caret(true)
        .dropdown_menu(move |mut menu, _, _| {
            for (label, checked, handler) in &options {
                let handler = handler.clone();
                menu = menu.item(PopupMenuItem::new(label.clone()).checked(*checked).on_click(move |_, _, cx| {
                    cue(cx, Cue::Select);
                    handler(cx);
                }));
            }
            menu
        })
}

/// A toggle handler writing the new value into one setting.
fn set(state: &Entity<AppState>, edit: impl Fn(&mut tick_core::settings::Settings, bool) + 'static) -> impl Fn(bool, &mut Window, &mut App) + 'static {
    let state = state.clone();
    move |on, _, cx| state.update(cx, |state, cx| state.update_settings(cx, |s| edit(s, on)))
}

fn handler(state: &Entity<AppState>, edit: impl Fn(&mut AppState, &mut Context<AppState>) + 'static) -> Handler {
    let state = state.clone();
    Rc::new(move |cx: &mut App| state.update(cx, |state, cx| edit(state, cx)))
}

pub fn render(view: &mut MainView, window: &mut Window, cx: &mut Context<MainView>) -> impl IntoElement {
    let entity = view.state.clone();
    let state = view.state.read(cx);
    let permissions = state.permissions;
    let parakeet = state.settings.selected_parakeet().is_some();
    let show_microphone = permissions.microphone.is_granted() && !state.devices.devices.is_empty();
    let _ = window;
    v_flex()
        .gap(space::XXL)
        .child(title("Settings", cx))
        .when(!permissions.all_granted(), |page| page.child(permissions_section(&entity, cx)))
        .child(model_section(view, cx))
        .when(!parakeet, |page| page.child(language_section(&entity, cx)))
        .child(hotkey_section(view, cx))
        .when(show_microphone, |page| page.child(microphone_section(&entity, cx)))
        .child(audio_section(view, cx))
        .child(intelligence_section(view, cx))
        .child(general_section(&entity, cx))
        .child(history_section(view, cx))
        .child(updates_section(cx))
}

fn status_control(id: &'static str, status: PermissionStatus, on_grant: impl Fn(&mut App) + 'static, cx: &App) -> AnyElement {
    let p = palette(cx);
    if status.is_granted() {
        h_flex()
            .gap(space::S)
            .items_center()
            .child(drawn_check(id, true, px(16.), p.success))
            .child(div().text_size(size::CAPTION).text_color(p.success).child("Granted"))
            .into_any_element()
    } else {
        button(id, "Grant", Tone::Primary, cx).on_click(move |_, _, cx| on_grant(cx)).into_any_element()
    }
}

fn permissions_section(state: &Entity<AppState>, cx: &App) -> impl IntoElement {
    let permissions = state.read(cx).permissions;
    let (mic, keys) = (state.clone(), state.clone());
    section(
        "Permissions",
        vec![
            row(
                "Audio",
                "Microphone",
                Some("To hear you while the hotkey is held.".into()),
                status_control("grant-mic", permissions.microphone, move |cx| mic.update(cx, |s, cx| s.request_microphone(cx)), cx),
                cx,
            )
            .into_any_element(),
            row(
                "Input",
                "Accessibility & Input Monitoring",
                Some("To detect the hotkey and type into other apps.".into()),
                status_control("grant-keys", permissions.combined_hotkey_status(), move |cx| keys.update(cx, |s, cx| s.request_hotkey_permissions(cx)), cx),
                cx,
            )
            .into_any_element(),
        ],
        cx,
    )
}

fn model_section(view: &MainView, cx: &mut Context<MainView>) -> impl IntoElement {
    let p = palette(cx);
    let entity = view.state.clone();
    let state = view.state.read(cx);
    let selected = state.settings.selected_model.clone();
    let models = &state.models;
    let flash = state.flash_model_section;
    let any = models.any_downloaded();
    let entries: Vec<_> = models
        .curated
        .iter()
        .filter(|entry| models.show_all || entry.model.parakeet().is_some())
        .cloned()
        .collect();
    let hidden = models.curated.iter().filter(|e| e.model.parakeet().is_none()).count();
    let error = models.error.clone();
    let show_all = models.show_all;
    let downloading_any = models.is_downloading();

    v_flex()
        .gap(space::S)
        .child(eyebrow("Model", cx))
        .when(!any, |el| {
            el.child(
                h_flex()
                    .gap(space::M)
                    .p(space::M)
                    .border_1()
                    .border_color(p.warning)
                    .child(icon(Icon::Download, px(16.), p.warning))
                    .child(v_flex().child(body("Download a model to start dictating", cx)).child(muted("Pick one below. Parakeet is fast and accurate on Apple Silicon.", cx))),
            )
        })
        .when_some(error, |el, error| {
            el.child(h_flex().gap(space::S).items_center().child(icon(Icon::Warning, px(14.), p.danger)).child(div().text_size(size::CAPTION).text_color(p.danger).child(error)))
        })
        .child(
            v_flex()
                .border_1()
                .border_color(p.line)
                // Draws the eye after a dictation was attempted without a model.
                .with_spring(
                    "model-flash",
                    gpui_kit::SpringAnimation::new(crate::ui::components::SNAP).to(if flash { 1.0f32 } else { 0.0 }),
                    move |el, t| el.border_color(if t > 0.5 { p.accent } else { p.line }).border_l(px(1.0 + 3.0 * t.clamp(0.0, 1.0))),
                )
                .children(entries.into_iter().enumerate().map(|(index, entry)| {
                    let name = entry.model.internal_name.clone();
                    let is_selected = entry.model.is_selected(&selected);
                    let progress = view.state.read(cx).models.downloading(&name);
                    let (select, download, cancel, delete, reveal) = (entity.clone(), entity.clone(), entity.clone(), entity.clone(), entity.clone());
                    let (select_name, download_name, delete_name) = (name.clone(), name.clone(), name.clone());
                    let downloaded = entry.downloaded;
                    v_flex()
                        .id(SharedString::from(format!("model-{name}")))
                        .when(index > 0, |el| el.border_t_1().border_color(p.line))
                        .hover(move |s| s.bg(p.hover))
                        .on_click(move |_, _, cx| select.update(cx, |s, cx| s.select_model(&select_name, cx)))
                        .child(
                            h_flex()
                                .gap(space::M)
                                .px(space::L)
                                .py(space::M)
                                .items_center()
                                .child(radio(SharedString::from(format!("model-radio-{name}")), is_selected, cx))
                                .child(
                                    v_flex()
                                        .flex_1().min_w_0()
                                        .gap(px(4.))
                                        .child(
                                            h_flex()
                                                .gap(space::S)
                                                .items_center()
                                                .child(body(entry.model.display_name.clone(), cx))
                                                .when_some(entry.model.badge(), |el, badge| {
                                                    el.child(div().px(px(5.)).py(px(1.)).border_1().border_color(p.accent).text_size(size::EYEBROW).text_color(p.accent).child(badge.to_uppercase()))
                                                }),
                                        )
                                        .child(
                                            h_flex()
                                                .gap(space::L)
                                                .child(h_flex().gap(space::XS).items_center().child(rating(entry.model.accuracy_stars, cx)).child(muted("Accuracy", cx)))
                                                .child(h_flex().gap(space::XS).items_center().child(rating(entry.model.speed_stars, cx)).child(muted("Speed", cx)))
                                                .child(muted(entry.model.size.clone(), cx)),
                                        ),
                                )
                                .child(muted(entry.model.storage_size.clone(), cx))
                                .child(
                                    div().w(px(28.)).flex().justify_center().child(match (progress, downloaded) {
                                        (Some(_), _) => crate::ui::components::icon_button(SharedString::from(format!("model-cancel-{name}")), Icon::Close, p.muted, cx)
                                            .on_click(move |_, _, cx| cancel.update(cx, |s, cx| s.cancel_model_download(cx)))
                                            .into_any_element(),
                                        (None, true) => drawn_check(SharedString::from(format!("model-check-{name}")), true, px(16.), p.success).into_any_element(),
                                        (None, false) => crate::ui::components::icon_button(SharedString::from(format!("model-download-{name}")), Icon::Download, if downloading_any { p.faint } else { p.text }, cx)
                                            .when(!downloading_any, |el| el.on_click(move |_, _, cx| download.update(cx, |s, cx| s.download_model(&download_name, cx))))
                                            .into_any_element(),
                                    }),
                                )
                                .when(downloaded, |el| {
                                    el.child(
                                        Button::new(SharedString::from(format!("model-more-{name}")))
                                            .ghost()
                                            .small()
                                            .icon(gpui_kit::component::Icon::empty().path(Icon::More.path()))
                                            .dropdown_menu(move |menu, _, _| {
                                                let (reveal, delete, delete_name) = (reveal.clone(), delete.clone(), delete_name.clone());
                                                menu.item(PopupMenuItem::new("Show in Finder").on_click(move |_, _, cx| reveal.read(cx).reveal_models()))
                                                    .separator()
                                                    .item(PopupMenuItem::new("Delete").on_click(move |_, _, cx| delete.update(cx, |s, cx| s.delete_model(&delete_name, cx))))
                                            }),
                                    )
                                }),
                        )
                        .when_some(progress, |el, progress| {
                            el.child(div().px(space::L).pb(space::M).child(progress_line(SharedString::from(format!("model-progress-{name}")), progress, p.accent, cx)))
                        })
                })),
        )
        .when(hidden > 0, |el| {
            let toggle_entity = entity.clone();
            el.child(
                h_flex()
                    .id("models-more")
                    .gap(space::S)
                    .items_center()
                    .text_size(size::CAPTION)
                    .text_color(p.muted)
                    .hover(move |s| s.text_color(p.text))
                    .child(if show_all { "Fewer models" } else { "More models" })
                    .child(icon(if show_all { Icon::ChevronDown } else { Icon::ChevronRight }, px(12.), p.muted))
                    .on_click(move |_, _, cx| toggle_entity.update(cx, |s, cx| s.toggle_all_models(cx))),
            )
        })
}

fn language_section(state: &Entity<AppState>, cx: &App) -> impl IntoElement {
    let current = state.read(cx).settings.output_language.clone();
    let languages = state.read(cx).languages.clone();
    let label = languages
        .iter()
        .find(|l| l.code == current)
        .map_or_else(|| "Auto-detect".to_string(), |l| if l.code.is_none() { "Auto-detect".into() } else { l.name.clone() });
    let options = languages
        .into_iter()
        .map(|language| {
            let code = language.code.clone();
            let checked = code == current;
            let name = if code.is_none() { "Auto-detect".to_string() } else { language.name };
            (SharedString::from(name), checked, handler(state, move |s, cx| {
                let code = code.clone();
                s.update_settings(cx, |settings| settings.output_language = code);
            }))
        })
        .collect();
    section(
        "Language",
        vec![row("Output", "Language to transcribe into", None, picker("language", label, options), cx).into_any_element()],
        cx,
    )
}

fn hotkey_section(view: &MainView, cx: &mut Context<MainView>) -> impl IntoElement {
    let p = palette(cx);
    let entity = view.state.clone();
    let state = view.state.read(cx);
    let capturing = state.capture == Some(CaptureTarget::Recording);
    let hotkey = state.settings.hotkey.clone();
    let shown_modifiers = if capturing { state.capture_modifiers.clone() } else { hotkey.modifiers.clone() };
    let shown_key = if capturing { None } else { hotkey.key };
    let lock = state.settings.double_tap_lock_enabled;
    let double_only = state.settings.use_double_tap_only;
    let minimum = state.settings.minimum_key_time;
    let mut caps: Vec<AnyElement> = shown_modifiers.sorted().iter().map(|m| keycap(m.kind.symbol(), capturing, cx).into_any_element()).collect();
    if shown_modifiers.is_hyperkey() {
        caps.push(keycap("✦", capturing, cx).into_any_element());
    }
    if let Some(key) = shown_key {
        caps.push(keycap(key.label(), capturing, cx).into_any_element());
    }
    let capture_entity = entity.clone();
    let mut rows: Vec<AnyElement> = vec![
        v_flex()
            .py(space::L)
            .gap(space::M)
            .items_center()
            .child(
                h_flex()
                    .id("hotkey-capture")
                    .gap(space::S)
                    .min_h(px(34.))
                    .items_center()
                    .children(caps)
                    .when(capturing && shown_modifiers.is_empty(), |el| {
                        el.child(div().h(px(34.)).w(px(110.)).border_1().border_color(p.accent).with_animation(
                            "capture-pulse",
                            Animation::new(Duration::from_millis(1100)).repeat(),
                            move |el, t| el.border_color(p.alpha(p.accent, 0.3 + 0.7 * (t * std::f32::consts::PI).sin())),
                        ))
                    })
                    .on_click(move |_, _, cx| capture_entity.update(cx, |s, cx| s.begin_capture(CaptureTarget::Recording, cx))),
            )
            .child(muted(if capturing { "Press a key or modifiers · Esc cancels" } else { "Press and hold, or double-tap to lock. Click to change." }, cx))
            .into_any_element(),
    ];
    if !capturing && hotkey.key.is_none() && !hotkey.modifiers.is_empty() {
        let sides: Vec<AnyElement> = hotkey
            .modifiers
            .kinds()
            .into_iter()
            .filter(|kind| kind.supports_side_selection())
            .map(|kind| side_selector(&entity, kind, hotkey.modifiers.side(kind).unwrap_or_default(), cx).into_any_element())
            .collect();
        if !sides.is_empty() {
            rows.push(v_flex().py(space::M).gap(space::S).child(eyebrow("Modifier side", cx)).children(sides).into_any_element());
        }
    }
    rows.push(row("Behavior", "Double-tap to lock", Some("Tap twice to keep recording hands-free.".into()), toggle("double-tap-lock", lock, true, set(&entity, |s, on| s.double_tap_lock_enabled = on), cx), cx).into_any_element());
    if hotkey.key.is_some() {
        rows.push(row("Tapping", "Double-tap only", Some("Require a double-tap even for key combinations.".into()), toggle("double-tap-only", double_only, lock, set(&entity, |s, on| s.use_double_tap_only = on), cx), cx).into_any_element());
    } else {
        rows.push(
            v_flex()
                .py(space::M)
                .gap(space::S)
                .child(h_flex().justify_between().child(v_flex().gap(px(3.)).child(eyebrow("Minimum hold", cx)).child(body("Hold time before recording starts", cx))).child(div().text_size(size::BODY).font_weight(FontWeight::MEDIUM).child(format!("{minimum:.1}s"))))
                .child(Slider::new(&view.minimum_hold))
                .into_any_element(),
        );
    }
    rows.push(
        shortcut_row(
            &entity,
            CaptureTarget::Walkthrough,
            ("Walkthrough", "Record your screen while you talk, then paste it into an AI agent"),
            state.settings.walkthrough_hotkey.clone(),
            |settings| settings.walkthrough_hotkey = None,
            cx,
        )
        .into_any_element(),
    );
    section("Hotkey", rows, cx)
}

fn side_selector(state: &Entity<AppState>, kind: ModifierKind, current: ModifierSide, cx: &App) -> impl IntoElement {
    let p = palette(cx);
    h_flex()
        .gap(space::M)
        .items_center()
        .child(div().w(px(110.)).text_size(size::BODY).child(format!("{} {}", kind.symbol(), kind.display_name())))
        .child(h_flex().children(ModifierSide::ALL.map(|side| {
            let selected = side == current;
            let entity = state.clone();
            div()
                .id(SharedString::from(format!("side-{kind:?}-{side:?}")))
                .px(space::M)
                .py(px(5.))
                .border_1()
                .border_color(if selected { p.accent } else { p.line_strong })
                .bg(if selected { p.accent_soft } else { p.alpha(p.surface, 0.0) })
                .text_size(size::CAPTION)
                .text_color(if selected { p.text } else { p.muted })
                .hover(move |s| s.text_color(p.text))
                .child(side.display_name())
                .on_click(move |_, _, cx| {
                    cue(cx, Cue::Select);
                    entity.update(cx, |s, cx| s.update_settings(cx, |settings| settings.hotkey.modifiers = settings.hotkey.modifiers.setting(kind, side)))
                })
        })))
}

fn microphone_section(state: &Entity<AppState>, cx: &App) -> impl IntoElement {
    let p = palette(cx);
    let app = state.read(cx);
    let selected = app.settings.selected_microphone_id.clone();
    let devices = app.devices.clone();
    let default_label = devices.default_name.as_ref().map_or_else(|| "System default".to_string(), |n| format!("System default ({n})"));
    let current = match &selected {
        Some(id) => devices.devices.iter().find(|d| &d.id == id).map_or_else(|| "Disconnected device".to_string(), |d| d.name.clone()),
        None => default_label.clone(),
    };
    let mut options: Vec<(SharedString, bool, Handler)> = vec![(default_label.into(), selected.is_none(), handler(state, |s, cx| s.update_settings(cx, |x| x.selected_microphone_id = None)))];
    for device in &devices.devices {
        let id = device.id.clone();
        options.push((device.name.clone().into(), selected.as_ref() == Some(&device.id), handler(state, move |s, cx| {
            let id = id.clone();
            s.update_settings(cx, |x| x.selected_microphone_id = Some(id));
        })));
    }
    let missing = selected.as_ref().is_some_and(|id| !devices.devices.iter().any(|d| &d.id == id));
    let mut rows = vec![row("Input", "Microphone", Some("Overrides the system default while dictating.".into()), picker("microphone", current, options), cx).into_any_element()];
    if missing {
        rows.push(h_flex().py(space::M).gap(space::S).child(icon(Icon::Warning, px(14.), p.warning)).child(muted("The selected microphone isn't connected; the built-in microphone is used.", cx)).into_any_element());
    }
    if !devices.unavailable_bluetooth.is_empty() {
        let names = devices.unavailable_bluetooth.iter().map(|d| d.name.clone()).collect::<Vec<_>>().join(", ");
        rows.push(
            h_flex()
                .py(space::M)
                .gap(space::S)
                .items_start()
                .child(icon(Icon::Headphones, px(14.), p.muted))
                .child(muted(format!("{names}: macOS currently exposes only the headset's stereo output. Its microphone appears here automatically when the hands-free profile does."), cx))
                .into_any_element(),
        );
    }
    section("Microphone", rows, cx)
}

fn audio_section(view: &MainView, cx: &mut Context<MainView>) -> impl IntoElement {
    let entity = view.state.clone();
    let settings = &view.state.read(cx).settings;
    let enabled = settings.sound_effects_enabled;
    let percent = (settings.sound_effects_volume / tick_core::constants::BASE_SOUND_EFFECTS_VOLUME * 100.0).round();
    let mut rows = vec![row("Effects", "Interaction sounds", Some("Cues for recording, results, and the interface.".into()), toggle("sounds", enabled, true, set(&entity, |s, on| s.sound_effects_enabled = on), cx), cx).into_any_element()];
    if enabled {
        rows.push(
            v_flex()
                .py(space::M)
                .gap(space::S)
                .child(h_flex().justify_between().child(eyebrow("Volume", cx)).child(div().text_size(size::BODY).child(format!("{percent:.0}%"))))
                .child(Slider::new(&view.volume))
                .into_any_element(),
        );
    }
    section("Sound", rows, cx)
}

fn intelligence_section(view: &MainView, cx: &mut Context<MainView>) -> impl IntoElement {
    let p = palette(cx);
    let entity = view.state.clone();
    let state = view.state.read(cx);
    let on = state.settings.ai_post_processing_mode == AiPostProcessingMode::On;
    let groq_model = state.settings.selected_groq_model;
    let groq_key_set = !state.groq_key.trim().is_empty();
    let selected_model = state.settings.selected_ai_model;
    let ai = &state.ai;
    let (downloading, downloaded, progress, size, error, warming) = (ai.downloading, ai.downloaded, ai.progress, ai.size, ai.error.clone(), ai.warming);
    let toggle_entity = entity.clone();
    let mut rows = vec![row(
        "Intelligence",
        "AI post-processing",
        Some("Removes fillers, resolves self-corrections, and formats for the app you're in.".into()),
        toggle("ai", on, true, move |on, _, cx| {
            toggle_entity.update(cx, |s, cx| s.update_settings(cx, |x| x.ai_post_processing_mode = if on { AiPostProcessingMode::On } else { AiPostProcessingMode::Off }))
        }, cx),
        cx,
    )
    .into_any_element()];
    if on {
        let groq_options = GroqModel::ALL
            .iter()
            .map(|model| {
                let model = *model;
                (SharedString::from(model.display_name()), model == groq_model, handler(&entity, move |s, cx| s.update_settings(cx, |x| x.selected_groq_model = model)))
            })
            .collect();
        rows.push(row("Cloud", "Groq model (when a key is set)", Some("Reasoning is turned off for Qwen models.".into()), picker("groq-model", groq_model.display_name(), groq_options), cx).into_any_element());
        rows.push(
            v_flex()
                .py(space::M)
                .gap(space::S)
                .child(eyebrow("Groq API key", cx))
                .child(Input::new(&view.groq_key).mask_toggle())
                .child(muted("Stored in your keychain. With a key, Groq formats text within a 5-second budget; otherwise everything stays on this Mac.", cx))
                .into_any_element(),
        );
        rows.push(
            v_flex()
                .py(space::M)
                .gap(space::S)
                .child(eyebrow("On-device model", cx))
                .children(OnDeviceAiModel::ALL.map(|model| {
                    let is_selected = model == selected_model;
                    let (select, download, cancel, delete) = (entity.clone(), entity.clone(), entity.clone(), entity.clone());
                    v_flex()
                        .id(SharedString::from(format!("ai-{model:?}")))
                        .p(space::M)
                        .gap(space::S)
                        .border_1()
                        .border_color(if is_selected { p.accent } else { p.line })
                        .hover(move |s| s.border_color(if is_selected { p.accent } else { p.text }))
                        .on_click(move |_, _, cx| {
                            if !is_selected {
                                cue(cx, Cue::Select);
                                select.update(cx, |s, cx| s.update_settings(cx, |x| x.selected_ai_model = model));
                            }
                        })
                        .child(
                            h_flex()
                                .gap(space::M)
                                .items_start()
                                .child(radio(SharedString::from(format!("ai-radio-{model:?}")), is_selected, cx))
                                .child(v_flex().flex_1().min_w_0().gap(px(3.)).child(body(model.display_name(), cx)).child(muted(model.tagline(), cx)))
                                .child(muted(model.approximate_size(), cx)),
                        )
                        .when(is_selected, |el| {
                            el.child(if downloading {
                                v_flex()
                                    .gap(space::S)
                                    .child(progress_line("ai-progress", progress, p.accent, cx))
                                    .child(h_flex().justify_between().child(muted(format!("Downloading… {:.0}%", progress * 100.0), cx)).child(button("ai-cancel", "Cancel", Tone::Ghost, cx).on_click(move |_, _, cx| cancel.update(cx, |s, cx| s.cancel_ai_download(cx)))))
                                    .into_any_element()
                            } else if downloaded {
                                h_flex()
                                    .justify_between()
                                    .items_center()
                                    .child(h_flex().gap(space::S).items_center().child(drawn_check("ai-ready", true, px(14.), p.success)).child(muted(match (warming, size) {
                                        (true, _) => "Loading into memory…".to_string(),
                                        (false, Some(bytes)) => format!("Ready · {}", format_bytes(bytes)),
                                        (false, None) => "Ready".to_string(),
                                    }, cx)))
                                    .child(button("ai-delete", "Delete", Tone::Danger, cx).on_click(move |_, _, cx| delete.update(cx, |s, cx| s.delete_ai_model(cx))))
                                    .into_any_element()
                            } else {
                                h_flex()
                                    .justify_between()
                                    .items_center()
                                    .child(match &error {
                                        Some(error) => h_flex().gap(space::S).child(icon(Icon::Warning, px(13.), p.danger)).child(div().text_size(size::CAPTION).text_color(p.danger).child(error.clone())).into_any_element(),
                                        None => muted("Not downloaded", cx).into_any_element(),
                                    })
                                    .child(button("ai-download", if error.is_some() { "Retry download" } else { "Download" }, Tone::Primary, cx).on_click(move |_, _, cx| download.update(cx, |s, cx| s.download_ai_model(cx))))
                                    .into_any_element()
                            })
                        })
                }))
                .child(h_flex().pt(space::S).gap(space::S).items_center().child(icon(Icon::Shield, px(13.), p.muted)).child(muted(
                    if groq_key_set { "Groq receives transcript text. Audio never leaves your Mac." } else { "Formatting runs on your Mac. Nothing is sent anywhere." },
                    cx,
                )))
                .into_any_element(),
        );
    }
    section("Intelligence", rows, cx)
}

fn general_section(state: &Entity<AppState>, cx: &App) -> impl IntoElement {
    let p = palette(cx);
    let settings = state.read(cx).settings.clone();
    let swatches = h_flex().gap(space::S).children(ThemeColor::ALL.map(|color| {
        let selected = color == settings.theme_color;
        let entity = state.clone();
        let fill = swatch(color, p.dark);
        div()
            .id(SharedString::from(format!("swatch-{color:?}")))
            .size(px(22.))
            .p(px(3.))
            .border_1()
            .border_color(if selected { p.text } else { p.alpha(p.line, 0.0) })
            .hover(move |s| s.border_color(p.line_strong))
            .child(if color == ThemeColor::Multicolor {
                div().size_full().flex().flex_wrap().children([0x2F6BFF, 0xF2382C, 0x1FA35A, 0xE8B500].map(|c| div().size(px(7.)).bg(gpui_kit::rgb(c)))).into_any_element()
            } else {
                div().size_full().bg(fill).into_any_element()
            })
            .on_click(move |_, _, cx| {
                cue(cx, Cue::Select);
                entity.update(cx, |s, cx| s.update_settings(cx, |x| x.theme_color = color));
            })
    }));
    // Three square segments; the chosen one is filled.
    let appearance = h_flex().border_1().border_color(p.line_strong).children(AppearanceMode::ALL.map(|mode| {
        let selected = mode == settings.appearance_mode;
        let entity = state.clone();
        div()
            .id(SharedString::from(format!("appearance-{mode:?}")))
            .px(space::M)
            .py(px(5.))
            .text_size(size::CAPTION)
            .text_color(if selected { p.text } else { p.muted })
            .when(selected, |s| s.bg(p.hover))
            .when(!selected, |s| s.hover(move |s| s.text_color(p.text)))
            .child(mode.display_name())
            .on_click(move |_, _, cx| {
                cue(cx, Cue::Select);
                entity.update(cx, |s, cx| s.update_settings(cx, |x| x.appearance_mode = mode));
            })
    }));
    let behavior_options = RecordingAudioBehavior::ALL
        .iter()
        .map(|b| {
            let b = *b;
            (SharedString::from(b.display_name()), b == settings.recording_audio_behavior, handler(state, move |s, cx| s.update_settings(cx, |x| x.recording_audio_behavior = b)))
        })
        .collect();
    let indicator_options = RecordingIndicatorStyle::ALL
        .iter()
        .map(|style| {
            let style = *style;
            (SharedString::from(style.display_name()), style == settings.recording_indicator_style, handler(state, move |s, cx| s.update_settings(cx, |x| x.recording_indicator_style = style)))
        })
        .collect();
    section(
        "General",
        vec![
            row("Appearance", "Light, dark, or match macOS", None, appearance, cx).into_any_element(),
            row("Theme", "Accent color", Some(settings.theme_color.display_name().into()), swatches, cx).into_any_element(),
            row("Launch", "Open at login", None, toggle("login", settings.open_on_login, true, set(state, |s, on| s.open_on_login = on), cx), cx).into_any_element(),
            row("App", "Show in Dock", None, toggle("dock", settings.show_dock_icon, true, set(state, |s, on| s.show_dock_icon = on), cx), cx).into_any_element(),
            row("Power", "Keep the Mac awake while recording", None, toggle("sleep", settings.prevent_system_sleep, true, set(state, |s, on| s.prevent_system_sleep = on), cx), cx).into_any_element(),
            row("Performance", "Super Fast mode", Some("Keeps the microphone warm so recording starts instantly.".into()), toggle("super-fast", settings.super_fast_mode_enabled, true, set(state, |s, on| s.super_fast_mode_enabled = on), cx), cx).into_any_element(),
            row("While recording", "Other audio", Some("What happens to sound playing on the Mac.".into()), picker("audio-behavior", settings.recording_audio_behavior.display_name(), behavior_options), cx).into_any_element(),
            row("Indicator", "Where recording shows", Some("Only one indicator is visible at a time.".into()), picker("indicator", settings.recording_indicator_style.display_name(), indicator_options), cx).into_any_element(),
        ],
        cx,
    )
}

fn history_section(view: &MainView, cx: &mut Context<MainView>) -> impl IntoElement {
    let entity = view.state.clone();
    let view_entity = cx.entity();
    let state = view.state.read(cx);
    let settings = state.settings.clone();
    let count = state.history.history.len();
    let confirm = view.confirm_delete_all;
    let save_entity = entity.clone();
    let mut rows = vec![row(
        "Storage",
        "Save transcription history",
        Some("Keeps transcripts and their audio. Turning this off deletes saved history.".into()),
        toggle("save-history", settings.save_transcription_history, true, move |on, _, cx| save_entity.update(cx, |s, cx| s.set_save_history(on, cx)), cx),
        cx,
    )
    .into_any_element()];
    if settings.save_transcription_history {
        let entries = [0i64, 50, 100, 200, 500, 1000]
            .into_iter()
            .map(|n| {
                let value = (n > 0).then_some(n);
                (SharedString::from(if n == 0 { "Unlimited".to_string() } else { n.to_string() }), value == settings.max_history_entries, handler(&entity, move |s, cx| s.update_settings(cx, |x| x.max_history_entries = value)))
            })
            .collect();
        rows.push(row("Max entries", "Transcripts to keep", Some("The oldest are removed past the limit.".into()), picker("max-entries", settings.max_history_entries.map_or("Unlimited".into(), |n| n.to_string()), entries), cx).into_any_element());
        let retention = RecordingRetention::ALL
            .iter()
            .map(|r| {
                let r = *r;
                (SharedString::from(r.display_name()), r == settings.recording_retention, handler(&entity, move |s, cx| s.set_retention(r, cx)))
            })
            .collect();
        rows.push(row("Auto-delete", "Keep recordings for", Some("Transcripts are always kept; only audio is deleted.".into()), picker("retention", settings.recording_retention.display_name(), retention), cx).into_any_element());
        rows.push(
            shortcut_row(
                &entity,
                CaptureTarget::PasteLast,
                ("Paste last transcript", "Shortcut to paste your latest transcript"),
                settings.paste_last_transcript_hotkey.clone(),
                |settings| settings.paste_last_transcript_hotkey = None,
                cx,
            )
            .into_any_element(),
        );
        if count > 0 {
            let (ask, cancel, confirm_entity, delete) = (view_entity.clone(), view_entity.clone(), view_entity.clone(), entity.clone());
            rows.push(
                h_flex()
                    .py(space::M)
                    .gap(space::M)
                    .items_center()
                    .child(v_flex().flex_1().min_w_0().gap(px(3.)).child(eyebrow("Danger", cx)).child(body(format!("Delete all {count} transcripts and recordings"), cx)))
                    .child(if confirm {
                        h_flex()
                            .gap(space::S)
                            .child(button("delete-all-cancel", "Keep", Tone::Ghost, cx).on_click(move |_, _, cx| cancel.update(cx, |v, cx| {
                                v.confirm_delete_all = false;
                                cx.notify();
                            })))
                            .child(button("delete-all-confirm", "Delete everything", Tone::Danger, cx).on_click(move |_, _, cx| {
                                delete.update(cx, |s, cx| s.delete_all_transcripts(cx));
                                confirm_entity.update(cx, |v, cx| {
                                    v.confirm_delete_all = false;
                                    cx.notify();
                                })
                            }))
                            .into_any_element()
                    } else {
                        button("delete-all", "Delete all…", Tone::Danger, cx)
                            .on_click(move |_, _, cx| {
                                cue(cx, Cue::Warning);
                                ask.update(cx, |v, cx| {
                                    v.confirm_delete_all = true;
                                    cx.notify();
                                })
                            })
                            .into_any_element()
                    })
                    .into_any_element(),
            );
        }
    }
    section("History", rows, cx)
}

/// A clearable shortcut that needs at least one modifier and a key.
fn shortcut_row(
    state: &Entity<AppState>,
    target: CaptureTarget,
    (label, description): (&'static str, &'static str),
    shortcut: Option<tick_core::hotkey::HotKey>,
    clear_edit: fn(&mut tick_core::settings::Settings),
    cx: &App,
) -> impl IntoElement {
    let p = palette(cx);
    let app = state.read(cx);
    let capturing = app.capture == Some(target);
    let shown: Vec<AnyElement> = if capturing {
        app.capture_modifiers.sorted().iter().map(|m| keycap(m.kind.symbol(), true, cx).into_any_element()).collect()
    } else {
        shortcut.as_ref().map_or_else(Vec::new, |hk| {
            let mut caps: Vec<AnyElement> = hk.modifiers.sorted().iter().map(|m| keycap(m.kind.symbol(), false, cx).into_any_element()).collect();
            if let Some(key) = hk.key {
                caps.push(keycap(key.label(), false, cx).into_any_element());
            }
            caps
        })
    };
    let id = SharedString::from(format!("{target:?}-shortcut"));
    let (capture, clear) = (state.clone(), state.clone());
    h_flex()
        .py(space::M)
        .gap(space::L)
        .items_center()
        .child(v_flex().flex_1().min_w_0().gap(px(3.)).child(eyebrow(label, cx)).child(body(description, cx)).child(muted(if capturing { "Hold at least one modifier, then press a key · Esc cancels" } else { "Click the keys to change." }, cx)))
        .child(
            h_flex()
                .id(SharedString::from(format!("{id}-capture")))
                .gap(space::XS)
                .min_w(px(80.))
                .min_h(px(34.))
                .items_center()
                .justify_end()
                .when(shown.is_empty(), |el| el.child(div().px(space::M).h(px(34.)).flex().items_center().border_1().border_color(if capturing { p.accent } else { p.line_strong }).text_size(size::CAPTION).text_color(p.muted).child(if capturing { "Press keys" } else { "Not set" })))
                .children(shown)
                .on_click(move |_, _, cx| capture.update(cx, |s, cx| s.begin_capture(target, cx))),
        )
        .when(shortcut.is_some() && !capturing, |el| {
            el.child(crate::ui::components::icon_button(SharedString::from(format!("{id}-clear")), Icon::Close, p.muted, cx).on_click(move |_, _, cx| {
                cue(cx, Cue::Close);
                clear.update(cx, |s, cx| s.update_settings(cx, clear_edit))
            }))
        })
}

fn updates_section(cx: &App) -> impl IntoElement {
    section(
        "Updates",
        vec![row(
            "Version",
            format!("Tick {}", env!("CARGO_PKG_VERSION")),
            None,
            button("check-updates", "Check for updates", Tone::Secondary, cx).on_click(|_, _, cx| {
                cue(cx, Cue::Tap);
                crate::native::updater::check();
            }),
            cx,
        )
        .into_any_element()],
        cx,
    )
}
