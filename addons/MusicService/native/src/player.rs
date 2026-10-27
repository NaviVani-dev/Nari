use rand::RngExt;
use serde_json::json;
use std::collections::{HashMap, HashSet};
use std::sync::mpsc::Sender;
use std::sync::Arc;
use std::time::Instant;

use crate::audio::{Engine, EngineEvent, Media};
use crate::effects::{Custom, Effect, Stage, MAX_STAGES};
use crate::spectrum::SNAPSHOT;
use crate::events::Event;
use crate::library::{Library, Song};
use crate::playlists::Playlists;

pub const REPEAT_OFF: i32 = 0;
pub const REPEAT_ALL: i32 = 1;
pub const REPEAT_ONE: i32 = 2;

const RESTART_THRESHOLD_MS: u64 = 5000;
const POSITION_INTERVAL_MS: u128 = 250;
const MIN_EFFECT_FACTOR: f32 = 0.25;
const MAX_EFFECT_FACTOR: f32 = 4.0;
const TRACK_GAP_MS: u64 = 1000;
const DUCK_VOLUME: f32 = 0.2;
const REBUILD_INTERVAL_MS: u128 = 1000;

#[derive(serde::Deserialize, Default)]
#[serde(default)]
struct RemoteSong {
    id: String,
    title: String,
    artist: String,
    artist_id: String,
    album: String,
    album_id: String,
    #[serde(deserialize_with = "whole_number")]
    duration: i64,
    uri: String,
    file_name: String,
    cover: String,
    cover_url: String,
    public_cover_url: String,
    share_url: String,
    replay_gain: Option<f32>,
    live: bool,
    ephemeral: bool,
}

fn whole_number<'de, D: serde::Deserializer<'de>>(deserializer: D) -> Result<i64, D::Error> {
    let value: serde_json::Value = serde::Deserialize::deserialize(deserializer)?;
    Ok(value.as_i64().or_else(|| value.as_f64().map(|number| number.round() as i64)).unwrap_or(0))
}

fn remote_songs(json: &str) -> Vec<RemoteSong> {
    let entries: Vec<serde_json::Value> = serde_json::from_str(json).unwrap_or_default();
    entries
        .into_iter()
        .filter_map(|entry| serde_json::from_value::<RemoteSong>(entry).ok())
        .filter(|song| !song.id.is_empty())
        .collect()
}

pub struct Player {
    engine: Option<Engine>,
    cast: Option<Arc<crate::cast::Broadcast>>,
    remote: HashMap<String, Arc<Song>>,
    cover_urls: HashMap<String, String>,
    fetched_covers: HashSet<String>,
    library: Arc<Library>,
    playlists: Arc<Playlists>,
    events: Sender<Event>,
    items: Vec<Arc<Song>>,
    index: usize,
    loaded: usize,
    tokens: usize,
    queued: Option<(usize, usize, String)>,
    base_queue_ids: Vec<String>,
    queue_ids: Vec<String>,
    queue_version: u64,
    shuffled: bool,
    repeat: i32,
    playing: bool,
    ended: bool,
    last_error: String,
    normalize: bool,
    ducked: bool,
    gapless: bool,
    effect: Effect,
    speed: f32,
    pitch: f32,
    state: String,
    last_tick: Instant,
    spectrum_latency: i32,
    last_rebuild: Instant,
    plugin_track: String,
    plugin_playing: bool,
    equalizer: Vec<(f32, f32)>,
    custom: String,
    rack: Vec<Stage>,
    seeks: u64,
    live: usize,
    detected: (usize, u64),
    stream_title: String,
    ending: Option<Option<u64>>,
}

impl Player {
    pub fn new(library: Arc<Library>, playlists: Arc<Playlists>, events: Sender<Event>) -> Self {
        let mut player = Self {
            engine: Engine::new(None),
            cast: None,
            remote: HashMap::new(),
            cover_urls: HashMap::new(),
            fetched_covers: HashSet::new(),
            library,
            playlists,
            events,
            items: Vec::new(),
            index: 0,
            loaded: 0,
            tokens: 0,
            queued: None,
            base_queue_ids: Vec::new(),
            queue_ids: Vec::new(),
            queue_version: 0,
            shuffled: false,
            repeat: REPEAT_OFF,
            playing: false,
            ended: false,
            last_error: String::new(),
            normalize: false,
            ducked: false,
            gapless: true,
            effect: Effect::None,
            speed: 1.0,
            pitch: 1.0,
            state: String::new(),
            last_tick: Instant::now(),
            spectrum_latency: -1,
            last_rebuild: Instant::now(),
            plugin_track: String::new(),
            plugin_playing: false,
            equalizer: Vec::new(),
            custom: String::new(),
            seeks: 0,
            rack: Vec::new(),
            live: 0,
            detected: (0, 0),
            stream_title: String::new(),
            ending: None,
        };
        if player.engine.is_none() {
            player.last_error = "AUDIO_UNAVAILABLE: no output device".into();
        }
        player.refresh(false);
        player
    }

