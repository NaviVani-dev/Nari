use serde::Deserialize;
use serde_json::{json, Value as Json};
use std::collections::HashMap;
use std::sync::mpsc::{channel, Receiver, RecvTimeoutError, Sender};
use std::sync::OnceLock;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use crate::library::{UNKNOWN_ALBUM, UNKNOWN_ARTIST};

const APP_ID: &str = "1554973956778500219";
const NARI_URL: &str = "https://narimusic.com";
const DEEZER: &str = "https://api.deezer.com/search/";
const DEBOUNCE: Duration = Duration::from_secs(1);
const RETRY: Duration = Duration::from_secs(5);
const MAX_DRIFT: i64 = 2;
const MAX_TEXT: usize = 128;

enum Command {
    Settings(Json),
    Track(Json),
    Playback { playing: bool, position: u64, speed: f32 },
}

#[derive(Deserialize, Default, Clone, PartialEq, Debug)]
#[serde(default)]
struct Settings {
    enabled: bool,
    status_name: String,
    show_paused: bool,
    song_button: bool,
    nari_button: bool,
    fetch_artwork: bool,
    provider: String,
}

static COMMANDS: OnceLock<Sender<Command>> = OnceLock::new();

pub fn start() {
    let (commands, receiver) = channel();
    if COMMANDS.set(commands).is_ok() {
        std::thread::Builder::new()
            .name("discord".into())
            .spawn(move || Worker::default().run(receiver))
            .ok();
    }
}

fn send(command: Command) {
    if let Some(commands) = COMMANDS.get() {
        let _ = commands.send(command);
    }
}

pub fn settings(settings_json: &str) {
    send(Command::Settings(serde_json::from_str(settings_json).unwrap_or(Json::Null)));
}

pub fn track(song: &Json) {
    send(Command::Track(song.clone()));
}

pub fn playback(playing: bool, position: u64, speed: f32) {
    send(Command::Playback { playing, position, speed });
}

type CoverKey = (String, String, String);

struct Worker {
    settings: Settings,
    track: Json,
    playing: bool,
    speed: f32,
    started_at: Option<i64>,
    covers: HashMap<CoverKey, Option<String>>,
    shown: Json,
    due: Option<Instant>,
    link: link::Link,
}

impl Default for Worker {
    fn default() -> Self {
        Self {
            settings: Settings::default(),
            track: Json::Null,
            playing: false,
            speed: 1.0,
            started_at: None,
            covers: HashMap::new(),
            shown: Json::Null,
            due: None,
            link: link::Link::new(),
        }
    }
}

impl Worker {
    fn run(mut self, receiver: Receiver<Command>) {
        loop {
            let command = match self.due {
                Some(due) => receiver.recv_timeout(due.saturating_duration_since(Instant::now())),
                None => receiver.recv().map_err(|_| RecvTimeoutError::Disconnected),
            };
            match command {
                Ok(command) => {
                    if self.handle(command, unix_time()) {
                        self.due = Some(Instant::now() + DEBOUNCE);
                    }
                }
                Err(RecvTimeoutError::Timeout) => {
                    self.due = None;
                    self.flush();
                }
                Err(RecvTimeoutError::Disconnected) => return,
            }
        }
    }

    fn snapshot(&self) -> (Settings, Json, bool, f32, Option<i64>) {
        (self.settings.clone(), self.track.clone(), self.playing, self.speed, self.started_at)
    }

    fn handle(&mut self, command: Command, now: i64) -> bool {
        let before = self.snapshot();
        match command {
            Command::Settings(settings) => self.settings = serde_json::from_value(settings).unwrap_or_default(),
            Command::Track(song) => {
                self.track = song;
                self.started_at = None;
            }
            Command::Playback { playing, position, speed } => {
                self.playing = playing;
                self.speed = if speed > 0.0 { speed } else { 1.0 };
                let measured = now - (position as f64 / 1000.0 / self.speed as f64) as i64;
                if self.started_at.map_or(true, |started_at| (started_at - measured).abs() > MAX_DRIFT) {
                    self.started_at = Some(measured);
                }
            }
        }
        before != self.snapshot()
    }

    fn shows(&self) -> bool {
        self.settings.enabled && !self.track.is_null() && (self.playing || self.settings.show_paused)
    }

    fn flush(&mut self) {
        let wanted = if self.shows() {
            let cover = self.cover();
            presence(&self.settings, &self.track, self.started_at.filter(|_| self.playing), self.speed, cover)
        } else {
            Json::Null
        };
        if wanted == self.shown {
            return;
        }
        if self.link.send(&wanted) {
            self.shown = wanted;
        } else {
            self.due = Some(Instant::now() + RETRY);
        }
    }

