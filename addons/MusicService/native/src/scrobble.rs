use md5::{Digest, Md5};
use serde_json::{json, Map, Value as Json};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::mpsc::{channel, Receiver, RecvTimeoutError, Sender};
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use crate::events::Event;

pub(crate) const LASTFM_KEY: &str = "a9196050ad5c7ff1e6745a41ed66c44a";
const LASTFM_SECRET: &str = "a0b3b374ef140e06ac1719f2026d90a8";
const LIBREFM_KEY: &str = "6e61726973637262626c65726e617269";
const LIBREFM_SECRET: &str = "6e617269736563726574736563726574";
const LISTENBRAINZ: &str = "https://api.listenbrainz.org/1/";
const SERVICES: [&str; 3] = ["lastfm", "librefm", "listenbrainz"];
const ACCOUNTS_FILE: &str = "scrobble.json";
const QUEUE_FILE: &str = "scrobble_queue.json";
const MIN_LENGTH: Duration = Duration::from_secs(30);
const MAX_WAIT: Duration = Duration::from_secs(240);
const RETRY: Duration = Duration::from_secs(300);
const IDLE: Duration = Duration::from_secs(3600);
const LISTENBRAINZ_BATCH: usize = 50;
const QUEUE_LIMIT: usize = 10_000;
const POLL: Duration = Duration::from_secs(3);
const APPROVAL: Duration = Duration::from_secs(600);
const HTTP_TIMEOUT: Duration = Duration::from_secs(20);

struct Site {
    api: &'static str,
    auth: &'static str,
    key: &'static str,
    secret: &'static str,
    batch: usize,
}

fn site(service: &str) -> Option<Site> {
    match service {
        "lastfm" => Some(Site {
            api: "https://ws.audioscrobbler.com/2.0/",
            auth: "https://www.last.fm/api/auth/",
            key: LASTFM_KEY,
            secret: LASTFM_SECRET,
            batch: 50,
        }),
        "librefm" => Some(Site {
            api: "https://libre.fm/2.0/",
            auth: "https://libre.fm/api/auth/",
            key: LIBREFM_KEY,
            secret: LIBREFM_SECRET,
            batch: 1,
        }),
        _ => None,
    }
}

enum Command {
    Track(Json),
    State(bool),
    Connect(String),
    Cancel(String),
    Token(String),
    Disconnect(String),
}

#[derive(Debug, PartialEq)]
enum Failure {
    Offline(String),
    Rejected(String),
    SignedOut,
    Waiting,
}

impl Failure {
    fn message(self) -> String {
        match self {
            Failure::Offline(message) | Failure::Rejected(message) => message,
            Failure::SignedOut => "Session expired, connect again".into(),
            Failure::Waiting => "Nari wasn't approved in time, try again".into(),
        }
    }
}

struct Shared {
    commands: Sender<Command>,
    accounts: Mutex<Map<String, Json>>,
    root: PathBuf,
}

static SHARED: OnceLock<Shared> = OnceLock::new();

pub fn start(root: PathBuf, events: Sender<Event>) {
    let (commands, receiver) = channel();
    let accounts = crate::vault::read(&root.join(ACCOUNTS_FILE))
        .and_then(|bytes| serde_json::from_slice::<Json>(&bytes).ok())
        .and_then(|json| json.as_object().cloned())
        .unwrap_or_default();
    if SHARED.set(Shared { commands, accounts: Mutex::new(accounts), root }).is_ok() {
        std::thread::Builder::new()
            .name("scrobbler".into())
            .spawn(move || Worker::new(events).run(receiver))
            .ok();
    }
}

fn send(command: Command) {
    if let Some(shared) = SHARED.get() {
        let _ = shared.commands.send(command);
    }
}

pub fn track(song: &Json) {
    send(Command::Track(song.clone()));
}

pub fn state(playing: bool) {
    send(Command::State(playing));
}

pub fn connect(service: &str) {
    send(Command::Connect(service.into()));
}

pub fn cancel(service: &str) {
    send(Command::Cancel(service.into()));
}

pub fn set_token(token: &str) {
    send(Command::Token(token.trim().into()));
}

