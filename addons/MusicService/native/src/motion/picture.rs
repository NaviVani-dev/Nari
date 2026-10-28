use std::io::Cursor;
use std::path::Path;

use image::codecs::gif::GifDecoder;
use image::codecs::png::PngDecoder;
use image::codecs::webp::WebPDecoder;
use image::{AnimationDecoder, Frames, ImageError};

use super::{Frame, Pixels, Source};

const CACHE_LIMIT: usize = 48 * 1024 * 1024;
const MIN_DELAY: f64 = 0.02;
const DEFAULT_DELAY: f64 = 0.1;

#[derive(Clone, Copy, PartialEq)]
enum Kind {
    Gif,
    Apng,
    Webp,
    Still,
}

pub fn is_picture(bytes: &[u8]) -> bool {
    bytes.starts_with(b"GIF8")
        || bytes.starts_with(b"\x89PNG")
        || bytes.starts_with(&[0xFF, 0xD8])
        || bytes.starts_with(b"BM")
        || (bytes.starts_with(b"RIFF") && bytes.get(8..12) == Some(b"WEBP"))
}

pub fn is_animated(bytes: &[u8]) -> bool {
    match kind_of(bytes) {
        Ok(Kind::Gif) => GifDecoder::new(Cursor::new(bytes)).is_ok_and(|decoder| decoder.into_frames().take(2).count() == 2),
        Ok(Kind::Apng | Kind::Webp) => true,
        _ => false,
    }
}

fn kind_of(bytes: &[u8]) -> Result<Kind, ImageError> {
    if bytes.starts_with(b"GIF8") {
        return Ok(Kind::Gif);
    }
    if bytes.starts_with(b"\x89PNG") && PngDecoder::new(Cursor::new(bytes))?.is_apng()? {
        return Ok(Kind::Apng);
    }
    if bytes.starts_with(b"RIFF") && bytes.get(8..12) == Some(b"WEBP") && WebPDecoder::new(Cursor::new(bytes))?.has_animation() {
        return Ok(Kind::Webp);
    }
    Ok(Kind::Still)
}

struct Cached {
    start: f64,
    duration: f64,
    width: u32,
    height: u32,
    pixels: Vec<u8>,
}

pub struct PictureSource {
    bytes: Vec<u8>,
    kind: Kind,
    frames: Option<Frames<'static>>,
    still: bool,
    elapsed: f64,
    cache: Vec<Cached>,
    cached: usize,
    caching: bool,
    replay: Option<usize>,
}

impl PictureSource {
    pub fn open(path: &Path) -> Result<Self, String> {
        let bytes = std::fs::read(path).map_err(|error| error.to_string())?;
        let kind = kind_of(&bytes).map_err(|error| error.to_string())?;
        let mut source = Self { bytes, kind, frames: None, still: false, elapsed: 0.0, cache: Vec::new(), cached: 0, caching: true, replay: None };
        source.start()?;
        Ok(source)
    }

    fn start(&mut self) -> Result<(), String> {
        let error = |error: ImageError| error.to_string();
        let cursor = Cursor::new(self.bytes.clone());
        self.frames = match self.kind {
            Kind::Gif => Some(GifDecoder::new(cursor).map_err(error)?.into_frames()),
            Kind::Apng => Some(PngDecoder::new(cursor).map_err(error)?.apng().map_err(error)?.into_frames()),
            Kind::Webp => Some(WebPDecoder::new(cursor).map_err(error)?.into_frames()),
            Kind::Still => None,
        };
        self.still = false;
        self.elapsed = 0.0;
        Ok(())
    }

    fn decode(&mut self) -> Result<Option<Cached>, String> {
        let Some(frames) = self.frames.as_mut() else {
            if self.still {
                return Ok(None);
            }
            self.still = true;
            let image = image::load_from_memory(&self.bytes).map_err(|error| error.to_string())?.into_rgba8();
            let (width, height) = image.dimensions();
            return Ok(Some(Cached { start: 0.0, duration: DEFAULT_DELAY, width, height, pixels: image.into_raw() }));
        };
        let Some(frame) = frames.next().transpose().map_err(|error| error.to_string())? else {
            return Ok(None);
        };
        let (numerator, denominator) = frame.delay().numer_denom_ms();
        let delay = numerator as f64 / denominator.max(1) as f64 / 1000.0;
        let duration = if delay < MIN_DELAY { DEFAULT_DELAY } else { delay };
        let start = self.elapsed;
        self.elapsed += duration;
        let buffer = frame.into_buffer();
        let (width, height) = buffer.dimensions();
        Ok(Some(Cached { start, duration, width, height, pixels: buffer.into_raw() }))
    }

