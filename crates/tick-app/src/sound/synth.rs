//! Offline renderer for Cuelume recipes, matching its Web Audio graph:
//! sine/filtered-noise layers with linear swells and exponential decays, a
//! faint stereo convolution room, a 40 Hz high-pass, and a soft clip.

use std::f32::consts::{LN_10, PI};
use std::sync::OnceLock;

use rustfft::num_complex::Complex32;
use rustfft::FftPlanner;

use super::recipes::{Emphasis, Filter, Layer, Recipe, Source};

const SOURCE_STOP_PADDING: f32 = 0.05;
const RELEASE_GAP: f32 = 0.09;
const DECAY_JITTER: f32 = 0.1;
const MODE_JITTER: f32 = 0.005;
const BRIGHT_HZ: f32 = 2500.0;
const OUTPUT_GAIN: f32 = 5.8;
const CLIP_KNEE: f32 = 0.7;
const ROOM_SEND: f32 = 0.08;
const ROOM_SECONDS: f32 = 0.25;
const ROOM_PREDELAY: f32 = 0.008;
const ROOM_LOWPASS: f32 = 3500.0;
const ROOM_SEEDS: [u32; 2] = [3110, 5639];
const NOISE_SECONDS: f32 = 2.0;
const FAST_MS: f32 = 70.0;
const SLOW_MS: f32 = 220.0;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Part {
    Press,
    Release,
    Both,
}

#[derive(Debug, Clone, Copy)]
struct Shape {
    pitch: f32,
    level: f32,
    length: f32,
    bright: f32,
    tail: f32,
}

impl Shape {
    fn new(emphasis: Emphasis, since_last_ms: Option<f32>) -> Shape {
        let mut shape = Shape { pitch: 1.0, level: 1.0, length: 1.0, bright: 1.0, tail: 1.0 };
        match emphasis {
            Emphasis::Subtle => {
                shape.level *= 0.8;
                shape.length *= 0.85;
                shape.bright *= 0.75;
            }
            Emphasis::Normal => {}
            Emphasis::Strong => {
                shape.pitch *= 0.98;
                shape.level *= 1.08;
                shape.length *= 1.2;
                shape.bright *= 1.1;
            }
        }
        if let Some(since) = since_last_ms {
            let speed = ((SLOW_MS - since) / (SLOW_MS - FAST_MS)).clamp(0.0, 1.0);
            shape.level *= 1.0 - 0.22 * speed;
            shape.length *= 1.0 - 0.25 * speed;
            shape.bright *= 1.0 - 0.2 * speed;
            shape.tail *= 1.0 - 0.8 * speed;
        }
        shape
    }
}

/// Mulberry32-style generator used by Cuelume for noise and rooms.
fn seeded(seed: u32) -> impl FnMut() -> f32 {
    let mut state = seed;
    move || {
        state = state.wrapping_add(0x6d2b_79f5);
        let mut mixed = (state ^ (state >> 15)).wrapping_mul(1 | state);
        mixed = mixed.wrapping_add((mixed ^ (mixed >> 7)).wrapping_mul(61 | mixed)) ^ mixed;
        ((mixed ^ (mixed >> 14)) as f64 / 4_294_967_296.0) as f32
    }
}

fn nudge(amount: f32) -> f32 {
    1.0 + (fastrand_f32() * 2.0 - 1.0) * amount
}

fn fastrand_f32() -> f32 {
    use std::cell::Cell;
    thread_local!(static STATE: Cell<u64> = Cell::new(
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_or(0x9e37, |d| d.as_nanos() as u64) | 1
    ));
    STATE.with(|state| {
        let mut x = state.get();
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        state.set(x);
        (x >> 40) as f32 / (1u64 << 24) as f32
    })
}

/// Web Audio BiquadFilterNode (lowpass Q in dB, bandpass Q linear).
#[derive(Default)]
struct Biquad {
    b0: f32,
    b1: f32,
    b2: f32,
    a1: f32,
    a2: f32,
    x1: f32,
    x2: f32,
    y1: f32,
    y2: f32,
}

