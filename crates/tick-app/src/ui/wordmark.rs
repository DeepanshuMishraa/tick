//! Tick's mark: three square bars, the same shape as the menu bar icon.

use gpui_kit::base::h_flex;
use gpui_kit::{div, Hsla, IntoElement, ParentElement as _, Pixels, Styled as _};

pub fn mark(size: Pixels, color: Hsla) -> impl IntoElement {
    let unit = size / 18.;
    h_flex()
        .h(size)
        .gap(unit * 2.)
        .items_center()
        .children([8.5f32, 15.0, 11.0].map(|height| div().w(unit * 3.).h(unit * height).bg(color)))
}
