//! Walkthroughs: press the walkthrough shortcut, talk, click and draw on the
//! screen, press it again. Keyframes are captured when something happens,
//! the narration is transcribed on device and matched to them, and the
//! contact sheet plus a timestamped summary are pasted into the front app
//! (usually an AI agent).

use std::path::PathBuf;
use std::time::{Duration, Instant};

use futures::channel::mpsc::{self, UnboundedSender};
use futures::StreamExt;
use gpui_kit::{AsyncApp, Context, Task, WeakEntity};
use image::RgbaImage;
use tick_core::hotkey::MousePhase;
use tick_core::settings::Settings;
use tick_core::walkthrough::{self, Header, Keyframe, Stroke, Thumbnail, Trigger};

use super::dictation::{apply_text_rules, remove_file, sleeper, stop_recorder};
use super::{AppState, Feedback, PasteFailure, Phase};
use crate::audio::capture::SAMPLE_RATE;
use crate::hotkeys::{WalkthroughInput, WalkthroughTap};
use crate::platform::paste::{self, PasteResult};
use crate::platform::screen::{self, Display};
use crate::platform::system::{self, ScreenGeometry};
use crate::platform::workspace::{self, Haptic};
use crate::sound::Cue;
use crate::walkthrough as bundle;

/// Delay before a click's keyframe, so it shows what the click did.
const CLICK_SETTLE: Duration = Duration::from_millis(300);
/// Delay before a mark's keyframe, so the overlay has drawn it.
const MARK_SETTLE: Duration = Duration::from_millis(60);
/// How long a click ripple stays on screen.
pub const RIPPLE: Duration = Duration::from_millis(600);
/// Width keyframes are kept at in memory for the contact sheet.
const TILE_COLUMNS: usize = 2;

/// A mark drawn over the screen while recording.
#[derive(Debug, Clone, PartialEq)]
pub enum Mark {
    Ink(Stroke),
    Pin { number: u32, at: (f32, f32) },
}

/// What the ink overlay shows. Kept apart from `AppState` so pointer
/// movement redraws only the overlay.
#[derive(Debug, Default)]
pub struct Sketch {
    /// The screen being recorded; `None` hides the overlay.
    pub screen: Option<ScreenGeometry>,
    pub marks: Vec<Mark>,
    /// The stroke under the pointer, in overlay points.
    pub current: Option<Stroke>,
    pub ripples: Vec<(Instant, (f32, f32))>,
    /// The overlay's window number, kept visible in keyframes.
    pub window: Option<u32>,
}

impl Sketch {
    fn next_pin(&self) -> u32 {
        self.marks.iter().filter(|mark| matches!(mark, Mark::Pin { .. })).count() as u32 + 1
    }
}

struct Request {
    trigger: Trigger,
    at: f64,
    not_before: Instant,
}

/// Keyframes kept by the capture worker, with their contact-sheet tiles.
#[derive(Default)]
struct Captured {
    keyframes: Vec<Keyframe>,
    tiles: Vec<RgbaImage>,
}

pub(super) struct Session {
    started: Instant,
    bundle: PathBuf,
    origin: (f64, f64),
    app: Option<String>,
    requests: UnboundedSender<Request>,
    worker: Task<Captured>,
    _poll: Task<()>,
    last_deliberate: Option<f64>,
    deliberate: usize,
}

pub(super) enum Walkthrough {
    Recording(Session),
    /// Transcribing, assembling and pasting the finished recording.
    Compiling,
}

impl AppState {
    pub(super) fn walkthrough_input(&mut self, input: WalkthroughInput, cx: &mut Context<Self>) {
        match input {
            WalkthroughInput::Toggle => match &self.walkthrough {
                Some(Walkthrough::Recording(_)) => self.finish_walkthrough(cx),
                Some(Walkthrough::Compiling) => {}
                None => self.start_walkthrough(cx),
            },
            WalkthroughInput::Undo => self.undo_mark(cx),
            WalkthroughInput::Ink(phase, x, y) => self.ink(phase, x, y, cx),
            WalkthroughInput::Click(x, y) => self.walkthrough_click(x, y, cx),
        }
    }

