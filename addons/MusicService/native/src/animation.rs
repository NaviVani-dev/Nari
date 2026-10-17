use std::collections::HashMap;
use std::io::Cursor;
use std::path::Path;
use std::sync::atomic::{AtomicI64, Ordering};
use std::sync::{LazyLock, Mutex};

use godot::classes::image::Format;
use godot::classes::Image;
use godot::prelude::*;
use image::codecs::gif::GifDecoder;
use image::codecs::png::PngDecoder;
use image::codecs::webp::WebPDecoder;
use image::{AnimationDecoder, Frames as ImageFrames};

const DEFAULT_DELAY: f32 = 0.1;

type Job = Option<Result<Frames, String>>;

static NEXT_JOB: AtomicI64 = AtomicI64::new(1);
static JOBS: LazyLock<Mutex<HashMap<i64, Job>>> = LazyLock::new(|| Mutex::new(HashMap::new()));

struct Frames {
    max: usize,
    max_size: u32,
    first_only: bool,
    step: usize,
    pending: usize,
    width: u32,
    height: u32,
    pixels: Vec<Vec<u8>>,
    delays: Vec<f32>,
}

impl Frames {
    fn new(max: usize, max_size: u32) -> Self {
        Self { max: max.max(2) & !1, max_size, first_only: false, step: 1, pending: 0, width: 0, height: 0, pixels: Vec::new(), delays: Vec::new() }
    }

    fn done(&self) -> bool {
        self.first_only && !self.pixels.is_empty()
    }

    fn fit(&self, width: u32, height: u32) -> (u32, u32) {
        let longest = width.max(height);
        if self.max_size == 0 || longest <= self.max_size {
            return (width, height);
        }
        let scale = self.max_size as f32 / longest as f32;
        (((width as f32 * scale) as u32).max(1), ((height as f32 * scale) as u32).max(1))
    }

    fn push(&mut self, width: u32, height: u32, rgba: Vec<u8>, delay: f32) {
        if self.done() {
            return;
        }
        let (fit_width, fit_height) = self.fit(width, height);
        let (width, height, rgba) = if (fit_width, fit_height) == (width, height) {
            (width, height, rgba)
        } else {
            match image::RgbaImage::from_raw(width, height, rgba) {
                Some(full) => (fit_width, fit_height, image::imageops::resize(&full, fit_width, fit_height, image::imageops::FilterType::Triangle).into_raw()),
                None => return,
            }
        };
        if self.pending > 0 {
            if let Some(last) = self.delays.last_mut() {
                *last += delay;
            }
            self.pending -= 1;
            return;
        }
        if self.pixels.len() >= self.max {
            self.pixels = std::mem::take(&mut self.pixels).into_iter().step_by(2).collect();
            self.delays = self.delays.chunks(2).map(|pair| pair.iter().sum()).collect();
            self.step *= 2;
        }
        self.width = width;
        self.height = height;
        self.pixels.push(rgba);
        self.delays.push(delay);
        self.pending = self.step - 1;
    }
}

fn read_frames(frames: ImageFrames, into: &mut Frames) -> Result<(), String> {
    for frame in frames {
        if into.done() {
            break;
        }
        let frame = frame.map_err(|error| error.to_string())?;
        let (numerator, denominator) = frame.delay().numer_denom_ms();
        let delay = numerator as f32 / denominator.max(1) as f32 / 1000.0;
        let buffer = frame.into_buffer();
        let (width, height) = buffer.dimensions();
        into.push(width, height, buffer.into_raw(), if delay > 0.0 { delay } else { DEFAULT_DELAY });
    }
    Ok(())
}

fn decode_image(bytes: &[u8], into: &mut Frames) -> Result<(), String> {
    let error = |error: image::ImageError| error.to_string();
    if bytes.starts_with(b"GIF8") {
        return read_frames(GifDecoder::new(Cursor::new(bytes)).map_err(error)?.into_frames(), into);
    }
    if bytes.starts_with(b"\x89PNG") {
        let decoder = PngDecoder::new(Cursor::new(bytes)).map_err(error)?;
        if decoder.is_apng().map_err(error)? {
            return read_frames(decoder.apng().map_err(error)?.into_frames(), into);
        }
    }
    if bytes.starts_with(b"RIFF") && bytes.get(8..12) == Some(b"WEBP") {
        let decoder = WebPDecoder::new(Cursor::new(bytes)).map_err(error)?;
        if decoder.has_animation() {
            return read_frames(decoder.into_frames(), into);
        }
    }
    let still = image::load_from_memory(bytes).map_err(error)?.into_rgba8();
    let (width, height) = still.dimensions();
    into.push(width, height, still.into_raw(), 0.0);
    Ok(())
}

