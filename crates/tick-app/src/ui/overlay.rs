//! Recording indicators and the feedback notice, each in its own
//! click-through (or non-activating) overlay window.
//!
//! - Notch: a black, square extension of the camera housing with a live
//!   waveform and the target app's icon. A streaming model hangs a card of
//!   the words under that block.
//! - Pill: a dot-matrix disc and timer at the bottom of the screen. A
//!   streaming model opens a card of the words above it.
//! - Notice: "couldn't paste", "added to dictionary", "copied".

use std::time::{Duration, Instant};

use gpui_kit::base::{h_flex, v_flex};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    AnimationExt as _, App, AppContext as _, Bounds, Context, Entity, InteractiveElement as _,
    IntoElement, ParentElement as _, Render, SpringAnimation, StatefulInteractiveElement as _,
    Styled as _, Subscription, TitlebarOptions, Window, WindowBackgroundAppearance, WindowBounds,
    WindowKind, WindowOptions, canvas, div, fill, img, point, px, size,
};
use objc2::rc::Retained;
use objc2_app_kit::NSWindow;
use tick_core::settings::RecordingIndicatorStyle;

use super::components::{SNAP, drawn_check, icon, palette};
use super::icons::Icon;
use super::theme::FONT;
use super::theme::size as type_size;
use crate::platform::system::{self, ScreenGeometry};
use crate::platform::windows::{self, OverlayLevel};
use crate::state::{AppState, Feedback, Notice, PasteFailure, Phase};

const EXTENSION: f64 = 64.0;
const LOCK_ROW: f64 = 30.0;
const PILL_SIZE: (f64, f64) = (136.0, 36.0);
/// Square card of live words. It grows upward from the pill, or downward
/// from the notch, and never changes the indicator's own width.
const CARD_WIDTH: f32 = 300.0;
const CARD_MAX_LINES: usize = 6;
/// Mono at the UI body size fits about this many characters on one card line.
const CARD_CHARS: usize = 32;
const CARD_LINE: f32 = 20.0;
const CARD_PAD_Y: f32 = 12.0;
const CARD_GAP: f32 = 8.0;
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
const NOTCH_INK: gpui_kit::Hsla = gpui_kit::Hsla {
    h: 0.0,
    s: 0.0,
    l: 0.955,
    a: 1.0,
};
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
        OverlayView {
            kind,
            state,
            levels: vec![0.0; BARS],
            last_sample: Instant::now(),
            animate_until: Instant::now(),
            _observe: observe,
        }
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
        let live = state.live.clone();
        let streaming = card_open(phase, &state.settings.selected_model, &live);
        let showing = match self.kind {
            Kind::Notch => active(phase) && style == RecordingIndicatorStyle::Notch,
            Kind::Pill => active(phase) && style == RecordingIndicatorStyle::Pill,
            Kind::Notice => notice.is_some(),
        };
        if showing && self.kind != Kind::Notice {
            self.sample(if phase.recording_since().is_some() {
                meter.average
            } else {
                0.0
            });
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
            Kind::Notch => root.items_start().child(self.notch(
                phase,
                locked,
                showing,
                streaming,
                &live,
                source_icon,
                source_name,
                cx,
            )),
            Kind::Pill => root
                .items_end()
                .child(self.pill(phase, locked, showing, streaming, &live, cx)),
            Kind::Notice => root
                .items_end()
                .when_some(notice, |root, notice| root.child(notice_view(&notice, cx))),
        }
    }
}

