use std::f32::consts::{FRAC_1_SQRT_2, PI};

use serde::Deserialize;

use crate::audio::CHANNELS;

const COMB_TUNINGS: [i32; 6] = [1116, 1188, 1277, 1356, 1422, 1491];
const ALLPASS_TUNINGS: [i32; 2] = [556, 441];
const STEREO_SPREAD: i32 = 23;
const HALL_DECAY: f32 = 2.8;
const WIDENING: f32 = 1.25;
const OUTPUT_LIMIT: f32 = 30000.0;
pub const FULL_SCALE: f32 = 32768.0;
const GRAMOPHONE_SEED: u32 = 0x9E37_79B9;

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Effect {
    None,
    Concert,
    Radio,
    Robot,
    Helium,
    Senior,
    EightBit,
    Instrumental,
    Acapella,
    Gramophone,
}

impl Effect {
    pub fn from_id(id: &str) -> Option<Self> {
        Some(match id.to_lowercase().as_str() {
            "none" => Effect::None,
            "concert" => Effect::Concert,
            "radio" => Effect::Radio,
            "robot" => Effect::Robot,
            "helium" => Effect::Helium,
            "senior" => Effect::Senior,
            "8_bit" => Effect::EightBit,
            "instrumental" => Effect::Instrumental,
            "acapella" => Effect::Acapella,
            "gramophone" => Effect::Gramophone,
            _ => return None,
        })
    }

    pub fn id(self) -> &'static str {
        match self {
            Effect::None => "none",
            Effect::Concert => "concert",
            Effect::Radio => "radio",
            Effect::Robot => "robot",
            Effect::Helium => "helium",
            Effect::Senior => "senior",
            Effect::EightBit => "8_bit",
            Effect::Instrumental => "instrumental",
            Effect::Acapella => "acapella",
            Effect::Gramophone => "gramophone",
        }
    }

    pub fn pitch(self) -> f32 {
        match self {
            Effect::Helium => 1.55,
            Effect::Senior => 0.72,
            _ => 1.0,
        }
    }

    pub fn index(self) -> u8 {
        match self {
            Effect::None => 0,
            Effect::Concert => 1,
            Effect::Radio => 2,
            Effect::Robot => 3,
            Effect::Helium => 4,
            Effect::Senior => 5,
            Effect::EightBit => 6,
            Effect::Instrumental => 7,
            Effect::Acapella => 8,
            Effect::Gramophone => 9,
        }
    }

    pub fn from_index(index: u8) -> Self {
        match index {
            1 => Effect::Concert,
            2 => Effect::Radio,
            3 => Effect::Robot,
            4 => Effect::Helium,
            5 => Effect::Senior,
            6 => Effect::EightBit,
            7 => Effect::Instrumental,
            8 => Effect::Acapella,
            9 => Effect::Gramophone,
            _ => Effect::None,
        }
    }
}

struct LowPass {
    alpha: f32,
    state: f32,
}

impl LowPass {
    fn new(alpha: f32) -> Self {
        Self { alpha, state: 0.0 }
    }

    fn process(&mut self, input: f32) -> f32 {
        self.state += self.alpha * (input - self.state);
        self.state
    }

    fn reset(&mut self) {
        self.state = 0.0;
    }
}

struct Comb {
    buffer: Vec<f32>,
    index: usize,
    store: f32,
    feedback: f32,
    damping: f32,
}

impl Comb {
    fn new(size: i32, feedback: f32, damping: f32) -> Self {
        Self {
            buffer: vec![0.0; size.max(1) as usize],
            index: 0,
            store: 0.0,
            feedback,
            damping,
        }
    }

    fn process(&mut self, input: f32) -> f32 {
        let output = self.buffer[self.index];
        self.store = output * (1.0 - self.damping) + self.store * self.damping;
        self.buffer[self.index] = input + self.store * self.feedback;
        self.index = (self.index + 1) % self.buffer.len();
        output
    }

    fn reset(&mut self) {
        self.buffer.fill(0.0);
        self.store = 0.0;
    }
}

struct Allpass {
    buffer: Vec<f32>,
    index: usize,
}

impl Allpass {
    fn new(size: i32) -> Self {
        Self {
            buffer: vec![0.0; size.max(1) as usize],
            index: 0,
        }
    }

    fn process(&mut self, input: f32) -> f32 {
        let buffered = self.buffer[self.index];
        self.buffer[self.index] = input + buffered * 0.5;
        self.index = (self.index + 1) % self.buffer.len();
        buffered - input
    }

