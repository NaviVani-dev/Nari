use std::io::{self, Read};
use std::sync::OnceLock;
use std::time::{Duration, Instant};

use crate::stream::{Feed, Stream};

const CHUNK: usize = 64 * 1024;
const RANGE: u64 = 1024 * 1024;
const LOOKAHEAD: u64 = 512 * 1024;
const RETRIES: u32 = 3;
const MAX_BACKOFF: u32 = 4;
const WAIT_STEP: Duration = Duration::from_millis(200);
const LIVE_RETRIES: u32 = 5;
const PLAYLIST_LIMIT: u64 = 1024 * 1024;
const SEGMENT_LIMIT: u64 = 64 * 1024 * 1024;
const PLAYLIST_DEPTH: u32 = 3;
const CONNECT_TIMEOUT: Duration = Duration::from_secs(10);
const RESPONSE_TIMEOUT: Duration = Duration::from_secs(20);
const PLAYLIST_TYPES: [&str; 6] = ["mpegurl", "x-scpls", "pls+xml", "x-mpegurl", "vnd.apple.mpegurl", "audio/m3u"];

pub fn is_remote(uri: &str) -> bool {
    uri.starts_with("http://") || uri.starts_with("https://")
}

pub fn agent() -> &'static ureq::Agent {
    static AGENT: OnceLock<ureq::Agent> = OnceLock::new();
    AGENT.get_or_init(|| {
        ureq::Agent::config_builder()
            .timeout_connect(Some(CONNECT_TIMEOUT))
            .timeout_recv_response(Some(RESPONSE_TIMEOUT))
            .build()
            .into()
    })
}

type Response = ureq::http::Response<ureq::Body>;

pub fn open(url: &str) -> io::Result<Stream> {
    open_at(url, 0)
}

fn open_at(url: &str, depth: u32) -> io::Result<Stream> {
    if url.to_lowercase().split(['?', '#']).next().unwrap_or("").ends_with(".m3u8") {
        return crate::hls::open(url, &fetch_text(url)?);
    }
    let response = agent()
        .get(url)
        .header("Range", format!("bytes=0-{}", RANGE - 1))
        .header("Icy-MetaData", "1")
        .call()
        .map_err(io::Error::other)?;
    let content_type = header_text(&response, "content-type").to_lowercase();
    if depth < PLAYLIST_DEPTH && (is_playlist_name(url) || PLAYLIST_TYPES.iter().any(|kind| content_type.contains(kind))) {
        let text = read_text(response)?;
        if text.contains("#EXT-X-") {
            return crate::hls::open(url, &text);
        }
        let entry = playlist_entries(&text)
            .into_iter()
            .next()
            .ok_or_else(|| io::Error::other("the playlist has no streams"))?;
        return open_at(&join(url, &entry), depth + 1);
    }
    let ranged = response.status().as_u16() == 206;
    let metaint = header_number(&response, "icy-metaint").filter(|interval| *interval > 0);
    let length = if ranged { total_of(&response) } else { header_number(&response, "content-length") };
    let live = metaint.is_some() || (!ranged && length.is_none());
    let (feed, stream) = crate::stream::channel(live, if live { None } else { length });
    if live {
        let url = url.to_owned();
        let first = response.into_body().into_reader();
        std::thread::spawn(move || {
            if let Err(error) = keep_live(&feed, Box::new(first), metaint, &url) {
                feed.fail(error.to_string());
            }
        });
        return Ok(stream);
    }
    let first: Box<dyn Read + Send> = Box::new(response.into_body().into_reader());
    let url = url.to_owned();
    std::thread::spawn(move || {
        let result = match (ranged, length) {
            (true, Some(total)) => download_ranges(&feed, first, &url, total),
            _ => drain(&feed, first, &mut 0),
        };
        if let Err(error) = result {
            feed.fail(error.to_string());
        }
    });
    Ok(stream)
}

pub fn fetch_text(url: &str) -> io::Result<String> {
    read_text(agent().get(url).call().map_err(io::Error::other)?)
}

fn read_text(response: Response) -> io::Result<String> {
    let mut bytes = Vec::new();
    response.into_body().into_reader().take(PLAYLIST_LIMIT).read_to_end(&mut bytes)?;
    Ok(String::from_utf8_lossy(&bytes).into_owned())
}

