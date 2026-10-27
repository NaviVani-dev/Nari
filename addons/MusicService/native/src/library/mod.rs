pub mod covers;
pub mod folders;
pub mod meta;

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::mpsc::{channel, Sender};
use std::sync::{Arc, Mutex, RwLock};
use std::thread::JoinHandle;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use crate::events::Event;
use folders::{FolderKind, Folders};
use meta::{Metadata, RawLyrics};

pub const KIND_SONG: &str = "song";
#[allow(dead_code)]
pub const KIND_ALBUM: &str = "album";

const EXTRACT_THREADS: usize = 4;
const PROGRESS_INTERVAL_MS: u64 = 250;
const WATCH_DEBOUNCE: Duration = Duration::from_millis(1500);
const WATCH_TICK: Duration = Duration::from_millis(250);
const MAX_LYRICS_SIZE: u64 = 2 * 1024 * 1024;
const UNKNOWN_TITLE: &str = "Unknown title";
pub(crate) const UNKNOWN_ARTIST: &str = "Unknown artist";
pub(crate) const UNKNOWN_ALBUM: &str = "Unknown album";
const VARIOUS_ARTISTS: &str = "Various Artists";
const AUDIO_EXTENSIONS: [&str; 40] = [
    "mp3", "m4a", "mp4", "aac", "flac", "ogg", "oga", "opus", "wav", "wave", "aif", "aiff", "wma", "mid", "midi", "kar", "mod", "xm", "s3m", "it", "sid",
    "mptm", "669", "amf", "ams", "dbm", "dmf", "dsm", "far", "mdl", "med", "mo3", "mt2", "mtm", "okt", "psm", "ptm", "stm", "ult", "umx",
];

#[derive(Clone, Debug, Default)]
pub struct Song {
    pub live: bool,
    pub ephemeral: bool,
    pub id: String,
    pub title: String,
    pub sort_title: String,
    pub artist: String,
    pub artists: Vec<String>,
    pub artist_id: String,
    pub artist_ids: Vec<String>,
    pub album: String,
    pub album_id: String,
    pub album_artist: String,
    pub genres: Vec<String>,
    pub track: i32,
    pub disc: i32,
    pub year: i32,
    pub duration: i64,
    pub date_added: i64,
    pub date_modified: i64,
    pub uri: String,
    pub path: String,
    pub file_name: String,
    pub file_size: u64,
    pub mime_type: String,
    pub bitrate: i64,
    pub sample_rate: i32,
    pub isrc: String,
    pub musicbrainz_id: String,
    pub release_type: String,
    pub folder_cover: String,
    pub has_embedded_cover: bool,
    pub cover_hash: String,
    pub own_cover: bool,
    pub lyrics: Option<RawLyrics>,
    pub replay_gain: Option<f32>,
    pub public_cover_url: String,
    pub share_url: String,
}

#[derive(Clone, Debug)]
pub struct Album {
    pub id: String,
    pub title: String,
    pub artist: String,
    pub artist_id: String,
    pub year: i32,
    pub release_type: String,
    pub songs: Vec<Arc<Song>>,
}

#[derive(Clone, Debug)]
pub struct Artist {
    pub id: String,
    pub name: String,
    pub songs: Vec<Arc<Song>>,
    pub albums: Vec<Arc<Album>>,
}

#[derive(Serialize, Deserialize, Clone, Debug)]
struct SourceFile {
    uri: String,
    name: String,
    path: String,
    mime: String,
    size: u64,
    modified: i64,
    added: i64,
    #[serde(default)]
    media_id: String,
    cover: String,
    lyrics: String,
}

#[derive(Serialize, Deserialize, Clone)]
struct CacheEntry {
    modified: i64,
    size: u64,
    data: Metadata,
}

#[derive(Default)]
struct Snapshot {
    songs: Vec<Arc<Song>>,
    albums: Vec<Arc<Album>>,
    artists: Vec<Arc<Artist>>,
    songs_by_id: HashMap<String, Arc<Song>>,
    albums_by_id: HashMap<String, Arc<Album>>,
    artists_by_id: HashMap<String, Arc<Artist>>,
    tracks_json: String,
}

pub struct Library {
    root: PathBuf,
    cover_dir: PathBuf,
    events: Sender<Event>,
    folders: Mutex<Folders>,
    cache: Mutex<HashMap<String, CacheEntry>>,
    snapshot: RwLock<Snapshot>,
    ready: AtomicBool,
    loading: AtomicBool,
    busy: AtomicBool,
    reload_requested: AtomicBool,
    stage: Mutex<&'static str>,
    loaded: AtomicUsize,
    discovered: AtomicUsize,
    last_error: Mutex<String>,
    last_progress_ms: AtomicU64,
    missing_covers: Mutex<HashSet<String>>,
    pending_covers: Mutex<HashSet<String>>,
    pool: covers::Pool,
    stopping: AtomicBool,
    workers: Mutex<Vec<JoinHandle<()>>>,
    watch: Mutex<Option<Sender<WatchMessage>>>,
}

#[cfg(not(target_os = "android"))]
#[derive(Default)]
struct Scan {
    folders: HashSet<PathBuf>,
    files_seen: HashSet<String>,
    files: Vec<SourceFile>,
}

#[cfg_attr(target_os = "android", allow(dead_code))]
enum WatchMessage {
    Rewatch(Vec<PathBuf>),
    Touched,
    Stop,
}

impl Library {
    pub fn new(root: PathBuf, system_music_dir: PathBuf, events: Sender<Event>) -> Arc<Self> {
        let _ = std::fs::create_dir_all(&root);
        let _ = std::fs::remove_dir_all(root.join(format!("covers_{}", covers::COVER_SIZE)));
        let library = Arc::new(Self {
            cover_dir: root.join(format!("covers_{}_r{}", covers::COVER_SIZE, covers::CACHE_REVISION)),
            folders: Mutex::new(Folders::load(root.join("folders.json"), &system_music_dir)),
            cache: Mutex::new(read_json(&root.join("metadata_cache.json")).unwrap_or_default()),
            root,
            events,
            snapshot: RwLock::new(Snapshot {
                tracks_json: "[]".into(),
                ..Snapshot::default()
            }),
            ready: AtomicBool::new(false),
            loading: AtomicBool::new(false),
            busy: AtomicBool::new(false),
            reload_requested: AtomicBool::new(false),
            stage: Mutex::new("idle"),
            loaded: AtomicUsize::new(0),
            discovered: AtomicUsize::new(0),
            last_error: Mutex::new(String::new()),
            last_progress_ms: AtomicU64::new(0),
            missing_covers: Mutex::new(HashSet::new()),
            pending_covers: Mutex::new(HashSet::new()),
            pool: covers::Pool::new(),
            stopping: AtomicBool::new(false),
            workers: Mutex::new(Vec::new()),
            watch: Mutex::new(None),
        });
        library.load_snapshot();
        library.start_watcher();
        library
    }

