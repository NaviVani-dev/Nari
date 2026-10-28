#[derive(Clone, Debug, Default, PartialEq)]
pub struct Media {
    pub id: String,
    pub title: String,
    pub artists: Vec<String>,
    pub album: String,
    pub length_ms: u64,
    pub art: String,
    pub playing: bool,
    pub has_song: bool,
    pub has_next: bool,
    pub seeks: u64,
}

#[cfg(any(target_os = "linux", target_os = "macos", target_os = "ios"))]
pub use platform::Mpris;

#[cfg(not(any(target_os = "linux", target_os = "macos", target_os = "ios")))]
pub struct Mpris;

static FORWARDED: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

pub fn links_forwarded() -> bool {
    FORWARDED.load(std::sync::atomic::Ordering::Relaxed)
}

#[cfg(not(any(target_os = "linux", target_os = "macos", target_os = "ios")))]
impl Mpris {
    pub fn new(_: std::sync::Weak<std::sync::Mutex<crate::player::Player>>, _: std::sync::mpsc::Sender<crate::events::Event>) -> Option<Self> {
        None
    }

    pub fn update(&self, _: Media) {}
}

#[cfg(any(target_os = "macos", target_os = "ios"))]
mod platform {
    use super::Media;
    use crate::events::Event;
    use crate::player::Player;
    use block2::RcBlock;
    use objc2::rc::Retained;
    use objc2::runtime::{AnyObject, ProtocolObject};
    use objc2::AllocAnyThread;
    #[cfg(target_os = "macos")]
    use objc2_app_kit::NSImage;
    #[cfg(target_os = "ios")]
    use objc2_ui_kit::UIImage;
    use objc2_foundation::{NSCopying, NSData, NSMutableDictionary, NSNumber, NSSize, NSString};
    use objc2_media_player::{
        MPChangePlaybackPositionCommandEvent, MPMediaItemArtwork, MPMediaItemPropertyAlbumTitle, MPMediaItemPropertyArtist,
        MPMediaItemPropertyArtwork, MPMediaItemPropertyPlaybackDuration, MPMediaItemPropertyTitle, MPNowPlayingInfoCenter,
        MPNowPlayingInfoPropertyElapsedPlaybackTime, MPNowPlayingInfoPropertyPlaybackRate, MPNowPlayingPlaybackState, MPRemoteCommand,
        MPRemoteCommandCenter, MPRemoteCommandEvent, MPRemoteCommandHandlerStatus,
    };
    use std::cell::RefCell;
    use std::ptr::NonNull;
    use std::sync::{Mutex, MutexGuard, Weak};

    type Handler = RcBlock<dyn Fn(NonNull<MPRemoteCommandEvent>) -> MPRemoteCommandHandlerStatus>;

    pub struct Mpris {
        #[cfg(target_os = "macos")]
        now_playing: NowPlaying,
        _handlers: Vec<Handler>,
    }

    struct NowPlaying {
        player: Weak<Mutex<Player>>,
        art: RefCell<(String, Option<Retained<MPMediaItemArtwork>>)>,
    }