pub fn fetch_bytes(url: &str) -> io::Result<Vec<u8>> {
    let mut bytes = Vec::new();
    let response = agent().get(url).call().map_err(io::Error::other)?;
    response.into_body().into_reader().take(SEGMENT_LIMIT + 1).read_to_end(&mut bytes)?;
    if bytes.len() as u64 > SEGMENT_LIMIT {
        return Err(io::Error::new(io::ErrorKind::FileTooLarge, "the stream segment is too big"));
    }
    Ok(bytes)
}

fn is_playlist_name(url: &str) -> bool {
    let path = url.to_lowercase();
    let path = path.split(['?', '#']).next().unwrap_or("");
    path.ends_with(".m3u") || path.ends_with(".pls")
}

pub fn playlist_entries(text: &str) -> Vec<String> {
    text.lines()
        .map(str::trim)
        .filter_map(|line| match line.split_once('=') {
            Some((key, value)) if key.to_lowercase().starts_with("file") => Some(value.trim()),
            _ if line.is_empty() || line.starts_with('#') || line.starts_with('[') || line.contains('=') && !line.contains("://") => None,
            _ => Some(line),
        })
        .map(str::to_owned)
        .collect()
}

pub fn join(base: &str, target: &str) -> String {
    if is_remote(target) {
        return target.to_owned();
    }
    let scheme_end = base.find("://").map_or(0, |at| at + 3);
    if target.starts_with('/') {
        let host_end = base[scheme_end..].find('/').map_or(base.len(), |at| scheme_end + at);
        return format!("{}{}", &base[..host_end], target);
    }
    let path = base.split(['?', '#']).next().unwrap_or(base);
    let folder = path.rfind('/').filter(|at| *at >= scheme_end).map_or(path, |at| &path[..=at]);
    format!("{folder}{target}")
}

fn header_text(response: &Response, name: &str) -> String {
    response.headers().get(name).and_then(|value| value.to_str().ok()).unwrap_or("").trim().to_owned()
}

fn header_number(response: &Response, name: &str) -> Option<u64> {
    header_text(response, name).parse().ok()
}

fn total_of(response: &Response) -> Option<u64> {
    header_text(response, "content-range").rsplit_once('/')?.1.parse().ok()
}

fn drain(feed: &Feed, mut reader: Box<dyn Read + Send>, received: &mut u64) -> io::Result<()> {
    let mut chunk = vec![0u8; CHUNK];
    while !feed.closed() {
        match reader.read(&mut chunk) {
            Ok(0) => return Ok(()),
            Ok(read) => {
                if !feed.push(&chunk[..read]) {
                    return Ok(());
                }
                *received += read as u64;
            }
            Err(error) if error.kind() == io::ErrorKind::Interrupted => {}
            Err(error) => return Err(error),
        }
    }
    Ok(())
}

#[derive(Debug)]
struct Refused(u16);

impl std::fmt::Display for Refused {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(formatter, "the server answered {} to a range", self.0)
    }
}

impl std::error::Error for Refused {}

fn refused(error: &io::Error) -> bool {
    error.get_ref().is_some_and(|inner| inner.is::<Refused>())
}

fn rest(feed: &Feed, attempt: u32) {
    let until = Instant::now() + Duration::from_secs(1 << attempt.min(MAX_BACKOFF));
    while !feed.closed() && Instant::now() < until {
        std::thread::sleep(WAIT_STEP);
    }
}

fn request_range(url: &str, start: u64, end: u64) -> io::Result<Box<dyn Read + Send>> {
    let response = agent().get(url).header("Range", format!("bytes={start}-{end}")).call().map_err(|error| match error {
        ureq::Error::StatusCode(code) => io::Error::other(Refused(code)),
        other => io::Error::other(other),
    })?;
    if response.status().as_u16() != 206 {
        return Err(io::Error::other(Refused(response.status().as_u16())));
    }
    Ok(Box::new(response.into_body().into_reader()))
}

