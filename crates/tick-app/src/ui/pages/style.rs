//! Style: how formal AI formatting should be. Shown first as a picker the
//! first time the tab opens.

use gpui_kit::base::{h_flex, v_flex};
use gpui_kit::{
    div, px, AnimationExt as _, App, Context, FontWeight, InteractiveElement as _, IntoElement, ParentElement as _,
    SharedString, SpringAnimation, StatefulInteractiveElement as _, Styled as _, Window,
};
use tick_core::settings::WritingStyle;

use crate::sound::Cue;
use crate::ui::components::{button, cue, drawn_check, eyebrow, icon, muted, palette, title, Tone, SNAP};
use crate::ui::icons::Icon;
use crate::ui::main_view::MainView;
use crate::ui::theme::{size, space};

fn copy(style: WritingStyle) -> (&'static str, &'static str, Icon, &'static str, &'static str) {
    match style {
        WritingStyle::Formal => (
            "Formal",
            "Caps + punctuation",
            Icon::Mail,
            "Email draft",
            "Hey, are you free for lunch tomorrow? Let's do 12 if that works for you.",
        ),
        WritingStyle::Casual => (
            "Casual",
            "Caps, no end period",
            Icon::Chat,
            "Alex · 12:04",
            "Hey, are you free for lunch tomorrow? Let's do 12 if that works for you",
        ),
        WritingStyle::VeryCasual => (
            "very casual",
            "No caps, light punctuation",
            Icon::Chat,
            "Message",
            "hey, are you free for lunch tomorrow? let's do 12 if that works for you",
        ),
    }
}

fn card(style: WritingStyle, selected: bool, cx: &App) -> impl IntoElement {
    let p = palette(cx);
    let (name, badge, glyph, context, sample) = copy(style);
    let state = crate::state::AppState::global(cx);
    v_flex()
        .id(SharedString::from(format!("style-{name}")))
        .flex_1().min_w_0()
        .gap(space::L)
        .p(space::L)
        .border_1()
        .border_color(if selected { p.accent } else { p.line })
        .bg(if selected { p.accent_soft } else { p.surface })
        .hover(move |s| s.border_color(if selected { p.accent } else { p.text }))
        .on_click(move |_, _, cx| {
            cue(cx, Cue::Select);
            state.update(cx, |state, cx| {
                state.update_settings(cx, |s| {
                    s.selected_style_index = style.index();
                    s.has_selected_style = true;
                })
            })
        })
        .child(
            h_flex()
                .justify_between()
                .items_start()
                .child(
                    v_flex()
                        .gap(px(4.))
                        .child(div().text_size(size::LEAD).font_weight(FontWeight::MEDIUM).text_color(p.text).child(name))
                        .child(eyebrow(badge, cx)),
                )
                .child(
                    div()
                        .size(px(18.))
                        .border_1()
                        .border_color(if selected { p.accent } else { p.line_strong })
                        .bg(if selected { p.accent } else { p.alpha(p.surface, 0.0) })
                        .child(drawn_check(SharedString::from(format!("style-check-{name}")), selected, px(16.), p.on_accent)),
                ),
        )
        .child(
            v_flex()
                .gap(space::S)
                .p(space::M)
                .bg(p.ground)
                .border_1()
                .border_color(p.line)
                .child(h_flex().gap(space::S).items_center().child(icon(glyph, px(12.), p.muted)).child(muted(context, cx)))
                .child(div().text_size(size::BODY).line_height(px(20.)).text_color(p.text).child(sample)),
        )
}

pub fn render(view: &mut MainView, _: &mut Window, cx: &mut Context<MainView>) -> impl IntoElement {
    let current = view.state.read(cx).settings.writing_style();
    v_flex()
        .gap(space::XL)
        .child(title("Style", cx))
        .child(muted(
            "How formal formatted text should read. Tick adjusts capitalization and punctuation to match; it applies when AI post-processing is on.",
            cx,
        ))
        .child(h_flex().gap(space::M).items_stretch().children(WritingStyle::ALL.map(|style| card(style, style == current, cx))))
}

/// First-visit picker shown over the window.
pub fn wizard(view: &MainView, cx: &Context<MainView>) -> impl IntoElement {
    let p = palette(cx);
    let current = view.state.read(cx).settings.writing_style();
    let close = view.state.clone();
    div()
        .absolute()
        .inset_0()
        .flex()
        .items_center()
        .justify_center()
        .bg(p.alpha(gpui_kit::black(), 0.45))
        .child(
            v_flex()
                .w_full().max_w(px(760.))
                .gap(space::XL)
                .p(space::XXL)
                .bg(p.surface)
                .border_1()
                .border_color(p.line_strong)
                .with_spring("wizard-in", SpringAnimation::new(SNAP).to(1.0f32).from(0.0f32), |el, t| {
                    el.opacity(t.clamp(0.0, 1.0)).mt(px(16.0 * (1.0 - t)))
                })
                .child(
                    v_flex()
                        .gap(space::S)
                        .child(eyebrow("Personalize", cx))
                        .child(title("How do you write in other apps?", cx))
                        .child(muted("Pick the voice Tick should format your dictation in. You can change it later in Style.", cx)),
                )
                .child(h_flex().gap(space::M).items_stretch().children(WritingStyle::ALL.map(|style| card(style, style == current, cx))))
                .child(h_flex().justify_end().child(button("wizard-done", "Done", Tone::Primary, cx).on_click(move |_, _, cx| {
                    cue(cx, Cue::Close);
                    close.update(cx, |state, cx| {
                        state.wizard_open = false;
                        cx.notify();
                    })
                }))),
        )
}