impl OverlayView {
    fn notch(
        &self,
        phase: Phase,
        locked: bool,
        showing: bool,
        streaming: bool,
        live: &crate::speech::LiveText,
        source_icon: Option<std::sync::Arc<gpui_kit::Image>>,
        source_name: Option<String>,
        cx: &App,
    ) -> impl IntoElement {
        let p = palette(cx);
        let geometry = system::active_screen();
        let notch_width = geometry
            .and_then(|g| g.notch_width)
            .unwrap_or(NO_NOTCH_WIDTH) as f32;
        // Without a camera housing to tuck into, the block fades as it closes.
        let has_notch = geometry.is_some_and(|g| g.notch_width.is_some());
        // Beside a real camera housing the block must be black to read as one
        // shape with it; elsewhere it follows the theme like the pill.
        let (ground, ink) = if has_notch {
            (gpui_kit::black(), NOTCH_INK)
        } else {
            (p.hud, p.hud_text)
        };
        // A near-black accent (Monochrome in light mode) would vanish on black.
        let mark = if has_notch && p.accent.l < 0.3 {
            ink
        } else {
            p.accent
        };
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
        let housing = v_flex()
            .bg(ground)
            .overflow_hidden()
            .items_center()
            .with_spring(
                "notch",
                SpringAnimation::new(FLUID).to(target),
                move |el, t| {
                    let open = t.clamp(0.0, 1.0);
                    let lock = (t - 1.0).clamp(0.0, 1.0);
                    let width = notch_width + 2.0 * EXTENSION as f32 * open;
                    el.when(!has_notch, |el| el.opacity(open))
                        .w(px(width))
                        .h(px(notch_height
                            + (base_height - notch_height) * open
                            + LOCK_ROW as f32 * lock))
                },
            )
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
                            canvas(
                                |_, _, _| {},
                                move |bounds, _, window, _| {
                                    paint_bars(
                                        bounds,
                                        &levels,
                                        transcribing,
                                        if transcribing { quiet } else { mark },
                                        window,
                                    )
                                },
                            )
                            .size_full(),
                        ),
                    )
                    .child(
                        div()
                            .size(px(20.))
                            .flex()
                            .items_center()
                            .justify_center()
                            .child(match source_icon.clone() {
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
            });
        v_flex()
            .items_center()
            .child(housing)
            .when(streaming, |el| el.child(live_card(live, false, cx)))
    }

    /// A square bar: an accent mark that breathes with the voice, a live
    /// accent waveform, and the elapsed time. While the text is prepared the
    /// waveform becomes a traveling wave in the quiet text color.
    fn pill(
        &self,
        phase: Phase,
        locked: bool,
        showing: bool,
        streaming: bool,
        live: &crate::speech::LiveText,
        cx: &App,
    ) -> impl IntoElement {
        let p = palette(cx);
        let level = self.levels.last().copied().unwrap_or(0.0);
        let recording = phase.recording_since().is_some();
        let elapsed = phase
            .recording_since()
            .map(|started| started.elapsed().as_secs());
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
                SpringAnimation::new(FLUID)
                    .to(if showing { 1.0f32 } else { 0.0 })
                    .from(0.0f32),
                |el, t| {
                    let t = t.clamp(0.0, 1.0);
                    el.opacity(t)
                        .mt(px(8.0 * (1.0 - t)))
                        .w(gpui_kit::relative(0.82 + 0.18 * t))
                },
            )
            .child(
                div()
                    .size(px(12.))
                    .flex_none()
                    .flex()
                    .items_center()
                    .justify_center()
                    .child(if locked {
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
                div().h(px(14.)).flex_1().child(
                    canvas(
                        |_, _, _| {},
                        move |bounds, _, window, _| {
                            paint_bars(bounds, &levels, !recording, wave, window)
                        },
                    )
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
        let width_target = if recording { 1.0f32 } else { 0.0 };
        let bar = div()
            .flex_none()
            .flex()
            .justify_center()
            .child(pill)
            .with_spring(
                "pill-width",
                SpringAnimation::new(FLUID).to(width_target).from(0.0f32),
                |el, t| {
                    let width = PILL_COMPACT_WIDTH
                        + (PILL_SIZE.0 as f32 - PILL_COMPACT_WIDTH) * t.clamp(0.0, 1.0);
                    el.w(px(width))
                },
            );
        v_flex()
            .flex_none()
            .items_center()
            .when(streaming, |el| el.child(live_card(live, true, cx)))
            .child(bar)
    }
}

fn model_streams(selected: &str) -> bool {
    tick_core::models::curated_models()
        .into_iter()
        .any(|model| model.streams && model.is_selected(selected))
}

/// The card exists only while a Parakeet Unified recording already has words.
/// Other models, and the moment before the first word, stay the plain indicator.
fn card_open(phase: Phase, selected: &str, live: &crate::speech::LiveText) -> bool {
    phase.recording_since().is_some() && model_streams(selected) && !live.is_empty()
}

/// Keeps the newest words. Committed text is trimmed from the left so the
/// word being spoken stays on screen.
fn live_line(committed: &str, tentative: &str, max_chars: usize) -> (String, String) {
    let tentative: String = tentative.chars().take(max_chars).collect();
    let room = max_chars.saturating_sub(tentative.chars().count());
    let committed_chars: Vec<char> = committed.chars().collect();
    if committed_chars.len() <= room {
        return (committed_chars.into_iter().collect(), tentative);
    }
    let start = committed_chars.len() - room;
    let body: String = committed_chars[start..].iter().collect();
    (format!("…{body}"), tentative)
}

/// Wrapped line count for the card, capped so a long dictation stays on the newest lines.
fn card_lines(text: &str) -> usize {
    if text.is_empty() {
        return 1;
    }
    let mut lines = 1usize;
    let mut column = 0usize;
    for word in text.split_inclusive(char::is_whitespace) {
        let count = word.chars().count();
        if column > 0 && column + count > CARD_CHARS {
            lines += 1;
            column = 0;
        }
        if count > CARD_CHARS {
            lines += count.saturating_sub(1) / CARD_CHARS;
            column = count % CARD_CHARS;
        } else {
            column += count;
        }
    }
    lines.clamp(1, CARD_MAX_LINES)
}

fn transcript_text(live: &crate::speech::LiveText) -> String {
    let (committed, tentative) = live_line(
        &live.committed,
        &live.tentative,
        CARD_MAX_LINES * CARD_CHARS,
    );
    format!("{committed}{tentative}")
}

/// Extra window height, in px, for the open card and the gap under or over it.
fn card_block_px(live: &crate::speech::LiveText) -> i32 {
    if live.is_empty() {
        return 0;
    }
    let height =
        CARD_PAD_Y * 2.0 + CARD_LINE * card_lines(&transcript_text(live)) as f32 + CARD_GAP;
    height.round() as i32
}

/// Card of the words heard so far. `above` puts the gap under the card, so
/// it sits on the pill. Otherwise the gap is above it, under the notch.
fn live_card(live: &crate::speech::LiveText, above: bool, cx: &App) -> impl IntoElement {
    let p = palette(cx);
    let text = transcript_text(live);
    let content_h = CARD_PAD_Y * 2.0 + CARD_LINE * card_lines(&text) as f32;
    let ink = p.hud_text;
    v_flex()
        .w(px(CARD_WIDTH))
        .h(px(content_h))
        .flex_none()
        .justify_end()
        .bg(p.hud)
        .border_1()
        .border_color(p.alpha(ink, 0.12))
        .px(px(14.))
        .py(px(CARD_PAD_Y))
        .overflow_hidden()
        .font_family(FONT)
        .text_size(type_size::BODY)
        .line_height(px(CARD_LINE))
        .with_spring(
            "live-card",
            SpringAnimation::new(FLUID).to(1.0f32).from(0.0f32),
            move |el, t| {
                let t = t.clamp(0.0, 1.0);
                let shift = 8.0 * (1.0 - t);
                let el = el.opacity(t);
                if above {
                    el.mb(px(CARD_GAP)).mt(px(shift))
                } else {
                    el.mt(px(CARD_GAP + shift))
                }
            },
        )
        .child(
            div()
                .w_full()
                .whitespace_normal()
                .text_color(ink)
                .child(text),
        )
}

fn epoch_seconds() -> f32 {
    use std::sync::OnceLock;
    static START: OnceLock<Instant> = OnceLock::new();
    START.get_or_init(Instant::now).elapsed().as_secs_f32()
}

/// Square bars: a scrolling waveform while recording, a traveling wave
/// while transcribing.
fn paint_bars(
    bounds: Bounds<gpui_kit::Pixels>,
    levels: &[f32],
    transcribing: bool,
    color: gpui_kit::Hsla,
    window: &mut Window,
) {
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
        window.paint_quad(fill(
            Bounds::new(point(px(x), px(y)), size(px(bar), px(bar_height))),
            color,
        ));
    }
}

fn notice_copy(notice: &Notice) -> (Icon, String, String) {
    match &notice.feedback {
        Feedback::Copied => (
            Icon::Clipboard,
            "Copied to clipboard".into(),
            "Ready to paste anywhere".into(),
        ),
        Feedback::DictionaryAdded(list) => match list.as_slice() {
            [one] => (
                Icon::Dictionary,
                format!("Learned “{}”", one.replacement),
                format!(
                    "“{}” will now be written “{}”",
                    one.match_text, one.replacement
                ),
            ),
            many => (
                Icon::Dictionary,
                format!("{} words added to Dictionary", many.len()),
                many.iter()
                    .map(|c| format!("{} → {}", c.match_text, c.replacement))
                    .collect::<Vec<_>>()
                    .join("   "),
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
        Feedback::WalkthroughStarted { finish } => (
            Icon::Mic,
            "Recording a walkthrough".into(),
            format!("Talk and click · ⇧ drag to draw · ⇧ click to pin · {finish} to finish"),
        ),
        Feedback::ScreenRecordingNeeded => (
            Icon::Warning,
            "Tick needs Screen Recording".into(),
            "Allow Tick in System Settings › Screen Recording, then try again".into(),
        ),
        Feedback::WalkthroughFailed(reason) => {
            (Icon::Warning, "Walkthrough failed".into(), reason.clone())
        }
    }
}

fn notice_view(notice: &Notice, cx: &App) -> impl IntoElement {
    let p = palette(cx);
    let (glyph, heading, detail) = notice_copy(notice);
    let remaining = 1.0
        - (notice.shown_at.elapsed().as_secs_f32() / notice.duration.as_secs_f32()).clamp(0.0, 1.0);
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
        .with_spring(
            "notice-in",
            SpringAnimation::new(SNAP).to(1.0f32).from(0.0f32),
            |el, t| el.opacity(t.clamp(0.0, 1.0)).mt(px(10.0 * (1.0 - t))),
        )
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
                        .child(
                            div()
                                .text_size(type_size::BODY)
                                .text_color(p.hud_text)
                                .truncate()
                                .child(heading),
                        )
                        .child(
                            div()
                                .text_size(type_size::CAPTION)
                                .text_color(p.alpha(p.hud_text, 0.6))
                                .truncate()
                                .child(detail),
                        ),
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
                            .on_click(move |_, _, cx| {
                                state.update(cx, |state, cx| state.copy_notice_text(cx))
                            }),
                    )
                }),
        )
        .child(
            div()
                .h(px(1.))
                .w_full()
                .bg(p.alpha(p.hud_text, 0.1))
                .child(div().h_full().bg(p.accent).w(gpui_kit::relative(remaining))),
        )
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
    ink: Option<OverlayWindow>,
    _observe: Option<Subscription>,
    _observe_sketch: Option<Subscription>,
    notice_height: f64,
    /// Extra height currently given to each indicator window for the live card.
    /// Zero means the plain indicator frame.
    pill_extra: i32,
    notch_extra: i32,
}

