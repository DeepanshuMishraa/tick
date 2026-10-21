//! Routes speech-model calls to the engine that runs the model: GGUF models
//! in-process through transcribe-cpp, everything else through the Swift
//! bridge. Callers name a model; they never pick an engine.

mod engine;
pub mod gguf;

use std::path::Path;
use std::sync::Arc;
use std::sync::atomic::Ordering;
use std::time::Duration;

use futures::channel::oneshot;
use parking_lot::Mutex;

use crate::intelligence::{DownloadControl, DownloadError};
use crate::native;
pub use crate::native::NativeError;
pub use crate::native::speech::catalog;
pub use engine::LiveText;
use gguf::GgufModel;

#[derive(Debug, Clone, Copy)]
enum Engine {
    Gguf(&'static GgufModel),
    Native,
}

impl Engine {
    fn of(model: &str) -> Engine {
        GgufModel::from_identifier(model).map_or(Engine::Native, Engine::Gguf)
    }
}

/// Which engine receives microphone samples while a recording streams.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum StreamOwner {
    None,
    Gguf,
    Native,
}

static STREAM_OWNER: Mutex<StreamOwner> = Mutex::new(StreamOwner::None);

fn failed(message: String) -> NativeError {
    NativeError::Failed(message)
}

/// A running model download.
pub enum Download {
    Native(native::speech::Download),
    Gguf {
        control: DownloadControl,
        receiver: oneshot::Receiver<Result<(), DownloadError>>,
    },
}

#[derive(Clone)]
pub enum CancelHandle {
    Native(native::speech::CancelHandle),
    Gguf(DownloadControl),
}

impl CancelHandle {
    pub fn cancel(self) {
        match self {
            CancelHandle::Native(handle) => handle.cancel(),
            CancelHandle::Gguf(control) => control.cancelled.store(true, Ordering::Relaxed),
        }
    }
}

impl Download {
    pub fn cancel_handle(&self) -> CancelHandle {
        match self {
            Download::Native(download) => CancelHandle::Native(download.cancel_handle()),
            Download::Gguf { control, .. } => CancelHandle::Gguf(control.clone()),
        }
    }

    pub async fn finish(self) -> Result<(), NativeError> {
        match self {
            Download::Native(download) => download.finish().await,
            Download::Gguf { receiver, .. } => match receiver.await {
                Ok(Ok(())) => Ok(()),
                Ok(Err(DownloadError::Cancelled)) => Err(NativeError::Cancelled),
                Ok(Err(error)) => Err(failed(error.to_string())),
                Err(_) => Err(NativeError::Dropped),
            },
        }
    }
}

/// Downloads `model`, reporting 0…1 progress.
pub fn download(model: &str, progress: impl Fn(f64) + Send + Sync + 'static) -> Download {
    let Engine::Gguf(model) = Engine::of(model) else {
        return Download::Native(native::speech::download(model, progress));
    };
    let control = DownloadControl::default();
    let (sender, receiver) = oneshot::channel();
    let finished = Arc::new(std::sync::atomic::AtomicBool::new(false));
    let (poll_control, poll_finished) = (control.clone(), finished.clone());
    std::thread::spawn(move || {
        while !poll_finished.load(Ordering::Relaxed) {
            progress(poll_control.completed.load(Ordering::Relaxed) as f64 / model.bytes() as f64);
            std::thread::sleep(Duration::from_millis(100));
        }
    });
    let worker_control = control.clone();
    std::thread::Builder::new()
        .name("tick-model-download".into())
        .spawn(move || {
            let result = model.download(&worker_control);
            finished.store(true, Ordering::Relaxed);
            let _ = sender.send(result);
        })
        .expect("spawning the model download thread");
    Download::Gguf { control, receiver }
}

/// Loads `model` so the first dictation is fast; unloads the GGUF engine
/// when a Swift-run model takes over.
pub async fn warm(model: &str) -> Result<(), NativeError> {
    match Engine::of(model) {
        Engine::Gguf(model) => {
            if !model.is_downloaded() {
                return Ok(());
            }
            engine::engine().load(model).await.map_err(failed)
        }
        Engine::Native => {
            engine::engine().unload();
            native::speech::warm(model).await
        }
    }
}

pub async fn transcribe(
    path: &Path,
    model: &str,
    language: Option<&str>,
) -> Result<String, NativeError> {
    match Engine::of(model) {
        Engine::Gguf(model) => engine::engine()
            .transcribe(model, path)
            .await
            .map_err(failed),
        Engine::Native => native::speech::transcribe(path, model, language).await,
    }
}

pub async fn delete(model: &str) -> Result<(), NativeError> {
    match Engine::of(model) {
        Engine::Gguf(model) => {
            engine::engine().unload();
            model
                .delete()
                .map_err(|e| failed(format!("The model could not be deleted: {e}")))
        }
        Engine::Native => native::speech::delete(model).await,
    }
}

pub async fn is_downloaded(model: &str) -> bool {
    match Engine::of(model) {
        Engine::Gguf(model) => model.is_downloaded(),
        Engine::Native => native::speech::is_downloaded(model).await,
    }
}

/// Starts a streaming session. `false` when the model does not stream here.
pub async fn start_streaming(model: &str) -> Result<bool, NativeError> {
    let (owner, started) = match Engine::of(model) {
        Engine::Gguf(model) => (StreamOwner::Gguf, engine::engine().begin(model).await),
        Engine::Native => (
            StreamOwner::Native,
            native::speech::start_streaming(model).await?,
        ),
    };
    *STREAM_OWNER.lock() = if started { owner } else { StreamOwner::None };
    Ok(started)
}

/// Words the open stream has heard so far. Empty when nothing is streaming.
pub fn partial() -> LiveText {
    match *STREAM_OWNER.lock() {
        StreamOwner::Gguf => engine::partial(),
        StreamOwner::None | StreamOwner::Native => LiveText::default(),
    }
}

/// Feeds 16 kHz mono samples to the active stream (no-op without one).
pub fn push(samples: &[f32]) {
    if samples.is_empty() {
        return;
    }
    match *STREAM_OWNER.lock() {
        StreamOwner::None => {}
        StreamOwner::Gguf => engine::engine().feed(samples),
        StreamOwner::Native => native::speech::push(samples),
    }
}

pub async fn finish_streaming() -> Result<Option<String>, NativeError> {
    let owner = std::mem::replace(&mut *STREAM_OWNER.lock(), StreamOwner::None);
    match owner {
        StreamOwner::None => Ok(None),
        StreamOwner::Gguf => engine::engine().finish().await.map_err(failed),
        StreamOwner::Native => native::speech::finish_streaming().await,
    }
}

pub fn cancel_streaming() {
    let owner = std::mem::replace(&mut *STREAM_OWNER.lock(), StreamOwner::None);
    match owner {
        StreamOwner::None => {}
        StreamOwner::Gguf => engine::engine().cancel_stream(),
        StreamOwner::Native => native::speech::cancel_streaming(),
    }
    engine::clear_partial();
}