    fn reset(&mut self) {
        self.buffer.fill(0.0);
    }
}

struct Delay {
    buffer: Vec<f32>,
    index: usize,
    feedback: f32,
}

impl Delay {
    fn new(size: i32, feedback: f32) -> Self {
        Self {
            buffer: vec![0.0; size.max(1) as usize],
            index: 0,
            feedback,
        }
    }

    fn process(&mut self, input: f32) -> f32 {
        let delayed = self.buffer[self.index];
        self.buffer[self.index] = input + delayed * self.feedback;
        self.index = (self.index + 1) % self.buffer.len();
        delayed
    }

    fn reset(&mut self) {
        self.buffer.fill(0.0);
    }
}

pub struct Chain {
    sample_rate: u32,
    effect: Effect,
    frame: [f32; CHANNELS],
    combs: Vec<Vec<Comb>>,
    allpasses: Vec<Vec<Allpass>>,
    pre_delays: Vec<Delay>,
    wet_high_pass: Vec<LowPass>,
    robot_high_pass: Vec<LowPass>,
    robot_resonators: Vec<Delay>,
    robot_phase: f32,
    radio_high_pass: Vec<LowPass>,
    radio_low_pass: Vec<LowPass>,
    gramophone_high_pass: Vec<LowPass>,
    gramophone_low_pass: Vec<LowPass>,
    gramophone_noise: u32,
    gramophone_wow: Vec<f32>,
    gramophone_wow_index: usize,
    gramophone_wow_phase: f32,
    gramophone_grain: LowPass,
    gramophone_hiss: LowPass,
    gramophone_pop: f32,
    held: [f32; CHANNELS],
    hold_counter: usize,
    hold_length: usize,
    voices: crate::voices::VoiceSplit,
}

impl Chain {
    pub fn new(sample_rate: u32) -> Self {
        let rate = sample_rate.max(1) as f32;
        let alpha_for = |frequency: f32| 1.0 - (-2.0 * PI * frequency / rate).exp();
        let scale = rate / 44100.0;
        let decay_for = |size: i32| 10f32.powf(-3.0 * size as f32 / (rate * HALL_DECAY));
        let combs = (0..CHANNELS)
            .map(|channel| {
                COMB_TUNINGS
                    .iter()
                    .map(|tuning| {
                        let size = ((*tuning + channel as i32 * STEREO_SPREAD) as f32 * scale) as i32;
                        Comb::new(size, decay_for(size), 0.25)
                    })
                    .collect()
            })
            .collect();
        let allpasses = (0..CHANNELS)
            .map(|channel| {
                ALLPASS_TUNINGS
                    .iter()
                    .map(|tuning| {
                        Allpass::new(
                            ((*tuning + channel as i32 * STEREO_SPREAD) as f32 * scale) as i32,
                        )
                    })
                    .collect()
            })
            .collect();
        Self {
            sample_rate: sample_rate.max(1),
            effect: Effect::None,
            frame: [0.0; CHANNELS],
            combs,
            allpasses,
            pre_delays: (0..CHANNELS)
                .map(|_| Delay::new((rate * 0.022) as i32, 0.0))
                .collect(),
            wet_high_pass: (0..CHANNELS).map(|_| LowPass::new(alpha_for(200.0))).collect(),
            robot_high_pass: (0..CHANNELS).map(|_| LowPass::new(alpha_for(180.0))).collect(),
            robot_resonators: (0..CHANNELS)
                .map(|_| Delay::new((rate * 0.007) as i32, 0.5))
                .collect(),
            robot_phase: 0.0,
            radio_high_pass: (0..2).map(|_| LowPass::new(alpha_for(450.0))).collect(),
            radio_low_pass: (0..2).map(|_| LowPass::new(alpha_for(2800.0))).collect(),
            gramophone_high_pass: (0..2).map(|_| LowPass::new(alpha_for(220.0))).collect(),
            gramophone_low_pass: (0..3).map(|_| LowPass::new(alpha_for(3200.0))).collect(),
            gramophone_noise: GRAMOPHONE_SEED,
            gramophone_wow: vec![0.0; (rate * 0.03) as usize + 2],
            gramophone_wow_index: 0,
            gramophone_wow_phase: 0.0,
            gramophone_grain: LowPass::new(alpha_for(40.0)),
            gramophone_hiss: LowPass::new(alpha_for(5000.0)),
            gramophone_pop: 0.0,
            held: [0.0; CHANNELS],
            hold_counter: 0,
            hold_length: (sample_rate as usize / 8000).max(1),
            voices: crate::voices::VoiceSplit::new(sample_rate),
        }
    }

