//! Recording indicators and the feedback notice, each in its own
//! click-through (or non-activating) overlay window.
//!
//! - Notch: a black, square extension of the camera housing with a live
//!   waveform and the target app's icon.
//! - Pill: a dot-matrix disc and timer at the bottom of the screen.
//! - Notice: "couldn't paste", "added to dictionary", "copied".

use std::time::{Duration, Instant};

use gpui_kit::base::{h_flex, v_flex};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    canvas, div, fill, img, point, px, size, AnimationExt as _, App, AppContext as _, Bounds, Context, Entity,
    InteractiveElement as _, IntoElement, ParentElement as _, Render, SpringAnimation,
    StatefulInteractiveElement as _, Styled as _, Subscription, TitlebarOptions, Window, WindowBackgroundAppearance,
    WindowBounds, WindowKind, WindowOptions,
};
use objc2::rc::Retained;
use objc2_app_kit::NSWindow;
use tick_core::settings::RecordingIndicatorStyle;

use super::components::{drawn_check, icon, palette, SNAP};
use super::icons::Icon;
use super::theme::size as type_size;
use crate::platform::system::{self, ScreenGeometry};
use crate::platform::windows::{self, OverlayLevel};
use crate::state::{AppState, Feedback, Notice, PasteFailure, Phase};

const EXTENSION: f64 = 64.0;
const LOCK_ROW: f64 = 30.0;
const PILL_SIZE: (f64, f64) = (136.0, 36.0);
/// Pill width while transcribing, with no timer.
const PILL_COMPACT_WIDTH: f32 = 96.0;
/// How long an indicator stays on screen after recording ends, so it can
/// animate out instead of vanishing.
const EXIT: Duration = Duration::from_millis(420);
/// One spring for every indicator: quick, with a hint of overshoot so
/// opening and closing feel physical rather than linear.
const FLUID: gpui_kit::SpringConfig = gpui_kit::SpringConfig::new(380.0, 30.0, 1.0);
/// Width of the dark block between the two ears on a screen without a
/// camera housing.
const NO_NOTCH_WIDTH: f64 = 40.0;
/// Text on the black notch block.
const NOTCH_INK: gpui_kit::Hsla = gpui_kit::Hsla { h: 0.0, s: 0.0, l: 0.955, a: 1.0 };
const NOTICE_WIDTH: f64 = 380.0;
const BARS: usize = 9;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Kind {
    Notch,
    Pill,
    Notice,
}

pub struct OverlayView {
    kind: Kind,
    state: Entity<AppState>,
    levels: Vec<f32>,
    last_sample: Instant,
    /// Keep drawing until here so the exit animation plays out.
    animate_until: Instant,
    _observe: Subscription,
}

impl OverlayView {
    fn new(kind: Kind, state: Entity<AppState>, cx: &mut Context<Self>) -> OverlayView {
        let observe = cx.observe(&state, |_, _, cx| cx.notify());
        OverlayView { kind, state, levels: vec![0.0; BARS], last_sample: Instant::now(), animate_until: Instant::now(), _observe: observe }
    }

    /// Scrolling waveform history sampled at ~30 Hz from the input meter.
    fn sample(&mut self, level: f32) {
        if self.last_sample.elapsed() < Duration::from_millis(33) {
            return;
        }
        self.last_sample = Instant::now();
        self.levels.remove(0);
        self.levels.push((level * 6.0).clamp(0.0, 1.0).sqrt());
    }
}

fn active(phase: Phase) -> bool {
    phase != Phase::Idle
}

impl Render for OverlayView {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let state = self.state.read(cx);
        let phase = state.phase;
        let locked = state.locked;
        let style = state.settings.recording_indicator_style;
        let meter = state.recorder.meter();
        let notice = state.notice.clone();
        let source_icon = state.source_icon.clone();
        let source_name = state.source_name.clone();
        let showing = match self.kind {
            Kind::Notch => active(phase) && style == RecordingIndicatorStyle::Notch,
            Kind::Pill => active(phase) && style == RecordingIndicatorStyle::Pill,
            Kind::Notice => notice.is_some(),
        };
        if showing && self.kind != Kind::Notice {
            self.sample(if matches!(phase, Phase::Recording { .. }) { meter.average } else { 0.0 });
            self.animate_until = Instant::now() + EXIT;
        }
        if self.kind != Kind::Notice && Instant::now() < self.animate_until {
            window.request_animation_frame();
        }
        if showing && self.kind == Kind::Notice {
            window.request_animation_frame();
        }
        let root = div().size_full().flex().justify_center();
        match self.kind {
            Kind::Notch => root.items_start().child(self.notch(phase, locked, showing, source_icon, source_name, cx)),
            Kind::Pill => root.items_center().child(self.pill(phase, locked, showing, cx)),
            Kind::Notice => root.items_end().when_some(notice, |root, notice| root.child(notice_view(&notice, cx))),
        }
    }
}

