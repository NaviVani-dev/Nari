use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use cpal::{FromSample, SizedSample};
use serde_json::Value;
use signalsmith_stretch::Stretch;
use std::collections::VecDeque;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::Sender;
use std::sync::{Arc, Mutex};

use crate::audio::{Media, CHANNELS};
use crate::effects::{Chain, Effect};
use crate::events::Event;

pub const SLOTS: usize = 180;
pub const RATE: u32 = 44100;
const WAVE: usize = 128;
const WAVE_OFFSET: usize = 32;
const LOUDNESS_OFFSET: usize = WAVE_OFFSET + WAVE;
const LEVEL_OFFSET: usize = LOUDNESS_OFFSET + 1;
pub const FRAME_BYTES: usize = LEVEL_OFFSET + SLOTS;
const MAX_FRAMES: usize = RATE as usize * 10;
const PENDING_SLOT: i32 = -1;
const EDIT_SLOT: i32 = -2;
const BLOCK: f32 = 512.0;
const CACHED_SOUNDS: usize = 48;
const HEADER_BYTES: usize = 44;
const LEVEL_DECAY: f32 = 0.72;
const TARGET_PEAK: f32 = 32767.0 * 0.95;
const MAX_RECORD_GAIN: f32 = 4.0;
const KNEE: f32 = 0.75;
const OUTPUT_SCALE: f32 = 32000.0 / 32768.0;
const MIN_FACTOR: f32 = 0.25;
const MAX_FACTOR: f32 = 4.0;
const NEUTRAL: f32 = 0.001;

struct Voice {
    slot: i32,
    samples: Arc<Vec<i16>>,
    looped: bool,
    position: f64,
    playing: bool,
    level: f32,
}

struct Mix {
    voices: Vec<Voice>,
    levels: [f32; SLOTS],
    frame: [u8; FRAME_BYTES],
    capturing: bool,
}

impl Mix {
    fn new() -> Self {
        Self {
            voices: Vec::new(),
            levels: [0.0; SLOTS],
            frame: quiet_frame(),
            capturing: false,
        }
    }

    fn stop(&mut self, slot: i32) {
        self.voices.retain(|voice| voice.slot != slot);
    }

    fn publish_wave(&mut self, samples: &[f32]) {
        if samples.is_empty() {
            return;
        }
        let mut loudest = 0.0f32;
        for index in 0..WAVE {
            let sample = samples[index * samples.len() / WAVE];
            loudest = loudest.max(sample.abs());
            self.frame[WAVE_OFFSET + index] = ((sample * 127.0) + 128.0).clamp(0.0, 255.0) as u8;
        }
        self.frame[LOUDNESS_OFFSET] = (loudest * 255.0).clamp(0.0, 255.0) as u8;
    }

    fn render(&mut self, output: &mut [f32], step: f64) {
        let mut active = false;
        for voice in self.voices.iter_mut().filter(|voice| voice.playing) {
            active = true;
            let length = voice.samples.len();
            let mut peak = 0.0f32;
            for sample in output.iter_mut() {
                if voice.position >= length as f64 {
                    if !voice.looped {
                        break;
                    }
                    voice.position = 0.0;
                }
                let low = voice.position as usize;
                let high = (low + 1).min(length - 1);
                let blend = (voice.position - low as f64) as f32;
                let value = (f32::from(voice.samples[low])
                    + (f32::from(voice.samples[high]) - f32::from(voice.samples[low])) * blend)
                    / 32768.0;
                *sample += value;
                peak = peak.max(value.abs());
                voice.position += step;
            }
            voice.level = peak;
        }
        self.voices
            .retain(|voice| voice.looped || voice.position < voice.samples.len() as f64);
        for sample in output.iter_mut() {
            *sample = limit(*sample) * OUTPUT_SCALE;
        }
        if !self.capturing {
            self.publish_wave(output);
        }
        let decay = LEVEL_DECAY.powf(output.len() as f32 / (BLOCK / step as f32));
        for level in self.levels.iter_mut() {
            *level *= decay;
        }
        if active {
            for voice in &self.voices {
                if let Ok(slot) = usize::try_from(voice.slot) {
                    if slot < SLOTS && voice.level > self.levels[slot] {
                        self.levels[slot] = voice.level;
                    }
                }
            }
        }
        for (slot, level) in self.levels.iter().enumerate() {
            self.frame[LEVEL_OFFSET + slot] = (level * 255.0).clamp(0.0, 255.0) as u8;
        }
    }
}

