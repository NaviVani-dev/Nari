use godot::classes::os::SystemDir;
use godot::classes::{Node, Object, Os, ProjectSettings};
use godot::prelude::*;
use serde_json::json;
use std::path::PathBuf;
use std::sync::mpsc::Sender;
use std::sync::{Arc, Mutex, MutexGuard};

use crate::events::{Bridge, Bus, Event};
use crate::library::folders::{Folder, FolderKind};
use crate::library::Library;
use crate::player::Player;
use crate::playlists::Playlists;
use crate::soundboard::Soundboard;
use crate::mpris::{Media, Mpris};
use crate::tray::Tray;

const PLAYLIST_IMAGE_SIZE: u32 = 512;
const PENDING_IMAGE: &str = "playlist_image_pending.jpg";
const PENDING_PLUGIN: &str = "plugin_pending.zip";
const TEXT_LIMIT: u64 = 4 * 1024 * 1024;
const EXTRACT_LIMIT: u64 = 1024 * 1024 * 1024;
const SOUNDFONTS: &str = "soundfonts";

#[derive(GodotClass)]
#[class(base = Object)]
pub struct MusicService {
    base: Base<Object>,
    bus: Bus,
    root: PathBuf,
    library: Arc<Library>,
    playlists: Arc<Playlists>,
    player: Arc<Mutex<Player>>,
    soundboard: Soundboard,
    tray: Option<Tray>,
    tray_state: (String, bool, String),
    mpris: Option<Mpris>,
    cast: crate::cast::Cast,
    media: Media,
    started: bool,
    now_playing: bool,
    resume_after_recording: bool,
}

impl UserSingleton for MusicService {}

#[godot_api]
impl IObject for MusicService {
    fn init(base: Base<Object>) -> Self {
        let bus = Bus::new();
        #[cfg(target_os = "android")]
        crate::android::attach(bus.sender());
        #[cfg(target_os = "ios")]
        crate::ios::start_audio_session();
        let root = PathBuf::from(ProjectSettings::singleton().globalize_path("user://").to_string());
        #[cfg(not(target_os = "ios"))]
        let music = PathBuf::from(Os::singleton().get_system_dir(SystemDir::MUSIC).to_string());
        #[cfg(target_os = "ios")]
        let music = PathBuf::new();
        crate::vault::init(root.clone());
        crate::history::init(root.clone());
        crate::analysis::init(root.clone());
        let library = Library::new(root.join("library"), music, bus.sender());
        let playlists = Arc::new(Playlists::new(&root));
        crate::scrobble::start(root.clone(), bus.sender());
        crate::discord::start();
        let player = Arc::new(Mutex::new(Player::new(library.clone(), playlists.clone(), bus.sender())));
        #[cfg(target_os = "android")]
        crate::android::drive(Arc::downgrade(&player));
        let mpris = Mpris::new(Arc::downgrade(&player), bus.sender());
        let cast = crate::cast::Cast::new(Arc::downgrade(&player), bus.sender());
        Self {
            base,
            player,
            soundboard: Soundboard::new(root.join("soundboard"), bus.sender()),
            tray: Tray::new(bus.sender()),
            tray_state: (String::new(), false, String::new()),
            mpris,
            cast,
            media: Media::default(),
            started: false,
            now_playing: false,
            resume_after_recording: false,
            root,
            library,
            playlists,
            bus,
        }
    }
}

#[godot_api]
impl MusicService {
    #[signal]
    fn playback_changed(state: GString);
    #[signal]
    fn cover_ready(kind: GString, id: GString, thumb: bool, path: GString);
    #[signal]
    fn library_load_progress(status: GString);
    #[signal]
    fn library_ready(success: bool, error: GString);
    #[signal]
    fn music_folder_selected(kind: GString, success: bool, uri: GString);
    #[signal]
    fn music_effect_changed(state: GString);
    #[signal]
    fn library_changed();
    #[signal]
    fn soundboard_changed();
    #[signal]
    fn soundboard_captured(success: bool);
    #[signal]
    fn playlist_image_picked(path: GString);
    #[signal]
    fn plugin_picked(path: GString);
    #[signal]
    fn theme_picked(path: GString);
    #[signal]
    fn soundfont_picked(path: GString);
    #[signal]
    fn text_picked(text: GString);
    #[signal]
    fn scrobble_auth_url(service: GString, url: GString);
    #[signal]
    fn scrobble_account_changed(service: GString, error: GString);
    #[signal]
    fn tray_command(command: GString);
    #[signal]
    fn now_playing_requested();
    #[signal]
    fn link_opened(url: GString);
    #[signal]
    fn song_played(song_json: GString);
    #[signal]
    fn job_done(id: i64, result_json: GString);
    #[signal]
    fn cast_devices_changed(devices_json: GString);
    #[signal]
    fn cast_state_changed(state_json: GString);

    fn shutdown(&mut self) {
        if let Some(tray) = self.tray.take() {
            tray.shutdown();
        }
        self.mpris = None;
        self.cast.disconnect();
        self.soundboard.shutdown();
        self.player().shutdown();
        self.library.shutdown();
        let signals: Vec<StringName> = self
            .base()
            .get_signal_list()
            .iter_shared()
            .map(|signal| StringName::from(&signal.at("name").to::<GString>()))
            .collect();
        for signal in signals {
            let connections = self.base().get_signal_connection_list(&signal);
            for connection in connections.iter_shared() {
                let callable = connection.at("callable").to::<Callable>();
                self.base_mut().disconnect(&signal, &callable);
            }
        }
    }