impl OverlayView {
    fn notch(
        &self,
        phase: Phase,
        locked: bool,
        showing: bool,
        source_icon: Option<std::sync::Arc<gpui_kit::Image>>,
        source_name: Option<String>,
        cx: &App,
    ) -> impl IntoElement {
        let p = palette(cx);
        let geometry = system::active_screen();
        let notch_width = geometry.and_then(|g| g.notch_width).unwrap_or(NO_NOTCH_WIDTH) as f32;
        // Without a camera housing to tuck into, the block fades as it closes.
        let has_notch = geometry.is_some_and(|g| g.notch_width.is_some());
        // Beside a real camera housing the block must be black to read as one
        // shape with it; elsewhere it follows the theme like the pill.
        let (ground, ink) = if has_notch { (gpui_kit::black(), NOTCH_INK) } else { (p.hud, p.hud_text) };
        // A near-black accent (Monochrome in light mode) would vanish on black.
        let mark = if has_notch && p.accent.l < 0.3 { ink } else { p.accent };
        let notch_height = geometry.map_or(32.0, |g| g.notch_height) as f32;
        let base_height = (notch_height + 14.0).max(48.0);
        let levels = self.levels.clone();
        let transcribing = phase == Phase::Transcribing;
        let quiet = p.alpha(ink, 0.55);
        // One spring: 0 tucked into the housing, 1 open, 2 open with the lock row.
        let target = match (showing, locked) {
            (false, _) => 0.0f32,
            (true, false) => 1.0,
            (true, true) => 2.0,
        };
        v_flex()
            .bg(ground)
            .overflow_hidden()
            .items_center()
            .with_spring("notch", SpringAnimation::new(FLUID).to(target), move |el, t| {
                let open = t.clamp(0.0, 1.0);
                let lock = (t - 1.0).clamp(0.0, 1.0);
                el.when(!has_notch, |el| el.opacity(open))
                    .w(px(notch_width + 2.0 * EXTENSION as f32 * open))
                    .h(px(notch_height + (base_height - notch_height) * open + LOCK_ROW as f32 * lock))
            })
            .child(
                h_flex()
                    .w_full()
                    .h(px(base_height))
                    .flex_none()
                    .items_center()
                    .justify_between()
                    .px(px(14.))
                    .child(
                        div().w(px(EXTENSION as f32 - 20.0)).h(px(18.)).child(
                            canvas(|_, _, _| {}, move |bounds, _, window, _| {
                                paint_bars(bounds, &levels, transcribing, if transcribing { quiet } else { mark }, window)
                            })
                            .size_full(),
                        ),
                    )
                    .child(
                        div().size(px(20.)).flex().items_center().justify_center().child(match source_icon.clone() {
                            Some(image) => img(image).size(px(20.)).into_any_element(),
                            None => icon(Icon::Mic, px(14.), ink).into_any_element(),
                        }),
                    ),
            )
            .when(locked, |el| {
                el.child(
                    h_flex()
                        .h(px(LOCK_ROW as f32))
                        .gap(px(6.))
                        .items_center()
                        .child(icon(Icon::Lock, px(11.), mark))
                        .child(
                            div()
                                .text_size(type_size::CAPTION)
                                .text_color(ink)
                                .whitespace_nowrap()
                                .child(source_name.unwrap_or_else(|| "Listening".into())),
                        ),
                )
            })
    }