    fn start_walkthrough(&mut self, cx: &mut Context<Self>) {
        if self.phase != Phase::Idle || !self.require_model(cx) {
            return;
        }
        if !screen::recording_granted() {
            tracing::warn!(target: "walkthrough", "Screen Recording is not granted; asking");
            screen::request_recording();
            self.sound.play(Cue::Warning);
            self.show_notice(Feedback::ScreenRecordingNeeded, cx);
            return;
        }
        let Some(geometry) = system::active_screen() else {
            tracing::error!(target: "walkthrough", "no screen under the pointer; walkthrough not started");
            return;
        };
        let bundle = match bundle::create_bundle() {
            Ok(bundle) => bundle,
            Err(error) => {
                tracing::error!(target: "walkthrough", "could not create the walkthrough folder: {error}");
                self.sound.play(Cue::Error);
                self.show_notice(Feedback::WalkthroughFailed("Tick couldn't create a folder for it in Application Support.".into()), cx);
                return;
            }
        };
        let origin = geometry.display_origin();
        let display = Display { x: origin.0, y: origin.1, width: geometry.width, height: geometry.height, scale: geometry.scale };
        let keep_window = self.sketch.read(cx).window;
        let started = Instant::now();
        let (requests, receiver) = mpsc::unbounded::<Request>();
        let worker = spawn_worker(receiver, display, keep_window, bundle.clone(), cx);
        let poll_requests = requests.clone();
        let poll = cx.spawn(async move |_, cx| loop {
            cx.background_executor().timer(Duration::from_secs_f64(walkthrough::CHANGE_POLL_INTERVAL)).await;
            let request = Request { trigger: Trigger::ScreenChanged, at: started.elapsed().as_secs_f64(), not_before: Instant::now() };
            if poll_requests.unbounded_send(request).is_err() {
                break;
            }
        });
        self.walkthrough = Some(Walkthrough::Recording(Session {
            started,
            bundle,
            origin,
            app: workspace::frontmost_app().map(|app| app.name),
            requests,
            worker,
            _poll: poll,
            last_deliberate: None,
            deliberate: 0,
        }));
        self.notice = None;
        self.phase = Phase::Walkthrough { started };
        self.hotkeys.set_walkthrough(WalkthroughTap::Recording { undoable: false });
        self.sketch.update(cx, |sketch, cx| {
            *sketch = Sketch { screen: Some(geometry), window: sketch.window, ..Sketch::default() };
            cx.notify();
        });
        self.sound.press(Cue::Lock);
        workspace::haptic(Haptic::Alignment);
        if self.settings.prevent_system_sleep {
            self.sleep = crate::platform::system::SleepAssertion::prevent("Tick walkthrough");
        }
        let finish = self.settings.walkthrough_hotkey.as_ref().map(|hotkey| hotkey.label()).unwrap_or_default();
        self.show_notice(Feedback::WalkthroughStarted { finish }, cx);
        // The overlay needs a moment to appear before the first frame.
        self.request_keyframe(Trigger::Start, Duration::from_millis(150));
        tracing::info!(target: "walkthrough", "walkthrough started");

        let recorder = self.recorder.clone();
        self.tasks.transcription = Some(cx.spawn(async move |this, cx| {
            let result = cx.background_executor().spawn(async move { recorder.start() }).await;
            if let Err(error) = result {
                tracing::error!(target: "walkthrough", "microphone failed to start: {error}");
                let _ = this.update(cx, |state, cx| {
                    state.cancel(cx);
                    state.show_notice(Feedback::WalkthroughFailed("The microphone didn't start.".into()), cx);
                });
            }
        }));
        cx.notify();
    }

    fn request_keyframe(&mut self, trigger: Trigger, settle: Duration) {
        let Some(Walkthrough::Recording(session)) = &mut self.walkthrough else { return };
        let at = session.started.elapsed().as_secs_f64();
        if !walkthrough::accepts_keyframe(session.last_deliberate, session.deliberate, at, trigger) {
            return;
        }
        session.last_deliberate = Some(at);
        session.deliberate += 1;
        let _ = session.requests.unbounded_send(Request { trigger, at, not_before: Instant::now() + settle });
    }

