use image::codecs::jpeg::JpegEncoder;
use image::imageops::FilterType;
use std::io::Cursor;
use std::path::{Path, PathBuf};
use std::sync::mpsc::{channel, Sender};
use std::sync::{Arc, Mutex};
use std::thread::{self, JoinHandle};

pub const COVER_SIZE: u32 = 720;
pub const THUMB_SIZE: u32 = 256;
#[cfg(any(target_os = "macos", target_os = "ios"))]
pub const ORIGINAL_SIZE: u32 = 2048;
pub const CACHE_REVISION: u32 = 2;
const JPEG_QUALITY: u8 = 90;
const WORKERS: usize = 2;

pub fn cover_file(dir: &Path, kind: &str, id: &str, thumb: bool) -> PathBuf {
    let safe: String = id
        .chars()
        .map(|character| {
            if character.is_ascii_alphanumeric() || matches!(character, '.' | '_' | '-') {
                character
            } else {
                '_'
            }
        })
        .collect();
    let suffix = if thumb { "_thumb" } else { "" };
    dir.join(format!("{kind}_{safe}{suffix}.jpg"))
}

pub fn is_cached(path: &Path) -> bool {
    std::fs::metadata(path).is_ok_and(|meta| meta.len() > 0)
}

pub fn write_atomically(path: &Path, bytes: &[u8]) {
    let _ = crate::storage::write_atomically(path, bytes);
}

pub fn to_scaled_jpeg(bytes: &[u8], max_size: u32) -> Option<Vec<u8>> {
    scaled_jpeg(image::load_from_memory(bytes).ok()?, max_size)
}

pub fn scaled_jpeg(decoded: image::DynamicImage, max_size: u32) -> Option<Vec<u8>> {
    let (width, height) = (decoded.width(), decoded.height());
    if width == 0 || height == 0 {
        return None;
    }
    let longest = width.max(height);
    let decoded = if longest > max_size {
        let scale = max_size as f32 / longest as f32;
        decoded.resize(
            ((width as f32 * scale) as u32).max(1),
            ((height as f32 * scale) as u32).max(1),
            FilterType::Triangle,
        )
    } else {
        decoded
    };
    let mut output = Vec::new();
    JpegEncoder::new_with_quality(&mut Cursor::new(&mut output), JPEG_QUALITY)
        .encode_image(&decoded.to_rgb8())
        .ok()?;
    Some(output)
}

pub struct Pool {
    jobs: Mutex<Option<Sender<Box<dyn FnOnce() + Send>>>>,
    workers: Mutex<Vec<JoinHandle<()>>>,
}

impl Pool {
    pub fn new() -> Self {
        let (jobs, receiver) = channel::<Box<dyn FnOnce() + Send>>();
        let receiver = Arc::new(Mutex::new(receiver));
        let workers = (0..WORKERS)
            .map(|_| {
                let receiver = receiver.clone();
                thread::spawn(move || loop {
                    let job = {
                        let Ok(guard) = receiver.lock() else {
                            return;
                        };
                        guard.recv()
                    };
                    match job {
                        Ok(job) => job(),
                        Err(_) => return,
                    }
                })
            })
            .collect();
        Self {
            jobs: Mutex::new(Some(jobs)),
            workers: Mutex::new(workers),
        }
    }

    pub fn run(&self, job: impl FnOnce() + Send + 'static) {
        if let Some(jobs) = self.jobs.lock().unwrap().as_ref() {
            let _ = jobs.send(Box::new(job));
        }
    }

    pub fn shutdown(&self) {
        self.jobs.lock().unwrap().take();
        for worker in self.workers.lock().unwrap().drain(..) {
            let _ = worker.join();
        }
    }
}

pub fn score(name: &str, path: &Path) -> i32 {
    let (base, extension) = match name.rsplit_once('.') {
        Some((base, extension)) => (base.to_lowercase(), extension.to_lowercase()),
        None => (name.to_lowercase(), String::new()),
    };
    let folder_name = path
        .file_name()
        .map(|name| name.to_string_lossy().to_lowercase())
        .unwrap_or_default();
    let mut score: i32 = ["front", "art", "album", "folder", "cover", &folder_name]
        .iter()
        .enumerate()
        .map(|(index, value)| {
            if !value.is_empty() && base.contains(*value) {
                index as i32 + 1
            } else {
                0
            }
        })
        .sum();
    score *= match extension.as_str() {
        "gif" | "mp4" | "webm" => 6,
        "webp" => 5,
        "jpeg" | "jpg" => 4,
        "png" => 3,
        _ => 1,
    };
    score *= if matches!(extension.as_str(), "webp" | "jpg" | "jpeg" | "png" | "gif" | "mp4" | "webm") {
        2
    } else {
        1
    };
    score
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cover_names_replace_unsafe_characters() {
        let path = cover_file(Path::new("/covers"), "album", "album-a/b:c", true);
        assert_eq!(
            path,
            Path::new("/covers/album_album-a_b_c_thumb.jpg").to_path_buf()
        );
    }

    #[test]
    fn folder_covers_prefer_the_obvious_names() {
        let folder = Path::new("/music/Kid A");
        assert!(score("cover.jpg", folder) > score("scan1.jpg", folder));
        assert!(score("folder.webp", folder) > score("folder.png", folder));
        assert!(score("kid a.jpg", folder) > 0);
        assert_eq!(score("booklet.txt", folder), 0);
    }
}