    pub fn shutdown(&self) {
        self.stopping.store(true, Ordering::SeqCst);
        if let Some(watch) = self.watch.lock().unwrap().take() {
            let _ = watch.send(WatchMessage::Stop);
        }
        self.pool.shutdown();
        for worker in self.workers.lock().unwrap().drain(..) {
            let _ = worker.join();
        }
    }

    fn track(&self, worker: JoinHandle<()>) {
        let mut workers = self.workers.lock().unwrap();
        workers.retain(|worker| !worker.is_finished());
        workers.push(worker);
    }

    #[cfg(target_os = "android")]
    fn start_watcher(self: &Arc<Self>) {}

    #[cfg(not(target_os = "android"))]
    fn start_watcher(self: &Arc<Self>) {
        let (sender, receiver) = channel::<WatchMessage>();
        *self.watch.lock().unwrap() = Some(sender.clone());
        let library = Arc::downgrade(self);
        let worker = std::thread::spawn(move || {
            let touched = sender;
            let Ok(mut watcher) = notify::recommended_watcher(move |event| {
                if let Ok(notify::Event { kind, .. }) = event {
                    if !kind.is_access() {
                        let _ = touched.send(WatchMessage::Touched);
                    }
                }
            }) else {
                return;
            };
            let mut watched: Vec<PathBuf> = Vec::new();
            let mut dirty: Option<Instant> = None;
            loop {
                match receiver.recv_timeout(WATCH_TICK) {
                    Ok(WatchMessage::Stop)
                    | Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => return,
                    Ok(WatchMessage::Touched) => dirty = Some(Instant::now()),
                    Ok(WatchMessage::Rewatch(roots)) => {
                        for root in watched.drain(..) {
                            let _ = notify::Watcher::unwatch(&mut watcher, &root);
                        }
                        for root in &roots {
                            let _ = notify::Watcher::watch(
                                &mut watcher,
                                root,
                                notify::RecursiveMode::Recursive,
                            );
                        }
                        watched = roots;
                    }
                    Err(std::sync::mpsc::RecvTimeoutError::Timeout) => {}
                }
                if dirty.is_some_and(|at| at.elapsed() >= WATCH_DEBOUNCE) {
                    dirty = None;
                    let Some(library) = library.upgrade() else {
                        return;
                    };
                    library.start_loading(false);
                }
            }
        });
        self.track(worker);
        self.rewatch();
    }

    fn rewatch(&self) {
        let folders = self.folders.lock().unwrap();
        let roots = folders.roots();
        drop(folders);
        if let Some(watch) = self.watch.lock().unwrap().as_ref() {
            let _ = watch.send(WatchMessage::Rewatch(roots));
        }
    }

    fn load_snapshot(self: &Arc<Self>) {
        let library = self.clone();
        let worker = std::thread::spawn(move || {
            let Some(sources) = read_json::<Vec<SourceFile>>(&library.root.join("sources.json"))
            else {
                return;
            };
            if sources.is_empty() {
                return;
            }
            let songs: Vec<Song> = {
                let cache = library.cache.lock().unwrap();
                sources
                    .iter()
                    .filter_map(|source| {
                        let entry = cache.get(&source.uri)?;
                        if entry.modified != source.modified || entry.size != source.size {
                            return None;
                        }
                        Some(library.create_song(source, &entry.data))
                    })
                    .collect()
            };
            if library.publish(songs) {
                let _ = library.events.send(Event::LibraryChanged);
            }
        });
        self.track(worker);
    }

    pub fn start_loading(self: &Arc<Self>, clear_cache: bool) {
        if self.stopping.load(Ordering::SeqCst) {
            return;
        }
        if self.busy.swap(true, Ordering::SeqCst) {
            self.reload_requested.store(true, Ordering::SeqCst);
            return;
        }
        let library = self.clone();
        let worker = std::thread::spawn(move || {
            let blocking = clear_cache || !library.ready.load(Ordering::SeqCst);
            let outcome = library.load(clear_cache, blocking);
            library.loading.store(false, Ordering::SeqCst);
            library.busy.store(false, Ordering::SeqCst);
            library.emit_progress(false);
            let _ = library.events.send(Event::LibraryReady {
                success: outcome.0,
                error: outcome.1.clone(),
            });
            if outcome.2 {
                let _ = library.events.send(Event::LibraryChanged);
            }
            if library.reload_requested.swap(false, Ordering::SeqCst) {
                library.start_loading(false);
            }
        });
        self.track(worker);
    }

    fn load(self: &Arc<Self>, clear_cache: bool, blocking: bool) -> (bool, String, bool) {
        if blocking {
            self.loading.store(true, Ordering::SeqCst);
            self.ready.store(false, Ordering::SeqCst);
            *self.stage.lock().unwrap() = "discovering";
            self.loaded.store(0, Ordering::SeqCst);
            self.discovered.store(0, Ordering::SeqCst);
            self.last_error.lock().unwrap().clear();
            self.emit_progress(false);
        }
        if clear_cache {
            self.cache.lock().unwrap().clear();
        }

        let sources = self.discover();
        self.discovered.store(sources.len(), Ordering::SeqCst);
        if blocking {
            *self.stage.lock().unwrap() = "extracting";
        }
        self.emit_progress(false);

        let mut found: Vec<Option<Song>> = vec![None; sources.len()];
        let mut uncached = Vec::new();
        {
            let cache = self.cache.lock().unwrap();
            for (index, source) in sources.iter().enumerate() {
                match cache.get(&source.uri) {
                    Some(entry) if entry.modified == source.modified && entry.size == source.size => {
                        found[index] = Some(self.create_song(source, &entry.data));
                    }
                    _ => uncached.push(index),
                }
            }
        }
        self.loaded
            .store(sources.len() - uncached.len(), Ordering::SeqCst);

        let extracted = self.extract(&sources, &uncached);
        {
            let present: HashSet<&str> = sources.iter().map(|source| source.uri.as_str()).collect();
            let mut cache = self.cache.lock().unwrap();
            cache.retain(|uri, _| present.contains(uri.as_str()));
            for (index, metadata) in &extracted {
                let source = &sources[*index];
                cache.insert(
                    source.uri.clone(),
                    CacheEntry {
                        modified: source.modified,
                        size: source.size,
                        data: metadata.clone(),
                    },
                );
            }
        }
        for (index, metadata) in &extracted {
            found[*index] = Some(self.create_song(&sources[*index], metadata));
        }

        if self.stopping.load(Ordering::SeqCst) {
            return (false, String::new(), false);
        }
        if blocking {
            *self.stage.lock().unwrap() = "building";
        }
        self.emit_progress(false);
        let changed = self.publish(found.into_iter().flatten().collect()) || blocking;
        write_json(&self.root.join("metadata_cache.json"), &*self.cache.lock().unwrap());
        write_json(&self.root.join("sources.json"), &sources);
        (true, String::new(), changed)
    }

