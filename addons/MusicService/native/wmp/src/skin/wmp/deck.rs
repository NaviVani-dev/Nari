#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum PlayState {
    #[default]
    Stopped = 1,
    Paused = 2,
    Playing = 3,
    Buffering = 6,
}

pub const OPEN_MEDIA_CHANGING: i32 = 8;
pub const OPEN_MEDIA_OPEN: i32 = 13;
pub const OPEN_NO_MEDIA: i32 = 6;

#[derive(Clone, Debug, Default, PartialEq)]
pub struct Song {
    pub title: String,
    pub artist: String,
    pub album: String,
    pub uri: String,
    pub duration_s: f64,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Deck {
    pub state: PlayState,
    pub song: Option<Song>,
    pub position_s: f64,
    pub bitrate: u32,
    pub volume: u8,
    pub mute: bool,
    pub balance: i32,
    pub shuffle: bool,
    pub repeat: bool,
    pub can_control: bool,
    pub queue: Vec<Song>,
    pub playing: Option<usize>,
    pub eq_on: bool,
    pub eq_bands: [f32; 10],
    pub eq_preamp: f32,
    pub eq_presets: Vec<String>,
    pub eq_preset: Option<usize>,
    pub effect: usize,
}

impl Default for Deck {
    fn default() -> Self {
        Self {
            state: PlayState::Stopped,
            song: None,
            position_s: 0.0,
            bitrate: 0,
            volume: 100,
            mute: false,
            balance: 0,
            shuffle: false,
            repeat: false,
            can_control: true,
            queue: Vec::new(),
            playing: None,
            eq_on: false,
            eq_bands: [0.0; 10],
            eq_preamp: 0.0,
            eq_presets: Vec::new(),
            eq_preset: None,
            effect: 0,
        }
    }
}

impl Deck {
    pub fn status(&self) -> &'static str {
        match self.state {
            PlayState::Playing => "Playing",
            PlayState::Paused => "Paused",
            PlayState::Buffering => "Buffering",
            PlayState::Stopped => {
                if self.song.is_some() {
                    "Stopped"
                } else {
                    "Ready"
                }
            }
        }
    }

    pub fn open_state(&self) -> i32 {
        if self.song.is_some() {
            OPEN_MEDIA_OPEN
        } else {
            OPEN_NO_MEDIA
        }
    }

    pub fn available(&self, name: &str) -> bool {
        let on = self.song.is_some() && self.can_control;
        let sounding = matches!(self.state, PlayState::Playing | PlayState::Buffering);
        match name.to_ascii_lowercase().as_str() {
            "play" => on && !sounding,
            "pause" => on && sounding,
            "stop" => on && self.state != PlayState::Stopped,
            "next" | "previous" => on,
            "fastforward" | "fastreverse" => on && sounding,
            "currentposition" | "currentitem" => self.song.is_some(),
            _ => false,
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub enum Command {
    Play,
    Pause,
    Stop,
    Next,
    Previous,
    Seek(u32),
    SeekBy(i64),
    SetVolume(u8),
    PreviewVolume(u8),
    SetMute(bool),
    SetBalance(i32),
    SetShuffle(bool),
    SetRepeat(bool),
    PlayQueued(usize),
    SetEqBand(usize, f32),
    SetEqPreamp(f32),
    SetEqOn(bool),
    SetEqPreset(usize),
    ResetEq,
    Effect(i32),
    BackToMain,
    PlaySound(String),
    OpenFile,
    PlayList(Vec<String>, usize),
}

pub fn clock(seconds: f64) -> String {
    let total = seconds.max(0.0) as u64;
    let (hours, minutes, seconds) = (total / 3600, total / 60 % 60, total % 60);
    if hours > 0 {
        format!("{hours:02}:{minutes:02}:{seconds:02}")
    } else {
        format!("{minutes:02}:{seconds:02}")
    }
}
