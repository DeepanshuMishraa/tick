//! Insights: totals, speed, a square-cell activity heatmap, weekday rhythm,
//! and the apps dictated into most.

use chrono::{Datelike, Duration, NaiveDate};
use gpui_kit::base::{h_flex, v_flex};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    AnimationExt as _, Context, FontWeight, InteractiveElement as _, IntoElement,
    ParentElement as _, SharedString, SpringAnimation, StatefulInteractiveElement as _,
    Styled as _, Window, div, img, px, relative,
};
use tick_core::stats::{add_months, hours_saved, month_start, months_between};

use crate::sound::Cue;
use crate::ui::components::{GLIDE, cue, eyebrow, icon, muted, palette};
use crate::ui::icons::Icon;
use crate::ui::main_view::MainView;
use crate::ui::theme::{size, space};

const CELL: f32 = 12.0;
const GAP: f32 = 3.0;
const MONTHS_PER_PAGE: i32 = 3;

fn card(cx: &Context<MainView>) -> gpui_kit::Div {
    let p = palette(cx);
    v_flex()
        .p(space::L)
        .gap(space::S)
        .border_1()
        .border_color(p.line)
        .bg(p.surface)
}

fn number(value: impl Into<SharedString>, cx: &Context<MainView>) -> gpui_kit::Div {
    div()
        .text_size(px(26.))
        .font_weight(FontWeight::MEDIUM)
        .text_color(palette(cx).text)
        .child(value.into())
}

fn grouped(value: usize) -> String {
    let digits = value.to_string();
    let mut out = String::new();
    for (index, ch) in digits.chars().enumerate() {
        if index > 0 && (digits.len() - index) % 3 == 0 {
            out.push(',');
        }
        out.push(ch);
    }
    out
}