    fn pump(&mut self) {
        for event in self.bus.drain() {
            match event {
                Event::PlaybackChanged(state) => {
                    self.signals().playback_changed().emit(&state)
                }
                Event::CoverReady {
                    kind,
                    id,
                    thumb,
                    path,
                } => self
                    .signals()
                    .cover_ready()
                    .emit(&kind, &id, thumb, &path),
                Event::LibraryProgress(status) => {
                    self.signals().library_load_progress().emit(&status)
                }
                Event::LibraryReady { success, error } => {
                    self.signals().library_ready().emit(success, &error)
                }
                Event::FolderSelected {
                    kind,
                    success,
                    uri,
                } => self
                    .signals()
                    .music_folder_selected()
                    .emit(&kind, success, &uri),
                Event::EffectChanged(state) => {
                    self.signals().music_effect_changed().emit(&state)
                }
                Event::LibraryChanged => self.signals().library_changed().emit(),
                Event::SoundboardChanged => self.signals().soundboard_changed().emit(),
                Event::SoundboardCaptured(success) => {
                    self.signals().soundboard_captured().emit(success)
                }
                Event::PlaylistImagePicked(path) => {
                    self.signals().playlist_image_picked().emit(&path)
                }
                Event::PluginPicked(path) => self.signals().plugin_picked().emit(&path),
                Event::ThemePicked(path) => self.signals().theme_picked().emit(&path),
                Event::SoundFontPicked(path) => self.signals().soundfont_picked().emit(&path),
                Event::TextPicked(text) => self.signals().text_picked().emit(&text),
                Event::ScrobbleAuthUrl { service, url } => {
                    self.signals().scrobble_auth_url().emit(&service, &url)
                }
                Event::ScrobbleAccount { service, error } => {
                    self.signals().scrobble_account_changed().emit(&service, &error)
                }
                Event::TrayCommand(command) => self.signals().tray_command().emit(&command),
                Event::Link(url) => self.signals().link_opened().emit(&url),
                Event::Played(song) => self.signals().song_played().emit(&song),
                Event::Job(id, result) => self.signals().job_done().emit(id, &result),
                Event::CastDevices(devices) => self.signals().cast_devices_changed().emit(&devices),
                Event::CastState(state) => self.signals().cast_state_changed().emit(&state),
                Event::Bridge(bridge) => self.bridge(bridge),
            }
        }
    }

    #[allow(dead_code)]
    fn events(&self) -> Sender<Event> {
        self.bus.sender()
    }

    #[func(rename = hasNotificationPermission)]
    fn has_notification_permission(&self) -> bool {
        has_permission("notification")
    }

    #[func(rename = requestNotificationPermission)]
    fn request_notification_permission(&self) {
        request_permission("notification");
    }

    #[func(rename = hasRecordPermission)]
    fn has_record_permission(&self) -> bool {
        has_permission("record")
    }

    #[func(rename = requestRecordPermission)]
    fn request_record_permission(&self) {
        request_permission("record");
    }

    #[func(rename = takeNowPlayingRequest)]
    fn take_now_playing_request(&mut self) -> bool {
        std::mem::take(&mut self.now_playing)
    }

    fn start_library(&mut self) {
        #[cfg(target_os = "android")]
        if !crate::android::ready() {
            return;
        }
        self.started = true;
        if self.library.has_music_folders() {
            self.library.start_loading(false);
        }
    }

    fn tick(&mut self) {
        if !self.started {
            self.start_library();
        }
        let (state, media) = {
            let mut player = self.player();
            player.tick();
            (player.tray_state(), player.media())
        };
        self.cast.reap();
        if let Some(captured) = self.soundboard.tick() {
            if std::mem::take(&mut self.resume_after_recording) {
                self.player().resume();
            }
            self.signals().soundboard_captured().emit(captured);
        }
        if state != self.tray_state {
            self.tray_state = state.clone();
            if let Some(tray) = self.tray.as_ref() {
                tray.set_state(state.0, state.1, state.2);
            }
        }
        if media != self.media {
            self.media = media.clone();
            if let Some(mpris) = self.mpris.as_ref() {
                mpris.update(media);
            }
        }
    }

    #[func(rename = getBatteryLevel)]
    fn get_battery_level(&self) -> i32 {
        crate::device::battery().level
    }

    #[func(rename = isBatteryCharging)]
    fn is_battery_charging(&self) -> bool {
        crate::device::battery().charging
    }

    #[func(rename = getScrobbleAccountsJson)]
    fn get_scrobble_accounts_json(&self) -> GString {
        serde_json::Value::Object(crate::scrobble::accounts()).to_string().as_str().into()
    }

    #[func(rename = scrobbleConnect)]
    fn scrobble_connect(&self, service: GString) {
        crate::scrobble::connect(&service.to_string());
    }

    #[func(rename = scrobbleCancel)]
    fn scrobble_cancel(&self, service: GString) {
        crate::scrobble::cancel(&service.to_string());
    }

    #[func(rename = scrobbleSetToken)]
    fn scrobble_set_token(&self, token: GString) {
        crate::scrobble::set_token(&token.to_string());
    }

    #[func(rename = scrobbleDisconnect)]
    fn scrobble_disconnect(&self, service: GString) {
        crate::scrobble::disconnect(&service.to_string());
    }

    #[func(rename = getOutputDeviceJson)]
    fn get_output_device_json(&self) -> GString {
        let output = crate::device::output();
        json!({ "kind": output.kind, "name": output.name })
            .to_string()
            .as_str()
            .into()
    }

    #[func(rename = castScan)]
    fn cast_scan(&mut self, enabled: bool) {
        self.cast.scan(enabled);
    }

    #[func(rename = getCastDevicesJson)]
    fn get_cast_devices_json(&self) -> GString {
        self.cast.devices_json().as_str().into()
    }

    #[func(rename = castConnect)]
    fn cast_connect(&mut self, id: GString) -> bool {
        self.cast.connect(&id.to_string())
    }

    #[func(rename = castDisconnect)]
    fn cast_disconnect(&mut self) {
        self.cast.disconnect();
    }

    #[func(rename = getCastStateJson)]
    fn get_cast_state_json(&self) -> GString {
        self.cast.state_json().as_str().into()
    }

    #[func(rename = getNetworkStateJson)]
    fn get_network_state_json(&self) -> GString {
        let network = crate::device::network();
        json!({ "connection": network.connection, "level": network.level })
            .to_string()
            .as_str()
            .into()
    }