    fn with(player: &Weak<Mutex<Player>>, action: impl FnOnce(&mut MutexGuard<'_, Player>)) -> MPRemoteCommandHandlerStatus {
        match player.upgrade() {
            Some(player) => {
                let mut player = player.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
                action(&mut player);
                MPRemoteCommandHandlerStatus::Success
            }
            None => MPRemoteCommandHandlerStatus::NoActionableNowPlayingItem,
        }
    }

    fn bind(command: &MPRemoteCommand, handlers: &mut Vec<Handler>, handler: impl Fn(NonNull<MPRemoteCommandEvent>) -> MPRemoteCommandHandlerStatus + 'static) {
        let handler: Handler = RcBlock::new(handler);
        unsafe {
            command.setEnabled(true);
            command.addTargetWithHandler(&handler);
        }
        handlers.push(handler);
    }

    impl Mpris {
        pub fn new(player: Weak<Mutex<Player>>, _events: std::sync::mpsc::Sender<Event>) -> Option<Self> {
            let center = unsafe { MPRemoteCommandCenter::sharedCommandCenter() };
            let mut handlers = Vec::new();
            unsafe {
                let weak = player.clone();
                bind(&center.playCommand(), &mut handlers, move |_| with(&weak, |player| player.resume()));
                let weak = player.clone();
                bind(&center.pauseCommand(), &mut handlers, move |_| with(&weak, |player| player.pause()));
                let weak = player.clone();
                bind(&center.stopCommand(), &mut handlers, move |_| with(&weak, |player| player.pause()));
                let weak = player.clone();
                bind(&center.togglePlayPauseCommand(), &mut handlers, move |_| with(&weak, |player| player.toggle()));
                let weak = player.clone();
                bind(&center.nextTrackCommand(), &mut handlers, move |_| with(&weak, |player| player.next()));
                let weak = player.clone();
                bind(&center.previousTrackCommand(), &mut handlers, move |_| with(&weak, |player| player.previous()));
                let weak = player.clone();
                bind(&center.changePlaybackPositionCommand(), &mut handlers, move |event| {
                    let event = event.cast::<MPChangePlaybackPositionCommandEvent>();
                    let seconds = event.as_ref().positionTime();
                    with(&weak, |player| player.seek_to((seconds * 1000.0).clamp(0.0, i32::MAX as f64) as i32))
                });
            }
            #[cfg(target_os = "ios")]
            watch(player);
            Some(Self {
                #[cfg(target_os = "macos")]
                now_playing: NowPlaying::new(player),
                _handlers: handlers,
            })
        }

        #[cfg(target_os = "macos")]
        pub fn update(&self, media: Media) {
            self.now_playing.update(media);
        }

        #[cfg(target_os = "ios")]
        pub fn update(&self, _: Media) {}
    }

    #[cfg(target_os = "ios")]
    fn watch(player: Weak<Mutex<Player>>) {
        std::thread::spawn(move || {
            let now_playing = NowPlaying::new(player.clone());
            let mut shown = Media::default();
            while let Some(current) = player.upgrade() {
                let media = {
                    let mut player = current.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
                    player.tick();
                    player.media()
                };
                drop(current);
                if media != shown {
                    shown = media.clone();
                    now_playing.update(media);
                }
                std::thread::sleep(std::time::Duration::from_millis(250));
            }
        });
    }

    impl NowPlaying {
        fn new(player: Weak<Mutex<Player>>) -> Self {
            Self { player, art: RefCell::new((String::new(), None)) }
        }

        fn update(&self, media: Media) {
            unsafe {
                let center = MPNowPlayingInfoCenter::defaultCenter();
                let remote = MPRemoteCommandCenter::sharedCommandCenter();
                remote.nextTrackCommand().setEnabled(media.has_next);
                remote.previousTrackCommand().setEnabled(media.has_song);
                if !media.has_song {
                    center.setNowPlayingInfo(None);
                    #[cfg(target_os = "macos")]
                    center.setPlaybackState(MPNowPlayingPlaybackState::Stopped);
                    return;
                }
                let position = self
                    .player
                    .upgrade()
                    .map(|player| player.lock().unwrap_or_else(|poisoned| poisoned.into_inner()).position())
                    .unwrap_or(0);
                let info: Retained<NSMutableDictionary<NSString, AnyObject>> = NSMutableDictionary::new();
                let put = |key: &NSString, value: &AnyObject| info.setObject_forKey(value, ProtocolObject::<dyn NSCopying>::from_ref(key));
                put(MPMediaItemPropertyTitle, &NSString::from_str(&media.title));
                put(MPMediaItemPropertyArtist, &NSString::from_str(&media.artists.join(", ")));
                put(MPMediaItemPropertyAlbumTitle, &NSString::from_str(&media.album));
                put(MPMediaItemPropertyPlaybackDuration, &NSNumber::new_f64(media.length_ms as f64 / 1000.0));
                put(MPNowPlayingInfoPropertyElapsedPlaybackTime, &NSNumber::new_f64(position as f64 / 1000.0));
                put(MPNowPlayingInfoPropertyPlaybackRate, &NSNumber::new_f64(if media.playing { 1.0 } else { 0.0 }));
                if let Some(artwork) = self.artwork(&media) {
                    put(MPMediaItemPropertyArtwork, &artwork);
                }
                center.setNowPlayingInfo(Some(&info));
                #[cfg(target_os = "macos")]
                center.setPlaybackState(if media.playing { MPNowPlayingPlaybackState::Playing } else { MPNowPlayingPlaybackState::Paused });
            }
        }

        fn artwork(&self, media: &Media) -> Option<Retained<MPMediaItemArtwork>> {
            let key = format!("{}:{}", media.id, media.art);
            let mut cached = self.art.borrow_mut();
            if cached.0 != key {
                cached.1 = [self.original(), std::fs::read(&media.art).ok()].into_iter().flatten().find_map(|bytes| artwork_of(&bytes));
                cached.0 = key;
            }
            cached.1.clone()
        }

        fn original(&self) -> Option<Vec<u8>> {
            let song = self.player.upgrade()?.lock().unwrap_or_else(|poisoned| poisoned.into_inner()).local_song()?;
            crate::library::original_cover(&song)
        }
    }

    #[cfg(target_os = "macos")]
    fn artwork_of(bytes: &[u8]) -> Option<Retained<MPMediaItemArtwork>> {
        let image = NSImage::initWithData(NSImage::alloc(), &NSData::with_bytes(bytes))?;
        let size = image.size();
        let handler = RcBlock::new(move |_: NSSize| NonNull::from(&*image));
        Some(unsafe { MPMediaItemArtwork::initWithBoundsSize_requestHandler(MPMediaItemArtwork::alloc(), size, &handler) })
    }

    #[cfg(target_os = "ios")]
    fn artwork_of(bytes: &[u8]) -> Option<Retained<MPMediaItemArtwork>> {
        let image = UIImage::imageWithData(&NSData::with_bytes(bytes))?;
        let size = unsafe { image.size() };
        let handler = RcBlock::new(move |_: NSSize| NonNull::from(&*image));
        Some(unsafe { objc2::msg_send![MPMediaItemArtwork::alloc(), initWithBoundsSize: size, requestHandler: &*handler] })
    }

    impl Drop for Mpris {
        fn drop(&mut self) {
            unsafe {
                let remote = MPRemoteCommandCenter::sharedCommandCenter();
                for command in [
                    remote.playCommand(),
                    remote.pauseCommand(),
                    remote.stopCommand(),
                    remote.togglePlayPauseCommand(),
                    remote.nextTrackCommand(),
                    remote.previousTrackCommand(),
                ] {
                    command.removeTarget(None);
                }
                remote.changePlaybackPositionCommand().removeTarget(None);
                MPNowPlayingInfoCenter::defaultCenter().setNowPlayingInfo(None);
            }
        }
    }
}

#[cfg(target_os = "linux")]
mod platform {
    use super::Media;
    use crate::events::Event;
    use crate::player::Player;
    use crate::tray::{QUIT, SHOW};
    use std::collections::HashMap;
    use std::sync::mpsc::{channel, Receiver, Sender};
    use std::sync::{Mutex, MutexGuard, Weak};
    use zbus::object_server::SignalEmitter;
    use zbus::zvariant::{ObjectPath, OwnedValue, Value};

