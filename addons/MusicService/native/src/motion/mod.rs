mod hardware;
mod picture;
mod video;

use std::fs::File;
use std::io::Read;
use std::path::Path;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::mpsc::{self, Receiver, SyncSender, TryRecvError};
use std::sync::{Arc, Mutex};
use std::thread::Thread;
use std::time::Duration;

use godot::classes::image::Format;
use godot::classes::{Image, ImageTexture};
use godot::prelude::*;

pub use picture::{is_animated as is_picture_animated, is_picture};

const QUEUE: usize = 3;
const MAX_STEP: f64 = 0.25;
const MAX_LAG: f64 = 0.5;
const MIN_LOOP: f64 = 0.05;
const IDLE: Duration = Duration::from_millis(50);

pub struct Frame {
    pub start: f64,
    pub duration: f64,
    pub width: u32,
    pub height: u32,
    pub pixels: Option<Pixels>,
}

pub enum Pixels {
    Rgba(Vec<u8>),
    Yuv { luma: Vec<u8>, chroma: Vec<u8>, color: Color },
}

#[derive(Clone, Copy, PartialEq, Debug)]
pub struct Color {
    pub kr: f32,
    pub kb: f32,
    pub full: bool,
}

#[derive(Clone, Copy, PartialEq)]
pub enum Output {
    Yuv,
    Rgba,
}

pub trait Source {
    fn next(&mut self, deadline: f64) -> Result<Option<Frame>, String>;
    fn seek(&mut self, seconds: f64) -> Result<(), String>;
    fn length(&self) -> Option<f64>;
    fn decoder(&self) -> String;
    fn hardware(&self) -> bool;
}

pub fn open(location: &str, output: Output, hardware: bool, cancel: &Arc<AtomicBool>) -> Result<Box<dyn Source>, String> {
    if !crate::remote::is_remote(location) {
        let mut head = [0u8; 16];
        let read = File::open(location).and_then(|mut file| file.read(&mut head)).map_err(|error| error.to_string())?;
        if is_picture(&head[..read]) {
            return Ok(Box::new(picture::PictureSource::open(Path::new(location))?));
        }
    }
    Ok(Box::new(video::VideoSource::open(location, output, hardware, cancel)?))
}

pub fn first_frame(location: &str, output: Output) -> Result<Frame, String> {
    let mut source = open(location, output, false, &Arc::default())?;
    while let Some(frame) = source.next(f64::NEG_INFINITY)? {
        if frame.pixels.is_some() {
            return Ok(frame);
        }
    }
    Err("the file has no frames".into())
}

enum Message {
    Frame { generation: u64, time: f64, frame: Frame },
    Ended(u64),
    Still,
    Failed(String),
}

#[derive(Default)]
struct Info {
    decoder: String,
    hardware: bool,
    length: Option<f64>,
}

struct Shared {
    stop: Arc<AtomicBool>,
    looping: AtomicBool,
    clock: AtomicU64,
    generation: AtomicU64,
    seek: Mutex<Option<f64>>,
    info: Mutex<Info>,
}

impl Default for Shared {
    fn default() -> Self {
        Self {
            stop: Arc::default(),
            looping: AtomicBool::new(true),
            clock: AtomicU64::new(0),
            generation: AtomicU64::new(0),
            seek: Mutex::new(None),
            info: Mutex::default(),
        }
    }
}

impl Shared {
    fn clock(&self) -> f64 {
        f64::from_bits(self.clock.load(Ordering::Relaxed))
    }

    fn describe(&self, source: &dyn Source) {
        *self.info.lock().unwrap() = Info { decoder: source.decoder(), hardware: source.hardware(), length: source.length() };
    }
}