    /// Converts a global point to overlay points; `None` off the recorded screen.
    fn local_point(&self, x: f64, y: f64, cx: &Context<Self>) -> Option<(f32, f32)> {
        let Some(Walkthrough::Recording(session)) = &self.walkthrough else { return None };
        let screen = self.sketch.read(cx).screen?;
        let (local_x, local_y) = (x - session.origin.0, y - session.origin.1);
        (local_x >= 0.0 && local_y >= 0.0 && local_x <= screen.width && local_y <= screen.height)
            .then_some((local_x as f32, local_y as f32))
    }

    fn ink(&mut self, phase: MousePhase, x: f64, y: f64, cx: &mut Context<Self>) {
        let Some(point) = self.local_point(x, y, cx) else {
            if phase == MousePhase::Up {
                self.end_stroke(cx);
            }
            return;
        };
        match phase {
            MousePhase::Down => self.sketch.update(cx, |sketch, cx| {
                sketch.current = Some(vec![point]);
                cx.notify();
            }),
            MousePhase::Dragged => self.sketch.update(cx, |sketch, cx| {
                let Some(stroke) = sketch.current.as_mut() else { return };
                // Sub-point jitter adds vertices without changing the line.
                if stroke.last().is_some_and(|last| (last.0 - point.0).abs() + (last.1 - point.1).abs() < 1.5) {
                    return;
                }
                stroke.push(point);
                cx.notify();
            }),
            MousePhase::Up => {
                self.sketch.update(cx, |sketch, _| {
                    if let Some(stroke) = sketch.current.as_mut() {
                        stroke.push(point);
                    }
                });
                self.end_stroke(cx);
            }
        }
    }

    fn end_stroke(&mut self, cx: &mut Context<Self>) {
        let trigger = self.sketch.update(cx, |sketch, cx| {
            let stroke = sketch.current.take()?;
            let trigger = if walkthrough::is_tap(&stroke) {
                let number = sketch.next_pin();
                sketch.marks.push(Mark::Pin { number, at: stroke[0] });
                Trigger::Pin(number)
            } else {
                sketch.marks.push(Mark::Ink(stroke));
                Trigger::Ink
            };
            cx.notify();
            Some(trigger)
        });
        if let Some(trigger) = trigger {
            self.hotkeys.set_walkthrough(WalkthroughTap::Recording { undoable: true });
            self.request_keyframe(trigger, MARK_SETTLE);
        }
    }

    fn undo_mark(&mut self, cx: &mut Context<Self>) {
        let remaining = self.sketch.update(cx, |sketch, cx| {
            sketch.marks.pop();
            cx.notify();
            sketch.marks.len()
        });
        if matches!(self.walkthrough, Some(Walkthrough::Recording(_))) {
            self.hotkeys.set_walkthrough(WalkthroughTap::Recording { undoable: remaining > 0 });
        }
    }

    fn walkthrough_click(&mut self, x: f64, y: f64, cx: &mut Context<Self>) {
        let Some(point) = self.local_point(x, y, cx) else { return };
        self.sketch.update(cx, |sketch, cx| {
            sketch.ripples.retain(|(at, _)| at.elapsed() < RIPPLE);
            sketch.ripples.push((Instant::now(), point));
            cx.notify();
        });
        self.request_keyframe(Trigger::Click, CLICK_SETTLE);
    }

