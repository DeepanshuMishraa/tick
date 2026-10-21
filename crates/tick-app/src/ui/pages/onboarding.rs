//! First run: a welcome, then the two permissions Tick needs. Also shown
//! in repair mode when a permission is revoked after setup.

use std::time::Duration;

use gpui_kit::base::{h_flex, v_flex};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    Animation, AnimationExt as _, App, Context, FontWeight, IntoElement, ParentElement as _,
    SharedString, SpringAnimation, StatefulInteractiveElement as _, Styled as _, Window, div, px,
};

use crate::platform::permissions::PermissionStatus;
use crate::sound::Cue;
use crate::ui::components::{
    GLIDE, SNAP, Tone, button, cue, drawn_check, eyebrow, icon, muted, palette,
};
use crate::ui::icons::Icon;
use crate::ui::main_view::MainView;
use crate::ui::theme::{size, space};

pub fn render(
    view: &mut MainView,
    repair: bool,
    _: &mut Window,
    cx: &mut Context<MainView>,
) -> impl IntoElement {
    let p = palette(cx);
    let step = if repair { 1 } else { view.onboarding_step };
    let view_entity = cx.entity();
    v_flex()
        .size_full()
        .items_center()
        .justify_center()
        .gap(space::XXL)
        .px(px(64.))
        .child(if repair {
            h_flex()
                .gap(space::S)
                .items_center()
                .child(icon(Icon::Warning, px(14.), p.warning))
                .child(
                    div()
                        .text_size(size::CAPTION)
                        .text_color(p.warning)
                        .child("Permissions needed to resume dictation"),
                )
                .into_any_element()
        } else {
            h_flex()
                .gap(space::S)
                .children((0..2).map(|index| {
                    div()
                        .h(px(2.))
                        .bg(if index == step {
                            p.accent
                        } else {
                            p.line_strong
                        })
                        .with_spring(
                            SharedString::from(format!("step-{index}")),
                            SpringAnimation::new(SNAP).to(if index == step { 1.0f32 } else { 0.0 }),
                            |bar, t| bar.w(px(24.0 + 24.0 * t)),
                        )
                }))
                .into_any_element()
        })
        .child(if step == 0 {
            welcome(cx).into_any_element()
        } else {
            permissions(view, repair, cx).into_any_element()
        })
        .child(
            h_flex()
                .w_full()
                .max_w(px(760.))
                .justify_between()
                .child(if step == 1 && !repair {
                    let back = view_entity.clone();
                    button("onboarding-back", "Back", Tone::Ghost, cx)
                        .on_click(move |_, _, cx| {
                            cue(cx, Cue::Navigate);
                            back.update(cx, |view, cx| {
                                view.onboarding_step = 0;
                                cx.notify();
                            })
                        })
                        .into_any_element()
                } else {
                    div().into_any_element()
                })
                .child(if step == 0 {
                    let next = view_entity.clone();
                    button("onboarding-continue", "Continue", Tone::Primary, cx)
                        .on_click(move |_, _, cx| {
                            cue(cx, Cue::Navigate);
                            next.update(cx, |view, cx| {
                                view.onboarding_step = 1;
                                cx.notify();
                            })
                        })
                        .into_any_element()
                } else {
                    let state = view.state.clone();
                    button(
                        "onboarding-done",
                        if repair { "Done" } else { "Start using Tick" },
                        Tone::Primary,
                        cx,
                    )
                    .on_click(move |_, _, cx| {
                        state.update(cx, |state, cx| state.complete_onboarding(cx))
                    })
                    .into_any_element()
                }),
        )
}

