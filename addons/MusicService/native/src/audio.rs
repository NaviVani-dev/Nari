use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use cpal::{FromSample, SizedSample};
use opus_rs::OpusDecoder;
use signalsmith_stretch::Stretch;
use rubato::audioadapter_buffers::direct::InterleavedSlice;
use rubato::{Async, FixedAsync, PolynomialDegree, Resampler};
use std::collections::VecDeque;
use std::cell::Cell;
use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64, AtomicU8, Ordering};
use std::sync::mpsc::{channel, Receiver, Sender};
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use crate::effects::{Chain, Effect, Equalizer, Rack, Stage};
use crate::spectrum::{Spectrum, SNAPSHOT};
use symphonia::core::audio::GenericAudioBufferRef;
use symphonia::core::codecs::audio::well_known::CODEC_ID_OPUS;
use symphonia::core::codecs::audio::{AudioDecoder, AudioDecoderOptions};
use symphonia::core::errors::Error as SymphoniaError;
use symphonia::core::formats::probe::Hint;
use symphonia::core::formats::{FormatOptions, FormatReader, SeekMode, SeekTo, TrackType};
use symphonia::core::io::{MediaSource, MediaSourceStream};
use symphonia::core::meta::MetadataOptions;
use symphonia::core::packet::Packet;
use symphonia::core::units::Time;

pub const CHANNELS: usize = 2;
const BUFFER_MS: u64 = 250;
const RESAMPLE_CHUNK: usize = 1024;
const IDLE_SLEEP: Duration = Duration::from_millis(8);
pub const CAST_RATE: u32 = 48000;
const CAST_RATE_PPM: i64 = 0;
const PACER_FRAMES: usize = 960;
const BURST_SPEED: u32 = 16;
const BURST_CAP: Duration = Duration::from_secs(15);
const BURST_WAIT: Duration = Duration::from_millis(2);
const BURST_PATIENCE: u32 = 25;

static APP_VOLUME: AtomicU32 = AtomicU32::new(0x3f80_0000);

pub fn set_app_volume(volume: f32) {
    let volume = volume.clamp(0.0, 1.0);
    APP_VOLUME.store((volume * volume).to_bits(), Ordering::Relaxed);
}

pub fn app_volume() -> f32 {
    f32::from_bits(APP_VOLUME.load(Ordering::Relaxed))
}
const NEUTRAL_THRESHOLD: f32 = 1e-4;
const OPUS_MAX_FRAMES: usize = 5760;

#[derive(Clone, Default)]
pub struct Media {
    pub uri: String,
    pub name: String,
}

#[cfg(test)]
impl Media {
    pub fn of(path: &std::path::Path) -> Self {
        let uri = path.to_string_lossy().into_owned();
        Self {
            name: uri.clone(),
            uri,
        }
    }
}

pub enum EngineEvent {
    Finished(usize),
    Advanced(usize, usize),
    Failed(usize, String),
    Live(usize),
    Title(usize, String),
    Length(usize, u64),
}

enum Command {
    Load {
        media: Media,
        start_ms: u64,
        index: usize,
        gap_ms: Option<u64>,
        ticket: u64,
    },
    Seek(u64, u64),
    Queue(Option<(Media, usize)>),
    Clear,
}

struct Marker {
    frames: u64,
    index: usize,
    track_ms: f64,
    speed: f32,
}

struct Ring {
    samples: VecDeque<f32>,
    written: u64,
    consumed: u64,
    markers: VecDeque<Marker>,
    flushes: u64,
}

impl Ring {
    fn flush(&mut self) {
        self.samples.clear();
        self.consumed = self.written;
        self.markers.clear();
        self.flushes += 1;
    }

    fn pad(&mut self, frames: u64) {
        self.samples.extend(std::iter::repeat_n(0.0, frames as usize * CHANNELS));
        self.written += frames;
    }

    fn mark(&mut self, index: usize, track_ms: f64, speed: f32) {
        self.markers.push_back(Marker {
            frames: self.written,
            index,
            track_ms,
            speed,
        });
    }

    fn active(&self) -> Option<&Marker> {
        self.markers
            .iter()
            .rev()
            .find(|marker| marker.frames <= self.consumed)
    }
}

struct Shared {
    ring: Mutex<Ring>,
    spectrum: Mutex<Spectrum>,
    playing: AtomicBool,
    volume: AtomicU32,
    effect: AtomicU8,
    speed: AtomicU32,
    pitch: AtomicU32,
    lost: AtomicBool,
    equalizer: Mutex<Vec<(f32, f32)>>,
    equalizer_version: AtomicU32,
    rack: Mutex<Vec<Stage>>,
    rack_version: AtomicU32,
    watches: Mutex<Vec<(usize, crate::stream::Watch)>>,
    settled: AtomicU64,
    rate: u32,
    capacity: usize,
}

impl Shared {
    fn new(rate: u32, capacity: usize) -> Self {
        Self {
            ring: Mutex::new(Ring {
                samples: VecDeque::new(),
                written: 0,
                consumed: 0,
                markers: VecDeque::new(),
                flushes: 0,
            }),
            spectrum: Mutex::new(Spectrum::new()),
            playing: AtomicBool::new(false),
            volume: AtomicU32::new(1.0f32.to_bits()),
            effect: AtomicU8::new(0),
            speed: AtomicU32::new(1.0f32.to_bits()),
            pitch: AtomicU32::new(1.0f32.to_bits()),
            lost: AtomicBool::new(false),
            equalizer: Mutex::new(Vec::new()),
            equalizer_version: AtomicU32::new(0),
            rack: Mutex::new(Vec::new()),
            rack_version: AtomicU32::new(0),
            watches: Mutex::new(Vec::new()),
            settled: AtomicU64::new(0),
            rate,
            capacity: capacity,
        }
    }
}

