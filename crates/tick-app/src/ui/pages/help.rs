//! Help: frequently asked questions and where Tick comes from.

use gpui_kit::base::{h_flex, v_flex};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    AnimationExt as _, Context, InteractiveElement as _, IntoElement, ParentElement as _, Radians,
    SharedString, SpringAnimation, StatefulInteractiveElement as _, Styled as _, Transformation,
    Window, div, px, svg,
};

use crate::sound::Cue;
use crate::ui::components::{SNAP, body, cue, eyebrow, muted, palette, title};
use crate::ui::icons::Icon;
use crate::ui::main_view::MainView;
use crate::ui::theme::{size, space};

const FAQ: [(&str, &str); 5] = [
    (
        "How do I show an AI agent a problem on screen?",
        "Press ⌥⇧S (Settings → Hotkey → Walkthrough) and talk while you click around. Hold ⇧ and drag to draw, ⇧-click to drop a numbered pin, ⌘Z to undo a mark, Esc to cancel. Press ⌥⇧S again: Tick pastes a contact sheet of keyframes and a timestamped transcript into the app in front. Needs Screen Recording permission.",
    ),
    (
        "How do I change the recording hotkey?",
        "Open Settings → Hotkey, click the keys, then press the combination you want. A single modifier such as ⌥ works best for push-to-talk.",
    ),
    (
        "Does Tick process audio offline?",
        "Yes. Speech recognition runs on your Mac with Core ML. AI formatting runs locally too, unless you add a Groq key in Settings → Intelligence.",
    ),
    (
        "Where are my recordings kept?",
        "In ~/Library/Application Support/com.dipxsy.Tick/Recordings. Settings → History controls how long audio is kept; transcripts are never auto-deleted.",
    ),
    (
        "How do I lock recording hands-free?",
        "Double-tap the hotkey. Recording continues until you press it again or hit Esc.",
    ),
];

pub fn render(view: &mut MainView, _: &mut Window, cx: &mut Context<MainView>) -> impl IntoElement {
    let p = palette(cx);
    let view_entity = cx.entity();
    v_flex()
        .gap(space::XXL)
        .child(
            v_flex()
                .gap(space::S)
                .child(title("Help", cx))
                .child(muted("Setting up and getting the most out of Tick.", cx)),
        )
        .child(
            v_flex()
                .gap(space::S)
                .child(eyebrow("Questions", cx))
                .child(v_flex().border_t_1().border_color(p.line).children(
                    FAQ.iter().enumerate().map(|(index, (question, answer))| {
                        let open = view.expanded_faq.contains(&index);
                        let view_entity = view_entity.clone();
                        v_flex()
                            .id(("faq", index))
                            .border_b_1()
                            .border_color(p.line)
                            .px(space::M)
                            .py(space::M)
                            .gap(space::S)
                            .hover(move |s| s.bg(p.hover))
                            .on_click(move |_, _, cx| {
                                cue(cx, if open { Cue::Close } else { Cue::Open });
                                view_entity.update(cx, |view, cx| {
                                    if !view.expanded_faq.remove(&index) {
                                        view.expanded_faq.insert(index);
                                    }
                                    cx.notify();
                                })
                            })
                            .child(
                                h_flex()
                                    .justify_between()
                                    .items_center()
                                    .child(body(*question, cx))
                                    .child(
                                        svg()
                                            .path(Icon::ChevronDown.path())
                                            .size(px(14.))
                                            .text_color(p.muted)
                                            .with_spring(
                                                SharedString::from(format!("faq-chevron-{index}")),
                                                SpringAnimation::new(SNAP).to(if open {
                                                    1.0f32
                                                } else {
                                                    0.0
                                                }),
                                                |chevron, t| {
                                                    chevron.with_transformation(
                                                        Transformation::rotate(Radians(
                                                            std::f32::consts::PI * t,
                                                        )),
                                                    )
                                                },
                                            ),
                                    ),
                            )
                            .when(open, |el| {
                                el.child(
                                    div()
                                        .text_size(size::BODY)
                                        .line_height(px(20.))
                                        .text_color(p.muted)
                                        .child(*answer),
                                )
                            })
                    }),
                )),
        )
        .child(
            v_flex()
                .gap(space::S)
                .child(eyebrow("About", cx))
                .child(muted("For problems or ideas, write to Deepanshu.", cx))
                .child(link(
                    "help-mail",
                    "dipxsy@duck.com",
                    "mailto:dipxsy@duck.com",
                    cx,
                )),
        )
}

fn link(
    id: &'static str,
    label: &'static str,
    url: &'static str,
    cx: &Context<MainView>,
) -> impl IntoElement {
    let p = palette(cx);
    div()
        .id(id)
        .text_size(size::BODY)
        .text_color(p.text)
        .border_b_1()
        .border_color(p.line_strong)
        .hover(move |s| s.border_color(p.accent).text_color(p.accent))
        .child(label)
        .on_click(move |_, _, cx| {
            cue(cx, Cue::Tap);
            crate::platform::workspace::open_url(url);
        })
}