    #[func(rename = refreshLibrary)]
    fn refresh_library(&mut self) {
        self.library.start_loading(false);
    }

    #[func(rename = rescanMusicLibrary)]
    fn rescan_music_library(&mut self, clear_cache: bool) {
        self.library.start_loading(clear_cache);
    }

    #[func(rename = isMusicLibraryReady)]
    fn is_music_library_ready(&self) -> bool {
        self.library.is_ready()
    }

    #[func(rename = isMusicLibraryLoading)]
    fn is_music_library_loading(&self) -> bool {
        self.library.is_loading()
    }

    #[func(rename = getMusicLibraryStatusJson)]
    fn get_music_library_status_json(&self) -> GString {
        self.library.status_json().as_str().into()
    }

    #[func(rename = getMusicFoldersJson)]
    fn get_music_folders_json(&self) -> GString {
        self.library.folders_json(FolderKind::Music).as_str().into()
    }

    #[func(rename = getIgnoredMusicFoldersJson)]
    fn get_ignored_music_folders_json(&self) -> GString {
        self.library.folders_json(FolderKind::Ignored).as_str().into()
    }

    #[func(rename = requestAddMusicFolder)]
    fn request_add_music_folder(&mut self) {
        self.pick_folder(FolderKind::Music);
    }

    #[func(rename = requestAddIgnoredMusicFolder)]
    fn request_add_ignored_music_folder(&mut self) {
        self.pick_folder(FolderKind::Ignored);
    }

    #[func(rename = removeMusicFolder)]
    fn remove_music_folder(&mut self, uri: GString) -> bool {
        self.remove_folder(FolderKind::Music, &uri.to_string())
    }

    #[func(rename = removeIgnoredMusicFolder)]
    fn remove_ignored_music_folder(&mut self, uri: GString) -> bool {
        self.remove_folder(FolderKind::Ignored, &uri.to_string())
    }

    #[func(rename = getTracksJson)]
    fn get_tracks_json(&self) -> GString {
        self.library.tracks_json().as_str().into()
    }

    #[func(rename = getSongJson)]
    fn get_song_json(&self, song_id: GString) -> GString {
        self.library.song_json(&self.song_or_current(song_id)).as_str().into()
    }

    #[func(rename = getRawLyricsJson)]
    fn get_raw_lyrics_json(&self, song_id: GString) -> GString {
        self.library
            .raw_lyrics_json(&self.song_or_current(song_id))
            .as_str()
            .into()
    }

    #[func(rename = getAlbumsJson)]
    fn get_albums_json(&self) -> GString {
        self.library.albums_json().as_str().into()
    }

    #[func(rename = getAlbumJson)]
    fn get_album_json(&self, album_id: GString) -> GString {
        self.library.album_json(&album_id.to_string()).as_str().into()
    }

    #[func(rename = getArtistsJson)]
    fn get_artists_json(&self) -> GString {
        self.library.artists_json().as_str().into()
    }

    #[func(rename = getArtistJson)]
    fn get_artist_json(&self, artist_id: GString) -> GString {
        self.library
            .artist_json(&artist_id.to_string())
            .as_str()
            .into()
    }

    #[func(rename = getPlaylistsJson)]
    fn get_playlists_json(&self) -> GString {
        self.playlists.all_json(&self.library).as_str().into()
    }

    #[func(rename = getPlaylistJson)]
    fn get_playlist_json(&self, playlist_id: GString) -> GString {
        self.playlists
            .playlist_json(&playlist_id.to_string(), &self.library)
            .as_str()
            .into()
    }

    #[func(rename = createPlaylist)]
    fn create_playlist(&mut self, name: GString) -> GString {
        self.playlists.create(&name.to_string()).as_str().into()
    }

    #[func(rename = deletePlaylist)]
    fn delete_playlist(&mut self, playlist_id: GString) {
        self.playlists.delete(&playlist_id.to_string());
    }

    #[func(rename = renamePlaylist)]
    fn rename_playlist(&mut self, playlist_id: GString, name: GString) {
        self.playlists.rename(&playlist_id.to_string(), &name.to_string());
    }

    #[func(rename = addToPlaylist)]
    fn add_to_playlist(&mut self, playlist_id: GString, song_ids: GString) {
        let ids: Vec<String> = song_ids
            .to_string()
            .split(',')
            .filter(|id| !id.is_empty())
            .map(str::to_owned)
            .collect();
        self.playlists.add_songs(&playlist_id.to_string(), &ids);
    }

    #[func(rename = removeFromPlaylist)]
    fn remove_from_playlist(&mut self, playlist_id: GString, song_id: GString) {
        self.playlists
            .remove_song(&playlist_id.to_string(), &song_id.to_string());
    }

    #[func(rename = setPlaylistImage)]
    fn set_playlist_image(&mut self, playlist_id: GString, path: GString) {
        self.playlists
            .set_image(&playlist_id.to_string(), std::path::Path::new(&path.to_string()));
    }

    #[func(rename = pickPlaylistImage)]
    fn pick_playlist_image(&mut self) {
        #[cfg(target_os = "android")]
        crate::android::pick("image");
        #[cfg(not(target_os = "android"))]
        {
            let root = self.root.clone();
            let events = self.bus.sender();
            pick_file_in_background("Images", &["png", "jpg", "jpeg", "webp", "gif", "bmp"], move |picked| {
                let _ = events.send(Event::PlaylistImagePicked(square_image(&root, &picked)));
            });
        }
    }

    #[func(rename = setEqualizer)]
    fn set_equalizer(&mut self, bands: PackedVector2Array) {
        self.player()
            .set_equalizer(bands.as_slice().iter().map(|band| (band.x, band.y)).collect());
    }