    fn extract(&self, sources: &[SourceFile], uncached: &[usize]) -> Vec<(usize, Metadata)> {
        if uncached.is_empty() {
            return Vec::new();
        }
        let size = uncached.len().div_ceil(EXTRACT_THREADS).max(1);
        std::thread::scope(|scope| {
            let handles: Vec<_> = uncached
                .chunks(size)
                .map(|chunk| {
                    scope.spawn(move || {
                        let mut produced = Vec::with_capacity(chunk.len());
                        for index in chunk {
                            if self.stopping.load(Ordering::Relaxed) {
                                break;
                            }
                            if let Some(metadata) = meta::read(&sources[*index].uri, &sources[*index].name) {
                                produced.push((*index, metadata));
                            }
                            self.loaded.fetch_add(1, Ordering::Relaxed);
                            self.emit_progress(true);
                        }
                        produced
                    })
                })
                .collect();
            handles
                .into_iter()
                .filter_map(|handle| handle.join().ok())
                .flatten()
                .collect()
        })
    }

    #[cfg(target_os = "android")]
    fn discover(&self) -> Vec<SourceFile> {
        let folders = self.folders.lock().unwrap();
        let request = json!({
            "music": folders.list(FolderKind::Music),
            "ignored": folders.list(FolderKind::Ignored),
        })
        .to_string();
        drop(folders);
        let answer: Value = serde_json::from_str(&crate::android::discover(&request)).unwrap_or_default();
        let lost: Vec<String> = answer["lost"]
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(|uri| uri.as_str().map(str::to_owned))
            .collect();
        if !lost.is_empty() {
            let mut folders = self.folders.lock().unwrap();
            for uri in &lost {
                folders.remove(FolderKind::Music, uri);
            }
            drop(folders);
            *self.last_error.lock().unwrap() = format!("FOLDER_ACCESS_LOST: {}", lost.join(", "));
            let _ = self.events.send(Event::LibraryChanged);
        }
        serde_json::from_value(answer["files"].clone()).unwrap_or_default()
    }

    #[cfg(not(target_os = "android"))]
    fn discover(&self) -> Vec<SourceFile> {
        let folders = self.folders.lock().unwrap();
        let roots = folders.roots();
        let ignored = folders.ignored_paths();
        drop(folders);
        let mut scan = Scan::default();
        for root in roots {
            self.scan_dir(&root, &ignored, &mut scan);
        }
        scan.files
    }

    #[cfg(not(target_os = "android"))]
    fn scan_dir(&self, dir: &Path, ignored: &[PathBuf], scan: &mut Scan) {
        if self.stopping.load(Ordering::Relaxed) || ignored.iter().any(|path| dir.starts_with(path)) {
            return;
        }
        let real = std::fs::canonicalize(dir).unwrap_or_else(|_| dir.to_path_buf());
        if !scan.folders.insert(real) {
            return;
        }
        let Ok(entries) = std::fs::read_dir(dir) else {
            return;
        };
        let entries: Vec<_> = entries
            .filter_map(Result::ok)
            .filter_map(|entry| {
                let meta = entry.metadata().ok()?;
                Some((entry.file_name().to_string_lossy().into_owned(), entry.path(), meta))
            })
            .collect();
        if entries.iter().any(|(name, ..)| name == ".nomedia") {
            return;
        }

        let cover = entries
            .iter()
            .filter(|(_, _, meta)| meta.is_file())
            .map(|(name, path, _)| (covers::score(name, dir), path))
            .filter(|(score, _)| *score > 0)
            .max_by_key(|(score, _)| *score)
            .map(|(_, path)| path.to_string_lossy().into_owned())
            .unwrap_or_default();
        let lyrics_by_stem = best_lyrics_by_stem(&entries);

        for (name, path, meta) in &entries {
            if name.starts_with('.') {
                continue;
            }
            if meta.is_dir() {
                self.scan_dir(path, ignored, scan);
                continue;
            }
            let extension = extension_of(name);
            if !AUDIO_EXTENSIONS.contains(&extension.as_str()) {
                continue;
            }
            let uri = path.to_string_lossy().into_owned();
            if !scan.files_seen.insert(uri.clone()) {
                continue;
            }
            let lyrics = lyrics_by_stem
                .get(stem_of(name).as_str())
                .map(|(_, path)| path.to_string_lossy().into_owned())
                .unwrap_or_default();
            scan.files.push(SourceFile {
                name: name.clone(),
                path: uri.clone(),
                uri,
                mime: mime_of(&extension).to_owned(),
                size: meta.len(),
                modified: file_time(meta.modified().ok()),
                added: file_time(meta.created().ok().or_else(|| meta.modified().ok())),
                media_id: String::new(),
                cover: cover.clone(),
                lyrics,
            });
            self.discovered.store(scan.files.len(), Ordering::SeqCst);
            self.emit_progress(true);
        }
    }