fn showcase(
    index: usize,
    eyebrow_text: &str,
    heading: &str,
    text: &str,
    visual: impl IntoElement,
    cx: &App,
) -> impl IntoElement {
    let p = palette(cx);
    v_flex()
        .flex_1()
        .min_w_0()
        .gap(space::M)
        .p(space::L)
        .border_1()
        .border_color(p.line)
        .bg(p.surface)
        .with_spring(
            SharedString::from(format!("showcase-{index}")),
            SpringAnimation::new(GLIDE)
                .to(1.0f32)
                .from(-(index as f32) * 0.35),
            |card, t| {
                card.opacity(t.clamp(0.0, 1.0))
                    .mt(px(14.0 * (1.0 - t.clamp(0.0, 1.0))))
            },
        )
        .child(
            div()
                .h(px(76.))
                .flex()
                .items_center()
                .justify_center()
                .bg(p.ground)
                .border_1()
                .border_color(p.line)
                .child(visual),
        )
        .child(eyebrow(eyebrow_text.to_string(), cx))
        .child(
            div()
                .text_size(size::LEAD)
                .text_color(p.text)
                .child(heading.to_string()),
        )
        .child(muted(text.to_string(), cx))
}

fn welcome(cx: &App) -> impl IntoElement {
    let p = palette(cx);
    let hotkey = crate::state::AppState::global(cx)
        .read(cx)
        .settings
        .hotkey
        .label();
    // Keycap + live bars.
    let capture = h_flex()
        .gap(space::M)
        .items_center()
        .child(
            div()
                .px(space::S)
                .h(px(30.))
                .flex()
                .items_center()
                .border_1()
                .border_b_2()
                .border_color(p.line_strong)
                .text_size(size::LEAD)
                .child(hotkey),
        )
        .child(
            h_flex()
                .gap(px(2.))
                .items_center()
                .h(px(24.))
                .children((0..5).map(move |index| {
                    div().w(px(3.)).bg(p.accent).with_animation(
                        SharedString::from(format!("welcome-bar-{index}")),
                        Animation::new(Duration::from_millis(1400)).repeat(),
                        move |bar, t| {
                            bar.h(px(5.0
                                + 15.0
                                    * (0.5
                                        + 0.5
                                            * (t * std::f32::consts::TAU
                                                + index as f32 * 0.9)
                                                .sin())))
                        },
                    )
                })),
        );
    // A filler word struck through, then the clean result.
    let polish = v_flex()
        .gap(px(6.))
        .items_center()
        .child(
            div()
                .text_size(size::CAPTION)
                .text_color(p.muted)
                .relative()
                .child("um, let's ship…")
                .child(
                    div()
                        .absolute()
                        .top(px(8.))
                        .left_0()
                        .h(px(1.))
                        .bg(p.danger)
                        .with_animation(
                            "welcome-strike",
                            Animation::new(Duration::from_millis(2600)).repeat(),
                            |line, t| line.w(gpui_kit::relative((t * 2.5).min(1.0))),
                        ),
                ),
        )
        .child(
            h_flex()
                .gap(px(6.))
                .items_center()
                .child(drawn_check("welcome-check", true, px(12.), p.success))
                .child(
                    div()
                        .text_size(size::BODY)
                        .text_color(p.text)
                        .child("Let's ship."),
                ),
        );
    let private = h_flex()
        .gap(space::M)
        .items_center()
        .child(icon(Icon::Chip, px(26.), p.text))
        .child(
            v_flex().child(eyebrow("Apple silicon", cx)).child(
                div()
                    .text_size(size::CAPTION)
                    .text_color(p.text)
                    .child("0 KB to the cloud"),
            ),
        );
    v_flex()
        .w_full()
        .max_w(px(760.))
        .gap(space::XXL)
        .child(
            v_flex()
                .gap(space::S)
                .items_center()
                .child(
                    h_flex()
                        .gap(space::M)
                        .items_center()
                        .child(crate::ui::wordmark::mark(px(30.), p.text))
                        .child(
                            div()
                                .text_size(size::DISPLAY)
                                .font_weight(FontWeight::MEDIUM)
                                .child("Welcome to Tick."),
                        ),
                )
                .child(muted(
                    "Fast, private voice dictation for every app on your Mac.",
                    cx,
                )),
        )
        .child(
            h_flex()
                .gap(space::M)
                .items_stretch()
                .child(showcase(
                    0,
                    "Capture",
                    "Hold to talk",
                    "Hold the hotkey anywhere, speak, and let go to type.",
                    capture,
                    cx,
                ))
                .child(showcase(
                    1,
                    "Polish",
                    "Clean by default",
                    "Fillers vanish and punctuation lands where you meant it.",
                    polish,
                    cx,
                ))
                .child(showcase(
                    2,
                    "Privacy",
                    "On your Mac",
                    "Speech recognition runs locally. Nothing leaves unless you ask.",
                    private,
                    cx,
                )),
        )
}