fn pump(feed: &Feed, mut reader: Box<dyn Read + Send>, at: &mut u64) -> io::Result<()> {
    let mut chunk = vec![0u8; CHUNK];
    while !feed.closed() {
        match reader.read(&mut chunk) {
            Ok(0) => return Ok(()),
            Ok(read) => {
                if !feed.push_at(*at, &chunk[..read]) {
                    return Ok(());
                }
                *at += read as u64;
                if feed.covered(*at) || feed.wanted().is_some_and(|wanted| wanted < *at || wanted > *at + LOOKAHEAD) {
                    return Ok(());
                }
            }
            Err(error) if error.kind() == io::ErrorKind::Interrupted => {}
            Err(error) => return Err(error),
        }
    }
    Ok(())
}

fn download_ranges(feed: &Feed, first: Box<dyn Read + Send>, url: &str, total: u64) -> io::Result<()> {
    let mut at = 0u64;
    let mut next = Ok(first);
    let mut refusals = 0;
    let mut stalls = 0;
    loop {
        let start = at;
        let outcome = next.and_then(|reader| pump(feed, reader, &mut at));
        if feed.closed() {
            return Ok(());
        }
        match outcome {
            _ if at > start => (refusals, stalls) = (0, 0),
            Err(error) if refused(&error) => {
                refusals += 1;
                if refusals > RETRIES {
                    return Err(error);
                }
            }
            _ => {
                rest(feed, stalls);
                stalls += 1;
            }
        }
        let Some(from) = feed
            .wanted()
            .filter(|wanted| !feed.covered(*wanted))
            .or_else(|| feed.first_gap(at))
            .or_else(|| feed.first_gap(0))
        else {
            return Ok(());
        };
        let end = feed.next_start(from).unwrap_or(total).min(from + RANGE).min(total);
        at = from;
        next = request_range(url, from, end - 1);
    }
}

fn keep_live(feed: &Feed, first: Box<dyn Read + Send>, metaint: Option<u64>, url: &str) -> io::Result<()> {
    let mut reader = Some(first);
    let mut metaint = metaint;
    let mut failures = 0;
    loop {
        let outcome = match reader.take() {
            Some(reader) => pump_live(feed, reader, metaint),
            None => Ok(false),
        };
        if feed.closed() {
            return Ok(());
        }
        match outcome {
            Ok(true) => failures = 0,
            Ok(false) => failures += 1,
            Err(error) if failures >= LIVE_RETRIES => return Err(error),
            Err(_) => failures += 1,
        }
        if failures > LIVE_RETRIES {
            return Err(io::Error::other("the station stopped sending audio"));
        }
        std::thread::sleep(Duration::from_secs(1 << failures.min(4)));
        if let Ok(response) = agent().get(url).header("Icy-MetaData", "1").call() {
            metaint = header_number(&response, "icy-metaint").filter(|interval| *interval > 0);
            reader = Some(Box::new(response.into_body().into_reader()));
        }
    }
}

fn pump_live(feed: &Feed, mut reader: Box<dyn Read + Send>, metaint: Option<u64>) -> io::Result<bool> {
    let mut icy = metaint.map(|interval| Icy::new(interval as usize));
    let mut chunk = vec![0u8; CHUNK];
    let mut audio = Vec::with_capacity(CHUNK);
    let mut received = false;
    while !feed.closed() {
        let read = match reader.read(&mut chunk) {
            Ok(0) => return Ok(received),
            Ok(read) => read,
            Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
            Err(_) if received => return Ok(true),
            Err(error) => return Err(error),
        };
        received = true;
        audio.clear();
        match icy.as_mut() {
            Some(icy) => {
                if let Some(title) = icy.feed(&chunk[..read], &mut audio) {
                    feed.set_title(title);
                }
            }
            None => audio.extend_from_slice(&chunk[..read]),
        }
        if !audio.is_empty() && !feed.push(&audio) {
            break;
        }
    }
    Ok(received)
}

struct Icy {
    interval: usize,
    until_meta: usize,
    meta_left: Option<usize>,
    meta: Vec<u8>,
}

impl Icy {
    fn new(interval: usize) -> Self {
        Self { interval, until_meta: interval, meta_left: None, meta: Vec::new() }
    }