    pub fn process(&mut self, effect: Effect, samples: &mut [f32]) {
        if effect != self.effect {
            self.reset();
            self.effect = effect;
        }
        if matches!(effect, Effect::None | Effect::Senior) {
            return;
        }
        for frame in samples.chunks_mut(CHANNELS) {
            for channel in 0..CHANNELS {
                self.frame[channel] = frame[channel] * FULL_SCALE;
            }
            match effect {
                Effect::Concert => self.process_concert(),
                Effect::Radio => self.process_radio(),
                Effect::Robot => self.process_robot(),
                Effect::Helium => self.process_helium(),
                Effect::EightBit => self.process_eight_bit(),
                Effect::Instrumental => self.process_voices(false),
                Effect::Acapella => self.process_voices(true),
                Effect::Gramophone => self.process_gramophone(),
                _ => {}
            }
            for channel in 0..CHANNELS {
                frame[channel] = clip(self.frame[channel]) / FULL_SCALE;
            }
        }
    }

    fn process_concert(&mut self) {
        for channel in 0..CHANNELS {
            let input = self.frame[channel];
            let mut wet = self.pre_delays[channel].process(input * 0.09);
            wet -= self.wet_high_pass[channel].process(wet);
            let mut late = 0.0;
            for comb in self.combs[channel].iter_mut() {
                late += comb.process(wet);
            }
            for allpass in self.allpasses[channel].iter_mut() {
                late = allpass.process(late);
            }
            self.frame[channel] = input * 0.85 + late * 0.8;
        }
        let mid = (self.frame[0] + self.frame[1]) * 0.5;
        let side = (self.frame[0] - self.frame[1]) * 0.5 * WIDENING;
        self.frame[0] = mid + side;
        self.frame[1] = mid - side;
    }

    fn process_radio(&mut self) {
        let mut mono = 0.0;
        for channel in 0..CHANNELS {
            mono += self.frame[channel];
        }
        mono /= CHANNELS as f32;
        let mut band = mono;
        for stage in self.radio_high_pass.iter_mut() {
            band -= stage.process(band);
        }
        for stage in self.radio_low_pass.iter_mut() {
            band = stage.process(band);
        }
        let driven = saturate(band * 5.0, 20000.0) * 0.9;
        self.frame = [driven; CHANNELS];
    }

    fn process_robot(&mut self) {
        let carrier = (self.robot_phase * 2.0 * PI).sin();
        self.robot_phase += 62.0 / self.sample_rate as f32;
        if self.robot_phase >= 1.0 {
            self.robot_phase -= 1.0;
        }
        for channel in 0..CHANNELS {
            let input = self.frame[channel];
            let body = input - self.robot_high_pass[channel].process(input);
            let resonant = self.robot_resonators[channel].process(body);
            self.frame[channel] = (body + resonant * 0.7) * carrier * 0.9;
        }
    }

    fn process_helium(&mut self) {
        for channel in 0..CHANNELS {
            self.frame[channel] *= 0.72;
        }
    }

    fn process_eight_bit(&mut self) {
        if self.hold_counter == 0 {
            for channel in 0..CHANNELS {
                let driven = saturate(self.frame[channel] * 1.6, 30000.0);
                self.held[channel] = ((driven as i32) & -2048) as f32 * 0.8;
            }
        }
        self.frame = self.held;
        self.hold_counter = (self.hold_counter + 1) % self.hold_length;
    }