    fn remember(&mut self, frame: &Cached) {
        if !self.caching {
            return;
        }
        self.cached += frame.pixels.len();
        if self.cached > CACHE_LIMIT {
            self.caching = false;
            self.cache = Vec::new();
            return;
        }
        self.cache.push(Cached { pixels: frame.pixels.clone(), ..*frame });
    }
}

impl Source for PictureSource {
    fn next(&mut self, _deadline: f64) -> Result<Option<Frame>, String> {
        if let Some(index) = self.replay {
            let Some(cached) = self.cache.get(index) else {
                return Ok(None);
            };
            self.replay = Some(index + 1);
            let pixels = Some(Pixels::Rgba(cached.pixels.clone()));
            return Ok(Some(Frame { start: cached.start, duration: cached.duration, width: cached.width, height: cached.height, pixels }));
        }
        let Some(frame) = self.decode()? else {
            return Ok(None);
        };
        self.remember(&frame);
        Ok(Some(Frame { start: frame.start, duration: frame.duration, width: frame.width, height: frame.height, pixels: Some(Pixels::Rgba(frame.pixels)) }))
    }

    fn seek(&mut self, _seconds: f64) -> Result<(), String> {
        if self.caching && !self.cache.is_empty() {
            self.frames = None;
            self.replay = Some(0);
            return Ok(());
        }
        self.start()
    }

    fn length(&self) -> Option<f64> {
        None
    }

    fn decoder(&self) -> String {
        match self.kind {
            Kind::Gif => "gif",
            Kind::Apng => "apng",
            Kind::Webp => "webp",
            Kind::Still => "image",
        }
        .into()
    }

    fn hardware(&self) -> bool {
        false
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn gif(frames: usize) -> Vec<u8> {
        let mut bytes = Vec::new();
        {
            let mut encoder = image::codecs::gif::GifEncoder::new(&mut bytes);
            let frames = (0..frames).map(|index| {
                let buffer = image::RgbaImage::from_pixel(4, 2, image::Rgba([index as u8 * 40, 0, 0, 255]));
                image::Frame::from_parts(buffer, 0, 0, image::Delay::from_numer_denom_ms(50, 1))
            });
            encoder.encode_frames(frames).unwrap();
        }
        bytes
    }

    fn source(bytes: &[u8]) -> PictureSource {
        let path = std::env::temp_dir().join(format!("nari-motion-{}-{}.bin", std::process::id(), bytes.len()));
        std::fs::write(&path, bytes).unwrap();
        let source = PictureSource::open(&path).unwrap();
        std::fs::remove_file(path).unwrap();
        source
    }

    #[test]
    fn gif_frames_stream_with_their_timing() {
        let mut source = source(&gif(3));
        let starts: Vec<f64> = std::iter::from_fn(|| source.next(0.0).unwrap()).map(|frame| frame.start).collect();
        assert_eq!(starts.len(), 3);
        assert!((starts[2] - 0.1).abs() < 1e-6);
    }

    #[test]
    fn small_animations_replay_from_the_cache() {
        let mut source = source(&gif(2));
        while source.next(0.0).unwrap().is_some() {}
        source.seek(0.0).unwrap();
        assert_eq!(source.replay, Some(0));
        let frame = source.next(0.0).unwrap().unwrap();
        assert_eq!((frame.width, frame.height), (4, 2));
        assert!(matches!(frame.pixels, Some(Pixels::Rgba(ref pixels)) if pixels.len() == 32));
    }

    #[test]
    fn stills_give_one_frame() {
        let mut png = Vec::new();
        image::DynamicImage::ImageRgba8(image::RgbaImage::new(2, 2)).write_to(&mut Cursor::new(&mut png), image::ImageFormat::Png).unwrap();
        assert!(!is_animated(&png));
        let mut source = source(&png);
        assert!(source.next(0.0).unwrap().is_some());
        assert!(source.next(0.0).unwrap().is_none());
    }
}