    fn create_song(&self, source: &SourceFile, metadata: &Metadata) -> Song {
        let title = non_empty(&metadata.title)
            .unwrap_or_else(|| non_empty(&stem_of(&source.name)).unwrap_or(UNKNOWN_TITLE.into()));
        let artists = if metadata.artists.is_empty() {
            vec![UNKNOWN_ARTIST.to_owned()]
        } else {
            metadata.artists.clone()
        };
        let album = non_empty(&metadata.album).unwrap_or_else(|| {
            Path::new(&source.path)
                .parent()
                .and_then(Path::file_name)
                .map(|name| name.to_string_lossy().into_owned())
                .unwrap_or_else(|| UNKNOWN_ALBUM.to_owned())
        });
        let album_artists = if metadata.album_artists.is_empty() {
            artists.clone()
        } else {
            metadata.album_artists.clone()
        };
        let artist_ids: Vec<String> = artists
            .iter()
            .enumerate()
            .map(|(index, artist)| {
                metadata
                    .musicbrainz_artist_ids
                    .get(index)
                    .and_then(|id| non_empty(id))
                    .map(|id| format!("mbr-{id}"))
                    .unwrap_or_else(|| meta::stable_id("artist", artist))
            })
            .collect();
        let album_id = non_empty(&metadata.musicbrainz_album_id)
            .map(|id| format!("mba-{id}"))
            .unwrap_or_else(|| {
                let owner = if metadata.album_artists.is_empty() {
                    album_folder(&source.path)
                } else {
                    album_artists.join(";")
                };
                meta::stable_id("album", &format!("{owner}\0{album}"))
            });
        let song_id = non_empty(&source.media_id)
            .or_else(|| non_empty(&metadata.musicbrainz_track_id).map(|id| format!("mbs-{id}")))
            .unwrap_or_else(|| meta::stable_id("song", &source.uri));
        let lyrics = read_sidecar_lyrics(&source.lyrics).or_else(|| metadata.lyrics.clone());

        Song {
            id: song_id,
            sort_title: non_empty(&metadata.sort_title)
                .unwrap_or_else(|| meta::intelligent_sort_name(&title)),
            title,
            artist: artists.join(", "),
            artist_id: artist_ids
                .first()
                .cloned()
                .unwrap_or_else(|| meta::stable_id("artist", UNKNOWN_ARTIST)),
            artists,
            artist_ids,
            album,
            album_id,
            album_artist: album_artists.join(", "),
            genres: metadata.genres.clone(),
            track: metadata.track,
            disc: if metadata.disc > 0 { metadata.disc } else { folder_disc(&source.path).unwrap_or(1) },
            year: metadata.year,
            duration: metadata.duration,
            date_added: source.added,
            date_modified: source.modified,
            uri: source.uri.clone(),
            path: source.path.clone(),
            file_name: source.name.clone(),
            file_size: source.size,
            mime_type: source.mime.clone(),
            bitrate: metadata.bitrate,
            sample_rate: metadata.sample_rate,
            isrc: metadata.isrc.clone(),
            musicbrainz_id: metadata.musicbrainz_track_id.clone(),
            release_type: non_empty(&metadata.release_type).unwrap_or_else(|| "album".to_owned()),
            folder_cover: source.cover.clone(),
            has_embedded_cover: metadata.has_embedded_cover,
            cover_hash: metadata.cover_hash.clone(),
            lyrics,
            replay_gain: metadata.replay_gain,
            ..Song::default()
        }
    }

    fn publish(&self, mut songs: Vec<Song>) -> bool {
        merge_split_albums(&mut songs);
        drop_mixed_folder_covers(&mut songs);
        mark_own_covers(&mut songs);
        let songs: Vec<Arc<Song>> = songs.into_iter().map(Arc::new).collect();
        let albums = build_albums(&songs);
        let artists = build_artists(&songs, &albums);
        let mut sorted = songs.clone();
        sorted.sort_by_cached_key(|song| song.sort_title.to_lowercase());
        let tracks_json = Value::Array(sorted.iter().map(|song| song_json(song)).collect()).to_string();

        let mut snapshot = self.snapshot.write().unwrap();
        let changed = tracks_json != snapshot.tracks_json;
        snapshot.songs_by_id = songs.iter().map(|song| (song.id.clone(), song.clone())).collect();
        snapshot.albums_by_id = albums
            .iter()
            .map(|album| (album.id.clone(), album.clone()))
            .collect();
        snapshot.artists_by_id = artists
            .iter()
            .map(|artist| (artist.id.clone(), artist.clone()))
            .collect();
        snapshot.songs = sorted;
        snapshot.albums = albums;
        snapshot.artists = artists;
        snapshot.tracks_json = tracks_json;
        drop(snapshot);
        self.missing_covers.lock().unwrap().clear();
        self.ready.store(true, Ordering::SeqCst);
        *self.stage.lock().unwrap() = "ready";
        changed
    }

    fn emit_progress(&self, throttled: bool) {
        if !self.loading.load(Ordering::SeqCst) {
            return;
        }
        let now = now_ms();
        if throttled && now.saturating_sub(self.last_progress_ms.load(Ordering::Relaxed)) < PROGRESS_INTERVAL_MS {
            return;
        }
        self.last_progress_ms.store(now, Ordering::Relaxed);
        let _ = self.events.send(Event::LibraryProgress(self.status_json()));
    }

    pub fn is_ready(&self) -> bool {
        self.ready.load(Ordering::SeqCst)
    }

    pub fn is_loading(&self) -> bool {
        self.loading.load(Ordering::SeqCst)
    }

    pub fn status_json(&self) -> String {
        let loaded = self.loaded.load(Ordering::Relaxed);
        let discovered = self.discovered.load(Ordering::Relaxed);
        json!({
            "ready": self.ready.load(Ordering::SeqCst),
            "loading": self.loading.load(Ordering::SeqCst),
            "stage": *self.stage.lock().unwrap(),
            "loaded": loaded,
            "discovered": discovered,
            "progress": if discovered > 0 { loaded as f64 / discovered as f64 } else { 0.0 },
            "error": *self.last_error.lock().unwrap(),
        })
        .to_string()
    }

    pub fn tracks_json(&self) -> String {
        self.snapshot.read().unwrap().tracks_json.clone()
    }

    pub fn song_json(&self, id: &str) -> String {
        self.snapshot
            .read()
            .unwrap()
            .songs_by_id
            .get(id)
            .map(|song| song_json(song).to_string())
            .unwrap_or_else(|| "{}".to_owned())
    }

    pub fn song(&self, id: &str) -> Option<Arc<Song>> {
        self.snapshot.read().unwrap().songs_by_id.get(id).cloned()
    }

    pub fn songs_by_ids(&self, ids: &[String]) -> Vec<Arc<Song>> {
        let snapshot = self.snapshot.read().unwrap();
        ids.iter()
            .filter_map(|id| snapshot.songs_by_id.get(id).cloned())
            .collect()
    }

    pub fn artist(&self, id: &str) -> Option<Arc<Artist>> {
        self.snapshot.read().unwrap().artists_by_id.get(id).cloned()
    }

    pub fn songs(&self) -> Vec<Arc<Song>> {
        self.snapshot.read().unwrap().songs.clone()
    }

    pub fn raw_lyrics_json(&self, id: &str) -> String {
        let lyrics = self
            .song(id)
            .and_then(|song| song.lyrics.clone())
            .unwrap_or_default();
        json!({
            "text": lyrics.text,
            "format": lyrics.format,
            "source": lyrics.source,
            "song_id": id,
        })
        .to_string()
    }

    pub fn albums_json(&self) -> String {
        let snapshot = self.snapshot.read().unwrap();
        Value::Array(
            snapshot
                .albums
                .iter()
                .map(|album| album_json(album, false))
                .collect(),
        )
        .to_string()
    }

    pub fn album_json(&self, id: &str) -> String {
        self.snapshot
            .read()
            .unwrap()
            .albums_by_id
            .get(id)
            .map(|album| album_json(album, true).to_string())
            .unwrap_or_else(|| "{}".to_owned())
    }

    pub fn album(&self, id: &str) -> Option<Arc<Album>> {
        self.snapshot.read().unwrap().albums_by_id.get(id).cloned()
    }

