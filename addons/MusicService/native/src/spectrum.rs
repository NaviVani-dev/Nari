use std::f32::consts::PI;

use crate::audio::CHANNELS;

pub const BANDS: usize = 32;
pub const WAVE: usize = 128;
pub const SNAPSHOT: usize = BANDS + WAVE + 1;
pub const STEREO_BINS: usize = 1024;
pub const STEREO_SNAPSHOT: usize = STEREO_BINS * 4;

const WINDOW: usize = 1024;
const HOP: usize = 512;
const HISTORY: usize = 64;
const LOWEST_HZ: f64 = 40.0;
const HIGHEST_HZ: f64 = 16000.0;
const FLOOR_DB: f32 = -66.0;
const HIGH_LIFT_DB: f32 = 0.9;
const STEREO_WINDOW: usize = STEREO_BINS * 2;
const STEREO_HISTORY: usize = 32;
const STEREO_IDLE_HOPS: u32 = 64;
const STEREO_GAIN: f32 = 40.0;

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
    stereo: Stereo,
    pub latency_ms: i32,
}

struct Stereo {
    left: Vec<f32>,
    right: Vec<f32>,
    real: Vec<f32>,
    imaginary: Vec<f32>,
    window: Vec<f32>,
    ring: Vec<[u8; STEREO_SNAPSHOT]>,
    quiet: [u8; STEREO_SNAPSHOT],
    filled: usize,
    written: u64,
    idle: u32,
}

impl Stereo {
    fn new() -> Self {
        let window = (0..STEREO_WINDOW)
            .map(|index| 0.5 - 0.5 * (2.0 * PI * index as f32 / (STEREO_WINDOW - 1) as f32).cos())
            .collect();
        let mut quiet = [0u8; STEREO_SNAPSHOT];
        quiet[STEREO_BINS * 2..].fill(128);
        Self {
            left: vec![0.0; STEREO_WINDOW],
            right: vec![0.0; STEREO_WINDOW],
            real: vec![0.0; STEREO_WINDOW],
            imaginary: vec![0.0; STEREO_WINDOW],
            window,
            ring: vec![quiet; STEREO_HISTORY],
            quiet,
            filled: 0,
            written: 0,
            idle: STEREO_IDLE_HOPS,
        }
    }

    fn reset(&mut self) {
        self.filled = 0;
        self.written = 0;
    }

    fn push(&mut self, left: f32, right: f32) {
        self.left[self.filled] = left;
        self.right[self.filled] = right;
        self.filled += 1;
        if self.filled == STEREO_WINDOW {
            if self.idle < STEREO_IDLE_HOPS {
                self.idle += 1;
                self.analyse();
            }
            self.left.copy_within(STEREO_BINS.., 0);
            self.right.copy_within(STEREO_BINS.., 0);
            self.filled = STEREO_BINS;
        }
    }

    fn analyse(&mut self) {
        for index in 0..STEREO_WINDOW {
            self.real[index] = self.left[index] * self.window[index];
            self.imaginary[index] = self.right[index] * self.window[index];
        }
        fft(&mut self.real, &mut self.imaginary);

        let frame = &mut self.ring[(self.written as usize) % STEREO_HISTORY];
        let level = |x: f32, y: f32| ((x * x + y * y).sqrt().sqrt() * STEREO_GAIN).min(255.0) as u8;
        for bin in 0..STEREO_BINS {
            let mirror = (STEREO_WINDOW - bin) % STEREO_WINDOW;
            let (real, imaginary) = (self.real[bin], self.imaginary[bin]);
            let (mirror_real, mirror_imaginary) = (self.real[mirror], self.imaginary[mirror]);
            frame[bin] = level((real + mirror_real) * 0.5, (imaginary - mirror_imaginary) * 0.5);
            frame[STEREO_BINS + bin] = level((imaginary + mirror_imaginary) * 0.5, (mirror_real - real) * 0.5);
            let at = STEREO_BINS + bin;
            frame[STEREO_BINS * 2 + bin] = (self.left[at].clamp(-1.0, 1.0) * 127.0 + 128.0) as u8;
            frame[STEREO_BINS * 3 + bin] = (self.right[at].clamp(-1.0, 1.0) * 127.0 + 128.0) as u8;
        }
        self.written += 1;
    }

    fn read(&mut self, latency_ms: i32, sample_rate: u32) -> [u8; STEREO_SNAPSHOT] {
        self.idle = 0;
        if self.written == 0 {
            return self.quiet;
        }
        let delay = (i64::from(latency_ms) * i64::from(sample_rate) / 1000 / STEREO_BINS as i64)
            .clamp(0, STEREO_HISTORY as i64 - 2);
        let index = self.written as i64 - 1 - delay;
        if index < 0 {
            return self.quiet;
        }
        self.ring[(index as usize) % STEREO_HISTORY]
    }
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
            stereo: Stereo::new(),
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
        self.stereo.reset();
    }

    pub fn feed(&mut self, samples: &[f32]) {
        for frame in samples.chunks(CHANNELS) {
            self.stereo.push(frame[0], frame[frame.len() - 1]);
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

    pub fn read_stereo(&mut self) -> [u8; STEREO_SNAPSHOT] {
        self.stereo.read(self.latency_ms, self.sample_rate)
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

    fn left_only(frames: usize, rate: u32, hertz: f32) -> Vec<f32> {
        (0..frames)
            .flat_map(|index| [(2.0 * PI * hertz * index as f32 / rate as f32).sin() * 0.02, 0.0])
            .collect()
    }

    #[test]
    fn the_stereo_frame_keeps_the_channels_apart() {
        let rate = 44100;
        let mut spectrum = Spectrum::new();
        spectrum.latency_ms = 0;
        spectrum.configure(rate);
        spectrum.read_stereo();
        spectrum.feed(&left_only(STEREO_WINDOW * 4, rate, 1000.0));
        let frame = spectrum.read_stereo();
        let (left, right) = frame[..STEREO_BINS * 2].split_at(STEREO_BINS);
        let peak = (0..STEREO_BINS).max_by_key(|bin| left[*bin]).unwrap();
        let expected = (1000.0 * STEREO_WINDOW as f32 / rate as f32) as usize;
        assert!(peak.abs_diff(expected) <= 1, "peak on bin {peak}, expected {expected}");
        assert!(left[peak] > 100, "left peak was {}", left[peak]);
        assert!(right.iter().all(|bin| *bin < 8), "right leaked {:?}", right.iter().max());
        assert!(frame[STEREO_BINS * 2..STEREO_BINS * 3].iter().any(|wave| *wave != 128));
        assert!(frame[STEREO_BINS * 3..].iter().all(|wave| *wave == 128));
    }

    #[test]
    fn the_stereo_frame_only_runs_while_someone_reads_it() {
        let rate = 44100;
        let mut spectrum = Spectrum::new();
        spectrum.latency_ms = 0;
        spectrum.configure(rate);
        spectrum.feed(&left_only(STEREO_WINDOW * 4, rate, 1000.0));
        assert_eq!(spectrum.stereo.written, 0);
        spectrum.read_stereo();
        spectrum.feed(&left_only(STEREO_WINDOW * 4, rate, 1000.0));
        assert!(spectrum.stereo.written > 0);
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
