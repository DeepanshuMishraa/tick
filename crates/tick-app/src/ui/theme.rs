//! Tick's visual tokens. Every surface is square: radius is zero across the
//! Kit theme and every custom element. Colors come from one palette per
//! appearance plus the user's accent.

use gpui_kit::component::Theme;
use gpui_kit::{App, Global, Hsla, Pixels, SharedString, WindowAppearance, px, rgb};
use tick_core::settings::{AppearanceMode, ThemeColor};

pub const FONT: &str = "Spline Sans Mono";

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Palette {
    pub dark: bool,
    /// Window ground behind everything.
    pub ground: Hsla,
    /// Raised content surface.
    pub surface: Hsla,
    /// Hover/selected fill for rows and controls.
    pub hover: Hsla,
    pub text: Hsla,
    pub muted: Hsla,
    pub faint: Hsla,
    pub line: Hsla,
    pub line_strong: Hsla,
    pub accent: Hsla,
    /// Text drawn on an accent fill.
    pub on_accent: Hsla,
    pub accent_soft: Hsla,
    pub danger: Hsla,
    pub success: Hsla,
    pub warning: Hsla,
    pub recording: Hsla,
    /// Overlay (pill, notice) ground; light or dark with the theme.
    pub hud: Hsla,
    pub hud_text: Hsla,
    pub multicolor: bool,
}

impl Global for Palette {}

fn color(hex: u32) -> Hsla {
    rgb(hex).into()
}

fn with_alpha(color: Hsla, alpha: f32) -> Hsla {
    Hsla { a: alpha, ..color }
}

pub fn accent_for(theme: ThemeColor, dark: bool) -> Hsla {
    match theme {
        ThemeColor::Monochrome | ThemeColor::Multicolor => {
            if dark {
                color(0xEDEDEA)
            } else {
                color(0x111111)
            }
        }
        ThemeColor::Blue => color(0x2F6BFF),
        ThemeColor::Purple => color(0x7A5CFF),
        ThemeColor::Pink => color(0xF2508F),
        ThemeColor::Red => color(0xF2382C),
        ThemeColor::Orange => color(0xF5741B),
        ThemeColor::Yellow => color(0xE8B500),
        ThemeColor::Green => color(0x1FA35A),
    }
}

/// Swatch color shown in the theme picker.
pub fn swatch(theme: ThemeColor, dark: bool) -> Hsla {
    match theme {
        ThemeColor::Multicolor => color(0x2F6BFF),
        other => accent_for(other, dark),
    }
}

impl Palette {
    pub fn new(dark: bool, theme: ThemeColor) -> Palette {
        let accent = accent_for(theme, dark);
        let monochrome = matches!(theme, ThemeColor::Monochrome | ThemeColor::Multicolor);
        let on_accent = if monochrome {
            if dark {
                color(0x0E0E0E)
            } else {
                color(0xFAFAF8)
            }
        } else if theme == ThemeColor::Yellow {
            color(0x111111)
        } else {
            color(0xFFFFFF)
        };
        if dark {
            Palette {
                dark,
                ground: color(0x0B0B0B),
                surface: color(0x121212),
                hover: color(0x1B1B1B),
                text: color(0xEDEDEA),
                muted: color(0x8C8C88),
                faint: color(0x55554F),
                line: color(0x232322),
                line_strong: color(0x3A3A37),
                accent,
                on_accent,
                accent_soft: with_alpha(accent, 0.14),
                danger: color(0xFF5A4E),
                success: color(0x35C27A),
                warning: color(0xF2B33D),
                recording: color(0xFF3B30),
                hud: color(0x0A0A0A),
                hud_text: color(0xF4F4F1),
                multicolor: theme == ThemeColor::Multicolor,
            }
        } else {
            Palette {
                dark,
                ground: color(0xF4F3EF),
                surface: color(0xFBFAF8),
                hover: color(0xEDECE7),
                text: color(0x111111),
                muted: color(0x6B6A66),
                faint: color(0xA9A8A2),
                line: color(0xE3E1DB),
                line_strong: color(0xC9C7C0),
                accent,
                on_accent,
                accent_soft: with_alpha(accent, 0.10),
                danger: color(0xD8382E),
                success: color(0x1D8E52),
                warning: color(0xB97800),
                recording: color(0xFF3B30),
                hud: color(0xFBFAF8),
                hud_text: color(0x111111),
                multicolor: theme == ThemeColor::Multicolor,
            }
        }
    }

