//! The recording actor. A dedicated thread owns the input stream, the
//! default-input switching, and system output muting, mirroring the Swift
//! `RecordingClientLive` semantics.

use std::collections::HashSet;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::{Duration, Instant};

use crossbeam_channel::{Receiver, Sender};
use parking_lot::Mutex;
use tick_core::settings::RecordingAudioBehavior;
use uuid::Uuid;

use super::capture::{Capture, Meter};
use super::devices::{self, DeviceId, DeviceSnapshot, HardwareChange};
use crate::platform::workspace;

/// The subset of settings the recorder needs, captured per command.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RecorderConfig {
    pub super_fast: bool,
    pub microphone: Option<String>,
    pub audio_behavior: RecordingAudioBehavior,
}

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum EnvironmentChange {
    Hardware(HardwareChange),
    SystemWake,
}

impl EnvironmentChange {
    fn affects_input(&self) -> bool {
        !matches!(
            self,
            EnvironmentChange::Hardware(HardwareChange::DefaultOutput)
        )
    }
}

enum Command {
    Configure(RecorderConfig),
    WarmUp,
    Start { reply: Sender<Result<(), String>> },
    Stop { reply: Sender<Option<PathBuf>> },
    SetStreaming(bool),
    Environment(EnvironmentChange),
    FlushEnvironment(u64),
    RetryRestore { generation: Uuid, attempt: usize },
    ReapplyMute(Uuid),
    Cleanup { reply: Sender<()> },
}

#[derive(Debug, Clone, Copy)]
struct OutputState {
    volume: i64,
    muted: bool,
}

/// Cheap, cloneable handle to the recorder thread.
#[derive(Clone)]
pub struct Recorder {
    commands: Sender<Command>,
    meter: Arc<Mutex<Meter>>,
}

impl Recorder {
    /// Starts the actor. Device snapshots are delivered to `on_devices`.
    pub fn spawn(
        config: RecorderConfig,
        on_devices: impl Fn(DeviceSnapshot) + Send + 'static,
    ) -> Recorder {
        let (commands, receiver) = crossbeam_channel::unbounded();
        let (meter_tx, meter_rx) = crossbeam_channel::bounded(1);
        let loopback = commands.clone();
        std::thread::Builder::new()
            .name("tick-recorder".into())
            .spawn(move || {
                let capture = Capture::new();
                let _ = meter_tx.send(capture.meter.clone());
                let actor = Actor {
                    config,
                    capture,
                    loopback,
                    on_devices: Box::new(on_devices),
                    session: None,
                    original_input: None,
                    muted_output: None,
                    restore_generation: None,
                    active_device: None,
                    deferred_restart: false,
                    pending: HashSet::new(),
                    flush_token: 0,
                    started_at: None,
                };
                actor.run(receiver);
            })
            .expect("spawning the recorder thread");
        let meter = meter_rx.recv().unwrap_or_default();
        let recorder = Recorder { commands, meter };
        let observer = recorder.clone();
        devices::observe(move |change| {
            observer.environment_changed(EnvironmentChange::Hardware(change))
        });
        let observer = recorder.clone();
        crate::platform::workspace::on_wake(move || {
            observer.environment_changed(EnvironmentChange::SystemWake)
        });
        recorder
    }

    pub fn configure(&self, config: RecorderConfig) {
        let _ = self.commands.send(Command::Configure(config));
    }

    /// Pre-arms the microphone (Super Fast) or releases it (standard).
    pub fn warm_up(&self) {
        let _ = self.commands.send(Command::WarmUp);
    }

    /// Starts capturing; returns once the first file write is ready.
    pub fn start(&self) -> Result<(), String> {
        let (reply, response) = crossbeam_channel::bounded(1);
        let _ = self.commands.send(Command::Start { reply });
        response
            .recv()
            .unwrap_or_else(|_| Err("The recorder stopped unexpectedly.".into()))
    }

