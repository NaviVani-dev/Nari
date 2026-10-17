use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::{SystemTime, UNIX_EPOCH};

use crate::library::{song_json, Library};

const COVER_ALBUMS: usize = 4;

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
struct Playlist {
    id: String,
    #[serde(default = "default_name")]
    name: String,
    #[serde(default)]
    modified: i64,
    #[serde(default)]
    song_ids: Vec<String>,
}

fn default_name() -> String {
    "Playlist".to_owned()
}

pub struct Playlists {
    file: PathBuf,
    images: PathBuf,
    items: Mutex<Vec<Playlist>>,
}

impl Playlists {
    pub fn new(root: &Path) -> Self {
        let file = root.join("playlists.json");
        let items = std::fs::read_to_string(&file)
            .ok()
            .and_then(|raw| serde_json::from_str(&raw).ok())
            .unwrap_or_default();
        Self {
            file,
            images: root.join("playlist_images"),
            items: Mutex::new(items),
        }
    }

    pub fn all_json(&self, library: &Library) -> String {
        let items = self.items.lock().unwrap();
        Value::Array(items.iter().map(|playlist| self.json(playlist, library, false)).collect())
            .to_string()
    }

    pub fn playlist_json(&self, id: &str, library: &Library) -> String {
        self.items
            .lock()
            .unwrap()
            .iter()
            .find(|playlist| playlist.id == id)
            .map(|playlist| self.json(playlist, library, true).to_string())
            .unwrap_or_else(|| "{}".to_owned())
    }

    pub fn song_ids(&self, id: &str) -> Vec<String> {
        self.items
            .lock()
            .unwrap()
            .iter()
            .find(|playlist| playlist.id == id)
            .map(|playlist| playlist.song_ids.clone())
            .unwrap_or_default()
    }

    pub fn create(&self, name: &str) -> String {
        let now = now_ms();
        let mut items = self.items.lock().unwrap();
        let mut stamp = now;
        while items.iter().any(|playlist| playlist.id == stamp.to_string()) {
            stamp += 1;
        }
        let id = stamp.to_string();
        items.push(Playlist {
            id: id.clone(),
            name: name.to_owned(),
            modified: now,
            song_ids: Vec::new(),
        });
        self.save(&items);
        id
    }

    pub fn delete(&self, id: &str) {
        let mut items = self.items.lock().unwrap();
        let before = items.len();
        items.retain(|playlist| playlist.id != id);
        if items.len() == before {
            return;
        }
        let _ = std::fs::remove_file(self.image(id));
        self.save(&items);
    }

    pub fn rename(&self, id: &str, name: &str) {
        self.change(id, |playlist| playlist.name = name.to_owned());
    }

    pub fn add_songs(&self, id: &str, song_ids: &[String]) {
        self.change(id, |playlist| {
            let mut present: HashSet<String> = playlist.song_ids.iter().cloned().collect();
            for song_id in song_ids {
                if present.insert(song_id.clone()) {
                    playlist.song_ids.push(song_id.clone());
                }
            }
        });
    }

    pub fn remove_song(&self, id: &str, song_id: &str) {
        self.change(id, |playlist| {
            if let Some(index) = playlist.song_ids.iter().position(|value| value == song_id) {
                playlist.song_ids.remove(index);
            }
        });
    }

    pub fn set_image(&self, id: &str, source: &Path) {
        let target = self.image(id);
        self.change(id, |_| {
            let _ = std::fs::create_dir_all(&self.images);
            let _ = std::fs::copy(source, &target);
        });
    }

    fn change(&self, id: &str, edit: impl FnOnce(&mut Playlist)) {
        let mut items = self.items.lock().unwrap();
        let Some(playlist) = items.iter_mut().find(|playlist| playlist.id == id) else {
            return;
        };
        edit(playlist);
        playlist.modified = now_ms();
        self.save(&items);
    }

    fn image(&self, id: &str) -> PathBuf {
        self.images.join(format!("{id}.jpg"))
    }

    fn json(&self, playlist: &Playlist, library: &Library, include_songs: bool) -> Value {
        let songs = library.songs_by_ids(&playlist.song_ids);
        let mut covers: Vec<String> = Vec::new();
        for song in &songs {
            if covers.len() == COVER_ALBUMS {
                break;
            }
            if !song.album_id.is_empty() && !covers.contains(&song.album_id) {
                covers.push(song.album_id.clone());
            }
        }
        let image = self.image(&playlist.id);
        let mut value = json!({
            "id": playlist.id,
            "name": playlist.name,
            "song_count": songs.len(),
            "duration": songs.iter().map(|song| song.duration).sum::<i64>(),
            "modified": playlist.modified,
            "cover_album_id": songs.first().map(|song| song.album_id.clone()).unwrap_or_default(),
            "cover_album_ids": covers,
            "image": if image.exists() { image.to_string_lossy().into_owned() } else { String::new() },
        });
        if include_songs {
            value["tracks"] = Value::Array(songs.iter().map(|song| song_json(song)).collect());
        }
        value
    }

    fn save(&self, items: &[Playlist]) {
        if let Ok(raw) = serde_json::to_vec(items) {
            let _ = crate::storage::write_atomically(&self.file, &raw);
        }
    }
}

fn now_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|elapsed| elapsed.as_millis() as i64)
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_the_android_playlists_file_and_keeps_its_shape() {
        let root = std::env::temp_dir().join(format!("nari_playlists_{}", std::process::id()));
        std::fs::create_dir_all(&root).unwrap();
        std::fs::write(
            root.join("playlists.json"),
            r#"[{"id":"1700000000000","name":"Mix","modified":5,"song_ids":["12","song-a"]}]"#,
        )
        .unwrap();
        let playlists = Playlists::new(&root);
        assert_eq!(playlists.song_ids("1700000000000"), vec!["12", "song-a"]);
        playlists.add_songs("1700000000000", &["12".to_owned(), "13".to_owned()]);
        playlists.remove_song("1700000000000", "song-a");
        let created = playlists.create("New");
        let twin = playlists.create("Twin");
        assert_ne!(created, twin);
        playlists.delete(&twin);
        let reread = Playlists::new(&root);
        assert_eq!(reread.song_ids("1700000000000"), vec!["12", "13"]);
        assert!(reread.song_ids(&created).is_empty());
        playlists.delete(&created);
        assert!(Playlists::new(&root).song_ids(&created).is_empty());
        std::fs::remove_dir_all(&root).unwrap();
    }
}