    #[func(rename = pickPlugin)]
    fn pick_plugin(&mut self) {
        #[cfg(target_os = "android")]
        crate::android::pick("plugin");
        #[cfg(not(target_os = "android"))]
        {
            let root = self.root.clone();
            let events = self.bus.sender();
            pick_file_in_background("Nari plugin", &["zip"], move |picked| {
                let _ = events.send(Event::PluginPicked(pending_plugin(&root, &picked)));
            });
        }
    }

    #[func(rename = pickTheme)]
    fn pick_theme(&mut self) {
        #[cfg(target_os = "android")]
        crate::android::pick("theme");
        #[cfg(not(target_os = "android"))]
        {
            let root = self.root.clone();
            let events = self.bus.sender();
            pick_file_in_background("Nari theme", &["naritheme", "zip"], move |picked| {
                let _ = events.send(Event::ThemePicked(pending_plugin(&root, &picked)));
            });
        }
    }

    #[func(rename = pickSoundFont)]
    fn pick_soundfont(&mut self) {
        #[cfg(target_os = "android")]
        crate::android::pick("soundfont");
        #[cfg(not(target_os = "android"))]
        {
            let root = self.root.clone();
            let events = self.bus.sender();
            pick_file_in_background("SoundFont", &["sf2"], move |picked| {
                let name = std::path::Path::new(&picked)
                    .file_name()
                    .map(|name| name.to_string_lossy().into_owned())
                    .unwrap_or_default();
                let _ = events.send(Event::SoundFontPicked(keep_soundfont(&root, &picked, &name)));
            });
        }
    }

    #[func(rename = pickTextFile)]
    fn pick_text_file(&mut self, extensions: PackedStringArray) {
        #[cfg(target_os = "android")]
        {
            let _ = extensions;
            crate::android::pick("text");
        }
        #[cfg(not(target_os = "android"))]
        {
            let extensions: Vec<String> = extensions.as_slice().iter().map(GString::to_string).collect();
            let extensions: Vec<&str> = extensions.iter().map(String::as_str).collect();
            let events = self.bus.sender();
            pick_file_in_background("Text", &extensions, move |picked| {
                let _ = events.send(Event::TextPicked(text_of(&picked)));
            });
        }
    }

    #[func(rename = setSoundFont)]
    fn set_soundfont(&self, path: GString) {
        crate::synth::set_soundfont(&path.to_string());
    }

    #[func(rename = lastfmKey)]
    fn lastfm_key(&self) -> GString {
        crate::scrobble::LASTFM_KEY.into()
    }

    #[func(rename = setModuleEnding)]
    fn set_module_ending(&self, enabled: bool) {
        crate::synth::set_module_ending(enabled);
    }

    #[func(rename = extractPlugin)]
    fn extract_plugin(&self, zip_path: GString, target: GString) -> GString {
        match extract_zip(&zip_path.to_string(), &target.to_string()) {
            Ok(()) => GString::new(),
            Err(error) => error.as_str().into(),
        }
    }

    #[func(rename = getCachedCover)]
    fn get_cached_cover(&self, kind: GString, id: GString, thumb: bool) -> GString {
        self.library
            .cached_cover(&kind.to_string(), &id.to_string(), thumb)
            .as_str()
            .into()
    }

    #[func(rename = requestCover)]
    fn request_cover(&mut self, kind: GString, id: GString, thumb: bool) {
        self.library
            .request_cover(&kind.to_string(), &id.to_string(), thumb);
    }

    #[func(rename = applyMusicEffect)]
    fn apply_music_effect(&mut self, effect_id: GString) -> bool {
        self.player().apply_music_effect(&effect_id.to_string())
    }

    #[func(rename = applyCustomEffect)]
    fn apply_custom_effect(&mut self, id: GString, spec_json: GString) -> bool {
        self.player().apply_custom_effect(&id.to_string(), &spec_json.to_string())
    }

    #[func(rename = setAppVolume)]
    fn set_app_volume(&mut self, volume: f32) {
        crate::audio::set_app_volume(volume);
        self.cast.set_volume(volume);
    }

    #[func(rename = setNormalizeVolume)]
    fn set_normalize_volume(&mut self, enabled: bool) {
        self.player().set_normalize_volume(enabled);
    }

    #[func(rename = setGapless)]
    fn set_gapless(&mut self, enabled: bool) {
        self.player().set_gapless(enabled);
    }

    #[func(rename = setDiscord)]
    fn set_discord(&mut self, settings_json: GString) {
        crate::discord::settings(&settings_json.to_string());
    }

    #[func(rename = isReduceMotionEnabled)]
    fn is_reduce_motion_enabled(&self) -> bool {
        crate::device::reduce_motion()
    }

    #[func(rename = applyMusicDistortion)]
    fn apply_music_distortion(&mut self, speed: f32, pitch: f32) {
        self.player().apply_music_distortion(speed, pitch);
    }

    #[func(rename = resetMusicEffect)]
    fn reset_music_effect(&mut self) {
        self.player().reset_music_effect();
    }

    #[func(rename = resetMusicDistortion)]
    fn reset_music_distortion(&mut self) {
        self.player().reset_music_effect();
    }

    #[func(rename = getMusicEffectStateJson)]
    fn get_music_effect_state_json(&self) -> GString {
        self.player().effect_state_json().as_str().into()
    }

    #[func(rename = getAudioSpectrum)]
    fn get_audio_spectrum(&self) -> PackedByteArray {
        PackedByteArray::from(&self.player().spectrum()[..])
    }

    #[func(rename = setAudioSpectrumLatency)]
    fn set_audio_spectrum_latency(&mut self, milliseconds: i32) {
        self.player().set_spectrum_latency(milliseconds);
    }

    #[func]
    fn play(&mut self, song_id: GString, context_type: GString, context_id: GString) {
        self.player().play(
            &song_id.to_string(),
            &context_type.to_string(),
            &context_id.to_string(),
        );
    }

    #[func(rename = registerSongs)]
    fn register_songs(&mut self, songs_json: GString) {
        self.player().register_songs(&songs_json.to_string());
    }