    fn cover(&mut self) -> Option<String> {
        if let Some(url) = self.track["public_cover_url"].as_str().filter(|url| url.starts_with("https://")) {
            return Some(url.to_owned());
        }
        if !self.settings.fetch_artwork {
            return None;
        }
        let key = (artist_of(&self.track), album_of(&self.track), text(&self.track, "title"));
        if let Some(found) = self.covers.get(&key) {
            return found.clone();
        }
        let found = find_cover(&key.0, &key.1, &key.2).ok()?;
        self.covers.insert(key, found.clone());
        found
    }
}

fn presence(settings: &Settings, track: &Json, started_at: Option<i64>, speed: f32, cover: Option<String>) -> Json {
    let title = text(track, "title");
    let artist = artist_of(track);
    let album = album_of(track);
    let mut activity = json!({
        "type": 2,
        "name": status(settings, &title, &artist),
        "details": fit_text(&title).unwrap_or_else(|| "Unknown song".to_owned()),
    });
    if let Some(artist) = fit_text(&artist) {
        activity["state"] = json!(artist);
    }
    let mut assets = serde_json::Map::new();
    if let Some(cover) = cover {
        assets.insert("large_image".into(), json!(cover));
    }
    if let Some(album) = fit_text(&album) {
        assets.insert("large_text".into(), json!(album));
    }
    if !assets.is_empty() {
        activity["assets"] = Json::Object(assets);
    }
    if let Some(start) = started_at {
        let duration = track["duration"].as_i64().unwrap_or(0);
        activity["timestamps"] = match duration > 0 {
            true => json!({ "start": start, "end": start + (duration as f64 / 1000.0 / speed as f64) as i64 }),
            false => json!({ "start": start }),
        };
    }
    let mut buttons = Vec::new();
    if let Some(url) = track["share_url"].as_str().filter(|url| settings.song_button && url.starts_with("https://")) {
        buttons.push(json!({ "label": "Listen to this song", "url": url }));
    }
    if settings.nari_button {
        buttons.push(json!({ "label": "Get Nari", "url": NARI_URL }));
    }
    if !buttons.is_empty() {
        activity["buttons"] = json!(buttons);
    }
    activity
}

fn status(settings: &Settings, title: &str, artist: &str) -> String {
    let music = || "Music".to_owned();
    match settings.status_name.as_str() {
        "provider" => fit_text(&settings.provider).unwrap_or_else(|| "Nari".to_owned()),
        "music" => music(),
        "title" => fit_text(title).unwrap_or_else(music),
        "artist" => fit_text(artist).unwrap_or_else(music),
        "artist_title" => {
            let joined = [artist, title].into_iter().filter(|part| !part.is_empty()).collect::<Vec<_>>().join(" - ");
            fit_text(&joined).unwrap_or_else(music)
        }
        _ => "Nari".to_owned(),
    }
}

fn text(track: &Json, key: &str) -> String {
    track[key].as_str().unwrap_or("").trim().to_owned()
}

fn artist_of(track: &Json) -> String {
    Some(text(track, "artist")).filter(|artist| artist != UNKNOWN_ARTIST).unwrap_or_default()
}

fn album_of(track: &Json) -> String {
    Some(text(track, "album")).filter(|album| album != UNKNOWN_ALBUM).unwrap_or_default()
}

fn fit_text(value: &str) -> Option<String> {
    let mut units = 0;
    let mut fitted = String::new();
    for character in value.trim().chars() {
        units += character.len_utf16();
        if units > MAX_TEXT {
            break;
        }
        fitted.push(character);
    }
    let mut fitted = fitted.trim_end().to_owned();
    match fitted.chars().count() {
        0 => None,
        1 => {
            fitted.push('\u{a0}');
            Some(fitted)
        }
        _ => Some(fitted),
    }
}

fn find_cover(artist: &str, album: &str, title: &str) -> Result<Option<String>, ureq::Error> {
    let artist = searchable(artist);
    if artist.is_empty() {
        return Ok(None);
    }
    match search(&artist, "album", &searchable(album))? {
        Some(found) => Ok(Some(found)),
        None => search(&artist, "track", &searchable(title)),
    }
}

