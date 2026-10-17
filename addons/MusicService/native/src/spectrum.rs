use std::f32::consts::PI;

use crate::audio::CHANNELS;

pub const BANDS: usize = 32;
pub const WAVE: usize = 128;
pub const SNAPSHOT: usize = BANDS + WAVE + 1;

const WINDOW: usize = 1024;
const HOP: usize = 512;
const HISTORY: usize = 64;
const LOWEST_HZ: f64 = 40.0;
const HIGHEST_HZ: f64 = 16000.0;
const FLOOR_DB: f32 = -66.0;
const HIGH_LIFT_DB: f32 = 0.9;

pub struct Spectrum {
    samples: [f32; WINDOW],
    real: [f32; WINDOW],
    imaginary: [f32; WINDOW],
    window: [f32; WINDOW],
    edges: [usize; BANDS + 1],
    ring: Vec<[u8; SNAPSHOT]>,
    quiet: [u8; SNAPSHOT],
    filled: usize,
    sample_rate: u32,
    written: u64,
    pub latency_ms: i32,
}

impl Spectrum {
    pub fn new() -> Self {
        let mut window = [0.0f32; WINDOW];
        for (index, value) in window.iter_mut().enumerate() {
            *value = 0.5 - 0.5 * (2.0 * PI * index as f32 / (WINDOW - 1) as f32).cos();
        }
        let mut quiet = [0u8; SNAPSHOT];
        quiet[BANDS..BANDS + WAVE].fill(128);
        let mut spectrum = Self {
            samples: [0.0; WINDOW],
            real: [0.0; WINDOW],
            imaginary: [0.0; WINDOW],
            window,
            edges: [0; BANDS + 1],
            ring: vec![[0u8; SNAPSHOT]; HISTORY],
            quiet,
            filled: 0,
            sample_rate: 44100,
            written: 0,
            latency_ms: 180,
        };
        spectrum.configure(44100);
        spectrum
    }

    pub fn configure(&mut self, rate: u32) {
        self.sample_rate = if rate > 0 { rate } else { 44100 };
        let highest = HIGHEST_HZ.min(f64::from(self.sample_rate) * 0.45);
        let step = (highest / LOWEST_HZ).powf(1.0 / BANDS as f64);
        let mut previous = 0usize;
        for index in 0..=BANDS {
            let frequency = LOWEST_HZ * step.powi(index as i32);
            let bin = (frequency * WINDOW as f64 / f64::from(self.sample_rate)) as usize;
            let floor = if index == 0 { 1 } else { previous + 1 };
            previous = bin.max(floor).min(WINDOW / 2 - 1);
            self.edges[index] = previous;
        }
        self.reset();
    }

    pub fn reset(&mut self) {
        self.filled = 0;
        self.written = 0;
    }

    pub fn feed(&mut self, samples: &[f32]) {
        for frame in samples.chunks(CHANNELS) {
            let sum: f32 = frame.iter().sum();
            self.samples[self.filled] = sum / CHANNELS as f32;
            self.filled += 1;
            if self.filled == WINDOW {
                self.analyse();
                self.samples.copy_within(HOP.., 0);
                self.filled = WINDOW - HOP;
            }
        }
    }

    pub fn read(&self) -> [u8; SNAPSHOT] {
        if self.written == 0 {
            return self.quiet;
        }
        let delay = (i64::from(self.latency_ms) * i64::from(self.sample_rate) / 1000 / HOP as i64)
            .clamp(0, HISTORY as i64 - 2);
        let index = self.written as i64 - 1 - delay;
        if index < 0 {
            return self.quiet;
        }
        self.ring[(index as usize) % HISTORY]
    }

