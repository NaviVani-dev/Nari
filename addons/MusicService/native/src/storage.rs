use std::fs::File;
use std::io::{self, Read};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

pub fn open(uri: &str) -> io::Result<File> {
    if uri.starts_with("content://") {
        return content(uri);
    }
    File::open(uri)
}

pub fn read(uri: &str) -> io::Result<Vec<u8>> {
    let mut bytes = Vec::new();
    open(uri)?.read_to_end(&mut bytes)?;
    Ok(bytes)
}

pub fn read_limited(uri: &str, limit: u64) -> io::Result<Vec<u8>> {
    let mut bytes = Vec::new();
    open(uri)?.take(limit + 1).read_to_end(&mut bytes)?;
    if bytes.len() as u64 > limit {
        return Err(io::Error::new(io::ErrorKind::FileTooLarge, uri.to_owned()));
    }
    Ok(bytes)
}

pub fn write_atomically(path: &Path, bytes: &[u8]) -> io::Result<()> {
    if let Some(folder) = path.parent() {
        std::fs::create_dir_all(folder)?;
    }
    let temporary = temporary_sibling(path);
    if let Err(error) = std::fs::write(&temporary, bytes).and_then(|_| std::fs::rename(&temporary, path)) {
        let _ = std::fs::remove_file(&temporary);
        return Err(error);
    }
    Ok(())
}

fn temporary_sibling(path: &Path) -> PathBuf {
    static NEXT: AtomicU64 = AtomicU64::new(0);
    let name = path.file_name().unwrap_or_default().to_string_lossy();
    let unique = NEXT.fetch_add(1, Ordering::Relaxed);
    path.with_file_name(format!(".{name}.{}.{unique}.tmp", std::process::id()))
}

pub fn extension(name: &str) -> String {
    name.rsplit_once('.')
        .map(|(_, extension)| extension.to_lowercase())
        .filter(|extension| !extension.contains('/'))
        .unwrap_or_default()
}

#[cfg(target_os = "android")]
fn content(uri: &str) -> io::Result<File> {
    use std::os::fd::FromRawFd;
    let descriptor = crate::android::open_fd(uri);
    if descriptor < 0 {
        return Err(io::Error::new(io::ErrorKind::NotFound, uri.to_owned()));
    }
    Ok(unsafe { File::from_raw_fd(descriptor) })
}

#[cfg(not(target_os = "android"))]
fn content(uri: &str) -> io::Result<File> {
    Err(io::Error::new(io::ErrorKind::Unsupported, uri.to_owned()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn extensions_come_from_the_name_not_the_folder() {
        assert_eq!(extension("Song.FLAC"), "flac");
        assert_eq!(extension("content://media/external/audio/media/42"), "");
        assert_eq!(extension("primary%3AMusic%2Fsong.lrc"), "lrc");
        assert_eq!(extension("/music/v1.0/track"), "");
    }

    #[test]
    fn atomic_writes_replace_the_file_and_limited_reads_refuse_big_ones() {
        let folder = std::env::temp_dir().join(format!("nari-storage-{}", std::process::id()));
        let file = folder.join("nested").join("data.json");
        write_atomically(&file, b"first").unwrap();
        write_atomically(&file, b"second").unwrap();
        assert_eq!(std::fs::read(&file).unwrap(), b"second");
        let leftovers = std::fs::read_dir(file.parent().unwrap()).unwrap().count();
        assert_eq!(leftovers, 1);
        let path = file.to_string_lossy();
        assert_eq!(read_limited(&path, 6).unwrap(), b"second");
        assert!(read_limited(&path, 5).is_err());
        std::fs::remove_dir_all(folder).unwrap();
    }
}
