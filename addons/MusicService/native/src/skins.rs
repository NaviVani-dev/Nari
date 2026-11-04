use std::collections::HashMap;
use std::hash::{DefaultHasher, Hash, Hasher};
use std::path::Path;
use std::sync::Arc;
use std::time::Instant;

use godot::prelude::*;
use nari_wmp::skin::wmp::deck::{Command, Deck, PlayState, Song};
use nari_wmp::skin::wmp::live::{Edge, WindowCommand};
use nari_wmp::skin::wmp::paint::{Measure, Paint};
use nari_wmp::skin::wmp::picture::Picture;
use nari_wmp::skin::wmp::runtime::{Input, Modifiers, Runtime};
use nari_wmp::skin::wmp::{Box2, Wmp};

const FIRST: usize = 32;
const LAST: usize = 127;

#[derive(GodotClass)]
#[class(base = RefCounted, init)]
pub struct WmpSkin {
    wmp: Option<Arc<Wmp>>,
    runtime: Option<Runtime>,
    widths: [Vec<f32>; 3],
    pictures: HashMap<i64, Arc<Picture>>,
    due: HashMap<u32, Instant>,
    shapes: HashMap<u32, PackedVector2Array>,
}

fn value_number(value: &Variant) -> f64 {
    value.try_to::<f64>().ok().or_else(|| value.try_to::<i64>().ok().map(|whole| whole as f64)).or_else(|| value.try_to::<bool>().ok().map(f64::from)).unwrap_or_default()
}

fn number(dict: &VarDictionary, key: &str) -> f64 {
    dict.get(key).map(|value| value_number(&value)).unwrap_or_default()
}

fn flag(dict: &VarDictionary, key: &str) -> bool {
    dict.get(key).and_then(|value| value.try_to::<bool>().ok()).unwrap_or_default()
}

fn text(dict: &VarDictionary, key: &str) -> String {
    dict.get(key).map(|value| value.to_string()).unwrap_or_default()
}

fn song(dict: &VarDictionary) -> Song {
    Song { title: text(dict, "title"), artist: text(dict, "artist"), album: text(dict, "album"), uri: text(dict, "uri"), duration_s: number(dict, "duration_s") }
}

fn deck(dict: &VarDictionary) -> Deck {
    let list = |key: &str| dict.get(key).and_then(|value| value.try_to::<VarArray>().ok()).unwrap_or_default();
    let mut bands = [0.0; 10];
    for (index, value) in list("eq_bands").iter_shared().take(10).enumerate() {
        bands[index] = value_number(&value) as f32;
    }
    let index = |key: &str| usize::try_from(number(dict, key) as i64).ok();
    Deck {
        state: match number(dict, "state") as i64 {
            2 => PlayState::Paused,
            3 => PlayState::Playing,
            6 => PlayState::Buffering,
            _ => PlayState::Stopped,
        },
        song: dict.get("song").and_then(|value| value.try_to::<VarDictionary>().ok()).filter(|song| !song.is_empty()).map(|value| song(&value)),
        position_s: number(dict, "position_s"),
        bitrate: number(dict, "bitrate") as u32,
        volume: number(dict, "volume").clamp(0.0, 100.0) as u8,
        mute: flag(dict, "mute"),
        balance: number(dict, "balance") as i32,
        shuffle: flag(dict, "shuffle"),
        repeat: flag(dict, "repeat"),
        can_control: true,
        queue: list("queue").iter_shared().filter_map(|value| value.try_to::<VarDictionary>().ok()).map(|value| song(&value)).collect(),
        playing: index("playing"),
        eq_on: flag(dict, "eq_on"),
        eq_bands: bands,
        eq_preamp: number(dict, "eq_preamp") as f32,
        eq_presets: list("eq_presets").iter_shared().map(|value| value.to_string()).collect(),
        eq_preset: index("eq_preset"),
        effect: number(dict, "effect").max(0.0) as usize,
    }
}

