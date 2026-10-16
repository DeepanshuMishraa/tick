//! Home: greeting, three live stats, and the transcript history by day.

use std::time::Duration;

use chrono::{Datelike, NaiveDate};
use gpui_kit::base::{h_flex, v_flex};
use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::menu::{DropdownMenu as _, PopupMenuItem};
use gpui_kit::component::Sizable as _;
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    div, px, Animation, AnimationExt as _, Context, InteractiveElement as _, IntoElement,
    ParentElement as _, SharedString, StatefulInteractiveElement as _, Styled as _, Window,
};
use tick_core::history::Transcript;
use tick_core::stats::greeting;

use crate::state::Tab;
use crate::ui::components::{drawn_check, icon, muted, palette};
use crate::ui::icons::Icon;
use crate::ui::main_view::{HistoryDigest, MainView};
use crate::ui::theme::{size, space};

const PAGE: usize = HistoryDigest::RECENT;

fn day_label(date: NaiveDate, today: NaiveDate) -> String {
    let days = (today - date).num_days();
    match days {
        0 => "Today".into(),
        1 => "Yesterday".into(),
        2..=6 => date.format("%A").to_string(),
        _ if date.year() == today.year() => date.format("%-d %B").to_string(),
        _ => date.format("%-d %B %Y").to_string(),
    }
}

pub fn render(view: &mut MainView, _: &mut Window, cx: &mut Context<MainView>) -> impl IntoElement {
    let p = palette(cx);
    let state_entity = view.state.clone();
    let digest = view.digest(cx);
    let state = view.state.read(cx);
    let today = digest.today;
    let stats = digest.home.clone();
    let name = state.user_name.clone();
    let hotkey = state.settings.hotkey.label();
    let playing = state.playing.as_ref().map(|(id, _)| *id);
    let total = digest.total;
    let shown = digest.recent.clone();

    // One quiet line of numbers; it opens Insights.
    let summary = {
        let entity = state_entity.clone();
        let streak = format!("{}-day streak", stats.daily_streak);
        let words = format!("{} {}", thousands(stats.word_count), if stats.word_count == 1 { "word" } else { "words" });
        let pace = format!("{} wpm", stats.average_wpm);
        div()
            .id("home-summary")
            .text_size(size::BODY)
            .text_color(p.muted)
            .hover(move |s| s.text_color(p.text))
            .child(format!("{streak}  ·  {words}  ·  {pace}"))
            .on_click(move |_, _, cx| entity.update(cx, |state, cx| state.set_tab(Tab::Insights, cx)))
    };

    let mut groups: Vec<(String, Vec<Transcript>)> = Vec::new();
    for transcript in shown {
        let label = day_label(transcript.timestamp.to_local().date_naive(), today);
        match groups.last_mut() {
            Some((current, items)) if *current == label => items.push(transcript),
            _ => groups.push((label, vec![transcript])),
        }
    }

    v_flex()
        .gap(space::XXL)
        .child(
            v_flex()
                .gap(space::S)
                .child(div().text_size(size::TITLE).text_color(p.text).child(greeting(stats.word_count, &name)))
                .child(summary),
        )
        .when(total == 0, |page| page.child(empty_state(&hotkey, cx)))
        .children(groups.into_iter().map(|(label, items)| {
            v_flex()
                .child(div().pb(space::S).text_size(size::CAPTION).text_color(p.muted).child(label))
                .child(div().h(px(1.)).bg(p.line))
                .children(items.into_iter().map(|transcript| row(view, transcript, playing, cx)))
        }))
        .when(total > PAGE, |page| page.child(muted(format!("Showing the latest {PAGE} of {total} dictations."), cx)))
}

fn empty_state(hotkey: &str, cx: &gpui_kit::App) -> impl IntoElement + use<> {
    let p = palette(cx);
    v_flex()
        .py(px(56.))
        .gap(space::L)
        .items_center()
        .border_1()
        .border_color(p.line)
        .child(
            h_flex().gap(space::S).items_center().child(
                div()
                    .px(space::M)
                    .h(px(40.))
                    .flex()
                    .items_center()
                    .border_1()
                    .border_b_2()
                    .border_color(p.line_strong)
                    .text_size(size::LEAD)
                    .child(hotkey.to_string())
                    .with_animation(
                        "empty-keycap",
                        Animation::new(Duration::from_millis(2400)).repeat(),
                        move |key, t| {
                            let pressed = (0.1..0.45).contains(&t);
                            key.border_color(if pressed { p.accent } else { p.line_strong }).mt(px(if pressed { 2. } else { 0. }))
                        },
                    ),
            ),
        )
        .child(div().text_size(size::BODY).text_color(p.text).child("Hold the hotkey, speak, let go."))
        .child(muted("Your dictations will collect here, grouped by day.", cx))
}

