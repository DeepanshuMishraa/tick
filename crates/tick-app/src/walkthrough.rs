//! Walkthrough bundles on disk, under `Application Support/…/Walkthroughs`:
//! one folder per recording with `frames/frame-NN.png`, `contact-sheet.png`
//! and `summary.md`.

use std::path::{Path, PathBuf};

use image::{Rgba, RgbaImage, imageops};
use tick_core::walkthrough;

use crate::storage;

/// Finished walkthroughs kept on disk; older ones are deleted.
const KEEP: usize = 20;
/// Width of the contact sheet in pixels.
const SHEET_WIDTH: u32 = 1600;
const GAP: u32 = 8;

/// Creates an empty bundle folder named after the current time.
pub fn create_bundle() -> std::io::Result<PathBuf> {
    let name = chrono::Local::now().format("%Y-%m-%d-%H%M%S").to_string();
    let bundle = storage::walkthroughs().join(name);
    std::fs::create_dir_all(bundle.join("frames"))?;
    Ok(bundle)
}

/// `frames/frame-NN.png` for the keyframe at zero-based `index`.
pub fn frame_path(bundle: &Path, index: usize) -> PathBuf {
    bundle
        .join("frames")
        .join(format!("frame-{:02}.png", index + 1))
}

pub fn contact_sheet_path(bundle: &Path) -> PathBuf {
    bundle.join("contact-sheet.png")
}

/// Scales a frame down to the width of one contact-sheet cell for `count`
/// keyframes. Done per frame as it arrives, so full frames are not kept.
pub fn tile(frame: &RgbaImage, columns: usize) -> RgbaImage {
    let columns = columns.max(1) as u32;
    let width = (SHEET_WIDTH - GAP * (columns + 1)) / columns;
    let height = (u64::from(frame.height()) * u64::from(width) / u64::from(frame.width().max(1)))
        .max(1) as u32;
    imageops::resize(frame, width, height, imageops::FilterType::Triangle)
}

/// Lays tiles out in a grid, each labelled with its keyframe number.
/// Tiles must all have been made with `tile` for the same column count.
pub fn contact_sheet(tiles: &[RgbaImage]) -> Option<RgbaImage> {
    let first = tiles.first()?;
    let columns = walkthrough::sheet_columns(tiles.len()) as u32;
    let rows = (tiles.len() as u32).div_ceil(columns);
    let (cell_width, cell_height) = (
        first.width(),
        tiles.iter().map(RgbaImage::height).max().unwrap_or(1),
    );
    let width = GAP + columns * (cell_width + GAP);
    let height = GAP + rows * (cell_height + GAP);
    let mut sheet = RgbaImage::from_pixel(width, height, Rgba([24, 24, 24, 255]));
    for (index, tile) in tiles.iter().enumerate() {
        let (column, row) = (index as u32 % columns, index as u32 / columns);
        let (x, y) = (
            GAP + column * (cell_width + GAP),
            GAP + row * (cell_height + GAP),
        );
        imageops::overlay(&mut sheet, tile, i64::from(x), i64::from(y));
        label(&mut sheet, x, y, &format!("#{}", index + 1));
    }
    Some(sheet)
}

/// 5×7 dot-matrix glyphs, one row per byte, high bit on the left.
fn glyph(character: char) -> [u8; 7] {
    match character {
        '0' => [0x0E, 0x11, 0x13, 0x15, 0x19, 0x11, 0x0E],
        '1' => [0x04, 0x0C, 0x04, 0x04, 0x04, 0x04, 0x0E],
        '2' => [0x0E, 0x11, 0x01, 0x02, 0x04, 0x08, 0x1F],
        '3' => [0x1F, 0x02, 0x04, 0x02, 0x01, 0x11, 0x0E],
        '4' => [0x02, 0x06, 0x0A, 0x12, 0x1F, 0x02, 0x02],
        '5' => [0x1F, 0x10, 0x1E, 0x01, 0x01, 0x11, 0x0E],
        '6' => [0x06, 0x08, 0x10, 0x1E, 0x11, 0x11, 0x0E],
        '7' => [0x1F, 0x01, 0x02, 0x04, 0x08, 0x08, 0x08],
        '8' => [0x0E, 0x11, 0x11, 0x0E, 0x11, 0x11, 0x0E],
        '9' => [0x0E, 0x11, 0x11, 0x0F, 0x01, 0x02, 0x0C],
        '#' => [0x0A, 0x0A, 0x1F, 0x0A, 0x1F, 0x0A, 0x0A],
        _ => [0; 7],
    }
}

/// Draws `text` in white dots on a black square at the top-left of a tile.
fn label(image: &mut RgbaImage, x: u32, y: u32, text: &str) {
    const DOT: u32 = 3;
    const PITCH: u32 = 4;
    const PADDING: u32 = 8;
    let advance = 6 * PITCH;
    let width = PADDING * 2 + advance * text.chars().count() as u32 - PITCH;
    let height = PADDING * 2 + 7 * PITCH - (PITCH - DOT);
    fill(image, x, y, width, height, Rgba([0, 0, 0, 255]));
    for (position, character) in text.chars().enumerate() {
        for (row, bits) in glyph(character).iter().enumerate() {
            for column in 0..5u32 {
                if bits & (0x10 >> column) != 0 {
                    let dot_x = x + PADDING + position as u32 * advance + column * PITCH;
                    let dot_y = y + PADDING + row as u32 * PITCH;
                    fill(image, dot_x, dot_y, DOT, DOT, Rgba([255, 255, 255, 255]));
                }
            }
        }
    }
}

fn fill(image: &mut RgbaImage, x: u32, y: u32, width: u32, height: u32, color: Rgba<u8>) {
    for py in y..(y + height).min(image.height()) {
        for px in x..(x + width).min(image.width()) {
            image.put_pixel(px, py, color);
        }
    }
}

/// Deletes all but the newest `KEEP` bundles.
pub fn purge_old() {
    let root = storage::walkthroughs();
    let Ok(entries) = std::fs::read_dir(&root) else {
        return;
    };
    let names = entries
        .flatten()
        .filter(|entry| entry.path().is_dir())
        .map(|entry| entry.file_name().to_string_lossy().into_owned())
        .collect();
    for name in walkthrough::expired(names, KEEP) {
        if let Err(error) = std::fs::remove_dir_all(root.join(&name)) {
            tracing::warn!(target: "walkthrough", "could not delete an old walkthrough: {error}");
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn contact_sheet_fits_every_tile_in_a_grid() {
        let frame = RgbaImage::from_pixel(1728, 1117, Rgba([200, 200, 200, 255]));
        let columns = walkthrough::sheet_columns(5);
        let tiles: Vec<RgbaImage> = (0..5).map(|_| tile(&frame, columns)).collect();
        let sheet = contact_sheet(&tiles).unwrap();
        assert_eq!(columns, 3);
        assert!(sheet.width() <= SHEET_WIDTH);
        assert_eq!(sheet.height(), GAP + 2 * (tiles[0].height() + GAP));
        // The label of the first tile is drawn over it.
        assert_eq!(sheet.get_pixel(GAP + 1, GAP + 1), &Rgba([0, 0, 0, 255]));
        assert!(contact_sheet(&[]).is_none());
    }
}