    /// Accent for the n-th element of a sequence; cycles hues in multicolor.
    pub fn sequence(&self, index: usize, count: usize) -> Hsla {
        if !self.multicolor {
            return self.accent;
        }
        let hue = (index as f32 / count.max(1) as f32 + 0.55) % 1.0;
        Hsla {
            h: hue,
            s: 0.78,
            l: 0.58,
            a: 1.0,
        }
    }

    pub fn alpha(&self, color: Hsla, alpha: f32) -> Hsla {
        with_alpha(color, alpha)
    }
}

pub fn is_dark(appearance: WindowAppearance) -> bool {
    matches!(
        appearance,
        WindowAppearance::Dark | WindowAppearance::VibrantDark
    )
}

/// Spacing scale (px): 2, 4, 8, 12, 16, 24, 32, 48.
pub mod space {
    use gpui_kit::{Pixels, px};
    pub const XXS: Pixels = px(2.);
    pub const XS: Pixels = px(4.);
    pub const S: Pixels = px(8.);
    pub const M: Pixels = px(12.);
    pub const L: Pixels = px(16.);
    pub const XL: Pixels = px(24.);
    pub const XXL: Pixels = px(32.);
    pub const XXXL: Pixels = px(48.);
}

/// Type scale (px).
pub mod size {
    use gpui_kit::{Pixels, px};
    pub const EYEBROW: Pixels = px(10.5);
    pub const CAPTION: Pixels = px(11.5);
    pub const BODY: Pixels = px(13.);
    pub const LEAD: Pixels = px(15.);
    pub const TITLE: Pixels = px(22.);
    pub const DISPLAY: Pixels = px(34.);
}

pub const SIDEBAR_WIDTH: Pixels = px(208.);

/// Registers the bundled faces with the text system.
pub fn register_fonts(cx: &mut App) {
    let fonts: Vec<std::borrow::Cow<'static, [u8]>> = vec![
        include_bytes!("../../../../fonts/SplineSansMono-Variable.ttf")
            .as_slice()
            .into(),
        include_bytes!("../../../../fonts/SplineSansMono-Italic-Variable.ttf")
            .as_slice()
            .into(),
    ];
    if let Err(error) = cx.text_system().add_fonts(fonts) {
        tracing::error!(target: "app", "bundled fonts failed to load: {error}");
    }
}

/// Recomputes the palette and squares off the Kit theme.
/// `system` is the appearance macOS reports; `mode` may override it.
pub fn apply(
    system: WindowAppearance,
    mode: AppearanceMode,
    theme_color: ThemeColor,
    cx: &mut App,
) {
    let appearance = match mode {
        AppearanceMode::System => system,
        AppearanceMode::Light => WindowAppearance::Light,
        AppearanceMode::Dark => WindowAppearance::Dark,
    };
    let dark = is_dark(appearance);
    let palette = Palette::new(dark, theme_color);
    let mode_changed = cx
        .try_global::<Palette>()
        .is_none_or(|current| current.dark != dark);
    cx.set_global(palette);
    if mode_changed {
        Theme::change(appearance, None, cx);
    }
    Theme::update(cx, |theme| {
        theme.radius = px(0.);
        theme.radius_lg = px(0.);
        theme.shadow = false;
        theme.font_family = SharedString::new_static(FONT);
        theme.mono_font_family = SharedString::new_static(FONT);
        theme.font_size = px(14.);
        theme.mono_font_size = px(13.);
        theme.background = palette.surface;
        theme.foreground = palette.text;
        theme.border = palette.line_strong;
        theme.input = palette.line_strong;
        theme.ring = palette.accent;
        theme.caret = palette.accent;
        theme.primary = palette.accent;
        theme.primary_hover = palette.accent;
        theme.primary_active = palette.accent;
        theme.primary_foreground = palette.on_accent;
        theme.muted = palette.hover;
        theme.muted_foreground = palette.muted;
        theme.popover = palette.surface;
        theme.popover_foreground = palette.text;
        theme.accent = palette.hover;
        theme.accent_foreground = palette.text;
        theme.selection = palette.accent_soft;
        theme.list_hover = palette.hover;
        theme.list_active = palette.accent_soft;
    });
}