    /// A square bar: an accent mark that breathes with the voice, a live
    /// accent waveform, and the elapsed time. While the text is prepared the
    /// waveform becomes a traveling wave in the quiet text color.
    fn pill(&self, phase: Phase, locked: bool, showing: bool, cx: &App) -> impl IntoElement {
        let p = palette(cx);
        let level = self.levels.last().copied().unwrap_or(0.0);
        let recording = matches!(phase, Phase::Recording { .. });
        let elapsed = match phase {
            Phase::Recording { started } => Some(started.elapsed().as_secs()),
            _ => None,
        };
        let levels = self.levels.clone();
        let quiet = p.alpha(p.hud_text, 0.55);
        let wave = if recording { p.accent } else { quiet };
        let pill = h_flex()
            .w_full()
            .h(px(PILL_SIZE.1 as f32))
            .px(px(12.))
            .gap(px(10.))
            .items_center()
            .bg(p.hud)
            .border_1()
            .border_color(p.alpha(p.hud_text, 0.12))
            .overflow_hidden()
            .with_spring(
                "pill-open",
                SpringAnimation::new(FLUID).to(if showing { 1.0f32 } else { 0.0 }).from(0.0f32),
                |el, t| {
                    let t = t.clamp(0.0, 1.0);
                    el.opacity(t).mt(px(8.0 * (1.0 - t))).w(gpui_kit::relative(0.82 + 0.18 * t))
                },
            )
            .child(
                div().size(px(12.)).flex_none().flex().items_center().justify_center().child(if locked {
                    icon(Icon::Lock, px(11.), p.accent).into_any_element()
                } else {
                    div()
                        .size(px(8.))
                        .bg(if recording { p.accent } else { quiet })
                        .opacity(if recording { 0.45 + 0.55 * level } else { 1.0 })
                        .into_any_element()
                }),
            )
            .child(
                div().flex_1().h(px(14.)).child(
                    canvas(|_, _, _| {}, move |bounds, _, window, _| paint_bars(bounds, &levels, !recording, wave, window))
                        .size_full(),
                ),
            )
            .when_some(elapsed, |el, elapsed| {
                el.child(
                    div()
                        .w(px(30.))
                        .flex_none()
                        .flex()
                        .justify_end()
                        .text_size(type_size::CAPTION)
                        .text_color(p.alpha(p.hud_text, 0.7))
                        .whitespace_nowrap()
                        .child(format!("{}:{:02}", elapsed / 60, elapsed % 60)),
                )
            });
        // Processing drops the timer, so the bar tightens to its content.
        div().flex_none().flex().justify_center().child(pill).with_spring(
            "pill-width",
            SpringAnimation::new(FLUID).to(if recording { 1.0f32 } else { 0.0 }).from(1.0f32),
            |el, t| el.w(px(PILL_COMPACT_WIDTH + (PILL_SIZE.0 as f32 - PILL_COMPACT_WIDTH) * t)),
        )
    }
}

fn epoch_seconds() -> f32 {
    use std::sync::OnceLock;
    static START: OnceLock<Instant> = OnceLock::new();
    START.get_or_init(Instant::now).elapsed().as_secs_f32()
}

/// Square bars: a scrolling waveform while recording, a traveling wave
/// while transcribing.
fn paint_bars(bounds: Bounds<gpui_kit::Pixels>, levels: &[f32], transcribing: bool, color: gpui_kit::Hsla, window: &mut Window) {
    let count = levels.len();
    let gap = 2.0f32;
    let width = bounds.size.width.as_f32();
    let height = bounds.size.height.as_f32();
    let bar = ((width - gap * (count as f32 - 1.0)) / count as f32).max(1.0);
    let time = epoch_seconds();
    for (index, level) in levels.iter().enumerate() {
        let amplitude = if transcribing {
            0.25 + 0.35 * (0.5 + 0.5 * (time * 6.0 - index as f32 * 0.7).sin())
        } else {
            0.22 + 0.78 * level
        };
        let bar_height = (height * amplitude).max(2.0);
        let x = bounds.origin.x.as_f32() + index as f32 * (bar + gap);
        let y = bounds.origin.y.as_f32() + (height - bar_height) / 2.0;
        window.paint_quad(fill(Bounds::new(point(px(x), px(y)), size(px(bar), px(bar_height))), color));
    }
}

fn notice_copy(notice: &Notice) -> (Icon, String, String) {
    match &notice.feedback {
        Feedback::Copied => (Icon::Clipboard, "Copied to clipboard".into(), "Ready to paste anywhere".into()),
        Feedback::DictionaryAdded(list) => match list.as_slice() {
            [one] => (Icon::Dictionary, format!("Learned “{}”", one.replacement), format!("“{}” will now be written “{}”", one.match_text, one.replacement)),
            many => (
                Icon::Dictionary,
                format!("{} words added to Dictionary", many.len()),
                many.iter().map(|c| format!("{} → {}", c.match_text, c.replacement)).collect::<Vec<_>>().join("   "),
            ),
        },
        Feedback::PasteUnavailable { reason, .. } => (
            Icon::Warning,
            match reason {
                PasteFailure::NoFocusedInput => "No text field focused".into(),
                PasteFailure::Rejected => "This app rejected the paste".into(),
            },
            "Copy the transcript and paste it yourself".into(),
        ),
    }
}

