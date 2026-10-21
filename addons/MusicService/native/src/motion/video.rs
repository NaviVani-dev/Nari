use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Once};

use ffmpeg::color::{Range, Space};
use ffmpeg::format::context::{Input, StreamIo};
use ffmpeg::format::Pixel;
use ffmpeg::media::Type;
use ffmpeg::software::scaling::{Context as Scaler, Flags};
use ffmpeg::util::frame::video::Video;
use ffmpeg::{decoder, Discard, Packet};
use ffmpeg_next as ffmpeg;

use super::hardware;
use super::{Color, Frame, Output, Pixels, Source};

const BT601: (f32, f32) = (0.299, 0.114);
const BT709: (f32, f32) = (0.2126, 0.0722);
const BT2020: (f32, f32) = (0.2627, 0.0593);
const DEFAULT_RATE: f64 = 30.0;
const MAX_SIZE: u32 = 8192;

static INIT: Once = Once::new();

fn text(error: ffmpeg::Error) -> String {
    error.to_string()
}

fn init() {
    INIT.call_once(|| {
        let _ = ffmpeg::init();
        ffmpeg::log::set_level(ffmpeg::log::Level::Error);
    });
}

fn input(location: &str, cancel: &Arc<AtomicBool>) -> Result<Input, String> {
    if !crate::remote::is_remote(location) {
        return ffmpeg::format::input(location).map_err(text);
    }
    let (source, _) = crate::audio::open_input(location)?;
    let io = StreamIo::from_read_seek(source).map_err(text)?;
    let cancel = cancel.clone();
    ffmpeg::format::input_from_stream_with_interrupt(io, Some(location), None, move || cancel.load(Ordering::Relaxed)).map_err(text)
}

pub struct VideoSource {
    location: String,
    cancel: Arc<AtomicBool>,
    input: Input,
    stream: usize,
    time_base: f64,
    origin: i64,
    length: Option<f64>,
    frame_duration: f64,
    decoder: decoder::Video,
    name: String,
    hardware: bool,
    device: bool,
    output: Output,
    scaler: Option<(Pixel, u32, u32, Scaler)>,
    decoded: Video,
    transferred: Video,
    converted: Video,
    draining: bool,
    skipping: bool,
    last_start: f64,
    frames: u64,
}

impl VideoSource {
    pub fn open(location: &str, output: Output, hardware: bool, cancel: &Arc<AtomicBool>) -> Result<Self, String> {
        init();
        let mut input = input(location, cancel)?;
        let length = (input.duration() > 0).then(|| input.duration() as f64 / f64::from(ffmpeg::ffi::AV_TIME_BASE));
        let stream = input.streams().best(Type::Video).ok_or("the file has no video")?;
        let index = stream.index();
        let time_base = f64::from(stream.time_base());
        let origin = if stream.start_time() == ffmpeg::ffi::AV_NOPTS_VALUE { 0 } else { stream.start_time() };
        let rate = [stream.avg_frame_rate(), stream.rate()].into_iter().map(f64::from).find(|rate| rate.is_finite() && *rate > 0.0).unwrap_or(DEFAULT_RATE);
        let opened = hardware::open(&stream, output == Output::Yuv && hardware)?;
        let (width, height) = (opened.decoder.width(), opened.decoder.height());
        if width == 0 || height == 0 || width > MAX_SIZE || height > MAX_SIZE {
            return Err(format!("the video size {width}x{height} isn't supported"));
        }
        discard_others(&mut input, index);
        Ok(Self {
            location: location.to_owned(),
            cancel: cancel.clone(),
            input,
            stream: index,
            time_base,
            origin,
            length,
            frame_duration: 1.0 / rate,
            decoder: opened.decoder,
            name: opened.name,
            hardware: opened.hardware,
            device: opened.device,
            output,
            scaler: None,
            decoded: Video::empty(),
            transferred: Video::empty(),
            converted: Video::empty(),
            draining: false,
            skipping: false,
            last_start: 0.0,
            frames: 0,
        })
    }