#[derive(Clone, Copy)]
enum Kind {
    Lowpass,
    Highpass,
    Bandpass,
}

impl Biquad {
    fn set(&mut self, kind: Kind, frequency: f32, q: f32, rate: f32) {
        let w0 = 2.0 * PI * (frequency / rate).clamp(1e-5, 0.4999);
        let (sin, cos) = w0.sin_cos();
        let (b0, b1, b2, a0, a1, a2) = match kind {
            Kind::Lowpass | Kind::Highpass => {
                let alpha = sin / (2.0 * 10f32.powf(q / 20.0));
                let (b0, b1) = match kind {
                    Kind::Lowpass => ((1.0 - cos) / 2.0, 1.0 - cos),
                    _ => ((1.0 + cos) / 2.0, -(1.0 + cos)),
                };
                (b0, b1, b0, 1.0 + alpha, -2.0 * cos, 1.0 - alpha)
            }
            Kind::Bandpass => {
                let alpha = sin / (2.0 * q.max(1e-4));
                (alpha, 0.0, -alpha, 1.0 + alpha, -2.0 * cos, 1.0 - alpha)
            }
        };
        self.b0 = b0 / a0;
        self.b1 = b1 / a0;
        self.b2 = b2 / a0;
        self.a1 = a1 / a0;
        self.a2 = a2 / a0;
    }

    fn process(&mut self, x: f32) -> f32 {
        let y = self.b0 * x + self.b1 * self.x1 + self.b2 * self.x2 - self.a1 * self.y1 - self.a2 * self.y2;
        self.x2 = self.x1;
        self.x1 = x;
        self.y2 = self.y1;
        self.y1 = y;
        y
    }
}

fn noise_buffer(rate: f32) -> &'static Vec<f32> {
    static NOISE: OnceLock<Vec<f32>> = OnceLock::new();
    NOISE.get_or_init(|| {
        let mut random = seeded(1);
        (0..(NOISE_SECONDS * rate) as usize).map(|_| 2.0 * random() - 1.0).collect()
    })
}

/// Exponential glide value at `t` seconds after the start.
fn glided(from: f32, to: Option<f32>, time: f32, t: f32) -> f32 {
    match to {
        Some(to) if time > 0.0 && from > 0.0 && to > 0.0 => {
            if t >= time { to } else { from * (to / from).powf(t / time) }
        }
        _ => from,
    }
}

fn envelope(layer: &Layer, t: f32) -> f32 {
    if t < 0.0 {
        return 0.0;
    }
    if t < layer.attack {
        return layer.peak * (t / layer.attack.max(1e-6));
    }
    let tau = layer.decay / (3.0 * LN_10);
    layer.peak * (-(t - layer.attack) / tau.max(1e-6)).exp()
}

struct Shaped {
    layer: Layer,
    offset: f32,
}

fn shaped(layer: &Layer, shape: Shape, strike: (f32, f32), vary: bool, walk: f32) -> Layer {
    let frequency = layer.frequency;
    let gain = shape.level * if frequency >= BRIGHT_HZ { shape.bright } else { 1.0 };
    let pitch_factor = shape.pitch.clamp(0.75, 1.25);
    let gain = gain.clamp(0.0, 1.5);
    let length = shape.length.clamp(0.6, 1.6);
    let tune = match layer.source {
        Source::Tone => if vary { nudge(MODE_JITTER) } else { 1.0 },
        Source::Noise { .. } => strike.1,
    };
    let pitch = pitch_factor * strike.0 * tune * if layer.note { walk } else { 1.0 };
    let mut bent = *layer;
    bent.peak = layer.peak * gain * strike.1;
    bent.decay = layer.decay * length * if vary { nudge(DECAY_JITTER) } else { 1.0 };
    bent.frequency = frequency * pitch;
    bent.glide_to = layer.glide_to.map(|to| to * pitch);
    bent
}