    fn process_gramophone(&mut self) {
        let rate = self.sample_rate as f32;
        let mut mono = 0.0;
        for channel in 0..CHANNELS {
            mono += self.frame[channel];
        }
        mono /= CHANNELS as f32;
        let length = self.gramophone_wow.len();
        self.gramophone_wow[self.gramophone_wow_index] = mono;
        let wobble = (self.gramophone_wow_phase * 2.0 * PI).sin();
        self.gramophone_wow_phase = (self.gramophone_wow_phase + 0.55 / rate).fract();
        let lag = rate * (0.012 + 0.0025 * wobble);
        let read = (self.gramophone_wow_index as f32 - lag).rem_euclid(length as f32);
        let before = read.floor() as usize % length;
        let after = (before + 1) % length;
        let blend = read.fract();
        let mut band = self.gramophone_wow[before] * (1.0 - blend) + self.gramophone_wow[after] * blend;
        self.gramophone_wow_index = (self.gramophone_wow_index + 1) % length;
        for stage in self.gramophone_high_pass.iter_mut() {
            band -= stage.process(band);
        }
        for stage in self.gramophone_low_pass.iter_mut() {
            band = stage.process(band);
        }
        let grain_noise = self.gramophone_random();
        let grain = 1.0 + self.gramophone_grain.process(grain_noise) * 6.0;
        let music = saturate(band * 1.8 * grain, 22000.0) * 0.85;
        let hiss_noise = self.gramophone_random();
        let hiss = self.gramophone_hiss.process(hiss_noise) * 1400.0;
        let chance = self.gramophone_random().abs() * rate;
        if chance < 6.0 {
            self.gramophone_pop = self.gramophone_random() * 14000.0;
        } else if chance < 60.0 {
            self.gramophone_pop = self.gramophone_random() * 4500.0;
        }
        let crackle = self.gramophone_pop * self.gramophone_random().signum();
        self.gramophone_pop *= 0.55;
        self.frame = [music + hiss + crackle; CHANNELS];
    }

    fn gramophone_random(&mut self) -> f32 {
        self.gramophone_noise ^= self.gramophone_noise << 13;
        self.gramophone_noise ^= self.gramophone_noise >> 17;
        self.gramophone_noise ^= self.gramophone_noise << 5;
        self.gramophone_noise as f32 / u32::MAX as f32 * 2.0 - 1.0
    }

    fn process_voices(&mut self, keep_voices: bool) {
        self.frame = self.voices.process(self.frame, keep_voices);
    }

    fn reset(&mut self) {
        for channel in self.combs.iter_mut() {
            for comb in channel {
                comb.reset();
            }
        }
        for channel in self.allpasses.iter_mut() {
            for allpass in channel {
                allpass.reset();
            }
        }
        for delay in self.robot_resonators.iter_mut().chain(&mut self.pre_delays) {
            delay.reset();
        }
        for stage in self
            .robot_high_pass
            .iter_mut()
            .chain(&mut self.wet_high_pass)
            .chain(&mut self.radio_high_pass)
            .chain(&mut self.radio_low_pass)
            .chain(&mut self.gramophone_high_pass)
            .chain(&mut self.gramophone_low_pass)
        {
            stage.reset();
        }
        self.held = [0.0; CHANNELS];
        self.hold_counter = 0;
        self.robot_phase = 0.0;
        self.gramophone_noise = GRAMOPHONE_SEED;
        self.gramophone_wow.fill(0.0);
        self.gramophone_wow_index = 0;
        self.gramophone_wow_phase = 0.0;
        self.gramophone_grain.reset();
        self.gramophone_hiss.reset();
        self.gramophone_pop = 0.0;
        self.voices.reset();
    }
}

pub const MAX_BANDS: usize = 16;
const MAX_GAIN_DB: f32 = 24.0;
const BAND_Q: f32 = 1.0;
const SILENT_GAIN_DB: f32 = 0.01;

#[derive(Clone, Copy, Default)]
struct Biquad {
    b0: f32,
    b1: f32,
    b2: f32,
    a1: f32,
    a2: f32,
    x1: [f32; CHANNELS],
    x2: [f32; CHANNELS],
    y1: [f32; CHANNELS],
    y2: [f32; CHANNELS],
}

impl Biquad {
    fn peaking(rate: f32, frequency: f32, gain_db: f32) -> Self {
        let amplitude = 10f32.powf(gain_db / 40.0);
        let omega = 2.0 * PI * frequency / rate;
        let alpha = omega.sin() / (2.0 * BAND_Q);
        let cosine = omega.cos();
        let a0 = 1.0 + alpha / amplitude;
        Self {
            b0: (1.0 + alpha * amplitude) / a0,
            b1: -2.0 * cosine / a0,
            b2: (1.0 - alpha * amplitude) / a0,
            a1: -2.0 * cosine / a0,
            a2: (1.0 - alpha / amplitude) / a0,
            ..Self::default()
        }
    }