fn run(location: String, hardware: bool, sender: SyncSender<Message>, shared: Arc<Shared>) {
    let mut source = match open(&location, Output::Yuv, hardware, &shared.stop) {
        Ok(source) => source,
        Err(error) => {
            let _ = sender.send(Message::Failed(error));
            return;
        }
    };
    shared.describe(source.as_ref());
    let mut generation = shared.generation.load(Ordering::Acquire);
    let mut offset = 0.0;
    let mut end = 0.0;
    let mut floor = f64::NEG_INFINITY;
    let mut frames = 0usize;
    let mut looped = false;
    let mut ended = false;
    while !shared.stop.load(Ordering::Relaxed) {
        if let Some(target) = shared.seek.lock().unwrap().take() {
            generation = shared.generation.load(Ordering::Acquire);
            if let Err(error) = source.seek(target) {
                let _ = sender.send(Message::Failed(error));
                return;
            }
            (offset, end, floor, ended) = (0.0, 0.0, target, false);
        }
        if ended {
            std::thread::park_timeout(IDLE);
            continue;
        }
        match source.next(shared.clock() - offset) {
            Ok(Some(mut frame)) => {
                end = frame.start + frame.duration;
                if end <= floor {
                    continue;
                }
                if !looped {
                    frames += 1;
                    if frames == 1 {
                        shared.describe(source.as_ref());
                    }
                }
                let time = frame.start;
                frame.start += offset;
                if frame.pixels.is_some() && sender.send(Message::Frame { generation, time, frame }).is_err() {
                    return;
                }
            }
            Ok(None) if frames == 0 => {
                let _ = sender.send(Message::Failed("the file has no frames".into()));
                return;
            }
            Ok(None) if frames == 1 => {
                let _ = sender.send(Message::Still);
                return;
            }
            Ok(None) if !shared.looping.load(Ordering::Relaxed) => {
                ended = true;
                if sender.send(Message::Ended(generation)).is_err() {
                    return;
                }
            }
            Ok(None) => {
                looped = true;
                offset += f64::max(end, MIN_LOOP);
                (end, floor) = (0.0, f64::NEG_INFINITY);
                if let Err(error) = source.seek(0.0) {
                    let _ = sender.send(Message::Failed(error));
                    return;
                }
            }
            Err(error) => {
                let _ = sender.send(Message::Failed(error));
                return;
            }
        }
    }
}

#[derive(GodotClass)]
#[class(base = RefCounted, no_init)]
pub struct NariMotion {
    shared: Arc<Shared>,
    worker: Option<Thread>,
    receiver: Option<Receiver<Message>>,
    pending: Option<(f64, Frame)>,
    generation: u64,
    clock: f64,
    position: f64,
    started: bool,
    animated: bool,
    ended: bool,
    error: GString,
    size: Vector2i,
    color: Option<Color>,
    texture: Gd<ImageTexture>,
    chroma: Gd<ImageTexture>,
    shown: u64,
    dropped: u64,
}

impl NariMotion {
    fn take(&mut self) -> Option<(f64, Frame)> {
        if let Some(pending) = self.pending.take() {
            return Some(pending);
        }
        loop {
            let message = match self.receiver.as_ref()?.try_recv() {
                Ok(message) => message,
                Err(TryRecvError::Empty) => return None,
                Err(TryRecvError::Disconnected) => {
                    self.receiver = None;
                    return None;
                }
            };
            match message {
                Message::Frame { generation, time, frame } if generation == self.generation => return Some((time, frame)),
                Message::Ended(generation) if generation == self.generation => self.ended = true,
                Message::Frame { .. } | Message::Ended(_) => {}
                Message::Still => {
                    self.animated = false;
                    self.receiver = None;
                    return None;
                }
                Message::Failed(error) => {
                    self.error = GString::from(&error);
                    self.receiver = None;
                    return None;
                }
            }
        }
    }

    fn set_clock(&mut self, clock: f64) {
        self.clock = clock;
        self.shared.clock.store(clock.to_bits(), Ordering::Relaxed);
    }

    fn present(&mut self, catch_up: bool) -> bool {
        let mut due: Option<(f64, Frame)> = None;
        while let Some((time, frame)) = self.take() {
            if self.started && frame.start - frame.duration * 0.5 > self.clock {
                self.pending = Some((time, frame));
                break;
            }
            if due.replace((time, frame)).is_some() {
                self.dropped += 1;
            }
            if !self.started {
                break;
            }
        }
        let Some((time, frame)) = due else {
            return false;
        };
        if !self.started || catch_up && frame.start + MAX_LAG < self.clock {
            self.set_clock(frame.start);
        }
        self.position = time;
        self.show(frame);
        self.started = true;
        true
    }

    fn show(&mut self, frame: Frame) {
        let Some(pixels) = frame.pixels else {
            return;
        };
        let (width, height) = (frame.width as i32, frame.height as i32);
        self.size = Vector2i::new(width, height);
        match pixels {
            Pixels::Rgba(bytes) => {
                upload(&mut self.texture, width, height, Format::RGBA8, bytes);
                self.color = None;
            }
            Pixels::Yuv { luma, chroma, color } => {
                upload(&mut self.texture, width, height, Format::R8, luma);
                upload(&mut self.chroma, (width + 1) / 2, (height + 1) / 2, Format::RG8, chroma);
                self.color = Some(color);
            }
        }
        self.shown += 1;
    }