    const PATH: &str = "/org/mpris/MediaPlayer2";
    const NAME: &str = "org.mpris.MediaPlayer2.Nari";
    const DESKTOP_ENTRY: &str = "io.github.NaviVani_dev.Nari";
    const NO_TRACK: &str = "/org/mpris/MediaPlayer2/TrackList/NoTrack";
    const LINKS: &str = "io.github.NaviVani_dev.Nari";

    pub struct Mpris {
        updates: Sender<Media>,
    }

    impl Mpris {
        pub fn new(player: Weak<Mutex<Player>>, events: Sender<Event>) -> Option<Self> {
            let links = crate::opened::launch_targets();
            if !links.is_empty() && links.iter().all(|link| forward_link(link)) {
                super::FORWARDED.store(true, std::sync::atomic::Ordering::Relaxed);
                return None;
            }
            let (updates, receiver) = channel();
            std::thread::Builder::new()
                .name("mpris".into())
                .spawn(move || {
                    if let Err(error) = serve(player, events, receiver) {
                        godot::global::godot_error!("MusicService MPRIS unavailable: {error}");
                    }
                })
                .ok()?;
            Some(Self { updates })
        }

        pub fn update(&self, media: Media) {
            let _ = self.updates.send(media);
        }
    }

    fn serve(player: Weak<Mutex<Player>>, events: Sender<Event>, updates: Receiver<Media>) -> zbus::Result<()> {
        let build = |name: String| {
            zbus::blocking::connection::Builder::session()?
                .name(name)?
                .serve_at(PATH, Root { events: events.clone() })?
                .serve_at(PATH, Links { events: events.clone() })?
                .serve_at(PATH, Controls { player: player.clone(), media: Media::default() })?
                .build()
        };
        let connection = build(NAME.to_owned()).or_else(|_| build(format!("{NAME}.instance{}", std::process::id())))?;
        let controls = connection.object_server().interface::<_, Controls>(PATH)?;
        while let Ok(mut media) = updates.recv() {
            if let Some(latest) = updates.try_iter().last() {
                media = latest;
            }
            let mut current = controls.get_mut();
            let seeked = media.seeks != current.media.seeks && media.id == current.media.id;
            current.media = media;
            let emitter = controls.signal_emitter();
            zbus::block_on(async {
                current.playback_status_changed(emitter).await?;
                current.metadata_changed(emitter).await?;
                current.can_go_next_changed(emitter).await?;
                current.can_play_changed(emitter).await?;
                current.can_pause_changed(emitter).await?;
                current.can_seek_changed(emitter).await?;
                if seeked {
                    Controls::seeked(emitter, current.position()).await?;
                }
                zbus::Result::Ok(())
            })?;
        }
        Ok(())
    }