    #[func(rename = restoreSongs)]
    fn restore_songs(&mut self, ids: PackedStringArray, song_id: GString, position: i64) -> bool {
        let ids: Vec<String> = ids.as_slice().iter().map(GString::to_string).collect();
        self.player().restore_songs(&ids, &song_id.to_string(), position.max(0) as u64)
    }

    #[func(rename = playSongs)]
    fn play_songs(&mut self, ids: PackedStringArray, song_id: GString, shuffled: bool) {
        let ids: Vec<String> = ids.as_slice().iter().map(GString::to_string).collect();
        self.player().play_songs(&ids, &song_id.to_string(), shuffled);
    }

    #[func(rename = playShuffled)]
    fn play_shuffled(&mut self, context_type: GString, context_id: GString) {
        self.player()
            .play_shuffled(&context_type.to_string(), &context_id.to_string());
    }

    #[func]
    fn resume(&mut self) {
        self.player().resume();
    }

    #[func]
    fn pause(&mut self) {
        self.player().pause();
    }

    #[func]
    fn toggle(&mut self) {
        self.player().toggle();
    }

    #[func]
    fn stop(&mut self) {
        self.player().stop();
    }

    #[func]
    fn next(&mut self) {
        self.player().next();
    }

    #[func]
    fn previous(&mut self) {
        self.player().previous();
    }

    #[func(rename = seekTo)]
    fn seek_to(&mut self, position: i32) {
        self.player().seek_to(position);
    }

    #[func(rename = setShuffle)]
    fn set_shuffle(&mut self, enabled: bool) {
        self.player().set_shuffle(enabled);
    }

    #[func(rename = setRepeat)]
    fn set_repeat(&mut self, mode: i32) {
        self.player().set_repeat(mode);
    }

    #[func(rename = skipToQueueIndex)]
    fn skip_to_queue_index(&mut self, index: i32) {
        self.player().skip_to_queue_index(index);
    }

    #[func(rename = addToQueue)]
    fn add_to_queue(&mut self, song_id: GString) {
        self.player().add_to_queue(&song_id.to_string());
    }

    #[func(rename = playNext)]
    fn play_next(&mut self, song_id: GString) {
        self.player().play_next(&song_id.to_string());
    }

    #[func(rename = removeFromQueue)]
    fn remove_from_queue(&mut self, index: i32) {
        self.player().remove_from_queue(index);
    }

    #[func(rename = moveInQueue)]
    fn move_in_queue(&mut self, from: i32, to: i32) {
        self.player().move_in_queue(from, to);
    }

    #[func(rename = clearQueue)]
    fn clear_queue(&mut self) {
        self.player().clear_queue();
    }

    #[func(rename = getQueueSongsJson)]
    fn get_queue_songs_json(&self) -> GString {
        self.player().queue_songs_json().as_str().into()
    }

    #[func(rename = getQueueIdsJson)]
    fn get_queue_ids_json(&self) -> GString {
        self.player().queue_ids_json().as_str().into()
    }

    #[func(rename = getPlaybackStateJson)]
    fn get_playback_state_json(&self) -> GString {
        self.player().state_json().as_str().into()
    }

    #[func(rename = getPositionMs)]
    fn get_position_ms(&self) -> i32 {
        self.player().position() as i32
    }

    #[func(rename = getBuffered)]
    fn get_buffered(&self) -> PackedVector2Array {
        self.player().buffered().into_iter().map(|(start, end)| Vector2::new(start as f32, end as f32)).collect()
    }

    #[func(rename = getDurationMs)]
    fn get_duration_ms(&self) -> i32 {
        self.player().duration() as i32
    }

    #[func(rename = getSoundboardSlotsJson)]
    fn get_soundboard_slots_json(&self) -> GString {
        self.soundboard.slots_json().as_str().into()
    }

    #[func(rename = getSoundboardFrame)]
    fn get_soundboard_frame(&self) -> PackedByteArray {
        PackedByteArray::from(&self.soundboard.frame()[..])
    }

    #[func(rename = setSoundboardActive)]
    fn set_soundboard_active(&mut self, active: bool) {
        self.soundboard.set_active(active);
    }

    #[func(rename = playSound)]
    fn play_sound(&mut self, slot: i32) {
        self.soundboard.play(slot);
    }

    #[func(rename = deleteSound)]
    fn delete_sound(&mut self, slot: i32) {
        self.soundboard.delete(slot);
        self.signals().soundboard_changed().emit();
    }

    #[func(rename = moveSound)]
    fn move_sound(&mut self, from: i32, to: i32) -> bool {
        let moved = self.soundboard.swap(from, to);
        if moved {
            self.signals().soundboard_changed().emit();
        }
        moved
    }

    #[func(rename = startSoundRecording)]
    fn start_sound_recording(&mut self) -> bool {
        let started = self.soundboard.start_recording();
        if started && self.player().is_playing() {
            self.resume_after_recording = true;
            self.player().pause();
        }
        started
    }

    #[func(rename = stopSoundRecording)]
    fn stop_sound_recording(&mut self) {
        self.soundboard.stop_recording();
    }

    #[func(rename = isSoundRecording)]
    fn is_sound_recording(&self) -> bool {
        self.soundboard.is_recording()
    }

    #[func(rename = importSound)]
    fn import_sound(&mut self) {
        #[cfg(target_os = "android")]
        crate::android::pick("sound");
        #[cfg(not(target_os = "android"))]
        {
            let events = self.bus.sender();
            let audio = ["mp3", "m4a", "aac", "flac", "ogg", "opus", "wav", "aif", "aiff"];
            pick_file_in_background("Audio", &audio, move |picked| {
                let value = json!({ "uri": picked, "name": picked }).to_string();
                let _ = events.send(Event::Bridge(Bridge::Picked {
                    kind: "sound".into(),
                    value,
                }));
            });
        }
    }

    #[func(rename = playPendingSound)]
    fn play_pending_sound(&mut self) {
        self.soundboard.play_pending();
    }

