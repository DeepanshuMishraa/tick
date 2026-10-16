//! Deterministic transcript transformations: filler removal, dictionary
//! remappings, snippet expansion, and dictionary learning from user edits.

use fancy_regex::Regex;
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::hotkey::{Key, ModifierKind, Modifiers};
use crate::id::SwiftUuid;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WordRemapping {
    pub id: SwiftUuid,
    pub is_enabled: bool,
    #[serde(rename = "match")]
    pub match_text: String,
    pub replacement: String,
}

impl WordRemapping {
    pub fn new(match_text: impl Into<String>, replacement: impl Into<String>) -> Self {
        Self {
            id: SwiftUuid(Uuid::new_v4()),
            is_enabled: true,
            match_text: match_text.into(),
            replacement: replacement.into(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WordRemoval {
    pub id: SwiftUuid,
    pub is_enabled: bool,
    pub pattern: String,
}

impl WordRemoval {
    pub fn new(pattern: impl Into<String>) -> Self {
        Self { id: SwiftUuid(Uuid::new_v4()), is_enabled: true, pattern: pattern.into() }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Snippet {
    pub id: SwiftUuid,
    pub is_enabled: bool,
    pub shortcut: String,
    pub content: String,
}

impl Snippet {
    pub fn new(shortcut: impl Into<String>, content: impl Into<String>) -> Self {
        Self {
            id: SwiftUuid(Uuid::new_v4()),
            is_enabled: true,
            shortcut: shortcut.into(),
            content: content.into(),
        }
    }
}

fn whole_phrase_regex(phrase: &str) -> Option<Regex> {
    Regex::new(&format!(r"(?i)(?<!\w){}(?!\w)", fancy_regex::escape(phrase))).ok()
}

fn replace_literal(regex: &Regex, text: &str, replacement: &str) -> String {
    regex
        .replace_all(text, fancy_regex::NoExpand(replacement))
        .into_owned()
}

/// `\n`, `\t`, `\r` become control characters; `\\` becomes a backslash.
fn process_escape_sequences(value: &str) -> String {
    const PLACEHOLDER: &str = "\u{0}";
    value
        .replace("\\\\", PLACEHOLDER)
        .replace("\\n", "\n")
        .replace("\\t", "\t")
        .replace("\\r", "\r")
        .replace(PLACEHOLDER, "\\")
}

pub fn apply_remappings(text: &str, remappings: &[WordRemapping]) -> String {
    let mut output = text.to_string();
    for remapping in remappings.iter().filter(|r| r.is_enabled) {
        let phrase = remapping.match_text.trim();
        if phrase.is_empty() {
            continue;
        }
        if let Some(regex) = whole_phrase_regex(phrase) {
            output = replace_literal(&regex, &output, &process_escape_sequences(&remapping.replacement));
        }
    }
    output
}

pub fn apply_snippets(text: &str, snippets: &[Snippet]) -> String {
    let mut enabled: Vec<&Snippet> = snippets
        .iter()
        .filter(|s| s.is_enabled && !s.shortcut.trim().is_empty())
        .collect();
    // Longer shortcuts first so "intro email long" wins over "intro email".
    enabled.sort_by_key(|s| std::cmp::Reverse(s.shortcut.chars().count()));
    let mut output = text.to_string();
    for snippet in enabled {
        if let Some(regex) = whole_phrase_regex(snippet.shortcut.trim()) {
            output = replace_literal(&regex, &output, &process_escape_sequences(&snippet.content));
        }
    }
    output
}

pub fn apply_removals(text: &str, removals: &[WordRemoval]) -> String {
    if text.is_empty() || removals.is_empty() {
        return text.to_string();
    }
    let mut output = text.to_string();
    let mut changed = false;
    for removal in removals.iter().filter(|r| r.is_enabled) {
        let pattern = removal.pattern.trim();
        if pattern.is_empty() {
            continue;
        }
        let Ok(regex) = Regex::new(&format!(r"(?i)(?<!\w)(?:{pattern})(?!\w)")) else {
            continue;
        };
        let updated = replace_literal(&regex, &output, "");
        if updated != output {
            changed = true;
            output = updated;
        }
    }
    if !changed {
        return text.to_string();
    }
    cleanup_after_removal(&output)
}

fn cleanup_after_removal(text: &str) -> String {
    let rules: [(&str, &str); 6] = [
        (r"[ \t]{2,}", " "),
        (r"[ \t]+([,\.!?;:])", "$1"),
        (r"([,\.!?;:])[ \t]*\1+", "$1"),
        (r"(?m)^[ \t]*[,\.!?;:]+[ \t]*", ""),
        (r"[ \t]+\n", "\n"),
        (r"\n[ \t]+", "\n"),
    ];
    let mut output = text.to_string();
    for (pattern, replacement) in rules {
        if let Ok(regex) = Regex::new(pattern) {
            output = regex.replace_all(&output, replacement).into_owned();
        }
    }
    output.trim().to_string()
}

// MARK: - Dictionary learning

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WordCorrection {
    pub match_text: String,
    pub replacement: String,
}

impl WordCorrection {
    pub fn new(match_text: impl Into<String>, replacement: impl Into<String>) -> Self {
        Self { match_text: match_text.into(), replacement: replacement.into() }
    }
}

fn is_word_char(c: char) -> bool {
    c.is_alphanumeric() || c == '\''
}

fn words(text: &str) -> Vec<String> {
    text.split(|c: char| !is_word_char(c))
        .filter(|w| !w.is_empty())
        .map(str::to_string)
        .collect()
}

fn eq_ignore_case(a: &str, b: &str) -> bool {
    a.to_lowercase() == b.to_lowercase()
}

/// Optimal string alignment distance: an adjacent transposition costs one.
fn edit_distance(source: &[char], replacement: &[char]) -> usize {
    if source.is_empty() {
        return replacement.len();
    }
    if replacement.is_empty() {
        return source.len();
    }
    let mut before_previous: Option<Vec<usize>> = None;
    let mut previous: Vec<usize> = (0..=replacement.len()).collect();
    for i in 1..=source.len() {
        let mut current = vec![0; replacement.len() + 1];
        current[0] = i;
        for j in 1..=replacement.len() {
            let cost = usize::from(source[i - 1] != replacement[j - 1]);
            current[j] = (previous[j] + 1).min(current[j - 1] + 1).min(previous[j - 1] + cost);
            if let Some(pp) = &before_previous {
                if i > 1 && j > 1 && source[i - 1] == replacement[j - 2] && source[i - 2] == replacement[j - 1] {
                    current[j] = current[j].min(pp[j - 2] + 1);
                }
            }
        }
        before_previous = Some(previous);
        previous = current;
    }
    previous[replacement.len()]
}

/// Dictionary learning cannot infer intent from arbitrary word swaps; only
/// words close enough to be a spelling fix qualify.
fn is_spelling_like(source: &str, replacement: &str) -> bool {
    let a: Vec<char> = source.to_lowercase().chars().collect();
    let b: Vec<char> = replacement.to_lowercase().chars().collect();
    let allowed = if a.len().min(b.len()) >= 5 { 2 } else { 1 };
    edit_distance(&a, &b) <= allowed
}

fn correction_between(match_text: &str, replacement: &str) -> Option<WordCorrection> {
    (!eq_ignore_case(match_text, replacement)
        && match_text.chars().count() > 1
        && replacement.chars().count() > 1
        && is_spelling_like(match_text, replacement))
    .then(|| WordCorrection::new(match_text, replacement))
}

pub fn detect_correction(before: &str, after: &str) -> Option<WordCorrection> {
    let mut all = detect_all_corrections(before, after);
    (all.len() == 1).then(|| all.remove(0))
}

/// Every spelling-like word swap between two snapshots of equal word count.
pub fn detect_all_corrections(before: &str, after: &str) -> Vec<WordCorrection> {
    let a = words(before);
    let b = words(after);
    if a.len() != b.len() || a.is_empty() {
        return Vec::new();
    }
    a.iter().zip(&b).filter_map(|(x, y)| correction_between(x, y)).collect()
}

pub fn contains_inserted_text(snapshot: &str, inserted: &str) -> bool {
    let inserted = words(inserted);
    let snapshot = words(snapshot);
    if inserted.is_empty() || snapshot.len() < inserted.len() {
        return false;
    }
    (0..=snapshot.len() - inserted.len()).any(|start| {
        snapshot[start..start + inserted.len()]
            .iter()
            .zip(&inserted)
            .all(|(a, b)| eq_ignore_case(a, b))
    })
}

pub fn detect_observed_correction(
    before_insertion: Option<&str>,
    baseline: Option<&str>,
    snapshot: &str,
    inserted: &str,
) -> Option<WordCorrection> {
    let mut all = detect_observed_corrections(before_insertion, baseline, snapshot, inserted);
    (all.len() == 1).then(|| all.remove(0))
}

/// Spelling corrections inside the exact phrase Tick inserted; edits elsewhere
/// in the field are ignored. A missing baseline is never enough evidence.
pub fn detect_observed_corrections(
    before_insertion: Option<&str>,
    baseline: Option<&str>,
    snapshot: &str,
    inserted: &str,
) -> Vec<WordCorrection> {
    let Some(baseline) = baseline else { return Vec::new() };
    if Some(snapshot) == before_insertion || !contains_inserted_text(baseline, inserted) {
        return Vec::new();
    }
    let base = words(baseline);
    let snap = words(snapshot);
    let ins = words(inserted);
    if base.len() != snap.len() || ins.len() > base.len() {
        return Vec::new();
    }
    let Some(start) = (0..=base.len() - ins.len()).find(|&start| {
        base[start..start + ins.len()].iter().zip(&ins).all(|(a, b)| eq_ignore_case(a, b))
    }) else {
        return Vec::new();
    };
    (start..start + ins.len())
        .filter_map(|i| correction_between(&base[i], &snap[i]))
        .collect()
}

/// Reconstructs edits to just-inserted text from keystrokes, for editors that
/// do not expose their value through Accessibility. Short-lived; it never
/// persists or logs keyboard input.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct KeystrokeTracker {
    original: String,
    characters: Vec<char>,
    caret: usize,
    anchor: Option<usize>,
}

impl KeystrokeTracker {
    pub fn new(inserted: &str) -> Self {
        let characters: Vec<char> = inserted.chars().collect();
        Self { original: inserted.to_string(), caret: characters.len(), characters, anchor: None }
    }

    pub fn current_text(&self) -> String {
        self.characters.iter().collect()
    }

    pub fn correction(&self) -> Option<WordCorrection> {
        detect_correction(&self.original, &self.current_text())
    }

    pub fn corrections(&self) -> Vec<WordCorrection> {
        detect_all_corrections(&self.original, &self.current_text())
    }

    /// Adopts a mouse selection that Accessibility revealed.
    pub fn select_word(&mut self, selected: &str) -> bool {
        let needle: Vec<char> = selected.chars().collect();
        if needle.is_empty() || !needle.iter().all(|c| is_word_char(*c)) {
            return false;
        }
        let boundary = |c: char| !c.is_alphanumeric();
        let found = (0..self.characters.len()).find(|&start| {
            let end = start + needle.len();
            end <= self.characters.len()
                && self.characters[start..end] == needle[..]
                && (start == 0 || boundary(self.characters[start - 1]))
                && (end == self.characters.len() || boundary(self.characters[end]))
        });
        let Some(start) = found else { return false };
        self.anchor = Some(start);
        self.caret = start + needle.len();
        true
    }

    /// Applies one key-down. Returns true when the text changed.
    pub fn apply(&mut self, key: Option<Key>, text: Option<&str>, modifiers: &Modifiers) -> bool {
        let Some(key) = key else { return false };
        let command = modifiers.contains_kind(ModifierKind::Command);
        let control = modifiers.contains_kind(ModifierKind::Control);
        let option = modifiers.contains_kind(ModifierKind::Option);
        let shift = modifiers.contains_kind(ModifierKind::Shift);
        match key {
            Key::LeftArrow => {
                let target = if command {
                    0
                } else if option {
                    self.previous_word_boundary()
                } else {
                    self.caret.saturating_sub(1)
                };
                self.move_caret(target, shift);
                false
            }
            Key::RightArrow => {
                let target = if command {
                    self.characters.len()
                } else if option {
                    self.next_word_boundary()
                } else {
                    self.caret + 1
                };
                self.move_caret(target, shift);
                false
            }
            Key::Home => {
                self.move_caret(0, shift);
                false
            }
            Key::End => {
                self.move_caret(self.characters.len(), shift);
                false
            }
            Key::Delete => {
                if self.remove_selection() {
                    return self.finish();
                }
                let start = if command {
                    0
                } else if option {
                    self.previous_word_boundary()
                } else {
                    self.caret.saturating_sub(1)
                };
                if start >= self.caret {
                    return false;
                }
                self.characters.drain(start..self.caret);
                self.caret = start;
                self.finish()
            }
            Key::ForwardDelete => {
                if self.remove_selection() {
                    return self.finish();
                }
                let end = if command {
                    self.characters.len()
                } else if option {
                    self.next_word_boundary()
                } else {
                    self.caret + 1
                }
                .min(self.characters.len());
                if self.caret >= end {
                    return false;
                }
                self.characters.drain(self.caret..end);
                self.finish()
            }
            _ => {
                let Some(text) = text.filter(|t| !t.is_empty()) else { return false };
                if command || control {
                    return false;
                }
                self.remove_selection();
                let inserted: Vec<char> = text.chars().collect();
                let count = inserted.len();
                self.characters.splice(self.caret..self.caret, inserted);
                self.caret += count;
                self.finish()
            }
        }
    }

    fn move_caret(&mut self, proposed: usize, selecting: bool) {
        if selecting {
            if self.anchor.is_none() {
                self.anchor = Some(self.caret);
            }
        } else {
            self.anchor = None;
        }
        self.caret = proposed.min(self.characters.len());
    }

    fn remove_selection(&mut self) -> bool {
        let Some(anchor) = self.anchor.take() else { return false };
        if anchor == self.caret {
            return false;
        }
        let (lower, upper) = (anchor.min(self.caret), anchor.max(self.caret));
        self.characters.drain(lower..upper);
        self.caret = lower;
        true
    }

    fn previous_word_boundary(&self) -> usize {
        let mut index = self.caret;
        while index > 0 && self.characters[index - 1].is_whitespace() {
            index -= 1;
        }
        while index > 0 && !self.characters[index - 1].is_whitespace() {
            index -= 1;
        }
        index
    }

    fn next_word_boundary(&self) -> usize {
        let mut index = self.caret;
        while index < self.characters.len() && !self.characters[index].is_whitespace() {
            index += 1;
        }
        while index < self.characters.len() && self.characters[index].is_whitespace() {
            index += 1;
        }
        index
    }

    fn finish(&mut self) -> bool {
        self.anchor = None;
        true
    }
}

/// Spoken emergency escape hatch: "force quit tick (now)".
pub fn is_force_quit_command(text: &str) -> bool {
    let normalized: Vec<String> = text
        .to_lowercase()
        .split(|c: char| !c.is_alphanumeric())
        .filter(|w| !w.is_empty())
        .map(str::to_string)
        .collect();
    let joined = normalized.join(" ");
    joined == "force quit tick now" || joined == "force quit tick"
}
