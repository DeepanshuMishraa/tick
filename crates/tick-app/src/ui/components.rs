//! Square controls and small vector visuals shared by every screen.
//!
//! Motion is spring-based and short; every animated value is keyed by a
//! stable element id so interruptions continue from the current position.

use gpui_kit::base::{h_flex, v_flex};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    AnimationExt as _, App, Div, ElementId, FontWeight, Hsla, InteractiveElement as _, IntoElement,
    ParentElement as _, PathBuilder, Pixels, SharedString, SpringAnimation, SpringConfig,
    StatefulInteractiveElement as _, Styled as _, Window, canvas, div, point, px, svg,
};

use super::icons::Icon;
use super::theme::{Palette, size, space};
use crate::sound::Cue;
use crate::state::AppState;

/// Snappy, barely-overshooting spring for state changes.
pub const SNAP: SpringConfig = SpringConfig::new(520.0, 38.0, 1.0);
/// Softer spring for layout-scale movement.
pub const GLIDE: SpringConfig = SpringConfig::new(240.0, 28.0, 1.0);

pub fn palette(cx: &App) -> Palette {
    *cx.global::<Palette>()
}

pub fn cue(cx: &App, cue: Cue) {
    AppState::global(cx).read(cx).play_sound(cue);
}

pub fn icon(icon: Icon, size: impl Into<Pixels>, color: Hsla) -> impl IntoElement {
    let size = size.into();
    svg()
        .path(icon.path())
        .size(size)
        .flex_none()
        .text_color(color)
}

pub fn eyebrow(text: impl Into<SharedString>, cx: &App) -> Div {
    div()
        .text_size(size::EYEBROW)
        .text_color(palette(cx).muted)
        .child(text.into().to_uppercase())
}

pub fn title(text: impl Into<SharedString>, cx: &App) -> Div {
    div()
        .text_size(size::TITLE)
        .font_weight(FontWeight::MEDIUM)
        .text_color(palette(cx).text)
        .child(text.into())
}

pub fn body(text: impl Into<SharedString>, cx: &App) -> Div {
    div()
        .text_size(size::BODY)
        .text_color(palette(cx).text)
        .child(text.into())
}

