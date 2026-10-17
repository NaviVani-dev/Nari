use lofty::config::ParseOptions;
use lofty::file::{AudioFile, FileType, TaggedFileExt};
use lofty::id3::v2::{Frame, Id3v2Tag, SynchronizedTextFrame, TimestampFormat};
use lofty::mpeg::MpegFile;
use lofty::probe::Probe;
use lofty::tag::{ItemKey, Tag};
use md5::{Digest, Md5};
use serde::{Deserialize, Serialize};
use std::io::BufReader;

const SEPARATORS: [&str; 3] = [" / ", " feat.", " featuring "];
#[derive(Serialize, Deserialize, Clone, Debug, Default, PartialEq)]
pub struct RawLyrics {
    pub text: String,
    pub format: String,
    pub source: String,
}

#[derive(Serialize, Deserialize, Clone, Debug, Default)]
pub struct Metadata {
    pub title: String,
    pub sort_title: String,
    pub artists: Vec<String>,
    pub artist_sort_names: Vec<String>,
    pub album: String,
    pub album_artists: Vec<String>,
    pub album_sort: String,
    pub genres: Vec<String>,
    pub track: i32,
    pub disc: i32,
    pub year: i32,
    pub duration: i64,
    pub bitrate: i64,
    pub sample_rate: i32,
    pub isrc: String,
    pub musicbrainz_track_id: String,
    pub musicbrainz_album_id: String,
    pub musicbrainz_artist_ids: Vec<String>,
    pub release_type: String,
    pub has_embedded_cover: bool,
    pub cover_hash: String,
    pub lyrics: Option<RawLyrics>,
    pub replay_gain: Option<f32>,
}

pub fn read(uri: &str, name: &str) -> Option<Metadata> {
    if crate::synth::handles(name) {
        return crate::synth::metadata(uri, name);
    }
    let (tag, duration, bitrate, sample_rate, synced) = read_tag(uri, name)?;
    let tag = tag.unwrap_or_else(|| Tag::new(lofty::tag::TagType::Id3v2));
    let artists = values(&tag, ItemKey::TrackArtist);
    let lyrics = synced.or_else(|| {
        value(&tag, ItemKey::Lyrics)
            .or_else(|| value(&tag, ItemKey::UnsyncLyrics))
            .map(|text| RawLyrics {
                text,
                format: String::new(),
                source: "embedded".into(),
            })
    });
    Some(Metadata {
        title: value(&tag, ItemKey::TrackTitle).unwrap_or_default(),
        sort_title: value(&tag, ItemKey::TrackTitleSortOrder).unwrap_or_default(),
        artists,
        artist_sort_names: values(&tag, ItemKey::TrackArtistSortOrder),
        album: value(&tag, ItemKey::AlbumTitle).unwrap_or_default(),
        album_artists: values(&tag, ItemKey::AlbumArtist),
        album_sort: value(&tag, ItemKey::AlbumTitleSortOrder).unwrap_or_default(),
        genres: values(&tag, ItemKey::Genre),
        track: number(value(&tag, ItemKey::TrackNumber)),
        disc: number(value(&tag, ItemKey::DiscNumber)),
        year: year(value(&tag, ItemKey::Year).or_else(|| value(&tag, ItemKey::RecordingDate))),
        duration,
        bitrate,
        sample_rate,
        isrc: value(&tag, ItemKey::Isrc).unwrap_or_default(),
        musicbrainz_track_id: value(&tag, ItemKey::MusicBrainzRecordingId)
            .or_else(|| value(&tag, ItemKey::MusicBrainzTrackId))
            .unwrap_or_default(),
        musicbrainz_album_id: value(&tag, ItemKey::MusicBrainzReleaseId).unwrap_or_default(),
        musicbrainz_artist_ids: values(&tag, ItemKey::MusicBrainzArtistId),
        release_type: value(&tag, ItemKey::MusicBrainzReleaseType).unwrap_or_default(),
        has_embedded_cover: tag.pictures().iter().any(|art| !art.data().is_empty()),
        cover_hash: tag
            .pictures()
            .iter()
            .find(|art| !art.data().is_empty())
            .map(|art| crate::plugins::hex(&Md5::digest(art.data())))
            .unwrap_or_default(),
        lyrics,
        replay_gain: replay_gain(&tag),
    })
}

