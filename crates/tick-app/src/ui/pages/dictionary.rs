//! Dictionary: spoken → written replacements, learned automatically from
//! corrections or added by hand, plus optional filler removal.

use gpui_kit::base::{h_flex, v_flex};
use gpui_kit::component::input::Input;
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    AnimationExt as _, Context, InteractiveElement as _, IntoElement, ParentElement as _,
    SharedString, SpringAnimation, StatefulInteractiveElement as _, Styled as _, Window, div, px,
};

use crate::sound::Cue;
use crate::ui::components::{
    SNAP, Tone, body, button, cue, eyebrow, icon, icon_button, muted, palette, title, toggle,
};
use crate::ui::icons::Icon;
use crate::ui::main_view::MainView;
use crate::ui::theme::{size, space};

pub fn banner(
    id: &'static str,
    heading: &str,
    text: &str,
    examples: Vec<(String, Option<String>)>,
    on_dismiss: impl Fn(&mut gpui_kit::App) + 'static,
    cx: &Context<MainView>,
) -> impl IntoElement {
    let p = palette(cx);
    v_flex()
        .gap(space::M)
        .p(space::L)
        .border_1()
        .border_color(p.line)
        .border_l_2()
        .border_color(p.accent)
        .with_spring(
            id,
            SpringAnimation::new(SNAP).to(1.0f32).from(0.0f32),
            |el, t| el.opacity(t.clamp(0.0, 1.0)),
        )
        .child(
            h_flex()
                .justify_between()
                .items_center()
                .child(
                    div()
                        .text_size(size::LEAD)
                        .text_color(p.text)
                        .child(heading.to_string()),
                )
                .child(
                    icon_button(
                        SharedString::from(format!("{id}-dismiss")),
                        Icon::Close,
                        p.muted,
                        cx,
                    )
                    .on_click(move |_, _, cx| {
                        cue(cx, Cue::Close);
                        on_dismiss(cx);
                    }),
                ),
        )
        .child(muted(text.to_string(), cx))
        .child(
            h_flex()
                .flex_wrap()
                .gap(space::S)
                .children(examples.into_iter().map(|(from, to)| {
                    h_flex()
                        .gap(space::S)
                        .px(space::S)
                        .py(px(4.))
                        .border_1()
                        .border_color(p.line_strong)
                        .text_size(size::CAPTION)
                        .text_color(p.text)
                        .child(from)
                        .when_some(to, |el, to| {
                            el.child(icon(Icon::ArrowRight, px(11.), p.muted)).child(to)
                        })
                })),
        )
}