    fn analyse(&mut self) {
        for index in 0..WINDOW {
            self.real[index] = self.samples[index] * self.window[index];
            self.imaginary[index] = 0.0;
        }
        self.transform();

        let slot = (self.written as usize) % HISTORY;
        for band in 0..BANDS {
            let mut total = 0.0;
            let mut count = 0;
            let end = self.edges[band + 1].max(self.edges[band] + 1);
            for bin in self.edges[band]..end {
                total += (self.real[bin] * self.real[bin] + self.imaginary[bin] * self.imaginary[bin])
                    .sqrt();
                count += 1;
            }
            let magnitude = total / count as f32 / (WINDOW as f32 * 0.25);
            let decibels = 20.0 * (magnitude + 1e-7).log10() + band as f32 * HIGH_LIFT_DB;
            let value = ((decibels - FLOOR_DB) / -FLOOR_DB).clamp(0.0, 1.0);
            self.ring[slot][band] = (value * 255.0) as u8;
        }

        let stride = HOP / WAVE;
        for index in 0..WAVE {
            let sample = self.samples[WINDOW - HOP + index * stride].clamp(-1.0, 1.0);
            self.ring[slot][BANDS + index] = (sample * 127.0 + 128.0) as u8;
        }

        let energy: f32 = self.samples[WINDOW - HOP..]
            .iter()
            .map(|sample| sample * sample)
            .sum();
        let loudness = ((energy / HOP as f32).sqrt() * 4.0).clamp(0.0, 1.0);
        self.ring[slot][BANDS + WAVE] = (loudness * 255.0) as u8;

        self.written += 1;
    }

    fn transform(&mut self) {
        fft(&mut self.real, &mut self.imaginary);
    }
}

pub fn fft(real: &mut [f32], imaginary: &mut [f32]) {
    let size = real.len();
    let mut target = 0usize;
    for index in 1..size {
        let mut bit = size >> 1;
        while target & bit != 0 {
            target ^= bit;
            bit >>= 1;
        }
        target |= bit;
        if index < target {
            real.swap(index, target);
            imaginary.swap(index, target);
        }
    }
    let mut span = 2usize;
    while span <= size {
        let angle = -2.0 * PI / span as f32;
        let step_real = angle.cos();
        let step_imaginary = angle.sin();
        let half = span / 2;
        let mut start = 0usize;
        while start < size {
            let mut turn_real = 1.0f32;
            let mut turn_imaginary = 0.0f32;
            for offset in 0..half {
                let low = start + offset;
                let high = low + half;
                let product_real = real[high] * turn_real - imaginary[high] * turn_imaginary;
                let product_imaginary = real[high] * turn_imaginary + imaginary[high] * turn_real;
                real[high] = real[low] - product_real;
                imaginary[high] = imaginary[low] - product_imaginary;
                real[low] += product_real;
                imaginary[low] += product_imaginary;
                let next_real = turn_real * step_real - turn_imaginary * step_imaginary;
                turn_imaginary = turn_real * step_imaginary + turn_imaginary * step_real;
                turn_real = next_real;
            }
            start += span;
        }
        span <<= 1;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tone(frames: usize, rate: u32, frequency: f32, amplitude: f32) -> Vec<f32> {
        (0..frames)
            .flat_map(|frame| {
                let phase = 2.0 * PI * frequency * frame as f32 / rate as f32;
                let sample = phase.sin() * amplitude;
                [sample, sample]
            })
            .collect()
    }

    #[test]
    fn a_quiet_stream_reads_the_neutral_frame() {
        let spectrum = Spectrum::new();
        let frame = spectrum.read();
        assert_eq!(frame.len(), SNAPSHOT);
        assert_eq!(frame.len(), 161);
        assert!(frame[..BANDS].iter().all(|band| *band == 0));
        assert!(frame[BANDS..BANDS + WAVE].iter().all(|wave| *wave == 128));
        assert_eq!(frame[BANDS + WAVE], 0);
    }

    #[test]
    fn a_loud_tone_lights_up_its_band_and_the_loudness_byte() {
        let rate = 44100;
        let mut spectrum = Spectrum::new();
        spectrum.latency_ms = 0;
        spectrum.configure(rate);
        spectrum.feed(&tone(WINDOW * 4, rate, 440.0, 0.8));
        let frame = spectrum.read();
        assert!(frame[BANDS + WAVE] > 200, "loudness was {}", frame[BANDS + WAVE]);
        let loudest = (0..BANDS).max_by_key(|band| frame[*band]).unwrap();
        let expected = (0..BANDS)
            .find(|band| {
                let bin = 440.0 * WINDOW as f32 / rate as f32;
                (spectrum.edges[*band]..spectrum.edges[band + 1]).contains(&(bin as usize))
            })
            .unwrap();
        assert!(
            loudest.abs_diff(expected) <= 1,
            "peak landed on band {loudest}, expected around {expected}"
        );
    }
}