pub fn artwork(uri: &str, name: &str) -> Option<Vec<u8>> {
    let (tag, ..) = read_tag(uri, name)?;
    tag?.pictures()
        .iter()
        .map(|art| art.data().to_vec())
        .find(|data| !data.is_empty())
}

type TagRead = (Option<Tag>, i64, i64, i32, Option<RawLyrics>);

fn read_tag(uri: &str, name: &str) -> Option<TagRead> {
    let mut reader = BufReader::new(crate::storage::open(uri).ok()?);
    if crate::storage::extension(name) == "mp3" {
        let file = MpegFile::read_from(&mut reader, ParseOptions::new()).ok()?;
        let properties = file.properties();
        let synced = file.id3v2().and_then(synchronized_lyrics);
        let tag = file.id3v2().cloned().map(Tag::from);
        return Some((
            tag,
            properties.duration().as_millis() as i64,
            properties.audio_bitrate() as i64,
            properties.sample_rate() as i32,
            synced,
        ));
    }
    let mut probe = Probe::new(&mut reader).guess_file_type().ok()?;
    if probe.file_type().is_none() {
        probe = probe.set_file_type(FileType::from_ext(crate::storage::extension(name))?);
    }
    let file = probe.read().ok()?;
    let properties = file.properties();
    let duration = properties.duration().as_millis() as i64;
    let bitrate = properties.audio_bitrate().unwrap_or(0) as i64;
    let sample_rate = properties.sample_rate().unwrap_or(0) as i32;
    let tag = file.primary_tag().or_else(|| file.first_tag()).cloned();
    Some((tag, duration, bitrate, sample_rate, None))
}

fn synchronized_lyrics(tag: &Id3v2Tag) -> Option<RawLyrics> {
    let frame = tag.into_iter().find_map(|frame| match frame {
        Frame::Binary(binary) if binary.id().as_str() == "SYLT" => {
            SynchronizedTextFrame::parse(&binary.data, frame.flags()).ok()
        }
        _ => None,
    })?;
    let frames_to_ms = frame.timestamp_format == TimestampFormat::MPEG;
    let text = frame
        .content
        .iter()
        .map(|(raw, line)| {
            let ms = if frames_to_ms {
                u64::from(*raw) * 1152 * 1000 / 44100
            } else {
                u64::from(*raw)
            };
            format!(
                "[{:02}:{:02}.{:02}]{}",
                ms / 60000,
                (ms % 60000) / 1000,
                (ms % 1000) / 10,
                line
            )
        })
        .collect::<Vec<_>>()
        .join("\n");
    if text.is_empty() {
        return None;
    }
    Some(RawLyrics {
        text,
        format: "lrc".into(),
        source: "embedded_sylt".into(),
    })
}

fn value(tag: &Tag, key: ItemKey) -> Option<String> {
    tag.get_string(key)
        .map(str::trim)
        .filter(|text| !text.is_empty())
        .map(str::to_owned)
}

fn values(tag: &Tag, key: ItemKey) -> Vec<String> {
    value(tag, key).map(|text| split_values(&text)).unwrap_or_default()
}

fn replay_gain(tag: &Tag) -> Option<f32> {
    let raw = value(tag, ItemKey::ReplayGainTrackGain)?;
    let raw = raw.to_lowercase();
    let raw = raw.strip_suffix("db").unwrap_or(&raw).trim();
    raw.parse::<f32>().ok().filter(|gain| gain.is_finite())
}

