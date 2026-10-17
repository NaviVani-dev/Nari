use std::collections::HashSet;
use std::mem::discriminant;
use std::sync::mpsc::{channel, Receiver, Sender};

#[allow(dead_code)]
pub enum Event {
    PlaybackChanged(String),
    CoverReady {
        kind: String,
        id: String,
        thumb: bool,
        path: String,
    },
    LibraryProgress(String),
    LibraryReady {
        success: bool,
        error: String,
    },
    FolderSelected {
        kind: String,
        success: bool,
        uri: String,
    },
    EffectChanged(String),
    LibraryChanged,
    SoundboardChanged,
    SoundboardCaptured(bool),
    PlaylistImagePicked(String),
    PluginPicked(String),
    ThemePicked(String),
    SoundFontPicked(String),
    TextPicked(String),
    ScrobbleAuthUrl {
        service: String,
        url: String,
    },
    ScrobbleAccount {
        service: String,
        error: String,
    },
    TrayCommand(String),
    Played(String),
    Link(String),
    Job(i64, String),
    CastDevices(String),
    CastState(String),
    Bridge(Bridge),
}

impl Event {
    fn is_snapshot(&self) -> bool {
        matches!(
            self,
            Event::PlaybackChanged(_)
                | Event::LibraryProgress(_)
                | Event::EffectChanged(_)
                | Event::LibraryChanged
                | Event::SoundboardChanged
                | Event::CastDevices(_)
                | Event::CastState(_)
        )
    }
}

#[allow(dead_code)]
pub enum Bridge {
    Picked { kind: String, value: String },
    Permission { kind: String, granted: bool },
    LibraryChanged,
    NowPlaying,
    Link(String),
}

pub struct Bus {
    sender: Sender<Event>,
    receiver: Receiver<Event>,
}

impl Bus {
    pub fn new() -> Self {
        let (sender, receiver) = channel();
        Self { sender, receiver }
    }

    pub fn sender(&self) -> Sender<Event> {
        self.sender.clone()
    }

    pub fn drain(&self) -> Vec<Event> {
        let mut seen = HashSet::new();
        let mut events: Vec<Event> = self.receiver.try_iter().collect();
        events.reverse();
        events.retain(|event| !event.is_snapshot() || seen.insert(discriminant(event)));
        events.reverse();
        events
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn drain_keeps_latest_snapshot_of_each_kind() {
        let bus = Bus::new();
        let sender = bus.sender();
        for event in [
            Event::PlaybackChanged("a".into()),
            Event::Played("a".into()),
            Event::LibraryChanged,
            Event::PlaybackChanged("b".into()),
            Event::Played("b".into()),
            Event::LibraryChanged,
        ] {
            sender.send(event).unwrap();
        }
        let kinds: Vec<String> = bus
            .drain()
            .into_iter()
            .map(|event| match event {
                Event::PlaybackChanged(state) => format!("state {state}"),
                Event::Played(song) => format!("played {song}"),
                Event::LibraryChanged => "library".into(),
                _ => "other".into(),
            })
            .collect();
        assert_eq!(kinds, ["played a", "state b", "played b", "library"]);
    }
}
