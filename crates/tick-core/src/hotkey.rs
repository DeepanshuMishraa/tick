//! Keys, modifiers, and hotkey chords.
//!
//! Serialized names match the Swift `Sauce.Key` and `Modifier` encodings so
//! settings written by earlier versions decode unchanged.

use serde::{Deserialize, Deserializer, Serialize, Serializer};

/// A physical key, named after its US-QWERTY meaning.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Key {
    A, S, D, F, H, G, Z, X, C, V, B, Q, W, E, R, Y, T,
    One, Two, Three, Four, Six, Five, Equal, Nine, Seven, Minus, Eight, Zero,
    RightBracket, O, U, LeftBracket, I, P, L, J, Quote, K, Semicolon, Backslash,
    Comma, Slash, N, M, Period, Grave,
    KeypadDecimal, KeypadMultiply, KeypadPlus, KeypadClear, KeypadDivide, KeypadEnter,
    KeypadMinus, KeypadEquals, KeypadZero, KeypadOne, KeypadTwo, KeypadThree, KeypadFour,
    KeypadFive, KeypadSix, KeypadSeven, KeypadEight, KeypadNine,
    Return, Tab, Space, Delete, Escape,
    F1, F2, F3, F4, F5, F6, F7, F8, F9, F10, F11, F12, F13, F14, F15, F16, F17, F18, F19, F20,
    Help, Home, PageUp, ForwardDelete, End, PageDown,
    LeftArrow, RightArrow, DownArrow, UpArrow,
    Yen, Underscore, KeypadComma, Eisu, Kana, AtSign, Caret, Colon, Section,
}

impl Key {
    /// Key for a US-QWERTY virtual key code (`kVK_*`).
    pub fn from_qwerty_key_code(code: u16) -> Option<Self> {
        use Key::*;
        Some(match code {
            0 => A, 1 => S, 2 => D, 3 => F, 4 => H, 5 => G, 6 => Z, 7 => X, 8 => C, 9 => V,
            10 => Section, 11 => B, 12 => Q, 13 => W, 14 => E, 15 => R, 16 => Y, 17 => T,
            18 => One, 19 => Two, 20 => Three, 21 => Four, 22 => Six, 23 => Five, 24 => Equal,
            25 => Nine, 26 => Seven, 27 => Minus, 28 => Eight, 29 => Zero, 30 => RightBracket,
            31 => O, 32 => U, 33 => LeftBracket, 34 => I, 35 => P, 36 => Return, 37 => L,
            38 => J, 39 => Quote, 40 => K, 41 => Semicolon, 42 => Backslash, 43 => Comma,
            44 => Slash, 45 => N, 46 => M, 47 => Period, 48 => Tab, 49 => Space, 50 => Grave,
            51 => Delete, 53 => Escape, 64 => F17, 65 => KeypadDecimal, 67 => KeypadMultiply,
            69 => KeypadPlus, 71 => KeypadClear, 75 => KeypadDivide, 76 => KeypadEnter,
            78 => KeypadMinus, 79 => F18, 80 => F19, 81 => KeypadEquals, 82 => KeypadZero,
            83 => KeypadOne, 84 => KeypadTwo, 85 => KeypadThree, 86 => KeypadFour,
            87 => KeypadFive, 88 => KeypadSix, 89 => KeypadSeven, 90 => F20, 91 => KeypadEight,
            92 => KeypadNine, 93 => Yen, 94 => Underscore, 95 => KeypadComma, 96 => F5,
            97 => F6, 98 => F7, 99 => F3, 100 => F8, 101 => F9, 102 => Eisu, 103 => F11,
            104 => Kana, 105 => F13, 106 => F16, 107 => F14, 109 => F10, 111 => F12,
            113 => F15, 114 => Help, 115 => Home, 116 => PageUp, 117 => ForwardDelete,
            118 => F4, 119 => End, 120 => F2, 121 => PageDown, 122 => F1, 123 => LeftArrow,
            124 => RightArrow, 125 => DownArrow, 126 => UpArrow,
            _ => return None,
        })
    }