    pub fn artists_json(&self) -> String {
        let snapshot = self.snapshot.read().unwrap();
        Value::Array(
            snapshot
                .artists
                .iter()
                .map(|artist| artist_json(artist, false))
                .collect(),
        )
        .to_string()
    }

    pub fn artist_json(&self, id: &str) -> String {
        self.snapshot
            .read()
            .unwrap()
            .artists_by_id
            .get(id)
            .map(|artist| artist_json(artist, true).to_string())
            .unwrap_or_else(|| "{}".to_owned())
    }

    pub fn folders_json(&self, kind: FolderKind) -> String {
        serde_json::to_string(self.folders.lock().unwrap().list(kind)).unwrap_or_else(|_| "[]".into())
    }

    pub fn add_folder(self: &Arc<Self>, kind: FolderKind, folder: folders::Folder) -> bool {
        let added = self.folders.lock().unwrap().add(kind, folder);
        if added {
            self.rewatch();
            self.start_loading(false);
        }
        added
    }

    pub fn has_music_folders(&self) -> bool {
        !self.folders.lock().unwrap().list(FolderKind::Music).is_empty()
    }

    #[cfg_attr(not(target_os = "android"), allow(dead_code))]
    pub fn folder_used(&self, uri: &str) -> bool {
        let folders = self.folders.lock().unwrap();
        [FolderKind::Music, FolderKind::Ignored]
            .iter()
            .any(|kind| folders.list(*kind).iter().any(|folder| folder.uri == uri))
    }

    pub fn remove_folder(self: &Arc<Self>, kind: FolderKind, uri: &str) -> bool {
        let removed = self.folders.lock().unwrap().remove(kind, uri);
        if removed {
            self.rewatch();
            self.start_loading(false);
        }
        removed
    }

    pub fn cached_cover(&self, kind: &str, id: &str, thumb: bool) -> String {
        let path = covers::cover_file(&self.cover_dir, kind, id, thumb);
        if covers::is_cached(&path) {
            path.to_string_lossy().into_owned()
        } else {
            String::new()
        }
    }

    pub fn request_cover(self: &Arc<Self>, kind: &str, id: &str, thumb: bool) {
        let cached = self.cached_cover(kind, id, thumb);
        if !cached.is_empty() {
            self.send_cover(kind, id, thumb, cached);
            return;
        }
        let cover = format!("{kind}:{id}");
        if self.missing_covers.lock().unwrap().contains(&cover) {
            self.send_cover(kind, id, thumb, String::new());
            return;
        }
        let key = format!("{cover}:{thumb}");
        if !self.pending_covers.lock().unwrap().insert(key.clone()) {
            return;
        }
        let library = self.clone();
        let (kind, id) = (kind.to_owned(), id.to_owned());
        self.pool.run(move || {
            let path = library.build_cover(&kind, &id, thumb, &cover);
            library.pending_covers.lock().unwrap().remove(&key);
            library.send_cover(&kind, &id, thumb, path);
        });
    }

    fn build_cover(&self, kind: &str, id: &str, thumb: bool, cover: &str) -> String {
        let full = covers::cover_file(&self.cover_dir, kind, id, false);
        if !covers::is_cached(&full) {
            let reference = if kind == KIND_SONG {
                self.song(id)
            } else {
                self.album(id).and_then(|album| album.songs.first().cloned())
            };
            match reference.as_deref().and_then(|song| extract_cover(song, &full)) {
                Some(bytes) => covers::write_atomically(&full, &bytes),
                None => {
                    self.missing_covers.lock().unwrap().insert(cover.to_owned());
                }
            }
        }
        if !covers::is_cached(&full) {
            return String::new();
        }
        let target = covers::cover_file(&self.cover_dir, kind, id, thumb);
        if thumb {
            if let Some(bytes) = std::fs::read(&full)
                .ok()
                .and_then(|bytes| covers::to_scaled_jpeg(&bytes, covers::THUMB_SIZE))
            {
                covers::write_atomically(&target, &bytes);
            }
        }
        if covers::is_cached(&target) {
            target.to_string_lossy().into_owned()
        } else {
            String::new()
        }
    }

    fn send_cover(&self, kind: &str, id: &str, thumb: bool, path: String) {
        let _ = self.events.send(Event::CoverReady {
            kind: kind.to_owned(),
            id: id.to_owned(),
            thumb,
            path,
        });
    }
}

#[cfg(not(target_os = "android"))]
fn best_lyrics_by_stem(entries: &[(String, PathBuf, std::fs::Metadata)]) -> HashMap<String, (u8, PathBuf)> {
    let mut best: HashMap<String, (u8, PathBuf)> = HashMap::new();
    for (name, path, meta) in entries {
        if !meta.is_file() || meta.len() > MAX_LYRICS_SIZE {
            continue;
        }
        let rank = match extension_of(name).as_str() {
            "ttml" => 3,
            "lrc" => 2,
            "txt" => 1,
            _ => continue,
        };
        let stem = stem_of(name);
        let better = best.get(&stem).is_none_or(|(current, _)| rank >= *current);
        if better {
            best.insert(stem, (rank, path.clone()));
        }
    }
    best
}

#[cfg(any(target_os = "macos", target_os = "ios"))]
pub fn original_cover(song: &Song) -> Option<Vec<u8>> {
    cover_sources(song).into_iter().find_map(|bytes| covers::to_scaled_jpeg(&bytes, covers::ORIGINAL_SIZE))
}

fn extract_cover(song: &Song, full: &std::path::Path) -> Option<Vec<u8>> {
    cover_sources(song).into_iter().find_map(|bytes| cover_jpeg(&bytes, full))
}

fn cover_sources(song: &Song) -> Vec<Vec<u8>> {
    let mut sources = Vec::new();
    if song.own_cover {
        sources.extend(meta::artwork(&song.uri, &song.file_name));
    }
    if !song.folder_cover.is_empty() {
        sources.extend(crate::storage::read(&song.folder_cover).ok());
    }
    if song.has_embedded_cover && !song.own_cover {
        sources.extend(meta::artwork(&song.uri, &song.file_name));
    }
    sources
}

fn cover_jpeg(bytes: &[u8], full: &std::path::Path) -> Option<Vec<u8>> {
    let moving = full.with_extension("anim");
    if !crate::animation::is_animated(bytes) {
        let _ = std::fs::remove_file(&moving);
        return covers::to_scaled_jpeg(bytes, covers::COVER_SIZE);
    }
    covers::write_atomically(&moving, bytes);
    let poster = crate::animation::poster(&moving).and_then(|image| covers::scaled_jpeg(image, covers::COVER_SIZE));
    if poster.is_none() {
        let _ = std::fs::remove_file(&moving);
    }
    poster
}