fn outline(boxes: &[Box2], width: i32, height: i32) -> PackedVector2Array {
    let (width, height) = (width.max(1) as usize, height.max(1) as usize);
    let mut mask = vec![false; width * height];
    for area in boxes {
        for y in area.y.max(0) as usize..(area.y + area.height).clamp(0, height as i32) as usize {
            for x in area.x.max(0) as usize..(area.x + area.width).clamp(0, width as i32) as usize {
                mask[y * width + x] = true;
            }
        }
    }
    if mask.iter().all(|solid| *solid) {
        return PackedVector2Array::new();
    }
    let mut open: Vec<(usize, usize, usize)> = Vec::new();
    let mut rects: Vec<(usize, usize, usize, usize)> = Vec::new();
    for y in 0..=height {
        let mut runs = Vec::new();
        if y < height {
            let mut x = 0;
            while x < width {
                if mask[y * width + x] {
                    let start = x;
                    while x < width && mask[y * width + x] {
                        x += 1;
                    }
                    runs.push((start, x));
                } else {
                    x += 1;
                }
            }
        }
        let mut next = Vec::new();
        for (start, end, top) in open.drain(..) {
            if runs.contains(&(start, end)) {
                next.push((start, end, top));
            } else {
                rects.push((start, top, end, y));
            }
        }
        for run in runs {
            if !next.iter().any(|(start, end, _)| (*start, *end) == run) {
                next.push((run.0, run.1, y));
            }
        }
        open = next;
    }
    let mut points = PackedVector2Array::new();
    points.push(Vector2::ZERO);
    for (left, top, right, bottom) in rects {
        let (left, top, right, bottom) = (left as f32, top as f32, right as f32, bottom as f32);
        for point in [(left, top), (right, top), (right, bottom), (left, bottom), (left, top)] {
            points.push(Vector2::new(point.0, point.1));
        }
        points.push(Vector2::ZERO);
    }
    points
}

fn rect(area: Box2) -> Rect2i {
    Rect2i::new(Vector2i::new(area.x, area.y), Vector2i::new(area.width, area.height))
}

fn color(rgb: [u8; 3], alpha: u8) -> Color {
    Color::from_rgba8(rgb[0], rgb[1], rgb[2], alpha)
}

fn command(command: Command) -> VarArray {
    let (name, value): (&str, Variant) = match command {
        Command::Play => ("play", Variant::nil()),
        Command::Pause => ("pause", Variant::nil()),
        Command::Stop => ("stop", Variant::nil()),
        Command::Next => ("next", Variant::nil()),
        Command::Previous => ("previous", Variant::nil()),
        Command::Seek(seconds) => ("seek", seconds.to_variant()),
        Command::SeekBy(milliseconds) => ("seek_by", milliseconds.to_variant()),
        Command::SetVolume(volume) => ("volume", volume.to_variant()),
        Command::PreviewVolume(volume) => ("preview_volume", volume.to_variant()),
        Command::SetMute(mute) => ("mute", mute.to_variant()),
        Command::SetBalance(balance) => ("balance", balance.to_variant()),
        Command::SetShuffle(shuffle) => ("shuffle", shuffle.to_variant()),
        Command::SetRepeat(repeat) => ("repeat", repeat.to_variant()),
        Command::PlayQueued(index) => ("play_queued", (index as i64).to_variant()),
        Command::SetEqBand(band, gain) => ("eq_band", varray![band as i64, gain].to_variant()),
        Command::SetEqPreamp(gain) => ("eq_preamp", gain.to_variant()),
        Command::SetEqOn(on) => ("eq_on", on.to_variant()),
        Command::SetEqPreset(index) => ("eq_preset", (index as i64).to_variant()),
        Command::ResetEq => ("eq_reset", Variant::nil()),
        Command::Effect(step) => ("effect", step.to_variant()),
        Command::BackToMain => ("back", Variant::nil()),
        Command::PlaySound(name) => ("sound", name.to_variant()),
        Command::OpenFile => ("open_file", Variant::nil()),
        Command::PlayList(uris, index) => ("play_list", varray![&uris.iter().map(|uri| uri.to_variant()).collect::<VarArray>(), index as i64].to_variant()),
    };
    varray![name, &value]
}

#[godot_api]
impl WmpSkin {
    #[func]
    fn is_skin(path: GString) -> bool {
        nari_wmp::skin::is_media_player(Path::new(&path.to_string()))
    }

    #[func]
    fn open(&mut self, path: GString) -> bool {
        self.wmp = nari_wmp::skin::load(Path::new(&path.to_string())).map(Arc::new);
        self.wmp.is_some()
    }

    #[func]
    fn title(&self) -> GString {
        GString::from(self.wmp.as_ref().map_or("", |wmp| wmp.title.as_str()))
    }

    #[func]
    fn set_metrics(&mut self, regular: PackedFloat32Array, bold: PackedFloat32Array, mono: PackedFloat32Array) {
        self.widths = [regular.to_vec(), bold.to_vec(), mono.to_vec()];
    }

    #[func]
    fn start(&mut self, name: GString, state: VarDictionary, preferences: VarDictionary) -> bool {
        let Some(wmp) = self.wmp.clone() else { return false };
        let widths = Arc::new(self.widths.clone());
        let measure: Arc<Measure> = Arc::new(move |text: &str, size: f32, bold: bool, mono: bool| {
            let table = &widths[if mono { 2 } else if bold { 1 } else { 0 }];
            let fallback = table.iter().copied().sum::<f32>() / table.len().max(1) as f32;
            text.chars().map(|character| table.get((character as usize).wrapping_sub(FIRST)).copied().filter(|_| (FIRST..LAST).contains(&(character as usize))).unwrap_or(fallback)).sum::<f32>() * size
        });
        let prefs = preferences.iter_shared().map(|(key, value)| (key.to_string(), value.to_string())).collect();
        let mut runtime = Runtime::new(name.to_string(), wmp, deck(&state), prefs, measure, || {});
        runtime.await_window();
        self.runtime = Some(runtime);
        true
    }