    pub fn tick(&mut self) {
        let lost = self.engine.as_ref().is_none_or(Engine::lost);
        if lost && self.last_rebuild.elapsed().as_millis() >= REBUILD_INTERVAL_MS {
            self.rebuild();
        }
        let engine_events: Vec<EngineEvent> = self
            .engine
            .as_ref()
            .map(Engine::events)
            .unwrap_or_default();
        let mut notify = false;
        for event in engine_events {
            match event {
                EngineEvent::Finished(loaded) if loaded == self.loaded => {
                    self.forget_track_if_looping();
                    if self.next_index().is_some() {
                        self.advance();
                        notify = true;
                    } else {
                        self.ending = Some(None);
                    }
                }
                EngineEvent::Advanced(from, to) if from == self.loaded => {
                    self.forget_track_if_looping();
                    match self.queued.take() {
                        Some((token, index, _)) if token == to => {
                            self.index = index;
                            self.loaded = token;
                            self.stream_title.clear();
                            self.ended = false;
                            self.apply_replay_gain();
                        }
                        _ => match self.next_index() {
                            Some(index) => self.load(index, 0),
                            None => self.advance(),
                        },
                    }
                    notify = true;
                }
                EngineEvent::Live(loaded) if loaded == self.loaded => {
                    self.live = loaded;
                    notify = true;
                }
                EngineEvent::Length(loaded, length) if loaded == self.loaded => {
                    self.detected = (loaded, length);
                    notify = true;
                }
                EngineEvent::Title(loaded, title) if loaded == self.loaded => {
                    self.stream_title = title;
                    notify = true;
                }
                EngineEvent::Failed(loaded, error) if loaded == self.loaded => {
                    self.last_error = format!("DECODE_FAILED: {error}");
                    self.advance();
                    notify = true;
                }
                _ => {}
            }
        }
        if self.ended_audibly() {
            self.ending = None;
            self.advance();
            notify = true;
        }
        if notify {
            self.refresh(true);
            return;
        }
        if self.playing && self.last_tick.elapsed().as_millis() >= POSITION_INTERVAL_MS {
            self.last_tick = Instant::now();
            self.refresh(true);
        }
    }

    fn ended_audibly(&mut self) -> bool {
        let Some(page) = self.ending else {
            return false;
        };
        let drained = self.engine.as_ref().is_none_or(|engine| engine.buffered_ms() == 0);
        match (page, self.cast.as_ref()) {
            (_, None) => drained,
            (None, Some(sink)) => {
                if drained {
                    self.ending = Some(Some(sink.head()));
                }
                false
            }
            (Some(page), Some(sink)) => sink.until_ms(page) == 0,
        }
    }

    pub fn play(&mut self, song_id: &str, context_type: &str, context_id: &str) {
        if context_type == "queue" {
            if let Some(index) = self.queue_ids.iter().position(|id| id == song_id) {
                self.skip_to_queue_index(index as i32);
            }
            return;
        }
        let queue = self.resolve_context(context_type, context_id);
        self.play_list(queue, song_id);
    }

    pub fn play_shuffled(&mut self, context_type: &str, context_id: &str) {
        let queue = self.resolve_context(context_type, context_id);
        self.shuffle_list(queue);
    }

    pub fn register_songs(&mut self, songs_json: &str) {
        for song in remote_songs(songs_json) {
            if !song.cover.is_empty() && !song.cover_url.is_empty() {
                self.cover_urls.insert(song.cover.clone(), song.cover_url.clone());
            }
            let registered = Song {
                id: song.id.clone(),
                title: song.title,
                artists: vec![song.artist.clone()],
                artist: song.artist,
                artist_ids: vec![song.artist_id.clone()],
                artist_id: song.artist_id,
                album: song.album,
                album_id: song.album_id,
                duration: song.duration,
                uri: song.uri,
                file_name: song.file_name,
                folder_cover: song.cover,
                replay_gain: song.replay_gain,
                public_cover_url: song.public_cover_url,
                share_url: song.share_url,
                live: song.live,
                ephemeral: song.ephemeral,
                ..Song::default()
            };
            self.remote.insert(song.id, Arc::new(registered));
        }
    }

    pub fn play_songs(&mut self, ids: &[String], song_id: &str, shuffled: bool) {
        let queue = self.songs_by_ids(ids);
        if shuffled {
            self.shuffle_list(queue);
        } else {
            self.play_list(queue, song_id);
        }
    }

