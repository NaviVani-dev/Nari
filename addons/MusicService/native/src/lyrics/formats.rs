use serde::Deserialize;
use std::io::Read;
use std::time::Duration;

use super::{Line, Word};

const CIPHER: [u8; 16] = [
    0x40, 0x47, 0x61, 0x77, 0x5e, 0x32, 0x74, 0x47, 0x51, 0x36, 0x31, 0x2d, 0xce, 0xd2, 0x6e, 0x69,
];

pub(super) fn krc(packed: &[u8]) -> Vec<Line> {
    let Some(body) = packed.get(4..) else {
        return Vec::new();
    };
    let unmasked: Vec<u8> = body
        .iter()
        .enumerate()
        .map(|(index, byte)| byte ^ CIPHER[index % CIPHER.len()])
        .collect();
    let mut text = String::new();
    if flate2::read::ZlibDecoder::new(unmasked.as_slice())
        .read_to_string(&mut text)
        .is_err()
    {
        return Vec::new();
    }
    krc_text(&text)
}

fn krc_text(text: &str) -> Vec<Line> {
    text.lines().filter_map(krc_line).collect()
}

fn krc_line(line: &str) -> Option<Line> {
    let (header, rest) = line.strip_prefix('[')?.split_once(']')?;
    let (start, span) = pair_of(header)?;
    let mut words = Vec::new();
    let mut text = String::new();
    let mut rest = rest;
    while let Some(open) = rest.find('<') {
        let tail = &rest[open + 1..];
        let Some(shut) = tail.find('>') else { break };
        if !text.is_empty() || open > 0 {
            text.push_str(&rest[..open]);
        }
        let stamp = stamp_of(&tail[..shut], false);
        rest = &tail[shut + 1..];
        let spoken = rest.find('<').map(|next| &rest[..next]).unwrap_or(rest);
        if let Some((at, length)) = stamp {
            words.push(Word {
                start: start + at,
                end: start + at + length,
                text: spoken.to_owned(),
            });
        }
        text.push_str(spoken);
        rest = &rest[spoken.len()..];
    }
    text.push_str(rest);
    finish(start, span, text, words)
}

#[derive(Deserialize)]
struct LyricsFile {
    #[serde(default)]
    lines: Vec<FileLine>,
}

#[derive(Deserialize)]
struct FileLine {
    text: String,
    start_ms: u64,
    end_ms: Option<u64>,
    #[serde(default)]
    words: Vec<FileWord>,
}

#[derive(Deserialize)]
struct FileWord {
    text: String,
    start_ms: u64,
    end_ms: Option<u64>,
}

pub(super) fn lyricsfile(text: &str) -> Vec<Line> {
    let Ok(file) = serde_norway::from_str::<LyricsFile>(text) else {
        return Vec::new();
    };
    let mut lines: Vec<Line> = file
        .lines
        .into_iter()
        .filter(|line| !line.text.trim().is_empty())
        .map(|line| Line {
            start: Duration::from_millis(line.start_ms),
            end: line.end_ms.map(Duration::from_millis),
            text: line.text,
            words: line
                .words
                .into_iter()
                .map(|word| {
                    let start = Duration::from_millis(word.start_ms);
                    Word {
                        start,
                        end: word.end_ms.map(Duration::from_millis).unwrap_or(start),
                        text: word.text,
                    }
                })
                .collect(),
            background: Vec::new(),
            lead: true,
        })
        .collect();
    lines.sort_by_key(|line| line.start);
    lines
}

pub(super) fn yrc(text: &str) -> Vec<Line> {
    let mut lines: Vec<Line> = text.lines().filter_map(yrc_line).collect();
    lines.sort_by_key(|line| line.start);
    lines
}

