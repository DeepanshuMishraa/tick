//! Usage statistics derived from history for Home and Insights.

use std::collections::{BTreeMap, HashMap, HashSet};

use chrono::{Datelike, Duration, NaiveDate};

use crate::history::Transcript;

#[derive(Debug, Clone, PartialEq, Default)]
pub struct HomeStats {
    pub word_count: usize,
    pub daily_streak: usize,
    pub average_wpm: usize,
    pub unique_apps: usize,
}

fn day(transcript: &Transcript) -> NaiveDate {
    transcript.timestamp.to_local().date_naive()
}

/// Consecutive active days ending today (or yesterday if today is idle).
pub fn current_streak(active: &HashSet<NaiveDate>, today: NaiveDate) -> usize {
    let mut cursor = today;
    if !active.contains(&cursor) {
        let yesterday = today - Duration::days(1);
        if active.contains(&yesterday) {
            cursor = yesterday;
        }
    }
    let mut streak = 0;
    while active.contains(&cursor) {
        streak += 1;
        cursor -= Duration::days(1);
    }
    streak
}

pub fn home_stats(history: &[Transcript], today: NaiveDate) -> HomeStats {
    if history.is_empty() {
        return HomeStats { unique_apps: 1, ..HomeStats::default() };
    }
    let word_count = history.iter().map(Transcript::word_count).sum();
    let days: HashSet<NaiveDate> = history.iter().map(day).collect();
    let (mut words, mut seconds) = (0usize, 0.0f64);
    for transcript in history {
        let count = transcript.word_count();
        if transcript.duration > 0.5 && count > 0 {
            words += count;
            seconds += transcript.duration;
        }
    }
    let average_wpm = if seconds > 1.0 {
        ((words as f64) / (seconds / 60.0)).round().clamp(0.0, 250.0) as usize
    } else {
        0
    };
    let apps: HashSet<&str> = history.iter().filter_map(|t| t.source_app_name.as_deref()).collect();
    HomeStats { word_count, daily_streak: current_streak(&days, today), average_wpm, unique_apps: apps.len().max(1) }
}

pub fn greeting(word_count: usize, name: &str) -> String {
    let phrase = match word_count {
        0 => "Ready when you are",
        1..=200 => "You're finding your flow",
        201..=500 => "You're in a good rhythm",
        501..=2000 => "You're on a roll",
        _ => "You're in full flow",
    };
    format!("{phrase}, {name}")
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AppUsage {
    pub name: String,
    pub bundle_id: Option<String>,
    pub words: usize,
}

#[derive(Debug, Clone, PartialEq, Default)]
pub struct Insights {
    pub words_by_day: BTreeMap<NaiveDate, usize>,
    pub transcripts_by_day: BTreeMap<NaiveDate, usize>,
    /// Top five apps by dictated words.
    pub top_apps: Vec<AppUsage>,
    pub first_day: Option<NaiveDate>,
}

fn whitespace_words(text: &str) -> usize {
    text.split_whitespace().count()
}

pub fn insights(history: &[Transcript]) -> Insights {
    let mut result = Insights::default();
    let mut apps: HashMap<String, (Option<String>, usize)> = HashMap::new();
    for transcript in history {
        let date = day(transcript);
        let words = whitespace_words(&transcript.text);
        *result.words_by_day.entry(date).or_default() += words;
        *result.transcripts_by_day.entry(date).or_default() += 1;
        let name = transcript
            .source_app_name
            .clone()
            .filter(|n| !n.is_empty())
            .unwrap_or_else(|| "Other apps".to_string());
        let entry = apps.entry(name).or_insert((None, 0));
        entry.1 += words;
        if entry.0.is_none() {
            entry.0 = transcript.source_app_bundle_id.clone();
        }
        result.first_day = Some(result.first_day.map_or(date, |first: NaiveDate| first.min(date)));
    }
    let mut ranked: Vec<AppUsage> = apps
        .into_iter()
        .map(|(name, (bundle_id, words))| AppUsage { name, bundle_id, words })
        .collect();
    ranked.sort_by(|a, b| b.words.cmp(&a.words).then_with(|| a.name.cmp(&b.name)));
    ranked.truncate(5);
    result.top_apps = ranked;
    result
}

impl Insights {
    pub fn active_days(&self) -> usize {
        self.words_by_day.len()
    }

    pub fn streaks(&self, today: NaiveDate) -> (usize, usize) {
        let active: HashSet<NaiveDate> = self.words_by_day.keys().copied().collect();
        if active.is_empty() {
            return (0, 0);
        }
        let mut longest = 1;
        let mut run = 1;
        let dates: Vec<&NaiveDate> = self.words_by_day.keys().collect();
        for pair in dates.windows(2) {
            if *pair[1] - *pair[0] == Duration::days(1) {
                run += 1;
                longest = longest.max(run);
            } else {
                run = 1;
            }
        }
        (current_streak(&active, today), longest)
    }

    pub fn best_day(&self) -> Option<(NaiveDate, usize)> {
        self.words_by_day
            .iter()
            .max_by(|a, b| a.1.cmp(b.1).then(a.0.cmp(b.0)))
            .map(|(date, words)| (*date, *words))
    }

    /// Word totals per weekday, Sunday first.
    pub fn weekday_totals(&self) -> [usize; 7] {
        let mut totals = [0; 7];
        for (date, words) in &self.words_by_day {
            totals[date.weekday().num_days_from_sunday() as usize] += words;
        }
        totals
    }
}

/// Minutes-saved model shared by Insights copy: 40 WPM typing baseline.
pub fn hours_saved(word_count: usize, wpm: usize) -> f64 {
    if word_count == 0 {
        return 0.0;
    }
    let typing = word_count as f64 / 40.0;
    let voice = word_count as f64 / wpm.max(40) as f64;
    ((typing - voice) / 60.0).max(0.1)
}

/// First day of the month containing `date`.
pub fn month_start(date: NaiveDate) -> NaiveDate {
    date.with_day(1).unwrap_or(date)
}

pub fn add_months(date: NaiveDate, months: i32) -> NaiveDate {
    let total = date.year() * 12 + date.month0() as i32 + months;
    NaiveDate::from_ymd_opt(total.div_euclid(12), total.rem_euclid(12) as u32 + 1, 1).unwrap_or(date)
}

pub fn months_between(from: NaiveDate, to: NaiveDate) -> i32 {
    (to.year() - from.year()) * 12 + to.month() as i32 - from.month() as i32
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn streak_allows_idle_today() {
        let today = NaiveDate::from_ymd_opt(2026, 10, 15).unwrap();
        let active: HashSet<NaiveDate> =
            [today - Duration::days(1), today - Duration::days(2)].into_iter().collect();
        assert_eq!(current_streak(&active, today), 2);
        assert_eq!(current_streak(&HashSet::new(), today), 0);
    }

    #[test]
    fn month_math() {
        let d = NaiveDate::from_ymd_opt(2026, 11, 20).unwrap();
        assert_eq!(add_months(d, 2), NaiveDate::from_ymd_opt(2027, 1, 1).unwrap());
        assert_eq!(months_between(NaiveDate::from_ymd_opt(2025, 12, 3).unwrap(), d), 11);
    }

    #[test]
    fn greetings_scale_with_words() {
        assert_eq!(greeting(0, "Ana"), "Ready when you are, Ana");
        assert_eq!(greeting(3000, "Ana"), "You're in full flow, Ana");
    }
}
