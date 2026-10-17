use std::f32::consts::PI;
use std::sync::Arc;

use realfft::num_complex::Complex32;
use realfft::{ComplexToReal, RealFftPlanner, RealToComplex};

const WINDOW_SECONDS: f32 = 0.046;
const OVERLAP: usize = 4;
const LOW_EDGE: f32 = 110.0;
const LOW_FULL: f32 = 220.0;
const HIGH_FULL: f32 = 7500.0;
const HIGH_EDGE: f32 = 12000.0;
const SHARPNESS: i32 = 4;
const ATTACK: f32 = 0.55;
const RELEASE: f32 = 0.2;
const ONSET: f32 = 2.4;
const DRUM_KEEP: f32 = 0.2;
const HISTORY: f32 = 0.15;
const EPSILON: f32 = 1e-9;
const ACAPELLA_GAIN: f32 = 2.0;

pub struct VoiceSplit {
    size: usize,
    hop: usize,
    latency: usize,
    rover: usize,
    forward: Arc<dyn RealToComplex<f32>>,
    inverse: Arc<dyn ComplexToReal<f32>>,
    window: Vec<f32>,
    weights: Vec<f32>,
    input: [Vec<f32>; 2],
    pending: [Vec<f32>; 2],
    sum: [Vec<f32>; 2],
    time: Vec<f32>,
    spectra: [Vec<Complex32>; 2],
    voice: Vec<Complex32>,
    mask: Vec<f32>,
    smoothed: Vec<f32>,
    history: Vec<f32>,
    scratch_forward: Vec<Complex32>,
    scratch_inverse: Vec<Complex32>,
    norm: f32,
}

impl VoiceSplit {
    pub fn new(sample_rate: u32) -> Self {
        let rate = sample_rate.max(1) as f32;
        let size = ((rate * WINDOW_SECONDS) as usize).next_power_of_two().max(256);
        let hop = size / OVERLAP;
        let mut planner = RealFftPlanner::<f32>::new();
        let forward = planner.plan_fft_forward(size);
        let inverse = planner.plan_fft_inverse(size);
        let bins = size / 2 + 1;
        let window: Vec<f32> = (0..size).map(|n| 0.5 - 0.5 * (2.0 * PI * n as f32 / size as f32).cos()).collect();
        let overlap_gain: f32 = (0..OVERLAP).map(|step| window[step * hop].powi(2)).sum();
        let weights = (0..bins)
            .map(|bin| {
                let frequency = bin as f32 * rate / size as f32;
                let rise = smooth_step(LOW_EDGE, LOW_FULL, frequency);
                let fall = 1.0 - smooth_step(HIGH_FULL, HIGH_EDGE, frequency);
                rise * fall
            })
            .collect();
        Self {
            size,
            hop,
            latency: size - hop,
            rover: size - hop,
            scratch_forward: forward.make_scratch_vec(),
            scratch_inverse: inverse.make_scratch_vec(),
            forward,
            inverse,
            window,
            weights,
            input: [vec![0.0; size], vec![0.0; size]],
            pending: [vec![0.0; hop], vec![0.0; hop]],
            sum: [vec![0.0; size], vec![0.0; size]],
            time: vec![0.0; size],
            spectra: [vec![Complex32::default(); bins], vec![Complex32::default(); bins]],
            voice: vec![Complex32::default(); bins],
            mask: vec![0.0; bins],
            smoothed: vec![0.0; bins],
            history: vec![0.0; bins],
            norm: 1.0 / (overlap_gain * size as f32),
        }
    }

    pub fn reset(&mut self) {
        for channel in 0..2 {
            self.input[channel].fill(0.0);
            self.pending[channel].fill(0.0);
            self.sum[channel].fill(0.0);
        }
        self.mask.fill(0.0);
        self.history.fill(0.0);
        self.rover = self.latency;
    }