struct Capture {
    _stream: cpal::Stream,
    samples: Arc<Mutex<Vec<i16>>>,
    stop: Arc<AtomicBool>,
}

pub struct Soundboard {
    folder: PathBuf,
    events: Sender<Event>,
    mix: Arc<Mutex<Mix>>,
    output: Option<cpal::Stream>,
    lost: Arc<AtomicBool>,
    wanted: bool,
    cache: VecDeque<(i32, Arc<Vec<i16>>)>,
    capture: Option<Capture>,
    edit: Option<usize>,
}

impl Soundboard {
    pub fn new(folder: PathBuf, events: Sender<Event>) -> Self {
        let _ = std::fs::create_dir_all(&folder);
        Self {
            folder,
            events,
            mix: Arc::new(Mutex::new(Mix::new())),
            output: None,
            lost: Arc::new(AtomicBool::new(false)),
            wanted: false,
            cache: VecDeque::new(),
            capture: None,
            edit: None,
        }
    }

    pub fn slots_json(&self) -> String {
        let names: std::collections::HashSet<String> = std::fs::read_dir(&self.folder)
            .into_iter()
            .flatten()
            .flatten()
            .map(|entry| entry.file_name().to_string_lossy().into_owned())
            .collect();
        Value::from(
            (0..SLOTS)
                .filter(|slot| names.contains(&format!("{slot}.wav")))
                .collect::<Vec<_>>(),
        )
        .to_string()
    }

    pub fn frame(&self) -> [u8; FRAME_BYTES] {
        self.mix.lock().map(|mix| mix.frame).unwrap_or_else(|_| quiet_frame())
    }

    pub fn set_active(&mut self, active: bool) {
        self.wanted = active;
        if active {
            self.start_output();
        }
    }

    pub fn play(&mut self, slot: i32) {
        let Some(samples) = self.load(slot) else {
            return;
        };
        self.add_voice(slot, samples, false, 0.0, true);
    }

    pub fn delete(&mut self, slot: i32) {
        let _ = std::fs::remove_file(self.slot_file(slot));
        self.forget(slot);
        self.stop_voices(slot);
    }

    pub fn swap(&mut self, from: i32, to: i32) -> bool {
        if from == to || !valid(from) || !valid(to) {
            return false;
        }
        let source = self.slot_file(from);
        if !source.exists() {
            return false;
        }
        let target = self.slot_file(to);
        let swap = self.folder.join("swap.wav");
        let _ = std::fs::remove_file(&swap);
        if target.exists() {
            let _ = std::fs::rename(&target, &swap);
        }
        let _ = std::fs::rename(&source, &target);
        if swap.exists() {
            let _ = std::fs::rename(&swap, &source);
        }
        self.forget(from);
        self.forget(to);
        self.stop_voices(from);
        self.stop_voices(to);
        true
    }

    pub fn start_recording(&mut self) -> bool {
        if self.capture.is_some() || !crate::audio::available() {
            return false;
        }
        let Some(device) = cpal::default_host().default_input_device() else {
            return false;
        };
        let Ok(supported) = device.default_input_config() else {
            return false;
        };
        let format = supported.sample_format();
        let config: cpal::StreamConfig = supported.into();
        let samples = Arc::new(Mutex::new(Vec::with_capacity(MAX_FRAMES)));
        let stop = Arc::new(AtomicBool::new(false));
        let stream = match format {
            cpal::SampleFormat::I16 => record::<i16>(&device, &config, &samples, &stop, &self.mix),
            cpal::SampleFormat::U16 => record::<u16>(&device, &config, &samples, &stop, &self.mix),
            _ => record::<f32>(&device, &config, &samples, &stop, &self.mix),
        };
        let Some(stream) = stream else {
            return false;
        };
        if stream.play().is_err() {
            return false;
        }
        if let Ok(mut mix) = self.mix.lock() {
            mix.capturing = true;
        }
        self.capture = Some(Capture {
            _stream: stream,
            samples,
            stop,
        });
        true
    }

    pub fn stop_recording(&mut self) {
        if let Some(capture) = self.capture.as_ref() {
            capture.stop.store(true, Ordering::SeqCst);
        }
    }

    pub fn is_recording(&self) -> bool {
        self.capture.is_some()
    }

