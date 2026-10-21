//! One thread owns the loaded GGUF model. Loads, offline runs and live
//! streams share its queue in order. A live stream borrows the model's
//! session, so while one is open the thread only feeds it until it is
//! finished or cancelled; any other command abandons the stream first.

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, LazyLock};
use std::time::{Duration, Instant};

use crossbeam_channel::{Receiver, Sender};
use futures::channel::oneshot;
use transcribe_cpp::{
    Backend, CancelToken, DeviceType, Model, ModelOptions, RunOptions, Session, SessionOptions, StreamOptions,
    TimestampKind,
};

use super::gguf::GgufModel;

/// Parakeet needs at least this much audio; shorter clips are padded.
const MINIMUM_SAMPLES: usize = 24_000;
/// 8 s reaches every stream window shape a dictation uses (5.6 s left
/// context), so Metal compiles those kernels at load, not on the first finish.
const STREAM_PREWARM_SAMPLES: usize = 8 * 16_000;
/// A stream that has not produced its final text by then is aborted and the
/// whole clip is transcribed instead.
const STREAM_FINISH_DEADLINE: Duration = Duration::from_millis(1_500);

enum Command {
    Load { model: &'static GgufModel, reply: oneshot::Sender<Result<(), String>> },
    Unload,
    Begin { model: &'static GgufModel, reply: oneshot::Sender<bool> },
    Feed(Vec<f32>),
    Finish { reply: oneshot::Sender<Result<Option<String>, String>> },
    Cancel,
    Transcribe { model: &'static GgufModel, path: PathBuf, reply: oneshot::Sender<Result<String, String>> },
}

/// Cheap handle to the engine thread.
pub struct Engine {
    commands: Sender<Command>,
    cancel: CancelToken,
    /// Bumped per run so a late deadline cannot cancel a newer one.
    generation: Arc<AtomicU64>,
}

static ENGINE: LazyLock<Engine> = LazyLock::new(Engine::spawn);

pub fn engine() -> &'static Engine {
    &ENGINE
}

impl Engine {
    fn spawn() -> Engine {
        let (commands, receiver) = crossbeam_channel::unbounded();
        let cancel = CancelToken::new();
        let generation = Arc::new(AtomicU64::new(0));
        let worker = Worker { loaded: None, cancel: cancel.clone(), generation: generation.clone() };
        std::thread::Builder::new()
            .name("tick-gguf".into())
            .spawn(move || worker.run(receiver))
            .expect("spawning the GGUF engine thread");
        Engine { commands, cancel, generation }
    }

    async fn request<T>(&self, command: impl FnOnce(oneshot::Sender<T>) -> Command) -> Option<T> {
        let (reply, receiver) = oneshot::channel();
        self.commands.send(command(reply)).ok()?;
        receiver.await.ok()
    }

    pub async fn load(&self, model: &'static GgufModel) -> Result<(), String> {
        self.request(|reply| Command::Load { model, reply }).await.unwrap_or_else(|| Err(stopped()))
    }

    pub fn unload(&self) {
        let _ = self.commands.send(Command::Unload);
    }

    /// Opens a live stream when `model` is loaded and streams on this Mac.
    /// Never loads: a cold model would hold up the recording.
    pub async fn begin(&self, model: &'static GgufModel) -> bool {
        self.request(|reply| Command::Begin { model, reply }).await.unwrap_or(false)
    }

    pub fn feed(&self, samples: &[f32]) {
        let _ = self.commands.send(Command::Feed(samples.to_vec()));
    }

    pub fn cancel_stream(&self) {
        let _ = self.commands.send(Command::Cancel);
    }

    /// Finalizes the live stream. `Ok(None)` when none was open.
    pub async fn finish(&self) -> Result<Option<String>, String> {
        let generation = self.generation.load(Ordering::Acquire);
        let (cancel, current) = (self.cancel.clone(), self.generation.clone());
        std::thread::spawn(move || {
            std::thread::sleep(STREAM_FINISH_DEADLINE);
            if current.load(Ordering::Acquire) == generation {
                cancel.cancel();
            }
        });
        let result = self.request(|reply| Command::Finish { reply }).await.unwrap_or_else(|| Err(stopped()));
        self.generation.fetch_add(1, Ordering::AcqRel);
        result
    }

    /// Transcribes a finished 16 kHz mono recording, loading `model` first if needed.
    pub async fn transcribe(&self, model: &'static GgufModel, path: &Path) -> Result<String, String> {
        let path = path.to_path_buf();
        self.request(|reply| Command::Transcribe { model, path, reply }).await.unwrap_or_else(|| Err(stopped()))
    }
}

fn stopped() -> String {
    "The on-device transcription engine stopped unexpectedly. Restart Tick to recover; your recording was kept.".into()
}

struct Loaded {
    model: &'static GgufModel,
    transcriber: Model,
    session: Option<Session>,
    session_options: SessionOptions,
    run: RunOptions,
    /// Present only when the model advertises streaming, runs on the GPU,
    /// and its load probe succeeded.
    stream: Option<StreamOptions>,
}

impl Loaded {
    fn open(model: &'static GgufModel, cancel: &CancelToken) -> Result<Loaded, String> {
        if !model.is_downloaded() {
            return Err(format!("{} is not downloaded. Download it in Settings → Model.", model.identifier));
        }
        let started = Instant::now();
        transcribe_cpp::disable_logging();
        transcribe_cpp::init_backends_default().map_err(|e| format!("Metal could not be initialized: {e}"))?;
        let path = model.path();
        let transcriber = Model::load_with(&path, &ModelOptions { backend: Backend::Metal, device: None })
            .map_err(|e| format!("The speech model could not be loaded ({e}). Delete and download it again in Settings → Model."))?;
        let (architecture, variant) = (transcriber.arch(), transcriber.variant());
        if !model.matches(&architecture, &variant) {
            return Err(format!(
                "The downloaded file holds {architecture}/{variant}, not {}. Delete and download it again in Settings → Model.",
                model.identifier
            ));
        }
        let device = transcriber.device().map_err(|e| e.to_string())?;
        let gpu = matches!(device.device_type, DeviceType::Gpu | DeviceType::Igpu);
        // On the GPU only the per-token decoder runs on the CPU; extra
        // spin-waiting ggml workers stall it, so keep it on this thread.
        let session_options = if gpu { SessionOptions { n_threads: 1, ..Default::default() } } else { SessionOptions::default() };
        let capabilities = transcriber.capabilities();
        let language = capabilities.languages.iter().any(|l| l == "en").then(|| "en".to_string());
        let session = transcriber.session_with(&session_options).map_err(|e| e.to_string())?;
        let mut loaded = Loaded {
            model,
            transcriber,
            session: Some(session),
            session_options,
            run: RunOptions { timestamps: TimestampKind::Segment, language, ..Default::default() },
            stream: None,
        };
        loaded.run_offline(vec![0.0; MINIMUM_SAMPLES], cancel)?;
        if capabilities.supports_streaming && gpu {
            loaded.stream = loaded.probe_stream(cancel);
        }
        tracing::info!(
            target: "transcription",
            "loaded {} on {} in {}ms; streaming={}",
            model.identifier,
            device.kind,
            started.elapsed().as_millis(),
            loaded.stream.is_some()
        );
        Ok(loaded)
    }

    /// Takes the session for one run. Each run gets a fresh session after:
    /// transcribe-cpp keeps input-sized scratch for a session's lifetime.
    fn take_session(&mut self) -> Result<Session, String> {
        match self.session.take() {
            Some(session) => Ok(session),
            None => self.transcriber.session_with(&self.session_options).map_err(|e| e.to_string()),
        }
    }

    fn restore_session(&mut self) {
        self.session = self.transcriber.session_with(&self.session_options).ok();
    }

    fn run_offline(&mut self, mut samples: Vec<f32>, cancel: &CancelToken) -> Result<String, String> {
        samples.resize(samples.len().max(MINIMUM_SAMPLES), 0.0);
        samples.resize(samples.len() + self.model.trailing_silence_samples, 0.0);
        let mut session = self.take_session()?;
        session.set_cancel_token(cancel);
        let result = session.run(&samples, &self.run).map(|t| t.text.trim().to_string());
        drop(session);
        self.restore_session();
        result.map_err(|e| format!("Transcription failed: {e}"))
    }

    fn probe_stream(&mut self, cancel: &CancelToken) -> Option<StreamOptions> {
        let options = StreamOptions::default();
        let started = Instant::now();
        let mut session = self.take_session().ok()?;
        session.set_cancel_token(cancel);
        let result = session.stream(&self.run, &options).and_then(|mut stream| {
            stream.feed(&vec![0.0; STREAM_PREWARM_SAMPLES])?;
            stream.finalize().map(|_| ())
        });
        drop(session);
        self.restore_session();
        match result {
            Ok(()) => {
                tracing::info!(target: "transcription", "streaming available; prewarm {}ms", started.elapsed().as_millis());
                Some(options)
            }
            Err(error) => {
                tracing::warn!(target: "transcription", "model advertises streaming but could not stream: {error}");
                None
            }
        }
    }
}

struct Worker {
    loaded: Option<Loaded>,
    cancel: CancelToken,
    generation: Arc<AtomicU64>,
}

impl Worker {
    fn run(mut self, commands: Receiver<Command>) {
        let mut next = None;
        loop {
            let command = match next.take() {
                Some(command) => command,
                None => match commands.recv() {
                    Ok(command) => command,
                    Err(_) => return,
                },
            };
            match command {
                Command::Load { model, reply } => {
                    let _ = reply.send(self.ensure(model).map(|_| ()));
                }
                Command::Unload => self.loaded = None,
                Command::Begin { model, reply } => next = self.stream(model, reply, &commands),
                // Without an open stream there is nothing to feed or finish.
                Command::Feed(_) | Command::Cancel => {}
                Command::Finish { reply } => {
                    let _ = reply.send(Ok(None));
                }
                Command::Transcribe { model, path, reply } => {
                    self.cancel.reset();
                    let result = read_samples(&path).and_then(|samples| {
                        let cancel = self.cancel.clone();
                        self.ensure(model)?.run_offline(samples, &cancel)
                    });
                    let _ = reply.send(result);
                }
            }
        }
    }

    fn ensure(&mut self, model: &'static GgufModel) -> Result<&mut Loaded, String> {
        if self.loaded.as_ref().is_none_or(|loaded| loaded.model != model) {
            // Drop the old model first so two never sit in memory together.
            self.loaded = None;
            self.cancel.reset();
            self.loaded = Some(Loaded::open(model, &self.cancel)?);
        }
        self.loaded.as_mut().ok_or_else(stopped)
    }

    /// Runs one live stream to its end. Returns a command that arrived
    /// mid-stream and must be handled after it.
    fn stream(&mut self, model: &'static GgufModel, reply: oneshot::Sender<bool>, commands: &Receiver<Command>) -> Option<Command> {
        let Some(loaded) = self.loaded.as_mut().filter(|loaded| loaded.model == model) else {
            let _ = reply.send(false);
            return None;
        };
        let Some(options) = loaded.stream.clone() else {
            let _ = reply.send(false);
            return None;
        };
        let mut session = match loaded.take_session() {
            Ok(session) => session,
            Err(error) => {
                tracing::warn!(target: "transcription", "could not open a stream session: {error}");
                let _ = reply.send(false);
                return None;
            }
        };
        self.cancel.reset();
        self.generation.fetch_add(1, Ordering::AcqRel);
        session.set_cancel_token(&self.cancel);
        let started = Instant::now();
        let mut fed = 0usize;
        let leftover = match session.stream(&loaded.run, &options) {
            Err(error) => {
                tracing::warn!(target: "transcription", "could not begin a live stream: {error}");
                let _ = reply.send(false);
                None
            }
            Ok(mut stream) => {
                let _ = reply.send(true);
                let mut failure: Option<String> = None;
                loop {
                    match commands.recv() {
                        Ok(Command::Feed(samples)) => {
                            if failure.is_none() {
                                fed += samples.len();
                                if let Err(error) = stream.feed(&samples) {
                                    failure = Some(format!("stream feed failed: {error}"));
                                }
                            }
                        }
                        Ok(Command::Finish { reply }) => {
                            let finish_started = Instant::now();
                            let result = match failure {
                                Some(error) => Err(error),
                                None => finalize(&mut stream, model.trailing_silence_samples),
                            };
                            tracing::info!(
                                target: "transcription",
                                "stream finished: audio={}ms finish={}ms ok={}",
                                fed / 16,
                                finish_started.elapsed().as_millis(),
                                result.is_ok()
                            );
                            let _ = reply.send(result.map(Some));
                            break None;
                        }
                        Ok(Command::Cancel) | Err(_) => break None,
                        Ok(other) => break Some(other),
                    }
                }
            }
        };
        drop(session);
        loaded.restore_session();
        tracing::debug!(target: "transcription", "stream closed after {}ms", started.elapsed().as_millis());
        leftover
    }
}

/// Appends the model's trailing context, then flushes the stream.
fn finalize(stream: &mut transcribe_cpp::Stream<'_>, trailing_silence: usize) -> Result<String, String> {
    if trailing_silence > 0 {
        stream.feed(&vec![0.0; trailing_silence]).map_err(|e| format!("stream feed failed: {e}"))?;
    }
    stream.finalize().map_err(|e| format!("stream finalize failed: {e}"))?;
    let text = stream.text().full.trim().to_string();
    if text.is_empty() { Err("the stream returned no text".into()) } else { Ok(text) }
}

/// Reads the recorder's 16 kHz mono float WAV.
fn read_samples(path: &Path) -> Result<Vec<f32>, String> {
    let mut reader = hound::WavReader::open(path).map_err(|e| format!("The recording could not be read: {e}"))?;
    let spec = reader.spec();
    if spec.sample_rate != 16_000 || spec.channels != 1 || spec.sample_format != hound::SampleFormat::Float {
        return Err(format!(
            "The recording is {} Hz, {} channel(s), {:?}; expected 16 kHz mono float.",
            spec.sample_rate, spec.channels, spec.sample_format
        ));
    }
    reader.samples::<f32>().collect::<Result<Vec<_>, _>>().map_err(|e| format!("The recording could not be read: {e}"))
}
