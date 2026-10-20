//! User settings persisted as `tick_settings.json`.
//!
//! The JSON shape matches the Swift app's settings encoding, including
//! its legacy-value migrations, so upgrading keeps every preference.

use serde::{Deserialize, Deserializer, Serialize};

use crate::constants::{BASE_SOUND_EFFECTS_VOLUME, DEFAULT_MINIMUM_KEY_TIME};
use crate::hotkey::{HotKey, Key, ModifierKind, Modifiers};
use crate::models::ParakeetModel;
use crate::text::{Snippet, WordRemapping, WordRemoval};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum RecordingAudioBehavior {
    Mute,
    #[default]
    DoNothing,
}

impl<'de> Deserialize<'de> for RecordingAudioBehavior {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        // The removed "pauseMedia" option (and anything unknown) maps to Do Nothing.
        Ok(match String::deserialize(deserializer)?.as_str() {
            "mute" => Self::Mute,
            _ => Self::DoNothing,
        })
    }
}

impl RecordingAudioBehavior {
    pub const ALL: [Self; 2] = [Self::Mute, Self::DoNothing];
    pub fn display_name(self) -> &'static str {
        match self {
            Self::Mute => "Mute volume",
            Self::DoNothing => "Leave audio",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum RecordingIndicatorStyle {
    Notch,
    #[default]
    Pill,
}

impl RecordingIndicatorStyle {
    pub const ALL: [Self; 2] = [Self::Pill, Self::Notch];
    pub fn display_name(self) -> &'static str {
        match self {
            Self::Notch => "Notch",
            Self::Pill => "Floating pill",
        }
    }
}

/// Light or dark interface, or whichever macOS is using.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum AppearanceMode {
    #[default]
    System,
    Light,
    Dark,
}

impl AppearanceMode {
    pub const ALL: [Self; 3] = [Self::System, Self::Light, Self::Dark];
    pub fn display_name(self) -> &'static str {
        match self {
            Self::System => "System",
            Self::Light => "Light",
            Self::Dark => "Dark",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ThemeColor {
    Multicolor,
    Blue,
    Purple,
    Pink,
    Red,
    Orange,
    Yellow,
    Green,
    #[default]
    Monochrome,
}

impl ThemeColor {
    pub const ALL: [Self; 9] = [
        Self::Monochrome,
        Self::Blue,
        Self::Purple,
        Self::Pink,
        Self::Red,
        Self::Orange,
        Self::Yellow,
        Self::Green,
        Self::Multicolor,
    ];

    pub fn display_name(self) -> &'static str {
        match self {
            Self::Multicolor => "Multicolor",
            Self::Blue => "Blue",
            Self::Purple => "Purple",
            Self::Pink => "Pink",
            Self::Red => "Red",
            Self::Orange => "Orange",
            Self::Yellow => "Yellow",
            Self::Green => "Green",
            Self::Monochrome => "Monochrome",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum AiPostProcessingMode {
    #[default]
    Off,
    On,
}

impl<'de> Deserialize<'de> for AiPostProcessingMode {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        Ok(match String::deserialize(deserializer)?.as_str() {
            "on" | "appAware" => Self::On,
            _ => Self::Off,
        })
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
pub enum OnDeviceAiModel {
    #[default]
    #[serde(rename = "Qwen3-1.7B-MLX-4bit")]
    Qwen3_1_7B,
    #[serde(rename = "Qwen3-0.6B-MLX-4bit")]
    Qwen3_0_6B,
}

impl OnDeviceAiModel {
    pub const ALL: [Self; 2] = [Self::Qwen3_1_7B, Self::Qwen3_0_6B];

    pub fn directory_name(self) -> &'static str {
        match self {
            Self::Qwen3_1_7B => "Qwen3-1.7B-MLX-4bit",
            Self::Qwen3_0_6B => "Qwen3-0.6B-MLX-4bit",
        }
    }

    pub fn display_name(self) -> &'static str {
        match self {
            Self::Qwen3_1_7B => "Qwen3 1.7B",
            Self::Qwen3_0_6B => "Qwen3 0.6B",
        }
    }

    pub fn approximate_size(self) -> &'static str {
        match self {
            Self::Qwen3_1_7B => "914 MB",
            Self::Qwen3_0_6B => "302 MB",
        }
    }

    pub fn tagline(self) -> &'static str {
        match self {
            Self::Qwen3_1_7B => "Most precise. Handles lists, context and long paragraphs.",
            Self::Qwen3_0_6B => "Fastest. A light footprint for short, quick dictations.",
        }
    }

    pub fn remote_base_url(self) -> &'static str {
        match self {
            Self::Qwen3_1_7B => "https://pub-54623ce7fca847f9aec8c62f976b6c09.r2.dev/tick/models",
            Self::Qwen3_0_6B => "https://pub-54623ce7fca847f9aec8c62f976b6c09.r2.dev/tick/models/qwen3-0.6b",
        }
    }