    fn receive(&mut self) -> Result<bool, String> {
        loop {
            match self.decoder.receive_frame(&mut self.decoded) {
                Ok(()) => return Ok(true),
                Err(ffmpeg::Error::Eof) => return Ok(false),
                Err(ffmpeg::Error::Other { errno }) if errno == ffmpeg::error::EAGAIN => {}
                Err(ffmpeg::Error::InvalidData) => continue,
                Err(error) => return Err(text(error)),
            }
            if self.draining {
                return Ok(false);
            }
            let mut packet = Packet::empty();
            match packet.read(&mut self.input) {
                Ok(()) if packet.stream() == self.stream => match self.decoder.send_packet(&packet) {
                    Ok(()) | Err(ffmpeg::Error::InvalidData) => {}
                    Err(error) => return Err(text(error)),
                },
                Ok(()) => {}
                Err(ffmpeg::Error::Eof) => {
                    self.decoder.send_eof().map_err(text)?;
                    self.draining = true;
                }
                Err(error) => return Err(text(error)),
            }
        }
    }

    fn fall_back(&mut self) -> Result<(), String> {
        let stream = self.input.stream(self.stream).ok_or("the video stream is gone")?;
        let opened = hardware::open(&stream, false)?;
        self.decoder = opened.decoder;
        self.name = opened.name;
        self.hardware = false;
        self.device = false;
        let resume = self.last_start;
        self.locate(resume)
    }

    fn locate(&mut self, seconds: f64) -> Result<(), String> {
        let target = (((seconds + self.origin as f64 * self.time_base) * 1_000_000.0) as i64).max(0);
        if self.input.seek(target, ..target + 1).is_err() {
            self.input = input(&self.location, &self.cancel)?;
            discard_others(&mut self.input, self.stream);
        }
        self.decoder.flush();
        self.draining = false;
        Ok(())
    }

    fn start_of(&self) -> (f64, f64) {
        let duration = match self.decoded.packet().duration {
            duration if duration > 0 => duration as f64 * self.time_base,
            _ => self.frame_duration,
        };
        let start = match self.decoded.timestamp().or(self.decoded.pts()) {
            Some(pts) => (pts - self.origin) as f64 * self.time_base,
            None if self.frames == 0 => 0.0,
            None => self.last_start + duration,
        };
        (start, duration)
    }

    fn skip(&mut self, skipping: bool) {
        if skipping != self.skipping {
            self.skipping = skipping;
            self.decoder.skip_frame(if skipping { Discard::NonReference } else { Discard::Default });
        }
    }

    fn pixels(&mut self) -> Result<Pixels, String> {
        let source = if hardware::is_hardware_frame(self.decoded.format()) {
            hardware::transfer(&self.decoded, &mut self.transferred)?;
            &self.transferred
        } else {
            &self.decoded
        };
        let wanted = match self.output {
            Output::Rgba => Pixel::RGBA,
            Output::Yuv if matches!(source.format(), Pixel::NV12 | Pixel::YUV420P | Pixel::YUVJ420P) => return Ok(yuv(source, color_of(source, false))),
            Output::Yuv => Pixel::NV12,
        };
        let (format, width, height) = (source.format(), source.width(), source.height());
        if !matches!(&self.scaler, Some((cached, w, h, _)) if *cached == format && *w == width && *h == height) {
            let scaler =
                Scaler::get(format, width, height, wanted, width, height, Flags::BILINEAR | Flags::ACCURATE_RND | Flags::FULL_CHR_H_INT).map_err(text)?;
            self.scaler = Some((format, width, height, scaler));
        }
        let color = color_of(source, true);
        let (_, _, _, scaler) = self.scaler.as_mut().unwrap();
        scaler.run(source, &mut self.converted).map_err(text)?;
        Ok(match self.output {
            Output::Rgba => Pixels::Rgba(plane(&self.converted, 0, width as usize * 4, height as usize)),
            Output::Yuv => yuv(&self.converted, color),
        })
    }
}

