//! Identifier and timestamp encodings compatible with Swift `Codable` output.

use serde::{Deserialize, Deserializer, Serialize, Serializer};
use uuid::Uuid;

/// A UUID serialized in Foundation's uppercase form.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct SwiftUuid(pub Uuid);

impl SwiftUuid {
    pub fn new() -> Self {
        Self(Uuid::new_v4())
    }
}

impl Default for SwiftUuid {
    fn default() -> Self {
        Self::new()
    }
}

impl std::fmt::Display for SwiftUuid {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.0.hyphenated().to_string().to_uppercase())
    }
}

impl Serialize for SwiftUuid {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_str(&self.to_string())
    }
}

impl<'de> Deserialize<'de> for SwiftUuid {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let raw = String::deserialize(deserializer)?;
        Uuid::parse_str(&raw).map(SwiftUuid).map_err(serde::de::Error::custom)
    }
}

/// Seconds between the Unix epoch and Foundation's reference date (2001-01-01).
const REFERENCE_DATE_OFFSET: f64 = 978_307_200.0;

/// A point in time stored as Foundation's default `Date` encoding: seconds
/// since 2001-01-01T00:00:00Z.
#[derive(Debug, Clone, Copy, PartialEq, PartialOrd, Serialize, Deserialize)]
#[serde(transparent)]
pub struct SwiftDate(pub f64);

impl SwiftDate {
    pub fn now() -> Self {
        Self::from_unix(
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_secs_f64())
                .unwrap_or_default(),
        )
    }

    pub fn from_unix(seconds: f64) -> Self {
        Self(seconds - REFERENCE_DATE_OFFSET)
    }

    pub fn unix_seconds(self) -> f64 {
        self.0 + REFERENCE_DATE_OFFSET
    }

    pub fn to_local(self) -> chrono::DateTime<chrono::Local> {
        let seconds = self.unix_seconds();
        let whole = seconds.floor();
        let nanos = ((seconds - whole) * 1e9) as u32;
        chrono::DateTime::from_timestamp(whole as i64, nanos)
            .unwrap_or_default()
            .with_timezone(&chrono::Local)
    }
}