    fn pass(rate: f32, frequency: f32, high: bool) -> Self {
        let omega = 2.0 * PI * frequency / rate;
        let alpha = omega.sin() / (2.0 * FRAC_1_SQRT_2);
        let cosine = omega.cos();
        let a0 = 1.0 + alpha;
        let (edge, middle) = if high { ((1.0 + cosine) / 2.0, -(1.0 + cosine)) } else { ((1.0 - cosine) / 2.0, 1.0 - cosine) };
        Self {
            b0: edge / a0,
            b1: middle / a0,
            b2: edge / a0,
            a1: -2.0 * cosine / a0,
            a2: (1.0 - alpha) / a0,
            ..Self::default()
        }
    }

    fn process(&mut self, channel: usize, input: f32) -> f32 {
        let output = self.b0 * input + self.b1 * self.x1[channel] + self.b2 * self.x2[channel]
            - self.a1 * self.y1[channel]
            - self.a2 * self.y2[channel];
        self.x2[channel] = self.x1[channel];
        self.x1[channel] = input;
        self.y2[channel] = self.y1[channel];
        self.y1[channel] = output;
        output
    }
}

pub struct Equalizer {
    rate: f32,
    filters: Vec<Biquad>,
    preamp: f32,
    pub version: u32,
}

impl Equalizer {
    pub fn new(rate: u32) -> Self {
        Self { rate: rate as f32, filters: Vec::new(), preamp: 1.0, version: 0 }
    }

    pub fn configure(&mut self, bands: &[(f32, f32)], version: u32) {
        self.version = version;
        let limit = self.rate * 0.45;
        let mut filters: Vec<Biquad> = Vec::new();
        let mut boost: f32 = 0.0;
        for &(frequency, gain) in bands.iter().take(MAX_BANDS) {
            let gain = gain.clamp(-MAX_GAIN_DB, MAX_GAIN_DB);
            if !frequency.is_finite() || frequency <= 0.0 || frequency >= limit || gain.abs() < SILENT_GAIN_DB {
                continue;
            }
            boost = boost.max(gain);
            let mut filter = Biquad::peaking(self.rate, frequency, gain);
            if let Some(previous) = self.filters.get(filters.len()) {
                (filter.x1, filter.x2, filter.y1, filter.y2) = (previous.x1, previous.x2, previous.y1, previous.y2);
            }
            filters.push(filter);
        }
        self.preamp = 10f32.powf(-boost / 20.0);
        self.filters = filters;
    }

    pub fn process(&mut self, left: f32, right: f32) -> (f32, f32) {
        if self.filters.is_empty() {
            return (left, right);
        }
        let (mut left, mut right) = (left * self.preamp, right * self.preamp);
        for filter in &mut self.filters {
            left = filter.process(0, left);
            right = filter.process(1, right);
        }
        (left, right)
    }
}

pub const MAX_STAGES: usize = 16;
const ECHO_LIMIT_SECONDS: f32 = 2.0;

#[derive(Deserialize, Clone, Copy, Debug, PartialEq)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Stage {
    Lowpass { frequency: f32 },
    Highpass { frequency: f32 },
    Peak { frequency: f32, gain: f32 },
    Reverb { mix: Option<f32>, decay: Option<f32> },
    Echo { time: Option<f32>, feedback: Option<f32>, mix: Option<f32> },
    Distortion { drive: Option<f32> },
    Bitcrush { bits: Option<f32>, rate: Option<f32> },
    Tremolo { rate: Option<f32>, depth: Option<f32> },
    Ring { frequency: f32, mix: Option<f32> },
    Width { amount: f32 },
    Gain { db: f32 },
}

#[derive(Deserialize, Default)]
pub struct Custom {
    #[serde(default)]
    pub chain: Vec<Stage>,
    pub pitch: Option<f32>,
    pub speed: Option<f32>,
}

enum Unit {
    Filter(Biquad),
    Reverb { combs: Vec<Vec<Comb>>, allpasses: Vec<Vec<Allpass>>, mix: f32 },
    Echo { lines: Vec<Delay>, mix: f32 },
    Distortion { drive: f32 },
    Bitcrush { levels: f32, hold: usize, counter: usize, held: (f32, f32) },
    Tremolo { phase: f32, step: f32, depth: f32 },
    Ring { phase: f32, step: f32, mix: f32 },
    Width(f32),
    Gain(f32),
}

