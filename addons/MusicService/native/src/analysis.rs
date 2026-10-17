use ebur128::{EbuR128, Mode};
use serde_json::{json, Map, Value as Json};
use std::path::PathBuf;
use std::sync::{Mutex, OnceLock};

use crate::audio::{Media, CHANNELS};
use crate::spectrum::fft;

const RATE: u32 = 44100;
const LIMIT_SECONDS: usize = 600;
const FRAME: usize = 1024;
const HOP: usize = 256;
const KEY_DECIMATE: usize = 4;
const KEY_FRAME: usize = 8192;
const KEY_LOW_HZ: f32 = 55.0;
const KEY_HIGH_HZ: f32 = 2000.0;
const SLOWEST_BPM: f32 = 60.0;
const FASTEST_BPM: f32 = 200.0;
const USUAL_BPM: f32 = 120.0;
const PEAK_BLOCK: usize = 1024;
const POINTS: usize = 200;
const MAX_POINTS: usize = 4096;
const FILE: &str = "analysis.json";
const CACHE_LIMIT: usize = 2000;
const NOTES: [&str; 12] = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"];
const MAJOR: [f32; 12] = [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88];
const MINOR: [f32; 12] = [6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17];

static ROOT: OnceLock<PathBuf> = OnceLock::new();
static LOCK: Mutex<()> = Mutex::new(());

pub fn init(root: PathBuf) {
    let _ = ROOT.set(root);
}

#[derive(Clone, Copy)]
struct Wanted {
    bpm: bool,
    key: bool,
    loudness: bool,
    waveform: Option<usize>,
}

impl Wanted {
    fn of(options: &Json) -> Self {
        let chosen = |name: &str| options.get(name).is_some_and(|value| !value.is_null() && value != &json!(false));
        let everything = !["bpm", "key", "loudness", "waveform"].into_iter().any(chosen);
        let flag = |name: &str| everything || chosen(name);
        Self {
            bpm: flag("bpm"),
            key: flag("key"),
            loudness: flag("loudness"),
            waveform: flag("waveform").then(|| options["waveform"].as_u64().map_or(POINTS, |points| points as usize).clamp(1, MAX_POINTS)),
        }
    }

    fn missing(self, cached: &Json) -> Self {
        Self {
            bpm: self.bpm && cached.get("bpm").is_none(),
            key: self.key && cached.get("key").is_none(),
            loudness: self.loudness && cached.get("loudness").is_none(),
            waveform: self.waveform.filter(|points| cached["waveform"].as_array().is_none_or(|peaks| peaks.len() != *points)),
        }
    }

    fn any(self) -> bool {
        self.bpm || self.key || self.loudness || self.waveform.is_some()
    }
}

pub fn analyze(uri: &str, options: &Json) -> Result<Json, String> {
    let wanted = Wanted::of(options);
    let key = cache_key(uri);
    let mut result = cached(&key);
    let missing = wanted.missing(&result);
    if missing.any() {
        let fresh = measure(uri, missing)?;
        for (name, value) in fresh.as_object().into_iter().flatten() {
            result[name] = value.clone();
        }
        store(&key, &result);
    }
    let mut shown = Map::new();
    let pick = |names: &[&str], shown: &mut Map<String, Json>| {
        for name in names {
            if let Some(value) = result.get(*name).filter(|value| !value.is_null()) {
                shown.insert((*name).into(), value.clone());
            }
        }
    };
    if wanted.bpm {
        pick(&["bpm", "confidence"], &mut shown);
    }
    if wanted.key {
        pick(&["key", "camelot"], &mut shown);
    }
    if wanted.loudness {
        pick(&["loudness"], &mut shown);
    }
    if wanted.waveform.is_some() {
        pick(&["waveform"], &mut shown);
    }
    Ok(Json::Object(shown))
}