pub fn split_values(text: &str) -> Vec<String> {
    let bytes = text.as_bytes();
    let mut parts = Vec::new();
    let mut start = 0;
    let mut index = 0;
    while index < bytes.len() {
        if !text.is_char_boundary(index) {
            index += 1;
            continue;
        }
        let separator = SEPARATORS.iter().find(|separator| {
            let end = index + separator.len();
            end <= bytes.len() && bytes[index..end].eq_ignore_ascii_case(separator.as_bytes())
        });
        match separator {
            Some(separator) => {
                parts.push(text[start..index].trim().to_owned());
                index += separator.len();
                start = index;
            }
            None if bytes[index] == b';' => {
                parts.push(text[start..index].trim().to_owned());
                index += 1;
                start = index;
            }
            None => index += 1,
        }
    }
    parts.push(text[start..].trim().to_owned());
    parts.retain(|part| !part.is_empty());
    parts
}

pub fn intelligent_sort_name(value: &str) -> String {
    let trimmed = value.trim();
    for article in ["the", "a", "an"] {
        let Some(rest) = trimmed.get(..article.len()) else {
            continue;
        };
        if !rest.eq_ignore_ascii_case(article) {
            continue;
        }
        let rest = &trimmed[article.len()..];
        if rest.starts_with(char::is_whitespace) {
            return rest.trim_start().to_owned();
        }
    }
    trimmed.to_owned()
}

pub fn stable_id(kind: &str, value: &str) -> String {
    let mut digest = Md5::new();
    digest.update(value.to_lowercase().as_bytes());
    let mut bytes: [u8; 16] = digest.finalize().into();
    bytes[6] = (bytes[6] & 0x0f) | 0x30;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    let hex = crate::plugins::hex(&bytes);
    format!(
        "{kind}-{}-{}-{}-{}-{}",
        &hex[0..8],
        &hex[8..12],
        &hex[12..16],
        &hex[16..20],
        &hex[20..32]
    )
}

fn number(value: Option<String>) -> i32 {
    value
        .and_then(|text| {
            text.split('/')
                .next()
                .unwrap_or_default()
                .trim()
                .parse::<i32>()
                .ok()
        })
        .filter(|number| *number > 0)
        .unwrap_or(0)
}

fn year(value: Option<String>) -> i32 {
    value
        .and_then(|text| {
            let trimmed = text.trim();
            let head: String = trimmed.chars().take(4).collect();
            head.parse::<i32>().ok()
        })
        .filter(|year| *year > 0)
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn splits_artists_the_way_the_android_plugin_does() {
        assert_eq!(split_values("A; B"), vec!["A", "B"]);
        assert_eq!(split_values("A / B"), vec!["A", "B"]);
        assert_eq!(split_values("Lorde feat. Jack"), vec!["Lorde", "Jack"]);
        assert_eq!(split_values("Lorde Featuring Jack"), vec!["Lorde", "Jack"]);
        assert_eq!(split_values("AC/DC"), vec!["AC/DC"]);
        assert_eq!(split_values("  Solo  "), vec!["Solo"]);
    }

    #[test]
    fn strips_leading_articles_only_when_followed_by_space() {
        assert_eq!(intelligent_sort_name("The Beatles"), "Beatles");
        assert_eq!(intelligent_sort_name("  an Album"), "Album");
        assert_eq!(intelligent_sort_name("Anthrax"), "Anthrax");
        assert_eq!(intelligent_sort_name("Theory"), "Theory");
    }

    #[test]
    fn stable_ids_are_uuid_v3_like_the_android_plugin() {
        let id = stable_id("artist", "Radiohead");
        assert!(id.starts_with("artist-"));
        assert_eq!(id.len(), "artist-".len() + 36);
        assert_eq!(id.as_bytes()["artist-".len() + 14], b'3');
        assert_eq!(stable_id("artist", "RADIOHEAD"), id);
    }

    #[test]
    fn parses_numbers_and_years_like_the_android_plugin() {
        assert_eq!(number(Some("3/12".into())), 3);
        assert_eq!(number(Some("0".into())), 0);
        assert_eq!(year(Some("1997-05-21".into())), 1997);
        assert_eq!(year(Some("".into())), 0);
    }
}