impl Unit {
    fn new(stage: Stage, rate: f32) -> Self {
        let frequency = |value: f32| value.clamp(10.0, rate * 0.45);
        match stage {
            Stage::Lowpass { frequency: value } => Unit::Filter(Biquad::pass(rate, frequency(value), false)),
            Stage::Highpass { frequency: value } => Unit::Filter(Biquad::pass(rate, frequency(value), true)),
            Stage::Peak { frequency: value, gain } => {
                Unit::Filter(Biquad::peaking(rate, frequency(value), gain.clamp(-MAX_GAIN_DB, MAX_GAIN_DB)))
            }
            Stage::Reverb { mix, decay } => {
                let decay = decay.unwrap_or(HALL_DECAY).clamp(0.1, 10.0);
                let scale = rate / 44100.0;
                let size = |tuning: i32, channel: usize| ((tuning + channel as i32 * STEREO_SPREAD) as f32 * scale) as i32;
                Unit::Reverb {
                    combs: (0..CHANNELS)
                        .map(|channel| {
                            COMB_TUNINGS
                                .iter()
                                .map(|tuning| {
                                    let length = size(*tuning, channel);
                                    Comb::new(length, 10f32.powf(-3.0 * length as f32 / (rate * decay)), 0.25)
                                })
                                .collect()
                        })
                        .collect(),
                    allpasses: (0..CHANNELS)
                        .map(|channel| ALLPASS_TUNINGS.iter().map(|tuning| Allpass::new(size(*tuning, channel))).collect())
                        .collect(),
                    mix: mix.unwrap_or(0.5).clamp(0.0, 1.0),
                }
            }
            Stage::Echo { time, feedback, mix } => {
                let length = (time.unwrap_or(0.3).clamp(0.01, ECHO_LIMIT_SECONDS) * rate) as i32;
                let feedback = feedback.unwrap_or(0.4).clamp(0.0, 0.95);
                Unit::Echo {
                    lines: (0..CHANNELS).map(|_| Delay::new(length, feedback)).collect(),
                    mix: mix.unwrap_or(0.5).clamp(0.0, 1.0),
                }
            }
            Stage::Distortion { drive } => Unit::Distortion { drive: drive.unwrap_or(4.0).clamp(1.0, 100.0) },
            Stage::Bitcrush { bits, rate: target } => Unit::Bitcrush {
                levels: 2f32.powf(bits.unwrap_or(8.0).clamp(1.0, 16.0) - 1.0),
                hold: (rate / target.unwrap_or(rate).clamp(100.0, rate)).round().max(1.0) as usize,
                counter: 0,
                held: (0.0, 0.0),
            },
            Stage::Tremolo { rate: speed, depth } => Unit::Tremolo {
                phase: 0.0,
                step: 2.0 * PI * speed.unwrap_or(5.0).clamp(0.01, 40.0) / rate,
                depth: depth.unwrap_or(0.5).clamp(0.0, 1.0),
            },
            Stage::Ring { frequency: value, mix } => Unit::Ring {
                phase: 0.0,
                step: 2.0 * PI * frequency(value) / rate,
                mix: mix.unwrap_or(1.0).clamp(0.0, 1.0),
            },
            Stage::Width { amount } => Unit::Width(amount.clamp(0.0, 4.0)),
            Stage::Gain { db } => Unit::Gain(10f32.powf(db.clamp(-MAX_GAIN_DB, MAX_GAIN_DB) / 20.0)),
        }
    }

    fn process(&mut self, left: f32, right: f32) -> (f32, f32) {
        match self {
            Unit::Filter(filter) => (filter.process(0, left), filter.process(1, right)),
            Unit::Reverb { combs, allpasses, mix } => {
                let mut wet = [0.0; CHANNELS];
                for (channel, input) in [left, right].into_iter().enumerate() {
                    let mut late = 0.0;
                    for comb in combs[channel].iter_mut() {
                        late += comb.process(input * 0.09);
                    }
                    for allpass in allpasses[channel].iter_mut() {
                        late = allpass.process(late);
                    }
                    wet[channel] = input * 0.85 + late * 0.8;
                }
                (left + (wet[0] - left) * *mix, right + (wet[1] - right) * *mix)
            }
            Unit::Echo { lines, mix } => (
                left + lines[0].process(left) * *mix,
                right + lines[1].process(right) * *mix,
            ),
            Unit::Distortion { drive } => {
                let norm = drive.tanh();
                ((left * *drive).tanh() / norm, (right * *drive).tanh() / norm)
            }
            Unit::Bitcrush { levels, hold, counter, held } => {
                if *counter == 0 {
                    *held = ((left * *levels).round() / *levels, (right * *levels).round() / *levels);
                }
                *counter = (*counter + 1) % *hold;
                *held
            }
            Unit::Tremolo { phase, step, depth } => {
                let gain = 1.0 - *depth * (0.5 + 0.5 * phase.sin());
                *phase = (*phase + *step) % (2.0 * PI);
                (left * gain, right * gain)
            }
            Unit::Ring { phase, step, mix } => {
                let carrier = 1.0 - *mix + phase.sin() * *mix;
                *phase = (*phase + *step) % (2.0 * PI);
                (left * carrier, right * carrier)
            }
            Unit::Width(amount) => {
                let mid = (left + right) * 0.5;
                let side = (left - right) * 0.5 * *amount;
                (mid + side, mid - side)
            }
            Unit::Gain(gain) => (left * *gain, right * *gain),
        }
    }
}