fn row(view: &MainView, transcript: Transcript, playing: Option<tick_core::id::SwiftUuid>, cx: &Context<MainView>) -> impl IntoElement + use<> {
    let p = palette(cx);
    let id = transcript.id;
    let key = SharedString::from(id.to_string());
    let is_playing = playing == Some(id);
    let silent = {
        let lower = transcript.text.to_lowercase();
        lower.contains("silence") || lower.contains("slince")
    };
    let copied = view.copied.as_ref() == Some(&key);
    let time = transcript.timestamp.to_local().format("%H:%M").to_string();
    let text = transcript.text.clone();
    let state = view.state.clone();
    let view_entity = cx.entity();
    let has_audio = transcript.has_audio;
    let expanded = view.expanded_rows.contains(&key);

    h_flex()
        .id(SharedString::from(format!("row-{key}")))
        .group("row")
        .w_full()
        .gap(space::L)
        .px(space::S)
        .py(px(10.))
        .items_start()
        .border_b_1()
        .border_color(p.line)
        .hover(move |s| s.bg(p.alpha(p.hover, 0.5)))
        .cursor_pointer()
        .on_click({
            let view_entity = view_entity.clone();
            let key = key.clone();
            move |_, _, cx| {
                view_entity.update(cx, |view, cx| {
                    if !view.expanded_rows.remove(&key) {
                        view.expanded_rows.insert(key.clone());
                    }
                    cx.notify();
                })
            }
        })
        .child(
            div()
                .flex_1().min_w_0()
                .text_size(size::BODY)
                .line_height(px(20.))
                .text_color(if silent { p.muted } else { p.text })
                .when(silent, |t| t.italic())
                // Two lines at rest; a click shows the whole dictation.
                .when(!expanded, |t| t.line_clamp(2).text_ellipsis())
                .child(transcript.text.clone()),
        )
        // The time rests on the right; hovering swaps it for the actions.
        .child(
            div().relative().flex_none().w(px(72.)).h(px(20.)).child(
                div()
                    .w_full()
                    .flex()
                    .justify_end()
                    .text_size(size::CAPTION)
                    .text_color(p.muted)
                    .group_hover("row", |s| s.opacity(0.0))
                    .when(is_playing || copied, |s| s.opacity(0.0))
                    .child(time),
            ).child(
            h_flex()
                .absolute()
                .right_0()
                .top(px(-4.))
                .gap(space::XXS)
                .on_mouse_down(gpui_kit::MouseButton::Left, |_, _, cx| cx.stop_propagation())
                .opacity(0.0)
                .group_hover("row", |s| s.opacity(1.0))
                .when(is_playing || copied, |s| s.opacity(1.0))
                .when(is_playing, |s| s.child(playing_bars(cx)))
                .child({
                    let view_entity = view_entity.clone();
                    let state = state.clone();
                    let key = key.clone();
                    div()
                        .id(SharedString::from(format!("copy-{key}")))
                        .size(px(28.))
                        .flex()
                        .items_center()
                        .justify_center()
                        .hover(move |s| s.bg(p.line))
                        .child(if copied {
                            drawn_check(SharedString::from(format!("copied-{key}")), true, px(16.), p.accent).into_any_element()
                        } else {
                            icon(Icon::Copy, px(15.), p.muted).into_any_element()
                        })
                        .on_click(move |_, _, cx| {
                            state.read(cx).copy_transcript(&text);
                            let key = key.clone();
                            view_entity.update(cx, |view, cx| {
                                view.copied = Some(key.clone());
                                cx.notify();
                                cx.spawn(async move |view, cx| {
                                    cx.background_executor().timer(Duration::from_millis(1500)).await;
                                    let _ = view.update(cx, |view, cx| {
                                        if view.copied.as_ref() == Some(&key) {
                                            view.copied = None;
                                            cx.notify();
                                        }
                                    });
                                })
                                .detach();
                            });
                        })
                })
                .child({
                    let state = state.clone();
                    Button::new(SharedString::from(format!("more-{key}")))
                        .ghost()
                        .small()
                        .icon(gpui_kit::component::Icon::empty().path(Icon::More.path()))
                        .dropdown_menu(move |menu, _, _| {
                            let play_state = state.clone();
                            let delete_state = state.clone();
                            menu.item(
                                PopupMenuItem::new(if is_playing { "Stop audio" } else { "Play audio" })
                                    .disabled(!has_audio)
                                    .on_click(move |_, _, cx| play_state.update(cx, |s, cx| s.toggle_playback(id, cx))),
                            )
                            .separator()
                            .item(PopupMenuItem::new("Delete").on_click(move |_, _, cx| delete_state.update(cx, |s, cx| s.delete_transcript(id, cx))))
                        })
                }),
            ),
        )
}

/// Four square bars bouncing while a recording plays.
fn playing_bars(cx: &gpui_kit::App) -> impl IntoElement + use<> {
    let p = palette(cx);
    h_flex().w(px(28.)).h(px(28.)).gap(px(2.)).items_center().justify_center().children((0..4).map(move |index| {
        div().w(px(3.)).bg(p.accent).with_animation(
            SharedString::from(format!("playing-{index}")),
            Animation::new(Duration::from_millis(900)).repeat(),
            move |bar, t| {
                let phase = (t * std::f32::consts::TAU + index as f32 * 1.1).sin() * 0.5 + 0.5;
                bar.h(px(4.0 + phase * 10.0))
            },
        )
    }))
}

/// 54802 → "54,802".
fn thousands(value: usize) -> String {
    let digits = value.to_string();
    let mut out = String::new();
    for (index, digit) in digits.chars().enumerate() {
        if index > 0 && (digits.len() - index) % 3 == 0 {
            out.push(',');
        }
        out.push(digit);
    }
    out
}
