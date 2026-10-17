mod formats;
mod japanese;
mod rank;
pub mod romanize;
mod shape;
mod sheet;

use serde_json::{json, Value};
use std::time::Duration;

#[derive(Clone, Debug, PartialEq)]
pub struct Word {
    pub start: Duration,
    pub end: Duration,
    pub text: String,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Line {
    pub start: Duration,
    pub end: Option<Duration>,
    pub text: String,
    pub words: Vec<Word>,
    pub background: Vec<Word>,
    pub lead: bool,
}

impl Line {
    fn worded(&self) -> bool {
        self.words.len() > 1 || !self.background.is_empty()
    }
}

fn millis(value: &Value) -> Option<Duration> {
    value
        .as_f64()
        .filter(|number| *number >= 0.0)
        .map(|number| Duration::from_millis(number as u64))
}

fn words_from(value: &Value) -> Vec<Word> {
    value
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|segment| {
            let start = millis(&segment["start_ms"])?;
            Some(Word {
                start,
                end: millis(&segment["end_ms"]).unwrap_or(start).max(start),
                text: segment["text"].as_str().unwrap_or_default().to_owned(),
            })
        })
        .collect()
}

fn lines_from(value: &Value) -> Vec<Line> {
    value
        .as_array()
        .into_iter()
        .flatten()
        .map(|line| Line {
            start: millis(&line["start_ms"]).unwrap_or_default(),
            end: millis(&line["end_ms"]),
            text: line["text"].as_str().unwrap_or_default().to_owned(),
            words: words_from(&line["segments"]),
            background: words_from(&line["background_segments"]),
            lead: line["alignment"].as_str() != Some("end"),
        })
        .collect()
}

fn segment_json(word: &Word) -> Value {
    json!({
        "text": word.text,
        "start_ms": word.start.as_millis() as u64,
        "end_ms": word.end.as_millis() as u64,
        "part": false,
        "romanized_text": "",
    })
}

fn lines_json(lines: &[Line]) -> Value {
    Value::Array(
        lines
            .iter()
            .map(|line| {
                let end = line.end.map(|end| end.as_millis() as i64).unwrap_or(-1);
                let segments: Vec<Value> = match line.words.is_empty() {
                    true => vec![segment_json(&Word {
                        start: line.start,
                        end: line.end.unwrap_or(line.start),
                        text: line.text.clone(),
                    })],
                    false => line.words.iter().map(segment_json).collect(),
                };
                json!({
                    "start_ms": line.start.as_millis() as u64,
                    "end_ms": end,
                    "text": line.text,
                    "segments": segments,
                    "background_segments": line.background.iter().map(segment_json).collect::<Vec<_>>(),
                    "translation": "",
                    "romanized_text": "",
                    "alignment": if line.lead { "start" } else { "end" },
                    "song_part": "",
                    "agent_id": "",
                })
            })
            .collect(),
    )
}

pub fn krc_json(packed: &[u8]) -> String {
    lines_json(&formats::krc(packed)).to_string()
}

pub fn lyricsfile_json(text: &str) -> String {
    lines_json(&formats::lyricsfile(text)).to_string()
}

pub fn yrc_json(text: &str) -> String {
    lines_json(&formats::yrc(text)).to_string()
}

pub fn headed_json(lines: &str, title: &str, artists: &str) -> String {
    let mut lines = serde_json::from_str::<Value>(lines)
        .map(|value| lines_from(&value))
        .unwrap_or_default();
    let artists: Vec<String> = serde_json::from_str::<Vec<String>>(artists).unwrap_or_default();
    let quiet = sheet::instrumental(&lines);
    let matched = sheet::headed(&mut lines, title, &artists);
    lines.sort_by_key(|line| line.start);
    lines.retain(|line| !line.text.trim().is_empty());
    json!({
        "lines": lines_json(&lines),
        "instrumental": quiet,
        "matched": matched,
    })
    .to_string()
}

pub fn rank_json(query: &str, hits: &str) -> String {
    let query: Value = serde_json::from_str(query).unwrap_or_default();
    let hits: Vec<Value> = serde_json::from_str(hits).unwrap_or_default();
    let query = rank::Query {
        title: query["title"].as_str().unwrap_or_default().to_owned(),
        artist: query["artist"].as_str().unwrap_or_default().to_owned(),
        album: query["album"].as_str().filter(|album| !album.is_empty()).map(str::to_owned),
        duration: millis(&query["duration_ms"]).unwrap_or_default(),
    };
    let hits: Vec<rank::Hit> = hits
        .iter()
        .map(|hit| {
            let lyrics = &hit["lyrics"];
            rank::Hit {
                trust: hit["trust"].as_f64().unwrap_or(0.0).max(0.0) as u32,
                provider: hit["provider"].as_str().unwrap_or_default().to_owned(),
                title: hit["title"].as_str().unwrap_or_default().to_owned(),
                artist: hit["artist"].as_str().unwrap_or_default().to_owned(),
                album: hit["album"].as_str().filter(|album| !album.is_empty()).map(str::to_owned),
                duration: millis(&hit["duration_ms"]).filter(|duration| !duration.is_zero()),
                synced: lyrics["synced"].as_bool().unwrap_or(false),
                text: lyrics["text"].as_str().unwrap_or_default().to_owned(),
                lines: lines_from(&lyrics["lines"]),
            }
        })
        .collect();
    let (order, reshaped) = rank::ordered(&query, &hits);
    let reshaped: serde_json::Map<String, Value> = reshaped
        .into_iter()
        .map(|(index, lines)| (index.to_string(), lines_json(&lines)))
        .collect();
    json!({ "order": order, "reshaped": reshaped }).to_string()
}

pub fn romanize_lines(lines: &[String]) -> Vec<String> {
    romanize::lines(lines)
}
