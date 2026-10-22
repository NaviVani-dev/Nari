use std::collections::{BTreeMap, VecDeque};
use std::io::{self, Read, Seek, SeekFrom};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Condvar, Mutex, MutexGuard};

use symphonia::core::io::MediaSource;

pub const LIVE_CAPACITY: usize = 4 * 1024 * 1024;

#[derive(Default)]
struct Buffer {
    segments: BTreeMap<u64, VecDeque<u8>>,
    cursor: u64,
    wanted: Option<u64>,
    length: Option<u64>,
    done: bool,
    error: Option<String>,
    title: Option<String>,
}

impl Buffer {
    fn covering(&self, at: u64) -> Option<(u64, &VecDeque<u8>)> {
        let (start, bytes) = self.segments.range(..=at).next_back()?;
        (at < start + bytes.len() as u64).then_some((*start, bytes))
    }

    fn stored(&self) -> usize {
        self.segments.values().map(VecDeque::len).sum()
    }

    fn has_data(&self) -> bool {
        !self.segments.is_empty()
    }

    fn write(&mut self, bytes: &[u8]) {
        let at = self.cursor;
        self.cursor += bytes.len() as u64;
        let mut start = at;
        let mut data = VecDeque::new();
        if let Some((&key, segment)) = self.segments.range(..=at).next_back() {
            if key + segment.len() as u64 >= at {
                let mut segment = self.segments.remove(&key).unwrap_or_default();
                let tail = segment.split_off((at - key) as usize);
                if !tail.is_empty() {
                    self.segments.insert(at, tail);
                }
                start = key;
                data = segment;
            }
        }
        data.extend(bytes);
        let end = start + data.len() as u64;
        let following = self.segments.range(start..=end).map(|(key, _)| *key).collect::<Vec<_>>();
        for key in following {
            let segment = self.segments.remove(&key).unwrap_or_default();
            let overlap = (end - key) as usize;
            if segment.len() > overlap {
                data.extend(segment.range(overlap..));
            }
        }
        self.segments.insert(start, data);
        if self.wanted.is_some_and(|wanted| self.covering(wanted).is_some()) {
            self.wanted = None;
        }
    }

    fn first_gap(&self, from: u64) -> Option<u64> {
        let mut at = from;
        while let Some((start, bytes)) = self.covering(at) {
            at = start + bytes.len() as u64;
        }
        self.length.is_none_or(|length| at < length).then_some(at)
    }

    fn next_start(&self, after: u64) -> Option<u64> {
        self.segments.range(after + 1..).next().map(|(key, _)| *key)
    }
}

struct Shared {
    buffer: Mutex<Buffer>,
    ready: Condvar,
    closed: AtomicBool,
    live: AtomicBool,
    readers: AtomicUsize,
}

impl Shared {
    fn lock(&self) -> MutexGuard<'_, Buffer> {
        self.buffer.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
    }
}

pub struct Feed {
    shared: Arc<Shared>,
}

pub struct Stream {
    shared: Arc<Shared>,
    position: u64,
}

#[derive(Clone)]
pub struct Watch {
    shared: Arc<Shared>,
}

pub fn channel(live: bool, length: Option<u64>) -> (Feed, Stream) {
    let shared = Arc::new(Shared {
        buffer: Mutex::new(Buffer { length, ..Buffer::default() }),
        ready: Condvar::new(),
        closed: AtomicBool::new(false),
        live: AtomicBool::new(live),
        readers: AtomicUsize::new(1),
    });
    (Feed { shared: shared.clone() }, Stream { shared, position: 0 })
}

impl Feed {
    pub fn push(&self, bytes: &[u8]) -> bool {
        let shared = &self.shared;
        let mut buffer = shared.lock();
        while shared.live.load(Ordering::Relaxed) && buffer.stored() >= LIVE_CAPACITY && !self.closed() {
            buffer = shared.ready.wait(buffer).unwrap_or_else(|poisoned| poisoned.into_inner());
        }
        if self.closed() {
            return false;
        }
        buffer.write(bytes);
        drop(buffer);
        shared.ready.notify_all();
        true
    }

    pub fn push_at(&self, offset: u64, bytes: &[u8]) -> bool {
        if !self.shared.live.load(Ordering::Relaxed) {
            self.shared.lock().cursor = offset;
        }
        self.push(bytes)
    }

    pub fn wanted(&self) -> Option<u64> {
        self.shared.lock().wanted
    }

    pub fn covered(&self, at: u64) -> bool {
        self.shared.lock().covering(at).is_some()
    }

    pub fn first_gap(&self, from: u64) -> Option<u64> {
        self.shared.lock().first_gap(from)
    }

    pub fn next_start(&self, after: u64) -> Option<u64> {
        self.shared.lock().next_start(after)
    }