    #[func(rename = commitPendingSound)]
    fn commit_pending_sound(&mut self, slot: i32) -> bool {
        let committed = self.soundboard.commit_pending(slot);
        if committed {
            self.signals().soundboard_changed().emit();
        }
        committed
    }

    #[func(rename = discardPendingSound)]
    fn discard_pending_sound(&mut self) {
        self.soundboard.discard_pending();
    }

    #[func(rename = startSoundEdit)]
    fn start_sound_edit(&mut self, slot: i32, effect_id: GString, speed: f32, pitch: f32) -> bool {
        self.soundboard
            .start_edit(slot, &effect_id.to_string(), speed, pitch)
    }

    #[func(rename = setSoundEditPlaying)]
    fn set_sound_edit_playing(&mut self, playing: bool) {
        self.soundboard.set_edit_playing(playing);
    }

    #[func(rename = seekSoundEdit)]
    fn seek_sound_edit(&mut self, position_ms: i32) {
        self.soundboard.seek_edit(position_ms);
    }

    #[func(rename = getSoundEditPositionMs)]
    fn get_sound_edit_position_ms(&self) -> i32 {
        self.soundboard.edit_position_ms()
    }

    #[func(rename = getSoundEditDurationMs)]
    fn get_sound_edit_duration_ms(&self) -> i32 {
        self.soundboard.edit_duration_ms()
    }

    #[func(rename = stopSoundEdit)]
    fn stop_sound_edit(&mut self) {
        self.soundboard.stop_edit();
    }

    #[func(rename = saveSoundEdit)]
    fn save_sound_edit(&mut self, slot: i32, effect_id: GString, speed: f32, pitch: f32) -> bool {
        let saved = self
            .soundboard
            .save_edit(slot, &effect_id.to_string(), speed, pitch);
        if saved {
            self.signals().soundboard_changed().emit();
        }
        saved
    }

    #[func(rename = romanizeLines)]
    fn romanize_lines(&self, lines: PackedStringArray) -> PackedStringArray {
        let texts: Vec<String> = lines.as_slice().iter().map(GString::to_string).collect();
        crate::lyrics::romanize_lines(&texts)
            .iter()
            .map(|line| GString::from(line.as_str()))
            .collect()
    }

    #[func(rename = rankLyricsJson)]
    fn rank_lyrics_json(&self, query: GString, hits: GString) -> GString {
        crate::lyrics::rank_json(&query.to_string(), &hits.to_string())
            .as_str()
            .into()
    }

    #[func(rename = decodeKrcJson)]
    fn decode_krc_json(&self, content: GString) -> GString {
        let packed = godot::classes::Marshalls::singleton().base64_to_raw(&content);
        crate::lyrics::krc_json(packed.as_slice()).as_str().into()
    }

    #[func(rename = parseLyricsfileJson)]
    fn parse_lyricsfile_json(&self, text: GString) -> GString {
        crate::lyrics::lyricsfile_json(&text.to_string()).as_str().into()
    }

    #[func(rename = parseYrcJson)]
    fn parse_yrc_json(&self, text: GString) -> GString {
        crate::lyrics::yrc_json(&text.to_string()).as_str().into()
    }

    #[func(rename = cleanLyricsJson)]
    fn clean_lyrics_json(&self, lines: GString, title: GString, artists: GString) -> GString {
        crate::lyrics::headed_json(&lines.to_string(), &title.to_string(), &artists.to_string())
            .as_str()
            .into()
    }

    #[func(rename = setHistoryProvider)]
    fn set_history_provider(&self, provider: GString) {
        crate::history::set_provider(&provider.to_string());
    }

    #[func(rename = getHistoryJson)]
    fn get_history_json(&self, provider: GString) -> GString {
        crate::history::entries(&provider.to_string()).to_string().as_str().into()
    }

    #[func(rename = clearHistory)]
    fn clear_history(&self, provider: GString) {
        crate::history::clear(&provider.to_string());
    }

    #[func(rename = vaultSeal)]
    fn vault_seal(&self, plain: PackedByteArray) -> PackedByteArray {
        crate::vault::seal(plain.as_slice()).map(|bytes| PackedByteArray::from(bytes.as_slice())).unwrap_or_default()
    }

    #[func(rename = vaultOpen)]
    fn vault_open(&self, sealed: PackedByteArray) -> PackedByteArray {
        crate::vault::open(sealed.as_slice()).map(|bytes| PackedByteArray::from(bytes.as_slice())).unwrap_or_default()
    }

    #[func(rename = isSealed)]
    fn is_sealed(&self, uri: GString) -> bool {
        crate::plugins::sealed(&uri.to_string())
    }

    #[func(rename = saveStream)]
    fn save_stream(&self, id: i64, uri: GString, path: GString) {
        let (uri, path, events) = (uri.to_string(), path.to_string(), self.bus.sender());
        std::thread::spawn(move || {
            let result = match crate::audio::save(&uri, &path) {
                Ok(()) => json!({ "ok": true }),
                Err(error) => json!({ "ok": false, "error": error }),
            };
            let _ = events.send(Event::Job(id, result.to_string()));
        });
    }

    #[func(rename = updateFlatpak)]
    fn update_flatpak(&self, id: i64) {
        let events = self.bus.sender();
        std::thread::spawn(move || {
            let result = match crate::updates::update_flatpak() {
                Ok(()) => json!({ "ok": true }),
                Err(error) => json!({ "ok": false, "error": error }),
            };
            let _ = events.send(Event::Job(id, result.to_string()));
        });
    }

    #[func(rename = relaunchFlatpak)]
    fn relaunch_flatpak(&self) -> bool {
        crate::updates::relaunch_flatpak()
    }

    #[func(rename = installApk)]
    fn install_apk(&self, path: GString) -> GString {
        GString::from(crate::updates::install_apk(&path.to_string()).as_str())
    }

