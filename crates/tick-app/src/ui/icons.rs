//! Tick's icon set: 24-unit grid, 1.5 stroke, square caps, mitred joins —
//! drawn to match the square interface. Served from `tick/<name>.svg`, with
//! Kit's own icons as the fallback asset source.

use std::borrow::Cow;

use gpui_kit::{AssetSource, Result, SharedString};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Icon {
    Home,
    Insights,
    Dictionary,
    Snippets,
    Style,
    Settings,
    Help,
    Mic,
    Copy,
    More,
    Trash,
    Search,
    Close,
    ArrowRight,
    ChevronDown,
    ChevronRight,
    ChevronLeft,
    Download,
    Lock,
    Shield,
    Flame,
    Gauge,
    Words,
    Trophy,
    Warning,
    Clipboard,
    Keyboard,
    Headphones,
    Mail,
    Chat,
    Chip,
    Sidebar,
}

impl Icon {
    pub fn path(self) -> SharedString {
        SharedString::new_static(match self {
            Icon::Home => "tick/home.svg",
            Icon::Insights => "tick/insights.svg",
            Icon::Dictionary => "tick/dictionary.svg",
            Icon::Snippets => "tick/snippets.svg",
            Icon::Style => "tick/style.svg",
            Icon::Settings => "tick/settings.svg",
            Icon::Help => "tick/help.svg",
            Icon::Mic => "tick/mic.svg",
            Icon::Copy => "tick/copy.svg",
            Icon::More => "tick/more.svg",
            Icon::Trash => "tick/trash.svg",
            Icon::Search => "tick/search.svg",
            Icon::Close => "tick/close.svg",
            Icon::ArrowRight => "tick/arrow-right.svg",
            Icon::ChevronDown => "tick/chevron-down.svg",
            Icon::ChevronRight => "tick/chevron-right.svg",
            Icon::ChevronLeft => "tick/chevron-left.svg",
            Icon::Download => "tick/download.svg",
            Icon::Lock => "tick/lock.svg",
            Icon::Shield => "tick/shield.svg",
            Icon::Flame => "tick/flame.svg",
            Icon::Gauge => "tick/gauge.svg",
            Icon::Words => "tick/words.svg",
            Icon::Trophy => "tick/trophy.svg",
            Icon::Warning => "tick/warning.svg",
            Icon::Clipboard => "tick/clipboard.svg",
            Icon::Keyboard => "tick/keyboard.svg",
            Icon::Headphones => "tick/headphones.svg",
            Icon::Mail => "tick/mail.svg",
            Icon::Chat => "tick/chat.svg",
            Icon::Chip => "tick/chip.svg",
            Icon::Sidebar => "tick/sidebar.svg",
        })
    }
}

const OPEN: &str = r##"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="#000" stroke-width="1.5" stroke-linecap="square" stroke-linejoin="miter">"##;