enum Output {
    Device(#[allow(dead_code)] cpal::Stream),
    Pacer(Option<JoinHandle<()>>),
}

pub struct Engine {
    shared: Arc<Shared>,
    commands: Sender<Command>,
    events: Receiver<EngineEvent>,
    quit: Arc<AtomicBool>,
    decoder: Option<JoinHandle<()>>,
    output: Output,
    ticket: Cell<u64>,
    pending: Cell<(Option<usize>, u64)>,
}

impl Engine {
    pub fn new(cast: Option<Arc<crate::cast::Broadcast>>) -> Option<Self> {
        if !available() {
            return None;
        }
        let local = if cast.is_none() {
            let device = cpal::default_host().default_output_device()?;
            let supported = device.default_output_config().ok()?;
            Some((device, supported))
        } else {
            None
        };
        let rate = local.as_ref().map_or(CAST_RATE, |(_, supported)| supported.sample_rate());
        let shared = Arc::new(Shared::new(rate, (rate as u64 * BUFFER_MS / 1000) as usize * CHANNELS));

        let quit = Arc::new(AtomicBool::new(false));
        let output = match (local, cast) {
            (Some((device, supported)), _) => {
                let format = supported.sample_format();
                let config: cpal::StreamConfig = supported.into();
                let stream = match format {
                    cpal::SampleFormat::I16 => build_stream::<i16>(&device, config, shared.clone()),
                    cpal::SampleFormat::U16 => build_stream::<u16>(&device, config, shared.clone()),
                    _ => build_stream::<f32>(&device, config, shared.clone()),
                }?;
                #[cfg(not(target_os = "ios"))]
                stream.play().ok()?;
                Output::Device(stream)
            }
            (None, sink) => {
                let (shared, quit, sink) = (shared.clone(), quit.clone(), sink?);
                let thread = std::thread::Builder::new()
                    .name("cast-pacer".into())
                    .spawn(move || pacer(shared, sink, quit))
                    .ok()?;
                Output::Pacer(Some(thread))
            }
        };

        let (commands, command_rx) = channel();
        let (event_tx, events) = channel();
        let decoder = {
            let shared = shared.clone();
            let quit = quit.clone();
            std::thread::spawn(move || decode_loop(shared, command_rx, event_tx, quit))
        };

        Some(Self {
            shared,
            commands,
            events,
            quit,
            decoder: Some(decoder),
            output,
            ticket: Cell::new(0),
            pending: Cell::new((None, 0)),
        })
    }

    pub fn load(&self, media: Media, start_ms: u64, index: usize, gap_ms: Option<u64>) {
        let ticket = self.expect(Some(index), start_ms);
        let _ = self.commands.send(Command::Load {
            media,
            start_ms,
            index,
            gap_ms,
            ticket,
        });
    }

    fn expect(&self, index: Option<usize>, position_ms: u64) -> u64 {
        self.ticket.set(self.ticket.get() + 1);
        self.pending.set((index, position_ms));
        self.ticket.get()
    }

    pub fn queue(&self, next: Option<(Media, usize)>) {
        let _ = self.commands.send(Command::Queue(next));
    }

    pub fn seek(&self, position_ms: u64) {
        let ticket = self.expect(None, position_ms);
        let _ = self.commands.send(Command::Seek(position_ms, ticket));
    }

    pub fn clear(&self) {
        let _ = self.commands.send(Command::Clear);
    }

    pub fn set_playing(&self, playing: bool) {
        self.shared.playing.store(playing, Ordering::Relaxed);
        #[cfg(target_os = "ios")]
        if let Output::Device(stream) = &self.output {
            let _ = if playing { stream.play() } else { stream.pause() };
        }
    }

    pub fn set_volume(&self, volume: f32) {
        self.shared
            .volume
            .store(volume.clamp(0.0, 1.0).to_bits(), Ordering::Relaxed);
    }

    pub fn set_effect(&self, effect: Effect) {
        self.shared.effect.store(effect.index(), Ordering::Relaxed);
    }

    pub fn set_factors(&self, speed: f32, pitch: f32) {
        self.shared.speed.store(speed.to_bits(), Ordering::Relaxed);
        self.shared.pitch.store(pitch.to_bits(), Ordering::Relaxed);
    }

    pub fn set_equalizer(&self, bands: &[(f32, f32)]) {
        if let Ok(mut equalizer) = self.shared.equalizer.lock() {
            *equalizer = bands.to_vec();
        }
        self.shared.equalizer_version.fetch_add(1, Ordering::Release);
    }

    pub fn set_rack(&self, stages: &[Stage]) {
        if let Ok(mut rack) = self.shared.rack.lock() {
            *rack = stages.to_vec();
        }
        self.shared.rack_version.fetch_add(1, Ordering::Release);
    }

    pub fn spectrum(&self) -> [u8; SNAPSHOT] {
        self.shared
            .spectrum
            .lock()
            .map(|spectrum| spectrum.read())
            .unwrap_or([0; SNAPSHOT])
    }

    pub fn set_spectrum_latency(&self, milliseconds: i32) {
        if let Ok(mut spectrum) = self.shared.spectrum.lock() {
            spectrum.latency_ms = milliseconds;
        }
    }

    pub fn position(&self) -> Option<(usize, u64)> {
        let ring = self.shared.ring.lock().ok()?;
        if self.shared.settled.load(Ordering::Acquire) != self.ticket.get() {
            let (index, position_ms) = self.pending.get();
            return Some((index.or_else(|| ring.active().map(|marker| marker.index))?, position_ms));
        }
        let marker = ring.active()?;
        let elapsed = (ring.consumed - marker.frames) as f64 * 1000.0 * f64::from(marker.speed)
            / f64::from(self.shared.rate);
        Some((marker.index, (marker.track_ms + elapsed).max(0.0) as u64))
    }

    pub fn lost(&self) -> bool {
        self.shared.lost.load(Ordering::Relaxed)
    }