fn measure(uri: &str, wanted: Wanted) -> Result<Json, String> {
    let media = Media { uri: uri.to_owned(), name: uri.rsplit(['/', '\\']).next().unwrap_or(uri).to_owned() };
    let mut meter = wanted
        .loudness
        .then(|| EbuR128::new(CHANNELS as u32, RATE, Mode::I | Mode::LRA | Mode::SAMPLE_PEAK).map_err(|error| error.to_string()))
        .transpose()?;
    let mut onsets = Onsets::new();
    let mut chroma = Chroma::new();
    let mut peaks = Vec::new();
    let mut block = (0.0f32, 0usize);
    crate::audio::decode_each(&media, RATE, LIMIT_SECONDS * RATE as usize, |chunk| {
        if let Some(meter) = meter.as_mut() {
            let _ = meter.add_frames_f32(chunk);
        }
        for frame in chunk.chunks_exact(CHANNELS) {
            let mono = (frame[0] + frame[1]) * 0.5;
            if wanted.bpm {
                onsets.push(mono);
            }
            if wanted.key {
                chroma.push(mono);
            }
            if wanted.waveform.is_some() {
                block.0 = block.0.max(mono.abs());
                block.1 += 1;
                if block.1 == PEAK_BLOCK {
                    peaks.push(block.0);
                    block = (0.0, 0);
                }
            }
        }
    })?;
    if block.1 > 0 {
        peaks.push(block.0);
    }
    let mut result = Map::new();
    if wanted.bpm {
        let (bpm, confidence) = tempo(&onsets.envelope, HOP as f32 / RATE as f32).unwrap_or((0.0, 0.0));
        result.insert("bpm".into(), json!((f64::from(bpm) * 10.0).round() / 10.0));
        result.insert("confidence".into(), json!((f64::from(confidence) * 100.0).round() / 100.0));
    }
    if wanted.key {
        match chroma.key() {
            Some((tonic, minor)) => {
                result.insert("key".into(), json!(format!("{} {}", NOTES[tonic], if minor { "minor" } else { "major" })));
                result.insert("camelot".into(), json!(camelot(tonic, minor)));
            }
            None => {
                result.insert("key".into(), Json::Null);
            }
        }
    }
    if let Some(meter) = meter {
        let decibels = |value: f64| if value.is_finite() { (value * 10.0).round() / 10.0 } else { -70.0 };
        let peak = (0..CHANNELS as u32).filter_map(|channel| meter.sample_peak(channel).ok()).fold(0.0f64, f64::max);
        result.insert(
            "loudness".into(),
            json!({
                "integrated": decibels(meter.loudness_global().unwrap_or(f64::NEG_INFINITY)),
                "range": decibels(meter.loudness_range().unwrap_or(0.0)),
                "peak": decibels(20.0 * peak.max(1e-9).log10()),
            }),
        );
    }
    if let Some(points) = wanted.waveform {
        result.insert("waveform".into(), json!(reduce(&peaks, points)));
    }
    Ok(Json::Object(result))
}

struct Onsets {
    pending: Vec<f32>,
    window: Vec<f32>,
    previous: Vec<f32>,
    envelope: Vec<f32>,
}

impl Onsets {
    fn new() -> Self {
        Self { pending: Vec::with_capacity(FRAME * 2), window: hann(FRAME), previous: vec![0.0; FRAME / 2], envelope: Vec::new() }
    }

    fn push(&mut self, sample: f32) {
        self.pending.push(sample);
        if self.pending.len() < FRAME {
            return;
        }
        let magnitudes = spectrum(&self.pending[..FRAME], &self.window);
        let flux: f32 = magnitudes
            .iter()
            .zip(&self.previous)
            .map(|(now, before)| ((1.0 + 100.0 * now).ln() - (1.0 + 100.0 * before).ln()).max(0.0))
            .sum();
        self.previous = magnitudes;
        self.envelope.push(flux);
        self.pending.drain(..HOP);
    }
}

struct Chroma {
    pending: Vec<f32>,
    sum: (f32, usize),
    window: Vec<f32>,
    classes: [f32; 12],
}

impl Chroma {
    fn new() -> Self {
        Self { pending: Vec::with_capacity(KEY_FRAME * 2), sum: (0.0, 0), window: hann(KEY_FRAME), classes: [0.0; 12] }
    }