fn open_ink(state: &Entity<AppState>, cx: &mut App) -> Option<OverlayWindow> {
    let options = WindowOptions {
        window_bounds: Some(WindowBounds::Windowed(Bounds::new(
            point(px(0.), px(0.)),
            size(px(10.), px(10.)),
        ))),
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
    let sketch = state.read(cx).sketch.clone();
    let view_sketch = sketch.clone();
    let handle = cx
        .open_window(options, move |_, cx| {
            cx.new(|cx| super::ink::InkView::new(view_sketch, cx))
        })
        .ok()?;
    let native = handle
        .update(cx, |_, window, _| windows::ns_window(window))
        .ok()
        .flatten()?;
    windows::configure_overlay(&native, OverlayLevel::Shielding, true);
    windows::hide(&native);
    let number = u32::try_from(native.windowNumber()).ok();
    sketch.update(cx, |sketch, _| sketch.window = number);
    Some(OverlayWindow {
        handle: handle.into(),
        native,
    })
}

impl gpui_kit::Global for Overlays {}

fn open(kind: Kind, state: &Entity<AppState>, cx: &mut App) -> Option<OverlayWindow> {
    let options = WindowOptions {
        window_bounds: Some(WindowBounds::Windowed(Bounds::new(
            point(px(0.), px(0.)),
            size(px(10.), px(10.)),
        ))),
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
            window
                .observe_window_appearance(|_, cx| super::apply_theme(cx))
                .detach();
            cx.new(|cx| OverlayView::new(kind, state, cx))
        })
        .ok()?;
    let native = handle
        .update(cx, |_, window, _| windows::ns_window(window))
        .ok()
        .flatten()?;
    let level = if kind == Kind::Notch {
        OverlayLevel::StatusBar
    } else {
        OverlayLevel::Shielding
    };
    windows::configure_overlay(&native, level, kind != Kind::Notice);
    windows::hide(&native);
    Some(OverlayWindow {
        handle: handle.into(),
        native,
    })
}