    fn finish_walkthrough(&mut self, cx: &mut Context<Self>) {
        let Some(Walkthrough::Recording(session)) = self.walkthrough.replace(Walkthrough::Compiling) else { return };
        let duration = session.started.elapsed().as_secs_f64();
        tracing::info!(target: "walkthrough", "walkthrough finished after {duration:.1}s");
        self.phase = Phase::Transcribing;
        self.sleep = None;
        self.hotkeys.set_walkthrough(WalkthroughTap::Off);
        self.sound.release(Cue::Lock);
        workspace::haptic(Haptic::Level);
        self.notice = None;
        cx.notify();

        let recorder = self.recorder.clone();
        let settings = self.settings.clone();
        let previous = self.tasks.transcription.take();
        self.tasks.transcription = Some(cx.spawn(async move |this, cx| {
            if let Some(previous) = previous {
                previous.await;
            }
            let audio = cx.background_executor().spawn(async move { stop_recorder(&recorder) }).await;
            let Session { bundle, app, requests, worker, .. } = session;
            // Closing the queue lets the worker finish the frames already asked for.
            drop(requests);
            let captured = worker.await;
            let _ = this.update(cx, |state, cx| {
                state.sketch.update(cx, |sketch, cx| {
                    sketch.screen = None;
                    sketch.marks.clear();
                    sketch.current = None;
                    sketch.ripples.clear();
                    cx.notify();
                });
            });
            let outcome = compile(&bundle, captured, audio, duration, app, &settings, cx).await;
            match outcome {
                Ok((sheet, summary)) => {
                    let sleep = sleeper(cx);
                    let result = paste::paste_walkthrough(&sheet, &summary, &sleep).await;
                    let _ = this.update(cx, |state, cx| {
                        match result {
                            PasteResult::Pasted { .. } => state.sound.play(Cue::Ready),
                            PasteResult::NoFocusedInput => state.show_notice(Feedback::PasteUnavailable { text: summary, reason: PasteFailure::NoFocusedInput }, cx),
                            PasteResult::Failed => state.show_notice(Feedback::PasteUnavailable { text: summary, reason: PasteFailure::Rejected }, cx),
                        }
                        state.end_walkthrough(cx);
                    });
                }
                Err(message) => {
                    tracing::error!(target: "walkthrough", "walkthrough could not be assembled: {message}");
                    let _ = this.update(cx, |state, cx| {
                        state.sound.play(Cue::Error);
                        state.show_notice(Feedback::WalkthroughFailed(message), cx);
                        state.end_walkthrough(cx);
                    });
                }
            }
            cx.background_executor().spawn(async { bundle::purge_old() }).await;
        }));
    }

    fn end_walkthrough(&mut self, cx: &mut Context<Self>) {
        self.walkthrough = None;
        self.phase = Phase::Idle;
        cx.notify();
    }

    /// Esc while recording or compiling: drops everything, including the
    /// half-written bundle. Called from `cancel`.
    pub(super) fn discard_walkthrough(&mut self, cx: &mut Context<Self>) {
        let Some(walkthrough) = self.walkthrough.take() else { return };
        self.hotkeys.set_walkthrough(WalkthroughTap::Off);
        self.sketch.update(cx, |sketch, cx| {
            *sketch = Sketch { window: sketch.window, ..Sketch::default() };
            cx.notify();
        });
        if let Walkthrough::Recording(session) = walkthrough {
            let bundle = session.bundle.clone();
            drop(session);
            cx.background_executor()
                .spawn(async move {
                    let _ = std::fs::remove_dir_all(bundle);
                })
                .detach();
        }
        tracing::info!(target: "walkthrough", "walkthrough cancelled");
    }
}

/// Takes requested keyframes one at a time, so frames are numbered in order.
/// Screen-change polls are kept only when the screen actually changed.
fn spawn_worker(
    mut receiver: mpsc::UnboundedReceiver<Request>,
    display: Display,
    keep_window: Option<u32>,
    bundle: PathBuf,
    cx: &mut Context<AppState>,
) -> Task<Captured> {
    cx.spawn(async move |_: WeakEntity<AppState>, cx: &mut AsyncApp| {
        let mut captured = Captured::default();
        let mut last: Option<Thumbnail> = None;
        let mut warned = false;
        while let Some(request) = receiver.next().await {
            if captured.keyframes.len() >= walkthrough::MAX_KEYFRAMES {
                continue;
            }
            let wait = request.not_before.saturating_duration_since(Instant::now());
            if !wait.is_zero() {
                cx.background_executor().timer(wait).await;
            }
            let result = cx
                .background_executor()
                .spawn(async move {
                    let frame = screen::capture(&display, keep_window)?;
                    let thumbnail = Thumbnail::from_rgba(frame.as_raw(), frame.width() as usize, frame.height() as usize);
                    Ok::<_, screen::CaptureError>((frame, thumbnail))
                })
                .await;
            let (frame, thumbnail) = match result {
                Ok(captured) => captured,
                Err(error) => {
                    if !warned {
                        tracing::warn!(target: "walkthrough", "keyframe capture failed: {error}");
                        warned = true;
                    }
                    continue;
                }
            };
            let unchanged = matches!((&last, &thumbnail), (Some(last), Some(new)) if !new.differs_from(last));
            if !request.trigger.is_deliberate() && unchanged {
                continue;
            }
            last = thumbnail;
            let path = bundle::frame_path(&bundle, captured.keyframes.len());
            let tile = cx
                .background_executor()
                .spawn(async move {
                    if let Err(error) = frame.save(&path) {
                        tracing::error!(target: "walkthrough", "could not save a keyframe: {error}");
                    }
                    bundle::tile(&frame, TILE_COLUMNS)
                })
                .await;
            captured.keyframes.push(Keyframe { at: request.at, trigger: request.trigger });
            captured.tiles.push(tile);
        }
        captured
    })
}