pub struct Rack {
    rate: f32,
    units: Vec<Unit>,
    pub version: u32,
}

impl Rack {
    pub fn new(rate: u32) -> Self {
        Self { rate: rate.max(1) as f32, units: Vec::new(), version: 0 }
    }

    pub fn configure(&mut self, stages: &[Stage], version: u32) {
        self.version = version;
        self.units = stages.iter().take(MAX_STAGES).map(|stage| Unit::new(*stage, self.rate)).collect();
    }

    pub fn process(&mut self, left: f32, right: f32) -> (f32, f32) {
        if self.units.is_empty() {
            return (left, right);
        }
        let (mut left, mut right) = (left, right);
        for unit in &mut self.units {
            (left, right) = unit.process(left, right);
        }
        (left.clamp(-1.0, 1.0), right.clamp(-1.0, 1.0))
    }
}

fn saturate(value: f32, limit: f32) -> f32 {
    limit * (value / limit).tanh()
}

fn clip(value: f32) -> f32 {
    (saturate(value, OUTPUT_LIMIT) as i32).clamp(-32768, 32767) as f32
}

#[cfg(test)]
mod tests {
    use super::*;

    fn band_level(equalizer: &mut Equalizer, frequency: f32, rate: u32) -> f32 {
        let mut peak: f32 = 0.0;
        for frame in 0..rate {
            let input = (2.0 * PI * frequency * frame as f32 / rate as f32).sin() * 0.25;
            let (left, right) = equalizer.process(input, input);
            if frame > rate / 2 {
                peak = peak.max(left.abs()).max(right.abs());
            }
        }
        peak
    }

    #[test]
    fn equalizer_shapes_only_the_chosen_band() {
        let rate = 48_000;
        let mut flat = Equalizer::new(rate);
        flat.configure(&[(1000.0, 0.0), (60.0, 0.0)], 1);
        assert_eq!(flat.process(0.3, -0.2), (0.3, -0.2));
        let mut cut = Equalizer::new(rate);
        cut.configure(&[(1000.0, -12.0)], 1);
        let at_band = band_level(&mut cut, 1000.0, rate);
        let mut cut = Equalizer::new(rate);
        cut.configure(&[(1000.0, -12.0)], 1);
        let far_away = band_level(&mut cut, 60.0, rate);
        assert!(at_band < 0.25 * 0.3, "the band should drop by about 12 dB, got {at_band}");
        assert!(far_away > 0.25 * 0.9, "other frequencies should stay, got {far_away}");
        let mut boost = Equalizer::new(rate);
        boost.configure(&[(1000.0, 12.0)], 1);
        assert!(band_level(&mut boost, 1000.0, rate) <= 0.26, "boosts are compensated so they don't clip");
    }

    fn tone(frames: usize, rate: u32) -> Vec<f32> {
        (0..frames)
            .flat_map(|frame| {
                let phase = 2.0 * PI * 440.0 * frame as f32 / rate as f32;
                let sample = phase.sin() * 0.5;
                [sample, sample * 0.6]
            })
            .collect()
    }

    fn peak(samples: &[f32]) -> f32 {
        samples.iter().fold(0.0f32, |peak, value| peak.max(value.abs()))
    }

    #[test]
    fn every_effect_id_round_trips() {
        for id in [
            "none",
            "concert",
            "radio",
            "robot",
            "helium",
            "senior",
            "8_bit",
            "instrumental",
            "acapella",
            "gramophone",
        ] {
            let effect = Effect::from_id(id).unwrap();
            assert_eq!(effect.id(), id);
            assert_eq!(Effect::from_index(effect.index()), effect);
        }
        assert_eq!(Effect::from_id("nope"), None);
    }