    pub fn buffered_ms(&self) -> u64 {
        let Ok(ring) = self.shared.ring.lock() else {
            return 0;
        };
        (ring.samples.len() / CHANNELS) as u64 * 1000 / u64::from(self.shared.rate)
    }

    pub fn buffered(&self, index: usize) -> Vec<(f64, f64)> {
        let watches = self.shared.watches.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        watches.iter().find(|(owner, _)| *owner == index).map_or_else(|| vec![(0.0, 1.0)], |(_, watch)| watch.buffered())
    }

    pub fn events(&self) -> Vec<EngineEvent> {
        self.events.try_iter().collect()
    }
}

impl Drop for Engine {
    fn drop(&mut self) {
        self.quit.store(true, Ordering::SeqCst);
        let _ = self.commands.send(Command::Clear);
        if let Some(decoder) = self.decoder.take() {
            let _ = decoder.join();
        }
        if let Output::Pacer(thread) = &mut self.output {
            if let Some(thread) = thread.take() {
                let _ = thread.join();
            }
        }
    }
}

struct Mix {
    shared: Arc<Shared>,
    equalizer: Equalizer,
    rack: Rack,
    master: bool,
}

impl Mix {
    fn new(shared: Arc<Shared>, master: bool) -> Self {
        let (equalizer, rack) = (Equalizer::new(shared.rate), Rack::new(shared.rate));
        Self { shared, equalizer, rack, master }
    }

    fn flushes(&self) -> u64 {
        self.shared.ring.lock().map_or(0, |ring| ring.flushes)
    }

    fn buffered_frames(&self) -> usize {
        self.shared.ring.lock().map_or(0, |ring| ring.samples.len() / CHANNELS)
    }

    fn pull(&mut self, frames: usize, mut put: impl FnMut(f32, f32)) -> (u64, Option<usize>) {
        let shared = &self.shared;
        let mut volume = f32::from_bits(shared.volume.load(Ordering::Relaxed));
        if self.master {
            volume *= app_volume();
        }
        let playing = shared.playing.load(Ordering::Relaxed);
        let version = shared.equalizer_version.load(Ordering::Acquire);
        if version != self.equalizer.version {
            if let Ok(bands) = shared.equalizer.try_lock() {
                self.equalizer.configure(&bands, version);
            }
        }
        let version = shared.rack_version.load(Ordering::Acquire);
        if version != self.rack.version {
            if let Ok(stages) = shared.rack.try_lock() {
                self.rack.configure(&stages, version);
            }
        }
        let mut done = 0;
        let mut flushes = 0;
        let mut track = None;
        if let Ok(mut ring) = shared.ring.lock() {
            flushes = ring.flushes;
            if playing {
                while done < frames && ring.samples.len() >= CHANNELS {
                    let left = ring.samples.pop_front().unwrap_or(0.0);
                    let right = ring.samples.pop_front().unwrap_or(0.0);
                    let (left, right) = self.equalizer.process(left, right);
                    let (left, right) = self.rack.process(left, right);
                    put(left * volume, right * volume);
                    ring.consumed += 1;
                    done += 1;
                }
                while ring.markers.len() > 1 && ring.markers[1].frames <= ring.consumed {
                    ring.markers.pop_front();
                }
            }
            track = ring.markers.front().map(|marker| marker.index);
        }
        for _ in done..frames {
            put(0.0, 0.0);
        }
        (flushes, track)
    }
}

fn pacer(shared: Arc<Shared>, sink: Arc<crate::cast::Broadcast>, quit: Arc<AtomicBool>) {
    let mut mix = Mix::new(shared, false);
    let period = Duration::from_nanos(
        (PACER_FRAMES as i64 * 1_000_000_000 / i64::from(CAST_RATE) * 1_000_000 / (1_000_000 + CAST_RATE_PPM)) as u64,
    );
    let mut pcm = Vec::with_capacity(PACER_FRAMES * CHANNELS);
    let mut next = Instant::now();
    let mut last: Option<(u64, Option<usize>)> = None;
    let mut burst: Option<(Instant, Duration)> = None;
    let mut waited = 0;
    while !quit.load(Ordering::Relaxed) {
        if !mix.shared.playing.load(Ordering::Relaxed) {
            if let Some((flushes, track)) = last {
                let seen = mix.flushes();
                if seen != flushes {
                    sink.mark_flush();
                    last = Some((seen, track));
                }
            }
            std::thread::sleep(period);
            next = Instant::now();
            burst = None;
            continue;
        }
        burst = match (sink.hungry(), burst) {
            (false, _) => None,
            (true, None) => Some((Instant::now(), Duration::ZERO)),
            (true, kept) => kept,
        };
        let bursting = burst.is_some_and(|(started, produced)| produced.saturating_sub(started.elapsed()) < BURST_CAP);
        if bursting && mix.buffered_frames() < PACER_FRAMES && waited < BURST_PATIENCE {
            waited += 1;
            std::thread::sleep(BURST_WAIT);
            continue;
        }
        waited = 0;
        pcm.clear();
        let seen = mix.pull(PACER_FRAMES, |left, right| pcm.extend_from_slice(&[left, right]));
        match last {
            Some((flushes, _)) if flushes != seen.0 => sink.mark_flush(),
            Some((_, track)) if track != seen.1 => sink.mark_track(),
            _ => {}
        }
        last = Some(seen);
        sink.push_pcm(&pcm);
        if bursting {
            if let Some((_, produced)) = burst.as_mut() {
                *produced += period;
            }
            std::thread::sleep(period / BURST_SPEED);
            next = Instant::now();
            continue;
        }
        next += period.div_f32(sink.pace());
        let now = Instant::now();
        if next > now {
            std::thread::sleep(next - now);
        } else if now - next > Duration::from_secs(1) {
            next = now;
        }
    }
}

fn build_stream<T>(
    device: &cpal::Device,
    config: cpal::StreamConfig,
    shared: Arc<Shared>,
) -> Option<cpal::Stream>
where
    T: SizedSample + FromSample<f32>,
{
    let channels = config.channels as usize;
    let watch = shared.clone();
    let mut mix = Mix::new(shared, true);
    device
        .build_output_stream(
            config,
            move |output: &mut [T], _: &cpal::OutputCallbackInfo| {
                let silence = T::from_sample(0.0);
                let mut index = 0;
                mix.pull(output.len() / channels, |left, right| {
                    output[index] = T::from_sample(left);
                    if channels > 1 {
                        output[index + 1] = T::from_sample(right);
                    }
                    for extra in 2..channels {
                        output[index + extra] = silence;
                    }
                    index += channels;
                });
                output[index..].fill(silence);
            },
            move |error: cpal::Error| {
                if matches!(
                    error.kind(),
                    cpal::ErrorKind::DeviceNotAvailable | cpal::ErrorKind::StreamInvalidated
                ) {
                    watch.lost.store(true, Ordering::Relaxed);
                }
            },
            None,
        )
        .ok()
}

enum Decoder {
    Symphonia(Box<dyn AudioDecoder>),
    Opus(Box<OpusDecoder>, usize, Vec<f32>),
}

enum Input {
    Packets {
        format: Box<dyn FormatReader>,
        decoder: Decoder,
        track_id: u32,
        skip_frames: usize,
    },
    Synth(Box<dyn crate::synth::Generator>),
}

struct Source {
    input: Input,
    resampler: Option<Async<f32>>,
    pending: Vec<f32>,
    chain: Chain,
    stretch: Option<Stretch>,
    stretch_pitch: f32,
    source_rate: u32,
    index: usize,
    watch: Option<crate::stream::Watch>,
    live: bool,
    title: Option<String>,
    length: Option<u64>,
    media: Media,
    spare: Option<crate::stream::Stream>,
}

impl Source {
    fn open(media: &Media, index: usize, rate: u32) -> Result<Self, String> {
        match origin(&media.uri)? {
            Origin::Stream(stream) => Self::from_stream(media, stream, index, rate),
            Origin::File(path) => {
                let file = crate::storage::open(&path).map_err(|error| error.to_string())?;
                Self::from_input(media, Box::new(file), None, None, index, rate)
            }
        }
    }