    /// US-QWERTY virtual key code (`kVK_*`) for this key.
    pub fn qwerty_key_code(self) -> u16 {
        (0u16..=127)
            .find(|code| Self::from_qwerty_key_code(*code) == Some(self))
            .unwrap_or(match self {
                Key::AtSign => 33,
                Key::Caret => 24,
                Key::Colon => 39,
                _ => 0,
            })
    }

    /// Key for the character a key code produces in the active layout,
    /// mirroring `Sauce.Key(character:virtualKeyCode:)` so non-QWERTY layouts
    /// map letters by what they type.
    pub fn from_character(character: &str, key_code: u16) -> Option<Self> {
        use Key::*;
        const KEYPAD_0: u16 = 82;
        let keypad = |digit: u16| match digit {
            0 => KEYPAD_0,
            1..=7 => 82 + digit,
            8 => 91,
            _ => 92,
        };
        let lower = character.to_lowercase();
        Some(match lower.as_str() {
            "a" => A, "s" => S, "d" => D, "f" => F, "h" => H, "g" => G, "z" => Z, "x" => X,
            "c" => C, "v" => V, "b" => B, "q" => Q, "w" => W, "e" => E, "r" => R, "y" => Y,
            "t" => T, "o" => O, "u" => U, "i" => I, "p" => P, "l" => L, "j" => J, "k" => K,
            "n" => N, "m" => M,
            "]" => RightBracket, "[" => LeftBracket, "'" => Quote, ";" => Semicolon,
            "\\" => Backslash, "`" => Grave, " " => Space, "*" => KeypadMultiply,
            "+" => KeypadPlus, "¥" => Yen, "_" => Underscore, "@" => AtSign, "^" => Caret,
            ":" => Colon, "§" => Section,
            "," => if key_code == 95 { KeypadComma } else { Comma },
            "/" => if key_code == 75 { KeypadDivide } else { Slash },
            "." => if key_code == 65 { KeypadDecimal } else { Period },
            "-" => if key_code == 78 { KeypadMinus } else { Minus },
            "=" => if key_code == 81 { KeypadEquals } else { Equal },
            digit if digit.len() == 1 && digit.as_bytes()[0].is_ascii_digit() => {
                let value = u16::from(digit.as_bytes()[0] - b'0');
                let is_keypad = key_code == keypad(value);
                match (value, is_keypad) {
                    (0, false) => Zero, (1, false) => One, (2, false) => Two,
                    (3, false) => Three, (4, false) => Four, (5, false) => Five,
                    (6, false) => Six, (7, false) => Seven, (8, false) => Eight,
                    (9, false) => Nine, (0, true) => KeypadZero, (1, true) => KeypadOne,
                    (2, true) => KeypadTwo, (3, true) => KeypadThree, (4, true) => KeypadFour,
                    (5, true) => KeypadFive, (6, true) => KeypadSix, (7, true) => KeypadSeven,
                    (8, true) => KeypadEight, _ => KeypadNine,
                }
            }
            _ => return None,
        })
    }

    /// Short label shown in hotkey chips.
    pub fn label(self) -> String {
        use Key::*;
        let fixed = match self {
            Escape => "⎋", Space => "␣", Zero => "0", One => "1", Two => "2", Three => "3",
            Four => "4", Five => "5", Six => "6", Seven => "7", Eight => "8", Nine => "9",
            Period => ".", Comma => ",", Slash => "/", Quote => "\"", Backslash => "\\",
            LeftArrow => "←", RightArrow => "→", UpArrow => "↑", DownArrow => "↓",
            Return => "↩", Tab => "⇥", Delete => "⌫", ForwardDelete => "⌦",
            _ => "",
        };
        if !fixed.is_empty() {
            return fixed.to_string();
        }
        serde_json::to_value(self)
            .ok()
            .and_then(|value| value.as_str().map(str::to_uppercase))
            .unwrap_or_default()
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ModifierKind {
    Command,
    Option,
    Shift,
    Control,
    Fn,
}

impl ModifierKind {
    pub const ALL: [ModifierKind; 5] = [
        ModifierKind::Command,
        ModifierKind::Option,
        ModifierKind::Shift,
        ModifierKind::Control,
        ModifierKind::Fn,
    ];

    pub fn display_name(self) -> &'static str {
        match self {
            ModifierKind::Command => "Command",
            ModifierKind::Option => "Option",
            ModifierKind::Shift => "Shift",
            ModifierKind::Control => "Control",
            ModifierKind::Fn => "fn",
        }
    }

    pub fn symbol(self) -> &'static str {
        match self {
            ModifierKind::Option => "⌥",
            ModifierKind::Shift => "⇧",
            ModifierKind::Command => "⌘",
            ModifierKind::Control => "⌃",
            ModifierKind::Fn => "fn",
        }
    }