    pub fn process(&mut self, frame: [f32; 2], keep_voices: bool) -> [f32; 2] {
        let slot = self.rover - self.latency;
        let out = [self.pending[0][slot], self.pending[1][slot]];
        self.input[0][self.rover] = frame[0];
        self.input[1][self.rover] = frame[1];
        self.rover += 1;
        if self.rover >= self.size {
            self.rover = self.latency;
            self.analyse(keep_voices);
        }
        out
    }

    fn analyse(&mut self, keep_voices: bool) {
        for channel in 0..2 {
            for (index, sample) in self.time.iter_mut().enumerate() {
                *sample = self.input[channel][index] * self.window[index];
            }
            let _ = self.forward.process_with_scratch(&mut self.time, &mut self.spectra[channel], &mut self.scratch_forward);
        }
        self.update_mask();
        let bins = self.voice.len();
        for bin in 0..bins {
            let mid = (self.spectra[0][bin] + self.spectra[1][bin]) * 0.5;
            self.voice[bin] = mid * self.smoothed[bin];
        }
        if keep_voices {
            for channel in 0..2 {
                for bin in 0..bins {
                    self.spectra[channel][bin] = self.voice[bin] * ACAPELLA_GAIN;
                }
            }
        } else {
            for channel in 0..2 {
                for bin in 0..bins {
                    self.spectra[channel][bin] -= self.voice[bin];
                }
            }
        }
        for channel in 0..2 {
            let spectrum = &mut self.spectra[channel];
            spectrum[0].im = 0.0;
            spectrum[bins - 1].im = 0.0;
            let _ = self.inverse.process_with_scratch(spectrum, &mut self.time, &mut self.scratch_inverse);
            let sum = &mut self.sum[channel];
            for index in 0..self.size {
                sum[index] += self.time[index] * self.window[index] * self.norm;
            }
            self.pending[channel].copy_from_slice(&sum[..self.hop]);
            sum.copy_within(self.hop.., 0);
            let tail = self.size - self.hop;
            sum[tail..].fill(0.0);
            self.input[channel].copy_within(self.hop.., 0);
        }
    }

    fn update_mask(&mut self) {
        let bins = self.mask.len();
        for bin in 0..bins {
            let left = self.spectra[0][bin];
            let right = self.spectra[1][bin];
            let power = left.norm_sqr() + right.norm_sqr();
            let centred = (2.0 * (left * right.conj()).re / (power + EPSILON)).max(0.0);
            let mut wanted = centred.powi(SHARPNESS) * self.weights[bin];
            let level = (left + right).norm() * 0.5;
            if level > self.history[bin] * ONSET && self.history[bin] > EPSILON {
                wanted *= DRUM_KEEP;
            }
            self.history[bin] += HISTORY * (level - self.history[bin]);
            let current = self.mask[bin];
            let speed = if wanted > current { ATTACK } else { RELEASE };
            self.mask[bin] = current + speed * (wanted - current);
        }
        for bin in 0..bins {
            let before = self.mask[bin.saturating_sub(1)];
            let after = self.mask[(bin + 1).min(bins - 1)];
            self.smoothed[bin] = (before + self.mask[bin] * 2.0 + after) * 0.25;
        }
    }
}

fn smooth_step(from: f32, to: f32, value: f32) -> f32 {
    let t = ((value - from) / (to - from)).clamp(0.0, 1.0);
    t * t * (3.0 - 2.0 * t)
}

#[cfg(test)]
mod tests {
    use super::*;

    const RATE: u32 = 44100;

    fn level(signal: &[f32], frequency: f32) -> f32 {
        let (mut real, mut imaginary) = (0.0f64, 0.0f64);
        for (index, sample) in signal.iter().enumerate() {
            let phase = 2.0 * std::f64::consts::PI * frequency as f64 * index as f64 / RATE as f64;
            real += *sample as f64 * phase.cos();
            imaginary += *sample as f64 * phase.sin();
        }
        (2.0 * (real * real + imaginary * imaginary).sqrt() / signal.len() as f64) as f32
    }