fn render_layer(layer: &Layer, offset: f32, rate: f32, out: &mut [f32]) {
    let start = (offset * rate) as usize;
    let length = ((layer.attack + layer.decay + SOURCE_STOP_PADDING) * rate) as usize;
    let glide_time = layer.glide_time.unwrap_or(layer.attack + layer.decay);
    match layer.source {
        Source::Tone => {
            let mut phase = 0.0f32;
            for i in 0..length {
                let Some(slot) = out.get_mut(start + i) else { break };
                let t = i as f32 / rate;
                let frequency = glided(layer.frequency, layer.glide_to, glide_time, t);
                *slot += phase.sin() * envelope(layer, t);
                phase = (phase + 2.0 * PI * frequency / rate) % (2.0 * PI);
            }
        }
        Source::Noise { filter, q } => {
            let noise = noise_buffer(rate);
            let mut position = (fastrand_f32() * noise.len() as f32) as usize;
            let kind = match filter {
                Filter::Lowpass => Kind::Lowpass,
                Filter::Bandpass => Kind::Bandpass,
            };
            let mut biquad = Biquad::default();
            for i in 0..length {
                let Some(slot) = out.get_mut(start + i) else { break };
                if i % 16 == 0 {
                    let t = i as f32 / rate;
                    biquad.set(kind, glided(layer.frequency, layer.glide_to, glide_time, t), q, rate);
                }
                position = (position + 1) % noise.len();
                *slot += biquad.process(noise[position]) * envelope(layer, i as f32 / rate);
            }
        }
    }
}

fn room_impulse(rate: f32, seed: u32) -> Vec<f32> {
    const REFLECTIONS_PER_SECOND: f32 = 48_000.0;
    let mut random = seeded(seed);
    let fall = (60.0 / 20.0) * LN_10;
    let reflections: Vec<f32> = (0..(ROOM_SECONDS * REFLECTIONS_PER_SECOND) as usize)
        .map(|i| {
            let t = i as f32 / REFLECTIONS_PER_SECOND;
            let value = 2.0 * random() - 1.0;
            if t < ROOM_PREDELAY { 0.0 } else { value * (-fall * t / ROOM_SECONDS).exp() }
        })
        .collect();
    let scale = 1.0 / reflections.iter().map(|r| r * r).sum::<f32>().sqrt();
    let mut data = vec![0.0; (ROOM_SECONDS * rate) as usize];
    for (i, reflection) in reflections.iter().enumerate() {
        let at = i as f32 / REFLECTIONS_PER_SECOND * rate;
        let sample = at as usize;
        let late = at - sample as f32;
        if let Some(slot) = data.get_mut(sample) {
            *slot += reflection * scale * (1.0 - late);
        }
        if let Some(slot) = data.get_mut(sample + 1) {
            *slot += reflection * scale * late;
        }
    }
    data
}

fn convolve(signal: &[f32], impulse: &[f32]) -> Vec<f32> {
    let size = (signal.len() + impulse.len()).next_power_of_two();
    let mut planner = FftPlanner::<f32>::new();
    let forward = planner.plan_fft_forward(size);
    let inverse = planner.plan_fft_inverse(size);
    let mut a: Vec<Complex32> = signal.iter().map(|x| Complex32::new(*x, 0.0)).collect();
    a.resize(size, Complex32::default());
    let mut b: Vec<Complex32> = impulse.iter().map(|x| Complex32::new(*x, 0.0)).collect();
    b.resize(size, Complex32::default());
    forward.process(&mut a);
    forward.process(&mut b);
    for (x, y) in a.iter_mut().zip(&b) {
        *x *= y;
    }
    inverse.process(&mut a);
    let norm = 1.0 / size as f32;
    a.iter().take(signal.len() + impulse.len() - 1).map(|c| c.re * norm).collect()
}

fn soft_clip(level: f32) -> f32 {
    let over = level.abs() - CLIP_KNEE;
    if over <= 0.0 {
        return level;
    }
    let shoulder = 1.0 - CLIP_KNEE;
    level.signum() * (CLIP_KNEE + over - over * over / (2.0 * shoulder))
}

pub struct Play<'a> {
    pub recipe: &'a Recipe,
    pub part: Part,
    pub emphasis: Emphasis,
    /// 0…1 user volume.
    pub volume: f32,
    pub since_last_ms: Option<f32>,
    pub walk_step: usize,
}

