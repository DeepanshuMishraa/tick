//! Microphone capture: one CoreAudio input stream (via cpal), converted to
//! 16 kHz mono Float32, kept in a 1 s ring buffer for pre-roll, and written
//! to a WAV file while a recording is active. Streaming ASR receives the
//! same samples as the file.

use std::fs::File;
use std::io::BufWriter;
use std::path::PathBuf;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::time::Instant;

use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use crossbeam_channel::{Receiver, Sender};
use parking_lot::Mutex;
use rubato::{FftFixedInOut, Resampler};

pub const SAMPLE_RATE: u32 = 16_000;
const RING_SECONDS: f32 = 1.0;
const PRE_ROLL_SECONDS: f32 = 0.45;

#[derive(Debug, Clone, Copy, Default, PartialEq)]
pub struct Meter {
    /// RMS of the latest buffer, 0…1.
    pub average: f32,
    pub peak: f32,
}

#[derive(Debug, thiserror::Error)]
pub enum CaptureError {
    #[error("No microphone is available. Connect one or choose another input in Settings.")]
    NoInputDevice,
    #[error("The microphone could not be opened: {0}")]
    Stream(String),
    #[error("The recording file could not be created at {path}: {reason}")]
    File { path: PathBuf, reason: String },
}

enum Job {
    Samples {
        generation: u64,
        rate: u32,
        channels: u16,
        data: Vec<f32>,
    },
    Begin {
        path: PathBuf,
        requested_at: Instant,
        reply: Sender<Result<(), CaptureError>>,
    },
    Finish {
        reply: Sender<Option<PathBuf>>,
    },
    Reset,
}

struct Recording {
    path: PathBuf,
    writer: hound::WavWriter<BufWriter<File>>,
    requested_at: Instant,
    logged_first_buffer: bool,
}

struct Converter {
    rate: u32,
    resampler: Option<FftFixedInOut<f32>>,
    pending: Vec<f32>,
}

impl Converter {
    fn new(rate: u32) -> Converter {
        let resampler = (rate != SAMPLE_RATE)
            .then(|| FftFixedInOut::<f32>::new(rate as usize, SAMPLE_RATE as usize, 1024, 1).ok())
            .flatten();
        Converter {
            rate,
            resampler,
            pending: Vec::new(),
        }
    }

    fn push(&mut self, mono: &[f32], out: &mut Vec<f32>) {
        let Some(resampler) = self.resampler.as_mut() else {
            out.extend_from_slice(mono);
            return;
        };
        self.pending.extend_from_slice(mono);
        loop {
            let needed = resampler.input_frames_next();
            if self.pending.len() < needed {
                break;
            }
            let chunk: Vec<f32> = self.pending.drain(..needed).collect();
            if let Ok(result) = resampler.process(&[chunk], None) {
                if let Some(channel) = result.into_iter().next() {
                    out.extend(channel);
                }
            }
        }
    }
}

/// Owns the processing thread; samples arrive from the realtime callback.
struct Processor {
    ring: Vec<f32>,
    write: usize,
    valid: usize,
    converter: Option<Converter>,
    recording: Option<Recording>,
    meter: Arc<Mutex<Meter>>,
    streaming: Arc<AtomicBool>,
    generation: Arc<AtomicU64>,
}

impl Processor {
    fn run(mut self, jobs: Receiver<Job>) {
        for job in jobs {
            match job {
                Job::Samples {
                    generation,
                    rate,
                    channels,
                    data,
                } => {
                    if generation == self.generation.load(Ordering::Acquire) {
                        self.process(rate, channels, &data);
                    }
                }
                Job::Begin {
                    path,
                    requested_at,
                    reply,
                } => {
                    let _ = reply.send(self.begin(path, requested_at));
                }
                Job::Finish { reply } => {
                    let path = self.recording.take().and_then(|recording| {
                        let path = recording.path.clone();
                        match recording.writer.finalize() {
                            Ok(()) => Some(path),
                            Err(error) => {
                                tracing::error!(target: "recording", "failed to finalize recording: {error}");
                                Some(path)
                            }
                        }
                    });
                    self.clear_ring();
                    let _ = reply.send(path);
                }
                Job::Reset => {
                    self.recording = None;
                    self.converter = None;
                    self.clear_ring();
                }
            }
        }
    }