    pub fn set_length(&self, length: Option<u64>) {
        self.shared.lock().length = length;
    }

    pub fn set_live(&self) {
        self.shared.live.store(true, Ordering::Relaxed);
        self.shared.lock().length = None;
    }

    pub fn set_title(&self, title: String) {
        self.shared.lock().title = Some(title);
    }

    pub fn closed(&self) -> bool {
        self.shared.closed.load(Ordering::Relaxed)
    }

    pub fn fail(&self, error: String) {
        let mut buffer = self.shared.lock();
        if !buffer.done {
            buffer.error = Some(error);
        }
        buffer.done = true;
        drop(buffer);
        self.shared.ready.notify_all();
    }
}

impl Drop for Feed {
    fn drop(&mut self) {
        self.shared.lock().done = true;
        self.shared.ready.notify_all();
    }
}

impl Watch {
    pub fn title(&self) -> Option<String> {
        self.shared.lock().title.clone()
    }

    pub fn live(&self) -> bool {
        self.shared.live.load(Ordering::Relaxed)
    }

    pub fn buffered(&self) -> Vec<(f64, f64)> {
        let buffer = self.shared.lock();
        let Some(length) = buffer.length.filter(|length| *length > 0 && !self.live()) else {
            return Vec::new();
        };
        let total = length as f64;
        buffer
            .segments
            .iter()
            .map(|(start, bytes)| (*start as f64 / total, ((start + bytes.len() as u64) as f64 / total).min(1.0)))
            .collect()
    }
}

impl Stream {
    pub fn watch(&self) -> Watch {
        Watch { shared: self.shared.clone() }
    }

    pub fn wait_ready(&self, limit: std::time::Duration) -> bool {
        let until = std::time::Instant::now() + limit;
        let mut buffer = self.shared.lock();
        while !buffer.has_data() && !buffer.done {
            let left = until.saturating_duration_since(std::time::Instant::now());
            if left.is_zero() {
                return false;
            }
            buffer = self.shared.ready.wait_timeout(buffer, left).unwrap_or_else(|poisoned| poisoned.into_inner()).0;
        }
        true
    }

    pub fn reader(&self) -> Option<Stream> {
        if self.live() {
            return None;
        }
        self.shared.readers.fetch_add(1, Ordering::Relaxed);
        Some(Stream { shared: self.shared.clone(), position: 0 })
    }

    pub fn early_error(&self) -> Option<String> {
        let buffer = self.shared.lock();
        (!buffer.has_data()).then(|| buffer.error.clone()).flatten()
    }

    fn live(&self) -> bool {
        self.shared.live.load(Ordering::Relaxed)
    }
}

impl Read for Stream {
    fn read(&mut self, target: &mut [u8]) -> io::Result<usize> {
        let live = self.live();
        let mut buffer = self.shared.lock();
        loop {
            if let Some((start, bytes)) = buffer.covering(self.position) {
                let offset = (self.position - start) as usize;
                let (front, back) = bytes.as_slices();
                let count = if offset < front.len() {
                    let count = target.len().min(front.len() - offset);
                    target[..count].copy_from_slice(&front[offset..offset + count]);
                    count
                } else {
                    let at = offset - front.len();
                    let count = target.len().min(back.len() - at);
                    target[..count].copy_from_slice(&back[at..at + count]);
                    count
                };
                self.position += count as u64;
                if live {
                    let mut segment = buffer.segments.remove(&start).unwrap_or_default();
                    segment.drain(..(self.position - start) as usize);
                    if !segment.is_empty() {
                        buffer.segments.insert(self.position, segment);
                    }
                    drop(buffer);
                    self.shared.ready.notify_all();
                }
                return Ok(count);
            }
            if buffer.done || buffer.length.is_some_and(|length| self.position >= length) {
                return match &buffer.error {
                    Some(error) if buffer.done => Err(io::Error::other(error.clone())),
                    _ => Ok(0),
                };
            }
            buffer.wanted = Some(self.position);
            buffer = self.shared.ready.wait(buffer).unwrap_or_else(|poisoned| poisoned.into_inner());
        }
    }
}

impl Seek for Stream {
    fn seek(&mut self, target: SeekFrom) -> io::Result<u64> {
        let length = self.byte_len();
        let position = match target {
            SeekFrom::Start(offset) => Some(offset),
            SeekFrom::Current(offset) => self.position.checked_add_signed(offset),
            SeekFrom::End(offset) => length
                .ok_or_else(|| io::Error::new(io::ErrorKind::Unsupported, "unknown length"))?
                .checked_add_signed(offset),
        };
        let position = position.ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "seek before start"))?;
        if self.live() && position != self.position {
            return Err(io::Error::new(io::ErrorKind::Unsupported, "live streams can't seek"));
        }
        self.position = position;
        Ok(position)
    }
}