    fn feed(&mut self, mut input: &[u8], audio: &mut Vec<u8>) -> Option<String> {
        let mut title = None;
        while !input.is_empty() {
            match self.meta_left {
                None if self.until_meta > 0 => {
                    let take = self.until_meta.min(input.len());
                    audio.extend_from_slice(&input[..take]);
                    self.until_meta -= take;
                    input = &input[take..];
                }
                None => {
                    self.meta_left = Some(input[0] as usize * 16);
                    self.meta.clear();
                    input = &input[1..];
                }
                Some(left) => {
                    let take = left.min(input.len());
                    self.meta.extend_from_slice(&input[..take]);
                    input = &input[take..];
                    if take == left {
                        self.meta_left = None;
                        self.until_meta = self.interval;
                        if let Some(found) = stream_title(&self.meta) {
                            title = Some(found);
                        }
                    } else {
                        self.meta_left = Some(left - take);
                    }
                }
            }
        }
        title
    }
}

fn stream_title(meta: &[u8]) -> Option<String> {
    let end = meta.iter().position(|byte| *byte == 0).unwrap_or(meta.len());
    let text = match std::str::from_utf8(&meta[..end]) {
        Ok(text) => text.to_owned(),
        Err(_) => meta[..end].iter().map(|byte| *byte as char).collect(),
    };
    let start = text.find("StreamTitle='")? + "StreamTitle='".len();
    let rest = &text[start..];
    let value = rest.find("';").map_or(rest.trim_end_matches('\''), |at| &rest[..at]);
    Some(value.trim().to_owned())
}