impl Source for VideoSource {
    fn next(&mut self, deadline: f64) -> Result<Option<Frame>, String> {
        let received = match self.receive() {
            Err(_) if self.hardware => {
                self.fall_back()?;
                self.receive()?
            }
            result => result?,
        };
        if !received {
            return Ok(None);
        }
        if self.device && !hardware::is_hardware_frame(self.decoded.format()) {
            self.device = false;
            self.hardware = false;
            self.name = hardware::name_of(&self.decoder);
        }
        let (start, duration) = self.start_of();
        let late = self.frames > 0 && start + duration < deadline;
        self.skip(late);
        self.frames += 1;
        self.last_start = start;
        let pixels = if late { None } else { Some(self.pixels()?) };
        let (width, height) = (self.decoded.width(), self.decoded.height());
        Ok(Some(Frame { start, duration, width, height, pixels }))
    }

    fn seek(&mut self, seconds: f64) -> Result<(), String> {
        self.skip(false);
        if seconds <= 0.0 {
            self.frames = 0;
        }
        self.last_start = seconds.max(0.0);
        self.locate(self.last_start)
    }

    fn length(&self) -> Option<f64> {
        self.length
    }

    fn decoder(&self) -> String {
        self.name.clone()
    }

    fn hardware(&self) -> bool {
        self.hardware
    }
}

fn discard_others(input: &mut Input, keep: usize) {
    unsafe {
        let context = input.as_mut_ptr();
        for index in 0..(*context).nb_streams as usize {
            if index != keep {
                (**(*context).streams.add(index)).discard = ffmpeg::ffi::AVDiscard::AVDISCARD_ALL;
            }
        }
    }
}

fn color_of(frame: &Video, converted: bool) -> Color {
    let (kr, kb) = match frame.color_space() {
        Space::BT709 => BT709,
        Space::BT470BG | Space::SMPTE170M | Space::FCC => BT601,
        Space::BT2020NCL | Space::BT2020CL => BT2020,
        _ if frame.height() >= 720 => BT709,
        _ => BT601,
    };
    let full = !converted && (frame.color_range() == Range::JPEG || frame.format() == Pixel::YUVJ420P);
    Color { kr, kb, full }
}

fn yuv(frame: &Video, color: Color) -> Pixels {
    let (width, height) = (frame.width() as usize, frame.height() as usize);
    let (chroma_width, chroma_height) = (width.div_ceil(2), height.div_ceil(2));
    let luma = plane(frame, 0, width, height);
    let chroma = if frame.format() == Pixel::NV12 { plane(frame, 1, chroma_width * 2, chroma_height) } else { interleave(frame, chroma_width, chroma_height) };
    Pixels::Yuv { luma, chroma, color }
}

fn plane(frame: &Video, index: usize, row: usize, rows: usize) -> Vec<u8> {
    let (data, stride) = (frame.data(index), frame.stride(index));
    if stride == row {
        return data[..row * rows].to_vec();
    }
    let mut pixels = Vec::with_capacity(row * rows);
    for line in data.chunks(stride).take(rows) {
        pixels.extend_from_slice(&line[..row]);
    }
    pixels
}