fn yrc_line(line: &str) -> Option<Line> {
    let (header, rest) = line.strip_prefix('[')?.split_once(']')?;
    let (start, span) = pair_of(header)?;
    let mut words: Vec<Word> = Vec::new();
    let mut text = String::new();
    let mut rest = rest;
    while let Some(open) = rest.find('(') {
        let tail = &rest[open + 1..];
        let Some(shut) = tail.find(')') else { break };
        match stamp_of(&tail[..shut], true) {
            Some((at, length)) => {
                grow(&mut words, &mut text, &rest[..open]);
                rest = &tail[shut + 1..];
                let spoken = rest.find('(').map(|next| &rest[..next]).unwrap_or(rest);
                words.push(Word {
                    start: at,
                    end: at + length,
                    text: spoken.to_owned(),
                });
                text.push_str(spoken);
                rest = &rest[spoken.len()..];
            }
            None => {
                grow(&mut words, &mut text, &rest[..open + shut + 2]);
                rest = &tail[shut + 1..];
            }
        }
    }
    grow(&mut words, &mut text, rest);
    finish(start, span, text, words)
}

fn finish(start: Duration, span: Duration, text: String, words: Vec<Word>) -> Option<Line> {
    let text = text.trim().to_owned();
    if text.is_empty() {
        return None;
    }
    Some(Line {
        start,
        end: Some(start + span),
        text,
        words,
        background: Vec::new(),
        lead: true,
    })
}

fn grow(words: &mut [Word], text: &mut String, tail: &str) {
    if tail.is_empty() {
        return;
    }
    text.push_str(tail);
    if let Some(last) = words.last_mut() {
        last.text.push_str(tail);
    }
}

fn pair_of(header: &str) -> Option<(Duration, Duration)> {
    let (start, span) = header.split_once(',')?;
    Some((
        Duration::from_millis(start.trim().parse().ok()?),
        Duration::from_millis(span.trim().parse().ok()?),
    ))
}

fn stamp_of(stamp: &str, three_parts: bool) -> Option<(Duration, Duration)> {
    let mut parts = stamp.split(',');
    let at: u64 = parts.next()?.trim().parse().ok()?;
    let length: u64 = parts.next()?.trim().parse().ok()?;
    if three_parts {
        parts.next()?;
    }
    Some((Duration::from_millis(at), Duration::from_millis(length)))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    #[test]
    fn reads_a_lrclib_lyricsfile_with_words() {
        let lines = lyricsfile("version: '1.0'\nmetadata:\n  title: Jaded\nlines:\n- text: 'Hello world'\n  start_ms: 1200\n  end_ms: 2800\n  words:\n  - text: 'Hello '\n    start_ms: 1200\n    end_ms: 1900\n  - text: 'world'\n    start_ms: 1900\n    end_ms: 2800\n");
        assert_eq!(lines.len(), 1);
        assert_eq!(lines[0].words.len(), 2);
        assert_eq!(lines[0].words[1].start, Duration::from_millis(1900));
    }

    #[test]
    fn reads_a_yrc_line() {
        let lines = yrc(
            "{\"t\":0,\"c\":[{\"tx\":\"credits\"}]}\n[27360,1290](27360,240,0)I've (27600,90,0)been (27690,360,0)tryna (28050,600,0)call\n",
        );
        assert_eq!(lines.len(), 1);
        assert_eq!(lines[0].start, Duration::from_millis(27_360));
        assert_eq!(lines[0].end, Some(Duration::from_millis(28_650)));
        assert_eq!(lines[0].text, "I've been tryna call");
        assert_eq!(lines[0].words.len(), 4);
        assert_eq!(lines[0].words[0].text, "I've ");
        assert_eq!(lines[0].words[3].end, Duration::from_millis(28_650));
    }

    #[test]
    fn decrypts_and_reads_a_krc_sheet() {
        let sheet = "[ti:Idol]\n[1000,2000]<0,500,0>無敵<500,700,0>の<1200,800,0>笑顔\n";
        let mut encoder = flate2::write::ZlibEncoder::new(Vec::new(), flate2::Compression::default());
        encoder.write_all(sheet.as_bytes()).unwrap();
        let packed: Vec<u8> = b"krc1"
            .iter()
            .copied()
            .chain(
                encoder
                    .finish()
                    .unwrap()
                    .iter()
                    .enumerate()
                    .map(|(index, byte)| byte ^ CIPHER[index % CIPHER.len()]),
            )
            .collect();
        let lines = krc(&packed);
        assert_eq!(lines.len(), 1);
        assert_eq!(lines[0].text, "無敵の笑顔");
        assert_eq!(lines[0].words[1].start, Duration::from_millis(1500));
        assert_eq!(lines[0].words[2].end, Duration::from_millis(3000));
    }
}