fn notice_view(notice: &Notice, cx: &App) -> impl IntoElement {
    let p = palette(cx);
    let (glyph, heading, detail) = notice_copy(notice);
    let remaining = 1.0 - (notice.shown_at.elapsed().as_secs_f32() / notice.duration.as_secs_f32()).clamp(0.0, 1.0);
    let copied = notice.feedback == Feedback::Copied;
    let can_copy = matches!(notice.feedback, Feedback::PasteUnavailable { .. });
    let learned = matches!(notice.feedback, Feedback::DictionaryAdded(_));
    let state = AppState::global(cx);
    v_flex()
        .id("notice")
        .w(px(NOTICE_WIDTH as f32 - 16.0))
        .mb(px(8.))
        .bg(p.hud)
        .border_1()
        .border_color(p.alpha(p.hud_text, 0.14))
        .with_spring("notice-in", SpringAnimation::new(SNAP).to(1.0f32).from(0.0f32), |el, t| {
            el.opacity(t.clamp(0.0, 1.0)).mt(px(10.0 * (1.0 - t)))
        })
        .child(
            h_flex()
                .gap(px(12.))
                .px(px(14.))
                .py(px(12.))
                .items_center()
                .child(
                    div()
                        .size(px(26.))
                        .flex()
                        .flex_none()
                        .items_center()
                        .justify_center()
                        .border_1()
                        .border_color(p.alpha(p.accent, 0.6))
                        .child(if copied || learned {
                            drawn_check("notice-check", true, px(16.), p.accent).into_any_element()
                        } else {
                            icon(glyph, px(14.), p.hud_text).into_any_element()
                        }),
                )
                .child(
                    v_flex()
                        .flex_1()
                        .gap(px(2.))
                        .overflow_hidden()
                        .child(div().text_size(type_size::BODY).text_color(p.hud_text).truncate().child(heading))
                        .child(div().text_size(type_size::CAPTION).text_color(p.alpha(p.hud_text, 0.6)).truncate().child(detail)),
                )
                .when(can_copy, |el| {
                    el.child(
                        div()
                            .id("notice-copy")
                            .flex_none()
                            .px(px(10.))
                            .py(px(5.))
                            .border_1()
                            .border_color(p.alpha(p.hud_text, 0.3))
                            .text_size(type_size::CAPTION)
                            .text_color(p.hud_text)
                            .hover(move |s| s.bg(p.alpha(p.hud_text, 0.12)))
                            .active(move |s| s.bg(p.alpha(p.hud_text, 0.22)))
                            .child("Copy")
                            .on_click(move |_, _, cx| state.update(cx, |state, cx| state.copy_notice_text(cx))),
                    )
                }),
        )
        .child(div().h(px(1.)).w_full().bg(p.alpha(p.hud_text, 0.1)).child(div().h_full().bg(p.accent).w(gpui_kit::relative(remaining))))
}

struct OverlayWindow {
    handle: gpui_kit::AnyWindowHandle,
    native: Retained<NSWindow>,
}

/// Owns the overlay windows and keeps them placed on the active screen.
pub struct Overlays {
    notch: Option<OverlayWindow>,
    pill: Option<OverlayWindow>,
    notice: Option<OverlayWindow>,
    _observe: Option<Subscription>,
    notice_height: f64,
}

impl gpui_kit::Global for Overlays {}

fn open(kind: Kind, state: &Entity<AppState>, cx: &mut App) -> Option<OverlayWindow> {
    let options = WindowOptions {
        window_bounds: Some(WindowBounds::Windowed(Bounds::new(point(px(0.), px(0.)), size(px(10.), px(10.))))),
        titlebar: None::<TitlebarOptions>,
        focus: false,
        show: false,
        kind: WindowKind::PopUp,
        is_movable: false,
        is_resizable: false,
        is_minimizable: false,
        window_background: WindowBackgroundAppearance::Transparent,
        ..WindowOptions::default()
    };
    let state = state.clone();
    let handle = cx
        .open_window(options, move |window, cx| {
            // Keeps "System" appearance in step even while the main window is closed.
            window.observe_window_appearance(|_, cx| super::apply_theme(cx)).detach();
            cx.new(|cx| OverlayView::new(kind, state, cx))
        })
        .ok()?;
    let native = handle.update(cx, |_, window, _| windows::ns_window(window)).ok().flatten()?;
    let level = if kind == Kind::Notch { OverlayLevel::StatusBar } else { OverlayLevel::Shielding };
    windows::configure_overlay(&native, level, kind != Kind::Notice);
    windows::hide(&native);
    Some(OverlayWindow { handle: handle.into(), native })
}