    fn push(&mut self, sample: f32) {
        self.sum.0 += sample;
        self.sum.1 += 1;
        if self.sum.1 < KEY_DECIMATE {
            return;
        }
        self.pending.push(self.sum.0 / KEY_DECIMATE as f32);
        self.sum = (0.0, 0);
        if self.pending.len() < KEY_FRAME {
            return;
        }
        let magnitudes = spectrum(&self.pending[..KEY_FRAME], &self.window);
        let bin_hz = (RATE as usize / KEY_DECIMATE) as f32 / KEY_FRAME as f32;
        for (bin, magnitude) in magnitudes.iter().enumerate().skip(1) {
            let hz = bin as f32 * bin_hz;
            if !(KEY_LOW_HZ..=KEY_HIGH_HZ).contains(&hz) {
                continue;
            }
            let note = (12.0 * (hz / 440.0).log2() + 69.0).round() as i32;
            self.classes[note.rem_euclid(12) as usize] += magnitude;
        }
        self.pending.drain(..KEY_FRAME / 2);
    }

    fn key(&self) -> Option<(usize, bool)> {
        if self.classes.iter().sum::<f32>() <= f32::EPSILON {
            return None;
        }
        let mut best = (f32::MIN, 0, false);
        for tonic in 0..12 {
            for (profile, minor) in [(&MAJOR, false), (&MINOR, true)] {
                let rotated: Vec<f32> = (0..12).map(|class| profile[(class + 12 - tonic) % 12]).collect();
                let score = correlation(&self.classes, &rotated);
                if score > best.0 {
                    best = (score, tonic, minor);
                }
            }
        }
        Some((best.1, best.2))
    }
}

fn hann(size: usize) -> Vec<f32> {
    (0..size).map(|index| 0.5 - 0.5 * (2.0 * std::f32::consts::PI * index as f32 / (size - 1) as f32).cos()).collect()
}

fn spectrum(samples: &[f32], window: &[f32]) -> Vec<f32> {
    let mut real: Vec<f32> = samples.iter().zip(window).map(|(sample, weight)| sample * weight).collect();
    let mut imaginary = vec![0.0; real.len()];
    fft(&mut real, &mut imaginary);
    let scale = 2.0 / real.len() as f32;
    (0..real.len() / 2).map(|bin| (real[bin] * real[bin] + imaginary[bin] * imaginary[bin]).sqrt() * scale).collect()
}

fn correlation(left: &[f32], right: &[f32]) -> f32 {
    let mean = |values: &[f32]| values.iter().sum::<f32>() / values.len() as f32;
    let (left_mean, right_mean) = (mean(left), mean(right));
    let (mut product, mut left_power, mut right_power) = (0.0, 0.0, 0.0);
    for (a, b) in left.iter().zip(right) {
        product += (a - left_mean) * (b - right_mean);
        left_power += (a - left_mean) * (a - left_mean);
        right_power += (b - right_mean) * (b - right_mean);
    }
    product / (left_power * right_power).sqrt().max(f32::EPSILON)
}

fn tempo(envelope: &[f32], hop_seconds: f32) -> Option<(f32, f32)> {
    let shortest = (60.0 / FASTEST_BPM / hop_seconds).floor() as usize;
    let longest = (60.0 / SLOWEST_BPM / hop_seconds).ceil() as usize;
    if envelope.len() < longest * 4 {
        return None;
    }
    let mean = envelope.iter().sum::<f32>() / envelope.len() as f32;
    let centered: Vec<f32> = envelope.iter().map(|value| value - mean).collect();
    let energy: f32 = centered.iter().map(|value| value * value).sum::<f32>() / centered.len() as f32;
    if energy <= f32::EPSILON {
        return None;
    }
    let lagged = |lag: usize| centered.iter().zip(&centered[lag..]).map(|(a, b)| a * b).sum::<f32>() / (centered.len() - lag) as f32;
    let scores: Vec<f32> = (0..=longest + 1).map(|lag| if lag < shortest - 1 { 0.0 } else { lagged(lag) }).collect();
    let preference = |lag: usize| {
        let octaves = (60.0 / (lag as f32 * hop_seconds) / USUAL_BPM).log2();
        (-0.5 * octaves * octaves).exp()
    };
    let best = (shortest..=longest).max_by(|a, b| (scores[*a] * preference(*a)).total_cmp(&(scores[*b] * preference(*b))))?;
    let (before, here, after) = (scores[best - 1], scores[best], scores[best + 1]);
    let curve = before - 2.0 * here + after;
    let shift = if curve.abs() > f32::EPSILON { (0.5 * (before - after) / curve).clamp(-0.5, 0.5) } else { 0.0 };
    let bpm = 60.0 / ((best as f32 + shift) * hop_seconds);
    Some((bpm, (here / energy).clamp(0.0, 1.0)))
}

