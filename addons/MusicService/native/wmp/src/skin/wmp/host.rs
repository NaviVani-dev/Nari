use std::collections::HashMap;
use std::sync::Arc;

use super::deck::{Command, Deck, PlayState, Song, clock};
use super::live::{
    ELEMENT_BASE, Edge, Element, ElementId, Kind, ViewState, WindowCommand, number_of, text_of,
    truthy,
};
use super::paint::{Measure, font_of};
use crate::skin::script::{Host, HostId, Value};

const PLAYER: HostId = 1;
const CONTROLS: HostId = 2;
const SETTINGS: HostId = 3;
const MEDIA: HostId = 4;
const PLAYLIST: HostId = 5;
const NETWORK: HostId = 6;
const THEME: HostId = 7;
const MEDIACENTER: HostId = 8;
const CDROMS: HostId = 9;
const EVENT: HostId = 10;
const NOTHING: HostId = 11;
const COLLECTION: HostId = 12;
const ERROR: HostId = 13;
const SONG: HostId = 1 << 32;
const LIST: HostId = 1 << 34;
const ITEM: HostId = 1 << 36;
const LIST_LIMIT: usize = 256;

const CONSTANTS: &[(&str, i32)] = &[
    ("psUndefined", 0),
    ("psStopped", 1),
    ("psPaused", 2),
    ("psPlaying", 3),
    ("psScanForward", 4),
    ("psScanReverse", 5),
    ("psBuffering", 6),
    ("psWaiting", 7),
    ("psMediaEnded", 8),
    ("psTransitioning", 9),
    ("psReady", 10),
    ("psReconnecting", 11),
    ("osUndefined", 0),
    ("osPlaylistChanging", 1),
    ("osPlaylistLocating", 2),
    ("osPlaylistConnecting", 3),
    ("osPlaylistLoading", 4),
    ("osPlaylistOpening", 5),
    ("osPlaylistOpenNoMedia", 6),
    ("osPlaylistChanged", 7),
    ("osMediaChanging", 8),
    ("osMediaLocating", 9),
    ("osMediaConnecting", 10),
    ("osMediaLoading", 11),
    ("osMediaOpening", 12),
    ("osMediaOpen", 13),
    ("osBeginCodecAcquisition", 14),
    ("osEndCodecAcquisition", 15),
    ("osBeginLicenseAcquisition", 16),
    ("osEndLicenseAcquisition", 17),
    ("osBeginIndividualization", 18),
    ("osEndIndividualization", 19),
    ("osMediaWaiting", 20),
    ("osOpeningUnknownURL", 21),
];

const ATOMS: &[&str] = &[
    "title",
    "author",
    "wm/albumtitle",
    "wm/albumartist",
    "duration",
    "sourceurl",
    "bitrate",
];

pub const EFFECTS: &[&str] = &["Bars", "Sound Wave", "None"];

#[derive(Clone, Debug, PartialEq)]
pub enum ViewRequest {
    Open(String),
    CloseNamed(String),
    Close(u32),
    Switch(u32, String),
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct EventInfo {
    pub x: f64,
    pub y: f64,
    pub offset_x: f64,
    pub offset_y: f64,
    pub key_code: f64,
    pub button: f64,
    pub shift: bool,
    pub ctrl: bool,
    pub alt: bool,
    pub source: Option<ElementId>,
}

pub struct Shared {
    pub deck: Deck,
    pub prefs: HashMap<String, String>,
    pub prefs_changed: bool,
    pub commands: Vec<Command>,
    pub requests: Vec<ViewRequest>,
    pub event: EventInfo,
    pub mediacenter: HashMap<String, Value>,
    pub measure: Arc<Measure>,
    pub title: String,
    pub author: String,
    pub current_view: String,
    pub library: Vec<Song>,
    pub lists: Vec<Vec<Song>>,
}

pub struct Bridge<'a> {
    pub view: &'a mut ViewState,
    pub shared: &'a mut Shared,
}

fn number(value: f64) -> Value {
    Value::Number(value)
}

fn text(value: &str) -> Value {
    Value::Str(value.into())
}

fn arg_text(args: &[Value], at: usize) -> String {
    args.get(at).map(text_of).unwrap_or_default()
}

fn arg_number(args: &[Value], at: usize) -> f64 {
    args.get(at).map_or(0.0, number_of)
}

fn preference_text(value: &Value) -> String {
    match value {
        Value::Bool(true) => "True".into(),
        Value::Bool(false) => "False".into(),
        other => text_of(other),
    }
}

fn song_info(song: Option<&Song>, bitrate: u32, name: &str) -> Value {
    let Some(song) = song else {
        return text("");
    };
    match name.to_ascii_lowercase().as_str() {
        "title" | "name" => text(&song.title),
        "author" | "artist" | "displayartist" | "wm/albumartist" => text(&song.artist),
        "wm/albumtitle" | "album" => text(&song.album),
        "sourceurl" => text(&song.uri),
        "duration" => number(song.duration_s),
        "durationstring" => text(&clock(song.duration_s)),
        "bitrate" => number(f64::from(bitrate)),
        "mediatype" => text("audio"),
        _ => text(""),
    }
}