fn permission_card(
    id: &'static str,
    glyph: Icon,
    eyebrow_text: &str,
    heading: &str,
    text: &str,
    status: PermissionStatus,
    action_label: &'static str,
    on_grant: impl Fn(&mut App) + 'static,
    cx: &App,
) -> impl IntoElement {
    let p = palette(cx);
    let granted = status.is_granted();
    h_flex()
        .gap(space::L)
        .p(space::L)
        .items_center()
        .border_1()
        .border_color(if granted { p.success } else { p.line })
        .bg(p.surface)
        .child(
            div()
                .size(px(40.))
                .flex()
                .flex_none()
                .items_center()
                .justify_center()
                .border_1()
                .border_color(p.line_strong)
                .child(icon(glyph, px(18.), p.text)),
        )
        .child(
            v_flex()
                .flex_1()
                .min_w_0()
                .gap(px(3.))
                .child(eyebrow(eyebrow_text.to_string(), cx))
                .child(div().text_size(size::LEAD).child(heading.to_string()))
                .child(muted(text.to_string(), cx)),
        )
        .child(if granted {
            h_flex()
                .gap(space::S)
                .items_center()
                .child(drawn_check(
                    SharedString::from(format!("{id}-granted")),
                    true,
                    px(18.),
                    p.success,
                ))
                .child(
                    div()
                        .text_size(size::CAPTION)
                        .text_color(p.success)
                        .child("Ready"),
                )
                .into_any_element()
        } else {
            button(id, action_label, Tone::Primary, cx)
                .on_click(move |_, _, cx| on_grant(cx))
                .into_any_element()
        })
}

fn permissions(view: &MainView, repair: bool, cx: &App) -> impl IntoElement {
    let state = view.state.clone();
    let permissions = state.read(cx).permissions;
    let (mic, keys) = (state.clone(), state.clone());
    let mic_label = if permissions.microphone == PermissionStatus::Denied {
        "Open Settings"
    } else {
        "Enable"
    };
    let keys_label = if permissions.accessibility.is_granted() {
        "Enable Input Monitoring"
    } else if permissions.accessibility == PermissionStatus::Denied {
        "Open Settings"
    } else {
        "Enable"
    };
    v_flex()
        .w_full()
        .max_w(px(760.))
        .gap(space::L)
        .child(
            v_flex()
                .gap(space::S)
                .child(
                    div()
                        .text_size(px(28.))
                        .font_weight(FontWeight::MEDIUM)
                        .child(if repair {
                            "Access was revoked."
                        } else {
                            "Two permissions."
                        }),
                )
                .child(muted(
                    if repair {
                        "Tick lost a permission it needs. Grant it again below to keep dictating."
                    } else {
                        "Tick needs to hear you and to type for you. Nothing else."
                    },
                    cx,
                )),
        )
        .child(permission_card(
            "grant-microphone",
            Icon::Mic,
            "Audio",
            "Microphone",
            "Records only while the hotkey is held.",
            permissions.microphone,
            mic_label,
            move |cx| mic.update(cx, |s, cx| s.request_microphone(cx)),
            cx,
        ))
        .child(permission_card(
            "grant-accessibility",
            Icon::Keyboard,
            "Input",
            "Accessibility & Input Monitoring",
            "Detects the hotkey and inserts text into the app you're using.",
            permissions.combined_hotkey_status(),
            keys_label,
            move |cx| keys.update(cx, |s, cx| s.request_hotkey_permissions(cx)),
            cx,
        ))
        .child(
            h_flex()
                .gap(space::S)
                .items_center()
                .child(icon(Icon::Lock, px(12.), palette(cx).muted))
                .child(muted("Everything stays on this Mac.", cx)),
        )
        .when(!permissions.all_granted(), |el| {
            el.child(muted("Grant both to continue.", cx))
        })
}
