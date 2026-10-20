//! Walkthroughs: the screen recorded while the user talks, clicks and draws,
//! compiled into numbered keyframes and a transcript an AI agent can read.
//!
//! Everything here is platform-free: which moments become keyframes, how the
//! narration is split into utterances and matched to keyframes, and the text
//! handed to the agent.

/// Most keyframes kept per walkthrough; later triggers are ignored.
pub const MAX_KEYFRAMES: usize = 24;
/// Seconds between screen-change checks.
pub const CHANGE_POLL_INTERVAL: f64 = 1.5;
/// Two triggers closer than this produce one keyframe.
pub const MIN_KEYFRAME_GAP: f64 = 0.4;
/// Side of the square luma thumbnail compared to detect screen changes.
pub const THUMBNAIL_SIDE: usize = 32;

/// Why a keyframe was taken.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Trigger {
    Start,
    Click,
    Ink,
    /// A numbered pin, counted from 1.
    Pin(u32),
    ScreenChanged,
}

impl Trigger {
    /// Label shown beside the keyframe in the agent summary.
    pub fn label(self) -> String {
        match self {
            Trigger::Start => "start".into(),
            Trigger::Click => "clicked".into(),
            Trigger::Ink => "drew".into(),
            Trigger::Pin(number) => format!("pin {number}"),
            Trigger::ScreenChanged => "screen changed".into(),
        }
    }

    /// Whether the user asked for this frame, as opposed to a screen change
    /// noticed by polling.
    pub fn is_deliberate(self) -> bool {
        self != Trigger::ScreenChanged
    }
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Keyframe {
    /// Seconds since the walkthrough started.
    pub at: f64,
    pub trigger: Trigger,
}

/// Whether a keyframe triggered at `now` should be taken, given the time of
/// the previous one and how many exist.
pub fn accepts_keyframe(previous: Option<f64>, count: usize, now: f64, trigger: Trigger) -> bool {
    if count >= MAX_KEYFRAMES {
        return false;
    }
    match previous {
        None => true,
        // Marks are always kept: the user drew them for the agent to see.
        Some(_) if matches!(trigger, Trigger::Ink | Trigger::Pin(_)) => true,
        Some(previous) => now - previous >= MIN_KEYFRAME_GAP,
    }
}

/// A downscaled grayscale copy of a frame, for change detection.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Thumbnail(Vec<u8>);

impl Thumbnail {
    /// Box-filters an RGBA image down to `THUMBNAIL_SIDE²` luma samples.
    pub fn from_rgba(rgba: &[u8], width: usize, height: usize) -> Option<Thumbnail> {
        if width == 0 || height == 0 || rgba.len() < width * height * 4 {
            return None;
        }
        let side = THUMBNAIL_SIDE;
        let mut sums = vec![(0u64, 0u64); side * side];
        // Every 4th pixel each way is plenty for a 32×32 summary.
        for y in (0..height).step_by(4) {
            let cell_y = y * side / height;
            for x in (0..width).step_by(4) {
                let cell = cell_y * side + x * side / width;
                let offset = (y * width + x) * 4;
                let (r, g, b) = (u64::from(rgba[offset]), u64::from(rgba[offset + 1]), u64::from(rgba[offset + 2]));
                sums[cell].0 += (r * 299 + g * 587 + b * 114) / 1000;
                sums[cell].1 += 1;
            }
        }
        Some(Thumbnail(sums.into_iter().map(|(sum, n)| sum.checked_div(n).unwrap_or(0) as u8).collect()))
    }

    /// Whether enough of the screen differs to be worth a keyframe: a
    /// blinking caret or a ticking clock must not count, a new page must.
    pub fn differs_from(&self, other: &Thumbnail) -> bool {
        const CELL_DELTA: u8 = 10;
        const CHANGED_FRACTION: f64 = 0.03;
        let changed = self.0.iter().zip(&other.0).filter(|(a, b)| a.abs_diff(**b) > CELL_DELTA).count();
        changed as f64 / self.0.len().max(1) as f64 > CHANGED_FRACTION
    }
}

/// A span of the recording that contains speech, in seconds.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Utterance {
    pub start: f64,
    pub end: f64,
}

impl Utterance {
    pub fn midpoint(&self) -> f64 {
        (self.start + self.end) / 2.0
    }
}

