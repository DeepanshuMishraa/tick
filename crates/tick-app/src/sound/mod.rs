//! Interaction sounds (Cuelume cues, synthesized in Rust) and recording
//! playback, mixed into one output stream.

mod recipes;
mod synth;

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::Arc;
use std::time::Instant;

use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use crossbeam_channel::Sender;
use parking_lot::Mutex;
use tick_core::constants::BASE_SOUND_EFFECTS_VOLUME;

pub use recipes::{Cue, Emphasis};
use synth::{Part, Play};

/// How long a cue's previous play fades when it plays again.
const HANDOFF_SECONDS: f32 = 0.08;
const NOTE_HANDOFF_SECONDS: f32 = 0.4;

struct Voice {
    owner: Option<Cue>,
    clip: Option<u64>,
    samples: Arc<Vec<f32>>,
    position: usize,
    gain: f32,
    fade_step: f32,
    finished: Option<Arc<AtomicBool>>,
}

#[derive(Default)]
struct Mixer {
    voices: Vec<Voice>,
}

impl Mixer {
    fn fill(&mut self, out: &mut [f32], channels: usize) {
        out.fill(0.0);
        for voice in &mut self.voices {
            for frame in out.chunks_mut(channels) {
                if voice.position + 1 >= voice.samples.len() || voice.gain <= 0.0 {
                    break;
                }
                let (left, right) = (voice.samples[voice.position], voice.samples[voice.position + 1]);
                voice.position += 2;
                if channels == 1 {
                    frame[0] += (left + right) * 0.5 * voice.gain;
                } else {
                    frame[0] += left * voice.gain;
                    frame[1] += right * voice.gain;
                }
                voice.gain -= voice.fade_step;
            }
        }
        self.voices.retain(|voice| {
            let done = voice.position + 1 >= voice.samples.len() || voice.gain <= 0.0;
            if done {
                if let Some(flag) = &voice.finished {
                    flag.store(true, Ordering::Release);
                }
            }
            !done
        });
    }
}

enum Job {
    Cue { cue: Cue, part: Part, emphasis: Emphasis },
    Clip { id: u64, path: PathBuf, finished: Arc<AtomicBool> },
}

/// A playing recording; `stop` silences it.
#[derive(Clone)]
pub struct ClipHandle {
    id: u64,
    finished: Arc<AtomicBool>,
    mixer: Arc<Mutex<Mixer>>,
}

impl ClipHandle {
    pub fn is_finished(&self) -> bool {
        self.finished.load(Ordering::Acquire)
    }

    pub fn stop(&self) {
        self.mixer.lock().voices.retain(|voice| voice.clip != Some(self.id));
        self.finished.store(true, Ordering::Release);
    }
}

#[derive(Clone)]
pub struct Sound {
    jobs: Sender<Job>,
    mixer: Arc<Mutex<Mixer>>,
    enabled: Arc<AtomicBool>,
    /// User volume as a 0…1 fraction, stored as f32 bits.
    volume: Arc<AtomicU32>,
    next_clip: Arc<AtomicU32>,
}

impl Sound {
    pub fn start() -> Sound {
        let mixer = Arc::new(Mutex::new(Mixer::default()));
        let enabled = Arc::new(AtomicBool::new(true));
        let volume = Arc::new(AtomicU32::new(1.0f32.to_bits()));
        let (jobs, receiver) = crossbeam_channel::unbounded::<Job>();
        let output_mixer = mixer.clone();
        let worker_volume = volume.clone();
        std::thread::Builder::new()
            .name("tick-sound".into())
            .spawn(move || {
                let Some((stream, rate)) = open_output(output_mixer.clone()) else {
                    tracing::error!(target: "sound", "no audio output device; sounds are disabled");
                    return;
                };
                let mut last_play: HashMap<Cue, Instant> = HashMap::new();
                let mut walk: HashMap<Cue, usize> = HashMap::new();
                for job in receiver {
                    match job {
                        Job::Cue { cue, part, emphasis } => {
                            let recipe = cue.recipe();
                            let now = Instant::now();
                            let since = last_play.get(&cue).map(|at| now.duration_since(*at).as_secs_f32() * 1000.0);
                            if part != Part::Release {
                                last_play.insert(cue, now);
                            }
                            let step = walk.entry(cue).or_default();
                            if since.is_some_and(|ms| ms < 400.0) && part != Part::Release {
                                *step = (*step + 1) % recipe.walk.len().max(1);
                            } else if part != Part::Release {
                                *step = 0;
                            }
                            let volume = f32::from_bits(worker_volume.load(Ordering::Relaxed));
                            let play = Play {
                                recipe: &recipe,
                                part,
                                emphasis,
                                volume,
                                since_last_ms: if cue.follows_cadence() { since } else { None },
                                walk_step: *step,
                            };
                            let samples = Arc::new(synth::render(&play, rate));
                            let mut mixer = output_mixer.lock();
                            if part != Part::Release {
                                let fade = if recipe.has_notes() { NOTE_HANDOFF_SECONDS } else { HANDOFF_SECONDS };
                                for voice in mixer.voices.iter_mut().filter(|v| v.owner == Some(cue)) {
                                    voice.fade_step = voice.gain / (fade * rate);
                                    voice.owner = None;
                                }
                            }
                            mixer.voices.push(Voice {
                                owner: (part != Part::Release).then_some(cue),
                                clip: None,
                                samples,
                                position: 0,
                                gain: 1.0,
                                fade_step: 0.0,
                                finished: None,
                            });
                        }
                        Job::Clip { id, path, finished } => match load_clip(&path, rate) {
                            Ok(samples) => output_mixer.lock().voices.push(Voice {
                                owner: None,
                                clip: Some(id),
                                samples: Arc::new(samples),
                                position: 0,
                                gain: 1.0,
                                fade_step: 0.0,
                                finished: Some(finished),
                            }),
                            Err(error) => {
                                tracing::error!(target: "history", "cannot play {}: {error}", path.display());
                                finished.store(true, Ordering::Release);
                            }
                        },
                    }
                }
                drop(stream);
            })
            .expect("spawning the sound thread");
        Sound { jobs, mixer, enabled, volume, next_clip: Arc::new(AtomicU32::new(1)) }
    }