pub fn disconnect(service: &str) {
    send(Command::Disconnect(service.into()));
}

pub fn accounts() -> Map<String, Json> {
    SHARED
        .get()
        .map(|shared| {
            accounts_of(shared)
                .iter()
                .map(|(service, account)| (service.clone(), account["user"].clone()))
                .collect()
        })
        .unwrap_or_default()
}

fn accounts_of(shared: &Shared) -> std::sync::MutexGuard<'_, Map<String, Json>> {
    shared.accounts.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
}

fn save_account(service: &str, account: Option<Json>) {
    let Some(shared) = SHARED.get() else {
        return;
    };
    let mut accounts = accounts_of(shared);
    match account {
        Some(account) => accounts.insert(service.into(), account),
        None => accounts.remove(service),
    };
    if let Ok(bytes) = serde_json::to_vec(&Json::Object(accounts.clone())) {
        let _ = crate::vault::write(&shared.root.join(ACCOUNTS_FILE), &bytes);
    }
}

struct Listen {
    song: Json,
    track: Option<Json>,
    started: u64,
    played: Duration,
    since: Option<Instant>,
    sent: bool,
}

impl Listen {
    fn played(&self) -> Duration {
        self.played + self.since.map_or(Duration::ZERO, |since| since.elapsed())
    }

    fn remaining(&self) -> Option<Duration> {
        if self.sent {
            return None;
        }
        let needed = match self.song["live"].as_bool() {
            Some(true) => MIN_LENGTH,
            _ => needed(self.song["duration"].as_u64().unwrap_or(0) / 1000)?,
        };
        Some(needed.saturating_sub(self.played()))
    }

    fn set_playing(&mut self, playing: bool) {
        match (playing, self.since) {
            (true, None) => self.since = Some(Instant::now()),
            (false, Some(since)) => {
                self.played += since.elapsed();
                self.since = None;
            }
            _ => {}
        }
    }
}

fn needed(duration_secs: u64) -> Option<Duration> {
    let duration = Duration::from_secs(duration_secs);
    (duration >= MIN_LENGTH).then(|| (duration / 2).min(MAX_WAIT))
}

fn scrobbable(song: &Json) -> Option<Json> {
    let text = |key: &str| song[key].as_str().unwrap_or("").trim().to_owned();
    let (title, artist) = (text("title"), text("artist"));
    if title.is_empty() || artist.is_empty() || artist == crate::library::UNKNOWN_ARTIST {
        return None;
    }
    let album = Some(text("album")).filter(|album| album != crate::library::UNKNOWN_ALBUM).unwrap_or_default();
    Some(json!({
        "title": title,
        "artist": artist,
        "album": album,
        "album_artist": text("album_artist"),
        "duration": song["duration"].as_u64().unwrap_or(0) / 1000,
    }))
}

fn now() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |elapsed| elapsed.as_secs())
}

struct Approval {
    token: String,
    next: Instant,
    until: Instant,
}

struct Worker {
    events: Sender<Event>,
    queue: Vec<Json>,
    listen: Option<Listen>,
    playing: bool,
    pending: HashMap<String, Approval>,
    last_flush: Instant,
    station: Json,
}

impl Worker {
    fn new(events: Sender<Event>) -> Self {
        let queue = SHARED
            .get()
            .and_then(|shared| read(&shared.root.join(QUEUE_FILE)).as_array().cloned())
            .unwrap_or_default();
        Self { events, queue, listen: None, playing: false, pending: HashMap::new(), last_flush: Instant::now(), station: Json::Null }
    }

    fn run(mut self, receiver: Receiver<Command>) {
        self.flush();
        loop {
            match receiver.recv_timeout(self.wait()) {
                Ok(command) => self.handle(command),
                Err(RecvTimeoutError::Timeout) => {}
                Err(RecvTimeoutError::Disconnected) => return,
            }
            self.check();
        }
    }