/// Transcribes the narration, matches it to keyframes, and writes the
/// contact sheet and summary. Returns the sheet's path and the summary.
async fn compile(
    bundle: &std::path::Path,
    captured: Captured,
    audio: Option<PathBuf>,
    duration: f64,
    app: Option<String>,
    settings: &Settings,
    cx: &mut AsyncApp,
) -> Result<(PathBuf, String), String> {
    if captured.keyframes.is_empty() {
        remove_file(audio);
        return Err("No keyframes were captured. Check that Tick is allowed in System Settings › Screen Recording.".into());
    }
    let samples = match audio.clone() {
        Some(path) => cx.background_executor().spawn(async move { read_samples(&path) }).await,
        None => Vec::new(),
    };
    let spoken = walkthrough::utterances(&samples, SAMPLE_RATE);
    let owners = walkthrough::attribute(&spoken, &captured.keyframes);
    let mut speech: Vec<Vec<String>> = vec![Vec::new(); captured.keyframes.len()];
    let clip = bundle.join("clip.wav");
    for (utterance, owner) in spoken.iter().zip(owners) {
        let start = (utterance.start * f64::from(SAMPLE_RATE)) as usize;
        let end = ((utterance.end * f64::from(SAMPLE_RATE)) as usize).min(samples.len());
        let Some(slice) = samples.get(start..end) else { continue };
        if let Err(error) = write_clip(&clip, slice) {
            tracing::error!(target: "walkthrough", "could not write a speech clip: {error}");
            continue;
        }
        match crate::speech::transcribe(&clip, &settings.selected_model, settings.output_language.as_deref()).await {
            Ok(text) => {
                let text = apply_text_rules(text.trim(), settings);
                if !text.is_empty() {
                    speech[owner].push(text);
                }
            }
            Err(error) => tracing::error!(target: "walkthrough", "an utterance failed to transcribe: {error}"),
        }
    }
    remove_file(Some(clip));
    remove_file(audio);

    let sheet_path = bundle::contact_sheet_path(bundle);
    let header = Header {
        duration,
        app,
        bundle: bundle.display().to_string(),
        contact_sheet: sheet_path.display().to_string(),
    };
    let summary = walkthrough::summary(&header, &captured.keyframes, &speech);
    let (sheet, text, folder) = (sheet_path.clone(), summary.clone(), bundle.to_path_buf());
    cx.background_executor()
        .spawn(async move {
            let columns = walkthrough::sheet_columns(captured.tiles.len());
            let tiles: Vec<RgbaImage> = captured.tiles.iter().map(|tile| bundle::tile(tile, columns)).collect();
            let image = bundle::contact_sheet(&tiles).ok_or("No keyframes to lay out.")?;
            image.save(&sheet).map_err(|error| format!("The contact sheet couldn't be saved: {error}"))?;
            std::fs::write(folder.join("summary.md"), text).map_err(|error| format!("The summary couldn't be saved: {error}"))
        })
        .await?;
    Ok((sheet_path, summary))
}

fn read_samples(path: &std::path::Path) -> Vec<f32> {
    match hound::WavReader::open(path) {
        Ok(mut reader) => reader.samples::<f32>().filter_map(Result::ok).collect(),
        Err(error) => {
            tracing::error!(target: "walkthrough", "could not read the walkthrough audio: {error}");
            Vec::new()
        }
    }
}

fn write_clip(path: &std::path::Path, samples: &[f32]) -> Result<(), hound::Error> {
    let spec = hound::WavSpec { channels: 1, sample_rate: SAMPLE_RATE, bits_per_sample: 32, sample_format: hound::SampleFormat::Float };
    let mut writer = hound::WavWriter::create(path, spec)?;
    for sample in samples {
        writer.write_sample(*sample)?;
    }
    writer.finalize()
}