    fn replay(&mut self, index: usize, rate: u32) -> Result<Self, String> {
        match self.spare.take() {
            Some(stream) => Self::from_stream(&self.media, stream, index, rate),
            None => Self::open(&self.media, index, rate),
        }
    }

    fn from_stream(media: &Media, stream: crate::stream::Stream, index: usize, rate: u32) -> Result<Self, String> {
        let spare = stream.reader();
        let watch = stream.watch();
        Self::from_input(media, Box::new(stream), Some(watch), spare, index, rate)
    }

    fn from_input(
        media: &Media,
        source: Box<dyn MediaSource>,
        watch: Option<crate::stream::Watch>,
        spare: Option<crate::stream::Stream>,
        index: usize,
        rate: u32,
    ) -> Result<Self, String> {
        let mut opened = Self::decode(media, source, watch, index, rate)?;
        opened.media = media.clone();
        opened.spare = spare;
        Ok(opened)
    }

    fn decode(media: &Media, mut source: Box<dyn MediaSource>, watch: Option<crate::stream::Watch>, index: usize, rate: u32) -> Result<Self, String> {
        if let Some(name) = [&media.name, &media.uri].into_iter().find(|name| crate::synth::handles(name)) {
            let mut bytes = Vec::new();
            std::io::Read::read_to_end(&mut source, &mut bytes).map_err(|error| error.to_string())?;
            return Self::with(Input::Synth(crate::synth::open(&bytes, name, rate)?), rate, rate, index, None);
        }
        let stream = MediaSourceStream::new(source, Default::default());
        let mut hint = Hint::new();
        let extension = crate::storage::extension(&media.name);
        if !extension.is_empty() {
            hint.with_extension(&extension);
        }
        let format = symphonia::default::get_probe()
            .probe(
                &hint,
                stream,
                FormatOptions::default(),
                MetadataOptions::default(),
            )
            .map_err(|error| error.to_string())?;
        let track = format
            .default_track(TrackType::Audio)
            .ok_or_else(|| "no audio track".to_owned())?;
        let track_id = track.id;
        let params = track
            .codec_params
            .as_ref()
            .and_then(|params| params.audio())
            .ok_or_else(|| "unsupported codec".to_owned())?
            .clone();
        let source_rate = params.sample_rate.unwrap_or(rate);
        let channels = params.channels.as_ref().map_or(CHANNELS, |channels| channels.count());
        let skip_frames = track.delay.unwrap_or(0) as usize;
        let length = track
            .time_base
            .zip(track.duration)
            .and_then(|(base, duration)| base.calc_duration(duration))
            .or_else(|| {
                let media = format.media_info();
                media.time_base.zip(media.duration).and_then(|(base, duration)| base.calc_duration(duration))
            })
            .map(|time| time.as_millis())
            .or_else(|| track.num_frames.map(|frames| i128::from(frames) * 1000 / i128::from(source_rate.max(1))))
            .filter(|length| *length > 0)
            .map(|length| length as u64);
        let decoder = if params.codec == CODEC_ID_OPUS {
            let opus = OpusDecoder::new(source_rate as i32, channels.max(1))
                .map_err(|error| error.to_string())?;
            Decoder::Opus(
                Box::new(opus),
                channels.max(1),
                vec![0.0; OPUS_MAX_FRAMES * channels.max(1)],
            )
        } else {
            Decoder::Symphonia(
                symphonia::default::get_codecs()
                    .make_audio_decoder(&params, &AudioDecoderOptions::default())
                    .map_err(|error| error.to_string())?,
            )
        };
        let mut opened = Self::with(Input::Packets { format, decoder, track_id, skip_frames }, source_rate, rate, index, watch)?;
        opened.length = length;
        Ok(opened)
    }