/// Splits mono audio into utterances at pauses, so each can be transcribed
/// and placed next to the keyframe on screen while it was said.
///
/// Speech is any 20 ms window louder than a floor and a multiple of the
/// recording's own noise level (capped at half its loud level). Pauses shorter than 0.6 s stay inside an
/// utterance; utterances longer than 25 s are cut at their quietest window.
pub fn utterances(samples: &[f32], sample_rate: u32) -> Vec<Utterance> {
    const WINDOW: f64 = 0.02;
    const MIN_LEVEL: f32 = 0.004;
    const NOISE_MULTIPLE: f32 = 3.0;
    const MAX_PAUSE: f64 = 0.6;
    const MIN_SPEECH: f64 = 0.2;
    const PADDING: f64 = 0.2;
    const MAX_LENGTH: f64 = 25.0;

    let window = ((f64::from(sample_rate) * WINDOW) as usize).max(1);
    let levels: Vec<f32> = samples
        .chunks(window)
        .map(|chunk| (chunk.iter().map(|s| s * s).sum::<f32>() / chunk.len() as f32).sqrt())
        .collect();
    if levels.is_empty() {
        return Vec::new();
    }
    let mut sorted = levels.clone();
    sorted.sort_by(f32::total_cmp);
    let noise = sorted[sorted.len() / 10];
    // Without pauses the "noise" is speech too; stay below the loud level.
    let loud = sorted[sorted.len() * 9 / 10];
    let threshold = (noise * NOISE_MULTIPLE).min(loud * 0.5).max(MIN_LEVEL);

    let mut spans: Vec<(usize, usize)> = Vec::new();
    let max_gap = (MAX_PAUSE / WINDOW) as usize;
    for (index, level) in levels.iter().enumerate() {
        if *level < threshold {
            continue;
        }
        match spans.last_mut() {
            Some((_, end)) if index - *end <= max_gap => *end = index + 1,
            _ => spans.push((index, index + 1)),
        }
    }
    let min_windows = (MIN_SPEECH / WINDOW) as usize;
    let max_windows = (MAX_LENGTH / WINDOW) as usize;
    let mut cut: Vec<(usize, usize)> = Vec::new();
    for (start, end) in spans.into_iter().filter(|(start, end)| end - start >= min_windows) {
        let mut start = start;
        while end - start > max_windows {
            // Quietest window in the second half of the allowed length.
            let split = (start + max_windows / 2..start + max_windows)
                .min_by(|a, b| levels[*a].total_cmp(&levels[*b]))
                .unwrap_or(start + max_windows);
            cut.push((start, split));
            start = split;
        }
        cut.push((start, end));
    }
    let duration = samples.len() as f64 / f64::from(sample_rate);
    cut.into_iter()
        .map(|(start, end)| Utterance {
            start: (start as f64 * WINDOW - PADDING).max(0.0),
            end: (end as f64 * WINDOW + PADDING).min(duration),
        })
        .collect()
}

/// For each utterance, the index of the keyframe it narrates: the latest
/// one taken by the utterance's midpoint, or the first if none was.
/// `keyframes` must be sorted by time.
pub fn attribute(utterances: &[Utterance], keyframes: &[Keyframe]) -> Vec<usize> {
    utterances
        .iter()
        .map(|utterance| keyframes.iter().rposition(|frame| frame.at <= utterance.midpoint()).unwrap_or(0))
        .collect()
}

/// `m:ss`.
pub fn clock(seconds: f64) -> String {
    let total = seconds.max(0.0).round() as u64;
    format!("{}:{:02}", total / 60, total % 60)
}

/// What the agent is told about the recording as a whole.
#[derive(Debug, Clone, PartialEq)]
pub struct Header {
    pub duration: f64,
    pub app: Option<String>,
    pub bundle: String,
    pub contact_sheet: String,
}

/// The text pasted after the contact sheet: where the files are, then each
/// keyframe with what triggered it and what was said over it.
pub fn summary(header: &Header, keyframes: &[Keyframe], speech: &[Vec<String>]) -> String {
    let mut out = format!("[Tick walkthrough · {}", clock(header.duration));
    if let Some(app) = header.app.as_deref().filter(|app| !app.is_empty()) {
        out.push_str(&format!(" · {app}"));
    }
    out.push_str(&format!(" · {}]\n", header.bundle));
    out.push_str(&format!(
        "Keyframes are numbered on the contact sheet ({}); full-size images are in frames/ (frame-01.png …).\n",
        header.contact_sheet
    ));
    if speech.iter().all(Vec::is_empty) {
        out.push_str("No speech was recognized.\n");
    }
    for (index, frame) in keyframes.iter().enumerate() {
        out.push_str(&format!("- #{} ({}) [{}]", index + 1, clock(frame.at), frame.trigger.label()));
        let said: Vec<&str> = speech.get(index).into_iter().flatten().map(|s| s.trim()).filter(|s| !s.is_empty()).collect();
        if !said.is_empty() {
            out.push_str(&format!(" \"{}\"", said.join(" ")));
        }
        out.push('\n');
    }
    out
}

