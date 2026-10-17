use std::io;
use std::time::{Duration, Instant};

use crate::remote::{fetch_bytes, fetch_text, join};
use crate::stream::{Feed, Stream};

const LIVE_EDGE: usize = 3;
const RETRIES: u32 = 5;
const MIN_WAIT: Duration = Duration::from_secs(1);
const MAX_WAIT: Duration = Duration::from_secs(10);
const POLL: Duration = Duration::from_millis(100);

#[derive(Debug, PartialEq)]
struct Playlist {
    target: Duration,
    sequence: u64,
    segments: Vec<String>,
    ended: bool,
}

pub fn open(url: &str, text: &str) -> io::Result<Stream> {
    let (url, text) = match best_variant(text) {
        Some(variant) => {
            let variant = join(url, &variant);
            let text = fetch_text(&variant)?;
            (variant, text)
        }
        None => (url.to_owned(), text.to_owned()),
    };
    let playlist = parse(&text).map_err(io::Error::other)?;
    let (feed, stream) = crate::stream::channel(true, None);
    std::thread::spawn(move || {
        if let Err(error) = follow(&feed, &url, playlist) {
            feed.fail(error);
        }
    });
    Ok(stream)
}

fn best_variant(text: &str) -> Option<String> {
    let mut best: Option<(u64, String)> = None;
    let mut bandwidth = None;
    for line in text.lines().map(str::trim) {
        if let Some(attributes) = line.strip_prefix("#EXT-X-STREAM-INF:") {
            bandwidth = Some(attribute(attributes, "BANDWIDTH").and_then(|value| value.parse().ok()).unwrap_or(0));
        } else if let Some(rate) = bandwidth.filter(|_| !line.is_empty() && !line.starts_with('#')) {
            if best.as_ref().is_none_or(|(top, _)| rate > *top) {
                best = Some((rate, line.to_owned()));
            }
            bandwidth = None;
        }
    }
    best.map(|(_, uri)| uri)
}

fn attribute<'a>(attributes: &'a str, name: &str) -> Option<&'a str> {
    attributes.split(',').find_map(|pair| {
        let (key, value) = pair.split_once('=')?;
        (key.trim() == name).then(|| value.trim().trim_matches('"'))
    })
}

fn parse(text: &str) -> Result<Playlist, String> {
    if !text.trim_start().starts_with("#EXTM3U") {
        return Err("the stream playlist is not valid".into());
    }
    let mut playlist = Playlist { target: MAX_WAIT, sequence: 0, segments: Vec::new(), ended: false };
    for line in text.lines().map(str::trim) {
        if let Some(value) = line.strip_prefix("#EXT-X-TARGETDURATION:") {
            playlist.target = Duration::from_secs_f64(value.parse::<f64>().unwrap_or(10.0).max(0.0));
        } else if let Some(value) = line.strip_prefix("#EXT-X-MEDIA-SEQUENCE:") {
            playlist.sequence = value.parse().unwrap_or(0);
        } else if let Some(value) = line.strip_prefix("#EXT-X-KEY:") {
            if attribute(value, "METHOD").is_some_and(|method| method != "NONE") {
                return Err("encrypted streams are not supported".into());
            }
        } else if line.starts_with("#EXT-X-MAP:") {
            return Err("fragmented MP4 streams are not supported yet".into());
        } else if line == "#EXT-X-ENDLIST" {
            playlist.ended = true;
        } else if !line.is_empty() && !line.starts_with('#') {
            playlist.segments.push(line.to_owned());
        }
    }
    Ok(playlist)
}

fn follow(feed: &Feed, url: &str, mut playlist: Playlist) -> Result<(), String> {
    let mut next = match playlist.ended {
        true => playlist.sequence,
        false => playlist.sequence + playlist.segments.len().saturating_sub(LIVE_EDGE) as u64,
    };
    let mut failures = 0;
    loop {
        let mut wrote = false;
        for (offset, segment) in playlist.segments.iter().enumerate() {
            let sequence = playlist.sequence + offset as u64;
            if sequence < next {
                continue;
            }
            let bytes = match fetch_bytes(&join(url, segment)) {
                Ok(bytes) => bytes,
                Err(error) => {
                    failures += 1;
                    if failures > RETRIES {
                        return Err(error.to_string());
                    }
                    break;
                }
            };
            let audio = if crate::ts::is_ts(&bytes) { crate::ts::demux(&bytes)? } else { bytes };
            if !feed.push(&audio) {
                return Ok(());
            }
            next = sequence + 1;
            wrote = true;
            failures = 0;
        }
        if playlist.ended && !wrote && next >= playlist.sequence + playlist.segments.len() as u64 {
            return Ok(());
        }
        if !wait(feed, (playlist.target / 2).clamp(MIN_WAIT, MAX_WAIT)) {
            return Ok(());
        }
        match fetch_text(url).map_err(|error| error.to_string()).and_then(|text| parse(&text)) {
            Ok(fresh) => {
                next = next.max(fresh.sequence);
                playlist = fresh;
            }
            Err(error) => {
                failures += 1;
                if failures > RETRIES {
                    return Err(error);
                }
            }
        }
    }
}

fn wait(feed: &Feed, time: Duration) -> bool {
    let until = Instant::now() + time;
    while Instant::now() < until {
        if feed.closed() {
            return false;
        }
        std::thread::sleep(POLL);
    }
    !feed.closed()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn picks_the_richest_variant_and_reads_media_playlists() {
        let master = "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=64000,CODECS=\"mp4a.40.5\"\nlow/index.m3u8\n#EXT-X-STREAM-INF:BANDWIDTH=128000\nhigh/index.m3u8\n";
        assert_eq!(best_variant(master).as_deref(), Some("high/index.m3u8"));
        assert_eq!(best_variant("#EXTM3U\n#EXTINF:6,\nseg.aac\n"), None);
        let media = "#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXT-X-MEDIA-SEQUENCE:41\n#EXTINF:6.0,\na.ts\n#EXTINF:6.0,\nb.ts\n";
        assert_eq!(
            parse(media).unwrap(),
            Playlist { target: Duration::from_secs(6), sequence: 41, segments: vec!["a.ts".into(), "b.ts".into()], ended: false }
        );
        assert!(parse(&format!("{media}#EXT-X-ENDLIST\n")).unwrap().ended);
        assert!(parse("#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI=\"k\"\n").unwrap_err().contains("encrypted"));
        assert!(parse("#EXTM3U\n#EXT-X-KEY:METHOD=NONE\n").is_ok());
        assert!(parse("#EXTM3U\n#EXT-X-MAP:URI=\"init.mp4\"\n").is_err());
        assert!(parse("<html>").is_err());
    }
}