    fn wait(&self) -> Duration {
        let retry = if self.queue.is_empty() { IDLE } else { RETRY.saturating_sub(self.last_flush.elapsed()) };
        self.listen
            .as_ref()
            .filter(|listen| listen.since.is_some())
            .and_then(Listen::remaining)
            .map_or(retry, |remaining| remaining.min(retry))
            .min(self.pending.values().map(|approval| approval.next.saturating_duration_since(Instant::now())).min().unwrap_or(IDLE))
    }

    fn poll(&mut self) {
        let now = Instant::now();
        let due: Vec<String> =
            self.pending.iter().filter(|(_, approval)| approval.next <= now).map(|(service, _)| service.clone()).collect();
        for service in due {
            let (Some(site), Some(approval)) = (site(&service), self.pending.get_mut(&service)) else {
                continue;
            };
            let params = vec![("method".into(), "auth.getSession".into()), ("token".into(), approval.token.clone())];
            match call(&site, params) {
                Ok(reply) => {
                    self.pending.remove(&service);
                    let session = &reply["session"];
                    save_account(&service, Some(json!({ "user": session["name"], "session": session["key"] })));
                    self.answer(&service, "");
                }
                Err(Failure::Waiting | Failure::Offline(_)) if now < approval.until => approval.next = now + POLL,
                Err(failure) => {
                    self.pending.remove(&service);
                    self.answer(&service, &failure.message());
                }
            }
        }
    }

    fn check(&mut self) {
        self.poll();
        let reached = self.listen.as_ref().and_then(Listen::remaining) == Some(Duration::ZERO);
        if reached {
            if let Some(listen) = self.listen.as_mut() {
                listen.sent = true;
                let station = &listen.song["station"];
                let heard = match station.is_object() {
                    true if station["id"] == self.station["id"] => None,
                    true => {
                        self.station = station.clone();
                        Some(station)
                    }
                    false => {
                        self.station = Json::Null;
                        Some(&listen.song)
                    }
                };
                if let Some(entry) = heard.and_then(|song| crate::history::record(song, listen.started)) {
                    let _ = self.events.send(Event::Played(entry.to_string()));
                    crate::plugins::emit("played", entry);
                }
                if let Some(mut entry) = listen.track.clone() {
                    entry["timestamp"] = json!(listen.started);
                    for service in accounts().keys() {
                        entry["service"] = json!(service);
                        self.queue.push(entry.clone());
                    }
                    self.drop_oldest_beyond_limit();
                }
            }
            self.flush();
        } else if !self.queue.is_empty() && self.last_flush.elapsed() >= RETRY {
            self.flush();
        }
    }

    fn handle(&mut self, command: Command) {
        match command {
            Command::Track(song) => {
                self.listen = (song["id"].is_string() && song["ephemeral"] != true).then(|| Listen {
                    track: scrobbable(&song),
                    song,
                    started: now(),
                    played: Duration::ZERO,
                    since: self.playing.then(Instant::now),
                    sent: false,
                });
                if let Some(track) = self.listen.as_ref().and_then(|listen| listen.track.as_ref()) {
                    for (service, account) in accounts_snapshot() {
                        let _ = now_playing(&service, &account, track);
                    }
                }
            }
            Command::State(playing) => {
                self.playing = playing;
                if let Some(listen) = self.listen.as_mut() {
                    listen.set_playing(playing);
                }
            }
            Command::Connect(service) => match site(&service) {
                Some(site) => match call(&site, vec![("method".into(), "auth.getToken".into())]) {
                    Ok(reply) => {
                        let token = reply["token"].as_str().unwrap_or_default().to_owned();
                        let url = format!("{}?api_key={}&token={}", site.auth, site.key, token);
                        let now = Instant::now();
                        self.pending.insert(service.clone(), Approval { token, next: now + POLL, until: now + APPROVAL });
                        let _ = self.events.send(Event::ScrobbleAuthUrl { service, url });
                    }
                    Err(failure) => self.answer(&service, &failure.message()),
                },
                None => {}
            },
            Command::Cancel(service) => {
                self.pending.remove(&service);
            }
            Command::Token(token) => match listenbrainz_user(&token) {
                Ok(user) => {
                    save_account("listenbrainz", Some(json!({ "user": user, "token": token })));
                    self.answer("listenbrainz", "");
                }
                Err(failure) => self.answer("listenbrainz", &failure.message()),
            },
            Command::Disconnect(service) => {
                save_account(&service, None);
                self.queue.retain(|entry| entry["service"] != service.as_str());
                self.save_queue();
                self.answer(&service, "");
            }
        }
    }