fn camelot(tonic: usize, minor: bool) -> String {
    let major = if minor { (tonic + 3) % 12 } else { tonic };
    format!("{}{}", (major * 7 % 12 + 7) % 12 + 1, if minor { "A" } else { "B" })
}

fn reduce(peaks: &[f32], points: usize) -> Vec<f64> {
    if peaks.is_empty() {
        return vec![0.0; points];
    }
    (0..points)
        .map(|point| {
            let start = point * peaks.len() / points;
            let end = ((point + 1) * peaks.len() / points).max(start + 1).min(peaks.len());
            let peak = peaks[start.min(peaks.len() - 1)..end].iter().fold(0.0f32, |top, value| top.max(*value));
            (f64::from(peak.min(1.0)) * 1000.0).round() / 1000.0
        })
        .collect()
}

fn cache_key(uri: &str) -> String {
    match std::fs::metadata(uri) {
        Ok(meta) => {
            let modified = meta.modified().ok().and_then(|time| time.duration_since(std::time::UNIX_EPOCH).ok()).map_or(0, |age| age.as_secs());
            format!("{uri}|{}|{modified}", meta.len())
        }
        Err(_) => uri.to_owned(),
    }
}

fn read() -> Map<String, Json> {
    ROOT.get()
        .and_then(|root| std::fs::read_to_string(root.join(FILE)).ok())
        .and_then(|text| serde_json::from_str(&text).ok())
        .unwrap_or_default()
}

fn cached(key: &str) -> Json {
    let _guard = LOCK.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    read().get(key).cloned().unwrap_or_else(|| json!({}))
}