/// A freehand stroke drawn by the user, in screen points.
pub type Stroke = Vec<(f32, f32)>;

/// A stroke this short is a click that dropped a pin, not a drawing.
pub fn is_tap(stroke: &[(f32, f32)]) -> bool {
    const TAP_LENGTH: f32 = 6.0;
    stroke.windows(2).map(|pair| ((pair[1].0 - pair[0].0).powi(2) + (pair[1].1 - pair[0].1).powi(2)).sqrt()).sum::<f32>()
        < TAP_LENGTH
}

/// Columns for a contact sheet of `count` keyframes: as square a grid as
/// four columns allow.
pub fn sheet_columns(count: usize) -> usize {
    match count {
        0 | 1 => 1,
        2..=4 => 2,
        5..=9 => 3,
        _ => 4,
    }
}

/// Saved walkthroughs past the newest `keep`, given their folder names,
/// which sort by creation time.
pub fn expired(mut names: Vec<String>, keep: usize) -> Vec<String> {
    names.sort();
    let excess = names.len().saturating_sub(keep);
    names.truncate(excess);
    names
}

#[cfg(test)]
mod tests {
    use super::*;

    fn frame(at: f64, trigger: Trigger) -> Keyframe {
        Keyframe { at, trigger }
    }

    #[test]
    fn keyframes_are_spaced_and_capped_but_marks_always_count() {
        assert!(accepts_keyframe(None, 0, 0.0, Trigger::Start));
        assert!(!accepts_keyframe(Some(1.0), 3, 1.2, Trigger::Click));
        assert!(accepts_keyframe(Some(1.0), 3, 1.5, Trigger::Click));
        assert!(accepts_keyframe(Some(1.0), 3, 1.05, Trigger::Pin(2)));
        assert!(!accepts_keyframe(Some(1.0), MAX_KEYFRAMES, 9.0, Trigger::Ink));
    }

    fn solid(width: usize, height: usize, value: u8) -> Vec<u8> {
        vec![value; width * height * 4]
    }

    #[test]
    fn thumbnails_ignore_small_changes_and_catch_large_ones() {
        let (w, h) = (320, 200);
        let base = Thumbnail::from_rgba(&solid(w, h, 40), w, h).unwrap();
        // A caret-sized change.
        let mut caret = solid(w, h, 40);
        for y in 50..60 {
            for x in 100..102 {
                let o = (y * w + x) * 4;
                caret[o..o + 3].copy_from_slice(&[255, 255, 255]);
            }
        }
        assert!(!base.differs_from(&Thumbnail::from_rgba(&caret, w, h).unwrap()));
        // A new page across the top half.
        let mut page = solid(w, h, 40);
        page[..w * h * 2].fill(230);
        assert!(base.differs_from(&Thumbnail::from_rgba(&page, w, h).unwrap()));
    }

    #[test]
    fn thumbnail_rejects_short_buffers() {
        assert_eq!(Thumbnail::from_rgba(&[0; 8], 4, 4), None);
        assert_eq!(Thumbnail::from_rgba(&[], 0, 0), None);
    }

    fn tone(seconds: f64, amplitude: f32) -> Vec<f32> {
        (0..(seconds * 16_000.0) as usize).map(|i| amplitude * (i as f32 * 0.3).sin()).collect()
    }

    #[test]
    fn utterances_split_at_pauses_and_bridge_short_gaps() {
        let mut audio = tone(1.0, 0.0);
        audio.extend(tone(1.0, 0.3)); // 1.0–2.0
        audio.extend(tone(0.3, 0.0)); // short pause, bridged
        audio.extend(tone(0.5, 0.3)); // 2.3–2.8
        audio.extend(tone(1.5, 0.0)); // long pause, splits
        audio.extend(tone(1.0, 0.3)); // 4.3–5.3
        audio.extend(tone(0.5, 0.0));
        let found = utterances(&audio, 16_000);
        assert_eq!(found.len(), 2, "{found:?}");
        assert!((found[0].start - 0.8).abs() < 0.05 && (found[0].end - 3.0).abs() < 0.05, "{found:?}");
        assert!((found[1].start - 4.1).abs() < 0.05 && (found[1].end - 5.5).abs() < 0.05, "{found:?}");
    }

