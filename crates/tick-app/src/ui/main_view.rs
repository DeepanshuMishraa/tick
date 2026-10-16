//! The main window: onboarding, permission repair, or the sidebar shell.

use std::collections::HashSet;

use gpui_kit::base::{h_flex, v_flex};
use gpui_kit::component::input::InputState;
use gpui_kit::component::slider::{SliderEvent, SliderState};
use gpui_kit::component::input::{InputEvent, TextareaState};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    div, px, AnimationExt as _, AppContext as _, Context, Entity, InteractiveElement as _, IntoElement,
    ParentElement as _, Render, SharedString, SpringAnimation, StatefulInteractiveElement as _, Styled as _,
    Subscription, Window,
};
use tick_core::constants::BASE_SOUND_EFFECTS_VOLUME;

use super::components::{icon, icon_button, palette, SNAP};
use super::icons::Icon;
use super::pages;
use super::theme::{size, space, SIDEBAR_WIDTH};
use crate::state::{AppState, Tab};

const ROW_HEIGHT: f32 = 30.0;
/// From this window width pages get their full side margins.
const ROOMY_ABOVE: f32 = 860.0;
/// Height of the top band; the traffic lights (at y 18, 14 px tall) sit on
/// its centre line.
const TITLEBAR_HEIGHT: f32 = 50.0;
/// Where content may start to the right of the traffic lights.
const TRAFFIC_LIGHTS_END: f32 = 84.0;

/// Retained view-local state for the pages (inputs, disclosure flags).
pub struct MainView {
    pub state: Entity<AppState>,
    pub dictionary_search: Entity<InputState>,
    pub word_match: Entity<InputState>,
    pub word_replacement: Entity<InputState>,
    pub snippet_search: Entity<InputState>,
    pub snippet_shortcut: Entity<InputState>,
    pub snippet_content: Entity<TextareaState>,
    pub groq_key: Entity<InputState>,
    pub minimum_hold: Entity<SliderState>,
    pub volume: Entity<SliderState>,
    pub dictionary_banner: bool,
    pub snippets_banner: bool,
    pub adding_word: bool,
    pub adding_snippet: bool,
    pub heatmap_page: Option<i32>,
    pub expanded_faq: HashSet<usize>,
    pub confirm_delete_all: bool,
    pub onboarding_step: usize,
    pub copied: Option<SharedString>,
    /// Home transcript rows shown in full instead of clamped.
    pub expanded_rows: HashSet<SharedString>,
    /// App icons by bundle id, rendered once.
    pub app_icons: std::collections::HashMap<String, Option<std::sync::Arc<gpui_kit::Image>>>,
    /// History-derived stats, rebuilt only when the history changes.
    digest: Option<std::rc::Rc<HistoryDigest>>,
    _subscriptions: Vec<Subscription>,
}

impl MainView {
    pub fn new(state: Entity<AppState>, window: &mut Window, cx: &mut Context<Self>) -> MainView {
        let input = |placeholder: &'static str, window: &mut Window, cx: &mut Context<Self>| {
            cx.new(|cx| InputState::new(window, cx).placeholder(placeholder))
        };
        let dictionary_search = input("Search words", window, cx);
        let word_match = input("Spoken, e.g. whispr", window, cx);
        let word_replacement = input("Written, e.g. Whisper", window, cx);
        let snippet_search = input("Search snippets", window, cx);
        let snippet_shortcut = input("Say this, e.g. my calendly link", window, cx);
        let snippet_content = cx.new(|cx| TextareaState::new(window, cx).auto_grow(2, 6).placeholder("…and Tick types this"));
        let key = state.read(cx).groq_key.clone();
        let groq_key = cx.new(|cx| InputState::new(window, cx).masked(true).placeholder("gsk_…").default_value(key));
        let settings = state.read(cx).settings.clone();
        let minimum_hold = cx.new(|_| {
            SliderState::new().min(0.0).max(2.0).step(0.1).default_value(settings.minimum_key_time as f32)
        });
        let volume = cx.new(|_| {
            SliderState::new()
                .min(0.0)
                .max(1.0)
                .step(0.01)
                .default_value((settings.sound_effects_volume / BASE_SOUND_EFFECTS_VOLUME).clamp(0.0, 1.0) as f32)
        });

