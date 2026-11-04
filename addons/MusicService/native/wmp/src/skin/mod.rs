pub mod script;
pub mod wmp;

use std::collections::{HashMap, VecDeque};
use std::io::Read;
use std::path::Path;
use std::sync::Arc;

pub type Rgb = [u8; 3];

pub const MAX_BITMAP_SIDE: u32 = 8192;
const MAX_DEPTH: usize = 8;
const MAX_FILE: u64 = 64 * 1024 * 1024;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Area {
    pub x: u32,
    pub y: u32,
    pub width: u32,
    pub height: u32,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Bitmap {
    pub width: u32,
    pub height: u32,
    pub rgba: Vec<u8>,
}

impl Bitmap {
    pub fn decode(bytes: &[u8]) -> Option<Self> {
        let mut reader = image::ImageReader::new(std::io::Cursor::new(bytes)).with_guessed_format().ok()?;
        let mut limits = image::Limits::default();
        limits.max_image_width = Some(MAX_BITMAP_SIDE);
        limits.max_image_height = Some(MAX_BITMAP_SIDE);
        reader.limits(limits);
        let image = reader.decode().ok()?.into_rgba8();
        Some(Self { width: image.width(), height: image.height(), rgba: image.into_raw() })
    }

    pub fn crop(&self, area: Area) -> Option<Bitmap> {
        let right = area.x.saturating_add(area.width).min(self.width);
        let bottom = area.y.saturating_add(area.height).min(self.height);
        if right <= area.x || bottom <= area.y {
            return None;
        }
        let mut rgba = Vec::with_capacity(4 * ((right - area.x) * (bottom - area.y)) as usize);
        for y in area.y..bottom {
            let start = 4 * (y * self.width + area.x) as usize;
            rgba.extend_from_slice(&self.rgba[start..start + 4 * (right - area.x) as usize]);
        }
        Some(Bitmap { width: right - area.x, height: bottom - area.y, rgba })
    }

    pub fn pixel(&self, x: u32, y: u32) -> Option<[u8; 4]> {
        if x >= self.width || y >= self.height {
            return None;
        }
        let at = 4 * (y * self.width + x) as usize;
        self.rgba[at..at + 4].try_into().ok()
    }
}

fn wanted(name: &str) -> bool {
    name.rsplit_once('.').is_some_and(|(_, extension)| matches!(extension, "wms" | "js" | "bmp" | "png" | "gif" | "jpg" | "jpeg" | "wav" | "mp3")) || name == "viscolor.txt"
}

fn read(path: &Path) -> HashMap<String, Vec<u8>> {
    let mut files = HashMap::new();
    if path.is_dir() {
        let mut folders = VecDeque::from([(path.to_path_buf(), 0)]);
        while let Some((folder, depth)) = folders.pop_front() {
            let Ok(entries) = std::fs::read_dir(&folder) else { continue };
            let mut entries: Vec<_> = entries.flatten().collect();
            entries.sort_by_key(|entry| entry.file_name());
            for entry in entries {
                let Ok(kind) = entry.file_type() else { continue };
                let name = wmp::file_name(&entry.file_name().to_string_lossy());
                if kind.is_dir() && depth < MAX_DEPTH {
                    folders.push_back((entry.path(), depth + 1));
                } else if kind.is_file() && wanted(&name) && !files.contains_key(&name) {
                    if let Ok(bytes) = std::fs::read(entry.path()) {
                        files.insert(name, bytes);
                    }
                }
            }
        }
        return files;
    }
    let Ok(file) = std::fs::File::open(path) else { return files };
    let Ok(mut archive) = zip::ZipArchive::new(file) else { return files };
    for index in 0..archive.len() {
        let Ok(entry) = archive.by_index(index) else { continue };
        let name = wmp::file_name(entry.name());
        if entry.is_dir() || !wanted(&name) || entry.size() > MAX_FILE {
            continue;
        }
        let mut bytes = Vec::new();
        if entry.take(MAX_FILE).read_to_end(&mut bytes).is_ok() {
            files.insert(name, bytes);
        }
    }
    files
}

pub fn is_media_player(path: &Path) -> bool {
    let files = read(path);
    let has = |names: &[&str]| names.iter().any(|name| files.contains_key(*name));
    files.keys().any(|name| name.ends_with(".wms")) && !(has(&["main.bmp", "main.png"]) && has(&["cbuttons.bmp", "cbuttons.png", "titlebar.bmp", "titlebar.png"]))
}

pub fn load(path: &Path) -> Option<wmp::Wmp> {
    let files = Arc::new(read(path));
    let mut definitions: Vec<&String> = files.keys().filter(|name| name.ends_with(".wms")).collect();
    definitions.sort();
    definitions.into_iter().find_map(|name| wmp::Wmp::parse(&decode_definition(&files[name]), name.strip_suffix(".wms").unwrap_or(name), files.clone()))
}

fn decode_definition(bytes: &[u8]) -> String {
    let utf16 = |rest: &[u8], big: bool| {
        let units: Vec<u16> = rest.chunks_exact(2).map(|pair| if big { u16::from_be_bytes([pair[0], pair[1]]) } else { u16::from_le_bytes([pair[0], pair[1]]) }).collect();
        String::from_utf16_lossy(&units)
    };
    match bytes {
        [0xff, 0xfe, rest @ ..] => utf16(rest, false),
        [0xfe, 0xff, rest @ ..] => utf16(rest, true),
        _ => match std::str::from_utf8(bytes) {
            Ok(text) => text.strip_prefix('\u{feff}').unwrap_or(text).to_owned(),
            Err(_) => bytes.iter().map(|&byte| char::from(byte)).collect(),
        },
    }
}
