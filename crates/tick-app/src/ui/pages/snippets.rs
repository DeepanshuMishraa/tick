//! Snippets: say a short phrase, Tick types the full text.

use gpui_kit::base::{h_flex, v_flex};
use gpui_kit::component::input::{Input, Textarea};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    div, px, Context, InteractiveElement as _, IntoElement, ParentElement as _, SharedString,
    StatefulInteractiveElement as _, Styled as _, Window,
};

use super::dictionary::banner;
use crate::sound::Cue;
use crate::ui::components::{body, button, cue, eyebrow, icon, icon_button, muted, palette, title, Tone};
use crate::ui::icons::Icon;
use crate::ui::main_view::MainView;
use crate::ui::theme::{size, space};

pub fn render(view: &mut MainView, _: &mut Window, cx: &mut Context<MainView>) -> impl IntoElement {
    let p = palette(cx);
    let state_entity = view.state.clone();
    let view_entity = cx.entity();
    let state = view.state.read(cx);
    let query = view.snippet_search.read(cx).value().to_lowercase();
    let snippets: Vec<_> = state
        .settings
        .snippets
        .iter()
        .filter(|s| query.is_empty() || s.shortcut.to_lowercase().contains(&query) || s.content.to_lowercase().contains(&query))
        .cloned()
        .collect();

    let open_form = {
        let view_entity = view_entity.clone();
        move |_: &gpui_kit::ClickEvent, window: &mut Window, cx: &mut gpui_kit::App| {
            cue(cx, Cue::Open);
            view_entity.update(cx, |view, cx| {
                view.adding_snippet = true;
                view.snippet_shortcut.update(cx, |input, cx| input.focus(window, cx));
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
                .child(title("Snippets", cx))
                .child(button("add-snippet", "Add snippet", Tone::Primary, cx).on_click(open_form)),
        )
        .when(view.snippets_banner, |page| {
            let view_entity = view_entity.clone();
            page.child(banner(
                "snippets-banner",
                "The stuff you shouldn't have to re-type.",
                "Save links, addresses and bios once. Say the shortcut while dictating and Tick types the full text.",
                vec![
                    ("LinkedIn".into(), Some("linkedin.com/in/…".into())),
                    ("intro email".into(), Some("Hey, would love to…".into())),
                    ("my calendly link".into(), Some("calendly.com/you".into())),
                ],
                move |cx| view_entity.update(cx, |view, cx| {
                    view.snippets_banner = false;
                    cx.notify();
                }),
                cx,
            ))
        })
        .when(view.adding_snippet, |page| {
            let save = view_entity.clone();
            let cancel = view_entity.clone();
            page.child(
                v_flex()
                    .gap(space::M)
                    .p(space::L)
                    .border_1()
                    .border_color(p.text)
                    .child(eyebrow("Shortcut", cx))
                    .child(Input::new(&view.snippet_shortcut))
                    .child(eyebrow("Expands to", cx))
                    .child(Textarea::new(&view.snippet_content))
                    .child(
                        h_flex()
                            .justify_between()
                            .items_center()
                            .child(muted("Use \\n for a line break. Matching ignores case.", cx))
                            .child(
                                h_flex()
                                    .gap(space::S)
                                    .child(button("snippet-cancel", "Cancel", Tone::Ghost, cx).on_click(move |_, _, cx| {
                                        cue(cx, Cue::Close);
                                        cancel.update(cx, |view, cx| {
                                            view.adding_snippet = false;
                                            cx.notify();
                                        })
                                    }))
                                    .child(button("snippet-save", "Save", Tone::Primary, cx).on_click(move |_, window, cx| {
                                        save.update(cx, |view, cx| view.save_snippet(window, cx))
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
                .child(div().flex_1().min_w_0().child(Input::new(&view.snippet_search).appearance(false)))
                .border_b_1()
                .border_color(p.line)
                .pb(space::S),
        )
        .child(
            v_flex()
                .when(snippets.is_empty(), |list| {
                    list.child(div().py(space::XXL).flex().justify_center().child(muted(
                        if query.is_empty() { "No snippets yet." } else { "No snippets match." },
                        cx,
                    )))
                })
                .children(snippets.into_iter().map(|snippet| {
                    let id = snippet.id;
                    let copy_entity = state_entity.clone();
                    let delete_entity = state_entity.clone();
                    let content = snippet.content.clone();
                    h_flex()
                        .id(SharedString::from(format!("snippet-{id}")))
                        .group("snippet")
                        .gap(space::L)
                        .px(space::M)
                        .py(space::M)
                        .items_start()
                        .border_b_1()
                        .border_color(p.line)
                        .hover(move |s| s.bg(p.hover))
                        .child(div().w(px(180.)).flex_none().child(body(snippet.shortcut.clone(), cx)))
                        .child(div().pt(px(3.)).child(icon(Icon::ArrowRight, px(14.), p.muted)))
                        .child(div().flex_1().min_w_0().text_size(size::BODY).text_color(p.muted).child(snippet.content.clone()))
                        .child(
                            h_flex()
                                .opacity(0.0)
                                .group_hover("snippet", |s| s.opacity(1.0))
                                .child(icon_button(SharedString::from(format!("snippet-copy-{id}")), Icon::Copy, p.muted, cx).on_click(
                                    move |_, _, cx| copy_entity.update(cx, |state, cx| state.copy_and_confirm(&content, cx)),
                                ))
                                .child(icon_button(SharedString::from(format!("snippet-delete-{id}")), Icon::Trash, p.muted, cx).on_click(
                                    move |_, _, cx| {
                                        delete_entity.update(cx, |state, cx| {
                                            state.update_settings(cx, |s| s.snippets.retain(|x| x.id != id));
                                            state.play_sound(Cue::Close);
                                        })
                                    },
                                )),
                        )
                })),
        )
}