    fn answer(&self, service: &str, error: &str) {
        let _ = self.events.send(Event::ScrobbleAccount { service: service.into(), error: error.into() });
    }

    fn flush(&mut self) {
        self.last_flush = Instant::now();
        let accounts = accounts_snapshot();
        for service in SERVICES {
            let Some(account) = accounts.get(service) else {
                self.queue.retain(|entry| entry["service"] != service);
                continue;
            };
            loop {
                let size = site(service).map_or(LISTENBRAINZ_BATCH, |site| site.batch);
                let batch: Vec<Json> =
                    self.queue.iter().filter(|entry| entry["service"] == service).take(size).cloned().collect();
                if batch.is_empty() {
                    break;
                }
                let result = submit(service, account, &batch);
                if matches!(result, Err(Failure::Offline(_))) {
                    break;
                }
                let mut left = batch.len();
                self.queue.retain(|entry| {
                    let drop = left > 0 && entry["service"] == service;
                    left -= drop as usize;
                    !drop
                });
                if result == Err(Failure::SignedOut) {
                    save_account(service, None);
                    self.answer(service, &Failure::SignedOut.message());
                    break;
                }
            }
        }
        self.save_queue();
    }

    fn drop_oldest_beyond_limit(&mut self) {
        let excess = self.queue.len().saturating_sub(QUEUE_LIMIT);
        self.queue.drain(..excess);
    }

    fn save_queue(&self) {
        if let Some(shared) = SHARED.get() {
            let _ = write(&shared.root.join(QUEUE_FILE), &Json::Array(self.queue.clone()));
        }
    }
}

fn accounts_snapshot() -> Map<String, Json> {
    SHARED.get().map(|shared| accounts_of(shared).clone()).unwrap_or_default()
}

fn now_playing(service: &str, account: &Json, track: &Json) -> Result<(), Failure> {
    match site(service) {
        Some(site) => {
            let mut params = vec![
                ("method".into(), "track.updateNowPlaying".into()),
                ("sk".into(), account["session"].as_str().unwrap_or_default().into()),
            ];
            params.extend(track_params(track, None));
            call(&site, params).map(|_| ())
        }
        None => listenbrainz_submit(account, "playing_now", vec![listen(track, None)]),
    }
}

fn submit(service: &str, account: &Json, batch: &[Json]) -> Result<(), Failure> {
    match site(service) {
        Some(site) => {
            let mut params = vec![
                ("method".into(), "track.scrobble".into()),
                ("sk".into(), account["session"].as_str().unwrap_or_default().into()),
            ];
            for (index, entry) in batch.iter().enumerate() {
                params.extend(track_params(entry, (site.batch > 1).then_some(index)));
            }
            call(&site, params).map(|_| ())
        }
        None => {
            let kind = if batch.len() == 1 { "single" } else { "import" };
            let listens = batch.iter().map(|entry| listen(entry, entry["timestamp"].as_u64())).collect();
            listenbrainz_submit(account, kind, listens)
        }
    }
}

fn track_params(track: &Json, index: Option<usize>) -> Vec<(String, String)> {
    let name = |key: &str| index.map_or_else(|| key.to_owned(), |index| format!("{key}[{index}]"));
    let mut params = vec![
        (name("artist"), track["artist"].as_str().unwrap_or_default().to_owned()),
        (name("track"), track["title"].as_str().unwrap_or_default().to_owned()),
    ];
    for (param, key) in [("album", "album"), ("albumArtist", "album_artist")] {
        if let Some(value) = track[key].as_str().filter(|value| !value.is_empty()) {
            params.push((name(param), value.to_owned()));
        }
    }
    if let Some(duration) = track["duration"].as_u64().filter(|duration| *duration > 0) {
        params.push((name("duration"), duration.to_string()));
    }
    if let Some(timestamp) = track["timestamp"].as_u64() {
        params.push((name("timestamp"), timestamp.to_string()));
    }
    params
}