pub fn fetch_cover(url: String, path: String) {
    std::thread::spawn(move || {
        let Ok(mut response) = agent().get(&url).call() else {
            return;
        };
        let Ok(bytes) = response.body_mut().read_to_vec() else {
            return;
        };
        let Ok(image) = image::load_from_memory(&bytes) else {
            return;
        };
        let target = std::path::Path::new(&path);
        if let Some(parent) = target.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        let partial = target.with_extension("part");
        if image.to_rgb8().save_with_format(&partial, image::ImageFormat::Jpeg).is_ok() {
            let _ = std::fs::rename(&partial, target);
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{Seek, SeekFrom, Write};
    use symphonia::core::io::MediaSource;
    use std::net::TcpListener;

    #[test]
    fn streams_and_seeks_inside_the_download() {
        let body: Vec<u8> = (0..300_000u32).map(|value| (value % 251) as u8).collect();
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let served = body.clone();
        std::thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let mut request = [0u8; 1024];
            let _ = stream.read(&mut request);
            write!(stream, "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n", served.len()).unwrap();
            stream.write_all(&served).unwrap();
        });
        let mut source = open(&format!("http://{address}/stream")).unwrap();
        assert_eq!(source.byte_len(), Some(body.len() as u64));
        assert!(source.is_seekable());
        source.seek(SeekFrom::End(-10)).unwrap();
        let mut tail = Vec::new();
        source.read_to_end(&mut tail).unwrap();
        assert_eq!(tail, body[body.len() - 10..]);
        source.seek(SeekFrom::Start(0)).unwrap();
        let mut all = Vec::new();
        source.read_to_end(&mut all).unwrap();
        assert_eq!(all, body);
        assert!(is_remote("https://music.example/rest/stream") && !is_remote("content://media/1"));
    }

    #[test]
    fn servers_with_ranges_are_read_a_range_at_a_time() {
        let body: Vec<u8> = (0..(RANGE as u32 * 2 + 12_345)).map(|value| (value % 253) as u8).collect();
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let served = body.clone();
        std::thread::spawn(move || {
            for connection in listener.incoming() {
                let mut stream = connection.unwrap();
                let mut request = [0u8; 2048];
                let size = stream.read(&mut request).unwrap();
                let request = String::from_utf8_lossy(&request[..size]).to_lowercase();
                let range = request.split("range: bytes=").nth(1).unwrap().split("\r\n").next().unwrap().to_owned();
                let (start, end) = range.split_once('-').unwrap();
                let start: usize = start.parse().unwrap();
                let end: usize = end.parse::<usize>().unwrap().min(served.len() - 1);
                let cut = if start == 0 { (end + 1) / 2 } else { end + 1 };
                write!(
                    stream,
                    "HTTP/1.1 206 Partial Content\r\nContent-Length: {}\r\nContent-Range: bytes {start}-{end}/{}\r\nConnection: close\r\n\r\n",
                    end + 1 - start,
                    served.len()
                )
                .unwrap();
                let _ = stream.write_all(&served[start..cut]);
            }
        });
        let mut source = open(&format!("http://{address}/stream")).unwrap();
        assert_eq!(source.byte_len(), Some(body.len() as u64));
        let mut all = Vec::new();
        source.read_to_end(&mut all).unwrap();
        assert_eq!(all.len(), body.len());
        assert!(all == body);
    }

    #[test]
    fn dropped_connections_wait_for_the_network_and_resume() {
        let body: Vec<u8> = (0..(RANGE as u32 + 4_321)).map(|value| (value % 239) as u8).collect();
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let served = body.clone();
        std::thread::spawn(move || {
            for (attempt, connection) in listener.incoming().enumerate() {
                let mut stream = connection.unwrap();
                let mut request = [0u8; 2048];
                let size = stream.read(&mut request).unwrap();
                if attempt == 1 {
                    continue;
                }
                let request = String::from_utf8_lossy(&request[..size]).to_lowercase();
                let range = request.split("range: bytes=").nth(1).unwrap().split("\r\n").next().unwrap().to_owned();
                let (start, end) = range.split_once('-').unwrap();
                let start: usize = start.parse().unwrap();
                let end: usize = end.parse::<usize>().unwrap().min(served.len() - 1);
                let cut = if attempt == 0 { (end + 1) / 2 } else { end + 1 };
                write!(
                    stream,
                    "HTTP/1.1 206 Partial Content\r\nContent-Length: {}\r\nContent-Range: bytes {start}-{end}/{}\r\nConnection: close\r\n\r\n",
                    end + 1 - start,
                    served.len()
                )
                .unwrap();
                let _ = stream.write_all(&served[start..cut]);
            }
        });
        let mut source = open(&format!("http://{address}/stream")).unwrap();
        let mut all = Vec::new();
        source.read_to_end(&mut all).unwrap();
        assert!(all == body);
    }

    #[test]
    fn seeking_ahead_fetches_that_range_first() {
        let body: Vec<u8> = (0..(RANGE as u32 * 8)).map(|value| (value % 241) as u8).collect();
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let served = body.clone();
        let (asked, ranges) = std::sync::mpsc::channel();
        std::thread::spawn(move || {
            for connection in listener.incoming() {
                let mut stream = connection.unwrap();
                let mut request = [0u8; 2048];
                let size = stream.read(&mut request).unwrap();
                let request = String::from_utf8_lossy(&request[..size]).to_lowercase();
                let range = request.split("range: bytes=").nth(1).unwrap().split("\r\n").next().unwrap().to_owned();
                let (start, end) = range.split_once('-').unwrap();
                let start: usize = start.parse().unwrap();
                let end: usize = end.parse::<usize>().unwrap().min(served.len() - 1);
                let _ = asked.send(start);
                let _ = write!(
                    stream,
                    "HTTP/1.1 206 Partial Content\r\nContent-Length: {}\r\nContent-Range: bytes {start}-{end}/{}\r\nConnection: close\r\n\r\n",
                    end + 1 - start,
                    served.len()
                );
                for piece in served[start..=end].chunks(64 * 1024) {
                    if stream.write_all(piece).is_err() {
                        break;
                    }
                    std::thread::sleep(Duration::from_millis(15));
                }
            }
        });
        let mut source = open(&format!("http://{address}/stream")).unwrap();
        let watch = source.watch();
        let target = RANGE * 6 + 100;
        source.seek(SeekFrom::Start(target)).unwrap();
        let mut piece = vec![0u8; 1000];
        source.read_exact(&mut piece).unwrap();
        assert_eq!(piece, body[target as usize..target as usize + 1000]);
        let starts: Vec<usize> = ranges.try_iter().collect();
        assert!(starts.contains(&(target as usize)), "the jump was fetched directly: {starts:?}");
        assert!(!starts.contains(&(RANGE as usize * 3)), "nothing in between was waited for: {starts:?}");
        source.seek(SeekFrom::Start(0)).unwrap();
        let mut all = Vec::new();
        source.read_to_end(&mut all).unwrap();
        assert!(all == body);
        assert_eq!(watch.buffered(), vec![(0.0, 1.0)]);
    }

    #[test]
    fn icy_metadata_is_split_from_the_audio() {
        let mut stream = Vec::new();
        let meta = b"StreamTitle='Band - It's Live';StreamUrl='';";
        let blocks = meta.len().div_ceil(16);
        for round in 0..3u8 {
            stream.extend(std::iter::repeat_n(round, 10));
            stream.push(blocks as u8);
            stream.extend_from_slice(meta);
            stream.extend(std::iter::repeat_n(0, blocks * 16 - meta.len()));
        }
        let mut icy = Icy::new(10);
        let mut audio = Vec::new();
        let mut titles = Vec::new();
        for piece in stream.chunks(7) {
            titles.extend(icy.feed(piece, &mut audio));
        }
        assert_eq!(audio, [[0u8; 10], [1; 10], [2; 10]].concat());
        assert_eq!(titles, vec!["Band - It's Live".to_owned(); 3]);
        assert_eq!(stream_title(&[0; 16]), None);
    }

    #[test]
    fn playlists_point_at_their_streams() {
        assert_eq!(playlist_entries("[playlist]\nNumberOfEntries=1\nFile1=http://radio.example/live\nTitle1=Radio\n"), vec!["http://radio.example/live"]);
        assert_eq!(playlist_entries("#EXTM3U\n#EXTINF:-1,Radio\n\nhttp://radio.example:8000/stream.mp3\n"), vec!["http://radio.example:8000/stream.mp3"]);
        assert_eq!(join("http://a.example/radio/list.m3u8?token=1", "seg/1.ts"), "http://a.example/radio/seg/1.ts");
        assert_eq!(join("http://a.example/radio/list.m3u8", "/root.ts"), "http://a.example/root.ts");
        assert_eq!(join("http://a.example", "https://b.example/x"), "https://b.example/x");
    }

    #[test]
    fn endless_streams_play_live_with_their_titles() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        std::thread::spawn(move || {
            for connection in listener.incoming() {
                let mut stream = connection.unwrap();
                let mut request = [0u8; 1024];
                let _ = stream.read(&mut request);
                let _ = write!(stream, "HTTP/1.1 200 OK\r\nContent-Type: audio/mpeg\r\nicy-metaint: 4\r\n\r\n");
                for round in 0..200u8 {
                    let meta = format!("StreamTitle='Song {round}';");
                    let blocks = meta.len().div_ceil(16);
                    let mut piece = vec![round; 4];
                    piece.push(blocks as u8);
                    piece.extend_from_slice(meta.as_bytes());
                    piece.resize(5 + blocks * 16, 0);
                    if stream.write_all(&piece).is_err() {
                        break;
                    }
                }
            }
        });
        let mut source = open(&format!("http://{address}/live")).unwrap();
        let watch = source.watch();
        let mut first = [0u8; 8];
        source.read_exact(&mut first).unwrap();
        assert_eq!(first, [0, 0, 0, 0, 1, 1, 1, 1]);
        assert!(watch.live() && !source.is_seekable() && source.byte_len().is_none());
        assert!(watch.title().is_some_and(|title| title.starts_with("Song ")));
        let mut rest = vec![0u8; 800];
        source.read_exact(&mut rest).unwrap();
        assert_eq!(rest[792..], [0, 0, 0, 0, 1, 1, 1, 1], "it reconnects after the server hangs up");
    }

    #[test]
    fn covers_are_saved_as_jpeg() {
        let mut png = std::io::Cursor::new(Vec::new());
        image::RgbaImage::from_pixel(4, 4, image::Rgba([200, 40, 90, 255]))
            .write_to(&mut png, image::ImageFormat::Png)
            .unwrap();
        let png = png.into_inner();
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        std::thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let mut request = [0u8; 1024];
            let _ = stream.read(&mut request);
            write!(stream, "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n", png.len()).unwrap();
            stream.write_all(&png).unwrap();
        });
        let path = std::env::temp_dir().join(format!("nari-cover-{}/album_720.jpg", std::process::id()));
        fetch_cover(format!("http://{address}/cover"), path.to_string_lossy().into_owned());
        for _ in 0..100 {
            if path.exists() {
                break;
            }
            std::thread::sleep(Duration::from_millis(20));
        }
        let saved = std::fs::read(&path).unwrap();
        assert_eq!(image::guess_format(&saved).unwrap(), image::ImageFormat::Jpeg);
        std::fs::remove_dir_all(path.parent().unwrap()).unwrap();
    }
}
