use std::collections::{HashMap, HashSet};
use std::sync::mpsc::{Receiver, Sender, channel};
use std::sync::{Arc, Mutex, OnceLock};

use image::AnimationDecoder;

use super::super::{Bitmap, MAX_BITMAP_SIDE, Rgb};
use super::Box2;

const MAX_DECODED: usize = 256 * 1024 * 1024;
const MAX_ANIMATION: usize = 128 * 1024 * 1024;
const MAX_STRIP_SAMPLES: u32 = 256 * 1024;
const STRIP_NOISE: i32 = 24;
const STRIP_MARGIN: f64 = 24.0;
const STRIP_CLEAR_SHARE: usize = 10;

#[derive(Clone, Debug, Default, PartialEq, Eq, Hash)]
pub struct ImageKey {
    pub file: String,
    pub clear: Vec<Rgb>,
    pub clear_corner: bool,
    pub window_only_clear: bool,
    pub mask: Option<(String, Rgb)>,
    pub cut: Option<(String, Option<Rgb>)>,
}

pub struct Frame {
    pub bitmap: Bitmap,
    pub delay_ms: u32,
}

pub struct Picture {
    pub frames: Vec<Frame>,
    pub origin: (i32, i32),
    pub size: (u32, u32),
    total_ms: u64,
    loops: Option<u32>,
    runs: OnceLock<Arc<Vec<Box2>>>,
    reversed: Mutex<HashMap<(String, Strip), bool>>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct Strip {
    pub width: u32,
    pub height: u32,
    pub count: u32,
    pub across: bool,
}

impl Picture {
    fn new(frames: Vec<Frame>, origin: (i32, i32), size: (u32, u32)) -> Self {
        let total_ms = frames.iter().map(|frame| u64::from(frame.delay_ms)).sum();
        Self {
            frames,
            origin,
            size,
            total_ms,
            loops: None,
            runs: OnceLock::new(),
            reversed: Mutex::new(HashMap::new()),
        }
    }

    pub fn strip_reversed(&self, map_name: &str, map: &Bitmap, strip: Strip) -> bool {
        let Ok(mut known) = self.reversed.lock() else {
            return false;
        };
        *known
            .entry((map_name.to_owned(), strip))
            .or_insert_with(|| {
                self.frames
                    .first()
                    .is_some_and(|frame| strip_runs_backwards(&frame.bitmap, map, strip))
            })
    }

    pub fn runs(&self) -> Arc<Vec<Box2>> {
        self.runs
            .get_or_init(|| {
                let Some(frame) = self.frames.first() else {
                    return Arc::new(Vec::new());
                };
                Arc::new(solid_runs(&frame.bitmap, self.origin))
            })
            .clone()
    }

    pub fn frame_at(&self, elapsed_ms: u64) -> (usize, Option<u64>) {
        if self.frames.len() < 2 || self.total_ms == 0 {
            return (0, None);
        }
        if let Some(loops) = self.loops
            && elapsed_ms >= self.total_ms.saturating_mul(u64::from(loops))
        {
            return (self.frames.len() - 1, None);
        }
        let mut left = elapsed_ms % self.total_ms;
        for (index, frame) in self.frames.iter().enumerate() {
            let delay = u64::from(frame.delay_ms);
            if left < delay {
                return (index, Some(delay - left));
            }
            left -= delay;
        }
        (0, Some(1))
    }