    #[func]
    fn analyze(&self, id: i64, uri: GString, options_json: GString) {
        let (uri, events) = (uri.to_string(), self.bus.sender());
        let options: serde_json::Value = serde_json::from_str(&options_json.to_string()).unwrap_or_default();
        std::thread::spawn(move || {
            let result = crate::analysis::analyze(&uri, &options).unwrap_or_else(|error| json!({ "error": error }));
            let _ = events.send(Event::Job(id, result.to_string()));
        });
    }

    #[func(rename = launchTargets)]
    fn launch_targets(&self) -> PackedStringArray {
        if crate::mpris::links_forwarded() {
            return PackedStringArray::new();
        }
        crate::opened::launch_targets().iter().map(GString::from).collect()
    }

    #[func(rename = fileSongJson)]
    fn file_song_json(&self, uri: GString, name: GString) -> GString {
        crate::opened::song(&uri.to_string(), &name.to_string(), &self.root.join("cache").join("opened")).to_string().as_str().into()
    }

    #[func(rename = isAudioFile)]
    fn is_audio_file(&self, name: GString) -> bool {
        crate::opened::is_audio(&name.to_string())
    }

    #[func(rename = linksForwarded)]
    fn links_forwarded(&self) -> bool {
        crate::mpris::links_forwarded()
    }

    #[func(rename = setTrayEnabled)]
    fn set_tray_enabled(&mut self, enabled: bool) {
        match (enabled, self.tray.is_some()) {
            (true, false) => self.tray = Tray::new(self.bus.sender()),
            (false, true) => {
                if let Some(tray) = self.tray.take() {
                    tray.shutdown();
                }
            }
            _ => {}
        }
    }

    #[func(rename = setWindowVisible)]
    fn set_window_visible(&self, visible: bool) -> bool {
        crate::tray::set_window_visible(visible)
    }
}

impl MusicService {
    fn player(&self) -> MutexGuard<'_, Player> {
        self.player.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    fn song_or_current(&self, song_id: GString) -> String {
        let id = song_id.to_string();
        if id.is_empty() {
            self.player().current_id()
        } else {
            id
        }
    }

    #[cfg(target_os = "android")]
    fn pick_folder(&self, kind: FolderKind) {
        crate::android::pick(kind.id());
    }

    #[cfg(target_os = "ios")]
    fn pick_folder(&self, kind: FolderKind) {
        let library = self.library.clone();
        let events = self.bus.sender();
        crate::ios::pick_folder(move |picked| {
            let uri = picked.as_ref().map(|folder| folder.uri.clone()).unwrap_or_default();
            let success = picked.is_some_and(|folder| library.add_folder(kind, folder));
            let _ = events.send(Event::FolderSelected {
                kind: kind.id().to_owned(),
                success,
                uri,
            });
        });
    }

    #[cfg(not(any(target_os = "android", target_os = "ios")))]
    fn pick_folder(&self, kind: FolderKind) {
        let library = self.library.clone();
        let events = self.bus.sender();
        std::thread::spawn(move || {
            let picked = rfd::FileDialog::new().pick_folder();
            let (success, uri) = match picked {
                Some(path) => (
                    library.add_folder(kind, Folder::of(&path)),
                    path.to_string_lossy().into_owned(),
                ),
                None => (false, String::new()),
            };
            let _ = events.send(Event::FolderSelected {
                kind: kind.id().to_owned(),
                success,
                uri,
            });
        });
    }

    fn remove_folder(&mut self, kind: FolderKind, uri: &str) -> bool {
        let removed = self.library.remove_folder(kind, uri);
        #[cfg(target_os = "android")]
        if removed && !self.library.folder_used(uri) {
            crate::android::release_folder(uri);
        }
        removed
    }

    fn bridge(&mut self, bridge: Bridge) {
        match bridge {
            Bridge::Picked { kind, value } => self.picked(&kind, &value),
            Bridge::Permission { .. } => {}
            Bridge::LibraryChanged => self.library.start_loading(false),
            Bridge::NowPlaying => {
                self.now_playing = true;
                self.signals().now_playing_requested().emit();
            }
            Bridge::Link(url) => self.signals().link_opened().emit(&url),
        }
    }

    fn picked(&mut self, kind: &str, value: &str) {
        let picked: serde_json::Value = serde_json::from_str(value).unwrap_or_default();
        let uri = picked["uri"].as_str().unwrap_or_default().to_owned();
        match kind {
            "music" | "ignored" => {
                let folder_kind = if kind == "music" { FolderKind::Music } else { FolderKind::Ignored };
                let added = serde_json::from_value::<Folder>(picked)
                    .ok()
                    .filter(|folder| !folder.uri.is_empty())
                    .is_some_and(|folder| self.library.add_folder(folder_kind, folder));
                self.signals()
                    .music_folder_selected()
                    .emit(kind, added, uri.as_str());
            }
            "image" => {
                let root = self.root.clone();
                let events = self.bus.sender();
                std::thread::spawn(move || {
                    let _ = events.send(Event::PlaylistImagePicked(square_image(&root, &uri)));
                });
            }
            "plugin" => {
                let root = self.root.clone();
                let events = self.bus.sender();
                std::thread::spawn(move || {
                    let _ = events.send(Event::PluginPicked(pending_plugin(&root, &uri)));
                });
            }
            "theme" => {
                let root = self.root.clone();
                let events = self.bus.sender();
                std::thread::spawn(move || {
                    let _ = events.send(Event::ThemePicked(pending_plugin(&root, &uri)));
                });
            }
            "soundfont" => {
                let root = self.root.clone();
                let events = self.bus.sender();
                let name = picked["name"].as_str().unwrap_or_default().to_owned();
                std::thread::spawn(move || {
                    let _ = events.send(Event::SoundFontPicked(keep_soundfont(&root, &uri, &name)));
                });
            }
            "text" => {
                let events = self.bus.sender();
                std::thread::spawn(move || {
                    let _ = events.send(Event::TextPicked(text_of(&uri)));
                });
            }
            "sound" if !uri.is_empty() => {
                let name = picked["name"].as_str().unwrap_or_default().to_owned();
                self.soundboard.import(uri, name);
            }
            "sound" => self.signals().soundboard_captured().emit(false),
            _ => {}
        }
    }

}