    #[test]
    fn silence_has_no_utterances_and_blips_are_dropped() {
        assert!(utterances(&tone(3.0, 0.0), 16_000).is_empty());
        let mut audio = tone(1.0, 0.0);
        audio.extend(tone(0.06, 0.4));
        audio.extend(tone(1.0, 0.0));
        assert!(utterances(&audio, 16_000).is_empty());
        assert!(utterances(&[], 16_000).is_empty());
    }

    #[test]
    fn long_speech_is_cut_below_the_limit() {
        let found = utterances(&tone(60.0, 0.3), 16_000);
        assert!(found.len() >= 3, "{found:?}");
        assert!(found.iter().all(|u| u.end - u.start <= 25.5), "{found:?}");
        assert!((found.last().unwrap().end - 60.0).abs() < 0.01);
    }

    #[test]
    fn speech_goes_to_the_keyframe_on_screen_at_its_midpoint() {
        let frames = [frame(0.0, Trigger::Start), frame(4.0, Trigger::Click), frame(9.0, Trigger::Ink)];
        let spoken = [
            Utterance { start: 0.5, end: 3.0 },
            Utterance { start: 3.0, end: 6.0 }, // midpoint 4.5: after the click
            Utterance { start: 7.0, end: 10.0 }, // midpoint 8.5: before the ink
            Utterance { start: 9.5, end: 12.0 },
        ];
        assert_eq!(attribute(&spoken, &frames), vec![0, 1, 1, 2]);
        assert_eq!(attribute(&spoken[..1], &[frame(2.0, Trigger::Start)]), vec![0]);
    }

    #[test]
    fn summary_lists_keyframes_with_speech() {
        let header = Header {
            duration: 72.4,
            app: Some("Safari".into()),
            bundle: "/tmp/w/2026-10-21-001500".into(),
            contact_sheet: "/tmp/w/2026-10-21-001500/contact-sheet.png".into(),
        };
        let frames = [frame(0.0, Trigger::Start), frame(5.2, Trigger::Click), frame(9.0, Trigger::Pin(1))];
        let speech = vec![vec!["So this is the deploy page.".into()], vec!["Retry does nothing.".into(), " Watch. ".into()], vec![]];
        let text = summary(&header, &frames, &speech);
        assert_eq!(
            text,
            "[Tick walkthrough · 1:12 · Safari · /tmp/w/2026-10-21-001500]\n\
             Keyframes are numbered on the contact sheet (/tmp/w/2026-10-21-001500/contact-sheet.png); full-size images are in frames/ (frame-01.png …).\n\
             - #1 (0:00) [start] \"So this is the deploy page.\"\n\
             - #2 (0:05) [clicked] \"Retry does nothing. Watch.\"\n\
             - #3 (0:09) [pin 1]\n"
        );
    }

    #[test]
    fn summary_says_when_nothing_was_heard() {
        let header = Header { duration: 3.0, app: None, bundle: "/b".into(), contact_sheet: "/b/c.png".into() };
        let text = summary(&header, &[frame(0.0, Trigger::Start)], &[vec![]]);
        assert!(text.starts_with("[Tick walkthrough · 0:03 · /b]\n"));
        assert!(text.contains("No speech was recognized.\n"));
    }

    #[test]
    fn taps_are_short_strokes() {
        assert!(is_tap(&[(10.0, 10.0)]));
        assert!(is_tap(&[(10.0, 10.0), (12.0, 11.0), (13.0, 12.0)]));
        assert!(!is_tap(&[(10.0, 10.0), (30.0, 10.0)]));
    }

    #[test]
    fn sheet_grid_and_retention() {
        assert_eq!([1, 2, 4, 5, 9, 10, 24].map(sheet_columns), [1, 2, 2, 3, 3, 4, 4]);
        let names = ["2026-10-03", "2026-10-01", "2026-10-02"].map(String::from).to_vec();
        assert_eq!(expired(names.clone(), 2), vec!["2026-10-01".to_string()]);
        assert!(expired(names, 5).is_empty());
    }

    #[test]
    fn clock_formats_minutes_and_seconds() {
        assert_eq!(clock(0.0), "0:00");
        assert_eq!(clock(59.6), "1:00");
        assert_eq!(clock(605.0), "10:05");
    }
}