    fn bytes(&self) -> usize {
        self.frames
            .iter()
            .map(|frame| frame.bitmap.rgba.len())
            .sum()
    }
}

fn solid_runs(bitmap: &Bitmap, origin: (i32, i32)) -> Vec<Box2> {
    let mut boxes: Vec<Box2> = Vec::new();
    let mut open: Vec<usize> = Vec::new();
    for y in 0..bitmap.height {
        let mut row: Vec<(i32, i32)> = Vec::new();
        let mut start = None;
        for x in 0..=bitmap.width {
            let solid = bitmap.pixel(x, y).is_some_and(|pixel| pixel[3] > 0);
            match (solid, start) {
                (true, None) => start = Some(x as i32),
                (false, Some(from)) => {
                    row.push((from, x as i32 - from));
                    start = None;
                }
                _ => {}
            }
        }
        let top = y as i32 + origin.1;
        let mut still_open = Vec::with_capacity(row.len());
        for (x, width) in row {
            let left = x + origin.0;
            let joined = open.iter().copied().find(|at| {
                let run: &Box2 = &boxes[*at];
                run.x == left && run.width == width
            });
            match joined {
                Some(at) => {
                    boxes[at].height += 1;
                    still_open.push(at);
                }
                None => {
                    boxes.push(Box2 {
                        x: left,
                        y: top,
                        width,
                        height: 1,
                    });
                    still_open.push(boxes.len() - 1);
                }
            }
        }
        open = still_open;
    }
    boxes
}

fn strip_runs_backwards(bitmap: &Bitmap, map: &Bitmap, strip: Strip) -> bool {
    let Strip {
        width,
        height,
        count,
        across,
    } = strip;
    if count < 3 || width == 0 || height == 0 {
        return false;
    }
    let pixel_of = |frame: u32, x: u32, y: u32| {
        let (x, y) = if across {
            (x + frame * width, y)
        } else {
            (x, y + frame * height)
        };
        bitmap.pixel(x, y)
    };
    let same = |a: [u8; 4], b: [u8; 4]| {
        (a[3] == 0 && b[3] == 0)
            || a.iter()
                .zip(b)
                .all(|(a, b)| (i32::from(*a) - i32::from(b)).abs() <= STRIP_NOISE)
    };
    let pixels = u64::from(width) * u64::from(height);
    let step = ((pixels / u64::from(MAX_STRIP_SAMPLES)) as f64)
        .sqrt()
        .ceil()
        .max(1.0) as usize;
    let (last, middle) = (count - 1, (count - 1) / 2);
    let (mut differing, mut first_at, mut last_at) = (0usize, (0u64, 0usize), (0u64, 0usize));
    for y in (0..height).step_by(step) {
        for x in (0..width).step_by(step) {
            let (Some(a), Some(z), Some(m)) = (
                pixel_of(0, x, y),
                pixel_of(last, x, y),
                pixel_of(middle, x, y),
            ) else {
                continue;
            };
            if same(a, z) {
                continue;
            }
            differing += 1;
            let tally = match (same(a, m), same(z, m)) {
                (false, true) => &mut first_at,
                (true, false) => &mut last_at,
                _ => continue,
            };
            if let Some(place) = map.pixel(x, y)
                && place[0] == place[1]
                && place[1] == place[2]
            {
                tally.0 += u64::from(place[0]);
                tally.1 += 1;
            }
        }
    }
    let clear = first_at.1 + last_at.1;
    if first_at.1 == 0 || last_at.1 == 0 || clear * STRIP_CLEAR_SHARE < differing {
        return false;
    }
    let mean = |(sum, count): (u64, usize)| sum as f64 / count as f64;
    mean(first_at) - mean(last_at) >= STRIP_MARGIN
}

fn gif_loops(bytes: &[u8]) -> Option<u32> {
    let marker = b"NETSCAPE2.0";
    let Some(at) = bytes.windows(marker.len()).position(|part| part == marker) else {
        return Some(1);
    };
    let block = bytes.get(at + marker.len()..at + marker.len() + 4)?;
    let count = u16::from_le_bytes([block[2], block[3]]);
    (count != 0).then_some(u32::from(count) + 1)
}

fn frames_of(bytes: &[u8]) -> Option<Vec<Frame>> {
    if bytes.starts_with(b"GIF8") {
        let decoder = image::codecs::gif::GifDecoder::new(std::io::Cursor::new(bytes)).ok()?;
        let (width, height) = image::ImageDecoder::dimensions(&decoder);
        if width > MAX_BITMAP_SIDE || height > MAX_BITMAP_SIDE {
            return None;
        }
        let mut frames = Vec::new();
        let mut total = 0usize;
        for frame in decoder.into_frames() {
            let Ok(frame) = frame else {
                break;
            };
            let (numerator, denominator) = frame.delay().numer_denom_ms();
            let delay_ms = (numerator / denominator.max(1)).max(20);
            let buffer = frame.into_buffer();
            total = total.saturating_add(buffer.as_raw().len());
            if total > MAX_ANIMATION {
                break;
            }
            frames.push(Frame {
                bitmap: Bitmap {
                    width: buffer.width(),
                    height: buffer.height(),
                    rgba: buffer.into_raw(),
                },
                delay_ms,
            });
        }
        if !frames.is_empty() {
            return Some(frames);
        }
    }
    Some(vec![Frame {
        bitmap: Bitmap::decode(bytes)?,
        delay_ms: 0,
    }])
}

pub fn region_of(bitmap: &Bitmap, color: Rgb) -> Option<(i32, i32, i32, i32)> {
    let (mut x0, mut y0, mut x1, mut y1) = (i32::MAX, i32::MAX, -1, -1);
    for y in 0..bitmap.height {
        for x in 0..bitmap.width {
            if bitmap.pixel(x, y).is_some_and(|p| p[..3] == color) {
                x0 = x0.min(x as i32);
                y0 = y0.min(y as i32);
                x1 = x1.max(x as i32);
                y1 = y1.max(y as i32);
            }
        }
    }
    (x1 >= 0).then_some((x0, y0, x1 - x0 + 1, y1 - y0 + 1))
}

pub fn decode(files: &HashMap<String, Vec<u8>>, key: &ImageKey) -> Option<Picture> {
    let bytes = files.get(&key.file)?;
    let loops = if bytes.starts_with(b"GIF8") {
        gif_loops(bytes)
    } else {
        None
    };
    let mut picture = decode_frames(files, bytes, key)?;
    picture.loops = loops;
    Some(picture)
}

fn decode_frames(
    files: &HashMap<String, Vec<u8>>,
    bytes: &[u8],
    key: &ImageKey,
) -> Option<Picture> {
    let mut frames = frames_of(bytes)?;
    let corner: Option<Rgb> = key.clear_corner.then(|| {
        frames
            .first()
            .and_then(|frame| frame.bitmap.pixel(0, 0))
            .map_or([0; 3], |pixel| [pixel[0], pixel[1], pixel[2]])
    });
    let mut clear: Vec<Rgb> = key.clear.iter().copied().chain(corner).collect();
    if key.window_only_clear {
        let has_window = frames.first().is_some_and(|frame| {
            frame
                .bitmap
                .rgba
                .as_chunks::<4>()
                .0
                .iter()
                .any(|p| p[3] == 0)
        });
        if !has_window {
            clear.clear();
        }
        for frame in &mut frames {
            for pixel in frame.bitmap.rgba.as_chunks_mut::<4>().0 {
                pixel[3] = 255;
            }
        }
    }
    for frame in &mut frames {
        if !clear.is_empty() {
            for pixel in frame.bitmap.rgba.as_chunks_mut::<4>().0 {
                if clear.iter().any(|clear| pixel[..3] == *clear) {
                    *pixel = [0, 0, 0, 0];
                }
            }
        }
    }
    if let Some((clip_file, color)) = &key.cut
        && let Some(clip) = files.get(clip_file).and_then(|bytes| Bitmap::decode(bytes))
    {
        let color = color.or_else(|| clip.pixel(0, 0).map(|pixel| [pixel[0], pixel[1], pixel[2]]));
        for frame in &mut frames {
            let width = frame.bitmap.width as usize;
            for (at, pixel) in frame
                .bitmap
                .rgba
                .as_chunks_mut::<4>()
                .0
                .iter_mut()
                .enumerate()
            {
                let (x, y) = ((at % width.max(1)) as u32, (at / width.max(1)) as u32);
                if clip
                    .pixel(x, y)
                    .is_some_and(|mask| Some([mask[0], mask[1], mask[2]]) == color)
                {
                    *pixel = [0, 0, 0, 0];
                }
            }
        }
    }
    let first = frames.first()?;
    let size = (first.bitmap.width, first.bitmap.height);
    let Some((map_file, color)) = &key.mask else {
        return Some(Picture::new(frames, (0, 0), size));
    };
    let map = Bitmap::decode(files.get(map_file)?)?;
    let (x, y, width, height) = region_of(&map, *color)?;
    let area = super::super::Area {
        x: x as u32,
        y: y as u32,
        width: width as u32,
        height: height as u32,
    };
    let mut kept = Vec::with_capacity(frames.len());
    for frame in frames {
        let delay_ms = frame.delay_ms;
        let Some(mut bitmap) = frame.bitmap.crop(area) else {
            continue;
        };
        let (kept_width, kept_height) = (bitmap.width, bitmap.height);
        for row in 0..kept_height {
            for column in 0..kept_width {
                let on = map
                    .pixel(area.x + column, area.y + row)
                    .is_some_and(|pixel| pixel[..3] == *color);
                if !on {
                    let at = 4 * (row * kept_width + column) as usize;
                    bitmap.rgba[at..at + 4].fill(0);
                }
            }
        }
        kept.push(Frame { bitmap, delay_ms });
    }
    (!kept.is_empty()).then(|| Picture::new(kept, (x, y), size))
}

type Decoded = (ImageKey, Option<Arc<Picture>>);

pub struct Images {
    ready: HashMap<ImageKey, (Arc<Picture>, u64)>,
    asked: HashSet<ImageKey>,
    missing: HashSet<ImageKey>,
    to_worker: Sender<ImageKey>,
    from_worker: Receiver<Decoded>,
    decoded_bytes: usize,
    clock: u64,
    pub arrivals: u64,
}

impl Images {
    pub fn new(files: Arc<HashMap<String, Vec<u8>>>, arrived: impl Fn() + Send + 'static) -> Self {
        let (to_worker, requests) = channel::<ImageKey>();
        let (answers, from_worker) = channel();
        let started = std::thread::Builder::new()
            .name("skin-pictures".into())
            .spawn(move || {
                for key in requests {
                    let picture = decode(&files, &key).map(Arc::new);
                    if answers.send((key, picture)).is_err() {
                        break;
                    }
                    arrived();
                }
            });
        let _ = started;
        Self {
            ready: HashMap::new(),
            asked: HashSet::new(),
            missing: HashSet::new(),
            to_worker,
            from_worker,
            decoded_bytes: 0,
            clock: 0,
            arrivals: 0,
        }
    }

