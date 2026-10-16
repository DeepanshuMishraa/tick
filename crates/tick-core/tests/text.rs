//! Ported from WordRemappingTests.swift and WordRemovalTests.swift.

use tick_core::hotkey::{Key, ModifierKind, Modifiers};
use tick_core::text::*;

fn wc(a: &str, b: &str) -> WordCorrection {
    WordCorrection::new(a, b)
}

#[test]
fn detects_one_word_correction() {
    assert_eq!(
        detect_correction("Please open kurzor in the browser", "Please open cursor in the browser"),
        Some(wc("kurzor", "cursor"))
    );
}

#[test]
fn detects_correction_with_punctuation() {
    assert_eq!(detect_correction("hello, how are you?", "helo, how are you?"), Some(wc("hello", "helo")));
}

#[test]
fn detects_repeated_letter_and_transposition() {
    assert_eq!(detect_correction("Use crook in this sentence", "Use crok in this sentence"), Some(wc("crook", "crok")));
    assert_eq!(detect_correction("Use form here", "Use from here"), Some(wc("form", "from")));
}

#[test]
fn ignores_semantic_replacement() {
    assert_eq!(detect_correction("I made the change", "I might the change"), None);
}

#[test]
fn baseline_must_contain_inserted_text() {
    assert!(contains_inserted_text("hello, how are you?", "hello, how are you?"));
    assert!(!contains_inserted_text("helo, how are you?", "hello, how are you?"));
}

#[test]
fn observed_corrections() {
    assert_eq!(
        detect_observed_correction(Some("Please say "), None, "zeros is changed to ones", "hello, how are you?"),
        None
    );
    assert_eq!(
        detect_observed_correction(
            Some("Please say "),
            Some("Please say hello, how are you?"),
            "Please say helo, how are you?",
            "hello, how are you?"
        ),
        Some(wc("hello", "helo"))
    );
    assert_eq!(
        detect_observed_corrections(
            Some("Prefix "),
            Some("Prefix open kurzor and teh file Suffix"),
            "Prefix open cursor and the file Suffix",
            "open kurzor and teh file"
        ),
        vec![wc("kurzor", "cursor"), wc("teh", "the")]
    );
    assert_eq!(
        detect_observed_correction(
            Some("Please say "),
            Some("Please say hello, how are you? Existing text"),
            "Please say hello, how are you? Changed text",
            "hello, how are you?"
        ),
        None
    );
    assert_eq!(detect_observed_correction(Some("Please say "), None, "Please say ", "hello, how are you?"), None);
}

#[test]
fn keystroke_reconstruction() {
    let none = Modifiers::empty();
    let mut tracker = KeystrokeTracker::new("hello, how are you?");
    tracker.apply(Some(Key::LeftArrow), None, &Modifiers::of(&[ModifierKind::Command]));
    tracker.apply(Some(Key::RightArrow), None, &none);
    tracker.apply(Some(Key::RightArrow), None, &none);
    tracker.apply(Some(Key::ForwardDelete), None, &none);
    assert_eq!(tracker.current_text(), "helo, how are you?");
    assert_eq!(tracker.correction(), Some(wc("hello", "helo")));

    let mut tracker = KeystrokeTracker::new("hello world");
    tracker.apply(Some(Key::LeftArrow), None, &Modifiers::of(&[ModifierKind::Command]));
    for _ in 0..5 {
        tracker.apply(Some(Key::RightArrow), None, &Modifiers::of(&[ModifierKind::Shift]));
    }
    for (key, text) in [(Key::H, "h"), (Key::E, "e"), (Key::L, "l"), (Key::O, "o")] {
        tracker.apply(Some(key), Some(text), &none);
    }
    assert_eq!(tracker.current_text(), "helo world");
    assert_eq!(tracker.correction(), Some(wc("hello", "helo")));

    let mut tracker = KeystrokeTracker::new("Use crook in this sentence");
    assert!(tracker.select_word("crook"));
    for (key, text) in [(Key::C, "c"), (Key::R, "r"), (Key::O, "o"), (Key::K, "k")] {
        tracker.apply(Some(key), Some(text), &none);
    }
    assert_eq!(tracker.current_text(), "Use crok in this sentence");
    assert_eq!(tracker.correction(), Some(wc("crook", "crok")));
}

#[test]
fn multiple_corrections() {
    assert_eq!(
        detect_all_corrections("open kurzor and fix teh label", "open cursor and fix the label"),
        vec![wc("kurzor", "cursor"), wc("teh", "the")]
    );
    assert_eq!(
        detect_all_corrections("I made teh change in kurzor", "I might the change in cursor"),
        vec![wc("teh", "the"), wc("kurzor", "cursor")]
    );
    assert_eq!(detect_correction("open kurzor and teh file", "open cursor and the file"), None);
    assert_eq!(detect_correction("open kurzor", "open cursor now"), None);
    assert_eq!(detect_correction("open kurzor now", "open cursor"), None);
}

#[test]
fn snippets_expand() {
    assert_eq!(
        apply_snippets("Send this to Gmail", &[Snippet::new("Gmail", "person@example.com")]),
        "Send this to person@example.com"
    );
}

#[test]
fn remappings() {
    let r = |m: &str, t: &str| vec![WordRemapping::new(m, t)];
    assert_eq!(apply_remappings("Hello comma world", &r("comma", ",")), "Hello , world");
    assert_eq!(apply_remappings("Hello new line world", &r("new line", "\\n")), "Hello \n world");
    assert_eq!(apply_remappings("Hello new paragraph world", &r("new paragraph", "\\n\\n")), "Hello \n\n world");
    assert_eq!(apply_remappings("Hello tab world", &r("tab", "\\t")), "Hello \t world");
    assert_eq!(apply_remappings("Hello backslash world", &r("backslash", "\\\\")), "Hello \\ world");
    assert_eq!(apply_remappings("Hello code world", &r("code", "\\\\n")), "Hello \\n world");
    assert_eq!(apply_remappings("Hello comma world", &r("COMMA", ",")), "Hello , world");
    assert_eq!(apply_remappings("renewable energy", &r("new", "\\n")), "renewable energy");
    let mut disabled = WordRemapping::new("comma", ",");
    disabled.is_enabled = false;
    assert_eq!(apply_remappings("Hello comma world", &[disabled]), "Hello comma world");
    let many = vec![
        WordRemapping::new("comma", ","),
        WordRemapping::new("period", "."),
        WordRemapping::new("new line", "\\n"),
    ];
    assert_eq!(apply_remappings("Hello comma new line world period", &many), "Hello , \n world .");
}

#[test]
fn removals() {
    let all: Vec<WordRemoval> = ["uh+", "um+", "er+", "hm+"].into_iter().map(WordRemoval::new).collect();
    assert_eq!(apply_removals("Umm uhhh er hmm", &all), "");
    let two: Vec<WordRemoval> = ["uh+", "um+"].into_iter().map(WordRemoval::new).collect();
    assert_eq!(apply_removals("Well, um, that's uh fine", &two), "Well, that's fine");
    assert_eq!(apply_removals("thumb", &[WordRemoval::new("um+")]), "thumb");
    assert_eq!(apply_removals("um, hello", &[WordRemoval::new("um+")]), "hello");
}

#[test]
fn force_quit_phrase() {
    assert!(is_force_quit_command("Force quit Tick now."));
    assert!(!is_force_quit_command("force quit the app"));
}
