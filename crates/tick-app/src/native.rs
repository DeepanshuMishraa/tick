//! Safe wrappers over the TickNative Swift bridge (Core ML speech engines,
//! MLX generation, PermissionFlow panel, Sparkle).
//!
//! Every asynchronous call registers a slot keyed by a numeric id that is
//! passed to Swift as the opaque context. Callbacks look the slot up by id,
//! so a late callback after completion is ignored instead of touching freed
//! memory.

use std::collections::HashMap;
use std::ffi::{CStr, CString, c_char, c_void};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, LazyLock};

use futures::channel::oneshot;
use parking_lot::Mutex;

type DoneFn = extern "C" fn(*mut c_void, *const c_char, *const c_char);
type ProgressFn = extern "C" fn(*mut c_void, f64);
type ChunkFn = extern "C" fn(*mut c_void, *const c_char) -> bool;

#[link(name = "TickNative", kind = "framework")]
unsafe extern "C" {
    fn tn_task_cancel(id: u64);
    fn tn_speech_download(
        model: *const c_char,
        ctx: *mut c_void,
        progress: ProgressFn,
        done: DoneFn,
    ) -> u64;
    fn tn_speech_warm(model: *const c_char, ctx: *mut c_void, done: DoneFn);
    fn tn_speech_transcribe(
        path: *const c_char,
        model: *const c_char,
        language: *const c_char,
        ctx: *mut c_void,
        done: DoneFn,
    );
    fn tn_speech_delete(model: *const c_char, ctx: *mut c_void, done: DoneFn);
    fn tn_speech_is_downloaded(model: *const c_char, ctx: *mut c_void, done: DoneFn);
    fn tn_speech_catalog(ctx: *mut c_void, done: DoneFn);
    fn tn_stream_start(model: *const c_char, ctx: *mut c_void, done: DoneFn);
    fn tn_stream_push(samples: *const f32, count: isize);
    fn tn_stream_finish(ctx: *mut c_void, done: DoneFn);
    fn tn_stream_cancel();
    fn tn_llm_warm(directory: *const c_char, ctx: *mut c_void, done: DoneFn);
    fn tn_llm_generate(
        directory: *const c_char,
        system: *const c_char,
        user: *const c_char,
        max_tokens: i32,
        ctx: *mut c_void,
        chunk: ChunkFn,
        done: DoneFn,
    );
    fn tn_llm_unload();
    fn tn_permission_flow_open(pane: i32);
    fn tn_permission_flow_dismiss();
    fn tn_updater_start();
    fn tn_updater_check();
    fn tn_updater_can_check() -> bool;
}

/// A failure reported by a native engine, in its own words.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum NativeError {
    #[error("{0}")]
    Failed(String),
    #[error("The operation was cancelled.")]
    Cancelled,
    #[error("The native engine stopped before replying.")]
    Dropped,
}

type Reply = Result<Option<String>, NativeError>;

struct Slot {
    reply: Option<oneshot::Sender<Reply>>,
    progress: Option<Arc<dyn Fn(f64) + Send + Sync>>,
    chunk: Option<Arc<dyn Fn(&str) -> bool + Send + Sync>>,
}

static NEXT_SLOT: AtomicUsize = AtomicUsize::new(1);
static SLOTS: LazyLock<Mutex<HashMap<usize, Slot>>> = LazyLock::new(|| Mutex::new(HashMap::new()));

fn register(slot: Slot) -> usize {
    let id = NEXT_SLOT.fetch_add(1, Ordering::Relaxed);
    SLOTS.lock().insert(id, slot);
    id
}

fn copy(pointer: *const c_char) -> Option<String> {
    // SAFETY: Swift passes either null or a NUL-terminated string valid for this call.
    (!pointer.is_null()).then(|| {
        unsafe { CStr::from_ptr(pointer) }
            .to_string_lossy()
            .into_owned()
    })
}

extern "C" fn on_done(ctx: *mut c_void, result: *const c_char, error: *const c_char) {
    let Some(slot) = SLOTS.lock().remove(&(ctx as usize)) else {
        return;
    };
    let reply = match copy(error) {
        Some(message) if message == "cancelled" => Err(NativeError::Cancelled),
        Some(message) => Err(NativeError::Failed(message)),
        None => Ok(copy(result)),
    };
    if let Some(sender) = slot.reply {
        let _ = sender.send(reply);
    }
}

