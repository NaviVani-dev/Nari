use serde_json::{json, Map, Value as Json};
use std::path::{Path, PathBuf};
use std::sync::{Mutex, OnceLock};

const FILE: &str = "history.json";
const LIMIT: usize = 2000;
const KEPT: [&str; 8] = ["id", "title", "artist", "artists", "album", "album_id", "artist_id", "duration"];

static ROOT: OnceLock<PathBuf> = OnceLock::new();
static PROVIDER: Mutex<String> = Mutex::new(String::new());
static LOCK: Mutex<()> = Mutex::new(());

pub fn init(root: PathBuf) {
    let _ = ROOT.set(root);
}

pub fn set_provider(provider: &str) {
    *PROVIDER.lock().unwrap_or_else(|poisoned| poisoned.into_inner()) = provider.to_owned();
}

fn provider() -> String {
    PROVIDER.lock().unwrap_or_else(|poisoned| poisoned.into_inner()).clone()
}

pub fn record(song: &Json, at: u64) -> Option<Json> {
    let id = song["id"].as_str().filter(|id| !id.is_empty())?;
    let path = ROOT.get()?.join(FILE);
    let _guard = LOCK.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    let mut all = read(&path);
    let shelf = all.entry(provider()).or_insert_with(|| json!({})).as_object_mut()?;
    let plays = shelf.get(id).and_then(|entry| entry["plays"].as_u64()).unwrap_or(0) + 1;
    let mut entry: Map<String, Json> = KEPT.iter().filter_map(|key| song.get(*key).map(|value| (key.to_string(), value.clone()))).collect();
    entry.insert("plays".into(), json!(plays));
    entry.insert("last_played".into(), json!(at));
    shelf.insert(id.to_owned(), Json::Object(entry.clone()));
    prune(shelf);
    save(&path, all);
    Some(Json::Object(entry))
}

pub fn entries(provider: &str) -> Json {
    let Some(root) = ROOT.get() else {
        return json!([]);
    };
    let _guard = LOCK.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    let mut list: Vec<Json> = read(&root.join(FILE)).get(provider).and_then(Json::as_object).map(|shelf| shelf.values().cloned().collect()).unwrap_or_default();
    list.sort_by_key(|entry| std::cmp::Reverse(entry["last_played"].as_u64().unwrap_or(0)));
    Json::Array(list)
}

pub fn clear(provider: &str) {
    let Some(root) = ROOT.get() else {
        return;
    };
    let path = root.join(FILE);
    let _guard = LOCK.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    let mut all = read(&path);
    all.remove(provider);
    save(&path, all);
}

fn prune(shelf: &mut Map<String, Json>) {
    if shelf.len() <= LIMIT {
        return;
    }
    let mut ages: Vec<(u64, String)> = shelf.iter().map(|(id, entry)| (entry["last_played"].as_u64().unwrap_or(0), id.clone())).collect();
    ages.sort();
    for (_, id) in ages.into_iter().take(shelf.len() - LIMIT) {
        shelf.remove(&id);
    }
}

fn save(path: &Path, all: Map<String, Json>) {
    let _ = crate::storage::write_atomically(path, Json::Object(all).to_string().as_bytes());
}

fn read(path: &Path) -> Map<String, Json> {
    std::fs::read_to_string(path).ok().and_then(|text| serde_json::from_str(&text).ok()).unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn counts_plays_per_provider_and_prunes() {
        let root = std::env::temp_dir().join(format!("nari-history-{}", std::process::id()));
        std::fs::create_dir_all(&root).unwrap();
        let _ = ROOT.set(root.clone());
        set_provider("local");
        record(&json!({ "id": "a", "title": "A", "extra": 1 }), 10).unwrap();
        record(&json!({ "id": "b", "title": "B" }), 20).unwrap();
        let again = record(&json!({ "id": "a", "title": "A" }), 30).unwrap();
        assert_eq!(again["plays"], 2);
        assert!(again.get("extra").is_none());
        let list = entries("local");
        assert_eq!(list[0]["id"], "a");
        assert_eq!(list[1]["id"], "b");
        assert_eq!(entries("plex"), json!([]));
        assert!(record(&json!({ "title": "no id" }), 40).is_none());
        let mut shelf: Map<String, Json> = (0..LIMIT + 5).map(|index| (index.to_string(), json!({ "last_played": index }))).collect();
        prune(&mut shelf);
        assert_eq!(shelf.len(), LIMIT);
        assert!(!shelf.contains_key("0") && shelf.contains_key(&(LIMIT + 4).to_string()));
        clear("local");
        assert_eq!(entries("local"), json!([]));
        std::fs::remove_dir_all(root).unwrap();
    }
}