enum Change {
    /// Screen-relative frame (x, y, width, height), then order front.
    Show(ScreenGeometry, (f64, f64, f64, f64)),
    Hide,
    /// An indicator whose recording ended: hide once the exit animation has
    /// played, unless recording started again meanwhile.
    Retire,
}

fn apply(native: &NSWindow, change: &Change) {
    match change {
        Change::Show(screen, (x, y, width, height)) => {
            windows::set_frame(native, screen.x + x, screen.y + y, *width, *height);
            windows::show(native);
        }
        Change::Hide => windows::hide(native),
        Change::Retire => {}
    }
}

impl Overlays {
    pub fn install(state: &Entity<AppState>, cx: &mut App) {
        let mut overlays = Overlays {
            notch: open(Kind::Notch, state, cx),
            pill: open(Kind::Pill, state, cx),
            notice: open(Kind::Notice, state, cx),
            _observe: None,
            notice_height: 0.0,
        };
        overlays._observe = Some(cx.observe(state, |state, cx| Overlays::sync(&state, cx)));
        cx.set_global(overlays);
    }

    fn sync(state: &Entity<AppState>, cx: &mut App) {
        let (phase, style, notice) = {
            let state = state.read(cx);
            (state.phase, state.settings.recording_indicator_style, state.notice.clone())
        };
        let Some(screen) = system::active_screen() else { return };
        let overlays = cx.global_mut::<Overlays>();
        let recording = active(phase);
        let mut changes = Vec::new();
        if let Some(window) = &overlays.notch {
            let show = recording && style == RecordingIndicatorStyle::Notch;
            if show && !windows::is_visible(&window.native) {
                let notch_width = screen.notch_width.unwrap_or(NO_NOTCH_WIDTH);
                let height = (screen.notch_height + 14.0).max(48.0) + LOCK_ROW;
                let width = notch_width + 2.0 * EXTENSION;
                changes.push((window.native.clone(), Change::Show(screen, ((screen.width - width) / 2.0, screen.height - height, width, height))));
            } else if !show && windows::is_visible(&window.native) {
                changes.push((window.native.clone(), Change::Retire));
            }
        }
        if let Some(window) = &overlays.pill {
            let show = recording && style == RecordingIndicatorStyle::Pill;
            if show && !windows::is_visible(&window.native) {
                let (width, height) = (PILL_SIZE.0 + 24.0, PILL_SIZE.1 + 16.0);
                let bottom = screen.visible_y - screen.y + 40.0;
                changes.push((window.native.clone(), Change::Show(screen, ((screen.width - width) / 2.0, bottom, width, height))));
            } else if !show && windows::is_visible(&window.native) {
                changes.push((window.native.clone(), Change::Retire));
            }
        }
        if let Some(window) = &overlays.notice {
            match &notice {
                Some(notice) => {
                    let lines = match &notice.feedback {
                        Feedback::DictionaryAdded(list) if list.len() > 1 => 1.0,
                        _ => 0.0,
                    };
                    let height = 92.0 + lines * 14.0;
                    if !windows::is_visible(&window.native) || overlays.notice_height != height {
                        overlays.notice_height = height;
                        let bottom = screen.visible_y - screen.y + 96.0;
                        changes.push((window.native.clone(), Change::Show(screen, ((screen.width - NOTICE_WIDTH) / 2.0, bottom, NOTICE_WIDTH, height))));
                    }
                }
                None if windows::is_visible(&window.native) => changes.push((window.native.clone(), Change::Hide)),
                None => {}
            }
        }
        let handles: Vec<gpui_kit::AnyWindowHandle> =
            [&overlays.notch, &overlays.pill, &overlays.notice].iter().filter_map(|w| w.as_ref().map(|w| w.handle)).collect();
        // Resizing an NSWindow makes GPUI re-enter the app to report the new
        // size, which fails while this observer holds it; the window would keep
        // drawing at its old size. Apply frame changes on the next turn instead.
        cx.spawn(async move |cx| {
            for (native, change) in &changes {
                apply(native, change);
            }
            cx.update(|cx| {
                for handle in handles {
                    let _ = handle.update(cx, |_, window, _| window.refresh());
                }
            });
            if changes.iter().any(|(_, change)| matches!(change, Change::Retire)) {
                cx.background_executor().timer(EXIT).await;
                if cx.update(|cx| AppState::global(cx).read(cx).phase == Phase::Idle) {
                    for (native, _) in changes.iter().filter(|(_, change)| matches!(change, Change::Retire)) {
                        windows::hide(native);
                    }
                }
            }
        })
        .detach();
    }
}