fn store(key: &str, result: &Json) {
    let Some(root) = ROOT.get() else {
        return;
    };
    let _guard = LOCK.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    let mut all = read();
    let mut entry = result.clone();
    entry["at"] = json!(std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_or(0, |age| age.as_secs()));
    all.insert(key.to_owned(), entry);
    if all.len() > CACHE_LIMIT {
        let mut ages: Vec<(u64, String)> = all.iter().map(|(key, entry)| (entry["at"].as_u64().unwrap_or(0), key.clone())).collect();
        ages.sort();
        for (_, old) in ages.into_iter().take(all.len() - CACHE_LIMIT) {
            all.remove(&old);
        }
    }
    let _ = crate::storage::write_atomically(&root.join(FILE), Json::Object(all).to_string().as_bytes());
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::f32::consts::PI;

    fn write_wav(path: &std::path::Path, samples: &[f32]) {
        let mut bytes = Vec::new();
        let data = (samples.len() * 2 * 2) as u32;
        bytes.extend_from_slice(b"RIFF");
        bytes.extend_from_slice(&(36 + data).to_le_bytes());
        bytes.extend_from_slice(b"WAVEfmt ");
        for value in [16u32, 1 | (2 << 16), RATE, RATE * 4, 4 | (16 << 16)] {
            bytes.extend_from_slice(&value.to_le_bytes());
        }
        bytes.extend_from_slice(b"data");
        bytes.extend_from_slice(&data.to_le_bytes());
        for sample in samples {
            let value = (sample.clamp(-1.0, 1.0) * 32767.0) as i16;
            bytes.extend_from_slice(&value.to_le_bytes());
            bytes.extend_from_slice(&value.to_le_bytes());
        }
        std::fs::write(path, bytes).unwrap();
    }

    fn signal(seconds: f32, make: impl Fn(f32) -> f32) -> Vec<f32> {
        (0..(seconds * RATE as f32) as usize).map(|index| make(index as f32 / RATE as f32)).collect()
    }

    #[test]
    fn measures_tempo_key_loudness_and_shape() {
        let folder = std::env::temp_dir().join(format!("nari-analysis-{}", std::process::id()));
        std::fs::create_dir_all(&folder).unwrap();
        let clicks = folder.join("clicks.wav");
        write_wav(&clicks, &signal(30.0, |time| {
            let since = time % 0.5;
            if since < 0.02 { (2.0 * PI * 1000.0 * time).sin() * (1.0 - since / 0.02) * 0.8 } else { 0.0 }
        }));
        let chord = folder.join("chord.wav");
        write_wav(&chord, &signal(8.0, |time| [261.63, 329.63, 392.0].iter().map(|hz| (2.0 * PI * hz * time).sin() * 0.2).sum()));
        let quiet = folder.join("quiet.wav");
        let amplitude = 10f32.powf(-23.0 / 20.0);
        write_wav(&quiet, &signal(10.0, |time| (2.0 * PI * 1000.0 * time).sin() * amplitude));
        let path = |file: &std::path::Path| file.to_string_lossy().into_owned();

        let tempo = analyze(&path(&clicks), &json!({ "bpm": true, "waveform": 30 })).unwrap();
        let bpm = tempo["bpm"].as_f64().unwrap();
        assert!((bpm - 120.0).abs() <= 1.0, "bpm was {bpm}");
        assert!(tempo["confidence"].as_f64().unwrap() > 0.3);
        assert!(tempo.get("key").is_none() && tempo["waveform"].as_array().unwrap().len() == 30);

        let key = analyze(&path(&chord), &json!({ "key": true })).unwrap();
        assert_eq!(key["key"], "C major");
        assert_eq!(key["camelot"], "8B");

        let loudness = analyze(&path(&quiet), &json!({ "loudness": true })).unwrap();
        let integrated = loudness["loudness"]["integrated"].as_f64().unwrap();
        assert!((integrated + 23.0).abs() <= 0.5, "loudness was {integrated}");

        let everything = analyze(&path(&chord), &json!({})).unwrap();
        assert!(everything.get("bpm").is_some() && everything.get("loudness").is_some() && everything["waveform"].as_array().unwrap().len() == POINTS);

        assert_eq!(camelot(9, true), "8A");
        assert_eq!(camelot(5, false), "7B");
        assert_eq!(camelot(7, false), "9B");
        assert!(analyze("/nowhere/missing.mp3", &json!({})).is_err());
        std::fs::remove_dir_all(folder).unwrap();
    }

    #[test]
    fn results_are_cached_per_file() {
        let folder = std::env::temp_dir().join(format!("nari-analysis-cache-{}", std::process::id()));
        std::fs::create_dir_all(&folder).unwrap();
        let _ = ROOT.set(folder.clone());
        let song = folder.join("song.wav");
        write_wav(&song, &signal(3.0, |time| (2.0 * PI * 440.0 * time).sin() * 0.5));
        let uri = song.to_string_lossy().into_owned();
        let first = analyze(&uri, &json!({ "waveform": 10 })).unwrap();
        std::fs::write(&song, b"not audio anymore").unwrap();
        let key = cache_key(&uri);
        let mut all = read();
        all.insert(key, json!({ "waveform": first["waveform"].clone() }));
        std::fs::write(folder.join(FILE), Json::Object(all).to_string()).unwrap();
        assert_eq!(analyze(&uri, &json!({ "waveform": 10 })).unwrap(), first);
        assert!(analyze(&uri, &json!({ "waveform": 11 })).is_err());
        std::fs::remove_dir_all(folder).unwrap();
    }
}