    /// Stops and returns the finished WAV file, if a recording was active.
    pub fn stop(&self) -> Option<PathBuf> {
        let (reply, response) = crossbeam_channel::bounded(1);
        let _ = self.commands.send(Command::Stop { reply });
        response.recv().ok().flatten()
    }

    pub fn set_streaming(&self, enabled: bool) {
        let _ = self.commands.send(Command::SetStreaming(enabled));
    }

    pub fn environment_changed(&self, change: EnvironmentChange) {
        let _ = self.commands.send(Command::Environment(change));
    }

    pub fn meter(&self) -> Meter {
        *self.meter.lock()
    }

    /// Restores audio state and releases the microphone (app termination).
    pub fn cleanup(&self) {
        let (reply, response) = crossbeam_channel::bounded(1);
        let _ = self.commands.send(Command::Cleanup { reply });
        let _ = response.recv_timeout(Duration::from_secs(2));
    }
}

struct Actor {
    config: RecorderConfig,
    capture: Capture,
    loopback: Sender<Command>,
    on_devices: Box<dyn Fn(DeviceSnapshot) + Send>,
    session: Option<Uuid>,
    original_input: Option<DeviceId>,
    muted_output: Option<OutputState>,
    restore_generation: Option<(Uuid, OutputState)>,
    active_device: Option<DeviceId>,
    deferred_restart: bool,
    pending: HashSet<EnvironmentChange>,
    flush_token: u64,
    started_at: Option<Instant>,
}

impl Actor {
    fn run(mut self, commands: Receiver<Command>) {
        (self.on_devices)(devices::snapshot());
        self.schedule_settle_snapshot();
        for command in commands {
            match command {
                Command::Configure(config) => self.config = config,
                Command::WarmUp => self.warm_up(),
                Command::Start { reply } => {
                    let result = self.start();
                    let started = result.is_ok();
                    let _ = reply.send(result);
                    // Muting goes through AppleScript (~50-200 ms), so it runs
                    // after the caller is told capture began.
                    if started && self.config.audio_behavior == RecordingAudioBehavior::Mute {
                        self.mute_output();
                        if let Some(session) = self.session {
                            // Bluetooth profile switches can unmute; re-assert briefly.
                            for delay in [250, 500] {
                                self.after(
                                    Duration::from_millis(delay),
                                    Command::ReapplyMute(session),
                                );
                            }
                        }
                    }
                }
                Command::Stop { reply } => {
                    let _ = reply.send(self.stop());
                }
                Command::SetStreaming(enabled) => {
                    self.capture
                        .streaming
                        .store(enabled, std::sync::atomic::Ordering::Relaxed);
                }
                Command::Environment(change) => {
                    self.pending.insert(change);
                    self.flush_token += 1;
                    self.after(
                        Duration::from_millis(350),
                        Command::FlushEnvironment(self.flush_token),
                    );
                }
                Command::FlushEnvironment(token) => {
                    if token == self.flush_token {
                        let changes = std::mem::take(&mut self.pending);
                        self.handle_environment(&changes);
                    }
                }
                Command::RetryRestore {
                    generation,
                    attempt,
                } => self.retry_restore(generation, attempt),
                Command::ReapplyMute(session) => {
                    if self.session == Some(session) && self.muted_output.is_some() {
                        run_script("set volume output muted true");
                    }
                }
                Command::Cleanup { reply } => {
                    self.session = None;
                    self.restore_audio_state();
                    self.restore_generation = None;
                    self.capture.stop("cleanup");
                    let _ = reply.send(());
                    return;
                }
            }
        }
    }

    fn after(&self, delay: Duration, command: Command) {
        let loopback = self.loopback.clone();
        std::thread::spawn(move || {
            std::thread::sleep(delay);
            let _ = loopback.send(command);
        });
    }

    fn schedule_settle_snapshot(&self) {
        // One delayed re-publish lets Bluetooth/USB names settle.
        let loopback = self.loopback.clone();
        std::thread::spawn(move || {
            std::thread::sleep(Duration::from_secs(2));
            let _ = loopback.send(Command::Environment(EnvironmentChange::Hardware(
                HardwareChange::Devices,
            )));
        });
    }