    fn color(&self) -> Color {
        self.color.unwrap_or(Color { kr: 0.2126, kb: 0.0722, full: true })
    }
}

fn upload(texture: &mut Gd<ImageTexture>, width: i32, height: i32, format: Format, bytes: Vec<u8>) {
    let Some(image) = Image::create_from_data(width, height, false, format, &PackedByteArray::from(bytes)) else {
        return;
    };
    if texture.get_width() == width && texture.get_height() == height && texture.get_format() == format {
        texture.update(&image);
    } else {
        texture.set_image(&image);
    }
}

#[godot_api]
impl NariMotion {
    #[func]
    fn open(location: GString, hardware: bool) -> Gd<Self> {
        let (sender, receiver) = mpsc::sync_channel(QUEUE);
        let shared = Arc::new(Shared::default());
        let worker = shared.clone();
        let location = location.to_string();
        let worker = std::thread::Builder::new()
            .name("nari-motion".into())
            .spawn(move || run(location, hardware, sender, worker))
            .ok()
            .map(|handle| handle.thread().clone());
        Gd::from_object(Self {
            shared,
            worker,
            receiver: Some(receiver),
            pending: None,
            generation: 0,
            clock: 0.0,
            position: 0.0,
            started: false,
            animated: true,
            ended: false,
            error: GString::new(),
            size: Vector2i::ZERO,
            color: None,
            texture: ImageTexture::new_gd(),
            chroma: ImageTexture::new_gd(),
            shown: 0,
            dropped: 0,
        })
    }

    #[func]
    fn probe(location: GString) -> GString {
        match first_frame(&location.to_string(), Output::Yuv) {
            Ok(_) => GString::new(),
            Err(error) => GString::from(&error),
        }
    }

    #[func]
    fn advance(&mut self, delta: f64) -> bool {
        if self.started {
            self.set_clock(self.clock + delta.clamp(0.0, MAX_STEP));
        }
        self.present(true)
    }

    #[func]
    fn advance_to(&mut self, clock: f64) -> bool {
        if self.started {
            self.set_clock(clock.max(0.0));
        }
        self.present(false)
    }

    #[func]
    fn seek(&mut self, seconds: f64) {
        let target = seconds.max(0.0);
        self.generation += 1;
        self.shared.generation.store(self.generation, Ordering::Release);
        *self.shared.seek.lock().unwrap() = Some(target);
        self.pending = None;
        self.ended = false;
        self.position = target;
        self.set_clock(target);
        self.pending = self.take();
        if let Some(worker) = &self.worker {
            worker.unpark();
        }
    }

    #[func]
    fn set_looping(&mut self, looping: bool) {
        self.shared.looping.store(looping, Ordering::Relaxed);
    }

    #[func]
    fn get_position(&self) -> f64 {
        self.position
    }

    #[func]
    fn get_length(&self) -> f64 {
        self.shared.info.lock().unwrap().length.unwrap_or(0.0)
    }

    #[func]
    fn get_clock(&self) -> f64 {
        self.clock
    }

    #[func]
    fn is_ended(&self) -> bool {
        self.ended && self.pending.is_none()
    }

    #[func]
    fn is_started(&self) -> bool {
        self.started
    }

    #[func]
    fn is_animated(&self) -> bool {
        self.animated
    }

    #[func]
    fn is_finished(&self) -> bool {
        self.receiver.is_none() && self.pending.is_none()
    }

    #[func]
    fn is_yuv(&self) -> bool {
        self.color.is_some()
    }

    #[func]
    fn get_error(&self) -> GString {
        self.error.clone()
    }

    #[func]
    fn get_size(&self) -> Vector2i {
        self.size
    }

    #[func]
    fn get_texture(&self) -> Gd<ImageTexture> {
        self.texture.clone()
    }

    #[func]
    fn get_chroma(&self) -> Gd<ImageTexture> {
        self.chroma.clone()
    }

    #[func]
    fn get_color_matrix(&self) -> Basis {
        let Color { kr, kb, .. } = self.color();
        let kg = 1.0 - kr - kb;
        Basis::from_cols(
            Vector3::ONE,
            Vector3::new(0.0, -2.0 * kb * (1.0 - kb) / kg, 2.0 * (1.0 - kb)),
            Vector3::new(2.0 * (1.0 - kr), -2.0 * kr * (1.0 - kr) / kg, 0.0),
        )
    }