    pub fn supports_side_selection(self) -> bool {
        self != ModifierKind::Fn
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ModifierSide {
    #[default]
    Either,
    Left,
    Right,
}

impl ModifierSide {
    pub const ALL: [ModifierSide; 3] = [ModifierSide::Either, ModifierSide::Left, ModifierSide::Right];

    fn order(self) -> u8 {
        match self {
            ModifierSide::Left => 0,
            ModifierSide::Either => 1,
            ModifierSide::Right => 2,
        }
    }

    pub fn display_name(self) -> &'static str {
        match self {
            ModifierSide::Either => "Either",
            ModifierSide::Left => "Left",
            ModifierSide::Right => "Right",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct Modifier {
    pub kind: ModifierKind,
    pub side: ModifierSide,
}

impl Modifier {
    pub const fn new(kind: ModifierKind) -> Self {
        Self { kind, side: ModifierSide::Either }
    }

    pub const fn sided(kind: ModifierKind, side: ModifierSide) -> Self {
        Self { kind, side }
    }

    fn matches(self, other: Modifier) -> bool {
        self.kind == other.kind
            && (self.side == ModifierSide::Either
                || other.side == ModifierSide::Either
                || self.side == other.side)
    }
}

impl PartialOrd for Modifier {
    fn partial_cmp(&self, other: &Self) -> Option<std::cmp::Ordering> {
        Some(self.cmp(other))
    }
}

impl Ord for Modifier {
    fn cmp(&self, other: &Self) -> std::cmp::Ordering {
        self.kind
            .cmp(&other.kind)
            .then(self.side.order().cmp(&other.side.order()))
    }
}

impl Serialize for Modifier {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        #[derive(Serialize)]
        struct Repr {
            kind: ModifierKind,
            side: ModifierSide,
        }
        Repr { kind: self.kind, side: self.side }.serialize(serializer)
    }
}

impl<'de> Deserialize<'de> for Modifier {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        // Legacy settings stored bare kind strings ("option").
        #[derive(Deserialize)]
        #[serde(untagged)]
        enum Repr {
            Legacy(ModifierKind),
            Full {
                kind: ModifierKind,
                #[serde(default)]
                side: ModifierSide,
            },
        }
        Ok(match Repr::deserialize(deserializer)? {
            Repr::Legacy(kind) => Modifier::new(kind),
            Repr::Full { kind, side } => Modifier { kind, side },
        })
    }
}

/// A set of held modifiers. Sides are significant only when explicitly chosen.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct Modifiers {
    modifiers: Vec<Modifier>,
}

impl PartialEq for Modifiers {
    fn eq(&self, other: &Self) -> bool {
        self.sorted_all() == other.sorted_all()
    }
}

impl Eq for Modifiers {}

impl Modifiers {
    pub fn new(items: impl IntoIterator<Item = Modifier>) -> Self {
        let mut modifiers: Vec<Modifier> = Vec::new();
        for item in items {
            if !modifiers.contains(&item) {
                modifiers.push(item);
            }
        }
        Self { modifiers }
    }

    pub fn of(kinds: &[ModifierKind]) -> Self {
        Self::new(kinds.iter().copied().map(Modifier::new))
    }

    pub fn empty() -> Self {
        Self::default()
    }

    fn sorted_all(&self) -> Vec<Modifier> {
        let mut all = self.modifiers.clone();
        all.sort();
        all
    }