    pub fn restore_songs(&mut self, ids: &[String], song_id: &str, position_ms: u64) -> bool {
        let queue = self.songs_by_ids(ids);
        let Some(index) = queue.iter().position(|song| song.id == song_id) else {
            return false;
        };
        self.last_error.clear();
        self.shuffled = false;
        self.base_queue_ids = queue.iter().map(|song| song.id.clone()).collect();
        self.items = queue;
        self.load(index, position_ms);
        self.set_playing(false);
        true
    }

    fn play_list(&mut self, queue: Vec<Arc<Song>>, song_id: &str) {
        if queue.is_empty() {
            return;
        }
        let index = queue
            .iter()
            .position(|song| song.id == song_id)
            .unwrap_or(0);
        self.shuffled = false;
        self.start_queue(queue, index);
    }

    fn shuffle_list(&mut self, queue: Vec<Arc<Song>>) {
        if queue.is_empty() {
            return;
        }
        let start = rand::rng().random_range(0..queue.len());
        let order = shuffle_order(queue.len(), start);
        let queue = order.iter().map(|index| queue[*index].clone()).collect();
        self.shuffled = true;
        self.start_queue(queue, 0);
    }

    pub fn resume(&mut self) {
        if self.items.is_empty() {
            return;
        }
        if self.ended {
            self.load(0, 0);
        }
        self.set_playing(true);
    }

    pub fn pause(&mut self) {
        self.set_playing(false);
    }

    pub fn toggle(&mut self) {
        if self.playing {
            self.pause();
        } else {
            self.resume();
        }
    }

    pub fn stop(&mut self) {
        if let Some(engine) = self.engine.as_ref() {
            engine.clear();
            engine.set_playing(false);
        }
        self.items.clear();
        self.queued = None;
        self.base_queue_ids.clear();
        self.index = 0;
        self.playing = false;
        self.ended = false;
        self.ending = None;
        self.refresh(true);
    }

    pub fn next(&mut self) {
        if self.items.is_empty() {
            return;
        }
        self.load(self.next_index().unwrap_or(0), 0);
        self.refresh(true);
    }

    pub fn previous(&mut self) {
        if (!self.is_live() && self.position() > RESTART_THRESHOLD_MS) || self.previous_index().is_none() {
            self.seek_to(0);
            return;
        }
        if let Some(index) = self.previous_index() {
            self.load(index, 0);
            self.refresh(true);
        }
    }

    pub fn seek_to(&mut self, position_ms: i32) {
        let position = position_ms.max(0) as u64;
        if self.items.is_empty() || self.is_live() {
            return;
        }
        if self.ended || self.ending.is_some() {
            self.load(self.index, position);
        } else if let Some(engine) = self.engine.as_ref() {
            engine.seek(position);
        }
        self.seeks += 1;
        self.refresh(true);
    }

    pub fn set_shuffle(&mut self, enabled: bool) {
        if enabled == self.shuffled {
            return;
        }
        let count = self.items.len();
        if count == 0 || self.base_queue_ids.len() != count {
            return;
        }
        let Some(current) = self.items.get(self.index).cloned() else {
            return;
        };
        let start = self
            .base_queue_ids
            .iter()
            .position(|id| *id == current.id)
            .unwrap_or(0);
        let before = if enabled {
            Vec::new()
        } else {
            self.songs_by_ids(&self.base_queue_ids[..start])
        };
        let after = if enabled {
            let order: Vec<String> = shuffle_order(count, start)
                .into_iter()
                .skip(1)
                .map(|index| self.base_queue_ids[index].clone())
                .collect();
            self.songs_by_ids(&order)
        } else {
            self.songs_by_ids(&self.base_queue_ids[start + 1..])
        };
        if before.len() + after.len() + 1 != count {
            return;
        }
        self.shuffled = enabled;
        self.index = before.len();
        self.items = before;
        self.items.push(current);
        self.items.extend(after);
        self.refresh(true);
    }

    pub fn set_repeat(&mut self, mode: i32) {
        self.repeat = match mode {
            REPEAT_ALL => REPEAT_ALL,
            REPEAT_ONE => REPEAT_ONE,
            _ => REPEAT_OFF,
        };
        self.refresh(true);
    }

    pub fn skip_to_queue_index(&mut self, index: i32) {
        if index < 0 || index as usize >= self.items.len() {
            return;
        }
        self.load(index as usize, 0);
        self.set_playing(true);
    }

    pub fn add_to_queue(&mut self, song_id: &str) {
        let Some(song) = self.song(song_id) else {
            return;
        };
        self.items.push(song);
        let id = song_id.to_owned();
        self.sync_base(move |base| base.push(id));
        self.refresh(true);
    }