fn folder_disc(path: &str) -> Option<i32> {
    let name = Path::new(path).parent()?.file_name()?.to_string_lossy().to_lowercase();
    let rest = ["cd", "disc", "disk"]
        .iter()
        .find_map(|prefix| name.strip_prefix(prefix))?
        .trim_start_matches([' ', '_', '-']);
    if rest.is_empty() || !rest.chars().all(|c| c.is_ascii_digit()) {
        return None;
    }
    rest.parse().ok()
}

fn album_folder(path: &str) -> String {
    let parent = Path::new(path).parent();
    let folder = if folder_disc(path).is_some() { parent.and_then(Path::parent) } else { parent };
    folder.map(|folder| folder.to_string_lossy().into_owned()).unwrap_or_default()
}

fn merge_split_albums(songs: &mut [Song]) {
    let folders: Vec<String> = songs.iter().map(|song| album_folder(&song.path)).collect();
    let canonical: HashMap<String, String> = {
        let mut titles: HashMap<&str, HashSet<&str>> = HashMap::new();
        for (song, folder) in songs.iter().zip(&folders) {
            titles.entry(folder.as_str()).or_default().insert(song.album.as_str());
        }
        let mut counts: HashMap<&str, HashMap<&str, usize>> = HashMap::new();
        for (song, folder) in songs.iter().zip(&folders) {
            if !folder.is_empty() && song.album != UNKNOWN_ALBUM && titles[folder.as_str()].len() == 1 {
                *counts.entry(folder.as_str()).or_default().entry(song.album_id.as_str()).or_default() += 1;
            }
        }
        counts
            .into_iter()
            .filter(|(_, ids)| ids.len() > 1)
            .filter_map(|(folder, ids)| {
                ids.into_iter()
                    .max_by(|a, b| a.1.cmp(&b.1).then(b.0.cmp(a.0)))
                    .map(|(id, _)| (folder.to_owned(), id.to_owned()))
            })
            .collect()
    };
    for (song, folder) in songs.iter_mut().zip(&folders) {
        if let Some(id) = canonical.get(folder) {
            song.album_id = id.clone();
        }
    }
    let releases: HashMap<String, String> = {
        let mut albums: HashMap<&str, (String, i32, usize)> = HashMap::new();
        for song in songs.iter().filter(|song| song.album != UNKNOWN_ALBUM) {
            let entry = albums.entry(song.album_id.as_str()).or_insert((song.album.to_lowercase(), 0, 0));
            entry.1 = entry.1.max(song.year);
            entry.2 += 1;
        }
        let mut shared: HashMap<(String, i32), Vec<(&str, usize)>> = HashMap::new();
        for (id, (title, year, count)) in albums {
            if year > 0 {
                shared.entry((title, year)).or_default().push((id, count));
            }
        }
        shared
            .into_values()
            .filter(|ids| ids.len() > 1)
            .flat_map(|ids| {
                let main = ids.iter().max_by(|a, b| a.1.cmp(&b.1).then(b.0.cmp(a.0))).unwrap().0.to_owned();
                ids.into_iter().map(move |(id, _)| (id.to_owned(), main.clone()))
            })
            .collect()
    };
    for song in songs.iter_mut() {
        if let Some(id) = releases.get(&song.album_id) {
            song.album_id = id.clone();
        }
    }
}

fn drop_mixed_folder_covers(songs: &mut [Song]) {
    let mut albums: HashMap<String, HashSet<String>> = HashMap::new();
    for song in songs.iter().filter(|song| !song.folder_cover.is_empty()) {
        albums.entry(song.folder_cover.clone()).or_default().insert(song.album_id.clone());
    }
    for song in songs.iter_mut() {
        if albums.get(&song.folder_cover).is_some_and(|ids| ids.len() > 1) {
            song.folder_cover.clear();
        }
    }
}

fn mark_own_covers(songs: &mut [Song]) {
    let mut first: HashMap<String, (i32, i32, String, String)> = HashMap::new();
    for song in songs.iter() {
        let key = (song.disc, song.track, song.sort_title.to_lowercase(), song.cover_hash.clone());
        first
            .entry(song.album_id.clone())
            .and_modify(|current| {
                if key < *current {
                    *current = key.clone();
                }
            })
            .or_insert(key);
    }
    for song in songs.iter_mut() {
        song.own_cover = !song.cover_hash.is_empty()
            && first.get(&song.album_id).is_some_and(|reference| reference.3 != song.cover_hash);
    }
}

fn build_albums(songs: &[Arc<Song>]) -> Vec<Arc<Album>> {
    let mut grouped: Vec<(String, Vec<Arc<Song>>)> = Vec::new();
    let mut index_of: HashMap<&str, usize> = HashMap::new();
    for song in songs {
        match index_of.get(song.album_id.as_str()) {
            Some(index) => grouped[*index].1.push(song.clone()),
            None => {
                index_of.insert(&song.album_id, grouped.len());
                grouped.push((song.album_id.clone(), vec![song.clone()]));
            }
        }
    }
    let mut albums: Vec<Arc<Album>> = grouped
        .into_iter()
        .map(|(id, mut album_songs)| {
            album_songs.sort_by_cached_key(|song| {
                (song.disc, song.track, song.sort_title.to_lowercase())
            });
            let reference = album_songs[0].clone();
            let shared = album_songs.iter().all(|song| song.album_artist == reference.album_artist);
            Arc::new(Album {
                id,
                title: reference.album.clone(),
                artist: if shared { reference.album_artist.clone() } else { VARIOUS_ARTISTS.to_owned() },
                artist_id: if shared { reference.artist_id.clone() } else { String::new() },
                year: album_songs.iter().map(|song| song.year).max().unwrap_or(0),
                release_type: reference.release_type.clone(),
                songs: album_songs,
            })
        })
        .collect();
    albums.sort_by_cached_key(|album| meta::intelligent_sort_name(&album.title).to_lowercase());
    albums
}