    /// Sorted for display; empty for the four-modifier "hyper" chord, which
    /// is shown as a single glyph.
    pub fn sorted(&self) -> Vec<Modifier> {
        if self.is_hyperkey() { Vec::new() } else { self.sorted_all() }
    }

    pub fn iter(&self) -> impl Iterator<Item = &Modifier> {
        self.modifiers.iter()
    }

    pub fn is_hyperkey(&self) -> bool {
        [ModifierKind::Command, ModifierKind::Option, ModifierKind::Shift, ModifierKind::Control]
            .iter()
            .all(|kind| self.contains_kind(*kind))
    }

    pub fn is_empty(&self) -> bool {
        self.modifiers.is_empty()
    }

    pub fn contains(&self, modifier: Modifier) -> bool {
        self.modifiers.iter().any(|candidate| candidate.matches(modifier))
    }

    pub fn contains_kind(&self, kind: ModifierKind) -> bool {
        self.modifiers.iter().any(|candidate| candidate.kind == kind)
    }

    pub fn kinds(&self) -> Vec<ModifierKind> {
        let mut kinds: Vec<ModifierKind> = self.modifiers.iter().map(|m| m.kind).collect();
        kinds.sort();
        kinds.dedup();
        kinds
    }

    pub fn is_subset_of(&self, other: &Modifiers) -> bool {
        self.modifiers.iter().all(|modifier| other.contains(*modifier))
    }

    pub fn union(&self, other: &Modifiers) -> Modifiers {
        Modifiers::new(self.modifiers.iter().chain(other.modifiers.iter()).copied())
    }

    pub fn matches_exactly(&self, expected: &Modifiers) -> bool {
        if !expected.modifiers.iter().all(|requirement| self.contains(*requirement)) {
            return false;
        }
        self.modifiers.iter().all(|candidate| {
            expected
                .modifiers
                .iter()
                .find(|requirement| requirement.kind == candidate.kind)
                .is_some_and(|requirement| candidate.matches(*requirement))
        })
    }

    pub fn side(&self, kind: ModifierKind) -> Option<ModifierSide> {
        self.modifiers.iter().find(|m| m.kind == kind).map(|m| m.side)
    }

    pub fn setting(&self, kind: ModifierKind, side: ModifierSide) -> Modifiers {
        Modifiers::new(
            self.modifiers
                .iter()
                .copied()
                .filter(|m| m.kind != kind)
                .chain(std::iter::once(Modifier::sided(kind, side))),
        )
    }

    pub fn erasing_sides(&self) -> Modifiers {
        Modifiers::new(self.modifiers.iter().map(|m| Modifier::new(m.kind)))
    }

    pub fn removing(&self, kind: ModifierKind) -> Modifiers {
        Modifiers::new(self.modifiers.iter().copied().filter(|m| m.kind != kind))
    }

    /// Parses `CGEventFlags`, including device-dependent left/right bits.
    pub fn from_event_flags(flags: u64) -> Modifiers {
        const SHIFT: u64 = 0x0002_0000;
        const CONTROL: u64 = 0x0004_0000;
        const OPTION: u64 = 0x0008_0000;
        const COMMAND: u64 = 0x0010_0000;
        const FN: u64 = 0x0080_0000;
        let mut result = Vec::new();
        let mut insert = |kind, general: u64, left: u64, right: u64| {
            let mut specific = false;
            if flags & left != 0 {
                result.push(Modifier::sided(kind, ModifierSide::Left));
                specific = true;
            }
            if flags & right != 0 {
                result.push(Modifier::sided(kind, ModifierSide::Right));
                specific = true;
            }
            if !specific && flags & general != 0 {
                result.push(Modifier::new(kind));
            }
        };
        insert(ModifierKind::Shift, SHIFT, 0x02, 0x04);
        insert(ModifierKind::Control, CONTROL, 0x01, 0x2000);
        insert(ModifierKind::Option, OPTION, 0x20, 0x40);
        insert(ModifierKind::Command, COMMAND, 0x08, 0x10);
        if flags & FN != 0 {
            result.push(Modifier::new(ModifierKind::Fn));
        }
        Modifiers::new(result)
    }