    fn with(input: Input, source_rate: u32, rate: u32, index: usize, watch: Option<crate::stream::Watch>) -> Result<Self, String> {
        let resampler = (source_rate != rate)
            .then(|| {
                Async::<f32>::new_poly(
                    f64::from(rate) / f64::from(source_rate),
                    1.1,
                    PolynomialDegree::Septic,
                    RESAMPLE_CHUNK,
                    CHANNELS,
                    FixedAsync::Input,
                )
                .map_err(|error| error.to_string())
            })
            .transpose()?;
        Ok(Self {
            input,
            resampler,
            pending: Vec::new(),
            chain: Chain::new(source_rate),
            stretch: None,
            stretch_pitch: 1.0,
            source_rate,
            index,
            watch,
            live: false,
            title: None,
            length: None,
            media: Media::default(),
            spare: None,
        })
    }

    fn news(&mut self) -> Vec<EngineEvent> {
        let mut news = Vec::new();
        if let Some(length) = self.length.take() {
            news.push(EngineEvent::Length(self.index, length));
        }
        let Some(watch) = self.watch.as_ref() else {
            return news;
        };
        if !self.live && watch.live() {
            self.live = true;
            news.push(EngineEvent::Live(self.index));
        }
        let title = watch.title();
        if title.is_some() && title != self.title {
            self.title = title.clone();
            news.push(EngineEvent::Title(self.index, title.unwrap_or_default()));
        }
        news
    }

    fn seek(&mut self, position_ms: u64) {
        match &mut self.input {
            Input::Packets { format, decoder, track_id, .. } => {
                let time = Time::try_new(
                    (position_ms / 1000) as i64,
                    ((position_ms % 1000) * 1_000_000) as u32,
                )
                .unwrap_or(Time::ZERO);
                let _ = format.seek(
                    SeekMode::Accurate,
                    SeekTo::Time {
                        time,
                        track_id: Some(*track_id),
                    },
                );
                decoder.reset();
            }
            Input::Synth(generator) => generator.seek(position_ms),
        }
        self.stretch = None;
        self.stretch_pitch = 1.0;
        self.pending.clear();
    }

    fn next_chunk(
        &mut self,
        shared: &Shared,
        speed: f32,
        pitch: f32,
    ) -> Result<Option<Vec<f32>>, String> {
        loop {
            if let Some(chunk) = self.drain()? {
                return Ok(Some(chunk));
            }
            let Some(mut raw) = self.input.next_raw()? else {
                return self.finish();
            };
            if raw.is_empty() {
                continue;
            }
            if let Ok(mut spectrum) = shared.spectrum.lock() {
                spectrum.feed(&raw);
            }
            let effect = Effect::from_index(shared.effect.load(Ordering::Relaxed));
            self.chain.process(effect, &mut raw);
            let stretched = self.stretch(raw, speed, pitch);
            self.pending.extend(stretched);
        }
    }

    fn stretch(&mut self, raw: Vec<f32>, speed: f32, pitch: f32) -> Vec<f32> {
        if is_neutral(speed) && is_neutral(pitch) {
            self.stretch = None;
            self.stretch_pitch = 1.0;
            return raw;
        }
        let source_rate = self.source_rate;
        let stretch = self
            .stretch
            .get_or_insert_with(|| Stretch::preset_default(CHANNELS as u32, source_rate));
        if (pitch - self.stretch_pitch).abs() > NEUTRAL_THRESHOLD {
            stretch.set_transpose_factor(pitch, None);
            self.stretch_pitch = pitch;
        }
        let input_frames = raw.len() / CHANNELS;
        let output_frames = ((input_frames as f32 / speed).round() as usize).max(1);
        let mut output = vec![0.0f32; output_frames * CHANNELS];
        stretch.process(&raw, &mut output);
        output
    }

    fn drain(&mut self) -> Result<Option<Vec<f32>>, String> {
        let Some(resampler) = self.resampler.as_mut() else {
            if self.pending.is_empty() {
                return Ok(None);
            }
            return Ok(Some(std::mem::take(&mut self.pending)));
        };
        let frames = resampler.input_frames_next();
        if self.pending.len() < frames * CHANNELS {
            return Ok(None);
        }
        let input: Vec<f32> = self.pending.drain(..frames * CHANNELS).collect();
        resample(resampler, &input, frames).map(Some)
    }