/// Renders one play to interleaved stereo at `rate`.
pub fn render(play: &Play<'_>, rate: f32) -> Vec<f32> {
    let recipe = play.recipe;
    let shape = Shape::new(play.emphasis, play.since_last_ms);
    let vary = recipe.vary.is_some();
    let strike = recipe.vary.map_or((1.0, 1.0), |(pitch, level)| (nudge(pitch), nudge(level)));
    let walk = 2f32.powf(recipe.walk.get(play.walk_step).copied().unwrap_or(0.0) / 12.0);
    let mut parts: Vec<(&[Layer], f32)> = Vec::new();
    if play.part != Part::Release {
        parts.push((&recipe.layers, 0.0));
    }
    if play.part != Part::Press && !recipe.release.is_empty() {
        parts.push((&recipe.release, if play.part == Part::Both { RELEASE_GAP } else { 0.0 }));
    }
    let layers: Vec<Shaped> = parts
        .iter()
        .flat_map(|(layers, delay)| {
            layers
                .iter()
                .filter(|layer| play.emphasis >= layer.from)
                .map(move |layer| Shaped { layer: shaped(layer, shape, strike, vary, walk), offset: *delay })
        })
        .collect();
    if layers.is_empty() {
        return Vec::new();
    }
    let end = layers
        .iter()
        .map(|s| s.offset + s.layer.attack + s.layer.decay + SOURCE_STOP_PADDING)
        .fold(0.0f32, f32::max);
    let mut dry = vec![0.0f32; ((end + ROOM_SECONDS) * rate) as usize + 1];
    for shaped in &layers {
        render_layer(&shaped.layer, shaped.offset, rate, &mut dry);
    }
    let master = recipe.master_gain * play.volume;
    for sample in &mut dry {
        *sample *= master;
    }

    // Room: low-passed send into two independent impulse channels.
    let mut walls = Biquad::default();
    walls.set(Kind::Lowpass, ROOM_LOWPASS, -3.0, rate);
    let send_gain = ROOM_SEND * recipe.room;
    let send: Vec<f32> = dry.iter().map(|x| walls.process(x * send_gain)).collect();
    let rooms: Vec<Vec<f32>> = ROOM_SEEDS.iter().map(|seed| convolve(&send, &room_impulse(rate, *seed))).collect();

    let mut highpass = [Biquad::default(), Biquad::default()];
    for filter in &mut highpass {
        filter.set(Kind::Highpass, 40.0, -3.0, rate);
    }
    let mut out = Vec::with_capacity(dry.len() * 2);
    for (i, sample) in dry.iter().enumerate() {
        for (channel, filter) in highpass.iter_mut().enumerate() {
            let wet = rooms[channel].get(i).copied().unwrap_or(0.0);
            out.push(soft_clip(filter.process((sample + wet) * OUTPUT_GAIN)));
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::sound::recipes::Cue;

    #[test]
    fn every_cue_renders_bounded_audio() {
        for cue in [Cue::Talk, Cue::Lock, Cue::Tap, Cue::Toggle, Cue::Success, Cue::Error, Cue::Close, Cue::Ready] {
            let recipe = cue.recipe();
            let audio = render(
                &Play { recipe: &recipe, part: Part::Press, emphasis: Emphasis::Normal, volume: 1.0, since_last_ms: None, walk_step: 0 },
                48_000.0,
            );
            assert!(!audio.is_empty(), "{cue:?} rendered nothing");
            let peak = audio.iter().fold(0.0f32, |m, x| m.max(x.abs()));
            assert!(peak > 0.001 && peak <= 1.0, "{cue:?} peak {peak}");
        }
    }

    #[test]
    fn release_half_differs_from_press() {
        let recipe = Cue::Talk.recipe();
        let play = |part| render(&Play { recipe: &recipe, part, emphasis: Emphasis::Normal, volume: 1.0, since_last_ms: None, walk_step: 0 }, 48_000.0);
        assert!(play(Part::Release).len() < play(Part::Press).len());
    }
}