#[cfg(target_os = "android")]
fn has_permission(kind: &str) -> bool {
    crate::android::has_permission(kind)
}

#[cfg(not(target_os = "android"))]
fn has_permission(_kind: &str) -> bool {
    true
}

#[cfg(target_os = "android")]
fn request_permission(kind: &str) {
    crate::android::request_permission(kind);
}

#[cfg(not(target_os = "android"))]
fn request_permission(_kind: &str) {}

fn extract_zip(zip_path: &str, target: &str) -> Result<(), String> {
    let file = std::fs::File::open(zip_path).map_err(|error| error.to_string())?;
    let mut archive = zip::ZipArchive::new(file).map_err(|error| error.to_string())?;
    let mut unpacked: u64 = 0;
    for index in 0..archive.len() {
        let entry = archive.by_index_raw(index).map_err(|error| error.to_string())?;
        if entry.is_symlink() {
            return Err(format!("the archive has a link, '{}', and links aren't allowed", entry.name()));
        }
        unpacked = unpacked.saturating_add(entry.size());
    }
    if unpacked > EXTRACT_LIMIT {
        return Err(format!("the archive unpacks to more than {} MB", EXTRACT_LIMIT / 1024 / 1024));
    }
    archive.extract(target).map_err(|error| error.to_string())
}

#[cfg(target_os = "ios")]
fn pick_file_in_background(_filter: &'static str, _extensions: &[&str], deliver: impl FnOnce(String) + Send + 'static) {
    deliver(String::new());
}

#[cfg(not(any(target_os = "android", target_os = "ios")))]
fn pick_file_in_background(filter: &'static str, extensions: &[&str], deliver: impl FnOnce(String) + Send + 'static) {
    let extensions: Vec<String> = extensions.iter().map(|extension| extension.to_string()).collect();
    std::thread::spawn(move || {
        let mut dialog = rfd::FileDialog::new();
        if !extensions.is_empty() {
            dialog = dialog.add_filter(filter, &extensions);
        }
        let picked = dialog
            .pick_file()
            .map(|path| path.to_string_lossy().into_owned())
            .unwrap_or_default();
        deliver(picked);
    });
}

fn pending_plugin(root: &std::path::Path, uri: &str) -> String {
    if uri.is_empty() {
        return String::new();
    }
    let target = root.join(PENDING_PLUGIN);
    crate::storage::read(uri)
        .and_then(|bytes| crate::storage::write_atomically(&target, &bytes))
        .map(|_| target.to_string_lossy().into_owned())
        .unwrap_or_default()
}

fn text_of(uri: &str) -> String {
    if uri.is_empty() {
        return String::new();
    }
    crate::storage::read_limited(uri, TEXT_LIMIT)
        .map(|bytes| String::from_utf8_lossy(&bytes).into_owned())
        .unwrap_or_default()
}

fn keep_soundfont(root: &std::path::Path, uri: &str, name: &str) -> String {
    let Some(bytes) = crate::storage::read(uri)
        .ok()
        .filter(|bytes| !uri.is_empty() && bytes.starts_with(b"RIFF") && bytes.get(8..12) == Some(b"sfbk"))
    else {
        return String::new();
    };
    let folder = root.join(SOUNDFONTS);
    let stem: String = name
        .rsplit_once('.')
        .map_or(name, |(stem, _)| stem)
        .chars()
        .map(|char| if char.is_alphanumeric() || " -_()".contains(char) { char } else { '_' })
        .collect();
    let stem = if stem.trim().is_empty() { "SoundFont".to_owned() } else { stem.trim().to_owned() };
    let mut target = folder.join(format!("{stem}.sf2"));
    let mut copy = 2;
    while target.exists() {
        target = folder.join(format!("{stem} ({copy}).sf2"));
        copy += 1;
    }
    std::fs::create_dir_all(&folder)
        .and_then(|_| std::fs::write(&target, bytes))
        .map(|_| target.to_string_lossy().into_owned())
        .unwrap_or_default()
}

fn square_image(root: &std::path::Path, uri: &str) -> String {
    if uri.is_empty() {
        return String::new();
    }
    let decoded = crate::storage::read(uri).ok().and_then(|bytes| {
        let mut decoder = image::ImageReader::new(std::io::Cursor::new(bytes))
            .with_guessed_format()
            .ok()?
            .into_decoder()
            .ok()?;
        let orientation = image::ImageDecoder::orientation(&mut decoder).ok();
        let mut picture = image::DynamicImage::from_decoder(decoder).ok()?;
        if let Some(orientation) = orientation {
            picture.apply_orientation(orientation);
        }
        Some(picture)
    });
    let Some(picture) = decoded else {
        return String::new();
    };
    let side = picture.width().min(picture.height());
    let square = picture
        .crop_imm((picture.width() - side) / 2, (picture.height() - side) / 2, side, side)
        .resize_exact(PLAYLIST_IMAGE_SIZE, PLAYLIST_IMAGE_SIZE, image::imageops::FilterType::Triangle)
        .to_rgb8();
    let target = root.join(PENDING_IMAGE);
    match square.save_with_format(&target, image::ImageFormat::Jpeg) {
        Ok(()) => target.to_string_lossy().into_owned(),
        Err(_) => String::new(),
    }
}

#[derive(GodotClass)]
#[class(base = Node, init)]
pub struct ServiceTicker {
    base: Base<Node>,
}

#[godot_api]
impl INode for ServiceTicker {
    fn ready(&mut self) {
        MusicService::singleton().bind_mut().start_library();
    }

    fn process(&mut self, _delta: f64) {
        let mut service = MusicService::singleton();
        service.bind_mut().tick();
        service.bind_mut().pump();
    }

    fn exit_tree(&mut self) {
        MusicService::singleton().bind_mut().shutdown();
    }
}