fn build_artists(songs: &[Arc<Song>], albums: &[Arc<Album>]) -> Vec<Arc<Artist>> {
    let mut order: Vec<String> = Vec::new();
    let mut songs_by_artist: HashMap<String, Vec<Arc<Song>>> = HashMap::new();
    let mut names: HashMap<String, String> = HashMap::new();
    for song in songs {
        for (index, id) in song.artist_ids.iter().enumerate() {
            let entry = songs_by_artist.entry(id.clone()).or_insert_with(|| {
                order.push(id.clone());
                Vec::new()
            });
            entry.push(song.clone());
            names.insert(
                id.clone(),
                song.artists.get(index).cloned().unwrap_or_else(|| song.artist.clone()),
            );
        }
    }
    let mut albums_by_song: HashMap<&str, Vec<Arc<Album>>> = HashMap::new();
    for album in albums {
        for song in &album.songs {
            albums_by_song
                .entry(song.id.as_str())
                .or_default()
                .push(album.clone());
        }
    }
    let mut artists: Vec<Arc<Artist>> = order
        .into_iter()
        .map(|id| {
            let artist_songs = songs_by_artist.remove(&id).unwrap_or_default();
            let mut seen_songs = HashSet::new();
            let unique_songs: Vec<Arc<Song>> = artist_songs
                .iter()
                .filter(|song| seen_songs.insert(song.id.clone()))
                .cloned()
                .collect();
            let mut seen_albums = HashSet::new();
            let mut artist_albums: Vec<Arc<Album>> = artist_songs
                .iter()
                .filter_map(|song| albums_by_song.get(song.id.as_str()))
                .flatten()
                .filter(|album| seen_albums.insert(album.id.clone()))
                .cloned()
                .collect();
            artist_albums
                .sort_by_cached_key(|album| (-album.year, album.title.to_lowercase()));
            Arc::new(Artist {
                name: names.get(&id).cloned().unwrap_or_else(|| UNKNOWN_ARTIST.to_owned()),
                id,
                songs: unique_songs,
                albums: artist_albums,
            })
        })
        .collect();
    artists.sort_by_cached_key(|artist| meta::intelligent_sort_name(&artist.name).to_lowercase());
    artists
}

pub fn song_json(song: &Song) -> Value {
    json!({
        "id": song.id,
        "title": song.title,
        "sort_title": song.sort_title,
        "artist": song.artist,
        "artists": song.artists,
        "artist_id": song.artist_id,
        "artist_ids": song.artist_ids,
        "album": song.album,
        "album_id": song.album_id,
        "album_artist": song.album_artist,
        "genres": song.genres,
        "track_number": song.track,
        "disc_number": song.disc,
        "year": song.year,
        "duration": song.duration,
        "date_added": song.date_added,
        "date_modified": song.date_modified,
        "uri": song.uri,
        "path": song.path,
        "file_name": song.file_name,
        "file_size": song.file_size,
        "mime_type": song.mime_type,
        "bitrate": song.bitrate,
        "sample_rate": song.sample_rate,
        "isrc": song.isrc,
        "musicbrainz_id": song.musicbrainz_id,
        "release_type": song.release_type,
        "has_lyrics": song.lyrics.is_some(),
        "own_cover": song.own_cover,
    })
}

fn album_json(album: &Album, include_songs: bool) -> Value {
    let mut value = json!({
        "id": album.id,
        "title": album.title,
        "artist": album.artist,
        "artist_id": album.artist_id,
        "year": album.year,
        "release_type": album.release_type,
        "song_count": album.songs.len(),
        "duration": album.songs.iter().map(|song| song.duration).sum::<i64>(),
        "date_added": album.songs.iter().map(|song| song.date_added).max().unwrap_or(0),
    });
    if include_songs {
        value["tracks"] = Value::Array(album.songs.iter().map(|song| song_json(song)).collect());
    }
    value
}

fn artist_json(artist: &Artist, include_content: bool) -> Value {
    let mut value = json!({
        "id": artist.id,
        "name": artist.name,
        "album_count": artist.albums.len(),
        "song_count": artist.songs.len(),
        "duration": artist.songs.iter().map(|song| song.duration).sum::<i64>(),
        "cover_album_id": artist.albums.first().map(|album| album.id.clone()).unwrap_or_default(),
    });
    if include_content {
        value["albums"] = Value::Array(
            artist
                .albums
                .iter()
                .map(|album| album_json(album, false))
                .collect(),
        );
        value["tracks"] = Value::Array(artist.songs.iter().map(|song| song_json(song)).collect());
    }
    value
}

fn read_sidecar_lyrics(path: &str) -> Option<RawLyrics> {
    if path.is_empty() {
        return None;
    }
    let bytes = crate::storage::read_limited(path, MAX_LYRICS_SIZE).ok()?;
    let text = decode_text(&bytes);
    if text.trim().is_empty() {
        return None;
    }
    let format = crate::storage::extension(path);
    let format = if format.is_empty() { "txt".to_owned() } else { format };
    Some(RawLyrics {
        source: format!("file_{format}"),
        format,
        text,
    })
}

fn decode_text(bytes: &[u8]) -> String {
    match bytes {
        [0xef, 0xbb, 0xbf, rest @ ..] => String::from_utf8_lossy(rest).into_owned(),
        [0xff, 0xfe, rest @ ..] => decode_utf16(rest, u16::from_le_bytes),
        [0xfe, 0xff, rest @ ..] => decode_utf16(rest, u16::from_be_bytes),
        _ => String::from_utf8_lossy(bytes).into_owned(),
    }
}

fn decode_utf16(bytes: &[u8], to_unit: fn([u8; 2]) -> u16) -> String {
    let units: Vec<u16> = bytes
        .chunks_exact(2)
        .map(|pair| to_unit([pair[0], pair[1]]))
        .collect();
    String::from_utf16_lossy(&units)
}

fn extension_of(name: &str) -> String {
    name.rsplit_once('.')
        .map(|(_, extension)| extension.to_lowercase())
        .unwrap_or_default()
}

fn stem_of(name: &str) -> String {
    name.rsplit_once('.')
        .map(|(stem, _)| stem.to_owned())
        .unwrap_or_else(|| name.to_owned())
}

fn mime_of(extension: &str) -> &'static str {
    match extension {
        "mp3" => "audio/mpeg",
        "m4a" | "mp4" => "audio/mp4",
        "aac" => "audio/aac",
        "flac" => "audio/flac",
        "ogg" | "oga" => "audio/ogg",
        "opus" => "audio/opus",
        "wav" | "wave" => "audio/wav",
        "aif" | "aiff" => "audio/aiff",
        "wma" => "audio/x-ms-wma",
        _ => "audio/*",
    }
}

fn non_empty(value: &str) -> Option<String> {
    Some(value.trim())
        .filter(|text| !text.is_empty())
        .map(str::to_owned)
}

fn file_time(time: Option<SystemTime>) -> i64 {
    time.and_then(|time| time.duration_since(UNIX_EPOCH).ok())
        .map(|elapsed| elapsed.as_millis() as i64)
        .unwrap_or(0)
}

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|elapsed| elapsed.as_millis() as u64)
        .unwrap_or(0)
}

fn read_json<T: serde::de::DeserializeOwned>(path: &Path) -> Option<T> {
    serde_json::from_str(&std::fs::read_to_string(path).ok()?).ok()
}