enum Change {
    /// Screen-relative frame (x, y, width, height), then order front.
    Show(ScreenGeometry, (f64, f64, f64, f64)),
    Hide,
    /// An indicator whose recording ended: hide once the exit animation has
    /// played, unless recording started again meanwhile.
    Retire,
}

fn pill_frame(screen: &ScreenGeometry, extra: i32) -> (f64, f64, f64, f64) {
    let width = if extra > 0 {
        CARD_WIDTH as f64 + 24.0
    } else {
        PILL_SIZE.0 + 24.0
    };
    let height = PILL_SIZE.1 + 16.0 + extra as f64;
    let bottom = screen.visible_y - screen.y + 40.0;
    ((screen.width - width) / 2.0, bottom, width, height)
}

fn notch_frame(screen: &ScreenGeometry, extra: i32) -> (f64, f64, f64, f64) {
    let notch_width = screen.notch_width.unwrap_or(NO_NOTCH_WIDTH);
    let width = if extra > 0 {
        (notch_width + 2.0 * EXTENSION).max(CARD_WIDTH as f64 + 16.0)
    } else {
        notch_width + 2.0 * EXTENSION
    };
    let height = (screen.notch_height + 14.0).max(48.0) + LOCK_ROW + extra as f64;
    (
        (screen.width - width) / 2.0,
        screen.height - height,
        width,
        height,
    )
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
            ink: open_ink(state, cx),
            _observe: None,
            _observe_sketch: None,
            notice_height: 0.0,
            pill_extra: 0,
            notch_extra: 0,
        };
        overlays._observe = Some(cx.observe(state, |state, cx| Overlays::sync(&state, cx)));
        let sketch = state.read(cx).sketch.clone();
        overlays._observe_sketch =
            Some(cx.observe(&sketch, |sketch, cx| Overlays::sync_ink(&sketch, cx)));
        cx.set_global(overlays);
    }

    /// Covers the recorded screen while a walkthrough runs.
    fn sync_ink(sketch: &Entity<crate::state::Sketch>, cx: &mut App) {
        let screen = sketch.read(cx).screen;
        let Some(window) = &cx.global::<Overlays>().ink else {
            return;
        };
        let (native, handle) = (window.native.clone(), window.handle);
        let visible = windows::is_visible(&native);
        let change = match screen {
            Some(screen) if !visible => {
                Change::Show(screen, (0.0, 0.0, screen.width, screen.height))
            }
            None if visible => Change::Hide,
            _ => return,
        };
        // Frame changes re-enter GPUI; apply them on the next turn (see `sync`).
        cx.spawn(async move |cx| {
            apply(&native, &change);
            cx.update(|cx| {
                let _ = handle.update(cx, |_, window, _| window.refresh());
            });
        })
        .detach();
    }

    fn sync(state: &Entity<AppState>, cx: &mut App) {
        let (phase, style, notice, extra) = {
            let state = state.read(cx);
            let extra = if card_open(state.phase, &state.settings.selected_model, &state.live) {
                card_block_px(&state.live)
            } else {
                0
            };
            (
                state.phase,
                state.settings.recording_indicator_style,
                state.notice.clone(),
                extra,
            )
        };
        let Some(screen) = system::active_screen() else {
            return;
        };
        let overlays = cx.global_mut::<Overlays>();
        let recording = active(phase);
        let mut changes = Vec::new();
        let notch = overlays.notch.as_ref().map(|window| window.native.clone());
        if let Some(native) = notch {
            let show = recording && style == RecordingIndicatorStyle::Notch;
            let visible = windows::is_visible(&native);
            if show && (!visible || overlays.notch_extra != extra) {
                overlays.notch_extra = extra;
                changes.push((native, Change::Show(screen, notch_frame(&screen, extra))));
            } else if !show && visible {
                if overlays.notch_extra != 0 {
                    overlays.notch_extra = 0;
                    changes.push((
                        native.clone(),
                        Change::Show(screen, notch_frame(&screen, 0)),
                    ));
                }
                changes.push((native, Change::Retire));
            }
        }
        let pill = overlays.pill.as_ref().map(|window| window.native.clone());
        if let Some(native) = pill {
            let show = recording && style == RecordingIndicatorStyle::Pill;
            let visible = windows::is_visible(&native);
            if show && (!visible || overlays.pill_extra != extra) {
                overlays.pill_extra = extra;
                changes.push((native, Change::Show(screen, pill_frame(&screen, extra))));
            } else if !show && visible {
                if overlays.pill_extra != 0 {
                    overlays.pill_extra = 0;
                    changes.push((native.clone(), Change::Show(screen, pill_frame(&screen, 0))));
                }
                changes.push((native, Change::Retire));
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
                        changes.push((
                            window.native.clone(),
                            Change::Show(
                                screen,
                                (
                                    (screen.width - NOTICE_WIDTH) / 2.0,
                                    bottom,
                                    NOTICE_WIDTH,
                                    height,
                                ),
                            ),
                        ));
                    }
                }
                None if windows::is_visible(&window.native) => {
                    changes.push((window.native.clone(), Change::Hide))
                }
                None => {}
            }
        }
        let handles: Vec<gpui_kit::AnyWindowHandle> =
            [&overlays.notch, &overlays.pill, &overlays.notice]
                .iter()
                .filter_map(|w| w.as_ref().map(|w| w.handle))
                .collect();
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
            if changes
                .iter()
                .any(|(_, change)| matches!(change, Change::Retire))
            {
                cx.background_executor().timer(EXIT).await;
                if cx.update(|cx| AppState::global(cx).read(cx).phase == Phase::Idle) {
                    for (native, _) in changes
                        .iter()
                        .filter(|(_, change)| matches!(change, Change::Retire))
                    {
                        windows::hide(native);
                    }
                }
            }
        })
        .detach();
    }
}

#[cfg(test)]
mod tests {
    use super::live_line;

    #[test]
    fn card_lines_wraps_and_caps() {
        assert_eq!(super::card_lines(""), 1);
        assert_eq!(super::card_lines("hello"), 1);
        let wide = "word ".repeat(40);
        assert!(super::card_lines(wide.trim()) > 1);
        assert_eq!(
            super::card_lines(&"word ".repeat(80)),
            super::CARD_MAX_LINES
        );
    }

    #[test]
    fn live_line_keeps_the_newest_words() {
        let (committed, tentative) = live_line("abcdefghij", "xy", 8);
        assert_eq!(committed, "…efghij");
        assert_eq!(tentative, "xy");
        let (committed, tentative) = live_line("short", " word", 20);
        assert_eq!(committed, "short");
        assert_eq!(tentative, " word");
    }
}