    fn clear_ring(&mut self) {
        self.write = 0;
        self.valid = 0;
    }

    fn recent(&self, count: usize) -> Vec<f32> {
        let count = count.min(self.valid);
        let len = self.ring.len();
        let start = (self.write + len - count) % len;
        (0..count).map(|i| self.ring[(start + i) % len]).collect()
    }

    fn begin(&mut self, path: PathBuf, requested_at: Instant) -> Result<(), CaptureError> {
        let spec = hound::WavSpec {
            channels: 1,
            sample_rate: SAMPLE_RATE,
            bits_per_sample: 32,
            sample_format: hound::SampleFormat::Float,
        };
        let mut writer =
            hound::WavWriter::create(&path, spec).map_err(|error| CaptureError::File {
                path: path.clone(),
                reason: error.to_string(),
            })?;
        let pre_roll = self.recent((PRE_ROLL_SECONDS * SAMPLE_RATE as f32) as usize);
        for sample in &pre_roll {
            let _ = writer.write_sample(*sample);
        }
        // The stream gets the same audio as the file, pre-roll included.
        if self.streaming.load(Ordering::Relaxed) {
            crate::speech::push(&pre_roll);
        }
        tracing::info!(target: "recording", "recording file opened, pre-roll {:.3}s", pre_roll.len() as f32 / SAMPLE_RATE as f32);
        self.recording = Some(Recording {
            path,
            writer,
            requested_at,
            logged_first_buffer: false,
        });
        Ok(())
    }

    fn process(&mut self, rate: u32, channels: u16, data: &[f32]) {
        let channels = usize::from(channels.max(1));
        let mono: Vec<f32> = data
            .chunks(channels)
            .map(|frame| frame.iter().sum::<f32>() / frame.len() as f32)
            .collect();
        if self.converter.as_ref().is_none_or(|c| c.rate != rate) {
            self.converter = Some(Converter::new(rate));
        }
        let mut converted = Vec::with_capacity(mono.len() / 2);
        if let Some(converter) = self.converter.as_mut() {
            converter.push(&mono, &mut converted);
        }
        if converted.is_empty() {
            return;
        }
        let len = self.ring.len();
        for sample in &converted {
            self.ring[self.write] = *sample;
            self.write = (self.write + 1) % len;
        }
        self.valid = (self.valid + converted.len()).min(len);

        let Some(recording) = self.recording.as_mut() else {
            return;
        };
        let (mut sum, mut peak) = (0.0f32, 0.0f32);
        for sample in &converted {
            sum += sample * sample;
            peak = peak.max(sample.abs());
        }
        *self.meter.lock() = Meter {
            average: (sum / converted.len() as f32).sqrt(),
            peak,
        };
        if self.streaming.load(Ordering::Relaxed) {
            crate::speech::push(&converted);
        }
        if !recording.logged_first_buffer {
            recording.logged_first_buffer = true;
            tracing::info!(target: "recording", "first buffer latency {:.3}s", recording.requested_at.elapsed().as_secs_f32());
        }
        for sample in &converted {
            if let Err(error) = recording.writer.write_sample(*sample) {
                tracing::error!(target: "recording", "failed to write audio: {error}");
                self.recording = None;
                return;
            }
        }
    }
}

/// The armed input stream and its processing pipeline. Not `Send`: lives on
/// the recorder's control thread.
pub struct Capture {
    stream: Option<cpal::Stream>,
    jobs: Sender<Job>,
    generation: Arc<AtomicU64>,
    pub meter: Arc<Mutex<Meter>>,
    pub streaming: Arc<AtomicBool>,
    recording: bool,
}

