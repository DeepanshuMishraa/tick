//! Speech models that run in-process through transcribe-cpp (GGUF on Metal)
//! instead of the Swift bridge. Each is one pinned Hugging Face artifact,
//! verified by size and SHA-256 before first use.

use std::io::Read;
use std::path::PathBuf;

use sha2::{Digest, Sha256};
use tick_core::models::PARAKEET_UNIFIED_ENGLISH;

use crate::intelligence::{self, DownloadControl, DownloadError};
use crate::storage;

#[derive(Debug, PartialEq, Eq)]
pub struct GgufModel {
    pub identifier: &'static str,
    repository: &'static str,
    revision: &'static str,
    filename: &'static str,
    bytes: u64,
    sha256: &'static str,
    pub architecture: &'static str,
    variant: &'static str,
    /// Silence appended after the clip so the final token has right context.
    pub trailing_silence_samples: usize,
}

const MODELS: &[GgufModel] = &[GgufModel {
    identifier: PARAKEET_UNIFIED_ENGLISH,
    repository: "handy-computer/parakeet-unified-en-0.6b-gguf",
    revision: "7e948f21b7bdbac698d3318db9d350f1096f3b6c",
    filename: "parakeet-unified-en-0.6b-Q8_0.gguf",
    bytes: 731_357_568,
    sha256: "4b50b6dd862bf6e346929aaf4f5eaacec003bfa3f56462d6c874b41ef2f38795",
    architecture: "parakeet",
    variant: "unified-en-0.6b",
    trailing_silence_samples: 3_200,
}];

impl GgufModel {
    pub fn from_identifier(identifier: &str) -> Option<&'static GgufModel> {
        MODELS.iter().find(|model| model.identifier == identifier)
    }

    pub fn path(&self) -> PathBuf {
        storage::speech_models().join(self.filename)
    }

    fn receipt(&self) -> PathBuf {
        storage::speech_models().join(format!("{}.verified", self.filename))
    }

    fn staging(&self) -> PathBuf {
        storage::speech_models().join(format!(".download-{}", self.filename))
    }

    pub fn bytes(&self) -> u64 {
        self.bytes
    }

    /// On disk at the expected size, with a receipt from a passed checksum.
    pub fn is_downloaded(&self) -> bool {
        self.receipt().exists() && std::fs::metadata(self.path()).is_ok_and(|m| m.len() == self.bytes)
    }

    /// Checks the loaded artifact is the one this entry pins.
    pub fn matches(&self, architecture: &str, variant: &str) -> bool {
        architecture == self.architecture && variant == self.variant
    }

    /// Downloads and verifies the artifact; a finished one returns at once.
    pub fn download(&self, control: &DownloadControl) -> Result<(), DownloadError> {
        if self.is_downloaded() {
            control.completed.store(self.bytes, std::sync::atomic::Ordering::Relaxed);
            return Ok(());
        }
        let staging = self.staging();
        std::fs::create_dir_all(&staging).map_err(|e| DownloadError::Disk(e.to_string()))?;
        let url = format!("https://huggingface.co/{}/resolve/{}/{}", self.repository, self.revision, self.filename);
        let target = self.path();
        intelligence::download_file(&url, self.bytes, &target, &staging, control)?;
        let digest = sha256(&target, control)?;
        if digest != self.sha256 {
            let _ = std::fs::remove_file(&target);
            let _ = std::fs::remove_dir_all(&staging);
            tracing::error!(target: "models", "{} checksum mismatch: expected {}, got {digest}", self.filename, self.sha256);
            return Err(DownloadError::Incomplete(format!("{} failed its checksum and was removed", self.filename)));
        }
        std::fs::write(self.receipt(), self.sha256).map_err(|e| DownloadError::Disk(e.to_string()))?;
        let _ = std::fs::remove_dir_all(&staging);
        Ok(())
    }

    pub fn delete(&self) -> std::io::Result<()> {
        for file in [self.receipt(), self.path()] {
            match std::fs::remove_file(file) {
                Err(error) if error.kind() != std::io::ErrorKind::NotFound => return Err(error),
                _ => {}
            }
        }
        if self.staging().exists() {
            std::fs::remove_dir_all(self.staging())?;
        }
        Ok(())
    }
}

fn sha256(path: &std::path::Path, control: &DownloadControl) -> Result<String, DownloadError> {
    let mut file = std::fs::File::open(path).map_err(|e| DownloadError::Disk(e.to_string()))?;
    let mut hasher = Sha256::new();
    let mut buffer = vec![0u8; 1024 * 1024];
    loop {
        control.check()?;
        let read = file.read(&mut buffer).map_err(|e| DownloadError::Disk(e.to_string()))?;
        if read == 0 {
            break;
        }
        hasher.update(&buffer[..read]);
    }
    Ok(hasher.finalize().iter().map(|byte| format!("{byte:02x}")).collect())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parakeet_unified_is_the_pinned_parakeet_artifact() {
        let model = GgufModel::from_identifier(PARAKEET_UNIFIED_ENGLISH).expect("Parakeet Unified is a GGUF model");
        assert!(model.matches("parakeet", "unified-en-0.6b"));
        assert!(!model.matches("parakeet", "tdt-0.6b-v2"));
        assert!(GgufModel::from_identifier("parakeet-tdt-0.6b-v2-coreml").is_none());
    }
}