pub fn render(view: &mut MainView, _: &mut Window, cx: &mut Context<MainView>) -> impl IntoElement {
    let p = palette(cx);
    let state_entity = view.state.clone();
    let view_entity = cx.entity();
    let state = view.state.read(cx);
    let query = view.dictionary_search.read(cx).value().to_lowercase();
    let remappings: Vec<_> = state
        .settings
        .word_remappings
        .iter()
        .filter(|r| {
            query.is_empty()
                || r.match_text.to_lowercase().contains(&query)
                || r.replacement.to_lowercase().contains(&query)
        })
        .cloned()
        .collect();
    let removals_enabled = state.settings.word_removals_enabled;
    let removals = state.settings.word_removals.clone();

    let open_form = {
        let view_entity = view_entity.clone();
        move |_: &gpui_kit::ClickEvent, window: &mut Window, cx: &mut gpui_kit::App| {
            cue(cx, Cue::Open);
            view_entity.update(cx, |view, cx| {
                view.adding_word = true;
                view.word_match
                    .update(cx, |input, cx| input.focus(window, cx));
                cx.notify();
            });
        }
    };

    v_flex()
        .gap(space::XL)
        .child(
            h_flex()
                .justify_between()
                .items_center()
                .child(title("Dictionary", cx))
                .child(button("add-word", "Add word", Tone::Primary, cx).on_click(open_form.clone())),
        )
        .when(view.dictionary_banner, |page| {
            let view_entity = view_entity.clone();
            page.child(banner(
                "dictionary-banner",
                "Tick speaks the way you speak.",
                "Correct a word after Tick types it and the fix is learned automatically. Add names, jargon and spellings of your own here.",
                vec![
                    ("Q3 Roadmap".into(), None),
                    ("Whispr".into(), Some("Wisper".into())),
                    ("SF MOMA".into(), None),
                    ("Figma Jam".into(), None),
                ],
                move |cx| view_entity.update(cx, |view, cx| {
                    view.dictionary_banner = false;
                    cx.notify();
                }),
                cx,
            ))
        })
        .when(view.adding_word, |page| {
            let save = view_entity.clone();
            let cancel = view_entity.clone();
            page.child(
                v_flex()
                    .gap(space::M)
                    .p(space::L)
                    .border_1()
                    .border_color(p.text)
                    .child(eyebrow("New word", cx))
                    .child(
                        h_flex()
                            .gap(space::M)
                            .items_center()
                            .child(div().flex_1().min_w_0().child(Input::new(&view.word_match)))
                            .child(icon(Icon::ArrowRight, px(16.), p.muted))
                            .child(div().flex_1().min_w_0().child(Input::new(&view.word_replacement))),
                    )
                    .child(
                        h_flex()
                            .justify_between()
                            .items_center()
                            .child(muted("Matching ignores case and only replaces whole words.", cx))
                            .child(
                                h_flex()
                                    .gap(space::S)
                                    .child(button("word-cancel", "Cancel", Tone::Ghost, cx).on_click(move |_, _, cx| {
                                        cue(cx, Cue::Close);
                                        cancel.update(cx, |view, cx| {
                                            view.adding_word = false;
                                            cx.notify();
                                        })
                                    }))
                                    .child(button("word-save", "Save", Tone::Primary, cx).on_click(move |_, window, cx| {
                                        save.update(cx, |view, cx| view.save_word(window, cx))
                                    })),
                            ),
                    ),
            )
        })
        .child(
            h_flex()
                .gap(space::S)
                .items_center()
                .child(icon(Icon::Search, px(15.), p.muted))
                .child(div().flex_1().min_w_0().child(Input::new(&view.dictionary_search).appearance(false)))
                .border_b_1()
                .border_color(p.line)
                .pb(space::S),
        )
        .child(
            v_flex()
                .when(remappings.is_empty(), |list| {
                    list.child(div().py(space::XXL).flex().justify_center().child(muted(
                        if query.is_empty() { "No words yet. Correct a dictation or add one above." } else { "No words match." },
                        cx,
                    )))
                })
                .children(remappings.into_iter().map(|remapping| {
                    let id = remapping.id;
                    let entity = state_entity.clone();
                    h_flex()
                        .id(SharedString::from(format!("word-{id}")))
                        .group("word")
                        .gap(space::L)
                        .px(space::M)
                        .py(space::M)
                        .items_center()
                        .border_b_1()
                        .border_color(p.line)
                        .hover(move |s| s.bg(p.hover))
                        .when(!remapping.is_enabled, |row| row.opacity(0.5))
                        .child(div().flex_1().min_w_0().child(body(remapping.match_text.clone(), cx)))
                        .child(icon(Icon::ArrowRight, px(14.), p.muted))
                        .child(div().flex_1().min_w_0().child(body(remapping.replacement.clone(), cx)))
                        .child(
                            div().opacity(0.0).group_hover("word", |s| s.opacity(1.0)).child(
                                icon_button(SharedString::from(format!("word-delete-{id}")), Icon::Trash, p.muted, cx).on_click(move |_, _, cx| {
                                    entity.update(cx, |state, cx| {
                                        state.update_settings(cx, |s| s.word_remappings.retain(|r| r.id != id));
                                        state.play_sound(Cue::Close);
                                    })
                                }),
                            ),
                        )
                })),
        )
        .child(
            v_flex()
                .gap(space::M)
                .pt(space::L)
                .child(
                    h_flex()
                        .justify_between()
                        .items_center()
                        .child(
                            v_flex()
                                .gap(px(3.))
                                .child(eyebrow("Filler removal", cx))
                                .child(body("Strip hesitations before formatting", cx))
                                .child(muted("Each entry is a pattern; + repeats the letter (um+ matches umm).", cx)),
                        )
                        .child({
                            let entity = state_entity.clone();
                            toggle("removals", removals_enabled, true, move |on, _, cx| {
                                entity.update(cx, |state, cx| state.update_settings(cx, |s| s.word_removals_enabled = on))
                            }, cx)
                        }),
                )
                .when(removals_enabled, |el| {
                    el.child(h_flex().flex_wrap().gap(space::S).children(removals.into_iter().map(|removal| {
                        let id = removal.id;
                        let entity = state_entity.clone();
                        h_flex()
                            .id(SharedString::from(format!("removal-{id}")))
                            .gap(space::XS)
                            .pl(space::S)
                            .border_1()
                            .border_color(p.line_strong)
                            .text_size(size::CAPTION)
                            .child(removal.pattern.clone())
                            .child(icon_button(SharedString::from(format!("removal-x-{id}")), Icon::Close, p.muted, cx).on_click(move |_, _, cx| {
                                entity.update(cx, |state, cx| state.update_settings(cx, |s| s.word_removals.retain(|r| r.id != id)))
                            }))
                    })))
                }),
        )
}