    #[test]
    fn effects_change_the_signal_without_blowing_up() {
        let rate = 44100;
        for effect in [
            Effect::Concert,
            Effect::Radio,
            Effect::Robot,
            Effect::Helium,
            Effect::EightBit,
            Effect::Instrumental,
            Effect::Acapella,
            Effect::Gramophone,
        ] {
            let mut chain = Chain::new(rate);
            let source = tone(rate as usize / 2, rate);
            let mut samples = source.clone();
            chain.process(effect, &mut samples);
            assert!(
                samples.iter().all(|sample| sample.is_finite()),
                "{effect:?} produced a non finite sample"
            );
            assert!(peak(&samples) <= 1.0, "{effect:?} clipped past full scale");
            assert!(
                samples != source,
                "{effect:?} left the signal untouched"
            );
        }
    }

    #[test]
    fn none_and_senior_pass_through_untouched() {
        let rate = 44100;
        for effect in [Effect::None, Effect::Senior] {
            let mut chain = Chain::new(rate);
            let source = tone(1024, rate);
            let mut samples = source.clone();
            chain.process(effect, &mut samples);
            assert_eq!(samples, source, "{effect:?} should be a pass through");
        }
    }

    #[test]
    fn eight_bit_holds_samples_and_quantises_them() {
        let rate = 44100;
        let mut chain = Chain::new(rate);
        let mut samples = tone(64, rate);
        chain.process(Effect::EightBit, &mut samples);
        let hold = (rate as usize / 8000).max(1);
        for frame in 1..hold {
            assert_eq!(
                samples[frame * CHANNELS],
                samples[0],
                "sample and hold should repeat for {hold} frames"
            );
        }
        let distinct = |samples: &[f32]| {
            let mut levels: Vec<i32> = samples
                .iter()
                .map(|sample| (sample * FULL_SCALE) as i32)
                .collect();
            levels.sort_unstable();
            levels.dedup();
            levels.len()
        };
        let crushed = distinct(&samples);
        let original = distinct(&tone(64, rate));
        assert!(
            crushed * 4 < original,
            "bit crushing left {crushed} levels out of {original}"
        );
    }

    #[test]
    fn custom_chains_parse_and_stay_in_range() {
        let custom: Custom = serde_json::from_str(
            r#"{"pitch": 0.9, "chain": [
                {"type": "lowpass", "frequency": 800},
                {"type": "highpass", "frequency": 120},
                {"type": "peak", "frequency": 1000, "gain": 6},
                {"type": "reverb", "mix": 0.6, "decay": 3},
                {"type": "echo", "time": 0.25},
                {"type": "distortion", "drive": 8},
                {"type": "bitcrush", "bits": 6, "rate": 8000},
                {"type": "tremolo"},
                {"type": "ring", "frequency": 30},
                {"type": "width", "amount": 2},
                {"type": "gain", "db": 12}
            ]}"#,
        )
        .unwrap();
        assert_eq!(custom.pitch, Some(0.9));
        assert_eq!(custom.chain.len(), 11);
        let rate = 48_000;
        let mut rack = Rack::new(rate);
        rack.configure(&custom.chain, 1);
        let mut changed = false;
        for frame in 0..rate {
            let input = (2.0 * PI * 440.0 * frame as f32 / rate as f32).sin() * 0.5;
            let (left, right) = rack.process(input, input * 0.6);
            assert!(left.is_finite() && right.is_finite());
            assert!(left.abs() <= 1.0 && right.abs() <= 1.0);
            changed |= (left - input).abs() > 0.01;
        }
        assert!(changed, "the chain should change the signal");
        assert!(serde_json::from_str::<Custom>(r#"{"chain": [{"type": "nope"}]}"#).is_err());
    }

    #[test]
    fn empty_rack_passes_through() {
        let mut rack = Rack::new(44100);
        rack.configure(&[], 1);
        assert_eq!(rack.process(0.3, -0.2), (0.3, -0.2));
        let mut lowpass = Rack::new(48_000);
        lowpass.configure(&[Stage::Lowpass { frequency: 200.0 }], 1);
        let mut peak: f32 = 0.0;
        for frame in 0..48_000 {
            let input = (2.0 * PI * 8000.0 * frame as f32 / 48_000.0).sin() * 0.5;
            let (left, _) = lowpass.process(input, input);
            if frame > 24_000 {
                peak = peak.max(left.abs());
            }
        }
        assert!(peak < 0.05, "a 200 Hz lowpass should remove 8 kHz, got {peak}");
    }
}