    #[func]
    fn tick(&mut self, state: VarDictionary) -> VarArray {
        let Some(runtime) = self.runtime.as_mut() else { return VarArray::new() };
        runtime.tick(deck(&state), Instant::now()).into_iter().map(|item| command(item).to_variant()).collect()
    }

    #[func]
    fn views(&self) -> VarArray {
        let Some(runtime) = self.runtime.as_ref() else { return VarArray::new() };
        let primary = runtime.primary();
        runtime.views.iter().enumerate().filter(|(_, view)| view.state.windowed() && !view.state.closing).map(|(index, view)| {
            let (width, height) = view.state.size();
            let mut info = VarDictionary::new();
            info.set("key", view.state.key);
            info.set("id", view.state.id.as_str());
            info.set("size", Vector2i::new(width.round() as i32, height.round() as i32));
            info.set("resizing", view.state.resizing);
            info.set("primary", primary == Some(index));
            info.to_variant()
        }).collect()
    }

    #[func]
    fn closed(&self) -> bool {
        self.runtime.as_ref().is_none_or(|runtime| runtime.closed)
    }

    #[func]
    fn paint(&mut self, key: u32) -> VarArray {
        let Some(runtime) = self.runtime.as_mut() else { return VarArray::new() };
        let now = Instant::now();
        let (paints, wake) = runtime.paint(key, now);
        match wake {
            Some(ms) => self.due.insert(key, now + std::time::Duration::from_millis(ms)),
            None => self.due.remove(&key),
        };
        let mut out = VarArray::new();
        let mut boxes: Vec<Box2> = Vec::new();
        let size = runtime.view(key).map_or((0.0, 0.0), |view| view.state.size());
        for paint in paints {
            let mut op = VarDictionary::new();
            let clip = match paint {
                Paint::Picture { picture, frame, x, y, part, stretch, alpha, clip } => {
                    let id = Arc::as_ptr(&picture) as usize as i64;
                    self.pictures.entry(id).or_insert(picture);
                    let (width, height) = stretch.unwrap_or((part.width, part.height));
                    op.set("kind", "picture");
                    op.set("picture", id);
                    op.set("frame", frame as i64);
                    op.set("part", rect(part));
                    op.set("area", Rect2i::new(Vector2i::new(x, y), Vector2i::new(width, height)));
                    op.set("alpha", alpha);
                    clip
                }
                Paint::Fill { area, color: rgb, alpha, clip } => {
                    op.set("kind", "fill");
                    op.set("area", rect(area));
                    op.set("color", color(rgb, alpha));
                    clip
                }
                Paint::Text { text, clip } => {
                    op.set("kind", "text");
                    op.set("text", text.text.as_str());
                    op.set("area", rect(text.area));
                    op.set("size", text.size_px);
                    op.set("color", color(text.color, text.alpha));
                    op.set("bold", text.bold);
                    op.set("italic", text.italic);
                    op.set("underline", text.underline);
                    op.set("strikeout", text.strikeout);
                    op.set("mono", text.mono);
                    op.set("align", text.align as i64);
                    op.set("scroll", text.scroll);
                    op.set("wrap", text.wrap);
                    clip
                }
                Paint::Effects { area, alpha, clip } => {
                    op.set("kind", "effects");
                    op.set("area", rect(area));
                    op.set("alpha", alpha);
                    clip
                }
                Paint::Wave { area, color: rgb, alpha, clip } => {
                    op.set("kind", "wave");
                    op.set("area", rect(area));
                    op.set("color", color(rgb, alpha));
                    clip
                }
                Paint::Art { area, background, clip } => {
                    op.set("kind", "art");
                    op.set("area", rect(area));
                    if let Some(rgb) = background {
                        op.set("color", color(rgb, 255));
                    }
                    clip
                }
            };
            let mut hasher = DefaultHasher::new();
            op.to_variant().stringify().to_string().hash(&mut hasher);
            for area in clip.iter() {
                (area.x, area.y, area.width, area.height).hash(&mut hasher);
            }
            op.set("hash", hasher.finish() as i64);
            boxes.extend(clip.iter().copied());
            op.set("clip", &clip.iter().map(|area| rect(*area).to_variant()).collect::<VarArray>());
            out.push(&op.to_variant());
        }
        self.shapes.insert(key, outline(&boxes, size.0.round() as i32, size.1.round() as i32));
        out
    }