        let mut subscriptions = vec![cx.observe(&state, |_, _, cx| cx.notify())];
        for search in [&dictionary_search, &snippet_search] {
            subscriptions.push(cx.subscribe(search, |_, _, event: &InputEvent, cx| {
                if matches!(event, InputEvent::Change) {
                    cx.notify();
                }
            }));
        }
        subscriptions.push(cx.subscribe(&groq_key, |this, input, event: &InputEvent, cx| {
            if matches!(event, InputEvent::Change) {
                let key = input.read(cx).value().to_string();
                this.state.update(cx, |state, cx| state.set_groq_key(key, cx));
            }
        }));
        subscriptions.push(cx.subscribe(&minimum_hold, |this, _, event: &SliderEvent, cx| {
            let SliderEvent::Change(value) = event else { return };
            let seconds = (f64::from(value.start()) * 10.0).round() / 10.0;
            this.state.update(cx, |state, cx| state.update_settings(cx, |s| s.minimum_key_time = seconds));
        }));
        subscriptions.push(cx.subscribe(&volume, |this, _, event: &SliderEvent, cx| {
            let SliderEvent::Change(value) = event else { return };
            let fraction = f64::from(value.start());
            this.state.update(cx, |state, cx| {
                state.update_settings(cx, |s| s.sound_effects_volume = fraction * BASE_SOUND_EFFECTS_VOLUME)
            });
        }));
        for (field, submit) in [(&word_match, false), (&word_replacement, true)] {
            subscriptions.push(cx.subscribe_in(field, window, move |this, _, event: &InputEvent, window, cx| {
                if submit && matches!(event, InputEvent::PressEnter { .. }) {
                    this.save_word(window, cx);
                }
            }));
        }
        subscriptions.push(cx.subscribe_in(&snippet_shortcut, window, |this, _, event: &InputEvent, window, cx| {
            if matches!(event, InputEvent::PressEnter { .. }) {
                this.snippet_content.update(cx, |state, cx| state.focus(window, cx));
            }
        }));

