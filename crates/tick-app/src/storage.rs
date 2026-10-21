//! On-disk locations and JSON persistence, compatible with the Swift app's
//! layout under `~/Library/Application Support/com.dipxsy.Tick`.

use std::path::{Path, PathBuf};

use tick_core::history::History;
use tick_core::settings::{OnDeviceAiModel, Settings};

pub const BUNDLE_ID: &str = "com.dipxsy.Tick";

fn home() -> PathBuf {
    dirs::home_dir().unwrap_or_else(std::env::temp_dir)
}

/// `~/Library/Application Support/com.dipxsy.Tick`, created on demand.
pub fn app_support() -> PathBuf {
    let directory = dirs::data_dir()
        .unwrap_or_else(|| home().join("Library/Application Support"))
        .join(BUNDLE_ID);
    let _ = std::fs::create_dir_all(&directory);
    directory
}

fn ensure(directory: PathBuf) -> PathBuf {
    let _ = std::fs::create_dir_all(&directory);
    directory
}

pub fn recordings() -> PathBuf {
    ensure(app_support().join("Recordings"))
}

pub fn walkthroughs() -> PathBuf {
    ensure(app_support().join("Walkthroughs"))
}

pub fn speech_models() -> PathBuf {
    ensure(app_support().join("models"))
}

/// FluidAudio caches Parakeet under `$XDG_CACHE_HOME`; this keeps it inside
/// the app's own folder.
pub fn cache() -> PathBuf {
    ensure(app_support().join("cache"))
}

pub fn ai_models() -> PathBuf {
    ensure(cache().join("ai-models"))
}

pub fn ai_model(model: OnDeviceAiModel) -> PathBuf {
    ai_models().join(model.directory_name())
}

pub fn ai_model_staging(model: OnDeviceAiModel) -> PathBuf {
    ai_models().join(format!(".download-{}", model.directory_name()))
}

/// Resolves a data file, copying a legacy `~/Documents` copy forward once.
fn migrated(name: &str) -> PathBuf {
    let current = app_support().join(name);
    let legacy = home().join("Documents").join(name);
    if !current.exists() && legacy.exists() {
        let _ = std::fs::copy(&legacy, &current);
    }
    current
}

pub fn settings_path() -> PathBuf {
    let current = app_support().join("tick_settings.json");
    // The Swift app saved `hex_settings.json`; move it to the new name once.
    let legacy = migrated("hex_settings.json");
    if !current.exists() && legacy.exists() {
        let _ = std::fs::rename(&legacy, &current);
    }
    current
}

pub fn history_path() -> PathBuf {
    migrated("transcription_history.json")
}

/// Writes atomically so a crash mid-write never truncates user data.
pub fn write_atomic(path: &Path, bytes: &[u8]) -> std::io::Result<()> {
    let temporary = path.with_extension("json.tmp");
    std::fs::write(&temporary, bytes)?;
    std::fs::rename(&temporary, path)
}

pub fn load_settings() -> Settings {
    let path = settings_path();
    match std::fs::read(&path) {
        Ok(bytes) => Settings::from_json(&bytes).unwrap_or_else(|error| {
            tracing::error!(target: "settings", "settings at {} are unreadable ({error}); using defaults and keeping a backup", path.display());
            let _ = std::fs::copy(&path, path.with_extension("json.unreadable"));
            Settings::default()
        }),
        Err(_) => Settings::default(),
    }
}

pub fn save_settings(settings: &Settings) {
    match settings.to_json() {
        Ok(bytes) => {
            if let Err(error) = write_atomic(&settings_path(), &bytes) {
                tracing::error!(target: "settings", "failed to save settings: {error}");
            }
        }
        Err(error) => tracing::error!(target: "settings", "failed to encode settings: {error}"),
    }
}

pub fn load_history() -> History {
    let path = history_path();
    match std::fs::read(&path) {
        Ok(bytes) => History::from_json(&bytes).unwrap_or_else(|error| {
            tracing::error!(target: "history", "history at {} is unreadable ({error}); starting empty and keeping a backup", path.display());
            let _ = std::fs::copy(&path, path.with_extension("json.unreadable"));
            History::default()
        }),
        Err(_) => History::default(),
    }
}

/// One writer thread so saves land in order; queued snapshots coalesce to
/// the newest.
static HISTORY_WRITER: std::sync::LazyLock<crossbeam_channel::Sender<Vec<u8>>> =
    std::sync::LazyLock::new(|| {
        let (sender, receiver) = crossbeam_channel::unbounded::<Vec<u8>>();
        std::thread::Builder::new()
            .name("tick-history-writer".into())
            .spawn(move || {
                while let Ok(mut bytes) = receiver.recv() {
                    while let Ok(newer) = receiver.try_recv() {
                        bytes = newer;
                    }
                    if let Err(error) = write_atomic(&history_path(), &bytes) {
                        tracing::error!(target: "history", "failed to save history: {error}");
                    }
                }
            })
            .expect("spawning the history writer");
        sender
    });

/// Encodes on the caller's thread and writes on the writer thread.
pub fn save_history(history: &History) {
    match history.to_json() {
        Ok(bytes) => {
            let _ = HISTORY_WRITER.send(bytes);
        }
        Err(error) => tracing::error!(target: "history", "failed to encode history: {error}"),
    }
}

pub fn directory_size(path: &Path) -> u64 {
    let Ok(entries) = std::fs::read_dir(path) else {
        return 0;
    };
    entries
        .flatten()
        .map(|entry| match entry.metadata() {
            Ok(meta) if meta.is_dir() => directory_size(&entry.path()),
            Ok(meta) => meta.len(),
            Err(_) => 0,
        })
        .sum()
}

pub fn format_bytes(bytes: u64) -> String {
    const UNITS: [&str; 4] = ["bytes", "KB", "MB", "GB"];
    let mut value = bytes as f64;
    let mut unit = 0;
    while value >= 1000.0 && unit < UNITS.len() - 1 {
        value /= 1000.0;
        unit += 1;
    }
    if unit == 0 {
        format!("{bytes} bytes")
    } else {
        format!("{value:.1} {}", UNITS[unit])
    }
}