pub fn muted(text: impl Into<SharedString>, cx: &App) -> Div {
    div()
        .text_size(size::CAPTION)
        .text_color(palette(cx).muted)
        .child(text.into())
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Tone {
    Primary,
    Secondary,
    Ghost,
    Danger,
}

/// A square button: label, optional leading icon, four tones.
pub fn button(
    id: impl Into<ElementId>,
    label: impl Into<SharedString>,
    tone: Tone,
    cx: &App,
) -> gpui_kit::Stateful<Div> {
    let p = palette(cx);
    let (bg, fg, border, hover_bg, hover_border) = match tone {
        Tone::Primary => (
            p.accent,
            p.on_accent,
            p.accent,
            p.alpha(p.accent, 0.88),
            p.alpha(p.accent, 0.88),
        ),
        Tone::Secondary => (p.surface, p.text, p.line_strong, p.hover, p.text),
        Tone::Ghost => (
            p.alpha(p.surface, 0.0),
            p.text,
            p.alpha(p.line, 0.0),
            p.hover,
            p.alpha(p.line, 0.0),
        ),
        Tone::Danger => (
            p.surface,
            p.danger,
            p.line_strong,
            p.alpha(p.danger, 0.08),
            p.danger,
        ),
    };
    let active = if tone == Tone::Primary {
        p.alpha(p.accent, 0.75)
    } else {
        p.line
    };
    h_flex()
        .id(id.into())
        .flex_none()
        .gap(space::S)
        .h(px(30.))
        .px(space::M)
        .items_center()
        .justify_center()
        .bg(bg)
        .border_1()
        .border_color(border)
        .text_size(size::BODY)
        .text_color(fg)
        .whitespace_nowrap()
        .hover(move |s| s.bg(hover_bg).border_color(hover_border))
        .active(move |s| s.bg(active))
        .child(label.into())
}

pub fn icon_button(
    id: impl Into<ElementId>,
    glyph: Icon,
    color: Hsla,
    cx: &App,
) -> gpui_kit::Stateful<Div> {
    let p = palette(cx);
    div()
        .id(id.into())
        .flex_none()
        .size(px(28.))
        .flex()
        .items_center()
        .justify_center()
        .hover(move |s| s.bg(p.hover))
        .active(move |s| s.bg(p.line))
        .child(icon(glyph, px(15.), color))
}

/// Square switch: a block that springs across its track.
pub fn toggle(
    id: impl Into<ElementId>,
    on: bool,
    enabled: bool,
    on_change: impl Fn(bool, &mut Window, &mut App) + 'static,
    cx: &App,
) -> impl IntoElement {
    let p = palette(cx);
    let id: ElementId = id.into();
    let track = if on {
        p.accent
    } else {
        p.alpha(p.line_strong, 0.0)
    };
    let knob = if on { p.on_accent } else { p.muted };
    div()
        .id(id.clone())
        .flex_none()
        .w(px(36.))
        .h(px(20.))
        .p(px(3.))
        .border_1()
        .border_color(if on { p.accent } else { p.line_strong })
        .bg(track)
        .when(!enabled, |s| s.opacity(0.4))
        .when(enabled, |s| {
            s.on_click(move |_, window, cx| {
                on_change(!on, window, cx);
                cue(cx, Cue::Toggle);
                crate::platform::workspace::haptic(crate::platform::workspace::Haptic::Alignment);
            })
        })
        .child(div().size(px(12.)).bg(knob).with_spring(
            ElementId::NamedChild(std::sync::Arc::new(id), "knob".into()),
            SpringAnimation::new(SNAP).to(if on { 1.0f32 } else { 0.0 }),
            |knob, t| knob.ml(px(16. * t)),
        ))
}

/// Square radio mark; the inner block springs in.
pub fn radio(id: impl Into<ElementId>, selected: bool, cx: &App) -> impl IntoElement {
    let p = palette(cx);
    div()
        .flex_none()
        .size(px(14.))
        .border_1()
        .border_color(if selected { p.accent } else { p.line_strong })
        .flex()
        .items_center()
        .justify_center()
        .child(div().bg(p.accent).with_spring(
            id.into(),
            SpringAnimation::new(SNAP).to(if selected { 1.0f32 } else { 0.0 }),
            |inner, t| inner.size(px(6. * t)),
        ))
}

/// A two-pixel line that springs to `fraction` of its track.
pub fn progress_line(
    id: impl Into<ElementId>,
    fraction: f64,
    color: Hsla,
    cx: &App,
) -> impl IntoElement {
    let p = palette(cx);
    div()
        .w_full()
        .h(px(2.))
        .bg(p.line)
        .child(div().h_full().bg(color).with_spring(
            id.into(),
            SpringAnimation::new(GLIDE).to(fraction.clamp(0.0, 1.0) as f32),
            |bar, t| bar.w(gpui_kit::relative(t)),
        ))
}

/// Five small squares, `filled` of them solid.
pub fn rating(filled: u8, cx: &App) -> impl IntoElement {
    let p = palette(cx);
    h_flex().gap(px(2.)).children((0..5).map(move |index| {
        div().size(px(5.)).bg(if index < filled {
            p.text
        } else {
            p.line_strong
        })
    }))
}

/// A keycap chip for hotkey labels.
pub fn keycap(label: impl Into<SharedString>, active: bool, cx: &App) -> impl IntoElement {
    let p = palette(cx);
    div()
        .flex_none()
        .min_w(px(34.))
        .h(px(34.))
        .px(space::S)
        .flex()
        .items_center()
        .justify_center()
        .border_1()
        .border_color(if active { p.accent } else { p.line_strong })
        .border_b_2()
        .bg(p.surface)
        .text_size(size::LEAD)
        .text_color(p.text)
        .child(label.into())
}

/// A checkmark whose stroke draws itself in when `visible` turns on.
pub fn drawn_check(
    id: impl Into<ElementId>,
    visible: bool,
    side: Pixels,
    color: Hsla,
) -> impl IntoElement {
    div().size(side).flex_none().with_spring(
        id.into(),
        SpringAnimation::new(GLIDE).to(if visible { 1.0f32 } else { 0.0 }),
        move |el, t| {
            el.child(
                canvas(
                    |_, _, _| {},
                    move |bounds, _, window, _| {
                        let t = t.clamp(0.0, 1.0);
                        if t <= 0.01 {
                            return;
                        }
                        let s = bounds.size.width.as_f32();
                        let o = bounds.origin;
                        let a: (f32, f32) = (0.18 * s, 0.52 * s);
                        let b: (f32, f32) = (0.42 * s, 0.76 * s);
                        let c: (f32, f32) = (0.84 * s, 0.26 * s);
                        let first = ((b.0 - a.0).powi(2) + (b.1 - a.1).powi(2)).sqrt();
                        let second = ((c.0 - b.0).powi(2) + (c.1 - b.1).powi(2)).sqrt();
                        let mut remaining = t * (first + second);
                        let mut builder = PathBuilder::stroke(px((s / 12.0).max(1.5)));
                        builder.move_to(point(o.x + px(a.0), o.y + px(a.1)));
                        let lerp = |p: (f32, f32), q: (f32, f32), f: f32| {
                            (p.0 + (q.0 - p.0) * f, p.1 + (q.1 - p.1) * f)
                        };
                        let reach = lerp(a, b, (remaining / first).min(1.0));
                        builder.line_to(point(o.x + px(reach.0), o.y + px(reach.1)));
                        remaining -= first;
                        if remaining > 0.0 {
                            let reach = lerp(b, c, (remaining / second).min(1.0));
                            builder.line_to(point(o.x + px(reach.0), o.y + px(reach.1)));
                        }
                        if let Ok(path) = builder.build() {
                            window.paint_path(path, color);
                        }
                    },
                )
                .size_full(),
            )
        },
    )
}

/// One settings row: eyebrow, title, optional detail, trailing control.
pub fn row(
    eyebrow_text: &str,
    heading: impl Into<SharedString>,
    detail: Option<SharedString>,
    control: impl IntoElement,
    cx: &App,
) -> Div {
    h_flex()
        .w_full()
        .gap(space::L)
        .py(space::M)
        .items_center()
        .child(
            v_flex()
                .flex_1()
                .min_w_0()
                .gap(px(3.))
                .child(eyebrow(eyebrow_text.to_string(), cx))
                .child(body(heading, cx))
                .when_some(detail, |el, detail| el.child(muted(detail, cx))),
        )
        .child(control)
}

/// A titled group of rows separated by hairlines.
pub fn section(label: &str, rows: Vec<gpui_kit::AnyElement>, cx: &App) -> Div {
    let p = palette(cx);
    let count = rows.len();
    v_flex()
        .w_full()
        .gap(space::S)
        .child(eyebrow(label.to_string(), cx))
        .child(
            v_flex()
                .w_full()
                .px(space::L)
                .border_1()
                .border_color(p.line)
                .bg(p.surface)
                .children(rows.into_iter().enumerate().flat_map(move |(index, row)| {
                    let mut items = vec![row];
                    if index + 1 < count {
                        items.push(div().h(px(1.)).w_full().bg(p.line).into_any_element());
                    }
                    items
                })),
        )
}