fn search(artist: &str, kind: &str, name: &str) -> Result<Option<String>, ureq::Error> {
    if name.is_empty() {
        return Ok(None);
    }
    let mut response = crate::scrobble::agent()
        .get(format!("{DEEZER}{kind}"))
        .query("q", format!("{artist} {name}"))
        .query("limit", "10")
        .call()?;
    let page: Json = serde_json::from_str(&response.body_mut().read_to_string()?).unwrap_or(Json::Null);
    let Some(found) = page["data"].as_array() else {
        return Ok(None);
    };
    let candidates = found
        .iter()
        .filter(|item| same_artist(item["artist"]["name"].as_str().unwrap_or(""), artist))
        .map(|item| {
            let cover = match kind {
                "album" => &item["cover_xl"],
                _ => &item["album"]["cover_xl"],
            };
            (item["title"].as_str().unwrap_or("").to_owned(), cover.as_str().map(str::to_owned))
        });
    Ok(closest(candidates, name))
}

fn closest(candidates: impl Iterator<Item = (String, Option<String>)>, wanted: &str) -> Option<String> {
    let wanted = compared(wanted);
    let mut near = None;
    for (name, cover) in candidates {
        let Some(cover) = cover.filter(|cover| cover.starts_with("https://")) else {
            continue;
        };
        let name = compared(&searchable(&name));
        if name == wanted {
            return Some(cover);
        }
        if near.is_none() && extends(&name, &wanted) {
            near = Some(cover);
        }
    }
    near
}

fn same_artist(found: &str, wanted: &str) -> bool {
    let found = compared(found);
    let wanted = compared(wanted);
    found == wanted || extends(&found, &wanted)
}

fn extends(one: &str, other: &str) -> bool {
    let starts = |long: &str, short: &str| {
        !short.is_empty() && long.strip_prefix(short).is_some_and(|rest| rest.starts_with(' '))
    };
    starts(one, other) || starts(other, one)
}

fn searchable(text: &str) -> String {
    let mut kept = String::with_capacity(text.len());
    let mut depth = 0usize;
    for character in text.chars() {
        match character {
            '(' | '[' => depth += 1,
            ')' | ']' => depth = depth.saturating_sub(1),
            _ if depth == 0 => kept.push(character),
            _ => {}
        }
    }
    kept.split_whitespace().collect::<Vec<_>>().join(" ")
}

fn compared(text: &str) -> String {
    text.split(|character: char| !character.is_alphanumeric())
        .filter(|word| !word.is_empty())
        .map(str::to_lowercase)
        .collect::<Vec<_>>()
        .join(" ")
}

fn unix_time() -> i64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |elapsed| elapsed.as_secs() as i64)
}

#[cfg(not(target_os = "android"))]
mod link {
    use discord_rich_presence::{DiscordIpc, DiscordIpcClient};
    use serde_json::{json, Value as Json};

    pub struct Link {
        client: DiscordIpcClient,
        connected: bool,
        nonce: u64,
    }

    impl Link {
        pub fn new() -> Self {
            Self { client: DiscordIpcClient::new(super::APP_ID), connected: false, nonce: 0 }
        }

        pub fn send(&mut self, activity: &Json) -> bool {
            if self.connected && self.offer(activity) {
                return true;
            }
            if self.connected {
                let _ = self.client.close();
            }
            self.connected = self.client.connect().is_ok();
            self.connected && self.offer(activity)
        }

        fn offer(&mut self, activity: &Json) -> bool {
            self.nonce += 1;
            let payload = json!({
                "cmd": "SET_ACTIVITY",
                "args": { "pid": std::process::id(), "activity": activity },
                "nonce": self.nonce.to_string(),
            });
            if self.client.send(payload, 1).is_err() {
                self.connected = false;
                return false;
            }
            match self.client.recv() {
                Ok((_, answer)) => {
                    if answer["evt"] == "ERROR" {
                        godot::global::godot_warn!("Discord refused the presence: {}", answer["data"]["message"]);
                    }
                    true
                }
                Err(_) => {
                    self.connected = false;
                    false
                }
            }
        }
    }
}

#[cfg(target_os = "android")]
mod link {
    use serde_json::{json, Value as Json};

    pub struct Link;

    impl Link {
        pub fn new() -> Self {
            Self
        }