fn write_json<T: Serialize>(path: &Path, value: &T) {
    if let Ok(raw) = serde_json::to_vec(value) {
        let _ = crate::storage::write_atomically(path, &raw);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn song(id: &str, album_id: &str, track: i32, hash: &str, album_artist: &str) -> Song {
        Song {
            id: id.into(),
            album_id: album_id.into(),
            album: "Hits".into(),
            album_artist: album_artist.into(),
            track,
            cover_hash: hash.into(),
            ..Song::default()
        }
    }

    #[test]
    fn mixed_folders_keep_their_own_covers() {
        let mut songs = vec![
            Song { folder_cover: "/m/Singles/faker cover.jpg".into(), ..song("a", "x", 1, "", "A") },
            Song { folder_cover: "/m/Singles/faker cover.jpg".into(), ..song("b", "y", 1, "", "B") },
            Song { folder_cover: "/m/Hits/cover.jpg".into(), ..song("c", "z", 1, "", "C") },
            Song { folder_cover: "/m/Hits/cover.jpg".into(), ..song("d", "z", 2, "", "C") },
        ];
        drop_mixed_folder_covers(&mut songs);
        let covers: Vec<&str> = songs.iter().map(|song| song.folder_cover.as_str()).collect();
        assert_eq!(covers, ["", "", "/m/Hits/cover.jpg", "/m/Hits/cover.jpg"]);
    }

    #[test]
    fn groups_and_covers() {
        assert_eq!(album_folder("/m/Hits/CD 2/a.flac"), "/m/Hits");
        assert_eq!(album_folder("/m/Hits/a.flac"), "/m/Hits");
        assert_eq!(album_folder("/m/CDs/a.flac"), "/m/CDs");
        assert_eq!(folder_disc("/m/Hits/Disc 2/a.flac"), Some(2));
        assert_eq!(folder_disc("/m/Hits/CD1/a.flac"), Some(1));
        assert_eq!(folder_disc("/m/Hits/a.flac"), None);
        assert_eq!(folder_disc("/m/Discography/a.flac"), None);
        let mut songs = vec![
            song("b", "x", 2, "two", "B"),
            song("a", "x", 1, "one", "A"),
            song("c", "x", 3, "one", "C"),
            song("d", "x", 4, "", "D"),
        ];
        mark_own_covers(&mut songs);
        let own: Vec<bool> = songs.iter().map(|song| song.own_cover).collect();
        assert_eq!(own, [true, false, false, false]);
        let albums = build_albums(&songs.into_iter().map(Arc::new).collect::<Vec<_>>());
        assert_eq!(albums.len(), 1);
        assert_eq!(albums[0].artist, VARIOUS_ARTISTS);
    }

    #[cfg(not(target_os = "android"))]
    #[test]
    fn sidecar_lyrics_prefer_ttml_then_lrc_then_txt() {
        let folder = std::env::temp_dir().join(format!("nari-lyrics-{}", std::process::id()));
        std::fs::create_dir_all(&folder).unwrap();
        for name in ["a.flac", "a.txt", "a.lrc", "b.txt", "b.ttml", "c.jpg"] {
            std::fs::write(folder.join(name), b"x").unwrap();
        }
        let entries: Vec<_> = std::fs::read_dir(&folder)
            .unwrap()
            .filter_map(Result::ok)
            .map(|entry| (entry.file_name().to_string_lossy().into_owned(), entry.path(), entry.metadata().unwrap()))
            .collect();
        let best = best_lyrics_by_stem(&entries);
        let file_of = |stem: &str| best.get(stem).map(|(_, path)| path.file_name().unwrap().to_string_lossy().into_owned());
        assert_eq!(file_of("a").as_deref(), Some("a.lrc"));
        assert_eq!(file_of("b").as_deref(), Some("b.ttml"));
        assert_eq!(file_of("c"), None);
        std::fs::remove_dir_all(folder).unwrap();
    }

    #[test]
    fn merges_split_albums() {
        let located = |id: &str, album_id: &str, path: &str, album: &str, artist: &str| Song {
            path: path.into(),
            album: album.into(),
            ..song(id, album_id, 1, "", artist)
        };
        let mut songs = vec![
            located("a", "mba-1", "/m/Thriller/1.flac", "Thriller", "Michael Jackson"),
            located("b", "mba-2", "/m/Thriller/2.flac", "Thriller", "Michael Jackson"),
            located("c", "mba-1", "/m/Thriller/CD 2/3.flac", "Thriller", "Michael Jackson"),
            located("d", "x", "/m/Mix/1.flac", "Mix", "A"),
            located("e", "y", "/m/Mix/2.flac", "Mix", "B"),
            located("f", "p", "/m/Flat/1.flac", "Greatest Hits", "A"),
            located("g", "q", "/m/Flat/2.flac", "Greatest Hits", "B"),
            located("h", "r", "/m/Flat/3.flac", "Other", "C"),
            located("i", "s", "/m/Loose/1.flac", UNKNOWN_ALBUM, "A"),
            located("j", "t", "/m/Loose/2.flac", UNKNOWN_ALBUM, "B"),
        ];
        merge_split_albums(&mut songs);
        let ids: Vec<&str> = songs.iter().map(|song| song.album_id.as_str()).collect();
        assert_eq!(ids, ["mba-1", "mba-1", "mba-1", "x", "x", "p", "q", "r", "s", "t"]);
        let dated = |id: &str, album_id: &str, path: &str, album: &str, artist: &str, year: i32| Song {
            year,
            ..located(id, album_id, path, album, artist)
        };
        songs = vec![
            dated("a", "k", "/m/Kai/OST/1.flac", "OST", "Kai", 2025),
            dated("b", "k", "/m/Kai/OST/2.flac", "OST", "Kai", 2025),
            dated("c", "z", "/m/Zardonic/OST/3.flac", "OST", "Zardonic", 2025),
            dated("d", "g1", "/m/A/Greatest Hits/1.flac", "Greatest Hits", "A", 1999),
            dated("e", "g2", "/m/B/Greatest Hits/1.flac", "Greatest Hits", "B", 2004),
            dated("f", "n1", "/m/A/Untitled/1.flac", "Untitled", "A", 0),
            dated("g", "n2", "/m/B/Untitled/1.flac", "Untitled", "B", 0),
        ];
        merge_split_albums(&mut songs);
        let ids: Vec<&str> = songs.iter().map(|song| song.album_id.as_str()).collect();
        assert_eq!(ids, ["k", "k", "k", "g1", "g2", "n1", "n2"]);
        let albums = build_albums(&songs.into_iter().map(Arc::new).collect::<Vec<_>>());
        let ost = albums.iter().find(|album| album.title == "OST").unwrap();
        assert_eq!(ost.artist, VARIOUS_ARTISTS);
        assert_eq!(ost.songs.len(), 3);
    }
}