    fn finish(&mut self) -> Result<Option<Vec<f32>>, String> {
        if self.pending.is_empty() {
            return Ok(None);
        }
        let mut leftover = std::mem::take(&mut self.pending);
        let Some(resampler) = self.resampler.as_mut() else {
            return Ok(Some(leftover));
        };
        let frames = resampler.input_frames_next();
        leftover.resize(frames * CHANNELS, 0.0);
        resample(resampler, &leftover, frames).map(Some)
    }
}

impl Input {
    fn next_raw(&mut self) -> Result<Option<Vec<f32>>, String> {
        let (format, decoder, track_id, skip_frames) = match self {
            Input::Synth(generator) => return Ok(generator.render()),
            Input::Packets { format, decoder, track_id, skip_frames } => (format, decoder, track_id, skip_frames),
        };
        loop {
            let packet = match format.next_packet() {
                Ok(Some(packet)) => packet,
                Ok(None) => return Ok(None),
                Err(SymphoniaError::ResetRequired) => {
                    decoder.reset();
                    continue;
                }
                Err(SymphoniaError::IoError(error))
                    if error.kind() == std::io::ErrorKind::UnexpectedEof =>
                {
                    return Ok(None)
                }
                Err(error) => return Err(error.to_string()),
            };
            if packet.track_id != *track_id {
                continue;
            }
            let Some(mut raw) = decoder.decode(&packet)? else {
                continue;
            };
            if *skip_frames > 0 {
                let skip = (*skip_frames).min(raw.len() / CHANNELS);
                raw.drain(..skip * CHANNELS);
                *skip_frames -= skip;
                if raw.is_empty() {
                    continue;
                }
            }
            return Ok(Some(raw));
        }
    }
}

impl Decoder {
    fn decode(&mut self, packet: &Packet) -> Result<Option<Vec<f32>>, String> {
        match self {
            Decoder::Symphonia(decoder) => match decoder.decode(packet) {
                Ok(decoded) => Ok(Some(collect_stereo(&decoded))),
                Err(SymphoniaError::DecodeError(_)) => Ok(None),
                Err(SymphoniaError::ResetRequired) => {
                    decoder.reset();
                    Ok(None)
                }
                Err(error) => Err(error.to_string()),
            },
            Decoder::Opus(decoder, channels, scratch) => {
                let Ok(frames) = decoder.decode(&packet.data, OPUS_MAX_FRAMES, scratch) else {
                    return Ok(None);
                };
                Ok(Some(to_stereo(&scratch[..frames * *channels], *channels)))
            }
        }
    }

}

impl Decoder {
    fn reset(&mut self) {
        if let Decoder::Symphonia(decoder) = self {
            decoder.reset();
        }
    }
}

enum Origin {
    Stream(crate::stream::Stream),
    File(String),
}

fn origin(uri: &str) -> Result<Origin, String> {
    let resolved = match crate::remote::is_remote(uri) {
        true => None,
        false => crate::plugins::resolve(uri).transpose()?,
    };
    let uri = resolved.as_deref().unwrap_or(uri);
    match crate::plugins::open_source(uri) {
        Some(opened) => opened.map(Origin::Stream),
        None if crate::remote::is_remote(uri) => crate::remote::open(uri).map(Origin::Stream).map_err(|error| error.to_string()),
        None => Ok(Origin::File(uri.to_owned())),
    }
}

pub fn open_input(uri: &str) -> Result<(Box<dyn MediaSource>, Option<crate::stream::Watch>), String> {
    match origin(uri)? {
        Origin::Stream(stream) => {
            let watch = stream.watch();
            Ok((Box::new(stream), Some(watch)))
        }
        Origin::File(path) => Ok((Box::new(crate::storage::open(&path).map_err(|error| error.to_string())?), None)),
    }
}

pub fn save(uri: &str, path: &str) -> Result<(), String> {
    if !crate::plugins::savable(uri) {
        return Err("the plugin that plays this song doesn't allow saving it".into());
    }
    let (mut source, watch) = open_input(uri)?;
    if watch.is_some_and(|watch| watch.live()) {
        return Err("live streams can't be saved".into());
    }
    let mut file = std::fs::File::create(path).map_err(|error| error.to_string())?;
    std::io::copy(&mut source, &mut file).map_err(|error| error.to_string())?;
    Ok(())
}

pub fn available() -> bool {
    #[cfg(target_os = "android")]
    return crate::android::ready();
    #[cfg(not(target_os = "android"))]
    return true;
}

pub fn decode(media: &Media, rate: u32, limit_frames: usize) -> Result<Vec<f32>, String> {
    let mut output = Vec::new();
    decode_each(media, rate, limit_frames, |chunk| output.extend_from_slice(chunk))?;
    Ok(output)
}

fn remember(shared: &Shared, source: &Source) {
    let Some(watch) = source.watch.clone() else {
        return;
    };
    let mut watches = shared.watches.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    watches.retain(|(index, _)| *index != source.index);
    watches.push((source.index, watch));
    if watches.len() > 3 {
        watches.remove(0);
    }
}

pub fn decode_each(media: &Media, rate: u32, limit_frames: usize, mut sink: impl FnMut(&[f32])) -> Result<(), String> {
    let shared = Shared::new(rate, 0);
    let mut source = Source::open(media, 0, rate)?;
    let mut left = limit_frames.saturating_mul(CHANNELS);
    while left > 0 {
        match source.next_chunk(&shared, 1.0, 1.0)? {
            Some(chunk) => {
                let take = chunk.len().min(left);
                sink(&chunk[..take]);
                left -= take;
            }
            None => break,
        }
    }
    Ok(())
}

fn collect_stereo(decoded: &GenericAudioBufferRef<'_>) -> Vec<f32> {
    let frames = decoded.frames();
    let channels = decoded.spec().channels().count().max(1);
    let mut interleaved = vec![0.0f32; frames * channels];
    decoded.copy_to_slice_interleaved(&mut interleaved);
    to_stereo(&interleaved, channels)
}

fn to_stereo(interleaved: &[f32], channels: usize) -> Vec<f32> {
    if channels == CHANNELS {
        return interleaved.to_vec();
    }
    let mut stereo = Vec::with_capacity(interleaved.len() / channels.max(1) * CHANNELS);
    for frame in interleaved.chunks(channels.max(1)) {
        let left = frame.first().copied().unwrap_or(0.0);
        stereo.push(left);
        stereo.push(frame.get(1).copied().unwrap_or(left));
    }
    stereo
}

fn is_neutral(factor: f32) -> bool {
    (factor - 1.0).abs() < NEUTRAL_THRESHOLD
}

fn resample(
    resampler: &mut Async<f32>,
    input: &[f32],
    frames: usize,
) -> Result<Vec<f32>, String> {
    let adapter =
        InterleavedSlice::new(input, CHANNELS, frames).map_err(|error| error.to_string())?;
    let output = resampler
        .process(&adapter, None)
        .map_err(|error| error.to_string())?;
    Ok(output.take_data())
}

fn decode_loop(
    shared: Arc<Shared>,
    commands: Receiver<Command>,
    events: Sender<EngineEvent>,
    quit: Arc<AtomicBool>,
) {
    let mut source: Option<Source> = None;
    let mut next: Option<(Media, usize)> = None;
    let mut emitted_ms = 0.0f64;
    let mut marked_speed = 1.0f32;
    while !quit.load(Ordering::SeqCst) {
        while let Ok(command) = commands.try_recv() {
            match command {
                Command::Load {
                    media,
                    start_ms,
                    index,
                    gap_ms,
                    ticket,
                } => {
                    match Source::open(&media, index, shared.rate) {
                        Ok(mut opened) => {
                            remember(&shared, &opened);
                            next = None;
                            if start_ms > 0 {
                                opened.seek(start_ms);
                            }
                            emitted_ms = start_ms as f64;
                            marked_speed = f32::from_bits(shared.speed.load(Ordering::Relaxed));
                            if let Ok(mut ring) = shared.ring.lock() {
                                match gap_ms {
                                    Some(gap) => ring.pad(u64::from(shared.rate) * gap / 1000),
                                    None => ring.flush(),
                                }
                                ring.mark(index, emitted_ms, marked_speed);
                            }
                            if let Ok(mut spectrum) = shared.spectrum.lock() {
                                spectrum.configure(opened.source_rate);
                            }
                            source = Some(opened);
                        }
                        Err(error) => {
                            source = None;
                            next = None;
                            if let Ok(mut ring) = shared.ring.lock() {
                                ring.flush();
                            }
                            let _ = events.send(EngineEvent::Failed(index, error));
                        }
                    }
                    shared.settled.store(ticket, Ordering::Release);
                }
                Command::Seek(position_ms, ticket) => {
                    if let Some(source) = source.as_mut().filter(|source| !source.live) {
                        source.seek(position_ms);
                        emitted_ms = position_ms as f64;
                        marked_speed = f32::from_bits(shared.speed.load(Ordering::Relaxed));
                        if let Ok(mut ring) = shared.ring.lock() {
                            ring.flush();
                            ring.mark(source.index, emitted_ms, marked_speed);
                        }
                        if let Ok(mut spectrum) = shared.spectrum.lock() {
                            spectrum.reset();
                        }
                    }
                    shared.settled.store(ticket, Ordering::Release);
                }
                Command::Queue(queued) => next = queued,
                Command::Clear => {
                    source = None;
                    next = None;
                    if let Ok(mut ring) = shared.ring.lock() {
                        ring.flush();
                    }
                    if let Ok(mut spectrum) = shared.spectrum.lock() {
                        spectrum.reset();
                    }
                }
            }
        }

        let Some(current) = source.as_mut() else {
            std::thread::sleep(IDLE_SLEEP);
            continue;
        };
        let full = shared
            .ring
            .lock()
            .map(|ring| ring.samples.len() >= shared.capacity)
            .unwrap_or(true);
        if full {
            std::thread::sleep(IDLE_SLEEP);
            continue;
        }
        let speed = if current.live { 1.0 } else { f32::from_bits(shared.speed.load(Ordering::Relaxed)) };
        let pitch = f32::from_bits(shared.pitch.load(Ordering::Relaxed));
        match current.next_chunk(&shared, speed, pitch) {
            Ok(Some(chunk)) => {
                for news in current.news() {
                    let _ = events.send(news);
                }
                let frames = (chunk.len() / CHANNELS) as u64;
                if let Ok(mut ring) = shared.ring.lock() {
                    if (speed - marked_speed).abs() > NEUTRAL_THRESHOLD {
                        marked_speed = speed;
                        ring.mark(current.index, emitted_ms, speed);
                    }
                    ring.written += frames;
                    ring.samples.extend(chunk);
                }
                emitted_ms +=
                    frames as f64 * 1000.0 * f64::from(speed) / f64::from(shared.rate);
            }
            Ok(None) => {
                let finished = current.index;
                let following = next.take().map(|(media, index)| {
                    let opened = if media.uri == current.media.uri { current.replay(index, shared.rate) } else { Source::open(&media, index, shared.rate) };
                    (index, opened)
                });
                source = None;
                match following {
                    Some((index, Ok(opened))) => {
                        remember(&shared, &opened);
                        emitted_ms = 0.0;
                        marked_speed = speed;
                        if let Ok(mut ring) = shared.ring.lock() {
                            ring.mark(index, 0.0, marked_speed);
                        }
                        if let Ok(mut spectrum) = shared.spectrum.lock() {
                            spectrum.configure(opened.source_rate);
                        }
                        source = Some(opened);
                        let _ = events.send(EngineEvent::Advanced(finished, index));
                    }
                    _ => {
                        let _ = events.send(EngineEvent::Finished(finished));
                    }
                }
            }
            Err(error) => {
                let index = current.index;
                source = None;
                let _ = events.send(EngineEvent::Failed(index, error));
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::Path;

    fn write_sine(path: &Path, rate: u32, frames: usize) {
        let mut bytes = Vec::new();
        let data_len = (frames * CHANNELS * 2) as u32;
        bytes.extend_from_slice(b"RIFF");
        bytes.extend_from_slice(&(36 + data_len).to_le_bytes());
        bytes.extend_from_slice(b"WAVEfmt ");
        bytes.extend_from_slice(&16u32.to_le_bytes());
        bytes.extend_from_slice(&1u16.to_le_bytes());
        bytes.extend_from_slice(&(CHANNELS as u16).to_le_bytes());
        bytes.extend_from_slice(&rate.to_le_bytes());
        bytes.extend_from_slice(&(rate * CHANNELS as u32 * 2).to_le_bytes());
        bytes.extend_from_slice(&((CHANNELS * 2) as u16).to_le_bytes());
        bytes.extend_from_slice(&16u16.to_le_bytes());
        bytes.extend_from_slice(b"data");
        bytes.extend_from_slice(&data_len.to_le_bytes());
        for frame in 0..frames {
            let phase = 2.0 * std::f32::consts::PI * 440.0 * frame as f32 / rate as f32;
            let sample = (phase.sin() * 16000.0) as i16;
            for _ in 0..CHANNELS {
                bytes.extend_from_slice(&sample.to_le_bytes());
            }
        }
        std::fs::write(path, bytes).unwrap();
    }

    fn test_shared(rate: u32) -> Arc<Shared> {
        Arc::new(Shared::new(rate, usize::MAX))
    }

    fn decode_all(path: &Path, rate: u32) -> Vec<f32> {
        decode(&Media::of(path), rate, usize::MAX).unwrap()
    }

    #[test]
    fn queued_track_follows_without_a_gap() {
        let directory = std::env::temp_dir().join("music_service_gapless_test");
        std::fs::create_dir_all(&directory).unwrap();
        let (first, second) = (directory.join("a.wav"), directory.join("b.wav"));
        write_sine(&first, 44100, 4410);
        write_sine(&second, 44100, 2205);
        let shared = test_shared(44100);
        let (commands, command_rx) = channel();
        let (event_tx, events) = channel();
        let quit = Arc::new(AtomicBool::new(false));
        commands.send(Command::Load { media: Media::of(&first), start_ms: 0, index: 1, gap_ms: None, ticket: 1 }).unwrap();
        commands.send(Command::Queue(Some((Media::of(&second), 2)))).unwrap();
        let decoder = {
            let (shared, quit) = (shared.clone(), quit.clone());
            std::thread::spawn(move || decode_loop(shared, command_rx, event_tx, quit))
        };
        let mut lengths = Vec::new();
        let mut next = || loop {
            match events.recv_timeout(Duration::from_secs(5)).unwrap() {
                EngineEvent::Length(index, length) => lengths.push((index, length)),
                event => break event,
            }
        };
        let advanced = next();
        let finished = next();
        quit.store(true, Ordering::SeqCst);
        decoder.join().unwrap();
        assert!(matches!(advanced, EngineEvent::Advanced(1, 2)));
        assert!(matches!(finished, EngineEvent::Finished(2)));
        assert_eq!(lengths, vec![(1, 100), (2, 50)], "each track reports its decoded length");
        let ring = shared.ring.lock().unwrap();
        assert_eq!(ring.written, 4410 + 2205, "both tracks land back to back");
        assert_eq!(ring.samples.len(), (4410 + 2205) * CHANNELS);
        let boundaries: Vec<(u64, usize)> = ring.markers.iter().map(|marker| (marker.frames, marker.index)).collect();
        assert_eq!(boundaries, vec![(0, 1), (4410, 2)]);
        std::fs::remove_dir_all(&directory).unwrap();
    }

    #[test]
    fn repeating_a_stream_replays_the_download() {
        let directory = std::env::temp_dir().join("music_service_replay_test");
        std::fs::create_dir_all(&directory).unwrap();
        let file = directory.join("loop.wav");
        write_sine(&file, 44100, 4410);
        let body = std::fs::read(&file).unwrap();
        std::fs::remove_dir_all(&directory).unwrap();
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        std::thread::spawn(move || {
            use std::io::{Read, Write};
            let (mut stream, _) = listener.accept().unwrap();
            let mut request = [0u8; 1024];
            let _ = stream.read(&mut request);
            write!(stream, "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n", body.len()).unwrap();
            stream.write_all(&body).unwrap();
        });
        let media = Media { uri: format!("http://{address}/loop.wav"), name: "loop.wav".into() };
        let shared = test_shared(44100);
        let (commands, command_rx) = channel();
        let (event_tx, events) = channel();
        let quit = Arc::new(AtomicBool::new(false));
        commands.send(Command::Load { media: media.clone(), start_ms: 0, index: 1, gap_ms: None, ticket: 1 }).unwrap();
        commands.send(Command::Queue(Some((media, 1)))).unwrap();
        let decoder = {
            let (shared, quit) = (shared.clone(), quit.clone());
            std::thread::spawn(move || decode_loop(shared, command_rx, event_tx, quit))
        };
        let next = || loop {
            match events.recv_timeout(Duration::from_secs(5)).unwrap() {
                EngineEvent::Length(..) => {}
                event => break event,
            }
        };
        let advanced = next();
        let finished = next();
        quit.store(true, Ordering::SeqCst);
        decoder.join().unwrap();
        assert!(matches!(advanced, EngineEvent::Advanced(1, 1)));
        assert!(matches!(finished, EngineEvent::Finished(1)));
        assert_eq!(shared.ring.lock().unwrap().written, 4410 * 2, "the second loop plays from the first download");
    }

    #[test]
    fn videos_play_their_audio_track() {
        let samples = decode_all(&Path::new(env!("CARGO_MANIFEST_DIR")).join("fixtures").join("motion_sound.mp4"), 48_000);
        assert!((samples.len() as f64 / CHANNELS as f64 / 48_000.0 - 1.0).abs() < 0.05);
        assert!(samples.iter().any(|sample| sample.abs() > 0.1));
    }

    #[test]
    fn decodes_and_resamples_without_losing_the_signal() {
        let directory = std::env::temp_dir().join("music_service_audio_test");
        std::fs::create_dir_all(&directory).unwrap();
        let path = directory.join("sine.wav");
        write_sine(&path, 44100, 44100);

        let same = decode_all(&path, 44100);
        assert_eq!(same.len(), 44100 * CHANNELS, "1s of stereo at the source rate");
        let peak = same.iter().fold(0.0f32, |peak, sample| peak.max(sample.abs()));
        assert!((0.45..0.55).contains(&peak), "peak was {peak}");

        let resampled = decode_all(&path, 48000);
        let frames = resampled.len() / CHANNELS;
        assert!(
            (47000..49500).contains(&frames),
            "1s at 44.1k should resample to about 48000 frames, got {frames}"
        );
        let rms = (resampled.iter().map(|sample| sample * sample).sum::<f32>()
            / resampled.len() as f32)
            .sqrt();
        assert!((0.25..0.40).contains(&rms), "resampled rms was {rms}");

        std::fs::remove_file(&path).unwrap();
    }
}