    pub fn play_next(&mut self, song_id: &str) {
        let Some(song) = self.song(song_id) else {
            return;
        };
        let current_id = self.items.get(self.index).map(|song| song.id.clone());
        let at = (self.index + 1).min(self.items.len());
        self.items.insert(at, song);
        let id = song_id.to_owned();
        self.sync_base(move |base| {
            let at = current_id
                .and_then(|current| base.iter().position(|value| *value == current))
                .map(|index| index + 1)
                .unwrap_or(base.len());
            base.insert(at.min(base.len()), id);
        });
        self.refresh(true);
    }

    pub fn remove_from_queue(&mut self, index: i32) {
        if index < 0 || index as usize >= self.items.len() {
            return;
        }
        let index = index as usize;
        let removed = self.items.remove(index).id.clone();
        self.sync_base(move |base| remove_once_each(base, &[removed]));
        if index < self.index {
            self.index -= 1;
        } else if index == self.index {
            if self.index < self.items.len() {
                self.load(self.index, 0);
            } else {
                self.stop();
                return;
            }
        }
        self.refresh(true);
    }

    pub fn move_in_queue(&mut self, from: i32, to: i32) {
        let count = self.items.len();
        if from < 0 || to < 0 || from == to {
            return;
        }
        let (from, to) = (from as usize, to as usize);
        if from >= count || to >= count {
            return;
        }
        let item = self.items.remove(from);
        self.items.insert(to, item);
        if self.index == from {
            self.index = to;
        } else if from < self.index && to >= self.index {
            self.index -= 1;
        } else if from > self.index && to <= self.index {
            self.index += 1;
        }
        self.sync_base(|_| {});
        self.refresh(true);
    }

    pub fn clear_queue(&mut self) {
        let next = self.index + 1;
        if next >= self.items.len() {
            return;
        }
        let removed: Vec<String> = self.items[next..]
            .iter()
            .map(|song| song.id.clone())
            .collect();
        self.items.truncate(next);
        self.sync_base(move |base| remove_once_each(base, &removed));
        self.refresh(true);
    }

    pub fn set_gapless(&mut self, enabled: bool) {
        self.gapless = enabled;
    }

    #[cfg_attr(not(target_os = "android"), allow(dead_code))]
    pub fn set_ducked(&mut self, ducked: bool) {
        self.ducked = ducked;
        self.apply_replay_gain();
    }

    pub fn current_id(&self) -> String {
        self.items
            .get(self.index)
            .map(|song| song.id.clone())
            .unwrap_or_default()
    }

    #[cfg(any(target_os = "macos", target_os = "ios"))]
    pub fn local_song(&self) -> Option<Arc<Song>> {
        self.items.get(self.index).filter(|song| !self.remote.contains_key(&song.id)).cloned()
    }

    #[cfg_attr(not(target_os = "android"), allow(dead_code))]
    pub fn command(&mut self, name: &str, value: i64) {
        match name {
            "play" => self.resume(),
            "pause" | "stop" => self.pause(),
            "toggle" => self.toggle(),
            "next" => self.next(),
            "previous" => self.previous(),
            "seek" => self.seek_to(value.clamp(0, i64::from(i32::MAX)) as i32),
            "duck" => self.set_ducked(value != 0),
            _ => {}
        }
    }

    pub fn is_playing(&self) -> bool {
        self.playing
    }

    #[cfg_attr(not(target_os = "android"), allow(dead_code))]
    pub fn session_json(&self) -> String {
        let Some(song) = self.items.get(self.index) else {
            return json!({ "id": "" }).to_string();
        };
        let (title, artists, album) = self.shown(song);
        json!({
            "id": song.id,
            "title": title,
            "artist": artists.join(", "),
            "album": album,
            "live": self.is_live(),
            "duration": self.duration(),
            "position": self.position(),
            "playing": self.playing,
            "has_next": self.next_index().is_some(),
            "has_previous": self.previous_index().is_some(),
            "cover": self.cover(song, false),
        })
        .to_string()
    }

    pub fn set_equalizer(&mut self, bands: Vec<(f32, f32)>) {
        if let Some(engine) = self.engine.as_ref() {
            engine.set_equalizer(&bands);
        }
        self.equalizer = bands;
    }

    pub fn set_normalize_volume(&mut self, enabled: bool) {
        self.normalize = enabled;
        self.apply_replay_gain();
    }

    pub fn apply_music_effect(&mut self, effect_id: &str) -> bool {
        let Some(effect) = Effect::from_id(effect_id) else {
            return false;
        };
        self.clear_custom();
        self.effect = effect;
        self.speed = 1.0;
        self.pitch = effect.pitch();
        self.notify_effect();
        true
    }