    #[func]
    fn get_luma_range(&self) -> Vector2 {
        if self.color().full {
            Vector2::new(0.0, 1.0)
        } else {
            Vector2::new(16.0 / 255.0, 255.0 / 219.0)
        }
    }

    #[func]
    fn get_chroma_range(&self) -> Vector2 {
        if self.color().full {
            Vector2::new(128.0 / 255.0, 1.0)
        } else {
            Vector2::new(128.0 / 255.0, 255.0 / 224.0)
        }
    }

    #[func]
    fn get_info(&self) -> VarDictionary {
        let info = self.shared.info.lock().unwrap();
        let mut dictionary = VarDictionary::new();
        dictionary.set("decoder", info.decoder.as_str());
        dictionary.set("hardware", info.hardware);
        dictionary.set("shown", self.shown as i64);
        dictionary.set("dropped", self.dropped as i64);
        dictionary.set("clock", self.clock);
        dictionary
    }
}

impl Drop for NariMotion {
    fn drop(&mut self) {
        self.shared.stop.store(true, Ordering::Relaxed);
        self.receiver = None;
        if let Some(worker) = &self.worker {
            worker.unpark();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fixture(name: &str) -> String {
        format!("{}/fixtures/{name}", env!("CARGO_MANIFEST_DIR"))
    }

    fn spawn(name: &str, looping: bool) -> (Receiver<Message>, Arc<Shared>, std::thread::JoinHandle<()>) {
        let (sender, receiver) = mpsc::sync_channel(QUEUE);
        let shared = Arc::new(Shared::default());
        shared.looping.store(looping, Ordering::Relaxed);
        let worker = shared.clone();
        let location = fixture(name);
        (receiver, shared, std::thread::spawn(move || run(location, false, sender, worker)))
    }

    fn finish(receiver: Receiver<Message>, shared: Arc<Shared>, thread: std::thread::JoinHandle<()>) {
        shared.stop.store(true, Ordering::Relaxed);
        drop(receiver);
        thread.thread().unpark();
        thread.join().unwrap();
    }

    #[test]
    fn the_worker_keeps_time_across_loops() {
        let (receiver, shared, thread) = spawn("motion_vp9.webm", true);
        let starts: Vec<f64> = receiver
            .iter()
            .take(20)
            .map(|message| match message {
                Message::Frame { frame, .. } => frame.start,
                _ => panic!("expected frames"),
            })
            .collect();
        finish(receiver, shared, thread);
        assert!(starts.windows(2).all(|pair| pair[1] > pair[0]));
        assert!((starts[8] - 0.4).abs() < 1e-3);
    }

    #[test]
    fn videos_without_looping_end_and_can_be_sought_again() {
        let (receiver, shared, thread) = spawn("motion_h264.mp4", false);
        let mut frames = 0;
        loop {
            match receiver.recv().unwrap() {
                Message::Frame { .. } => frames += 1,
                Message::Ended(0) => break,
                _ => panic!("expected frames and the end"),
            }
        }
        assert_eq!(frames, 12);
        shared.generation.store(1, Ordering::Release);
        shared.clock.store(0.25f64.to_bits(), Ordering::Relaxed);
        *shared.seek.lock().unwrap() = Some(0.25);
        thread.thread().unpark();
        let Ok(Message::Frame { generation, time, .. }) = receiver.recv() else { panic!("expected a frame") };
        assert_eq!(generation, 1);
        assert!((time - 0.25).abs() < 1e-3);
        assert!((shared.info.lock().unwrap().length.unwrap() - 0.5).abs() < 0.05);
        finish(receiver, shared, thread);
    }

    #[test]
    fn probing_finds_playable_files() {
        assert!(first_frame(&fixture("motion_h264.mp4"), Output::Yuv).is_ok());
        assert!(first_frame(&fixture("cast_receiver.key.der"), Output::Yuv).is_err());
    }

    #[test]
    fn missing_files_report_an_error() {
        let (sender, receiver) = mpsc::sync_channel(QUEUE);
        run("/nonexistent/video.mp4".into(), false, sender, Arc::new(Shared::default()));
        assert!(matches!(receiver.recv(), Ok(Message::Failed(_))));
    }
}