    /// Files and exact byte sizes; sizes double as integrity checks.
    pub fn files(self) -> &'static [(&'static str, u64)] {
        match self {
            Self::Qwen3_1_7B => &[
                ("config.json", 988),
                ("merges.txt", 1_671_853),
                ("model.safetensors.index.json", 49_731),
                ("tokenizer.json", 11_422_654),
                ("tokenizer_config.json", 8_311),
                ("vocab.json", 2_776_833),
                ("model.safetensors", 914_316_100),
            ],
            Self::Qwen3_0_6B => &[
                ("config.json", 988),
                ("merges.txt", 1_671_853),
                ("model.safetensors.index.json", 49_731),
                ("tokenizer.json", 11_422_654),
                ("tokenizer_config.json", 9_689),
                ("vocab.json", 2_776_833),
                ("model.safetensors", 316_825_742),
            ],
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
pub enum GroqModel {
    #[default]
    #[serde(rename = "openai/gpt-oss-20b")]
    GptOss20B,
    #[serde(rename = "openai/gpt-oss-120b")]
    GptOss120B,
    #[serde(rename = "qwen/qwen3.6-27b")]
    Qwen36,
    #[serde(rename = "qwen/qwen3.8-27b")]
    Qwen38,
    #[serde(rename = "groq/compound-mini")]
    CompoundMini,
}

impl GroqModel {
    pub const ALL: [Self; 5] = [Self::GptOss20B, Self::GptOss120B, Self::Qwen36, Self::Qwen38, Self::CompoundMini];

    pub fn api_name(self) -> &'static str {
        match self {
            Self::GptOss20B => "openai/gpt-oss-20b",
            Self::GptOss120B => "openai/gpt-oss-120b",
            Self::Qwen36 => "qwen/qwen3.6-27b",
            Self::Qwen38 => "qwen/qwen3.8-27b",
            Self::CompoundMini => "groq/compound-mini",
        }
    }

    pub fn display_name(self) -> &'static str {
        match self {
            Self::GptOss20B => "GPT-OSS 20B",
            Self::GptOss120B => "GPT-OSS 120B",
            Self::Qwen36 => "Qwen 3.6 27B",
            Self::Qwen38 => "Qwen 3.8 27B",
            Self::CompoundMini => "Groq Compound Mini",
        }
    }

    /// Qwen models reason by default; Groq lets us switch that off.
    pub fn disables_reasoning(self) -> bool {
        matches!(self, Self::Qwen36 | Self::Qwen38)
    }
}

/// Writing style used by AI formatting. Stored as an index for compatibility.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WritingStyle {
    Formal,
    Casual,
    VeryCasual,
}

impl WritingStyle {
    pub const ALL: [Self; 3] = [Self::Formal, Self::Casual, Self::VeryCasual];

    pub fn from_index(index: i64) -> Self {
        match index {
            0 => Self::Formal,
            1 => Self::Casual,
            _ => Self::VeryCasual,
        }
    }