        pub fn send(&mut self, activity: &Json) -> bool {
            crate::android::discord(&json!({ "app": super::APP_ID, "activity": activity }).to_string());
            true
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn settings() -> Settings {
        Settings { enabled: true, song_button: true, nari_button: true, ..Settings::default() }
    }

    fn song() -> Json {
        json!({ "title": "Song", "artist": "Artist", "album": "Album", "duration": 200_000 })
    }

    #[test]
    fn text_fits_discord_limits() {
        assert_eq!(fit_text("  "), None);
        assert_eq!(fit_text("a"), Some("a\u{a0}".to_owned()));
        assert_eq!(fit_text(&"x".repeat(300)).unwrap().len(), MAX_TEXT);
        assert_eq!(fit_text(&"😀".repeat(100)).unwrap().chars().count(), MAX_TEXT / 2);
    }

    #[test]
    fn covers_match_by_artist_and_name() {
        assert!(same_artist("Daft Punk", "daft punk"));
        assert!(same_artist("Daft Punk feat. Pharrell", "Daft Punk"));
        assert!(!same_artist("Punk", "Daft Punk"));
        let found = closest(
            vec![
                ("Discovery Live".to_owned(), Some("https://near".to_owned())),
                ("Discovery".to_owned(), Some("https://exact".to_owned())),
            ]
            .into_iter(),
            "Discovery",
        );
        assert_eq!(found.as_deref(), Some("https://exact"));
        assert_eq!(closest(vec![("Other".to_owned(), Some("https://x".to_owned()))].into_iter(), "Discovery"), None);
        assert_eq!(searchable("Song  (Remastered) [Live]"), "Song");
    }

    #[test]
    fn start_follows_seeks_but_not_jitter() {
        let mut worker = Worker::default();
        assert!(worker.handle(Command::Playback { playing: true, position: 10_000, speed: 1.0 }, 1_000));
        assert_eq!(worker.started_at, Some(990));
        assert!(!worker.handle(Command::Playback { playing: true, position: 10_250, speed: 1.0 }, 1_000));
        assert!(!worker.handle(Command::Playback { playing: true, position: 12_000, speed: 1.0 }, 1_001));
        assert_eq!(worker.started_at, Some(990));
        worker.handle(Command::Playback { playing: true, position: 60_000, speed: 1.0 }, 1_002);
        assert_eq!(worker.started_at, Some(942));
        worker.handle(Command::Track(song()), 1_003);
        assert_eq!(worker.started_at, None);
    }

    #[test]
    fn presence_has_progress_and_buttons() {
        let activity = presence(&settings(), &song(), Some(100), 1.0, Some("https://cover".to_owned()));
        assert_eq!(activity["type"], 2);
        assert_eq!(activity["name"], "Nari");
        assert_eq!(activity["details"], "Song");
        assert_eq!(activity["state"], "Artist");
        assert_eq!(activity["assets"]["large_image"], "https://cover");
        assert_eq!(activity["timestamps"], json!({ "start": 100, "end": 300 }));
        assert_eq!(activity["buttons"].as_array().unwrap().len(), 1);
        assert_eq!(activity["buttons"][0]["url"], NARI_URL);

        let doubled = presence(&settings(), &song(), Some(100), 2.0, None);
        assert_eq!(doubled["timestamps"]["end"], 200);
        assert!(doubled.get("assets").unwrap()["large_image"].is_null());

        let paused = presence(&settings(), &song(), None, 1.0, None);
        assert!(paused.get("timestamps").is_none());

        let mut shared = song();
        shared["share_url"] = json!("https://listen");
        let bare = Settings { nari_button: false, ..settings() };
        let activity = presence(&bare, &shared, None, 1.0, None);
        assert_eq!(activity["buttons"], json!([{ "label": "Listen to this song", "url": "https://listen" }]));
        assert!(presence(&Settings { song_button: false, ..bare }, &shared, None, 1.0, None).get("buttons").is_none());
    }

    #[test]
    fn status_name_follows_the_setting() {
        let named = |status_name: &str, provider: &str| {
            status(&Settings { status_name: status_name.into(), provider: provider.into(), ..settings() }, "Song", "Artist")
        };
        assert_eq!(named("nari", ""), "Nari");
        assert_eq!(named("provider", "Navidrome"), "Navidrome");
        assert_eq!(named("provider", ""), "Nari");
        assert_eq!(named("music", ""), "Music");
        assert_eq!(named("title", ""), "Song");
        assert_eq!(named("artist", ""), "Artist");
        assert_eq!(named("artist_title", ""), "Artist - Song");
    }

    #[test]
    fn hidden_when_disabled_or_paused() {
        let mut worker = Worker { settings: settings(), track: song(), playing: true, ..Worker::default() };
        assert!(worker.shows());
        worker.playing = false;
        assert!(!worker.shows());
        worker.settings.show_paused = true;
        assert!(worker.shows());
        worker.settings.enabled = false;
        assert!(!worker.shows());
    }
}