impl Bridge<'_> {
    fn deck(&self) -> &Deck {
        &self.shared.deck
    }

    fn command(&mut self, command: Command) {
        self.shared.commands.push(command);
    }

    fn list(&self, at: usize) -> &[Song] {
        self.shared.lists.get(at).map_or(&[], Vec::as_slice)
    }

    fn new_list(&mut self, songs: Vec<Song>) -> Value {
        if self.shared.lists.len() >= LIST_LIMIT {
            self.shared.lists.clear();
        }
        self.shared.lists.push(songs);
        Value::Host(LIST + (self.shared.lists.len() - 1) as u64)
    }

    fn song(&self, object: HostId) -> Option<&Song> {
        if object >= ITEM {
            let at = object - ITEM;
            self.shared.lists.get((at >> 24) as usize).and_then(|list| list.get((at & 0xFF_FFFF) as usize))
        } else if object >= SONG {
            self.deck().queue.get((object - SONG) as usize)
        } else {
            self.deck().song.as_ref()
        }
    }

    fn media_get(&self, object: HostId, name: &str) -> Value {
        let song = self.song(object);
        match name {
            "imagesourcewidth" | "imagesourceheight" | "markercount" => number(0.0),
            "attributecount" => number(ATOMS.len() as f64),
            _ => song_info(song, self.deck().bitrate, name),
        }
    }

    fn player_get(&self, name: &str) -> Value {
        let deck = self.deck();
        match name {
            "controls" => Value::Host(CONTROLS),
            "settings" => Value::Host(SETTINGS),
            "currentmedia" => Value::Host(MEDIA),
            "currentplaylist" => Value::Host(PLAYLIST),
            "network" => Value::Host(NETWORK),
            "cdromcollection" => Value::Host(CDROMS),
            "playlistcollection" | "mediacollection" => Value::Host(COLLECTION),
            "dvd" | "closedcaption" => Value::Host(NOTHING),
            "error" => Value::Host(ERROR),
            "playstate" => number(f64::from(deck.state as i32)),
            "openstate" => number(f64::from(deck.open_state())),
            "status" => text(deck.status()),
            "url" => text(deck.song.as_ref().map_or("", |song| song.uri.as_str())),
            "isonline" => Value::Bool(true),
            "versioninfo" => text("11.0.5721.5262"),
            "fullscreen" => Value::Bool(false),
            _ => Value::Undefined,
        }
    }

    fn controls_get(&self, name: &str) -> Value {
        let deck = self.deck();
        match name {
            "currentposition" => number(deck.position_s),
            "currentpositionstring" => text(&clock(deck.position_s)),
            "currentitem" => Value::Host(MEDIA),
            _ => Value::Undefined,
        }
    }

    fn settings_get(&self, name: &str) -> Value {
        let deck = self.deck();
        match name {
            "volume" => number(f64::from(deck.volume)),
            "mute" => Value::Bool(deck.mute),
            "balance" => number(f64::from(deck.balance)),
            "autostart" | "invokeurls" => Value::Bool(true),
            "enableerrordialogs" => Value::Bool(false),
            "playcount" => number(1.0),
            "rate" => number(1.0),
            _ => Value::Undefined,
        }
    }

    fn network_get(&self, name: &str) -> Value {
        let bitrate = f64::from(self.deck().bitrate);
        match name {
            "bandwidth" | "bitrate" | "maxbitrate" | "maxbandwidth" => number(bitrate),
            "bufferingprogress" | "downloadprogress" | "receptionquality" => number(100.0),
            "sourceprotocol" => text("https"),
            _ => number(0.0),
        }
    }

    fn view_get(&self, element: &Element, name: &str) -> Option<Value> {
        Some(match name {
            "minwidth" | "minheight" | "maxwidth" | "maxheight" => number(element.num(name, 0.0)),
            "timerinterval" => number(element.num(name, 1000.0)),
            "titlebar" => Value::Bool(element.flag("titlebar", true)),
            "resizable" => Value::Bool(element.flag("resizable", element.flag("titlebar", true))),
            "focusobjectid" => text(
                self.view
                    .focus
                    .and_then(|id| self.view.elements[id].id.as_deref())
                    .unwrap_or(""),
            ),
            _ => return None,
        })
    }

    fn effects_get(&self, name: &str) -> Option<Value> {
        let effect = self.deck().effect.min(EFFECTS.len() - 1);
        Some(match name {
            "currenteffecttype" | "currenteffecttitle" | "currentpresettitle" => {
                text(EFFECTS[effect])
            }
            "currentpreset" => number(0.0),
            "effectcount" => number(EFFECTS.len() as f64),
            "currenteffectpresetcount" => number(1.0),
            "effectcangofullscreen" | "effecthaspropertypage" | "fullscreen" => Value::Bool(false),
            _ => return None,
        })
    }

    fn equalizer_get(&self, element: &Element, name: &str) -> Option<Value> {
        let deck = self.deck();
        if let Some(band) = name.strip_prefix("gainlevel")
            && let Ok(band) = band.parse::<usize>()
        {
            return Some(number(f64::from(
                *deck.eq_bands.get(band.wrapping_sub(1)).unwrap_or(&0.0),
            )));
        }
        Some(match name {
            "bands" => number(10.0),
            "preamp" => number(f64::from(deck.eq_preamp)),
            "bypass" => Value::Bool(!deck.eq_on),
            "enabled" | "enable" => Value::Bool(deck.eq_on),
            "presetcount" => number(deck.eq_presets.len() as f64),
            "currentpreset" => number(deck.eq_preset.map_or(-1.0, |preset| preset as f64)),
            "currentpresettitle" => text(
                deck.eq_preset
                    .and_then(|preset| deck.eq_presets.get(preset))
                    .map_or("Custom", String::as_str),
            ),
            "speakersize" => number(element.num(name, 1.0)),
            "currentspeakername" => text("Normal Speakers"),
            "enhancedaudio" | "crossfade" | "normalization" | "enablesplinetension" => {
                Value::Bool(element.flag(name, false))
            }
            "truebasslevel" | "trubasslevel" | "wowlevel" => number(element.num(name, 50.0)),
            _ => return None,
        })
    }

    fn element_get(&self, id: ElementId, name: &str) -> Value {
        let Some(element) = self.view.elements.get(id) else {
            return Value::Undefined;
        };
        match name {
            "left" => return number(element.left),
            "top" => return number(element.top),
            "width" => return number(self.text_size(id).map_or(element.width, |size| size.0)),
            "height" => return number(self.text_size(id).map_or(element.height, |size| size.1)),
            "visible" => return Value::Bool(element.visible),
            "enabled" => return Value::Bool(element.enabled),
            "zindex" => return number(f64::from(element.z)),
            "alphablend" => return number(element.alpha),
            "id" => return text(element.id.as_deref().unwrap_or("")),
            "elementtype" => return text(element.tag),
            "textwidth" => {
                let (size, bold, .., mono) = font_of(element);
                let value = element.props.get("value").map(text_of).unwrap_or_default();
                return number(f64::from((self.shared.measure)(&value, size, bold, mono)));
            }
            "down" | "sticky" => return Value::Bool(element.flag(name, false)),
            _ => {}
        }
        let special = match element.kind {
            Kind::View => self.view_get(element, name),
            Kind::Effects => self.effects_get(name),
            Kind::Equalizer => self.equalizer_get(element, name),
            Kind::ListBox | Kind::Playlist => match name {
                "itemcount" => Some(number(if element.kind == Kind::Playlist && !element.flag("custom", false) {
                    self.deck().queue.len() as f64
                } else {
                    element.items.len() as f64
                })),
                "selecteditem" => Some(number(element.selected.map_or(-1.0, |at| at as f64))),
                "firstvisibleitem" => Some(number(element.scroll)),
                _ => None,
            },
            Kind::Slider | Kind::CustomSlider => match name {
                "value" => Some(number(element.num("value", element.num("min", 0.0)))),
                "min" => Some(number(element.num("min", 0.0))),
                "max" => Some(number(element.num("max", 100.0))),
                _ => None,
            },
            Kind::VideoSettings => match name {
                "brightness" | "contrast" | "hue" | "saturation" => {
                    Some(number(element.num(name, 0.0)))
                }
                _ => None,
            },
            _ => None,
        };
        special
            .or_else(|| element.props.get(name).cloned())
            .unwrap_or(Value::Undefined)
    }

    fn text_size(&self, id: ElementId) -> Option<(f64, f64)> {
        let element = &self.view.elements[id];
        if element.kind != Kind::Text || !(element.auto_width || element.auto_height) {
            return None;
        }
        let (size, bold, .., mono) = font_of(element);
        let value = element.props.get("value").map(text_of).unwrap_or_default();
        let width = if element.auto_width {
            f64::from((self.shared.measure)(&value, size, bold, mono)).ceil() + 1.0
        } else {
            element.width
        };
        let height = if element.auto_height {
            super::paint::line_height(size)
        } else {
            element.height
        };
        Some((width, height))
    }

    fn element_set(&mut self, id: ElementId, name: &str, value: Value) {
        let Some(element) = self.view.elements.get(id) else {
            return;
        };
        if element.kind == Kind::Playlist
            && name == "playlist"
            && let Value::Host(list) = value
            && (LIST..ITEM).contains(&list)
        {
            let songs = self.list((list - LIST) as usize).to_vec();
            let element = &mut self.view.elements[id];
            element.items = songs.iter().map(|song| if song.artist.is_empty() { song.title.clone() } else { format!("{} - {}", song.artist, song.title) }).collect();
            element.props.insert("uris".into(), Value::Str(songs.iter().map(|song| song.uri.as_str()).collect::<Vec<_>>().join("\n").as_str().into()));
            element.props.insert("custom".into(), Value::Bool(true));
            element.selected = None;
            element.scroll = 0.0;
            self.view.changed = true;
            return;
        }
        match element.kind {
            Kind::Equalizer => {
                if let Some(band) = name.strip_prefix("gainlevel")
                    && let Ok(band) = band.parse::<usize>()
                    && (1..=10).contains(&band)
                {
                    let gain = number_of(&value) as f32;
                    let deck = &mut self.shared.deck;
                    if (deck.eq_bands[band - 1] - gain).abs() > 0.01 {
                        deck.eq_bands[band - 1] = gain;
                        deck.eq_preset = None;
                        if !deck.eq_on {
                            deck.eq_on = true;
                            self.command(Command::SetEqOn(true));
                        }
                        self.command(Command::SetEqBand(band - 1, gain));
                    }
                    return;
                }
                match name {
                    "preamp" => {
                        let gain = number_of(&value) as f32;
                        if (self.shared.deck.eq_preamp - gain).abs() > 0.01 {
                            self.shared.deck.eq_preamp = gain;
                            self.command(Command::SetEqPreamp(gain));
                        }
                        return;
                    }
                    "bypass" | "enabled" | "enable" => {
                        let on = truthy(&value) != (name == "bypass");
                        if self.shared.deck.eq_on != on {
                            self.shared.deck.eq_on = on;
                            self.command(Command::SetEqOn(on));
                        }
                        return;
                    }
                    "currentpreset" => {
                        let preset = number_of(&value);
                        if preset >= 0.0 {
                            self.eq_preset(preset as usize);
                        }
                        return;
                    }
                    _ => {}
                }
            }
            Kind::Effects if name == "currenteffecttype" || name == "currentpreset" => {
                self.view.store(id, &format!("skin-{name}"), value);
                return;
            }
            Kind::ListBox | Kind::Playlist if name == "selecteditem" => {
                let at = number_of(&value);
                self.view.elements[id].selected = (at >= 0.0).then_some(at as usize);
                self.view.changed = true;
                self.view.notify(id, "selecteditem");
                return;
            }
            Kind::ListBox | Kind::Playlist if name == "firstvisibleitem" => {
                self.view.elements[id].scroll = number_of(&value).max(0.0);
                self.view.changed = true;
                return;
            }
            Kind::View if name == "timerinterval" => {
                self.view.set(id, name, value);
                self.view.timer_due = None;
                return;
            }
            _ => {}
        }
        self.view.set(id, name, value);
    }

    fn eq_preset(&mut self, preset: usize) {
        if preset < self.shared.deck.eq_presets.len() {
            self.shared.deck.eq_preset = Some(preset);
            self.command(Command::SetEqPreset(preset));
        }
    }

    fn element_call(&mut self, id: ElementId, name: &str, args: &[Value]) -> Result<Value, String> {
        let Some(element) = self.view.elements.get(id) else {
            return Ok(Value::Undefined);
        };
        let kind = element.kind;
        match name {
            "moveto" | "slideto" => {
                let to = (arg_number(args, 0), arg_number(args, 1));
                self.view
                    .start_move(id, to, None, arg_number(args, 2), name == "slideto");
                return Ok(Value::Undefined);
            }
            "movesizeto" => {
                let to = (arg_number(args, 0), arg_number(args, 1));
                let size = (arg_number(args, 2), arg_number(args, 3));
                let eased = args.get(5).is_some_and(truthy);
                self.view
                    .start_move(id, to, Some(size), arg_number(args, 4), eased);
                return Ok(Value::Undefined);
            }
            "alphablendto" => {
                self.view
                    .start_fade(id, arg_number(args, 0), arg_number(args, 1));
                return Ok(Value::Undefined);
            }
            _ => {}
        }
        match kind {
            Kind::View => match name {
                "close" => {
                    self.shared.requests.push(ViewRequest::Close(self.view.key));
                    return Ok(Value::Undefined);
                }
                "minimize" => {
                    self.view.window.push(WindowCommand::Minimize);
                    return Ok(Value::Undefined);
                }
                "maximize" => {
                    self.view.window.push(WindowCommand::Maximize);
                    return Ok(Value::Undefined);
                }
                "restore" => {
                    self.view.window.push(WindowCommand::Restore);
                    return Ok(Value::Undefined);
                }
                "returntomediacenter" => {
                    self.command(Command::BackToMain);
                    return Ok(Value::Undefined);
                }
                "size" => {
                    let edge = match arg_text(args, 0).to_ascii_lowercase().as_str() {
                        "top" => Edge::North,
                        "bottom" => Edge::South,
                        "left" => Edge::West,
                        "right" => Edge::East,
                        "topleft" => Edge::NorthWest,
                        "topright" => Edge::NorthEast,
                        "bottomleft" => Edge::SouthWest,
                        _ => Edge::SouthEast,
                    };
                    self.view.window.push(WindowCommand::Resize(edge));
                    self.view.resizing = true;
                    return Ok(Value::Undefined);
                }
                _ => {}
            },
            Kind::Effects => match name {
                "next" | "nextpreset" | "nexteffect" => {
                    self.command(Command::Effect(1));
                    return Ok(Value::Undefined);
                }
                "previous" | "previouspreset" | "previouseffect" => {
                    self.command(Command::Effect(-1));
                    return Ok(Value::Undefined);
                }
                "effecttitle" | "effecttype" => {
                    let at = arg_number(args, 0) as usize;
                    return Ok(text(EFFECTS.get(at).copied().unwrap_or("")));
                }
                _ => {}
            },
            Kind::Equalizer => match name {
                "reset" => {
                    self.shared.deck.eq_bands = [0.0; 10];
                    self.shared.deck.eq_preset = None;
                    self.command(Command::ResetEq);
                    return Ok(Value::Undefined);
                }
                "gainlevels" => {
                    let band = format!("gainlevel{}", arg_number(args, 0));
                    return Ok(self.element_get(id, &band));
                }
                "presettitle" => {
                    let at = arg_number(args, 0) as usize;
                    let title = self.deck().eq_presets.get(at).cloned().unwrap_or_default();
                    return Ok(text(&title));
                }
                "nextpreset" | "previouspreset" => {
                    let count = self.deck().eq_presets.len();
                    if count > 0 {
                        let current = self.deck().eq_preset.unwrap_or(0);
                        let step = if name == "nextpreset" { 1 } else { count - 1 };
                        self.eq_preset((current + step) % count);
                    }
                    return Ok(Value::Undefined);
                }
                _ => {}
            },
            Kind::ListBox => {
                let element = &mut self.view.elements[id];
                self.view.changed = true;
                let at = arg_number(args, 0) as usize;
                match name {
                    "appenditem" => {
                        if element.items.len() < 65_536 {
                            element.items.push(arg_text(args, 0));
                        }
                        return Ok(Value::Undefined);
                    }
                    "insertitem" => {
                        if element.items.len() < 65_536 {
                            let at = at.min(element.items.len());
                            element.items.insert(at, arg_text(args, 1));
                        }
                        return Ok(Value::Undefined);
                    }
                    "replaceitem" => {
                        if let Some(item) = element.items.get_mut(at) {
                            *item = arg_text(args, 1);
                        }
                        return Ok(Value::Undefined);
                    }
                    "deleteitem" => {
                        if at < element.items.len() {
                            element.items.remove(at);
                        }
                        return Ok(Value::Undefined);
                    }
                    "deleteall" => {
                        element.items.clear();
                        element.selected = None;
                        return Ok(Value::Undefined);
                    }
                    "getitem" => {
                        return Ok(text(element.items.get(at).map_or("", String::as_str)));
                    }
                    "finditem" => {
                        let start = arg_number(args, 0);
                        let wanted = arg_text(args, 1).to_lowercase();
                        let from = if start < 0.0 { 0 } else { start as usize + 1 };
                        let found = element
                            .items
                            .iter()
                            .enumerate()
                            .skip(from)
                            .find(|(_, item)| item.to_lowercase().contains(&wanted))
                            .map_or(-1.0, |(at, _)| at as f64);
                        return Ok(number(found));
                    }
                    "getnextselecteditem" => {
                        let start = arg_number(args, 0);
                        let found = element.selected.map_or(-1.0, |selected| {
                            if (selected as f64) > start {
                                selected as f64
                            } else {
                                -1.0
                            }
                        });
                        return Ok(number(found));
                    }
                    "setselectedstate" => {
                        element.selected = args.get(1).is_some_and(truthy).then_some(at);
                        return Ok(Value::Undefined);
                    }
                    "show" => {
                        element.visible = true;
                        element.popped = element.flag("popup", false);
                        return Ok(Value::Undefined);
                    }
                    "dismiss" => {
                        element.popped = false;
                        element.visible = !element.flag("popup", false);
                        return Ok(Value::Undefined);
                    }
                    _ => {}
                }
            }
            Kind::VideoSettings if name == "reset" => {
                for setting in ["brightness", "contrast", "hue", "saturation"] {
                    self.view.set(id, setting, number(0.0));
                }
                return Ok(Value::Undefined);
            }
            _ => {}
        }
        if name == "click" {
            self.view.fire(id, "onclick", Vec::new());
            return Ok(Value::Undefined);
        }
        Ok(self.element_get(id, name))
    }
}