    pub fn index(self) -> i64 {
        match self {
            Self::Formal => 0,
            Self::Casual => 1,
            Self::VeryCasual => 2,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum RecordingRetention {
    #[default]
    Forever,
    OneDay,
    ThreeDays,
    SevenDays,
    OneMonth,
}

impl RecordingRetention {
    pub const ALL: [Self; 5] = [Self::Forever, Self::OneDay, Self::ThreeDays, Self::SevenDays, Self::OneMonth];

    pub fn display_name(self) -> &'static str {
        match self {
            Self::Forever => "Forever",
            Self::OneDay => "1 day",
            Self::ThreeDays => "3 days",
            Self::SevenDays => "7 days",
            Self::OneMonth => "1 month",
        }
    }

    /// Maximum age in seconds, or `None` to keep everything.
    pub fn max_age(self) -> Option<f64> {
        const DAY: f64 = 24.0 * 60.0 * 60.0;
        match self {
            Self::Forever => None,
            Self::OneDay => Some(DAY),
            Self::ThreeDays => Some(3.0 * DAY),
            Self::SevenDays => Some(7.0 * DAY),
            Self::OneMonth => Some(30.0 * DAY),
        }
    }
}

fn default_true() -> bool {
    true
}

fn default_volume() -> f64 {
    BASE_SOUND_EFFECTS_VOLUME
}

fn default_hotkey() -> HotKey {
    HotKey::new(None, Modifiers::of(&[ModifierKind::Option]))
}

fn default_model() -> String {
    ParakeetModel::MultilingualV3.identifier().to_string()
}

fn default_minimum_key_time() -> f64 {
    DEFAULT_MINIMUM_KEY_TIME
}

fn default_style_index() -> i64 {
    2
}

pub fn default_paste_last_hotkey() -> HotKey {
    HotKey::new(Some(Key::V), Modifiers::of(&[ModifierKind::Option, ModifierKind::Shift]))
}

fn default_paste_last() -> Option<HotKey> {
    Some(default_paste_last_hotkey())
}

/// Distinguishes an explicitly cleared shortcut (`null`) from a missing key.
fn nullable_hotkey<'de, D: Deserializer<'de>>(deserializer: D) -> Result<Option<HotKey>, D::Error> {
    Option::<HotKey>::deserialize(deserializer)
}

pub fn default_walkthrough_hotkey() -> HotKey {
    HotKey::new(Some(Key::S), Modifiers::of(&[ModifierKind::Option, ModifierKind::Shift]))
}

fn default_walkthrough() -> Option<HotKey> {
    Some(default_walkthrough_hotkey())
}

fn default_removals() -> Vec<WordRemoval> {
    ["uh+", "um+", "er+", "hm+"].into_iter().map(WordRemoval::new).collect()
}

fn default_snippets() -> Vec<Snippet> {
    vec![
        Snippet::new("LinkedIn", "https://www.linkedin.com/in/john-doe-9b0139134/"),
        Snippet::new("intro email", "Hey, would love to find some time to chat later..."),
        Snippet::new("my calendly link", "calendly.com/you/invite-name"),
    ]
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Settings {
    #[serde(default = "default_true")]
    pub sound_effects_enabled: bool,
    #[serde(default = "default_volume")]
    pub sound_effects_volume: f64,
    #[serde(default = "default_hotkey")]
    pub hotkey: HotKey,
    #[serde(default)]
    pub open_on_login: bool,
    #[serde(default = "default_true")]
    pub show_dock_icon: bool,
    /// Main window sidebar shown as an icon rail.
    #[serde(default)]
    pub sidebar_collapsed: bool,
    #[serde(default = "default_model")]
    pub selected_model: String,
    #[serde(default = "default_true")]
    pub use_clipboard_paste: bool,
    #[serde(default = "default_true")]
    pub prevent_system_sleep: bool,
    #[serde(default)]
    pub recording_audio_behavior: RecordingAudioBehavior,
    #[serde(default)]
    pub recording_indicator_style: RecordingIndicatorStyle,
    #[serde(default = "default_minimum_key_time")]
    pub minimum_key_time: f64,
    #[serde(default)]
    pub copy_to_clipboard: bool,
    #[serde(default)]
    pub super_fast_mode_enabled: bool,
    #[serde(default)]
    pub use_double_tap_only: bool,
    #[serde(default = "default_true")]
    pub double_tap_lock_enabled: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub output_language: Option<String>,
    #[serde(default, rename = "selectedMicrophoneID", skip_serializing_if = "Option::is_none")]
    pub selected_microphone_id: Option<String>,
    #[serde(default = "default_true")]
    pub save_transcription_history: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub max_history_entries: Option<i64>,
    #[serde(default)]
    pub recording_retention: RecordingRetention,
    #[serde(default = "default_paste_last", deserialize_with = "nullable_hotkey")]
    pub paste_last_transcript_hotkey: Option<HotKey>,
    /// Starts and finishes a walkthrough recording.
    #[serde(default = "default_walkthrough", deserialize_with = "nullable_hotkey")]
    pub walkthrough_hotkey: Option<HotKey>,
    #[serde(default)]
    pub has_completed_model_bootstrap: bool,
    #[serde(default)]
    pub has_completed_storage_migration: bool,
    #[serde(default)]
    pub word_removals_enabled: bool,
    #[serde(default = "default_removals")]
    pub word_removals: Vec<WordRemoval>,
    #[serde(default)]
    pub word_remappings: Vec<WordRemapping>,
    #[serde(default)]
    pub ai_post_processing_mode: AiPostProcessingMode,
    #[serde(default, rename = "selectedAIModel")]
    pub selected_ai_model: OnDeviceAiModel,
    #[serde(default)]
    pub selected_groq_model: GroqModel,
    #[serde(default = "default_style_index")]
    pub selected_style_index: i64,
    #[serde(default)]
    pub has_selected_style: bool,
    #[serde(default = "default_snippets")]
    pub snippets: Vec<Snippet>,
    #[serde(default)]
    pub theme_color: ThemeColor,
    #[serde(default)]
    pub appearance_mode: AppearanceMode,
    #[serde(default)]
    pub has_completed_welcome_onboarding: bool,
}

impl Default for Settings {
    fn default() -> Self {
        // The empty object takes every field default.
        serde_json::from_str("{}").unwrap_or_else(|_| unreachable!("all settings fields have defaults"))
    }
}

impl Settings {
    /// Decodes settings, applying legacy migrations and invariants.
    pub fn from_json(bytes: &[u8]) -> Result<Self, serde_json::Error> {
        let mut settings: Settings = serde_json::from_slice(bytes)?;
        settings.normalize();
        Ok(settings)
    }

    pub fn to_json(&self) -> Result<Vec<u8>, serde_json::Error> {
        serde_json::to_vec_pretty(self)
    }

    /// Double-tap-only requires the double-tap lock.
    pub fn normalize(&mut self) {
        if !self.double_tap_lock_enabled {
            self.use_double_tap_only = false;
        }
    }

    pub fn writing_style(&self) -> WritingStyle {
        WritingStyle::from_index(self.selected_style_index)
    }

    pub fn effective_double_tap_only(&self) -> bool {
        self.double_tap_lock_enabled && self.use_double_tap_only
    }

    pub fn selected_parakeet(&self) -> Option<ParakeetModel> {
        ParakeetModel::from_identifier(&self.selected_model)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn appearance_mode_defaults_to_system_and_round_trips() {
        assert_eq!(Settings::default().appearance_mode, AppearanceMode::System);
        let mut settings = Settings::default();
        settings.appearance_mode = AppearanceMode::Dark;
        let json = String::from_utf8(settings.to_json().unwrap()).unwrap();
        assert!(json.contains(r#""appearanceMode": "dark""#));
        let decoded: Settings = serde_json::from_str(&json).unwrap();
        assert_eq!(decoded.appearance_mode, AppearanceMode::Dark);
    }

    const V1: &str = r#"{
      "soundEffectsEnabled": false,
      "hotkey": {"key": null, "modifiers": {"modifiers": ["option"]}},
      "openOnLogin": true, "showDockIcon": false, "selectedModel": "whisper-large-v3",
      "useClipboardPaste": false, "preventSystemSleep": true, "pauseMediaOnRecord": true,
      "minimumKeyTime": 0.25, "copyToClipboard": true, "useDoubleTapOnly": true,
      "outputLanguage": "en", "selectedMicrophoneID": "builtin:mic",
      "saveTranscriptionHistory": false, "maxHistoryEntries": 10,
      "pasteLastTranscriptHotkey": {"key": "v", "modifiers": {"modifiers": ["option", "shift"]}},
      "hasCompletedModelBootstrap": true, "hasCompletedStorageMigration": true
    }"#;

    #[test]
    fn v1_fixture_migrates_to_current_defaults() {
        let s = Settings::from_json(V1.as_bytes()).unwrap();
        assert_eq!(s.recording_audio_behavior, RecordingAudioBehavior::DoNothing);
        assert!(!s.sound_effects_enabled);
        assert_eq!(s.sound_effects_volume, BASE_SOUND_EFFECTS_VOLUME);
        assert!(s.open_on_login);
        assert!(!s.show_dock_icon);
        assert_eq!(s.selected_model, "whisper-large-v3");
        assert!(!s.use_clipboard_paste);
        assert_eq!(s.minimum_key_time, 0.25);
        assert!(s.copy_to_clipboard);
        assert!(!s.super_fast_mode_enabled);
        assert!(s.use_double_tap_only);
        assert!(s.double_tap_lock_enabled);
        assert_eq!(s.output_language.as_deref(), Some("en"));
        assert_eq!(s.selected_microphone_id.as_deref(), Some("builtin:mic"));
        assert!(!s.save_transcription_history);
        assert_eq!(s.max_history_entries, Some(10));
        assert!(s.has_completed_model_bootstrap);
        assert_eq!(s.selected_style_index, 2);
        assert!(!s.has_selected_style);
        assert_eq!(s.snippets.len(), 3);
        assert_eq!(s.snippets[0].shortcut, "LinkedIn");
        assert_eq!(s.hotkey, default_hotkey());
    }

    #[test]
    fn round_trip_preserves_defaults() {
        let s = Settings::default();
        let decoded = Settings::from_json(&s.to_json().unwrap()).unwrap();
        assert_eq!(decoded, s);
    }

    #[test]
    fn normalizes_double_tap_only_when_lock_disabled() {
        let s = Settings::from_json(br#"{"useDoubleTapOnly":true,"doubleTapLockEnabled":false}"#).unwrap();
        assert!(!s.use_double_tap_only);
        assert!(!s.double_tap_lock_enabled);
    }

    #[test]
    fn removed_pause_media_maps_to_do_nothing() {
        let s = Settings::from_json(br#"{"recordingAudioBehavior":"pauseMedia"}"#).unwrap();
        assert_eq!(s.recording_audio_behavior, RecordingAudioBehavior::DoNothing);
    }

    #[test]
    fn legacy_groq_fields_are_dropped_and_mode_kept() {
        let s = Settings::from_json(
            br#"{"groqAPIKey":"legacy-secret","aiPostProcessingModel":"m","aiPostProcessingMode":"appAware","selectedStyleIndex":0}"#,
        )
        .unwrap();
        assert_eq!(s.ai_post_processing_mode, AiPostProcessingMode::On);
        assert_eq!(s.selected_style_index, 0);
        let saved = String::from_utf8(s.to_json().unwrap()).unwrap();
        assert!(!saved.contains("groqAPIKey"));
        assert!(!saved.contains("aiPostProcessingModel"));
    }

    #[test]
    fn cleared_paste_shortcut_stays_cleared() {
        let mut s = Settings::default();
        s.paste_last_transcript_hotkey = None;
        let decoded = Settings::from_json(&s.to_json().unwrap()).unwrap();
        assert_eq!(decoded.paste_last_transcript_hotkey, None);
        assert_eq!(Settings::default().paste_last_transcript_hotkey, Some(default_paste_last_hotkey()));
    }

    #[test]
    fn walkthrough_shortcut_defaults_and_stays_cleared() {
        assert_eq!(Settings::default().walkthrough_hotkey, Some(default_walkthrough_hotkey()));
        assert_eq!(Settings::from_json(V1.as_bytes()).unwrap().walkthrough_hotkey, Some(default_walkthrough_hotkey()));
        let mut s = Settings::default();
        s.walkthrough_hotkey = None;
        assert_eq!(Settings::from_json(&s.to_json().unwrap()).unwrap().walkthrough_hotkey, None);
    }

    #[test]
    fn theme_color_round_trips() {
        let mut s = Settings::default();
        s.theme_color = ThemeColor::Red;
        assert_eq!(Settings::from_json(&s.to_json().unwrap()).unwrap().theme_color, ThemeColor::Red);
    }

    #[test]
    fn decodes_current_swift_file_shape() {
        let s = Settings::from_json(
            br#"{"hotkey":{"modifiers":{"modifiers":[{"kind":"option","side":"right"}]}},
                 "selectedAIModel":"Qwen3-1.7B-MLX-4bit","selectedGroqModel":"qwen/qwen3.6-27b",
                 "recordingRetention":"oneDay","recordingIndicatorStyle":"pill","themeColor":"blue",
                 "wordRemappings":[{"id":"F42BC5E6-F9E1-47A3-804C-D5BA0F79D21A","isEnabled":true,"match":"there","replacement":"ther"}]}"#,
        )
        .unwrap();
        assert_eq!(s.selected_groq_model, GroqModel::Qwen36);
        assert_eq!(s.recording_retention, RecordingRetention::OneDay);
        assert_eq!(s.word_remappings[0].match_text, "there");
        let saved = String::from_utf8(s.to_json().unwrap()).unwrap();
        assert!(saved.contains("F42BC5E6-F9E1-47A3-804C-D5BA0F79D21A"));
    }
}