    pub fn apply_custom_effect(&mut self, id: &str, spec: &str) -> bool {
        let Ok(custom) = serde_json::from_str::<Custom>(spec) else {
            return false;
        };
        if id.is_empty() || custom.chain.len() > MAX_STAGES {
            return false;
        }
        self.effect = Effect::None;
        self.custom = id.to_owned();
        self.rack = custom.chain;
        self.speed = clamp_factor(custom.speed.unwrap_or(1.0));
        self.pitch = clamp_factor(custom.pitch.unwrap_or(1.0));
        self.notify_effect();
        true
    }

    fn clear_custom(&mut self) {
        self.custom.clear();
        self.rack.clear();
    }

    pub fn apply_music_distortion(&mut self, speed: f32, pitch: f32) {
        self.clear_custom();
        self.effect = Effect::None;
        self.speed = clamp_factor(speed);
        self.pitch = clamp_factor(pitch);
        self.notify_effect();
    }

    pub fn reset_music_effect(&mut self) {
        self.clear_custom();
        self.effect = Effect::None;
        self.speed = 1.0;
        self.pitch = 1.0;
        self.notify_effect();
    }

    pub fn effect_state_json(&self) -> String {
        let effect = if self.custom.is_empty() { self.effect.id() } else { self.custom.as_str() };
        json!({ "effect": effect, "speed": self.speed, "pitch": self.pitch }).to_string()
    }

    pub fn media(&self) -> crate::mpris::Media {
        let Some(song) = self.items.get(self.index) else {
            return crate::mpris::Media { playing: self.playing, ..Default::default() };
        };
        let (title, artists, album) = self.shown(song);
        crate::mpris::Media {
            id: song.id.clone(),
            title,
            artists,
            album,
            length_ms: self.duration(),
            art: self.cover(song, false),
            playing: self.playing,
            has_song: true,
            has_next: self.next_index().is_some(),
            seeks: self.seeks,
        }
    }

    pub fn tray_state(&self) -> (String, bool, String) {
        let Some(song) = self.items.get(self.index) else {
            return (String::new(), self.playing, String::new());
        };
        let (title, artists, _) = self.shown(song);
        (format!("{} — {}", title, artists.join(", ")), self.playing, self.cover(song, true))
    }

    pub fn is_live(&self) -> bool {
        (self.live != 0 && self.live == self.loaded) || self.items.get(self.index).is_some_and(|song| song.live)
    }

    fn shown(&self, song: &Song) -> (String, Vec<String>, String) {
        if self.stream_title.is_empty() {
            let artists = if song.artists.is_empty() { vec![song.artist.clone()] } else { song.artists.clone() };
            return (song.title.clone(), artists, song.album.clone());
        }
        match self.stream_title.split_once(" - ") {
            Some((artist, title)) => (title.trim().to_owned(), vec![artist.trim().to_owned()], song.title.clone()),
            None => (self.stream_title.clone(), vec![song.title.clone()], song.title.clone()),
        }
    }

    pub fn spectrum(&self) -> [u8; SNAPSHOT] {
        self.engine
            .as_ref()
            .map(Engine::spectrum)
            .unwrap_or_else(|| {
                let mut quiet = [0u8; SNAPSHOT];
                quiet[32..160].fill(128);
                quiet
            })
    }

    pub fn set_spectrum_latency(&mut self, milliseconds: i32) {
        self.spectrum_latency = milliseconds.clamp(0, 600);
        if let Some(engine) = self.engine.as_ref() {
            engine.set_spectrum_latency(self.spectrum_latency);
        }
    }

    fn rebuild(&mut self) {
        let position = self.position();
        self.rebuild_at(position);
    }

    fn rebuild_at(&mut self, position: u64) {
        self.last_rebuild = Instant::now();
        self.engine = None;
        self.engine = Engine::new(self.cast.clone());
        let Some(engine) = self.engine.as_ref() else {
            self.last_error = "AUDIO_UNAVAILABLE: no output device".into();
            return;
        };
        engine.set_effect(self.effect);
        engine.set_factors(self.speed, self.pitch);
        engine.set_equalizer(&self.equalizer);
        engine.set_rack(&self.rack);
        if self.spectrum_latency >= 0 {
            engine.set_spectrum_latency(self.spectrum_latency);
        }
        self.last_error.clear();
        if !self.items.is_empty() && !self.ended {
            self.load(self.index, position);
        }
        self.set_playing(self.playing);
    }

    pub fn set_cast(&mut self, sink: Option<Arc<crate::cast::Broadcast>>) {
        let position = self.position();
        self.cast = sink;
        self.rebuild_at(position);
        self.refresh(true);
    }

    pub fn state_json(&self) -> String {
        self.state.clone()
    }

    pub fn queue_songs_json(&self) -> String {
        let songs: Vec<serde_json::Value> = self
            .items
            .iter()
            .map(|song| {
                json!({
                    "id": song.id,
                    "title": song.title,
                    "artist": song.artist,
                    "artists": song.artists,
                    "artist_id": song.artist_id,
                    "album": song.album,
                    "album_id": song.album_id,
                    "duration": song.duration,
                    "own_cover": song.own_cover,
                })
            })
            .collect();
        serde_json::Value::Array(songs).to_string()
    }