    fn apply_preferred_input(&mut self) -> Option<DeviceId> {
        let target = devices::resolve_preferred(self.config.microphone.as_deref());
        let current = devices::default_input();
        if self.original_input.is_none() {
            self.original_input = current;
        }
        if let Some(target) = target {
            if Some(target) != current {
                tracing::info!(target: "recording", "switching input {} → {}", devices::describe(current), devices::describe(Some(target)));
                devices::set_default_input(target);
            }
        }
        devices::default_input()
    }

    /// Guards against a default input that lost its input streams (the
    /// "mic selected but nothing heard" failure) by hunting a live one.
    fn ensure_live_input(&mut self) -> Option<DeviceId> {
        if let Some(current) = devices::default_input().filter(|device| devices::has_input(*device))
        {
            return Some(current);
        }
        tracing::error!(target: "recording", "default input has no live input streams; hunting a fallback");
        let candidates = devices::built_in_input()
            .into_iter()
            .chain(devices::all_devices());
        for device in candidates {
            if devices::has_input(device) && devices::set_default_input(device) {
                return devices::default_input();
            }
        }
        devices::default_input()
    }

    fn ensure_capture_ready(
        &mut self,
        device: Option<DeviceId>,
        reason: &str,
    ) -> Result<(), String> {
        let live_default = devices::default_input();
        if self.active_device != device
            || self.active_device != live_default
            || !self.capture.is_running()
        {
            self.capture
                .stop(&format!("device or engine changed ({reason})"));
        }
        self.capture
            .start(reason)
            .map_err(|error| error.to_string())?;
        self.active_device = device;
        Ok(())
    }

    fn warm_up(&mut self) {
        let device = self.apply_preferred_input();
        if self.config.super_fast {
            if let Err(error) = self.ensure_capture_ready(device, "warm-up") {
                tracing::error!(target: "recording", "failed to arm capture: {error}");
            }
        } else if self.session.is_none() {
            self.capture.stop("warm-up standard");
            self.active_device = None;
        }
    }

    fn start(&mut self) -> Result<(), String> {
        if self.session.is_some() {
            tracing::warn!(target: "recording", "start ignored: a recording session is already active");
            return Ok(());
        }
        let requested_at = Instant::now();
        for device in devices::resolve_preferred(self.config.microphone.as_deref())
            .into_iter()
            .chain(devices::default_input())
        {
            devices::ensure_unmuted(device);
        }
        self.restore_generation = None;
        let session = Uuid::new_v4();
        self.session = Some(session);
        self.apply_preferred_input();
        let device = self.ensure_live_input();
        tracing::info!(
            target: "recording",
            "recording requested mode={} input={}",
            if self.config.super_fast { "super-fast" } else { "standard" },
            devices::describe(device)
        );
        let path = std::env::temp_dir().join(format!("tick-recording-{}.wav", Uuid::new_v4()));
        let result = self.ensure_capture_ready(device, "start").and_then(|()| {
            self.capture
                .begin(path, requested_at)
                .map_err(|error| error.to_string())
        });
        if let Err(error) = result {
            tracing::error!(target: "recording", "failed to start capture: {error}");
            self.session = None;
            self.restore_audio_state();
            return Err(error);
        }
        self.started_at = Some(Instant::now());
        tracing::info!(target: "recording", "recording started in {:.3}s", requested_at.elapsed().as_secs_f32());
        Ok(())
    }

    fn stop(&mut self) -> Option<PathBuf> {
        let path = self.capture.finish();
        let duration = self.started_at.take().map(|at| at.elapsed().as_secs_f32());
        self.session = None;
        tracing::info!(target: "recording", "recording stopped after {:?}s", duration);
        if !self.config.super_fast {
            self.capture.stop("standard stop");
            self.active_device = None;
        }
        if self.deferred_restart {
            self.deferred_restart = false;
            let mut changes = HashSet::new();
            changes.insert(EnvironmentChange::Hardware(HardwareChange::DefaultInput));
            self.handle_environment(&changes);
        }
        self.restore_audio_state();
        path
    }