    struct Root {
        events: Sender<Event>,
    }

    struct Links {
        events: Sender<Event>,
    }

    #[zbus::interface(name = "io.github.NaviVani_dev.Nari")]
    impl Links {
        fn open_link(&self, url: String) {
            let _ = self.events.send(Event::Link(url));
        }
    }

    fn forward_link(url: &str) -> bool {
        let Ok(connection) = zbus::blocking::Connection::session() else {
            return false;
        };
        connection.call_method(Some(NAME), PATH, Some(LINKS), "OpenLink", &(url,)).is_ok()
    }

    #[zbus::interface(name = "org.mpris.MediaPlayer2")]
    impl Root {
        fn raise(&self) {
            let _ = self.events.send(Event::TrayCommand(SHOW.to_owned()));
        }

        fn quit(&self) {
            let _ = self.events.send(Event::TrayCommand(QUIT.to_owned()));
        }

        #[zbus(property)]
        fn can_quit(&self) -> bool {
            true
        }

        #[zbus(property)]
        fn can_raise(&self) -> bool {
            true
        }

        #[zbus(property)]
        fn has_track_list(&self) -> bool {
            false
        }

        #[zbus(property)]
        fn identity(&self) -> &str {
            "Nari"
        }

        #[zbus(property)]
        fn desktop_entry(&self) -> &str {
            DESKTOP_ENTRY
        }

        #[zbus(property)]
        fn supported_uri_schemes(&self) -> Vec<String> {
            Vec::new()
        }

        #[zbus(property)]
        fn supported_mime_types(&self) -> Vec<String> {
            Vec::new()
        }
    }

    struct Controls {
        player: Weak<Mutex<Player>>,
        media: Media,
    }

    impl Controls {
        fn with(&self, action: impl FnOnce(&mut MutexGuard<'_, Player>)) {
            if let Some(player) = self.player.upgrade() {
                let mut player = player.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
                action(&mut player);
            }
        }

        fn current_ms(&self) -> u64 {
            self.player
                .upgrade()
                .map(|player| player.lock().unwrap_or_else(|poisoned| poisoned.into_inner()).position())
                .unwrap_or(0)
        }
    }

    #[zbus::interface(name = "org.mpris.MediaPlayer2.Player")]
    impl Controls {
        fn next(&self) {
            self.with(|player| player.next());
        }

        fn previous(&self) {
            self.with(|player| player.previous());
        }

        fn pause(&self) {
            self.with(|player| player.pause());
        }

        fn play_pause(&self) {
            self.with(|player| player.toggle());
        }

        fn stop(&self) {
            self.with(|player| player.pause());
        }

        fn play(&self) {
            self.with(|player| player.resume());
        }

        fn seek(&self, offset: i64) {
            let target = (self.current_ms() as i64 + offset / 1000).clamp(0, i32::MAX as i64);
            self.with(|player| player.seek_to(target as i32));
        }