    pub fn queue_ids_json(&self) -> String {
        serde_json::to_string(&self.queue_ids).unwrap_or_else(|_| "[]".into())
    }

    pub fn shutdown(&mut self) {
        if let Some(engine) = self.engine.take() {
            engine.set_playing(false);
            drop(engine);
        }
        self.playing = false;
    }

    pub fn position(&self) -> u64 {
        if self.items.is_empty() {
            return 0;
        }
        if let (Some(Some(page)), Some(sink)) = (self.ending, self.cast.as_ref()) {
            let left = (sink.until_ms(page) as f64 * f64::from(self.speed)) as u64;
            return self.duration().saturating_sub(left);
        }
        let delay = self.cast.as_ref().map_or(0, |sink| sink.delay_ms());
        let delay = if self.is_live() { delay } else { (delay as f64 * f64::from(self.speed)) as u64 };
        match self.engine.as_ref().and_then(Engine::position) {
            Some((loaded, position)) if loaded == self.loaded && self.is_live() => position.saturating_sub(delay),
            Some((loaded, position)) if loaded == self.loaded => position.saturating_sub(delay).min(self.duration().max(1)),
            _ => 0,
        }
    }

    pub fn buffered(&self) -> Vec<(f64, f64)> {
        match self.engine.as_ref() {
            Some(engine) if !self.is_live() => engine.buffered(self.loaded),
            _ => Vec::new(),
        }
    }

    pub fn duration(&self) -> u64 {
        let given = self.items.get(self.index).map(|song| song.duration.max(0) as u64).unwrap_or(0);
        match self.detected {
            (loaded, length) if given == 0 && loaded == self.loaded => length,
            _ => given,
        }
    }

    fn song(&self, id: &str) -> Option<Arc<Song>> {
        self.remote.get(id).cloned().or_else(|| self.library.song(id))
    }

    fn songs_by_ids(&self, ids: &[String]) -> Vec<Arc<Song>> {
        ids.iter().filter_map(|id| self.song(id)).collect()
    }

    fn cover(&self, song: &Song, thumb: bool) -> String {
        if self.remote.contains_key(&song.id) {
            return song.folder_cover.clone();
        }
        if song.album_id.is_empty() || song.own_cover {
            self.library.cached_cover(crate::library::KIND_SONG, &song.id, thumb)
        } else {
            self.library.cached_cover(crate::library::KIND_ALBUM, &song.album_id, thumb)
        }
    }

    fn ensure_cover(&mut self, song: &Song) {
        if !self.remote.contains_key(&song.id) {
            if self.cover(song, false).is_empty() {
                let (kind, id) = if song.album_id.is_empty() || song.own_cover {
                    (crate::library::KIND_SONG, &song.id)
                } else {
                    (crate::library::KIND_ALBUM, &song.album_id)
                };
                self.library.request_cover(kind, id, false);
            }
            return;
        }
        let path = &song.folder_cover;
        if path.is_empty() || std::path::Path::new(path).exists() || !self.fetched_covers.insert(path.clone()) {
            return;
        }
        if let Some(url) = self.cover_urls.get(path) {
            crate::remote::fetch_cover(url.clone(), path.clone());
        }
    }

    fn resolve_context(&self, context_type: &str, context_id: &str) -> Vec<Arc<Song>> {
        match context_type {
            "album" => self
                .library
                .album(context_id)
                .map(|album| album.songs.clone())
                .unwrap_or_default(),
            "artist" => self
                .library
                .artist(context_id)
                .map(|artist| artist.songs.clone())
                .unwrap_or_default(),
            "playlist" => self.songs_by_ids(&self.playlists.song_ids(context_id)),
            _ => self.library.songs(),
        }
    }

    fn start_queue(&mut self, queue: Vec<Arc<Song>>, index: usize) {
        self.last_error.clear();
        self.base_queue_ids = queue.iter().map(|song| song.id.clone()).collect();
        self.items = queue;
        self.load(index, 0);
        self.set_playing(true);
    }

    fn load(&mut self, index: usize, position_ms: u64) {
        self.start(index, position_ms, None);
    }

    fn start(&mut self, index: usize, position_ms: u64, gap_ms: Option<u64>) {
        self.index = index;
        self.ended = false;
        self.ending = None;
        let Some(song) = self.items.get(index).cloned() else {
            return;
        };
        self.tokens += 1;
        self.loaded = self.tokens;
        self.queued = None;
        self.stream_title.clear();
        if let Some(engine) = self.engine.as_ref() {
            engine.load(media(&song), position_ms, self.loaded, gap_ms);
        }
        self.ensure_cover(&song);
        self.apply_replay_gain();
    }