fn sign(params: &[(String, String)], secret: &str) -> String {
    let mut text: String = params.iter().map(|(key, value)| format!("{key}{value}")).collect();
    text.push_str(secret);
    crate::plugins::hex(&Md5::digest(text.as_bytes()))
}

fn call(site: &Site, mut params: Vec<(String, String)>) -> Result<Json, Failure> {
    params.push(("api_key".into(), site.key.into()));
    params.sort();
    let signature = sign(&params, site.secret);
    params.push(("api_sig".into(), signature));
    params.push(("format".into(), "json".into()));
    let response = agent()
        .post(site.api)
        .send_form(params.iter().map(|(key, value)| (key.as_str(), value.as_str())));
    let (status, reply) = answer(response)?;
    let message = reply["message"].as_str().unwrap_or_default().to_owned();
    match reply["error"].as_i64() {
        Some(9) => Err(Failure::SignedOut),
        Some(14) => Err(Failure::Waiting),
        Some(11 | 16 | 29) => Err(Failure::Offline(message)),
        Some(_) => Err(Failure::Rejected(message)),
        None => status_result(status, reply),
    }
}

fn listen(track: &Json, timestamp: Option<u64>) -> Json {
    let mut metadata = json!({
        "artist_name": track["artist"],
        "track_name": track["title"],
        "additional_info": {
            "media_player": "Nari",
            "submission_client": "Nari",
            "submission_client_version": env!("CARGO_PKG_VERSION"),
        },
    });
    if let Some(album) = track["album"].as_str().filter(|album| !album.is_empty()) {
        metadata["release_name"] = json!(album);
    }
    if let Some(duration) = track["duration"].as_u64().filter(|duration| *duration > 0) {
        metadata["additional_info"]["duration_ms"] = json!(duration * 1000);
    }
    let mut listen = json!({ "track_metadata": metadata });
    if let Some(timestamp) = timestamp {
        listen["listened_at"] = json!(timestamp);
    }
    listen
}

fn listenbrainz_submit(account: &Json, kind: &str, listens: Vec<Json>) -> Result<(), Failure> {
    let token = account["token"].as_str().unwrap_or_default();
    let response = agent()
        .post(format!("{LISTENBRAINZ}submit-listens"))
        .header("Authorization", format!("Token {token}"))
        .header("Content-Type", "application/json")
        .send(json!({ "listen_type": kind, "payload": listens }).to_string());
    let (status, reply) = answer(response)?;
    if status == 401 {
        return Err(Failure::SignedOut);
    }
    status_result(status, reply).map(|_| ())
}

fn listenbrainz_user(token: &str) -> Result<String, Failure> {
    let response = agent()
        .get(format!("{LISTENBRAINZ}validate-token"))
        .header("Authorization", format!("Token {token}"))
        .call();
    let (status, reply) = answer(response)?;
    let reply = status_result(status, reply)?;
    match reply["user_name"].as_str() {
        Some(user) if reply["valid"] == true => Ok(user.to_owned()),
        _ => Err(Failure::Rejected("That token isn't valid".into())),
    }
}

fn answer(response: Result<ureq::http::Response<ureq::Body>, ureq::Error>) -> Result<(u16, Json), Failure> {
    let mut response = response.map_err(|error| Failure::Offline(error.to_string()))?;
    let status = response.status().as_u16();
    let body = response.body_mut().read_to_string().unwrap_or_default();
    Ok((status, serde_json::from_str(&body).unwrap_or(Json::Null)))
}

fn status_result(status: u16, reply: Json) -> Result<Json, Failure> {
    let message = || reply["error"].as_str().map_or_else(|| format!("HTTP {status}"), str::to_owned);
    match status {
        200..=299 => Ok(reply),
        429 | 500.. => Err(Failure::Offline(message())),
        _ => Err(Failure::Rejected(message())),
    }
}

