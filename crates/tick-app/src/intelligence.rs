//! AI post-processing: Groq when an API key is stored, otherwise the local
//! Qwen model through MLX. Also owns the local model download.

use std::fs::File;
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Arc;
use std::time::Duration;

use parking_lot::Mutex;
use tick_core::ai::{self, OutputContract, CHUNK_PROMPT_SUFFIX};
use tick_core::app_context::AppContext;
use tick_core::settings::{GroqModel, OnDeviceAiModel, WritingStyle};

use crate::native::{self, NativeError};
use crate::storage;

#[derive(Debug, Clone, thiserror::Error)]
pub enum AiError {
    #[error("The on-device AI model is not downloaded. Download it in Settings → Intelligence.")]
    ModelUnavailable,
    #[error("The AI returned unusable output, so the cleaned transcript was used instead.")]
    InvalidOutput,
    #[error("Groq did not respond successfully ({0}).")]
    Groq(String),
    #[error("{0}")]
    Native(#[from] NativeError),
}

const KEYCHAIN_SERVICE: &str = "com.dipxsy.tick.groq";
/// Where the Swift app kept the key; read once and moved forward.
const LEGACY_KEYCHAIN_SERVICE: &str = "com.dipxsy.Hex.groq";
const KEYCHAIN_ACCOUNT: &str = "api-key";

pub fn groq_key() -> Option<String> {
    let read = |service| {
        security_framework::passwords::get_generic_password(service, KEYCHAIN_ACCOUNT)
            .ok()
            .and_then(|bytes| String::from_utf8(bytes).ok())
            .filter(|key| !key.is_empty())
    };
    read(KEYCHAIN_SERVICE).or_else(|| {
        let key = read(LEGACY_KEYCHAIN_SERVICE)?;
        set_groq_key(Some(&key));
        if read(KEYCHAIN_SERVICE).is_some() {
            let _ = security_framework::passwords::delete_generic_password(LEGACY_KEYCHAIN_SERVICE, KEYCHAIN_ACCOUNT);
        }
        Some(key)
    })
}

pub fn set_groq_key(key: Option<&str>) {
    let _ = security_framework::passwords::delete_generic_password(KEYCHAIN_SERVICE, KEYCHAIN_ACCOUNT);
    if let Some(key) = key.filter(|k| !k.is_empty()) {
        if let Err(error) = security_framework::passwords::set_generic_password(KEYCHAIN_SERVICE, KEYCHAIN_ACCOUNT, key.as_bytes()) {
            tracing::error!(target: "transcription", "could not store the Groq key in the keychain: {error}");
        }
    }
}

pub fn is_model_downloaded(model: OnDeviceAiModel) -> bool {
    let directory = storage::ai_model(model);
    ["config.json", "tokenizer.json", "tokenizer_config.json"].iter().all(|f| directory.join(f).exists())
        && std::fs::read_dir(&directory)
            .map(|entries| entries.flatten().any(|e| e.path().extension().is_some_and(|x| x == "safetensors")))
            .unwrap_or(false)
}

pub fn model_size(model: OnDeviceAiModel) -> Option<u64> {
    let size = storage::directory_size(&storage::ai_model(model));
    (size > 0).then_some(size)
}

pub fn delete_model(model: OnDeviceAiModel) -> std::io::Result<()> {
    native::llm::unload();
    for directory in [storage::ai_model(model), storage::ai_model_staging(model)] {
        if directory.exists() {
            std::fs::remove_dir_all(directory)?;
        }
    }
    Ok(())
}

pub struct PostProcess {
    pub text: String,
    pub context: Option<AppContext>,
    pub style: WritingStyle,
    pub groq_model: GroqModel,
    pub model: OnDeviceAiModel,
}

/// Formats a transcript. Errors mean the caller should fall back to
/// `ai::normalize`, never drop the transcript.
pub async fn post_process(request: PostProcess) -> Result<String, AiError> {
    let input = ai::normalize(&request.text);
    if input.is_empty() {
        return Err(AiError::InvalidOutput);
    }
    let context = ai::effective_app_context(request.context.as_ref(), &input).cloned();
    let prompt = ai::system_prompt(context.as_ref(), request.style, OutputContract::EditScript);

    if let Some(key) = groq_key() {
        return groq(&input, &prompt, &key, request.groq_model).await;
    }
    if !is_model_downloaded(request.model) {
        return Err(AiError::ModelUnavailable);
    }
    let directory = storage::ai_model(request.model);
    native::llm::warm(&directory).await?;
    let chunks = ai::chunks(&input);
    if chunks.len() == 1 {
        return match generate(&directory, &prompt, &input).await {
            Ok(output) => Ok(output),
            Err(error) => {
                tracing::warn!(target: "transcription", "local AI output rejected ({error}); using the deterministic cleanup");
                Ok(input)
            }
        };
    }
    // Segments run one at a time: concurrent generations contend for the
    // same Metal model and were several times slower.
    let chunk_prompt = format!("{prompt}{CHUNK_PROMPT_SUFFIX}");
    let mut results = Vec::with_capacity(chunks.len());
    for chunk in &chunks {
        let output = match generate(&directory, &chunk_prompt, chunk).await {
            Ok(output) => output,
            Err(_) => {
                let normalized = ai::normalize(chunk);
                if normalized.is_empty() { chunk.clone() } else { normalized }
            }
        };
        results.push(output);
    }
    let joined = results.join(" ");
    if joined.trim().is_empty() { Err(AiError::InvalidOutput) } else { Ok(joined) }
}

/// Streams an edit script and stops as soon as it validates.
async fn generate(directory: &Path, prompt: &str, source: &str) -> Result<String, AiError> {
    let script = Arc::new(Mutex::new(String::new()));
    let accepted: Arc<Mutex<Option<String>>> = Arc::new(Mutex::new(None));
    let (script_sink, accepted_sink, source_owned) = (script.clone(), accepted.clone(), source.to_string());
    native::llm::generate(directory, prompt, source, ai::max_output_tokens(source), move |chunk| {
        let mut script = script_sink.lock();
        script.push_str(chunk);
        match ai::apply_edit_script(&script, &source_owned) {
            Some(output) if !output.trim().is_empty() => {
                *accepted_sink.lock() = Some(output);
                false
            }
            _ => true,
        }
    })
    .await?;
    let result = accepted.lock().take();
    result.ok_or(AiError::InvalidOutput)
}

async fn groq(input: &str, prompt: &str, key: &str, model: GroqModel) -> Result<String, AiError> {
    let body = serde_json::json!({
        "model": model.api_name(),
        "messages": [{"role": "system", "content": prompt}, {"role": "user", "content": input}],
        "temperature": 0.1,
        "max_tokens": 2048,
        "reasoning_effort": if model.disables_reasoning() { serde_json::Value::from("none") } else { serde_json::Value::Null },
    });
    let key = key.to_string();
    let (sender, receiver) = futures::channel::oneshot::channel();
    std::thread::spawn(move || {
        let agent: ureq::Agent = ureq::Agent::config_builder()
            .timeout_global(Some(Duration::from_secs(5)))
            .http_status_as_error(false)
            .build()
            .into();
        let result = agent
            .post("https://api.groq.com/openai/v1/chat/completions")
            .header("Authorization", &format!("Bearer {key}"))
            .header("Content-Type", "application/json")
            .send(body.to_string())
            .map_err(|error| error.to_string())
            .and_then(|mut response| {
                let status = response.status();
                let text = response.body_mut().read_to_string().map_err(|error| error.to_string())?;
                if status.is_success() { Ok(text) } else { Err(format!("HTTP {}", status.as_u16())) }
            });
        let _ = sender.send(result);
    });
    let text = receiver.await.unwrap_or_else(|_| Err("request dropped".into())).map_err(AiError::Groq)?;
    let response: serde_json::Value = serde_json::from_str(&text).map_err(|e| AiError::Groq(e.to_string()))?;
    let content = response["choices"][0]["message"]["content"].as_str().ok_or(AiError::InvalidOutput)?;
    ai::apply_edit_script(content, input).ok_or(AiError::InvalidOutput)
}

// MARK: - Local model download

const PARALLEL_THRESHOLD: u64 = 32 * 1024 * 1024;
const CHUNK_SIZE: u64 = 32 * 1024 * 1024;
const MAX_CONNECTIONS: usize = 12;

#[derive(Debug, Clone, thiserror::Error)]
pub enum DownloadError {
    #[error("Download cancelled.")]
    Cancelled,
    #[error("The model server could not be reached: {0}")]
    Network(String),
    #[error("The downloaded model is incomplete ({0}). Retry the download.")]
    Incomplete(String),
    #[error("The model could not be saved: {0}")]
    Disk(String),
}

/// Shared progress and cancellation for one download.
#[derive(Clone, Default)]
pub struct DownloadControl {
    pub cancelled: Arc<AtomicBool>,
    pub completed: Arc<AtomicU64>,
}

impl DownloadControl {
    fn check(&self) -> Result<(), DownloadError> {
        if self.cancelled.load(Ordering::Relaxed) { Err(DownloadError::Cancelled) } else { Ok(()) }
    }