    fn advance(&mut self) {
        match self.next_index() {
            Some(index) => {
                let gap = if self.gapless { 0 } else { TRACK_GAP_MS };
                self.start(index, 0, Some(gap))
            }
            None => {
                self.ended = true;
                self.playing = false;
                if let Some(engine) = self.engine.as_ref() {
                    engine.set_playing(false);
                }
            }
        }
    }

    fn set_playing(&mut self, playing: bool) {
        self.playing = playing && !self.items.is_empty();
        if let Some(engine) = self.engine.as_ref() {
            engine.set_playing(self.playing);
        }
        self.refresh(true);
    }

    fn next_index(&self) -> Option<usize> {
        let count = self.items.len();
        if count == 0 {
            return None;
        }
        match self.repeat {
            REPEAT_ONE => Some(self.index),
            REPEAT_ALL => Some((self.index + 1) % count),
            _ => (self.index + 1 < count).then_some(self.index + 1),
        }
    }

    fn previous_index(&self) -> Option<usize> {
        let count = self.items.len();
        if count == 0 {
            return None;
        }
        match self.repeat {
            REPEAT_ONE => Some(self.index),
            REPEAT_ALL => Some((self.index + count - 1) % count),
            _ => (self.index > 0).then(|| self.index - 1),
        }
    }

    fn sync_base(&mut self, edit: impl FnOnce(&mut Vec<String>)) {
        if self.shuffled {
            edit(&mut self.base_queue_ids);
        } else {
            self.base_queue_ids = self.items.iter().map(|song| song.id.clone()).collect();
        }
    }

    fn apply_replay_gain(&self) {
        let gain = self
            .normalize
            .then(|| self.items.get(self.index).and_then(|song| song.replay_gain))
            .flatten();
        let duck = if self.ducked { DUCK_VOLUME } else { 1.0 };
        if let Some(engine) = self.engine.as_ref() {
            engine.set_volume(duck * gain.map_or(1.0, |gain| 10f32.powf(gain / 20.0).min(1.0)));
        }
    }

    fn notify_effect(&mut self) {
        if let Some(engine) = self.engine.as_ref() {
            engine.set_effect(self.effect);
            engine.set_factors(self.speed, self.pitch);
            engine.set_rack(&self.rack);
        }
        let state = self.effect_state_json();
        let _ = self.events.send(Event::EffectChanged(state));
        self.refresh(true);
    }

    fn sync_next(&mut self) {
        let wanted = self
            .next_index()
            .filter(|_| self.gapless && !self.ended)
            .and_then(|index| self.items.get(index).map(|song| (index, song.clone())));
        let current = self.queued.as_ref().map(|(_, index, id)| (*index, id.as_str()));
        if current == wanted.as_ref().map(|(index, song)| (*index, song.id.as_str())) {
            return;
        }
        if let Some((_, song)) = wanted.as_ref() {
            self.ensure_cover(song);
        }
        let Some(engine) = self.engine.as_ref() else {
            return;
        };
        self.queued = wanted.map(|(index, song)| {
            self.tokens += 1;
            engine.queue(Some((media(&song), self.tokens)));
            (self.tokens, index, song.id.clone())
        });
        if self.queued.is_none() {
            engine.queue(None);
        }
    }

    fn refresh(&mut self, notify: bool) {
        self.sync_next();
        let queue_changed = self.items.len() != self.queue_ids.len()
            || self.items.iter().zip(&self.queue_ids).any(|(song, id)| song.id != *id);
        if queue_changed {
            self.queue_ids = self.items.iter().map(|song| song.id.clone()).collect();
            self.queue_version += 1;
        }
        let position = self.position();
        let buffered = self
            .engine
            .as_ref()
            .map(|engine| position + engine.buffered_ms())
            .unwrap_or(position);
        self.state = json!({
            "connected": self.engine.is_some(),
            "casting": self.cast.is_some(),
            "error": self.last_error,
            "is_playing": self.playing,
            "state": if self.items.is_empty() { 1 } else if self.ended { 4 } else { 3 },
            "current_id": self.items.get(self.index).map(|song| song.id.clone()).unwrap_or_default(),
            "index": self.index,
            "queue_size": self.items.len(),
            "queue_version": self.queue_version,
            "position": position,
            "duration": self.duration(),
            "buffered": buffered,
            "shuffle": self.shuffled,
            "repeat": self.repeat,
            "has_next": self.next_index().is_some(),
            "has_previous": self.previous_index().is_some(),
            "effect": if self.custom.is_empty() { self.effect.id() } else { self.custom.as_str() },
            "speed": self.speed,
            "pitch": self.pitch,
            "live": self.is_live(),
            "stream_title": self.stream_title,
        })
        .to_string();
        if notify {
            let _ = self.events.send(Event::PlaybackChanged(self.state.clone()));
        }
        self.notify_plugins(position);
    }