    /// Glyph string such as "⌥⇧" (or "✦" for the hyper chord).
    pub fn label(&self) -> String {
        if self.is_hyperkey() {
            let fn_suffix = if self.contains_kind(ModifierKind::Fn) { "fn" } else { "" };
            return format!("✦{fn_suffix}");
        }
        self.sorted().iter().map(|m| m.kind.symbol()).collect()
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct HotKey {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub key: Option<Key>,
    pub modifiers: Modifiers,
}

impl HotKey {
    pub fn new(key: Option<Key>, modifiers: Modifiers) -> Self {
        Self { key, modifiers }
    }

    pub fn is_modifier_only(&self) -> bool {
        self.key.is_none()
    }

    pub fn label(&self) -> String {
        let mut text = self.modifiers.label();
        if let Some(key) = self.key {
            text.push_str(&key.label());
        }
        text
    }
}

/// One keyboard state transition reported by the global event tap.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct KeyEvent {
    pub key: Option<Key>,
    pub modifiers: Modifiers,
    pub text: Option<String>,
    pub is_key_down: bool,
}

impl KeyEvent {
    pub fn new(key: Option<Key>, modifiers: Modifiers) -> Self {
        Self { key, modifiers, text: None, is_key_down: true }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum InputEvent {
    Keyboard(KeyEvent),
    MouseClick,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn decodes_legacy_and_sided_modifiers() {
        let legacy: Modifiers = serde_json::from_str(r#"{"modifiers":["option","shift"]}"#).unwrap();
        assert_eq!(legacy, Modifiers::of(&[ModifierKind::Option, ModifierKind::Shift]));
        let sided: HotKey = serde_json::from_str(
            r#"{"modifiers":{"modifiers":[{"kind":"option","side":"right"}]}}"#,
        )
        .unwrap();
        assert_eq!(sided.key, None);
        assert_eq!(sided.modifiers.side(ModifierKind::Option), Some(ModifierSide::Right));
    }

    #[test]
    fn key_names_match_swift_raw_values() {
        assert_eq!(serde_json::to_string(&Key::RightBracket).unwrap(), "\"rightBracket\"");
        assert_eq!(serde_json::to_string(&Key::F12).unwrap(), "\"f12\"");
        assert_eq!(serde_json::to_string(&Key::Return).unwrap(), "\"return\"");
        assert_eq!(serde_json::from_str::<Key>("\"keypadZero\"").unwrap(), Key::KeypadZero);
    }

    #[test]
    fn key_code_round_trips() {
        for code in 0u16..=127 {
            if let Some(key) = Key::from_qwerty_key_code(code) {
                assert_eq!(key.qwerty_key_code(), code);
            }
        }
    }

    #[test]
    fn character_mapping_distinguishes_keypad() {
        assert_eq!(Key::from_character("1", 18), Some(Key::One));
        assert_eq!(Key::from_character("1", 83), Some(Key::KeypadOne));
        assert_eq!(Key::from_character("A", 0), Some(Key::A));
        assert_eq!(Key::from_character(".", 65), Some(Key::KeypadDecimal));
    }

    #[test]
    fn exact_matching_respects_sides() {
        let right_option = Modifiers::new([Modifier::sided(ModifierKind::Option, ModifierSide::Right)]);
        let left_held = Modifiers::new([Modifier::sided(ModifierKind::Option, ModifierSide::Left)]);
        let right_held = Modifiers::new([Modifier::sided(ModifierKind::Option, ModifierSide::Right)]);
        assert!(!left_held.matches_exactly(&right_option));
        assert!(right_held.matches_exactly(&right_option));
        assert!(right_held.matches_exactly(&Modifiers::of(&[ModifierKind::Option])));
    }

    #[test]
    fn event_flags_capture_sides() {
        // Right option + generic option mask.
        let modifiers = Modifiers::from_event_flags(0x0008_0000 | 0x40);
        assert_eq!(modifiers.side(ModifierKind::Option), Some(ModifierSide::Right));
    }
}