        MainView {
            state,
            dictionary_search,
            word_match,
            word_replacement,
            snippet_search,
            snippet_shortcut,
            snippet_content,
            groq_key,
            minimum_hold,
            volume,
            dictionary_banner: true,
            snippets_banner: true,
            adding_word: false,
            adding_snippet: false,
            heatmap_page: None,
            expanded_faq: HashSet::new(),
            confirm_delete_all: false,
            onboarding_step: 0,
            copied: None,
            expanded_rows: HashSet::new(),
            app_icons: std::collections::HashMap::new(),
            digest: None,
            _subscriptions: subscriptions,
        }
    }

    pub fn save_word(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let spoken = self.word_match.read(cx).value().trim().to_string();
        let written = self.word_replacement.read(cx).value().trim().to_string();
        if spoken.is_empty() || written.is_empty() {
            return;
        }
        self.state.update(cx, |state, cx| {
            state.update_settings(cx, |s| s.word_remappings.insert(0, tick_core::text::WordRemapping::new(spoken, written)));
            state.play_sound(crate::sound::Cue::Success);
        });
        for field in [&self.word_match, &self.word_replacement] {
            field.update(cx, |input, cx| input.set_value("", window, cx));
        }
        self.adding_word = false;
        cx.notify();
    }

    pub fn save_snippet(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let shortcut = self.snippet_shortcut.read(cx).value().trim().to_string();
        let content = self.snippet_content.read(cx).value().trim().to_string();
        if shortcut.is_empty() || content.is_empty() {
            return;
        }
        self.state.update(cx, |state, cx| {
            state.update_settings(cx, |s| s.snippets.insert(0, tick_core::text::Snippet::new(shortcut, content)));
            state.play_sound(crate::sound::Cue::Success);
        });
        self.snippet_shortcut.update(cx, |input, cx| input.set_value("", window, cx));
        self.snippet_content.update(cx, |input, cx| input.set_value("", window, cx));
        self.adding_snippet = false;
        cx.notify();
    }

    /// The source list. Collapsing slides it fully out of view, as Notes and
    /// Finder do; the toggle stays beside the traffic lights.
    fn sidebar(&self, cx: &Context<Self>) -> impl IntoElement {
        let p = palette(cx);
        let state = self.state.read(cx);
        let active = state.tab;
        let collapsed = state.settings.sidebar_collapsed;
        let primary = [
            (Tab::Home, Icon::Home),
            (Tab::Insights, Icon::Insights),
            (Tab::Dictionary, Icon::Dictionary),
            (Tab::Snippets, Icon::Snippets),
            (Tab::Style, Icon::Style),
        ];
        let secondary = [(Tab::Settings, Icon::Settings), (Tab::Help, Icon::Help)];
        let item = |tab: Tab, glyph: Icon| {
            let selected = tab == active;
            let entity = self.state.clone();
            h_flex()
                .id(SharedString::from(format!("nav-{}", tab.title())))
                .h(px(ROW_HEIGHT))
                .px(space::S)
                .gap(space::S)
                .items_center()
                .whitespace_nowrap()
                .text_size(size::BODY)
                .text_color(if selected { p.text } else { p.muted })
                .when(selected, |row| row.bg(p.hover))
                .when(!selected, |row| row.hover(move |s| s.text_color(p.text)))
                .child(icon(glyph, px(15.), if selected { p.text } else { p.muted }))
                .child(tab.title())
                .on_click(move |_, _, cx| entity.update(cx, |state, cx| state.set_tab(tab, cx)))
        };
        let width = SIDEBAR_WIDTH.as_f32();
        div()
            .h_full()
            .flex_none()
            .overflow_hidden()
            .child(
                v_flex()
                    .w(SIDEBAR_WIDTH)
                    .h_full()
                    .pt(px(TITLEBAR_HEIGHT))
                    .px(space::S)
                    .pb(space::M)
                    .gap(px(1.))
                    .border_r_1()
                    .border_color(p.line)
                    .children(primary.into_iter().map(|(tab, glyph)| item(tab, glyph)))
                    .child(div().flex_1())
                    .children(secondary.into_iter().map(|(tab, glyph)| item(tab, glyph))),
            )
            .with_spring(
                "sidebar-width",
                SpringAnimation::new(SNAP).to(if collapsed { 0.0f32 } else { 1.0 }),
                move |bar, t| bar.w(px(width * t.max(0.0))),
            )
    }
}