impl Host for Bridge<'_> {
    fn global(&mut self, name: &str) -> Option<Value> {
        let lower = name.to_ascii_lowercase();
        match lower.as_str() {
            "player" => return Some(Value::Host(PLAYER)),
            "theme" => return Some(Value::Host(THEME)),
            "mediacenter" => return Some(Value::Host(MEDIACENTER)),
            "event" => return Some(Value::Host(EVENT)),
            "view" => return Some(Value::Host(Element::host(self.view.root))),
            _ => {}
        }
        if let Some(id) = self.view.ids.get(&lower) {
            return Some(Value::Host(Element::host(*id)));
        }
        CONSTANTS
            .iter()
            .find(|(constant, _)| constant.eq_ignore_ascii_case(name))
            .map(|(_, value)| number(f64::from(*value)))
    }

    fn has(&mut self, object: HostId, name: &str) -> bool {
        let lower = name.to_ascii_lowercase();
        if object == PLAYER {
            return !matches!(self.player_get(&lower), Value::Undefined);
        }
        if object < ELEMENT_BASE {
            return false;
        }
        let id = (object - ELEMENT_BASE) as usize;
        let Some(element) = self.view.elements.get(id) else {
            return false;
        };
        if element.props.contains_key(&lower) {
            return true;
        }
        if matches!(
            lower.as_str(),
            "left"
                | "top"
                | "width"
                | "height"
                | "visible"
                | "enabled"
                | "zindex"
                | "alphablend"
                | "moveto"
                | "slideto"
                | "movesizeto"
                | "alphablendto"
                | "click"
        ) {
            return true;
        }
        match element.kind {
            Kind::Effects => matches!(
                lower.as_str(),
                "next"
                    | "previous"
                    | "nextpreset"
                    | "previouspreset"
                    | "nexteffect"
                    | "previouseffect"
                    | "currenteffecttype"
                    | "currentpreset"
                    | "currentpresettitle"
                    | "currenteffecttitle"
            ),
            Kind::Slider | Kind::CustomSlider => matches!(lower.as_str(), "value" | "min" | "max"),
            Kind::Button | Kind::ButtonElement => matches!(lower.as_str(), "down" | "sticky"),
            Kind::Text | Kind::EditBox => lower == "value",
            Kind::View => matches!(
                lower.as_str(),
                "close" | "minimize" | "maximize" | "restore" | "size" | "returntomediacenter"
            ),
            Kind::Equalizer => lower == "reset" || lower.starts_with("gainlevel"),
            Kind::ListBox => matches!(
                lower.as_str(),
                "show" | "dismiss" | "appenditem" | "deleteall" | "selecteditem" | "itemcount"
            ),
            _ => false,
        }
    }

    fn get(&mut self, object: HostId, name: &str) -> Value {
        let lower = name.to_ascii_lowercase();
        let name = lower.as_str();
        match object {
            object if (ITEM..ELEMENT_BASE).contains(&object) => self.media_get(object, name),
            object if (LIST..ITEM).contains(&object) => match name {
                "count" => number(self.list((object - LIST) as usize).len() as f64),
                "name" => text(""),
                _ => Value::Undefined,
            },
            PLAYER => self.player_get(name),
            CONTROLS => self.controls_get(name),
            SETTINGS => self.settings_get(name),
            MEDIA => self.media_get(object, name),
            NETWORK => self.network_get(name),
            PLAYLIST => match name {
                "count" => number(self.deck().queue.len() as f64),
                "name" => text("Now Playing"),
                "attributecount" => number(0.0),
                _ => Value::Undefined,
            },
            THEME => match name {
                "currentviewid" => text(&self.view.id.clone()),
                "title" => text(&self.shared.title.clone()),
                "author" => text(&self.shared.author.clone()),
                "version" => number(1.0),
                _ => Value::Undefined,
            },
            MEDIACENTER => {
                self.shared
                    .mediacenter
                    .get(name)
                    .cloned()
                    .unwrap_or_else(|| match name {
                        "effecttype" => text(EFFECTS[self.deck().effect.min(EFFECTS.len() - 1)]),
                        "effectpreset" | "videozoom" => {
                            number(if name == "videozoom" { 100.0 } else { 0.0 })
                        }
                        _ => Value::Undefined,
                    })
            }
            CDROMS | COLLECTION => match name {
                "count" => number(0.0),
                _ => Value::Undefined,
            },
            ERROR => match name {
                "errorcount" => number(0.0),
                _ => Value::Undefined,
            },
            EVENT => {
                let event = &self.shared.event;
                match name {
                    "x" | "clientx" | "screenx" => number(event.x),
                    "y" | "clienty" | "screeny" => number(event.y),
                    "offsetx" => number(event.offset_x),
                    "offsety" => number(event.offset_y),
                    "keycode" => number(event.key_code),
                    "button" => number(event.button),
                    "shiftkey" => Value::Bool(event.shift),
                    "ctrlkey" => Value::Bool(event.ctrl),
                    "altkey" => Value::Bool(event.alt),
                    "srcelement" => event
                        .source
                        .map_or(Value::Null, |id| Value::Host(Element::host(id))),
                    "fromelement" | "toelement" => Value::Null,
                    _ => Value::Undefined,
                }
            }
            object if object >= ELEMENT_BASE => {
                self.element_get((object - ELEMENT_BASE) as usize, name)
            }
            object if object >= SONG => self.media_get(object, name),
            _ => Value::Undefined,
        }
    }

    fn set(&mut self, object: HostId, name: &str, value: Value) {
        let lower = name.to_ascii_lowercase();
        let name = lower.as_str();
        match object {
            CONTROLS if name == "currentposition" => {
                let position = number_of(&value).max(0.0);
                if (self.deck().position_s - position).abs() > 0.05 {
                    self.shared.deck.position_s = position;
                    self.command(Command::Seek((position * 1000.0) as u32));
                }
            }
            SETTINGS => match name {
                "volume" => {
                    let volume = number_of(&value).clamp(0.0, 100.0).round() as u8;
                    if self.deck().volume != volume {
                        self.shared.deck.volume = volume;
                        self.command(Command::SetVolume(volume));
                    }
                }
                "mute" => {
                    let mute = truthy(&value);
                    if self.deck().mute != mute {
                        self.shared.deck.mute = mute;
                        self.command(Command::SetMute(mute));
                    }
                }
                "balance" => {
                    let balance = number_of(&value).clamp(-100.0, 100.0).round() as i32;
                    if self.deck().balance != balance {
                        self.shared.deck.balance = balance;
                        self.command(Command::SetBalance(balance));
                    }
                }
                _ => {}
            },
            PLAYER if name == "currentplaylist" => {
                if let Value::Host(list) = value
                    && (LIST..ITEM).contains(&list)
                {
                    let uris = self.list((list - LIST) as usize).iter().map(|song| song.uri.clone()).collect();
                    self.command(Command::PlayList(uris, 0));
                }
            }
            THEME if name == "currentviewid" => {
                self.shared
                    .requests
                    .push(ViewRequest::Switch(self.view.key, text_of(&value)));
            }
            MEDIACENTER => {
                if name == "effecttype" {
                }
                self.shared.mediacenter.insert(name.to_owned(), value);
            }
            object if object >= ELEMENT_BASE => {
                self.element_set((object - ELEMENT_BASE) as usize, name, value);
            }
            _ => {}
        }
    }

    fn call(&mut self, object: HostId, name: &str, args: &[Value]) -> Result<Value, String> {
        let lower = name.to_ascii_lowercase();
        let name = lower.as_str();
        if let Some(property) = name.strip_prefix("set:") {
            if property == "gainlevels" {
                let band = format!("gainlevel{}", arg_number(args, 0));
                let value = args.get(1).cloned().unwrap_or(Value::Undefined);
                self.set(object, &band, value);
                return Ok(Value::Undefined);
            }
            return self.call(object, property, args);
        }
        match object {
            object if (ITEM..ELEMENT_BASE).contains(&object) => self.media_call(object, name, args),
            object if (LIST..ITEM).contains(&object) => {
                let list = (object - LIST) as usize;
                Ok(match name {
                    "item" => {
                        let at = arg_number(args, 0);
                        if at >= 0.0 && (at as usize) < self.list(list).len() {
                            Value::Host(ITEM + ((list as u64) << 24) + at as u64)
                        } else {
                            Value::Host(NOTHING)
                        }
                    }
                    "appenditem" | "insertitem" => {
                        let source = args.get(if name == "insertitem" { 1 } else { 0 });
                        if let Some(Value::Host(item)) = source
                            && let Some(song) = self.song(*item).cloned()
                            && let Some(target) = self.shared.lists.get_mut(list)
                        {
                            target.push(song);
                        }
                        Value::Undefined
                    }
                    "clear" => {
                        if let Some(target) = self.shared.lists.get_mut(list) {
                            target.clear();
                        }
                        Value::Undefined
                    }
                    "getiteminfo" => text(""),
                    _ => Value::Undefined,
                })
            }
            CONTROLS => {
                let sounding =
                    matches!(self.deck().state, PlayState::Playing | PlayState::Buffering);
                match name {
                    "play" => {
                        if !sounding {
                            self.shared.deck.state = PlayState::Playing;
                            self.command(Command::Play);
                        }
                    }
                    "pause" => {
                        if sounding {
                            self.shared.deck.state = PlayState::Paused;
                            self.command(Command::Pause);
                        }
                    }
                    "stop" => {
                        self.shared.deck.state = PlayState::Stopped;
                        self.shared.deck.position_s = 0.0;
                        self.command(Command::Stop);
                    }
                    "next" => self.command(Command::Next),
                    "previous" => self.command(Command::Previous),
                    "fastforward" => self.command(Command::SeekBy(10_000)),
                    "fastreverse" => self.command(Command::SeekBy(-10_000)),
                    "isavailable" => {
                        return Ok(Value::Bool(self.deck().available(&arg_text(args, 0))));
                    }
                    "playitem" => {
                        if let Some(Value::Host(item)) = args.first()
                            && (ITEM..ELEMENT_BASE).contains(item)
                        {
                            let list = ((*item - ITEM) >> 24) as usize;
                            let uris = self.list(list).iter().map(|song| song.uri.clone()).collect();
                            self.command(Command::PlayList(uris, ((*item - ITEM) & 0xFF_FFFF) as usize));
                        } else if let Some(Value::Host(item)) = args.first()
                            && *item >= SONG
                            && *item < ELEMENT_BASE
                        {
                            self.command(Command::PlayQueued((*item - SONG) as usize));
                        }
                    }
                    _ => return Ok(self.controls_get(name)),
                }
                Ok(Value::Undefined)
            }
            SETTINGS => match name {
                "getmode" => Ok(Value::Bool(
                    match arg_text(args, 0).to_ascii_lowercase().as_str() {
                        "shuffle" => self.deck().shuffle,
                        "loop" => self.deck().repeat,
                        "autorewind" => true,
                        _ => false,
                    },
                )),
                "setmode" => {
                    let on = args.get(1).is_some_and(truthy);
                    match arg_text(args, 0).to_ascii_lowercase().as_str() {
                        "shuffle" if self.deck().shuffle != on => {
                            self.shared.deck.shuffle = on;
                            self.command(Command::SetShuffle(on));
                        }
                        "loop" if self.deck().repeat != on => {
                            self.shared.deck.repeat = on;
                            self.command(Command::SetRepeat(on));
                        }
                        _ => {}
                    }
                    Ok(Value::Undefined)
                }
                "isavailable" => Ok(Value::Bool(true)),
                _ => Ok(self.settings_get(name)),
            },
            MEDIA => self.media_call(object, name, args),
            PLAYLIST => match name {
                "item" => {
                    let at = arg_number(args, 0);
                    let row = at as usize;
                    Ok(if at >= 0.0 && row < self.deck().queue.len() {
                        Value::Host(SONG + row as u64)
                    } else {
                        Value::Host(NOTHING)
                    })
                }
                "getiteminfo" => Ok(text("")),
                _ => Ok(Value::Undefined),
            },
            PLAYER => match name {
                "launchurl" | "close" | "openplayer" => {
                    Ok(Value::Undefined)
                }
                "newplaylist" => Ok(self.new_list(Vec::new())),
                "newmedia" => Ok(Value::Host(NOTHING)),
                _ => Ok(self.player_get(name)),
            },
            THEME => Ok(self.theme_call(name, args)),
            COLLECTION if matches!(name, "getall" | "getbyname" | "getbyauthor" | "getbyalbum" | "getbyattribute" | "getbyattributeandmediatype" | "getbygenre") => {
                let wanted = arg_text(args, if name.starts_with("getbyattribute") { 1 } else { 0 }).to_lowercase();
                let attribute = arg_text(args, 0).to_lowercase();
                let songs: Vec<Song> = self.shared.library.iter().filter(|song| {
                    let field = match name {
                        "getbyname" => &song.title,
                        "getbyauthor" => &song.artist,
                        "getbyalbum" => &song.album,
                        "getbyattribute" | "getbyattributeandmediatype" if attribute == "mediatype" => return wanted == "audio",
                        "getbyattribute" | "getbyattributeandmediatype" => match attribute.as_str() {
                            "title" | "name" => &song.title,
                            "author" | "wm/albumartist" => &song.artist,
                            "wm/albumtitle" | "album" => &song.album,
                            _ => return false,
                        },
                        "getall" => return true,
                        _ => return false,
                    };
                    field.to_lowercase() == wanted
                }).cloned().collect();
                Ok(self.new_list(songs))
            }
            CDROMS | COLLECTION => Ok(match name {
                "getbyname"
                | "getbyattribute"
                | "getall"
                | "getbyauthor"
                | "getbyalbum"
                | "getbygenre"
                | "item"
                | "newplaylist"
                | "createquery"
                | "getbyattributeandmediatype" => Value::Host(COLLECTION),
                "getmediaatom" => {
                    let wanted = arg_text(args, 0).to_ascii_lowercase();
                    number(
                        ATOMS
                            .iter()
                            .position(|atom| *atom == wanted)
                            .map_or(-1.0, |at| at as f64),
                    )
                }
                _ => Value::Undefined,
            }),
            MEDIACENTER => Ok(self.get(MEDIACENTER, name)),
            object if object >= ELEMENT_BASE => {
                self.element_call((object - ELEMENT_BASE) as usize, name, args)
            }
            object if object >= SONG => self.media_call(object, name, args),
            NOTHING if name == "isavailable" => Ok(Value::Bool(false)),
            _ => Ok(Value::Undefined),
        }
    }

    fn index(&mut self, object: HostId, index: f64) -> Value {
        if object == PLAYLIST && index >= 0.0 && (index as usize) < self.deck().queue.len() {
            return Value::Host(SONG + index as u64);
        }
        Value::Undefined
    }
}