fn body(name: &str) -> Option<&'static str> {
    Some(match name {
        "home" => {
            r##"<path d="M4 11 12 4l8 7"/><path d="M6 9.5V20h12V9.5"/><path d="M10 20v-6h4v6"/>"##
        }
        "insights" => r##"<path d="M4 4v16h16"/><path d="M8 15l3.5-4 3 2.5L19 8"/>"##,
        "dictionary" => {
            r##"<path d="M5 4h11v16H5z"/><path d="M16 6h3v14h-3"/><path d="M8 8h5M8 11h5"/>"##
        }
        "snippets" => {
            r##"<path d="M8 6 3 12l5 6"/><path d="M16 6l5 6-5 6"/><path d="M13.5 5l-3 14"/>"##
        }
        "style" => {
            r##"<path d="M4 7h10M18 7h2M4 17h2M10 17h10"/><path d="M14 4.5v5h4v-5z"/><path d="M6 14.5v5h4v-5z"/>"##
        }
        "settings" => {
            r##"<path d="M7 7h10v10H7z"/><path d="M12 3v4M12 17v4M3 12h4M17 12h4M5.5 5.5l2 2M16.5 16.5l2 2M18.5 5.5l-2 2M7.5 16.5l-2 2"/><path d="M10.5 10.5h3v3h-3z"/>"##
        }
        "help" => {
            r##"<path d="M4 4h16v16H4z"/><path d="M9.5 9.5V8h5v4H12v2"/><path d="M12 16.5v1"/>"##
        }
        "mic" => {
            r##"<path d="M9 3h6v11H9z"/><path d="M5.5 11v2.5L8 17h8l2.5-3.5V11"/><path d="M12 17v4M9 21h6"/>"##
        }
        "copy" => r##"<path d="M8 8h12v12H8z"/><path d="M16 8V4H4v12h4"/>"##,
        "more" => {
            r##"<path d="M5 11h2v2H5zM11 11h2v2h-2zM17 11h2v2h-2z" fill="#000" stroke="none"/>"##
        }
        "trash" => {
            r##"<path d="M4 7h16"/><path d="M9.5 7V4h5v3"/><path d="M6 7l1 13h10l1-13"/><path d="M10 11v5M14 11v5"/>"##
        }
        "search" => r##"<path d="M5 5h9v9H5z"/><path d="M14 14l5.5 5.5"/>"##,
        "close" => r##"<path d="M6 6l12 12M18 6 6 18"/>"##,
        "arrow-right" => r##"<path d="M4 12h15"/><path d="M14 7l5 5-5 5"/>"##,
        "chevron-down" => r##"<path d="M6 9.5l6 6 6-6"/>"##,
        "chevron-right" => r##"<path d="M9.5 6l6 6-6 6"/>"##,
        "chevron-left" => r##"<path d="M14.5 6l-6 6 6 6"/>"##,
        "download" => {
            r##"<path d="M12 4v11"/><path d="M7 10.5l5 5 5-5"/><path d="M4 17v3h16v-3"/>"##
        }
        "lock" => {
            r##"<path d="M5 10.5h14V20H5z"/><path d="M8 10.5V5h8v5.5"/><path d="M12 14v2.5"/>"##
        }
        "shield" => {
            r##"<path d="M12 3 19 6v6l-2.5 5L12 21l-4.5-4L5 12V6z"/><path d="M9 12l2.2 2.2L15.5 10"/>"##
        }
        "flame" => r##"<path d="M12 3l5 7-1 2.5 2 1.5-1 4-5 3-5-3-1-4 2-3.5 1.5 1.5z"/>"##,
        "gauge" => {
            r##"<path d="M4 17 6 11l5-3.5h2L18 11l2 6"/><path d="M12 17l4-6"/><path d="M3 17h18"/>"##
        }
        "words" => r##"<path d="M4 6h16M4 10h16M4 14h10M4 18h13"/>"##,
        "trophy" => {
            r##"<path d="M8 4h8v5l-2 4h-4l-2-4z"/><path d="M8 6H4v3l4 2M16 6h4v3l-4 2"/><path d="M12 13v5M8 20h8"/>"##
        }
        "warning" => r##"<path d="M12 4 21 20H3z"/><path d="M12 10v4.5M12 16.5v1"/>"##,
        "clipboard" => {
            r##"<path d="M6 5h12v16H6z"/><path d="M9.5 3h5v4h-5z"/><path d="M9 12h6M9 16h4"/>"##
        }
        "keyboard" => {
            r##"<path d="M3 6h18v12H3z"/><path d="M6.5 9.5h1M10 9.5h1M13.5 9.5h1M17 9.5h.5M8 14.5h8"/>"##
        }
        "headphones" => {
            r##"<path d="M4 14V9l3-5h10l3 5v5"/><path d="M4 14h4v6H4zM16 14h4v6h-4z"/>"##
        }
        "mail" => r##"<path d="M3 6h18v12H3z"/><path d="M3 6l9 7 9-7"/>"##,
        "chat" => r##"<path d="M4 5h16v11h-9l-5 4v-4H4z"/>"##,
        "chip" => {
            r##"<path d="M7 7h10v10H7z"/><path d="M10 10h4v4h-4z"/><path d="M9.5 3v4M14.5 3v4M9.5 17v4M14.5 17v4M3 9.5h4M3 14.5h4M17 9.5h4M17 14.5h4"/>"##
        }
        "sidebar" => r##"<path d="M4 5h16v14H4z"/><path d="M9.5 5v14"/>"##,
        _ => return None,
    })
}

fn render(name: &str) -> Option<Vec<u8>> {
    body(name).map(|body| format!("{OPEN}{body}</svg>").into_bytes())
}

/// Tick icons first, then Kit's bundled icons.
pub struct Assets;

impl AssetSource for Assets {
    fn load(&self, path: &str) -> Result<Option<Cow<'static, [u8]>>> {
        if let Some(name) = path
            .strip_prefix("tick/")
            .and_then(|p| p.strip_suffix(".svg"))
        {
            return Ok(render(name).map(Cow::Owned));
        }
        gpui_kit::assets::Assets.load(path)
    }

    fn list(&self, path: &str) -> Result<Vec<SharedString>> {
        gpui_kit::assets::Assets.list(path)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const ALL: [Icon; 32] = [
        Icon::Home,
        Icon::Insights,
        Icon::Dictionary,
        Icon::Snippets,
        Icon::Style,
        Icon::Settings,
        Icon::Help,
        Icon::Mic,
        Icon::Copy,
        Icon::More,
        Icon::Trash,
        Icon::Search,
        Icon::Close,
        Icon::ArrowRight,
        Icon::ChevronDown,
        Icon::ChevronRight,
        Icon::ChevronLeft,
        Icon::Download,
        Icon::Lock,
        Icon::Shield,
        Icon::Flame,
        Icon::Gauge,
        Icon::Words,
        Icon::Trophy,
        Icon::Warning,
        Icon::Clipboard,
        Icon::Keyboard,
        Icon::Headphones,
        Icon::Mail,
        Icon::Chat,
        Icon::Chip,
        Icon::Sidebar,
    ];

    #[test]
    fn every_icon_has_parseable_svg() {
        for icon in ALL {
            let path = icon.path();
            let bytes = Assets
                .load(&path)
                .unwrap()
                .unwrap_or_else(|| panic!("{path} missing"));
            let text = String::from_utf8(bytes.to_vec()).unwrap();
            assert!(
                text.starts_with("<svg") && text.ends_with("</svg>"),
                "{path}"
            );
        }
    }
}
