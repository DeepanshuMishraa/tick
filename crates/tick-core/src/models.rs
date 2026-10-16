//! Speech model catalog: Parakeet variants, curated defaults, and glob
//! resolution for WhisperKit variant names.

use serde::Deserialize;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ParakeetModel {
    EnglishV2,
    MultilingualV3,
}

impl ParakeetModel {
    pub const ALL: [Self; 2] = [Self::EnglishV2, Self::MultilingualV3];

    pub fn identifier(self) -> &'static str {
        match self {
            Self::EnglishV2 => "parakeet-tdt-0.6b-v2-coreml",
            Self::MultilingualV3 => "parakeet-tdt-0.6b-v3-coreml",
        }
    }

    pub fn from_identifier(identifier: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|model| model.identifier() == identifier)
    }

    pub fn is_english_only(self) -> bool {
        self == Self::EnglishV2
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CuratedModel {
    pub display_name: String,
    pub internal_name: String,
    /// "English" or "Multilingual".
    pub size: String,
    pub accuracy_stars: u8,
    pub speed_stars: u8,
    pub storage_size: String,
}

impl CuratedModel {
    pub fn parakeet(&self) -> Option<ParakeetModel> {
        ParakeetModel::from_identifier(&self.internal_name)
    }

    pub fn badge(&self) -> Option<&'static str> {
        self.parakeet().map(|model| match model {
            ParakeetModel::EnglishV2 => "Best for English",
            ParakeetModel::MultilingualV3 => "Best multilingual",
        })
    }

    /// Whether this curated entry denotes `selected` (either may be a glob).
    pub fn is_selected(&self, selected: &str) -> bool {
        glob_matches(&self.internal_name, selected) || glob_matches(selected, &self.internal_name)
    }
}

const MODELS_JSON: &str = include_str!("../../../resources/models.json");

pub fn curated_models() -> Vec<CuratedModel> {
    serde_json::from_str(MODELS_JSON).unwrap_or_default()
}

/// Human name for a model identifier.
pub fn display_name(model: &str) -> String {
    curated_models()
        .into_iter()
        .find(|curated| glob_matches(&curated.internal_name, model))
        .map(|curated| curated.display_name)
        .unwrap_or_else(|| {
            model
                .replace(['-', '_'], " ")
                .split(' ')
                .map(|word| {
                    let mut chars = word.chars();
                    chars
                        .next()
                        .map(|first| first.to_uppercase().collect::<String>() + chars.as_str())
                        .unwrap_or_default()
                })
                .collect::<Vec<_>>()
                .join(" ")
        })
}

/// `fnmatch`-style glob with `*` and `?`; plain strings compare exactly.
pub fn glob_matches(pattern: &str, text: &str) -> bool {
    if !pattern.contains(['*', '?']) {
        return pattern == text;
    }
    let p: Vec<char> = pattern.chars().collect();
    let t: Vec<char> = text.chars().collect();
    let (mut pi, mut ti) = (0, 0);
    let mut star: Option<(usize, usize)> = None;
    while ti < t.len() {
        if pi < p.len() && (p[pi] == '?' || p[pi] == t[ti]) {
            pi += 1;
            ti += 1;
        } else if pi < p.len() && p[pi] == '*' {
            star = Some((pi, ti));
            pi += 1;
        } else if let Some((star_p, star_t)) = star {
            pi = star_p + 1;
            ti = star_t + 1;
            star = Some((star_p, star_t + 1));
        } else {
            return false;
        }
    }
    p[pi..].iter().all(|c| *c == '*')
}

/// Resolves a glob to a concrete model: downloaded first, then non-turbo.
pub fn resolve_pattern(pattern: &str, models: &[(String, bool)]) -> Option<String> {
    if !pattern.contains(['*', '?']) {
        return Some(pattern.to_string());
    }
    let matched: Vec<&(String, bool)> = models.iter().filter(|(name, _)| glob_matches(pattern, name)).collect();
    let downloaded: Vec<&&(String, bool)> = matched.iter().filter(|(_, d)| *d).collect();
    let pick = |pool: Vec<&String>| {
        pool.iter()
            .find(|name| !name.to_lowercase().contains("turbo"))
            .or_else(|| pool.first())
            .map(|name| (*name).clone())
    };
    if !downloaded.is_empty() {
        return pick(downloaded.iter().map(|(name, _)| name).collect());
    }
    pick(matched.iter().map(|(name, _)| name).collect())
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub struct Language {
    pub code: Option<String>,
    pub name: String,
}

const LANGUAGES_JSON: &str = include_str!("../../../resources/languages.json");

/// Output languages (the "Auto" entry has no code).
pub fn languages() -> Vec<Language> {
    serde_json::from_str(LANGUAGES_JSON).unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn globbing() {
        assert!(glob_matches("distil*large-v3", "distil-whisper_distil-large-v3"));
        assert!(!glob_matches("distil*large-v3", "openai_whisper-large-v3"));
        assert!(glob_matches("a?c", "abc"));
        assert!(glob_matches("exact", "exact"));
    }

    #[test]
    fn resolution_prefers_downloaded_non_turbo() {
        let models = vec![
            ("x-large-v3-turbo".to_string(), true),
            ("x-large-v3".to_string(), true),
            ("x-large-v2".to_string(), false),
        ];
        assert_eq!(resolve_pattern("x-large*", &models).as_deref(), Some("x-large-v3"));
    }

    #[test]
    fn bundled_catalogs_parse() {
        assert_eq!(curated_models().len(), 5);
        assert!(languages().len() > 50);
        assert_eq!(display_name("parakeet-tdt-0.6b-v3-coreml"), "Parakeet TDT v3");
    }
}