fn interleave(frame: &Video, width: usize, height: usize) -> Vec<u8> {
    let (u, v) = (frame.data(1), frame.data(2));
    let (u_stride, v_stride) = (frame.stride(1), frame.stride(2));
    let mut pixels = vec![0u8; width * height * 2];
    for (y, line) in pixels.chunks_exact_mut(width * 2).enumerate() {
        let (u_line, v_line) = (&u[y * u_stride..y * u_stride + width], &v[y * v_stride..y * v_stride + width]);
        for ((pair, u), v) in line.chunks_exact_mut(2).zip(u_line).zip(v_line) {
            pair[0] = *u;
            pair[1] = *v;
        }
    }
    pixels
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fixture(name: &str) -> String {
        format!("{}/fixtures/{name}", env!("CARGO_MANIFEST_DIR"))
    }

    fn open(name: &str, output: Output) -> VideoSource {
        VideoSource::open(&fixture(name), output, false, &Arc::default()).unwrap()
    }

    fn frames(source: &mut VideoSource) -> Vec<Frame> {
        std::iter::from_fn(|| source.next(f64::NEG_INFINITY).unwrap()).collect()
    }

    #[test]
    fn h264_frames_keep_full_size_and_odd_chroma() {
        let mut source = open("motion_h264.mp4", Output::Yuv);
        let frames = frames(&mut source);
        assert_eq!(frames.len(), 12);
        assert!((frames[11].start - 11.0 / 24.0).abs() < 1e-3);
        let Some(Pixels::Yuv { luma, chroma, color }) = &frames[0].pixels else { panic!("expected yuv") };
        assert_eq!((frames[0].width, frames[0].height), (66, 38));
        assert_eq!(luma.len(), 66 * 38);
        assert_eq!(chroma.len(), 33 * 19 * 2);
        assert_eq!(*color, Color { kr: BT709.0, kb: BT709.1, full: false });
    }

    #[test]
    fn colorimetry_follows_the_stream() {
        let first = |name: &str| open(name, Output::Yuv).next(0.0).unwrap().unwrap();
        let Some(Pixels::Yuv { color, .. }) = first("motion_vp9.webm").pixels else { panic!("expected yuv") };
        assert_eq!(color, Color { kr: BT709.0, kb: BT709.1, full: false });
        let Some(Pixels::Yuv { color, .. }) = first("motion_full.webm").pixels else { panic!("expected yuv") };
        assert_eq!(color, Color { kr: BT601.0, kb: BT601.1, full: true });
    }

    #[test]
    fn rewinding_plays_the_video_again() {
        let mut source = open("motion_vp9.webm", Output::Yuv);
        assert_eq!(frames(&mut source).len(), 8);
        source.seek(0.0).unwrap();
        let again = frames(&mut source);
        assert_eq!(again.len(), 8);
        assert!(again[0].start.abs() < 1e-6);
    }

    #[test]
    fn seeking_lands_on_the_requested_time() {
        let mut source = open("motion_h264.mp4", Output::Yuv);
        assert!((source.length().unwrap() - 0.5).abs() < 0.05);
        source.seek(0.25).unwrap();
        let shown: Vec<Frame> = frames(&mut source).into_iter().filter(|frame| frame.start + frame.duration > 0.25).collect();
        assert!((shown[0].start - 6.0 / 24.0).abs() < 1e-3);
        assert_eq!(shown.len(), 6);
    }

    #[test]
    fn urls_stream_through_the_http_client() {
        let body = std::fs::read(fixture("motion_vp9.webm")).unwrap();
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
        let mut source = VideoSource::open(&format!("http://{address}/clip.webm"), Output::Yuv, false, &Arc::default()).unwrap();
        assert_eq!(frames(&mut source).len(), 8);
        source.seek(0.0).unwrap();
        assert!(source.next(0.0).unwrap().unwrap().pixels.is_some());
    }

    #[test]
    fn late_frames_skip_their_pixels() {
        let mut source = open("motion_h264.mp4", Output::Yuv);
        assert!(source.next(10.0).unwrap().unwrap().pixels.is_some());
        assert!(source.next(10.0).unwrap().unwrap().pixels.is_none());
    }

    #[test]
    fn av1_plays_in_software() {
        let mut source = open("motion_av1.webm", Output::Yuv);
        assert_eq!(source.decoder(), "libdav1d");
        assert_eq!(frames(&mut source).len(), 8);
    }

    #[test]
    fn posters_come_out_as_rgba() {
        let mut source = open("motion_full.webm", Output::Rgba);
        let frame = source.next(0.0).unwrap().unwrap();
        assert!(matches!(frame.pixels, Some(Pixels::Rgba(ref pixels)) if pixels.len() == 64 * 36 * 4));
    }
}