    pub fn import(&self, uri: String, name: String) {
        let pending = self.pending_file();
        let events = self.events.clone();
        std::thread::spawn(move || {
            let decoded = crate::audio::decode(&Media { uri, name }, RATE, MAX_FRAMES)
                .map(|stereo| mono(&stereo))
                .ok()
                .filter(|samples| !samples.is_empty());
            let saved = decoded.is_some_and(|samples| write_wav(&pending, &samples));
            let _ = events.send(Event::SoundboardCaptured(saved));
        });
    }

    pub fn commit_pending(&mut self, slot: i32) -> bool {
        let pending = self.pending_file();
        if !pending.exists() || !valid(slot) {
            return false;
        }
        let target = self.slot_file(slot);
        let _ = std::fs::remove_file(&target);
        self.forget(slot);
        std::fs::rename(&pending, &target).is_ok()
    }

    pub fn discard_pending(&mut self) {
        let _ = std::fs::remove_file(self.pending_file());
        self.stop_voices(PENDING_SLOT);
    }

    pub fn play_pending(&mut self) {
        let Some(samples) = read_wav(&self.pending_file()) else {
            return;
        };
        self.add_voice(PENDING_SLOT, Arc::new(samples), false, 0.0, true);
    }

    pub fn start_edit(&mut self, slot: i32, effect: &str, speed: f32, pitch: f32) -> bool {
        let Some(source) = read_wav(&self.slot_file(slot)) else {
            return false;
        };
        let rendered = render(&source, effect, speed, pitch);
        let (position, playing) = self
            .mix
            .lock()
            .ok()
            .and_then(|mix| {
                mix.voices
                    .iter()
                    .find(|voice| voice.slot == EDIT_SLOT)
                    .map(|voice| {
                        (
                            voice.position * rendered.len() as f64 / voice.samples.len().max(1) as f64,
                            voice.playing,
                        )
                    })
            })
            .unwrap_or((0.0, true));
        self.edit = Some(rendered.len());
        self.add_voice(EDIT_SLOT, Arc::new(rendered), true, position, playing);
        true
    }

    pub fn set_edit_playing(&mut self, playing: bool) {
        self.edit_voice(|voice| voice.playing = playing);
    }

    pub fn seek_edit(&mut self, position_ms: i32) {
        self.edit_voice(|voice| {
            let last = voice.samples.len().saturating_sub(1) as f64;
            voice.position = (f64::from(position_ms.max(0)) * f64::from(RATE) / 1000.0).min(last);
        });
    }

    pub fn edit_position_ms(&self) -> i32 {
        self.mix
            .lock()
            .ok()
            .and_then(|mix| {
                mix.voices
                    .iter()
                    .find(|voice| voice.slot == EDIT_SLOT)
                    .map(|voice| (voice.position * 1000.0 / f64::from(RATE)) as i32)
            })
            .unwrap_or(0)
    }

    pub fn edit_duration_ms(&self) -> i32 {
        self.edit
            .map(|length| (length as u64 * 1000 / u64::from(RATE)) as i32)
            .unwrap_or(0)
    }

    pub fn stop_edit(&mut self) {
        self.edit = None;
        self.stop_voices(EDIT_SLOT);
    }

    pub fn save_edit(&mut self, slot: i32, effect: &str, speed: f32, pitch: f32) -> bool {
        let Some(source) = read_wav(&self.slot_file(slot)) else {
            return false;
        };
        let saved = write_wav(&self.slot_file(slot), &render(&source, effect, speed, pitch));
        self.forget(slot);
        self.stop_edit();
        saved
    }

    pub fn tick(&mut self) -> Option<bool> {
        if self.lost.swap(false, Ordering::Relaxed) {
            self.output = None;
            self.start_output();
        }
        if self.output.is_some() && !self.wanted {
            let idle = self.mix.lock().map(|mix| mix.voices.is_empty()).unwrap_or(true);
            if idle {
                self.release();
            }
        }
        let capture = self.capture.as_ref()?;
        let full = capture.samples.lock().map(|samples| samples.len() >= MAX_FRAMES).unwrap_or(true);
        if !full && !capture.stop.load(Ordering::SeqCst) {
            return None;
        }
        let capture = self.capture.take()?;
        drop(capture._stream);
        let mut samples = capture.samples.lock().map(|samples| samples.clone()).unwrap_or_default();
        samples.truncate(MAX_FRAMES);
        if let Ok(mut mix) = self.mix.lock() {
            mix.capturing = false;
        }
        normalize(&mut samples);
        Some(!samples.is_empty() && write_wav(&self.pending_file(), &samples))
    }

