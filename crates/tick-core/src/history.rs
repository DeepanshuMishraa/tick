//! Transcription history persisted as `transcription_history.json`.

use std::path::{Path, PathBuf};

use serde::{Deserialize, Deserializer, Serialize, Serializer};

use crate::id::{SwiftDate, SwiftUuid};
use crate::settings::RecordingRetention;

/// A `file://` URL as Foundation encodes it (percent-escaped absolute string).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FileUrl(pub PathBuf);

const PATH_ESCAPES: &percent_encoding::AsciiSet = &percent_encoding::NON_ALPHANUMERIC
    .remove(b'/')
    .remove(b'-')
    .remove(b'_')
    .remove(b'.')
    .remove(b'~');

impl Serialize for FileUrl {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        let path = self.0.to_string_lossy();
        let encoded = percent_encoding::utf8_percent_encode(&path, PATH_ESCAPES);
        serializer.serialize_str(&format!("file://{encoded}"))
    }
}

impl<'de> Deserialize<'de> for FileUrl {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let raw = String::deserialize(deserializer)?;
        let path = raw.strip_prefix("file://").unwrap_or(&raw);
        let decoded = percent_encoding::percent_decode_str(path).decode_utf8_lossy();
        Ok(FileUrl(PathBuf::from(decoded.into_owned())))
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Transcript {
    pub id: SwiftUuid,
    pub timestamp: SwiftDate,
    pub text: String,
    pub audio_path: FileUrl,
    pub duration: f64,
    #[serde(default, rename = "sourceAppBundleID", skip_serializing_if = "Option::is_none")]
    pub source_app_bundle_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub source_app_name: Option<String>,
    /// False once recording retention deleted the audio; text is always kept.
    #[serde(default = "default_true")]
    pub has_audio: bool,
}

fn default_true() -> bool {
    true
}

impl Transcript {
    pub fn word_count(&self) -> usize {
        self.text.split(' ').filter(|w| !w.is_empty()).count()
    }
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct History {
    #[serde(default)]
    pub history: Vec<Transcript>,
}

impl History {
    pub fn from_json(bytes: &[u8]) -> Result<Self, serde_json::Error> {
        serde_json::from_slice(bytes)
    }

    pub fn to_json(&self) -> Result<Vec<u8>, serde_json::Error> {
        serde_json::to_vec(self)
    }

    /// Inserts newest-first and trims to `max_entries`, returning evicted
    /// transcripts so their audio can be deleted.
    pub fn insert(&mut self, transcript: Transcript, max_entries: Option<i64>) -> Vec<Transcript> {
        self.history.insert(0, transcript);
        let mut evicted = Vec::new();
        if let Some(max) = max_entries.filter(|m| *m > 0).and_then(|m| usize::try_from(m).ok()) {
            while self.history.len() > max {
                if let Some(removed) = self.history.pop() {
                    evicted.push(removed);
                }
            }
        }
        evicted
    }

    pub fn remove(&mut self, id: SwiftUuid) -> Option<Transcript> {
        let index = self.history.iter().position(|t| t.id == id)?;
        Some(self.history.remove(index))
    }

    pub fn mark_audio_deleted(&mut self, ids: &[SwiftUuid]) {
        for transcript in &mut self.history {
            if ids.contains(&transcript.id) {
                transcript.has_audio = false;
            }
        }
    }
}

/// Transcripts whose audio is older than the retention cutoff.
pub fn expired_audio(history: &History, retention: RecordingRetention, now: SwiftDate) -> Vec<(SwiftUuid, PathBuf)> {
    let Some(max_age) = retention.max_age() else { return Vec::new() };
    let cutoff = now.0 - max_age;
    history
        .history
        .iter()
        .filter(|t| t.has_audio && t.timestamp.0 < cutoff)
        .map(|t| (t.id, t.audio_path.0.clone()))
        .collect()
}

/// Recording file name for a capture finished at `now`, matching the Swift
/// app's `<unix seconds>.wav` scheme.
pub fn recording_file_name(now: SwiftDate) -> String {
    format!("{}.wav", now.unix_seconds())
}

pub fn is_known_audio(history: &History, path: &Path) -> bool {
    history.history.iter().any(|t| t.audio_path.0 == path)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn decodes_swift_history_entry() {
        let json = r#"{"history":[{"audioPath":"file:///Users/me/Library/Application%20Support/com.dipxsy.Tick/Recordings/1792083298.340754.wav","duration":19.08,"id":"376C4547-E4CB-4D11-9097-A2D9C0C88B54","sourceAppBundleID":"den.dipxsy.app","sourceAppName":"Den","text":"Exactly","timestamp":813776098.342322}]}"#;
        let history = History::from_json(json.as_bytes()).unwrap();
        let entry = &history.history[0];
        assert!(entry.has_audio);
        assert_eq!(
            entry.audio_path.0,
            PathBuf::from("/Users/me/Library/Application Support/com.dipxsy.Tick/Recordings/1792083298.340754.wav")
        );
        let encoded = String::from_utf8(history.to_json().unwrap()).unwrap();
        assert!(encoded.contains("Application%20Support"));
        assert!(encoded.contains("376C4547-E4CB-4D11-9097-A2D9C0C88B54"));
        assert_eq!(History::from_json(encoded.as_bytes()).unwrap(), history);
    }

    #[test]
    fn insert_trims_and_reports_evictions() {
        let mut history = History::default();
        let make = |text: &str| Transcript {
            id: SwiftUuid::new(),
            timestamp: SwiftDate(0.0),
            text: text.into(),
            audio_path: FileUrl(PathBuf::from("/tmp/a.wav")),
            duration: 1.0,
            source_app_bundle_id: None,
            source_app_name: None,
            has_audio: true,
        };
        history.insert(make("one"), Some(2));
        history.insert(make("two"), Some(2));
        let evicted = history.insert(make("three"), Some(2));
        assert_eq!(evicted.len(), 1);
        assert_eq!(evicted[0].text, "one");
        assert_eq!(history.history[0].text, "three");
    }

    #[test]
    fn expired_audio_respects_retention() {
        let mut history = History::default();
        history.history.push(Transcript {
            id: SwiftUuid::new(),
            timestamp: SwiftDate(0.0),
            text: "old".into(),
            audio_path: FileUrl(PathBuf::from("/tmp/old.wav")),
            duration: 1.0,
            source_app_bundle_id: None,
            source_app_name: None,
            has_audio: true,
        });
        assert!(expired_audio(&history, RecordingRetention::Forever, SwiftDate(1e9)).is_empty());
        assert_eq!(expired_audio(&history, RecordingRetention::OneDay, SwiftDate(1e9)).len(), 1);
        assert!(expired_audio(&history, RecordingRetention::OneDay, SwiftDate(10.0)).is_empty());
    }
}