    fn add(&self, bytes: u64) {
        self.completed.fetch_add(bytes, Ordering::Relaxed);
    }
}

fn agent() -> ureq::Agent {
    ureq::Agent::config_builder()
        .timeout_connect(Some(Duration::from_secs(15)))
        .http_status_as_error(false)
        .build()
        .into()
}

fn fetch(url: &str, range: Option<(u64, u64)>, destination: &Path, control: &DownloadControl) -> Result<u16, DownloadError> {
    let mut request = agent().get(url);
    if let Some((start, end)) = range {
        request = request.header("Range", &format!("bytes={start}-{}", end - 1));
    }
    let mut response = request.call().map_err(|error| DownloadError::Network(error.to_string()))?;
    let status = response.status().as_u16();
    if !(200..300).contains(&status) {
        return Err(DownloadError::Network(format!("HTTP {status}")));
    }
    if range.is_some() && status != 206 {
        return Ok(status);
    }
    let mut file = File::create(destination).map_err(|e| DownloadError::Disk(e.to_string()))?;
    let mut reader = response.body_mut().as_reader();
    let mut buffer = vec![0u8; 256 * 1024];
    loop {
        control.check()?;
        let read = reader.read(&mut buffer).map_err(|e| DownloadError::Network(e.to_string()))?;
        if read == 0 {
            break;
        }
        file.write_all(&buffer[..read]).map_err(|e| DownloadError::Disk(e.to_string()))?;
        control.add(read as u64);
    }
    Ok(status)
}

fn file_size(path: &Path) -> u64 {
    std::fs::metadata(path).map(|m| m.len()).unwrap_or(0)
}

fn download_parallel(url: &str, size: u64, destination: &Path, staging: &Path, control: &DownloadControl) -> Result<bool, DownloadError> {
    let count = size.div_ceil(CHUNK_SIZE) as usize;
    let chunk_path = |index: usize| staging.join(format!("chunk-{index}.part"));
    let bounds = |index: usize| {
        let start = index as u64 * CHUNK_SIZE;
        (start, (start + CHUNK_SIZE).min(size))
    };
    let mut pending: Vec<usize> = Vec::new();
    for index in 0..count {
        let (start, end) = bounds(index);
        if file_size(&chunk_path(index)) == end - start {
            control.add(end - start);
        } else {
            pending.push(index);
        }
    }
    let queue = Arc::new(Mutex::new(pending));
    let failure: Arc<Mutex<Option<DownloadError>>> = Arc::new(Mutex::new(None));
    let unsupported = Arc::new(AtomicBool::new(false));
    std::thread::scope(|scope| {
        for _ in 0..MAX_CONNECTIONS.min(count) {
            let (queue, failure, unsupported) = (queue.clone(), failure.clone(), unsupported.clone());
            scope.spawn(move || loop {
                if failure.lock().is_some() || unsupported.load(Ordering::Relaxed) {
                    return;
                }
                let Some(index) = queue.lock().pop() else { return };
                let (start, end) = bounds(index);
                let path = chunk_path(index);
                match fetch(url, Some((start, end)), &path, control) {
                    Ok(206) if file_size(&path) == end - start => {}
                    Ok(206) => {
                        *failure.lock() = Some(DownloadError::Incomplete(format!("chunk {index}")));
                    }
                    Ok(_) => unsupported.store(true, Ordering::Relaxed),
                    Err(error) => *failure.lock() = Some(error),
                }
            });
        }
    });
    if let Some(error) = failure.lock().take() {
        return Err(error);
    }
    if unsupported.load(Ordering::Relaxed) {
        return Ok(false);
    }
    let mut output = File::create(destination).map_err(|e| DownloadError::Disk(e.to_string()))?;
    for index in 0..count {
        let mut input = File::open(chunk_path(index)).map_err(|e| DownloadError::Disk(e.to_string()))?;
        std::io::copy(&mut input, &mut output).map_err(|e| DownloadError::Disk(e.to_string()))?;
    }
    Ok(true)
}

/// Downloads every model file with byte-range parallelism and size checks.
/// Already-complete files and chunks are reused, so a retry resumes.
pub fn download_model(model: OnDeviceAiModel, control: &DownloadControl) -> Result<(), DownloadError> {
    let destination = storage::ai_model(model);
    let staging = storage::ai_model_staging(model);
    for directory in [&destination, &staging] {
        std::fs::create_dir_all(directory).map_err(|e| DownloadError::Disk(e.to_string()))?;
    }
    for (name, size) in model.files() {
        control.check()?;
        let target: PathBuf = destination.join(name);
        if file_size(&target) == *size {
            control.add(*size);
            continue;
        }
        let url = format!("{}/{name}", model.remote_base_url());
        let before = control.completed.load(Ordering::Relaxed);
        let done_parallel = *size >= PARALLEL_THRESHOLD && download_parallel(&url, *size, &target, &staging, control)?;
        if !done_parallel {
            control.completed.store(before, Ordering::Relaxed);
            let temporary = staging.join(format!("{name}.download"));
            fetch(&url, None, &temporary, control)?;
            std::fs::rename(&temporary, &target).map_err(|e| DownloadError::Disk(e.to_string()))?;
        }
        if file_size(&target) != *size {
            let _ = std::fs::remove_file(&target);
            return Err(DownloadError::Incomplete(name.to_string()));
        }
    }
    let _ = std::fs::remove_dir_all(&staging);
    if is_model_downloaded(model) { Ok(()) } else { Err(DownloadError::Incomplete("model files".into())) }
}

pub fn total_bytes(model: OnDeviceAiModel) -> u64 {
    model.files().iter().map(|(_, size)| size).sum()
}