    pub fn shutdown(&mut self) {
        self.stop_recording();
        self.capture = None;
        self.wanted = false;
        self.release();
    }

    fn add_voice(&mut self, slot: i32, samples: Arc<Vec<i16>>, looped: bool, position: f64, playing: bool) {
        if samples.is_empty() {
            return;
        }
        if let Ok(mut mix) = self.mix.lock() {
            mix.stop(slot);
            mix.voices.push(Voice {
                slot,
                samples,
                looped,
                position,
                playing,
                level: 0.0,
            });
        }
        self.start_output();
    }

    fn edit_voice(&mut self, change: impl FnOnce(&mut Voice)) {
        if let Ok(mut mix) = self.mix.lock() {
            if let Some(voice) = mix.voices.iter_mut().find(|voice| voice.slot == EDIT_SLOT) {
                change(voice);
            }
        }
    }

    fn stop_voices(&mut self, slot: i32) {
        if let Ok(mut mix) = self.mix.lock() {
            mix.stop(slot);
        }
    }

    fn start_output(&mut self) {
        if self.output.is_some() || !crate::audio::available() {
            return;
        }
        let Some(device) = cpal::default_host().default_output_device() else {
            return;
        };
        let Ok(supported) = device.default_output_config() else {
            return;
        };
        let format = supported.sample_format();
        let config: cpal::StreamConfig = supported.into();
        let stream = match format {
            cpal::SampleFormat::I16 => play::<i16>(&device, &config, &self.mix, &self.lost),
            cpal::SampleFormat::U16 => play::<u16>(&device, &config, &self.mix, &self.lost),
            _ => play::<f32>(&device, &config, &self.mix, &self.lost),
        };
        if let Some(stream) = stream.filter(|stream| stream.play().is_ok()) {
            self.output = Some(stream);
        }
    }

    fn release(&mut self) {
        self.output = None;
        self.edit = None;
        if let Ok(mut mix) = self.mix.lock() {
            let capturing = mix.capturing;
            *mix = Mix::new();
            mix.capturing = capturing;
        }
    }

    fn load(&mut self, slot: i32) -> Option<Arc<Vec<i16>>> {
        if let Some(index) = self.cache.iter().position(|(cached, _)| *cached == slot) {
            let entry = self.cache.remove(index)?;
            let samples = entry.1.clone();
            self.cache.push_back(entry);
            return Some(samples);
        }
        let samples = Arc::new(read_wav(&self.slot_file(slot))?);
        self.cache.push_back((slot, samples.clone()));
        if self.cache.len() > CACHED_SOUNDS {
            self.cache.pop_front();
        }
        Some(samples)
    }

    fn forget(&mut self, slot: i32) {
        self.cache.retain(|(cached, _)| *cached != slot);
    }

    fn slot_file(&self, slot: i32) -> PathBuf {
        self.folder.join(format!("{slot}.wav"))
    }

    fn pending_file(&self) -> PathBuf {
        self.folder.join("pending.wav")
    }
}

fn valid(slot: i32) -> bool {
    usize::try_from(slot).is_ok_and(|slot| slot < SLOTS)
}

fn quiet_frame() -> [u8; FRAME_BYTES] {
    let mut frame = [0u8; FRAME_BYTES];
    frame[WAVE_OFFSET..LOUDNESS_OFFSET].fill(128);
    frame
}

fn play<T>(
    device: &cpal::Device,
    config: &cpal::StreamConfig,
    mix: &Arc<Mutex<Mix>>,
    lost: &Arc<AtomicBool>,
) -> Option<cpal::Stream>
where
    T: SizedSample + FromSample<f32>,
{
    let channels = usize::from(config.channels).max(1);
    let step = f64::from(RATE) / f64::from(config.sample_rate);
    let mix = mix.clone();
    let lost = lost.clone();
    let mut mono: Vec<f32> = Vec::new();
    device
        .build_output_stream(
            config.clone(),
            move |output: &mut [T], _| {
                let frames = output.len() / channels;
                mono.clear();
                mono.resize(frames, 0.0);
                if let Ok(mut mix) = mix.try_lock() {
                    mix.render(&mut mono, step);
                }
                let volume = crate::audio::app_volume();
                for (frame, value) in output.chunks_mut(channels).zip(mono.iter()) {
                    for sample in frame {
                        *sample = T::from_sample(*value * volume);
                    }
                }
            },
            move |error: cpal::Error| {
                if matches!(
                    error.kind(),
                    cpal::ErrorKind::DeviceNotAvailable | cpal::ErrorKind::StreamInvalidated
                ) {
                    lost.store(true, Ordering::Relaxed);
                }
            },
            None,
        )
        .ok()
}