    fn handle_environment(&mut self, changes: &HashSet<EnvironmentChange>) {
        if changes.is_empty() {
            return;
        }
        let affects_input = changes.iter().any(EnvironmentChange::affects_input);
        if affects_input {
            (self.on_devices)(devices::snapshot());
        }
        if self.muted_output.is_some() {
            run_script("set volume output muted true");
        }
        if !affects_input {
            return;
        }
        let desired = devices::resolve_preferred(self.config.microphone.as_deref());
        let needs_restart =
            desired != self.active_device || (self.config.super_fast && !self.capture.is_running());
        tracing::info!(target: "recording", "audio environment changed {changes:?}; restart={needs_restart}");
        if !needs_restart {
            return;
        }
        if self.capture.is_recording() {
            self.deferred_restart = true;
            return;
        }
        let device = self.apply_preferred_input();
        if self.config.super_fast {
            if let Err(error) = self.ensure_capture_ready(device, "environment change") {
                tracing::error!(target: "recording", "failed to re-arm capture: {error}");
            }
        } else {
            self.capture.stop("environment change");
            self.active_device = None;
        }
    }

    fn mute_output(&mut self) {
        if self.muted_output.is_some() {
            return;
        }
        let Some(original) = read_output_state() else {
            tracing::error!(target: "media", "unable to read the system output state");
            return;
        };
        // Keep the volume; macOS carries the mute flag across routes, while
        // forcing volume to zero can persist through Bluetooth profile changes.
        if run_script("set volume output muted true") {
            self.muted_output = Some(original);
        }
    }

    fn restore_audio_state(&mut self) {
        if let Some(original) = self.original_input.take() {
            // An explicit microphone choice stays selected after recording.
            if self.config.microphone.is_none() && devices::default_input() != Some(original) {
                devices::set_default_input(original);
            }
        }
        if let Some(original) = self.muted_output.take() {
            // Restore at once, then re-apply while Bluetooth routes settle;
            // a newer recording session cancels the retries.
            apply_output_state(original);
            let generation = Uuid::new_v4();
            self.restore_generation = Some((generation, original));
            self.schedule_restore(generation, 0);
        }
    }

    fn schedule_restore(&self, generation: Uuid, attempt: usize) {
        const DELAYS: [u64; 4] = [300, 700, 1400, 2400];
        if let Some(delay) = DELAYS.get(attempt) {
            self.after(
                Duration::from_millis(*delay),
                Command::RetryRestore {
                    generation,
                    attempt,
                },
            );
        }
    }

    fn retry_restore(&mut self, generation: Uuid, attempt: usize) {
        let Some((current, original)) = self.restore_generation else {
            return;
        };
        if current != generation || self.session.is_some() {
            return;
        }
        apply_output_state(original);
        if attempt + 1 < 4 {
            self.schedule_restore(generation, attempt + 1);
        } else {
            self.restore_generation = None;
        }
    }
}

fn run_script(source: &str) -> bool {
    match workspace::run_apple_script(source) {
        Ok(_) => true,
        Err(error) => {
            tracing::error!(target: "media", "output command failed: {error}");
            false
        }
    }
}

fn read_output_state() -> Option<OutputState> {
    let source = "set s to get volume settings\nreturn ((output volume of s) as text) & \",\" & ((output muted of s) as text)";
    let value = workspace::run_apple_script(source).ok()??;
    let (volume, muted) = value.split_once(',')?;
    Some(OutputState {
        volume: volume.trim().parse().ok()?,
        muted: muted.trim().eq_ignore_ascii_case("true"),
    })
}

fn apply_output_state(state: OutputState) {
    let clause = if state.muted {
        "with output muted"
    } else {
        "without output muted"
    };
    if run_script(&format!(
        "set volume output volume {} {clause}",
        state.volume
    )) {
        tracing::info!(target: "media", "restored output volume={} muted={}", state.volume, state.muted);
    }
}