impl Render for MainView {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let p = palette(cx);
        let (onboarded, repair, tab, wizard) = {
            let state = self.state.read(cx);
            (state.settings.has_completed_welcome_onboarding, state.repair_mode, state.tab, state.wizard_open)
        };
        let root = div()
            .size_full()
            .relative()
            .font_family(super::theme::FONT)
            .text_color(p.text)
            .bg(p.ground);
        if !onboarded || repair {
            return root.child(pages::onboarding::render(self, repair, window, cx)).into_any_element();
        }
        let roomy = window.viewport_size().width >= px(ROOMY_ABOVE);
        let content = match tab {
            Tab::Home => pages::home::render(self, window, cx).into_any_element(),
            Tab::Insights => pages::insights::render(self, window, cx).into_any_element(),
            Tab::Dictionary => pages::dictionary::render(self, window, cx).into_any_element(),
            Tab::Snippets => pages::snippets::render(self, window, cx).into_any_element(),
            Tab::Style => pages::style::render(self, window, cx).into_any_element(),
            Tab::Settings => pages::settings::render(self, window, cx).into_any_element(),
            Tab::Help => pages::help::render(self, window, cx).into_any_element(),
        };
        let toggle = {
            let entity = self.state.clone();
            icon_button("sidebar-toggle", Icon::Sidebar, p.muted, cx)
                .absolute()
                .top(px((TITLEBAR_HEIGHT - 28.0) / 2.0 - 1.0))
                .left(px(TRAFFIC_LIGHTS_END))
                .on_mouse_down(gpui_kit::MouseButton::Left, |_, _, cx| cx.stop_propagation())
                .on_click(move |_, _, cx| entity.update(cx, |state, cx| state.toggle_sidebar(cx)))
        };
        // The top band has no chrome of its own; dragging it moves the window.
        let drag_band = div()
            .id("titlebar")
            .absolute()
            .top_0()
            .left_0()
            .w_full()
            .h(px(TITLEBAR_HEIGHT))
            .on_mouse_down(gpui_kit::MouseButton::Left, |_, window, _| window.start_window_move());
        root.child(
            h_flex()
                .size_full()
                .child(self.sidebar(cx))
                .child(
                    div()
                        .id("content")
                        .flex_1()
                        .min_w_0()
                        .h_full()
                        .bg(p.surface)
                        .overflow_y_scroll()
                        .child(
                            div()
                                .key_context("page")
                                .w_full()
                                .max_w(px(820.))
                                .mx_auto()
                                .px(if roomy { space::XXXL } else { space::XL })
                                .pt(px(TITLEBAR_HEIGHT + 24.0))
                                .pb(space::XXXL)
                                .child(content)
                                .with_spring(
                                    SharedString::from(format!("page-{}", tab.title())),
                                    SpringAnimation::new(SNAP).to(1.0f32).from(0.0f32),
                                    |page, t| page.opacity(t.clamp(0.0, 1.0)).mt(px(4.0 * (1.0 - t))),
                                ),
                        ),
                ),
        )
        .child(drag_band)
        .child(toggle)
        .when(wizard, |root| root.child(pages::style::wizard(self, cx)))
        .into_any_element()
    }
}

/// Stats and the recent list Home and Insights show. Computing them walks
/// the whole history, so the result is kept until the history changes.
pub struct HistoryDigest {
    key: (usize, u64, usize, chrono::NaiveDate),
    pub today: chrono::NaiveDate,
    pub home: tick_core::stats::HomeStats,
    pub insights: tick_core::stats::Insights,
    /// The newest transcripts first, at most `RECENT`.
    pub recent: Vec<tick_core::history::Transcript>,
    pub total: usize,
}

impl HistoryDigest {
    pub const RECENT: usize = 60;
}

impl MainView {
    pub fn digest(&mut self, cx: &gpui_kit::App) -> std::rc::Rc<HistoryDigest> {
        let history = &self.state.read(cx).history.history;
        let today = chrono::Local::now().date_naive();
        let newest = history.iter().map(|t| t.timestamp.0).fold(f64::MIN, f64::max);
        let with_audio = history.iter().filter(|t| t.has_audio).count();
        let key = (history.len(), newest.to_bits(), with_audio, today);
        if let Some(digest) = self.digest.as_ref().filter(|digest| digest.key == key) {
            return digest.clone();
        }
        let mut recent: Vec<&tick_core::history::Transcript> = history.iter().collect();
        recent.sort_by(|a, b| b.timestamp.0.total_cmp(&a.timestamp.0));
        let digest = std::rc::Rc::new(HistoryDigest {
            key,
            today,
            home: tick_core::stats::home_stats(history, today),
            insights: tick_core::stats::insights(history),
            recent: recent.into_iter().take(HistoryDigest::RECENT).cloned().collect(),
            total: history.len(),
        });
        self.digest = Some(digest.clone());
        digest
    }
}