    fn run(keep_voices: bool) -> [Vec<f32>; 2] {
        let mut split = VoiceSplit::new(RATE);
        let total = RATE as usize * 2;
        let mut outputs = [Vec::new(), Vec::new()];
        for index in 0..total {
            let t = index as f32 / RATE as f32;
            let voice = (2.0 * PI * 440.0 * t).sin() * 0.5;
            let guitar = (2.0 * PI * 1300.0 * t).sin() * 0.5;
            let bass = (2.0 * PI * 55.0 * t).sin() * 0.5;
            let frame = split.process([voice + guitar + bass, voice - guitar + bass], keep_voices);
            if index >= RATE as usize {
                outputs[0].push(frame[0]);
                outputs[1].push(frame[1]);
            }
        }
        outputs
    }

    #[test]
    fn acapella_keeps_the_centre_and_drops_the_sides() {
        let [left, right] = run(true);
        assert!(level(&left, 440.0) > 0.4, "voice {}", level(&left, 440.0));
        assert!(level(&left, 1300.0) < 0.05, "guitar {}", level(&left, 1300.0));
        assert!(level(&right, 55.0) < 0.05, "bass {}", level(&right, 55.0));
    }

    #[test]
    fn instrumental_drops_the_centre_and_keeps_bass_and_sides() {
        let [left, right] = run(false);
        assert!(level(&left, 440.0) < 0.1, "voice {}", level(&left, 440.0));
        assert!(level(&left, 1300.0) > 0.4 && level(&right, 1300.0) > 0.4, "guitar {}", level(&left, 1300.0));
        assert!(level(&left, 55.0) > 0.4, "bass {}", level(&left, 55.0));
    }

    #[test]
    #[ignore]
    fn renders_a_listening_sample() {
        let source = std::path::Path::new("target/voice_sample.flac");
        let media = crate::audio::Media::of(source);
        let start = 60 * RATE as usize;
        let length = 30 * RATE as usize;
        let decoded = crate::audio::decode(&media, RATE, start + length).unwrap();
        let clip = &decoded[start * 2..];
        let write = |name: &str, samples: &[f32]| {
            let mut bytes = Vec::new();
            for sample in samples {
                bytes.extend_from_slice(&((sample.clamp(-1.0, 1.0) * 32767.0) as i16).to_le_bytes());
            }
            let mut file = b"RIFF".to_vec();
            file.extend_from_slice(&(36 + bytes.len() as u32).to_le_bytes());
            file.extend_from_slice(b"WAVEfmt ");
            for value in [16u32, 1 | (2 << 16), RATE, RATE * 4, 4 | (16 << 16)] {
                file.extend_from_slice(&value.to_le_bytes());
            }
            file.extend_from_slice(b"data");
            file.extend_from_slice(&(bytes.len() as u32).to_le_bytes());
            file.extend_from_slice(&bytes);
            std::fs::write(format!("target/voice_{name}.wav"), file).unwrap();
        };
        write("original", clip);
        for (name, keep) in [("acapella", true), ("instrumental", false)] {
            let mut split = VoiceSplit::new(RATE);
            let mut out = Vec::with_capacity(clip.len());
            for frame in clip.chunks(2) {
                out.extend_from_slice(&split.process([frame[0], frame[1]], keep));
            }
            write(name, &out);
        }
    }

    #[test]
    fn untouched_sides_come_back_whole() {
        let mut split = VoiceSplit::new(RATE);
        let delay = split.size;
        let input: Vec<f32> = (0..RATE as usize).map(|index| ((index * 7919) % 2001) as f32 / 1000.0 - 1.0).collect();
        let mut output = Vec::new();
        for sample in &input {
            output.push(split.process([*sample, -*sample], false)[0]);
        }
        let error = input[..input.len() - delay].iter().zip(&output[delay..]).map(|(a, b)| (a - b).abs()).fold(0.0f32, f32::max);
        assert!(error < 1e-3, "reconstruction error {error}");
    }
}