extern "C" fn on_progress(ctx: *mut c_void, fraction: f64) {
    let progress = SLOTS
        .lock()
        .get(&(ctx as usize))
        .and_then(|slot| slot.progress.clone());
    if let Some(progress) = progress {
        progress(fraction);
    }
}

extern "C" fn on_chunk(ctx: *mut c_void, text: *const c_char) -> bool {
    let chunk = SLOTS
        .lock()
        .get(&(ctx as usize))
        .and_then(|slot| slot.chunk.clone());
    match (chunk, copy(text)) {
        (Some(chunk), Some(text)) => chunk(&text),
        _ => false,
    }
}

fn c(value: &str) -> CString {
    CString::new(value.replace('\0', "")).unwrap_or_default()
}

async fn wait(receiver: oneshot::Receiver<Reply>) -> Reply {
    receiver.await.unwrap_or(Err(NativeError::Dropped))
}

fn slot() -> (usize, oneshot::Receiver<Reply>) {
    let (sender, receiver) = oneshot::channel();
    (
        register(Slot {
            reply: Some(sender),
            progress: None,
            chunk: None,
        }),
        receiver,
    )
}

/// Core ML speech engines (WhisperKit and Parakeet).
pub mod speech {
    use super::*;

    /// A running model download; dropping it does not cancel.
    pub struct Download {
        task_id: u64,
        receiver: oneshot::Receiver<Reply>,
    }

    impl Download {
        pub fn cancel_handle(&self) -> CancelHandle {
            CancelHandle(self.task_id)
        }

        pub async fn finish(self) -> Result<(), NativeError> {
            wait(self.receiver).await.map(|_| ())
        }
    }

    #[derive(Debug, Clone, Copy)]
    pub struct CancelHandle(u64);

    impl CancelHandle {
        pub fn cancel(self) {
            // SAFETY: plain value call into the bridge.
            unsafe { tn_task_cancel(self.0) }
        }
    }

    /// Downloads (if needed) and loads `model`, reporting 0…1 progress.
    pub fn download(model: &str, progress: impl Fn(f64) + Send + Sync + 'static) -> Download {
        let (sender, receiver) = oneshot::channel();
        let id = register(Slot {
            reply: Some(sender),
            progress: Some(Arc::new(progress)),
            chunk: None,
        });
        let model = c(model);
        // SAFETY: arguments outlive the call; Swift copies strings immediately.
        let task_id =
            unsafe { tn_speech_download(model.as_ptr(), id as *mut c_void, on_progress, on_done) };
        Download { task_id, receiver }
    }

    pub async fn warm(model: &str) -> Result<(), NativeError> {
        let (id, receiver) = slot();
        let model = c(model);
        // SAFETY: see `download`.
        unsafe { tn_speech_warm(model.as_ptr(), id as *mut c_void, on_done) };
        wait(receiver).await.map(|_| ())
    }

    pub async fn transcribe(
        path: &std::path::Path,
        model: &str,
        language: Option<&str>,
    ) -> Result<String, NativeError> {
        let (id, receiver) = slot();
        let path = c(&path.to_string_lossy());
        let model = c(model);
        let language = language.map(c);
        let language_ptr = language.as_ref().map_or(std::ptr::null(), |l| l.as_ptr());
        // SAFETY: see `download`.
        unsafe {
            tn_speech_transcribe(
                path.as_ptr(),
                model.as_ptr(),
                language_ptr,
                id as *mut c_void,
                on_done,
            )
        };
        wait(receiver).await.map(Option::unwrap_or_default)
    }

    pub async fn delete(model: &str) -> Result<(), NativeError> {
        let (id, receiver) = slot();
        let model = c(model);
        // SAFETY: see `download`.
        unsafe { tn_speech_delete(model.as_ptr(), id as *mut c_void, on_done) };
        wait(receiver).await.map(|_| ())
    }

    pub async fn is_downloaded(model: &str) -> bool {
        let (id, receiver) = slot();
        let model = c(model);
        // SAFETY: see `download`.
        unsafe { tn_speech_is_downloaded(model.as_ptr(), id as *mut c_void, on_done) };
        matches!(wait(receiver).await, Ok(Some(value)) if value == "1")
    }

    #[derive(Debug, Clone, serde::Deserialize)]
    pub struct CatalogEntry {
        pub name: String,
        pub downloaded: bool,
    }