impl Bridge<'_> {
    fn media_call(&mut self, object: HostId, name: &str, args: &[Value]) -> Result<Value, String> {
        let song = self.song(object);
        let bitrate = self.deck().bitrate;
        Ok(match name {
            "getiteminfo" | "getiteminfobytype" => {
                text(&text_of(&song_info(song, bitrate, &arg_text(args, 0))))
            }
            "getiteminfobyatom" => {
                let atom = arg_number(args, 0);
                let name = if atom >= 0.0 {
                    ATOMS.get(atom as usize).copied().unwrap_or("")
                } else {
                    ""
                };
                text(&text_of(&song_info(song, bitrate, name)))
            }
            "getattributename" => text(
                ATOMS
                    .get(arg_number(args, 0) as usize)
                    .copied()
                    .unwrap_or(""),
            ),
            "isidentical" | "ismemberof" | "isreadonlyitem" => Value::Bool(false),
            "setiteminfo" => Value::Undefined,
            _ => self.media_get(object, name),
        })
    }

    fn theme_call(&mut self, name: &str, args: &[Value]) -> Value {
        match name {
            "openview" | "openviewrelative" => {
                self.shared
                    .requests
                    .push(ViewRequest::Open(arg_text(args, 0)));
            }
            "closeview" => {
                self.shared
                    .requests
                    .push(ViewRequest::CloseNamed(arg_text(args, 0)));
            }
            "savepreference" => {
                let key = arg_text(args, 0).to_lowercase();
                let value = args.get(1).map(preference_text).unwrap_or_default();
                if self.shared.prefs.len() < 4096 && value.len() < 4096 && key.len() < 256 {
                    self.shared.prefs.insert(key, value);
                    self.shared.prefs_changed = true;
                }
            }
            "loadpreference" => {
                let key = arg_text(args, 0).to_lowercase();
                return text(self.shared.prefs.get(&key).map_or("--", String::as_str));
            }
            "loadstring" => {
                return text(if arg_text(args, 0).ends_with("#2063") {
                    "Disconnected"
                } else {
                    ""
                });
            }
            "logstring" => {}
            "opendialog" => {
                self.command(Command::OpenFile);
                return text("");
            }
            "playsound" => self.command(Command::PlaySound(super::file_name(&arg_text(args, 0)))),
            _ => {}
        }
        Value::Undefined
    }
}
