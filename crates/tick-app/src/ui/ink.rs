//! The walkthrough ink overlay: a transparent, click-through window over the
//! recorded screen showing ⇧-drawn strokes, numbered pins and click
//! ripples. Keyframes include it, so the agent sees the marks too.

use std::time::Instant;

use gpui_kit::{
    canvas, div, outline, point, px, size, BorderStyle, Bounds, Context, Entity, Hsla, IntoElement,
    ParentElement as _, PathBuilder, Pixels, Render, Styled as _, Subscription, Window,
};

use super::theme::size as type_size;
use crate::state::{Mark, Sketch, RIPPLE};

/// Ink is a fixed, loud red so it reads on any screen and in any theme.
const INK: Hsla = Hsla { h: 0.0, s: 0.85, l: 0.55, a: 1.0 };
const STROKE: f32 = 4.0;
const PIN: f32 = 22.0;

pub struct InkView {
    sketch: Entity<Sketch>,
    _observe: Subscription,
}

impl InkView {
    pub fn new(sketch: Entity<Sketch>, cx: &mut Context<Self>) -> InkView {
        let observe = cx.observe(&sketch, |_, _, cx| cx.notify());
        InkView { sketch, _observe: observe }
    }
}

impl Render for InkView {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let sketch = self.sketch.read(cx);
        let mut strokes: Vec<Vec<(f32, f32)>> = sketch
            .marks
            .iter()
            .filter_map(|mark| match mark {
                Mark::Ink(stroke) => Some(stroke.clone()),
                Mark::Pin { .. } => None,
            })
            .collect();
        strokes.extend(sketch.current.clone());
        let pins: Vec<(u32, (f32, f32))> = sketch
            .marks
            .iter()
            .filter_map(|mark| match mark {
                Mark::Pin { number, at } => Some((*number, *at)),
                Mark::Ink(_) => None,
            })
            .collect();
        let ripples: Vec<(f32, (f32, f32))> = sketch
            .ripples
            .iter()
            .filter(|(at, _)| at.elapsed() < RIPPLE)
            .map(|(at, point)| (progress(*at), *point))
            .collect();
        if !ripples.is_empty() {
            window.request_animation_frame();
        }
        div()
            .size_full()
            .relative()
            .child(
                canvas(|_, _, _| {}, move |bounds, _, window, _| {
                    for stroke in &strokes {
                        paint_stroke(bounds, stroke, window);
                    }
                    for (t, at) in &ripples {
                        paint_ripple(bounds, *t, *at, window);
                    }
                })
                .absolute()
                .size_full(),
            )
            .children(pins.into_iter().map(|(number, (x, y))| pin(number, x, y)))
    }
}

fn progress(at: Instant) -> f32 {
    (at.elapsed().as_secs_f32() / RIPPLE.as_secs_f32()).clamp(0.0, 1.0)
}

fn paint_stroke(bounds: Bounds<Pixels>, stroke: &[(f32, f32)], window: &mut Window) {
    let [first, rest @ ..] = stroke else { return };
    if rest.is_empty() {
        return;
    }
    let at = |(x, y): (f32, f32)| point(bounds.origin.x + px(x), bounds.origin.y + px(y));
    let mut builder = PathBuilder::stroke(px(STROKE));
    builder.move_to(at(*first));
    for point in rest {
        builder.line_to(at(*point));
    }
    if let Ok(path) = builder.build() {
        window.paint_path(path, INK);
    }
}

/// A square that grows and fades where the user clicked.
fn paint_ripple(bounds: Bounds<Pixels>, t: f32, (x, y): (f32, f32), window: &mut Window) {
    let side = 12.0 + 24.0 * t;
    let origin = point(bounds.origin.x + px(x - side / 2.0), bounds.origin.y + px(y - side / 2.0));
    let color = Hsla { a: 1.0 - t, ..INK };
    window.paint_quad(outline(Bounds::new(origin, size(px(side), px(side))), color, BorderStyle::Solid).border_widths(px(3.)));
}

fn pin(number: u32, x: f32, y: f32) -> impl IntoElement {
    div()
        .absolute()
        .left(px(x - PIN / 2.0))
        .top(px(y - PIN / 2.0))
        .size(px(PIN))
        .flex()
        .items_center()
        .justify_center()
        .bg(INK)
        .text_size(type_size::CAPTION)
        .text_color(gpui_kit::white())
        .child(number.to_string())
}