impl MediaSource for Stream {
    fn is_seekable(&self) -> bool {
        !self.live() && self.byte_len().is_some()
    }

    fn byte_len(&self) -> Option<u64> {
        self.shared.lock().length
    }
}

impl Drop for Stream {
    fn drop(&mut self) {
        if self.shared.readers.fetch_sub(1, Ordering::Relaxed) == 1 {
            self.shared.closed.store(true, Ordering::Relaxed);
            self.shared.ready.notify_all();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;

    #[test]
    fn whole_streams_keep_everything_and_seek() {
        let (feed, mut stream) = channel(false, Some(6));
        assert!(feed.push(b"abc"));
        assert!(feed.push(b"def"));
        drop(feed);
        stream.seek(SeekFrom::End(-2)).unwrap();
        let mut tail = String::new();
        stream.read_to_string(&mut tail).unwrap();
        assert_eq!(tail, "ef");
        stream.seek(SeekFrom::Start(0)).unwrap();
        let mut all = String::new();
        stream.read_to_string(&mut all).unwrap();
        assert_eq!(all, "abcdef");
        assert!(stream.is_seekable());
    }

    #[test]
    fn live_streams_stay_bounded_and_refuse_seeks() {
        let (feed, mut stream) = channel(true, None);
        let watch = stream.watch();
        let writer = std::thread::spawn(move || {
            let chunk = vec![7u8; 64 * 1024];
            let mut pushed = 0usize;
            while pushed < LIVE_CAPACITY * 3 && feed.push(&chunk) {
                pushed += chunk.len();
            }
            feed.set_title("Band - Song".into());
            pushed
        });
        std::thread::sleep(Duration::from_millis(100));
        assert!(stream.shared.lock().stored() <= LIVE_CAPACITY + 64 * 1024);
        let mut sink = vec![0u8; 256 * 1024];
        let mut read = 0usize;
        while read < LIVE_CAPACITY * 3 {
            read += stream.read(&mut sink).unwrap();
        }
        assert_eq!(writer.join().unwrap(), LIVE_CAPACITY * 3);
        assert_eq!(watch.title().as_deref(), Some("Band - Song"));
        assert!(watch.live() && !stream.is_seekable());
        assert!(stream.seek(SeekFrom::Start(0)).is_err());
        assert_eq!(stream.seek(SeekFrom::Current(0)).unwrap(), read as u64);
    }

    #[test]
    fn extra_readers_replay_the_download_and_keep_it_open() {
        let (feed, mut stream) = channel(false, Some(6));
        assert!(feed.push(b"abcdef"));
        let mut again = stream.reader().unwrap();
        let mut first = Vec::new();
        stream.read_to_end(&mut first).unwrap();
        drop(stream);
        assert!(!feed.closed());
        let mut second = Vec::new();
        again.read_to_end(&mut second).unwrap();
        assert_eq!(first, second);
        drop(again);
        assert!(feed.closed());
        assert!(channel(true, None).1.reader().is_none());
    }

    #[test]
    fn closing_the_reader_unblocks_the_writer() {
        let (feed, stream) = channel(true, None);
        let writer = std::thread::spawn(move || {
            let chunk = vec![1u8; 1024 * 1024];
            while feed.push(&chunk) {}
        });
        std::thread::sleep(Duration::from_millis(50));
        drop(stream);
        writer.join().unwrap();
    }

    #[test]
    fn writes_out_of_order_merge_and_report_gaps() {
        let (feed, mut stream) = channel(false, Some(10));
        let watch = stream.watch();
        assert!(feed.push_at(6, b"ghij"));
        assert!(feed.push_at(0, b"abc"));
        assert_eq!(watch.buffered(), vec![(0.0, 0.3), (0.6, 1.0)]);
        assert_eq!((feed.first_gap(0), feed.next_start(3)), (Some(3), Some(6)));
        let reader = std::thread::spawn(move || {
            stream.seek(SeekFrom::Start(2)).unwrap();
            let mut all = String::new();
            stream.read_to_string(&mut all).unwrap();
            all
        });
        while feed.wanted() != Some(3) {
            std::thread::sleep(Duration::from_millis(5));
        }
        assert!(feed.push_at(2, b"cdefgh"));
        assert_eq!(feed.wanted(), None);
        assert_eq!(feed.first_gap(0), None);
        assert_eq!(reader.join().unwrap(), "cdefghij");
        assert_eq!(watch.buffered(), vec![(0.0, 1.0)]);
    }

    #[test]
    fn failures_reach_the_reader() {
        let (feed, mut stream) = channel(false, None);
        feed.push(b"ok");
        feed.fail("gone".into());
        let mut bytes = Vec::new();
        let error = stream.read_to_end(&mut bytes).unwrap_err();
        assert_eq!(bytes, b"ok");
        assert_eq!(error.to_string(), "gone");
    }
}