fn record<T>(
    device: &cpal::Device,
    config: &cpal::StreamConfig,
    samples: &Arc<Mutex<Vec<i16>>>,
    stop: &Arc<AtomicBool>,
    mix: &Arc<Mutex<Mix>>,
) -> Option<cpal::Stream>
where
    T: SizedSample,
    f32: FromSample<T>,
{
    let channels = usize::from(config.channels).max(1);
    let step = f64::from(config.sample_rate) / f64::from(RATE);
    let (samples, stop, mix) = (samples.clone(), stop.clone(), mix.clone());
    let mut cursor = 0.0f64;
    let mut carry: Vec<f32> = Vec::new();
    device
        .build_input_stream(
            config.clone(),
            move |input: &[T], _| {
                if stop.load(Ordering::Relaxed) {
                    return;
                }
                carry.extend(input.chunks(channels).map(|frame| {
                    frame.iter().map(|sample| sample.to_sample::<f32>()).sum::<f32>() / channels as f32
                }));
                let mut converted = Vec::new();
                while cursor + 1.0 < carry.len() as f64 {
                    let low = cursor as usize;
                    let blend = (cursor - low as f64) as f32;
                    converted.push(carry[low] + (carry[low + 1] - carry[low]) * blend);
                    cursor += step;
                }
                let used = (cursor as usize).min(carry.len());
                carry.drain(..used);
                cursor -= used as f64;
                if let Ok(mut mix) = mix.try_lock() {
                    mix.publish_wave(&converted);
                }
                if let Ok(mut captured) = samples.lock() {
                    let room = MAX_FRAMES.saturating_sub(captured.len());
                    captured.extend(
                        converted
                            .iter()
                            .take(room)
                            .map(|value| (value * 32768.0).clamp(-32768.0, 32767.0) as i16),
                    );
                    if captured.len() >= MAX_FRAMES {
                        stop.store(true, Ordering::Relaxed);
                    }
                }
            },
            |_| {},
            None,
        )
        .ok()
}

fn limit(value: f32) -> f32 {
    let magnitude = value.abs();
    if magnitude <= KNEE {
        return value;
    }
    let shaped = KNEE + ((magnitude - KNEE) / (1.0 - KNEE)).tanh() * (1.0 - KNEE);
    shaped.copysign(value)
}

fn normalize(samples: &mut [i16]) {
    let peak = samples.iter().map(|sample| i32::from(*sample).abs()).max().unwrap_or(0);
    if peak == 0 {
        return;
    }
    let gain = (TARGET_PEAK / peak as f32).min(MAX_RECORD_GAIN);
    if gain <= 1.0 {
        return;
    }
    for sample in samples.iter_mut() {
        *sample = (f32::from(*sample) * gain).round().clamp(-32768.0, 32767.0) as i16;
    }
}

fn mono(stereo: &[f32]) -> Vec<i16> {
    stereo
        .chunks(CHANNELS)
        .map(|frame| {
            let average = frame.iter().sum::<f32>() / frame.len() as f32;
            (average * 32768.0).clamp(-32768.0, 32767.0) as i16
        })
        .collect()
}

fn clamp_factor(factor: f32) -> f32 {
    if factor.is_finite() {
        factor.clamp(MIN_FACTOR, MAX_FACTOR)
    } else {
        1.0
    }
}