        fn set_position(&self, track: ObjectPath<'_>, position: i64) {
            if track.as_str() == track_path(&self.media.id) && position >= 0 && (position / 1000) as u64 <= self.media.length_ms {
                self.with(|player| player.seek_to((position / 1000).min(i32::MAX as i64) as i32));
            }
        }

        fn open_uri(&self, _uri: String) {}

        #[zbus(signal)]
        async fn seeked(emitter: &SignalEmitter<'_>, position: i64) -> zbus::Result<()>;

        #[zbus(property)]
        fn playback_status(&self) -> &str {
            match (self.media.has_song, self.media.playing) {
                (false, _) => "Stopped",
                (true, true) => "Playing",
                (true, false) => "Paused",
            }
        }

        #[zbus(property)]
        fn rate(&self) -> f64 {
            1.0
        }

        #[zbus(property)]
        fn minimum_rate(&self) -> f64 {
            1.0
        }

        #[zbus(property)]
        fn maximum_rate(&self) -> f64 {
            1.0
        }

        #[zbus(property)]
        fn volume(&self) -> f64 {
            1.0
        }

        #[zbus(property)]
        fn metadata(&self) -> HashMap<String, OwnedValue> {
            metadata(&self.media)
        }

        #[zbus(property(emits_changed_signal = "false"))]
        fn position(&self) -> i64 {
            self.current_ms() as i64 * 1000
        }

        #[zbus(property)]
        fn can_go_next(&self) -> bool {
            self.media.has_next
        }

        #[zbus(property)]
        fn can_go_previous(&self) -> bool {
            self.media.has_song
        }

        #[zbus(property)]
        fn can_play(&self) -> bool {
            self.media.has_song
        }

        #[zbus(property)]
        fn can_pause(&self) -> bool {
            self.media.has_song
        }

        #[zbus(property)]
        fn can_seek(&self) -> bool {
            self.media.has_song
        }

        #[zbus(property(emits_changed_signal = "const"))]
        fn can_control(&self) -> bool {
            true
        }
    }

    fn track_path(id: &str) -> String {
        if id.is_empty() {
            return NO_TRACK.to_owned();
        }
        let safe: String = id.bytes().map(|byte| format!("{byte:02x}")).collect();
        format!("/io/github/NaviVani_dev/Nari/track/t{safe}")
    }

    fn file_url(path: &str) -> String {
        let mut url = String::from("file://");
        for byte in path.bytes() {
            match byte {
                b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'/' | b'-' | b'_' | b'.' | b'~' => url.push(byte as char),
                _ => url.push_str(&format!("%{byte:02X}")),
            }
        }
        url
    }

    fn metadata(media: &Media) -> HashMap<String, OwnedValue> {
        let mut map = HashMap::new();
        let mut put = |key: &str, value: Value<'_>| {
            if let Ok(owned) = OwnedValue::try_from(value) {
                map.insert(key.to_owned(), owned);
            }
        };
        if let Ok(path) = ObjectPath::try_from(track_path(&media.id)) {
            put("mpris:trackid", Value::from(path));
        }
        if !media.has_song {
            return map;
        }
        put("xesam:title", Value::from(media.title.as_str()));
        put("xesam:artist", Value::from(media.artists.clone()));
        put("xesam:album", Value::from(media.album.as_str()));
        put("mpris:length", Value::from(media.length_ms as i64 * 1000));
        if !media.art.is_empty() {
            put("mpris:artUrl", Value::from(file_url(&media.art)));
        }
        map
    }

    #[cfg(test)]
    mod tests {
        use super::*;

        #[test]
        fn metadata_uses_valid_paths_and_urls() {
            let media = Media {
                id: "navidrome:a b/ñ".into(),
                title: "Song".into(),
                artists: vec!["One".into(), "Two".into()],
                album: "Album".into(),
                length_ms: 1500,
                art: "/tmp/covers/a b.jpg".into(),
                has_song: true,
                ..Media::default()
            };
            let map = metadata(&media);
            assert!(ObjectPath::try_from(track_path(&media.id)).is_ok());
            assert_eq!(track_path(""), NO_TRACK);
            assert_eq!(i64::try_from(&map["mpris:length"]).unwrap(), 1_500_000);
            assert_eq!(<&str>::try_from(&map["mpris:artUrl"]).unwrap(), "file:///tmp/covers/a%20b.jpg");
            assert_eq!(metadata(&Media::default()).len(), 1);
        }
    }
}