    /// Applies the settings toggle and volume (stored relative to the 0.2 ceiling).
    pub fn configure(&self, enabled: bool, settings_volume: f64) {
        self.enabled.store(enabled, Ordering::Relaxed);
        let fraction = (settings_volume / BASE_SOUND_EFFECTS_VOLUME).clamp(0.0, 1.0) as f32;
        self.volume.store(fraction.to_bits(), Ordering::Relaxed);
    }

    fn send(&self, cue: Cue, part: Part, emphasis: Emphasis) {
        if self.enabled.load(Ordering::Relaxed) {
            let _ = self.jobs.send(Job::Cue { cue, part, emphasis });
        }
    }

    pub fn play(&self, cue: Cue) {
        self.send(cue, Part::Both, Emphasis::Normal);
    }

    /// The press half of a gesture that lets go later.
    pub fn press(&self, cue: Cue) {
        self.send(cue, Part::Press, Emphasis::Normal);
    }

    pub fn release(&self, cue: Cue) {
        self.send(cue, Part::Release, Emphasis::Normal);
    }

    /// Plays a recording regardless of the cue toggle.
    pub fn play_clip(&self, path: PathBuf) -> ClipHandle {
        let id = u64::from(self.next_clip.fetch_add(1, Ordering::Relaxed));
        let finished = Arc::new(AtomicBool::new(false));
        let _ = self.jobs.send(Job::Clip { id, path, finished: finished.clone() });
        ClipHandle { id, finished, mixer: self.mixer.clone() }
    }
}

fn open_output(mixer: Arc<Mutex<Mixer>>) -> Option<(cpal::Stream, f32)> {
    let device = cpal::default_host().default_output_device()?;
    let config = device.default_output_config().ok()?;
    let rate = config.sample_rate().0 as f32;
    let channels = usize::from(config.channels());
    if config.sample_format() != cpal::SampleFormat::F32 {
        tracing::error!(target: "sound", "unsupported output format {:?}", config.sample_format());
        return None;
    }
    let stream = device
        .build_output_stream(
            &config.into(),
            move |out: &mut [f32], _: &cpal::OutputCallbackInfo| match mixer.try_lock() {
                Some(mut mixer) => mixer.fill(out, channels),
                None => out.fill(0.0),
            },
            |error| tracing::error!(target: "sound", "output stream error: {error}"),
            None,
        )
        .ok()?;
    stream.play().ok()?;
    Some((stream, rate))
}

/// Reads a mono WAV and converts it to stereo at the output rate.
fn load_clip(path: &std::path::Path, rate: f32) -> Result<Vec<f32>, String> {
    let reader = hound::WavReader::open(path).map_err(|e| e.to_string())?;
    let spec = reader.spec();
    let channels = usize::from(spec.channels.max(1));
    let samples: Vec<f32> = match spec.sample_format {
        hound::SampleFormat::Float => reader.into_samples::<f32>().filter_map(Result::ok).collect(),
        hound::SampleFormat::Int => {
            let scale = (1i64 << (spec.bits_per_sample - 1)) as f32;
            reader.into_samples::<i32>().filter_map(Result::ok).map(|s| s as f32 / scale).collect()
        }
    };
    let mono: Vec<f32> = samples.chunks(channels).map(|f| f.iter().sum::<f32>() / f.len() as f32).collect();
    let ratio = spec.sample_rate as f32 / rate;
    let frames = (mono.len() as f32 / ratio) as usize;
    let mut out = Vec::with_capacity(frames * 2);
    for i in 0..frames {
        let at = i as f32 * ratio;
        let index = at as usize;
        let frac = at - index as f32;
        let a = mono.get(index).copied().unwrap_or(0.0);
        let b = mono.get(index + 1).copied().unwrap_or(a);
        let value = a + (b - a) * frac;
        out.push(value);
        out.push(value);
    }
    Ok(out)
}
