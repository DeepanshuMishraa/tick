//! Cue recipes ported from Cuelume 0.2.8 (MIT, © 2026 Daniel Belyi):
//! `sounds/layers.js`, `sounds/recipes.js` (default theme) and
//! `sounds/press.js` (press theme). Values are copied verbatim.

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum Emphasis {
    Subtle,
    Normal,
    Strong,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Filter {
    Lowpass,
    Bandpass,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Source {
    Tone,
    Noise { filter: Filter, q: f32 },
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Layer {
    pub source: Source,
    /// Tone frequency or filter frequency, Hz.
    pub frequency: f32,
    pub glide_to: Option<f32>,
    pub glide_time: Option<f32>,
    pub attack: f32,
    pub decay: f32,
    pub peak: f32,
    /// Lowest emphasis that plays this layer.
    pub from: Emphasis,
    /// A swelling note whose pitch follows a walk.
    pub note: bool,
}

impl Layer {
    const fn tone(frequency: f32, attack: f32, decay: f32, peak: f32) -> Layer {
        Layer {
            source: Source::Tone,
            frequency,
            glide_to: None,
            glide_time: None,
            attack,
            decay,
            peak,
            from: Emphasis::Subtle,
            note: false,
        }
    }

    const fn noise(
        filter: Filter,
        frequency: f32,
        q: f32,
        attack: f32,
        decay: f32,
        peak: f32,
    ) -> Layer {
        Layer {
            source: Source::Noise { filter, q },
            frequency,
            glide_to: None,
            glide_time: None,
            attack,
            decay,
            peak,
            from: Emphasis::Subtle,
            note: false,
        }
    }

    const fn from(mut self, emphasis: Emphasis) -> Layer {
        self.from = emphasis;
        self
    }

    const fn glide(mut self, to: f32, time: f32) -> Layer {
        self.glide_to = Some(to);
        self.glide_time = Some(time);
        self
    }

    const fn with_q(mut self, q: f32) -> Layer {
        if let Source::Noise { filter, .. } = self.source {
            self.source = Source::Noise { filter, q };
        }
        self
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct Recipe {
    pub master_gain: f32,
    pub layers: Vec<Layer>,
    pub release: Vec<Layer>,
    /// Room send multiplier (`LANDED` = 2).
    pub room: f32,
    /// Strike variation: (pitch, level) nudges.
    pub vary: Option<(f32, f32)>,
    /// Semitone steps quick repeats walk through.
    pub walk: Vec<f32>,
}

impl Recipe {
    fn new(master_gain: f32, layers: Vec<Layer>) -> Recipe {
        Recipe {
            master_gain,
            layers,
            release: Vec::new(),
            room: 1.0,
            vary: None,
            walk: Vec::new(),
        }
    }

    pub fn has_notes(&self) -> bool {
        self.layers.iter().any(|layer| layer.note)
    }
}

const LANDED: f32 = 2.0;
const FLAT_Q: f32 = -3.0;
const KNOCK_DROP: f32 = 1.6;
const KNOCK_DROP_TIME: f32 = 0.018;
const BAR: &[(f32, f32)] = &[(1.0, 1.0), (2.76, 0.3), (5.4, 0.1)];
const MALLET: &[(f32, f32)] = &[(1.0, 1.0), (3.99, 0.2)];
const MODE_CEILING: f32 = 5000.0;
const STRIKE_ATTACK: f32 = 0.003;
const SHORTEST_MODE: f32 = 0.028;
const MODE_DAMPING: f32 = 0.75;

use Emphasis::{Normal, Strong};
use Filter::{Bandpass, Lowpass};

fn knock(frequency: f32, decay: f32, peak: f32) -> Layer {
    Layer::tone(frequency * KNOCK_DROP, 0.001, decay, peak).glide(frequency, KNOCK_DROP_TIME)
}

fn struck(
    frequency: f32,
    decay: f32,
    peak: f32,
    material: &[(f32, f32)],
    from: Option<Emphasis>,
) -> Vec<Layer> {
    material
        .iter()
        .filter(|(ratio, _)| frequency * ratio <= MODE_CEILING)
        .enumerate()
        .map(|(mode, (ratio, level))| {
            let layer_from = if mode == 0 {
                from
            } else {
                Some(from.unwrap_or(Normal))
            };
            let layer = Layer::tone(
                frequency * ratio,
                STRIKE_ATTACK,
                SHORTEST_MODE.max(decay / ratio.powf(MODE_DAMPING)),
                peak * level,
            );
            match layer_from {
                Some(emphasis) => layer.from(emphasis),
                None => layer,
            }
        })
        .collect()
}

fn contact(hardness: f32, peak: f32) -> Layer {
    Layer::noise(Lowpass, hardness, FLAT_Q, 0.001, 0.0035, peak)
}

fn ring(frequency: f32, peak: f32) -> Layer {
    Layer::noise(Bandpass, frequency, 8.0, 0.001, 0.0055, peak)
}

fn click(frequency: f32, peak: f32, from: Option<Emphasis>) -> Vec<Layer> {
    let layers = [
        ring(frequency, peak),
        ring(frequency * 0.675, peak * 0.5).with_q(2.0),
    ];
    layers
        .into_iter()
        .map(|layer| from.map_or(layer, |emphasis| layer.from(emphasis)))
        .collect()
}

fn thud(frequency: f32, decay: f32, peak: f32) -> Layer {
    Layer::noise(Lowpass, frequency, 0.7, 0.001, decay, peak)
}

const NOTE_PARTIALS: [(f32, f32, f32); 4] = [
    (1.0, 1.0, 1.0),
    (2.0, 0.9, 0.5),
    (3.0, 1.0, 0.04),
    (4.0, 0.73, 0.056),
];

fn note(frequency: f32, decay: f32, peak: f32, from: Option<Emphasis>) -> Vec<Layer> {
    let attack = 0.11f32.min(decay / 2.0);
    NOTE_PARTIALS
        .iter()
        .enumerate()
        .map(|(partial, (multiple, length, level))| {
            let layer_from = if partial < 2 {
                from
            } else {
                Some(from.unwrap_or(Normal))
            };
            let mut layer = Layer::tone(
                frequency * multiple * 1.09,
                attack,
                decay * length,
                peak * level,
            )
            .glide(frequency * multiple, 0.015);
            layer.note = true;
            match layer_from {
                Some(emphasis) => layer.from(emphasis),
                None => layer,
            }
        })
        .collect()
}

/// The cues Tick plays, each tied to one interface job.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Cue {
    /// Push-to-talk (press theme `tap`): press on hotkey down, release on up.
    Talk,
    /// Locked dictation (press theme `toggle`).
    Lock,
    Tap,
    Toggle,
    Select,
    Open,
    Close,
    Navigate,
    Success,
    Error,
    Warning,
    Loading,
    Ready,
}

impl Cue {
    pub fn recipe(self) -> Recipe {
        match self {
            Cue::Talk => press_tap(),
            Cue::Lock => press_toggle(),
            Cue::Tap => tap(),
            Cue::Toggle => toggle(),
            Cue::Select => select(),
            Cue::Open => open(),
            Cue::Close => close(),
            Cue::Navigate => navigate(),
            Cue::Success => success(),
            Cue::Error => error(),
            Cue::Warning => warning(),
            Cue::Loading => loading(),
            Cue::Ready => ready(),
        }
    }

    /// Cues whose repeats lighten with cadence.
    pub fn follows_cadence(self) -> bool {
        matches!(
            self,
            Cue::Tap | Cue::Toggle | Cue::Select | Cue::Navigate | Cue::Talk | Cue::Lock
        )
    }
}

// MARK: default theme

fn tap() -> Recipe {
    let mut recipe = Recipe::new(
        0.39,
        vec![
            Layer::noise(Bandpass, 4500.0, 1.2, 0.001, 0.00242, 0.03).from(Normal),
            Layer::tone(1174.66, 0.001, 0.18, 0.0135),
            Layer::tone(1180.0, 0.001, 0.164, 0.008),
            Layer::tone(3242.0, 0.001, 0.0827, 0.0055),
            knock(300.0, 0.0261, 0.02).from(Normal),
            Layer::tone(587.33, 0.002, 0.246, 0.009).from(Strong),
            knock(150.0, 0.0489, 0.014).from(Strong),
        ],
    );
    recipe.vary = Some((0.012, 0.12));
    recipe
}

fn select() -> Recipe {
    Recipe::new(
        0.306,
        vec![
            Layer::noise(Bandpass, 2800.0, 2.2, 0.001, 0.00749, 0.16).from(Normal),
            knock(415.0, 0.0194, 0.03),
            knock(208.0, 0.0313, 0.025).from(Strong),
        ],
    )
}

fn toggle() -> Recipe {
    Recipe::new(
        0.24,
        vec![
            Layer::noise(Bandpass, 1830.0, 1.6, 0.001, 0.0156, 0.12),
            knock(330.0, 0.0339, 0.045),
            Layer::noise(Bandpass, 3150.0, 1.6, 0.001, 0.0124, 0.08).from(Normal),
            knock(165.0, 0.0375, 0.025).from(Strong),
        ],
    )
}

fn open() -> Recipe {
    Recipe::new(
        0.335,
        vec![
            Layer::noise(Bandpass, 600.0, 1.4, 0.05, 0.0558, 0.168).glide(1500.0, 0.1),
            Layer::tone(659.25, 0.05, 0.165, 0.015),
            Layer::tone(1318.51, 0.05, 0.0883, 0.005).from(Normal),
            Layer::noise(Lowpass, 250.0, 0.7, 0.04, 0.0779, 0.12).from(Strong),
        ],
    )
}

fn close() -> Recipe {
    Recipe::new(
        0.258,
        vec![
            Layer::noise(Bandpass, 1400.0, 1.4, 0.02, 0.054, 0.216).glide(540.0, 0.07),
            Layer::tone(261.63, 0.003, 0.104, 0.02),
            Layer::noise(Bandpass, 350.0, 2.0, 0.001, 0.0273, 0.2).from(Normal),
            Layer::noise(Bandpass, 165.0, 2.0, 0.001, 0.0345, 0.3).from(Strong),
        ],
    )
}

fn success() -> Recipe {
    let mut layers = vec![contact(1500.0, 0.04)];
    layers.extend(struck(523.25, 0.333, 0.022, MALLET, None));
    layers.extend(struck(783.99, 0.391, 0.02, MALLET, None));
    layers.extend(struck(1318.51, 0.335, 0.014, MALLET, None));
    layers.extend(struck(261.63, 0.469, 0.02, MALLET, Some(Strong)));
    let mut recipe = Recipe::new(0.566, layers);
    recipe.room = LANDED;
    recipe
}

fn error() -> Recipe {
    let mut layers = vec![contact(900.0, 0.05)];
    layers.extend(struck(293.66, 0.138, 0.04, MALLET, None));
    layers.extend(struck(698.46, 0.106, 0.018, MALLET, None));
    layers.push(Layer::noise(Bandpass, 250.0, 1.5, 0.001, 0.0273, 0.2).from(Strong));
    Recipe::new(0.501, layers)
}

fn navigate() -> Recipe {
    Recipe::new(
        0.322,
        vec![
            Layer::noise(Bandpass, 400.0, 1.2, 0.12, 0.111, 0.18).glide(1100.0, 0.21),
            Layer::noise(Lowpass, 540.0, 0.7, 0.09, 0.109, 0.045).from(Normal),
            Layer::noise(Lowpass, 230.0, 0.7, 0.1, 0.144, 0.1).from(Strong),
        ],
    )
}

fn warning() -> Recipe {
    let mut layers = vec![contact(1200.0, 0.04)];
    layers.extend(struck(440.0, 0.163, 0.038, MALLET, None));
    layers.extend(struck(659.25, 0.145, 0.03, MALLET, None));
    layers.extend(struck(220.0, 0.261, 0.02, MALLET, Some(Strong)));
    Recipe::new(0.437, layers)
}

fn loading() -> Recipe {
    Recipe::new(
        0.106,
        vec![
            Layer::tone(196.0, 0.35, 0.969, 0.03),
            Layer::tone(392.0, 0.35, 0.9, 0.01),
            Layer::noise(Lowpass, 500.0, 0.7, 0.35, 0.844, 0.006).from(Normal),
            Layer::tone(98.0, 0.35, 1.04, 0.02).from(Strong),
        ],
    )
}

fn ready() -> Recipe {
    let mut layers = vec![contact(1500.0, 0.02)];
    layers.extend(struck(392.0, 0.497, 0.026, BAR, None));
    layers.push(Layer::tone(393.2, 0.003, 0.462, 0.012));
    layers.extend(struck(196.0, 0.612, 0.016, BAR, Some(Strong)));
    let mut recipe = Recipe::new(0.467, layers);
    recipe.room = LANDED;
    recipe
}

// MARK: press theme

const PRESS_HZ: f32 = 4000.0;
const RELEASE_HZ: f32 = 4800.0;
const C2: f32 = 65.41;
const E2: f32 = 82.41;

fn press_tap() -> Recipe {
    let mut layers = click(PRESS_HZ, 0.53, None);
    layers.extend(note(C2, 1.36, 0.12, None));
    layers.push(thud(200.0, 0.0472, 0.15).from(Strong));
    let mut recipe = Recipe::new(0.0431, layers);
    recipe.release = click(RELEASE_HZ, 0.28, Some(Normal));
    recipe.walk = vec![0.0, 4.0, 9.0];
    recipe.vary = Some((0.0, 0.08));
    recipe
}

fn press_toggle() -> Recipe {
    let mut layers = click(PRESS_HZ, 0.245, None);
    layers.push(knock(330.0, 0.0389, 0.05));
    layers.extend(note(E2, 0.324, 0.06, None));
    layers.push(knock(165.0, 0.05, 0.05).from(Strong));
    let mut recipe = Recipe::new(0.0571, layers);
    recipe.release = click(RELEASE_HZ, 0.1, Some(Normal));
    recipe.vary = Some((0.0, 0.08));
    recipe
}