pub fn is_animated(bytes: &[u8]) -> bool {
    if bytes.starts_with(b"GIF8") {
        return GifDecoder::new(Cursor::new(bytes)).is_ok_and(|decoder| decoder.into_frames().take(2).count() == 2);
    }
    if bytes.starts_with(b"\x89PNG") {
        return PngDecoder::new(Cursor::new(bytes)).is_ok_and(|decoder| decoder.is_apng().unwrap_or(false));
    }
    if bytes.starts_with(b"RIFF") && bytes.get(8..12) == Some(b"WEBP") {
        return WebPDecoder::new(Cursor::new(bytes)).is_ok_and(|decoder| decoder.has_animation());
    }
    bytes.get(4..8) == Some(b"ftyp") || bytes.starts_with(&[0x1A, 0x45, 0xDF, 0xA3])
}

pub fn poster(path: &Path) -> Option<image::DynamicImage> {
    let mut frames = Frames::new(2, 0);
    frames.first_only = true;
    let frames = decode_into(&path.to_string_lossy(), frames).ok()?;
    let pixels = frames.pixels.into_iter().next()?;
    image::RgbaImage::from_raw(frames.width, frames.height, pixels).map(image::DynamicImage::ImageRgba8)
}

fn is_image(bytes: &[u8]) -> bool {
    bytes.starts_with(b"GIF8")
        || bytes.starts_with(b"\x89PNG")
        || bytes.starts_with(&[0xFF, 0xD8])
        || bytes.starts_with(b"BM")
        || (bytes.starts_with(b"RIFF") && bytes.get(8..12) == Some(b"WEBP"))
}

fn decode_video(path: &Path, into: &mut Frames) -> Result<(), String> {
    use ffmpeg_next::format::Pixel;
    use ffmpeg_next::media::Type;
    use ffmpeg_next::software::scaling::{Context as Scaler, Flags};
    use ffmpeg_next::util::frame::video::Video;

    let error = |error: ffmpeg_next::Error| error.to_string();
    ffmpeg_next::init().map_err(error)?;
    let mut input = ffmpeg_next::format::input(path).map_err(error)?;
    let stream = input.streams().best(Type::Video).ok_or("the file has no video")?;
    let index = stream.index();
    let rate = stream.avg_frame_rate();
    let delay = if rate.numerator() > 0 { rate.denominator() as f32 / rate.numerator() as f32 } else { 1.0 / 30.0 };
    let context = ffmpeg_next::codec::context::Context::from_parameters(stream.parameters()).map_err(error)?;
    let mut decoder = context.decoder().video().map_err(error)?;
    let (source_width, source_height) = (decoder.width(), decoder.height());
    let (width, height) = into.fit(source_width, source_height);
    let mut scaler = Scaler::get(decoder.format(), source_width, source_height, Pixel::RGBA, width, height, Flags::BILINEAR).map_err(error)?;
    let mut decoded = Video::empty();
    let mut rgba = Video::empty();
    let mut drain = |decoder: &mut ffmpeg_next::decoder::Video, into: &mut Frames| -> Result<(), String> {
        while decoder.receive_frame(&mut decoded).is_ok() {
            scaler.run(&decoded, &mut rgba).map_err(error)?;
            let stride = rgba.stride(0);
            let row = width as usize * 4;
            let data = rgba.data(0);
            let mut pixels = Vec::with_capacity(row * height as usize);
            for y in 0..height as usize {
                pixels.extend_from_slice(&data[y * stride..y * stride + row]);
            }
            into.push(width, height, pixels, delay);
        }
        Ok(())
    };
    for (packet_stream, packet) in input.packets() {
        if into.done() {
            return Ok(());
        }
        if packet_stream.index() == index {
            decoder.send_packet(&packet).map_err(error)?;
            drain(&mut decoder, into)?;
        }
    }
    decoder.send_eof().map_err(error)?;
    drain(&mut decoder, into)
}