    #[derive(Debug, Clone, serde::Deserialize)]
    pub struct Catalog {
        pub recommended: String,
        pub models: Vec<CatalogEntry>,
    }

    /// Every WhisperKit variant on Hugging Face plus Parakeet, with download state.
    pub async fn catalog() -> Result<Catalog, NativeError> {
        let (id, receiver) = slot();
        // SAFETY: see `download`.
        unsafe { tn_speech_catalog(id as *mut c_void, on_done) };
        let json = wait(receiver).await?.unwrap_or_default();
        serde_json::from_str(&json)
            .map_err(|error| NativeError::Failed(format!("Unreadable model catalog: {error}")))
    }

    /// Starts a Parakeet streaming session. `false` when the model does not stream.
    pub async fn start_streaming(model: &str) -> Result<bool, NativeError> {
        let (id, receiver) = slot();
        let model = c(model);
        // SAFETY: see `download`.
        unsafe { tn_stream_start(model.as_ptr(), id as *mut c_void, on_done) };
        Ok(matches!(wait(receiver).await?, Some(value) if value == "1"))
    }

    /// Feeds 16 kHz mono samples to the active stream (no-op without one).
    pub fn push(samples: &[f32]) {
        if samples.is_empty() {
            return;
        }
        let count = isize::try_from(samples.len()).unwrap_or(isize::MAX);
        // SAFETY: the pointer/count pair describes `samples`, copied synchronously.
        unsafe { tn_stream_push(samples.as_ptr(), count) };
    }

    pub async fn finish_streaming() -> Result<Option<String>, NativeError> {
        let (id, receiver) = slot();
        // SAFETY: see `download`.
        unsafe { tn_stream_finish(id as *mut c_void, on_done) };
        wait(receiver).await
    }

    pub fn cancel_streaming() {
        // SAFETY: plain call into the bridge.
        unsafe { tn_stream_cancel() }
    }
}

/// MLX on-device language model.
pub mod llm {
    use super::*;

    pub async fn warm(directory: &std::path::Path) -> Result<(), NativeError> {
        let (id, receiver) = slot();
        let directory = c(&directory.to_string_lossy());
        // SAFETY: see `speech::download`.
        unsafe { tn_llm_warm(directory.as_ptr(), id as *mut c_void, on_done) };
        wait(receiver).await.map(|_| ())
    }

    /// Streams generated text to `on_chunk` until it returns `false` or the
    /// model stops.
    pub async fn generate(
        directory: &std::path::Path,
        system: &str,
        user: &str,
        max_tokens: i32,
        handler: impl Fn(&str) -> bool + Send + Sync + 'static,
    ) -> Result<(), NativeError> {
        let (sender, receiver) = oneshot::channel();
        let id = register(Slot {
            reply: Some(sender),
            progress: None,
            chunk: Some(Arc::new(handler)),
        });
        let directory = c(&directory.to_string_lossy());
        let system = c(system);
        let user = c(user);
        // SAFETY: see `speech::download`.
        unsafe {
            tn_llm_generate(
                directory.as_ptr(),
                system.as_ptr(),
                user.as_ptr(),
                max_tokens,
                id as *mut c_void,
                on_chunk,
                on_done,
            )
        };
        wait(receiver).await.map(|_| ())
    }

    pub fn unload() {
        // SAFETY: plain call into the bridge.
        unsafe { tn_llm_unload() }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PermissionPane {
    Accessibility,
    InputMonitoring,
}

/// Opens System Settings with the drag-to-authorize helper panel.
pub fn open_permission_panel(pane: PermissionPane) {
    let value = match pane {
        PermissionPane::Accessibility => 0,
        PermissionPane::InputMonitoring => 1,
    };
    // SAFETY: plain call into the bridge; it hops to the main queue.
    unsafe { tn_permission_flow_open(value) }
}

pub fn dismiss_permission_panel() {
    // SAFETY: plain call into the bridge.
    unsafe { tn_permission_flow_dismiss() }
}

pub mod updater {
    use super::*;

    pub fn start() {
        // SAFETY: plain call into the bridge.
        unsafe { tn_updater_start() }
    }

    pub fn check() {
        // SAFETY: plain call into the bridge.
        unsafe { tn_updater_check() }
    }

    pub fn can_check() -> bool {
        // SAFETY: plain call into the bridge.
        unsafe { tn_updater_can_check() }
    }
}