pub fn render(view: &mut MainView, _: &mut Window, cx: &mut Context<MainView>) -> impl IntoElement {
    let p = palette(cx);
    let digest = view.digest(cx);
    let today = digest.today;
    let home = &digest.home;
    let data = &digest.insights;
    let (current_streak, longest_streak) = data.streaks(today);
    let effective_wpm = if home.average_wpm > 0 {
        home.average_wpm
    } else {
        130
    };
    let pages = (home.word_count / 250).max(1);
    let best = data.best_day();
    let saved = hours_saved(home.word_count, effective_wpm);
    let multiplier = effective_wpm.max(40) as f32 / 40.0;

    let first_month = month_start(data.first_day.unwrap_or(today));
    let current_month = month_start(today);
    let max_page = (months_between(first_month, current_month) / MONTHS_PER_PAGE).max(0);
    let page = view.heatmap_page.unwrap_or(max_page).clamp(0, max_page);
    let start_month = add_months(first_month, page * MONTHS_PER_PAGE);
    let end_month = add_months(start_month, MONTHS_PER_PAGE - 1).min(current_month);
    let end_date = (add_months(end_month, 1) - Duration::days(1)).min(today);
    let grid_start =
        start_month - Duration::days(i64::from(start_month.weekday().num_days_from_sunday()));
    let grid_end =
        end_date + Duration::days(i64::from(6 - end_date.weekday().num_days_from_sunday()));
    let user_start = data.first_day.unwrap_or(today);
    let max_words = {
        let mut day = grid_start;
        let mut max = 1;
        while day <= grid_end {
            max = max.max(data.words_by_day.get(&day).copied().unwrap_or(0));
            day += Duration::days(1);
        }
        max
    };
    let mut weeks: Vec<Vec<(NaiveDate, usize, bool)>> = Vec::new();
    let mut day = grid_start;
    while day <= grid_end {
        if day.weekday().num_days_from_sunday() == 0 {
            weeks.push(Vec::new());
        }
        let words = data.words_by_day.get(&day).copied().unwrap_or(0);
        let unavailable = day < user_start || day > today;
        if let Some(week) = weeks.last_mut() {
            week.push((day, words, unavailable));
        }
        day += Duration::days(1);
    }
    let range_label = format!(
        "{} – {}",
        start_month.format("%b %Y"),
        end_month.format("%b %Y")
    );
    let view_entity = cx.entity();
    let pager = |id: &'static str, glyph: Icon, target: i32, enabled: bool| {
        let view_entity = view_entity.clone();
        div()
            .id(id)
            .size(px(26.))
            .flex()
            .items_center()
            .justify_center()
            .border_1()
            .border_color(p.line)
            .when(!enabled, |s| s.opacity(0.35))
            .when(enabled, |s| {
                s.hover(move |s| s.border_color(p.text))
                    .on_click(move |_, _, cx| {
                        cue(cx, Cue::Navigate);
                        view_entity.update(cx, |view, cx| {
                            view.heatmap_page = Some(target);
                            cx.notify();
                        })
                    })
            })
            .child(icon(glyph, px(14.), p.text))
    };

    let weekday_totals = data.weekday_totals();
    let weekday_max = weekday_totals.iter().copied().max().unwrap_or(0).max(1);
    let weekday_names = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
    let peak = weekday_totals
        .iter()
        .enumerate()
        .max_by_key(|(_, words)| **words)
        .filter(|(_, w)| **w > 0)
        .map(|(i, _)| weekday_names[i]);
    let app_total = data.top_apps.iter().map(|a| a.words).sum::<usize>().max(1);
    let app_max = data
        .top_apps
        .iter()
        .map(|a| a.words)
        .max()
        .unwrap_or(1)
        .max(1);
    let top_apps = data.top_apps.clone();
    let unique_apps = home.unique_apps;
    let level = move |words: usize| -> f32 {
        if words == 0 {
            return 0.0;
        }
        match words as f32 / max_words as f32 {
            r if r >= 0.75 => 1.0,
            r if r >= 0.5 => 0.75,
            r if r >= 0.25 => 0.5,
            _ => 0.25,
        }
    };
    let icons: Vec<Option<std::sync::Arc<gpui_kit::Image>>> = top_apps
        .iter()
        .map(|app| {
            app.bundle_id.as_ref().and_then(|id| {
                view.app_icons
                    .entry(id.clone())
                    .or_insert_with(|| {
                        crate::platform::workspace::app_icon_png(id, 32.0)
                            .map(crate::state::png_image)
                    })
                    .clone()
            })
        })
        .collect();

    v_flex()
        .gap(space::XL)
        .child(crate::ui::components::title("Insights", cx))
        .child(
            h_flex().gap(space::M).children(
                [
                    (
                        "Words spoken",
                        grouped(home.word_count),
                        if home.word_count == 0 {
                            "No dictations yet".to_string()
                        } else {
                            format!("{} recordings · ~{pages} pages", grouped(digest.total))
                        },
                        Icon::Words,
                    ),
                    (
                        "Active streak",
                        format!(
                            "{current_streak} {}",
                            if current_streak == 1 { "day" } else { "days" }
                        ),
                        if longest_streak > 1 {
                            format!("Longest: {longest_streak} days")
                        } else {
                            "Daily activity".into()
                        },
                        Icon::Flame,
                    ),
                    (
                        "Speaking speed",
                        format!("{effective_wpm} wpm"),
                        format!("{multiplier:.1}× faster than typing"),
                        Icon::Gauge,
                    ),
                    (
                        "Peak day",
                        best.map_or("—".into(), |(_, words)| grouped(words)),
                        best.map_or("No daily record yet".into(), |(date, _)| {
                            date.format("%-d %b").to_string()
                        }),
                        Icon::Trophy,
                    ),
                ]
                .into_iter()
                .map(|(label, value, detail, glyph)| {
                    card(cx)
                        .flex_1()
                        .min_w_0()
                        .child(
                            h_flex()
                                .justify_between()
                                .child(eyebrow(label, cx))
                                .child(icon(glyph, px(14.), p.muted)),
                        )
                        .child(number(value, cx))
                        .child(muted(detail, cx))
                }),
            ),
        )
        .child(
            card(cx)
                .child(eyebrow("Typing vs. dictation", cx))
                .child(muted(
                    if home.word_count > 0 {
                        format!("About {saved:.1} hours saved compared with typing at 40 wpm.")
                    } else {
                        "Start dictating to see how much time you save over typing.".into()
                    },
                    cx,
                ))
                .child(
                    v_flex().pt(space::S).gap(space::S).children(
                        [
                            ("Keyboard", 40usize, p.line_strong),
                            ("Voice", effective_wpm, p.accent),
                        ]
                        .map(|(label, wpm, color)| {
                            h_flex()
                                .gap(space::M)
                                .items_center()
                                .child(
                                    div()
                                        .w(px(72.))
                                        .text_size(size::CAPTION)
                                        .text_color(p.muted)
                                        .child(label),
                                )
                                .child(
                                    div().flex_1().min_w_0().h(px(8.)).child(
                                        div().h_full().bg(color).with_spring(
                                            SharedString::from(format!("speed-{label}")),
                                            SpringAnimation::new(GLIDE)
                                                .to(wpm as f32 / effective_wpm.max(40) as f32)
                                                .from(0.0f32),
                                            |bar, t| bar.w(relative(t.clamp(0.0, 1.0))),
                                        ),
                                    ),
                                )
                                .child(
                                    div()
                                        .w(px(64.))
                                        .text_size(size::CAPTION)
                                        .text_color(p.text)
                                        .child(format!("{wpm} wpm")),
                                )
                        }),
                    ),
                ),
        )
        .child(
            card(cx)
                .gap(space::L)
                .child(
                    h_flex()
                        .justify_between()
                        .items_center()
                        .child(
                            v_flex()
                                .gap(px(2.))
                                .child(eyebrow("Daily activity", cx))
                                .child(muted("Three months at a time", cx)),
                        )
                        .child(
                            h_flex()
                                .gap(space::S)
                                .items_center()
                                .child(pager("heatmap-back", Icon::ChevronLeft, page - 1, page > 0))
                                .child(
                                    div()
                                        .w(px(150.))
                                        .text_size(size::CAPTION)
                                        .text_color(p.text)
                                        .flex()
                                        .justify_center()
                                        .child(range_label),
                                )
                                .child(pager(
                                    "heatmap-forward",
                                    Icon::ChevronRight,
                                    page + 1,
                                    page < max_page,
                                )),
                        ),
                )
                .child(
                    h_flex()
                        .gap(px(GAP))
                        .child(v_flex().gap(px(GAP)).mr(space::S).children(
                            ["S", "M", "T", "W", "T", "F", "S"].map(|d| {
                                div()
                                    .h(px(CELL))
                                    .text_size(px(9.))
                                    .text_color(p.faint)
                                    .child(d)
                            }),
                        ))
                        .children(weeks.into_iter().enumerate().map(|(week_index, week)| {
                            v_flex()
                                .gap(px(GAP))
                                .children(week.into_iter().enumerate().map(
                                    move |(day_index, (_, words, unavailable))| {
                                        let intensity = level(words);
                                        div()
                                            .size(px(CELL))
                                            .bg(if unavailable {
                                                p.alpha(p.line, 0.35)
                                            } else if intensity == 0.0 {
                                                p.line
                                            } else {
                                                p.alpha(p.accent, intensity)
                                            })
                                            .with_spring(
                                                SharedString::from(format!(
                                                    "cell-{week_index}-{day_index}"
                                                )),
                                                SpringAnimation::new(GLIDE).to(1.0f32).from(0.0f32),
                                                |cell, t| cell.opacity(t.clamp(0.0, 1.0)),
                                            )
                                    },
                                ))
                        })),
                )
                .child(
                    h_flex()
                        .justify_between()
                        .child(
                            h_flex()
                                .gap(px(4.))
                                .items_center()
                                .child(muted("Less", cx))
                                .children([0.0f32, 0.25, 0.5, 0.75, 1.0].map(|a| {
                                    div().size(px(10.)).bg(if a == 0.0 {
                                        p.line
                                    } else {
                                        p.alpha(p.accent, a)
                                    })
                                }))
                                .child(muted("More", cx)),
                        )
                        .child(muted(
                            format!(
                                "{current_streak}-day streak · {} words",
                                grouped(home.word_count)
                            ),
                            cx,
                        )),
                ),
        )
        .child(
            h_flex()
                .gap(space::M)
                .items_start()
                .child(
                    card(cx)
                        .flex_1()
                        .min_w_0()
                        .child(
                            h_flex()
                                .justify_between()
                                .child(eyebrow("By weekday", cx))
                                .when_some(peak, |el, peak| {
                                    el.child(muted(format!("Peak: {peak}"), cx))
                                }),
                        )
                        .child(v_flex().pt(space::S).gap(space::S).children(
                            weekday_totals.iter().enumerate().map(|(index, words)| {
                                let is_peak = *words == weekday_max && *words > 0;
                                h_flex()
                                    .gap(space::M)
                                    .items_center()
                                    .child(
                                        div()
                                            .w(px(32.))
                                            .text_size(size::CAPTION)
                                            .text_color(p.muted)
                                            .child(weekday_names[index]),
                                    )
                                    .child(
                                        div().flex_1().min_w_0().h(px(6.)).bg(p.line).child(
                                            div()
                                                .h_full()
                                                .bg(if is_peak {
                                                    p.accent
                                                } else {
                                                    p.alpha(p.accent, 0.45)
                                                })
                                                .with_spring(
                                                    SharedString::from(format!("weekday-{index}")),
                                                    SpringAnimation::new(GLIDE)
                                                        .to(*words as f32 / weekday_max as f32)
                                                        .from(0.0f32),
                                                    |bar, t| bar.w(relative(t.clamp(0.0, 1.0))),
                                                ),
                                        ),
                                    )
                                    .child(
                                        div()
                                            .w(px(56.))
                                            .text_size(size::CAPTION)
                                            .text_color(p.text)
                                            .child(grouped(*words)),
                                    )
                            }),
                        )),
                )
                .child(
                    card(cx)
                        .flex_1()
                        .min_w_0()
                        .child(
                            h_flex()
                                .justify_between()
                                .child(eyebrow("Top apps", cx))
                                .child(muted(
                                    format!(
                                        "{unique_apps} {}",
                                        if unique_apps == 1 { "app" } else { "apps" }
                                    ),
                                    cx,
                                )),
                        )
                        .when(top_apps.is_empty(), |el| {
                            el.child(
                                div()
                                    .py(space::XL)
                                    .child(muted("Apps appear here as you dictate into them.", cx)),
                            )
                        })
                        .children(top_apps.into_iter().zip(icons).enumerate().map(
                            |(index, (app, app_icon))| {
                                let share = (app.words as f32 / app_total as f32 * 100.0).round();
                                v_flex()
                                    .pt(space::S)
                                    .gap(px(5.))
                                    .child(
                                        h_flex()
                                            .gap(space::S)
                                            .items_center()
                                            .child(match app_icon {
                                                Some(image) => {
                                                    img(image).size(px(16.)).into_any_element()
                                                }
                                                None => div()
                                                    .size(px(16.))
                                                    .border_1()
                                                    .border_color(p.line_strong)
                                                    .into_any_element(),
                                            })
                                            .child(
                                                div()
                                                    .flex_1()
                                                    .min_w_0()
                                                    .text_size(size::CAPTION)
                                                    .text_color(p.text)
                                                    .truncate()
                                                    .child(app.name.clone()),
                                            )
                                            .child(
                                                div()
                                                    .text_size(size::CAPTION)
                                                    .text_color(p.muted)
                                                    .child(format!("{share:.0}%")),
                                            ),
                                    )
                                    .child(
                                        div().h(px(4.)).bg(p.line).child(
                                            div().h_full().bg(p.sequence(index, 5)).with_spring(
                                                SharedString::from(format!("app-{index}")),
                                                SpringAnimation::new(GLIDE)
                                                    .to(app.words as f32 / app_max as f32)
                                                    .from(0.0f32),
                                                |bar, t| bar.w(relative(t.clamp(0.0, 1.0))),
                                            ),
                                        ),
                                    )
                            },
                        )),
                ),
        )
}