pub(crate) fn agent() -> &'static ureq::Agent {
    static AGENT: OnceLock<ureq::Agent> = OnceLock::new();
    AGENT.get_or_init(|| {
        ureq::Agent::config_builder()
            .timeout_global(Some(HTTP_TIMEOUT))
            .http_status_as_error(false)
            .build()
            .into()
    })
}

fn read(file: &Path) -> Json {
    std::fs::read_to_string(file)
        .ok()
        .and_then(|text| serde_json::from_str(&text).ok())
        .unwrap_or(Json::Null)
}

fn write(file: &Path, value: &Json) -> std::io::Result<()> {
    crate::storage::write_atomically(file, value.to_string().as_bytes())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn scrobbles_after_half_the_song_or_four_minutes() {
        assert_eq!(needed(20), None);
        assert_eq!(needed(30), Some(Duration::from_secs(15)));
        assert_eq!(needed(200), Some(Duration::from_secs(100)));
        assert_eq!(needed(3600), Some(MAX_WAIT));
    }

    #[test]
    fn paused_time_does_not_count() {
        let mut listen = Listen {
            song: json!({ "id": "a", "duration": 60_000 }),
            track: None,
            started: 0,
            played: Duration::from_secs(10),
            since: None,
            sent: false,
        };
        std::thread::sleep(Duration::from_millis(20));
        assert_eq!(listen.remaining(), Some(Duration::from_secs(20)));
        listen.set_playing(true);
        std::thread::sleep(Duration::from_millis(20));
        listen.set_playing(false);
        let remaining = listen.remaining().unwrap();
        assert!(remaining < Duration::from_secs(20) && remaining > Duration::from_secs(19));
        listen.sent = true;
        assert_eq!(listen.remaining(), None);
    }

    #[test]
    fn unknown_songs_are_not_scrobbled() {
        assert!(scrobbable(&json!({ "title": "Song", "artist": crate::library::UNKNOWN_ARTIST })).is_none());
        let track = scrobbable(&json!({ "title": "Song", "artist": "Band", "album": crate::library::UNKNOWN_ALBUM, "duration": 185_400 })).unwrap();
        assert_eq!(track["album"], "");
        assert_eq!(track["duration"], 185);
    }

    #[test]
    fn signature_matches_the_audioscrobbler_rules() {
        let mut params = vec![
            ("method".to_owned(), "auth.getSession".to_owned()),
            ("token".to_owned(), "abc".to_owned()),
            ("api_key".to_owned(), "key".to_owned()),
        ];
        params.sort();
        let expected = crate::plugins::hex(&Md5::digest(b"api_keykeymethodauth.getSessiontokenabcsecret"));
        assert_eq!(sign(&params, "secret"), expected);
    }

    #[test]
    fn batches_number_every_track() {
        let params = track_params(&json!({ "title": "T", "artist": "A", "album": "", "duration": 90, "timestamp": 5 }), Some(3));
        let keys: Vec<&str> = params.iter().map(|(key, _)| key.as_str()).collect();
        assert_eq!(keys, ["artist[3]", "track[3]", "duration[3]", "timestamp[3]"]);
    }

    #[test]
    fn libre_fm_gets_one_unindexed_scrobble_per_call() {
        let track = json!({ "title": "T", "artist": "A", "timestamp": 5 });
        let keys = |service: &str| {
            let site = site(service).unwrap();
            track_params(&track, (site.batch > 1).then_some(0)).into_iter().map(|(key, _)| key).collect::<Vec<_>>()
        };
        assert_eq!(keys("librefm"), ["artist", "track", "timestamp"]);
        assert_eq!(keys("lastfm"), ["artist[0]", "track[0]", "timestamp[0]"]);
    }

    #[test]
    fn files_round_trip() {
        let file = std::env::temp_dir().join(format!("nari-scrobble-{}.json", std::process::id()));
        write(&file, &json!([{ "service": "lastfm", "timestamp": 1 }])).unwrap();
        assert_eq!(read(&file)[0]["timestamp"], 1);
        let _ = std::fs::remove_file(file);
        assert_eq!(read(Path::new("/nonexistent/nari.json")), Json::Null);
    }
}
