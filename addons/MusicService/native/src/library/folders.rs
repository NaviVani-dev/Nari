use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};

const LEGACY_PICKER: &str = "picker";

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct Folder {
    pub uri: String,
    pub name: String,
    pub document_id: String,
}

impl Folder {
    pub fn of(path: &Path) -> Self {
        let uri = path.to_string_lossy().into_owned();
        let name = path
            .file_name()
            .map(|name| name.to_string_lossy().into_owned())
            .unwrap_or_else(|| uri.clone());
        Self {
            document_id: uri.clone(),
            uri,
            name,
        }
    }

    pub fn path(&self) -> PathBuf {
        PathBuf::from(&self.uri)
    }
}

#[derive(Serialize, Deserialize, Clone, Debug)]
pub struct Folders {
    #[serde(default, skip_serializing)]
    source: Option<String>,
    #[serde(default)]
    pub music: Vec<Folder>,
    #[serde(default)]
    pub ignored: Vec<Folder>,
    #[serde(skip)]
    path: PathBuf,
}

impl Folders {
    pub fn load(path: PathBuf, system_music_dir: &Path) -> Self {
        let mut folders = std::fs::read_to_string(&path)
            .ok()
            .and_then(|raw| serde_json::from_str::<Folders>(&raw).ok())
            .unwrap_or_else(|| Self {
                source: None,
                music: Vec::new(),
                ignored: Vec::new(),
                path: PathBuf::new(),
            });
        folders.path = path;
        #[cfg(target_os = "ios")]
        folders.music.iter().chain(&folders.ignored).for_each(crate::ios::resume);
        let legacy_system = folders.source.take().is_none_or(|source| source != LEGACY_PICKER);
        if !cfg!(target_os = "android")
            && legacy_system
            && folders.music.is_empty()
            && !system_music_dir.as_os_str().is_empty()
        {
            folders.music.push(Folder::of(system_music_dir));
            folders.save();
        }
        folders
    }

    pub fn add(&mut self, kind: FolderKind, folder: Folder) -> bool {
        let list = self.list_mut(kind);
        if list.iter().any(|existing| existing.uri == folder.uri) {
            return false;
        }
        list.push(folder);
        self.save();
        true
    }

    pub fn remove(&mut self, kind: FolderKind, uri: &str) -> bool {
        let list = self.list_mut(kind);
        let before = list.len();
        list.retain(|folder| folder.uri != uri);
        if list.len() == before {
            return false;
        }
        self.save();
        true
    }

    pub fn list(&self, kind: FolderKind) -> &[Folder] {
        match kind {
            FolderKind::Music => &self.music,
            FolderKind::Ignored => &self.ignored,
        }
    }

    pub fn roots(&self) -> Vec<PathBuf> {
        self.music.iter().map(Folder::path).collect()
    }

    pub fn ignored_paths(&self) -> Vec<PathBuf> {
        self.ignored.iter().map(Folder::path).collect()
    }

    fn list_mut(&mut self, kind: FolderKind) -> &mut Vec<Folder> {
        match kind {
            FolderKind::Music => &mut self.music,
            FolderKind::Ignored => &mut self.ignored,
        }
    }

    fn save(&self) {
        if let Ok(raw) = serde_json::to_vec(self) {
            let _ = crate::storage::write_atomically(&self.path, &raw);
        }
    }
}

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum FolderKind {
    Music,
    Ignored,
}

impl FolderKind {
    pub fn id(self) -> &'static str {
        match self {
            FolderKind::Music => "music",
            FolderKind::Ignored => "ignored",
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn legacy_system_source_becomes_music_folder() {
        let dir = std::env::temp_dir().join(format!("nari-folders-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("folders.json");
        let music = dir.join("Music");
        std::fs::write(&path, r#"{"source":"system","music":[],"ignored":[]}"#).unwrap();
        assert_eq!(Folders::load(path.clone(), &music).roots(), vec![music.clone()]);
        assert!(!std::fs::read_to_string(&path).unwrap().contains("source"));
        std::fs::write(&path, r#"{"source":"picker","music":[],"ignored":[]}"#).unwrap();
        assert!(Folders::load(path.clone(), &music).roots().is_empty());
        std::fs::remove_dir_all(&dir).unwrap();
    }
}