fn decode(path: &str, max_frames: usize, max_size: u32) -> Result<Frames, String> {
    decode_into(path, Frames::new(max_frames, max_size))
}

fn decode_into(path: &str, mut frames: Frames) -> Result<Frames, String> {
    let bytes = std::fs::read(path).map_err(|error| error.to_string())?;
    if is_image(&bytes) {
        decode_image(&bytes, &mut frames)?;
    } else {
        decode_video(Path::new(path), &mut frames)?;
    }
    if frames.pixels.is_empty() {
        return Err("the file has no frames".into());
    }
    Ok(frames)
}

#[derive(GodotClass)]
#[class(base = RefCounted, init)]
pub struct NariAnimation;

fn to_dictionary(result: Result<Frames, String>) -> VarDictionary {
    let mut dictionary = VarDictionary::new();
    match result {
        Ok(frames) => {
            let mut images = Array::<Gd<Image>>::new();
            for pixels in frames.pixels {
                let data = PackedByteArray::from(pixels);
                if let Some(image) = Image::create_from_data(frames.width as i32, frames.height as i32, false, Format::RGBA8, &data) {
                    images.push(&image);
                }
            }
            dictionary.set("frames", &images.to_variant());
            dictionary.set("delays", &PackedFloat32Array::from(frames.delays).to_variant());
        }
        Err(error) => dictionary.set("error", error),
    }
    dictionary
}

#[godot_api]
impl NariAnimation {
    #[func]
    fn start(path: GString, max_frames: i32, max_size: i32) -> i64 {
        let id = NEXT_JOB.fetch_add(1, Ordering::Relaxed);
        JOBS.lock().unwrap().insert(id, None);
        let path = path.to_string();
        let max_frames = max_frames.max(1) as usize;
        let max_size = max_size.max(0) as u32;
        std::thread::spawn(move || {
            let result = decode(&path, max_frames, max_size);
            JOBS.lock().unwrap().insert(id, Some(result));
        });
        id
    }

    #[func]
    fn is_animated(bytes: PackedByteArray) -> bool {
        is_animated(bytes.as_slice())
    }

    #[func]
    fn save_poster(source: GString, target: GString, max_size: i32) -> bool {
        let Some(jpeg) = poster(Path::new(&source.to_string())).and_then(|image| crate::library::covers::scaled_jpeg(image, max_size.max(1) as u32)) else {
            return false;
        };
        crate::library::covers::write_atomically(Path::new(&target.to_string()), &jpeg);
        true
    }

    #[func]
    fn take(id: i64) -> Variant {
        let mut jobs = JOBS.lock().unwrap();
        match jobs.get(&id) {
            Some(None) => Variant::nil(),
            Some(Some(_)) => {
                let result = jobs.remove(&id).flatten().unwrap_or_else(|| Err("lost".into()));
                drop(jobs);
                to_dictionary(result).to_variant()
            }
            None => to_dictionary(Err("unknown animation".into())).to_variant(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn frames_stay_under_the_limit_and_keep_the_total_time() {
        let mut frames = Frames::new(4, 0);
        for _ in 0..10 {
            frames.push(1, 1, vec![0; 4], 0.1);
        }
        assert!(frames.pixels.len() <= 4);
        assert_eq!(frames.pixels.len(), frames.delays.len());
        assert!((frames.delays.iter().sum::<f32>() - 1.0).abs() < 0.001);
    }

    #[test]
    fn big_frames_are_scaled_down() {
        let mut frames = Frames::new(4, 2);
        frames.push(4, 2, vec![255; 32], 0.1);
        assert_eq!((frames.width, frames.height), (2, 1));
        assert_eq!(frames.pixels[0].len(), 8);
    }

    #[test]
    fn only_moving_images_count_as_animated() {
        let still = image::RgbaImage::new(2, 2);
        let mut png = Vec::new();
        image::DynamicImage::ImageRgba8(still).write_to(&mut Cursor::new(&mut png), image::ImageFormat::Png).unwrap();
        assert!(!is_animated(&png));
        assert!(is_animated(b"\x00\x00\x00\x20ftypisom"));
    }
}