    pub fn poll(&mut self) {
        while let Ok((key, picture)) = self.from_worker.try_recv() {
            self.asked.remove(&key);
            self.arrivals = self.arrivals.wrapping_add(1);
            match picture {
                Some(picture) => {
                    self.decoded_bytes = self.decoded_bytes.saturating_add(picture.bytes());
                    self.clock += 1;
                    self.ready.insert(key, (picture, self.clock));
                    self.shrink();
                }
                None => {
                    if !key.file.is_empty() {
                    }
                    self.missing.insert(key);
                }
            }
        }
    }

    fn shrink(&mut self) {
        while self.decoded_bytes > MAX_DECODED && self.ready.len() > 1 {
            let Some(oldest) = self
                .ready
                .iter()
                .min_by_key(|(_, (_, used))| *used)
                .map(|(key, _)| key.clone())
            else {
                return;
            };
            if let Some((picture, _)) = self.ready.remove(&oldest) {
                self.decoded_bytes = self.decoded_bytes.saturating_sub(picture.bytes());
            }
        }
    }

    pub fn get(&mut self, key: &ImageKey) -> Option<Arc<Picture>> {
        self.clock += 1;
        let clock = self.clock;
        if let Some((picture, used)) = self.ready.get_mut(key) {
            *used = clock;
            return Some(picture.clone());
        }
        if !self.asked.contains(key)
            && !self.missing.contains(key)
            && self.to_worker.send(key.clone()).is_ok()
        {
            self.asked.insert(key.clone());
        }
        None
    }

    pub fn loading(&self) -> bool {
        !self.asked.is_empty()
    }
}