fn render(source: &[i16], effect_id: &str, speed: f32, pitch: f32) -> Vec<i16> {
    let effect = Effect::from_id(effect_id).unwrap_or(Effect::None);
    let speed = clamp_factor(speed);
    let pitch = clamp_factor(pitch) * effect.pitch();
    let mut stereo: Vec<f32> = source
        .iter()
        .flat_map(|sample| {
            let value = f32::from(*sample) / 32768.0;
            [value, value]
        })
        .collect();
    if (speed - 1.0).abs() > NEUTRAL || (pitch - 1.0).abs() > NEUTRAL {
        let mut stretch = Stretch::preset_default(CHANNELS as u32, RATE);
        stretch.set_transpose_factor(pitch, None);
        let frames = ((source.len() as f32 / speed).round() as usize).max(1);
        let mut output = vec![0.0f32; frames * CHANNELS];
        if !stretch.exact(&stereo, &mut output) {
            stretch.reset();
            stretch.process(&stereo, &mut output);
        }
        stereo = output;
    }
    if effect != Effect::None {
        Chain::new(RATE).process(effect, &mut stereo);
    }
    let mut rendered = mono(&stereo);
    rendered.truncate(MAX_FRAMES);
    rendered
}

fn write_wav(path: &Path, samples: &[i16]) -> bool {
    let payload = (samples.len() * 2) as u32;
    let mut bytes = Vec::with_capacity(HEADER_BYTES + payload as usize);
    bytes.extend_from_slice(b"RIFF");
    bytes.extend_from_slice(&(36 + payload).to_le_bytes());
    bytes.extend_from_slice(b"WAVEfmt ");
    bytes.extend_from_slice(&16u32.to_le_bytes());
    bytes.extend_from_slice(&1u16.to_le_bytes());
    bytes.extend_from_slice(&1u16.to_le_bytes());
    bytes.extend_from_slice(&RATE.to_le_bytes());
    bytes.extend_from_slice(&(RATE * 2).to_le_bytes());
    bytes.extend_from_slice(&2u16.to_le_bytes());
    bytes.extend_from_slice(&16u16.to_le_bytes());
    bytes.extend_from_slice(b"data");
    bytes.extend_from_slice(&payload.to_le_bytes());
    for sample in samples {
        bytes.extend_from_slice(&sample.to_le_bytes());
    }
    std::fs::write(path, bytes).is_ok()
}

fn read_wav(path: &Path) -> Option<Vec<i16>> {
    let bytes = std::fs::read(path).ok()?;
    if bytes.len() <= HEADER_BYTES {
        return None;
    }
    Some(
        bytes[HEADER_BYTES..]
            .chunks_exact(2)
            .map(|pair| i16::from_le_bytes([pair[0], pair[1]]))
            .collect(),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn frame_layout_matches_gdscript() {
        assert_eq!(FRAME_BYTES, crate::spectrum::SNAPSHOT + SLOTS);
        assert_eq!(LEVEL_OFFSET, 161);
        let frame = quiet_frame();
        assert!(frame[WAVE_OFFSET..LOUDNESS_OFFSET].iter().all(|value| *value == 128));
    }

    #[test]
    fn wav_round_trips_with_the_android_header() {
        let path = std::env::temp_dir().join(format!("nari_sound_{}.wav", std::process::id()));
        let samples: Vec<i16> = (0..1000).map(|index| (index * 30 - 15000) as i16).collect();
        assert!(write_wav(&path, &samples));
        let bytes = std::fs::read(&path).unwrap();
        assert_eq!(&bytes[0..4], b"RIFF");
        assert_eq!(u32::from_le_bytes([bytes[24], bytes[25], bytes[26], bytes[27]]), RATE);
        assert_eq!(read_wav(&path).unwrap(), samples);
        std::fs::remove_file(&path).unwrap();
    }

    #[test]
    fn normalizing_boosts_quiet_takes_up_to_four_times() {
        let mut quiet = vec![1000i16, -500];
        normalize(&mut quiet);
        assert_eq!(quiet, vec![4000, -2000]);
        let mut loud = vec![20000i16];
        normalize(&mut loud);
        assert_eq!(loud[0], (20000.0f32 * (TARGET_PEAK / 20000.0)).round() as i16);
    }

    #[test]
    fn limiter_only_bends_above_the_knee() {
        assert_eq!(limit(0.5), 0.5);
        assert!(limit(2.0) < 1.0 && limit(2.0) > KNEE);
        assert_eq!(limit(-2.0), -limit(2.0));
    }

    #[test]
    fn rendering_changes_length_with_speed() {
        let source: Vec<i16> = (0..RATE as usize).map(|index| ((index as f32 * 0.05).sin() * 8000.0) as i16).collect();
        let faster = render(&source, "none", 2.0, 1.0);
        assert!((faster.len() as i64 - source.len() as i64 / 2).abs() < 64);
        assert_eq!(render(&source, "none", 1.0, 1.0), source);
    }
}