    fn notify_plugins(&mut self, position: u64) {
        let current = format!("{}\n{}\n{}", self.current_id(), self.stream_title, self.is_live());
        if current != self.plugin_track {
            self.plugin_track = current;
            let song = self.items.get(self.index).map_or(serde_json::Value::Null, |song| {
                let (title, artists, album) = self.shown(song);
                json!({
                    "id": song.id,
                    "title": title,
                    "artist": artists.join(", "),
                    "artists": artists,
                    "album": album,
                    "live": self.is_live(),
                    "ephemeral": song.ephemeral,
                    "station": if self.is_live() { json!({ "id": song.id, "title": song.title, "artist": song.artist, "album": song.album }) } else { serde_json::Value::Null },
                    "album_id": song.album_id,
                    "artist_id": song.artist_id,
                    "album_artist": song.album_artist,
                    "duration": song.duration,
                    "public_cover_url": song.public_cover_url,
                    "share_url": song.share_url,
                })
            });
            crate::scrobble::track(&song);
            crate::discord::track(&song);
            crate::plugins::emit("track", song);
        }
        if self.playing != self.plugin_playing {
            self.plugin_playing = self.playing;
            crate::scrobble::state(self.playing);
            crate::plugins::emit("state", json!({ "playing": self.playing, "position": position }));
        }
        crate::discord::playback(self.playing, position, self.speed);
    }

    fn forget_track_if_looping(&mut self) {
        if self.next_index() == Some(self.index) {
            self.plugin_track.clear();
        }
    }
}

fn media(song: &Song) -> Media {
    Media {
        uri: song.uri.clone(),
        name: song.file_name.clone(),
    }
}

fn clamp_factor(factor: f32) -> f32 {
    if factor.is_finite() {
        factor.clamp(MIN_EFFECT_FACTOR, MAX_EFFECT_FACTOR)
    } else {
        1.0
    }
}

fn remove_once_each(base: &mut Vec<String>, removed: &[String]) {
    let mut pending: HashMap<&str, usize> = HashMap::new();
    for id in removed {
        *pending.entry(id.as_str()).or_default() += 1;
    }
    base.retain(|id| match pending.get_mut(id.as_str()) {
        Some(left) if *left > 0 => {
            *left -= 1;
            false
        }
        _ => true,
    });
}

fn shuffle_order(length: usize, start: usize) -> Vec<usize> {
    let mut random = rand::rng();
    let mut shuffled = vec![0usize; length];
    for index in 0..length {
        let swap = random.random_range(0..=index);
        shuffled[index] = shuffled[swap];
        shuffled[swap] = index;
    }
    if let Some(slot) = shuffled.iter().position(|value| *value == start) {
        shuffled.swap(0, slot);
    }
    shuffled
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn shuffle_order_is_a_permutation_starting_at_the_chosen_track() {
        for length in 1..40usize {
            let start = length / 2;
            let order = shuffle_order(length, start);
            assert_eq!(order.len(), length);
            assert_eq!(order[0], start);
            let mut sorted = order.clone();
            sorted.sort_unstable();
            assert_eq!(sorted, (0..length).collect::<Vec<_>>());
        }
    }

    #[test]
    fn removing_from_the_base_queue_keeps_other_copies() {
        let mut base: Vec<String> = ["a", "b", "a", "c", "b"].map(String::from).to_vec();
        remove_once_each(&mut base, &["a".to_owned(), "b".to_owned()]);
        assert_eq!(base, ["a", "c", "b"]);
        remove_once_each(&mut base, &["z".to_owned()]);
        assert_eq!(base, ["a", "c", "b"]);
    }

    #[test]
    fn remote_songs_survive_json_round_trips() {
        let songs = remote_songs(r#"[{"id": "a", "duration": 232000.0}, {"id": "b", "duration": 5000, "live": "nope"}, {"id": "c", "duration": 1500}]"#);
        let found: Vec<(&str, i64)> = songs.iter().map(|song| (song.id.as_str(), song.duration)).collect();
        assert_eq!(found, vec![("a", 232000), ("c", 1500)]);
    }

    #[test]
    fn effect_factors_stay_inside_the_android_range() {
        assert_eq!(clamp_factor(f32::NAN), 1.0);
        assert_eq!(clamp_factor(0.0), MIN_EFFECT_FACTOR);
        assert_eq!(clamp_factor(99.0), MAX_EFFECT_FACTOR);
        assert_eq!(Effect::from_id("HELIUM").map(Effect::pitch), Some(1.55));
        assert_eq!(Effect::from_id("nope"), None);
    }
}