impl Capture {
    pub fn new() -> Capture {
        let (jobs, receiver) = crossbeam_channel::unbounded();
        let meter = Arc::new(Mutex::new(Meter::default()));
        let streaming = Arc::new(AtomicBool::new(false));
        let generation = Arc::new(AtomicU64::new(0));
        let processor = Processor {
            ring: vec![0.0; (RING_SECONDS * SAMPLE_RATE as f32) as usize],
            write: 0,
            valid: 0,
            converter: None,
            recording: None,
            meter: meter.clone(),
            streaming: streaming.clone(),
            generation: generation.clone(),
        };
        std::thread::Builder::new()
            .name("tick-capture".into())
            .spawn(move || processor.run(receiver))
            .expect("spawning the capture thread");
        Capture {
            stream: None,
            jobs,
            generation,
            meter,
            streaming,
            recording: false,
        }
    }

    pub fn is_running(&self) -> bool {
        self.stream.is_some()
    }

    pub fn is_recording(&self) -> bool {
        self.recording
    }

    /// Opens the system default input if it is not already running.
    pub fn start(&mut self, reason: &str) -> Result<(), CaptureError> {
        if self.stream.is_some() {
            return Ok(());
        }
        let host = cpal::default_host();
        let device = host
            .default_input_device()
            .ok_or(CaptureError::NoInputDevice)?;
        let config = device
            .default_input_config()
            .map_err(|error| CaptureError::Stream(error.to_string()))?;
        let rate = config.sample_rate().0;
        let channels = config.channels();
        let generation = self.generation.fetch_add(1, Ordering::AcqRel) + 1;
        let jobs = self.jobs.clone();
        let on_error = |error: cpal::StreamError| tracing::error!(target: "recording", "input stream error: {error}");
        let stream = match config.sample_format() {
            cpal::SampleFormat::F32 => device.build_input_stream(
                &config.into(),
                move |data: &[f32], _: &cpal::InputCallbackInfo| {
                    let _ = jobs.send(Job::Samples {
                        generation,
                        rate,
                        channels,
                        data: data.to_vec(),
                    });
                },
                on_error,
                None,
            ),
            cpal::SampleFormat::I16 => device.build_input_stream(
                &config.into(),
                move |data: &[i16], _: &cpal::InputCallbackInfo| {
                    let data = data
                        .iter()
                        .map(|s| f32::from(*s) / f32::from(i16::MAX))
                        .collect();
                    let _ = jobs.send(Job::Samples {
                        generation,
                        rate,
                        channels,
                        data,
                    });
                },
                on_error,
                None,
            ),
            other => {
                return Err(CaptureError::Stream(format!(
                    "unsupported sample format {other:?}"
                )));
            }
        }
        .map_err(|error| CaptureError::Stream(error.to_string()))?;
        stream
            .play()
            .map_err(|error| CaptureError::Stream(error.to_string()))?;
        tracing::info!(target: "recording", "capture armed ({reason}) at {rate} Hz × {channels}");
        self.stream = Some(stream);
        Ok(())
    }

    pub fn stop(&mut self, reason: &str) {
        if let Some(stream) = self.stream.take() {
            tracing::info!(target: "recording", "capture stopped ({reason})");
            drop(stream);
        }
        self.generation.fetch_add(1, Ordering::AcqRel);
        self.recording = false;
        let _ = self.jobs.send(Job::Reset);
    }

    pub fn begin(&mut self, path: PathBuf, requested_at: Instant) -> Result<(), CaptureError> {
        let (reply, response) = crossbeam_channel::bounded(1);
        let _ = self.jobs.send(Job::Begin {
            path,
            requested_at,
            reply,
        });
        let result = response
            .recv()
            .unwrap_or_else(|_| Err(CaptureError::Stream("capture thread stopped".into())));
        self.recording = result.is_ok();
        result
    }

    pub fn finish(&mut self) -> Option<PathBuf> {
        self.recording = false;
        *self.meter.lock() = Meter::default();
        let (reply, response) = crossbeam_channel::bounded(1);
        let _ = self.jobs.send(Job::Finish { reply });
        response.recv().ok().flatten()
    }
}