    #[func]
    fn shape(&self, key: u32) -> PackedVector2Array {
        self.shapes.get(&key).cloned().unwrap_or_default()
    }

    #[func]
    fn set_library(&mut self, songs: VarArray) {
        if let Some(runtime) = self.runtime.as_mut() {
            runtime.shared.library = songs.iter_shared().filter_map(|value| value.try_to::<VarDictionary>().ok()).map(|value| song(&value)).collect();
        }
    }

    #[func]
    fn file(&self, name: GString) -> PackedByteArray {
        self.wmp.as_ref().and_then(|wmp| wmp.files.get(&name.to_string().to_lowercase())).map_or_else(PackedByteArray::new, |bytes| PackedByteArray::from(&bytes[..]))
    }

    #[func]
    fn errors(&mut self) -> PackedStringArray {
        self.runtime.as_mut().map_or_else(PackedStringArray::new, |runtime| runtime.take_errors().iter().map(GString::from).collect())
    }

    #[func]
    fn needs_paint(&self, key: u32) -> bool {
        let changed = self.runtime.as_ref().and_then(|runtime| runtime.view(key)).is_none_or(|view| view.state.changed);
        changed || self.due.get(&key).is_some_and(|due| *due <= Instant::now())
    }

    #[func]
    fn frame(&self, picture: i64, frame: i64) -> VarDictionary {
        let mut result = VarDictionary::new();
        if let Some(found) = self.pictures.get(&picture).and_then(|picture| picture.frames.get(frame.max(0) as usize)) {
            result.set("width", found.bitmap.width);
            result.set("height", found.bitmap.height);
            result.set("rgba", &PackedByteArray::from(&found.bitmap.rgba[..]));
        }
        result
    }

    #[func]
    fn input(&mut self, key: u32, kind: GString, x: f32, y: f32, value: i64, shift: bool, ctrl: bool, alt: bool) {
        let Some(runtime) = self.runtime.as_mut() else { return };
        let input = match kind.to_string().as_str() {
            "pointer" => Input::Pointer { x, y },
            "left" => Input::Left,
            "press" => Input::Press { secondary: value != 0 },
            "release" => Input::Release { secondary: value != 0 },
            "wheel" => Input::Wheel(x),
            "key_down" => Input::Key { code: value as u32, pressed: true },
            "key_up" => Input::Key { code: value as u32, pressed: false },
            "character" => match char::from_u32(value as u32) {
                Some(character) => Input::Character(character),
                None => return,
            },
            "resized" => Input::Resized(x, y),
            _ => return,
        };
        runtime.input(key, input, Modifiers { shift, ctrl, alt }, Instant::now());
    }

    #[func]
    fn window_commands(&mut self, key: u32) -> VarArray {
        let Some(runtime) = self.runtime.as_mut() else { return VarArray::new() };
        runtime.window_commands(key).into_iter().map(|command| match command {
            WindowCommand::Drag => varray!["drag"],
            WindowCommand::Minimize => varray!["minimize"],
            WindowCommand::Maximize => varray!["maximize"],
            WindowCommand::Restore => varray!["restore"],
            WindowCommand::Resize(edge) => varray!["resize", match edge {
                Edge::NorthWest => 0,
                Edge::North => 1,
                Edge::NorthEast => 2,
                Edge::West => 3,
                Edge::East => 4,
                Edge::SouthWest => 5,
                Edge::South => 6,
                Edge::SouthEast => 7,
            }],
        }.to_variant()).collect()
    }

    #[func]
    fn window_ready(&mut self, key: u32) {
        if let Some(runtime) = self.runtime.as_mut() {
            runtime.window_ready(key);
        }
    }

    #[func]
    fn hover(&self, key: u32) -> VarArray {
        let Some(runtime) = self.runtime.as_ref() else { return VarArray::new() };
        let (tip, cursor) = runtime.hover_info(key);
        varray![tip.unwrap_or_default(), cursor.unwrap_or_default()]
    }

    #[func]
    fn wake_ms(&self) -> i64 {
        self.runtime.as_ref().and_then(|runtime| runtime.next_wake(Instant::now())).map_or(-1, |wake| wake.as_millis() as i64)
    }

    #[func]
    fn preferences(&mut self) -> VarDictionary {
        let mut result = VarDictionary::new();
        if let Some(runtime) = self.runtime.as_mut() {
            if std::mem::take(&mut runtime.shared.prefs_changed) {
                for (key, value) in &runtime.shared.prefs {
                    result.set(key.as_str(), value.as_str());
                }
            }
        }
        result
    }

    #[func]
    fn shut_down(&mut self) {
        if let Some(runtime) = self.runtime.as_mut() {
            runtime.shut_down();
        }
        self.pictures.clear();
    }
}
