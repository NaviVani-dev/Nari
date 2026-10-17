use md5::{Digest, Md5};
use serde_json::{json, Value as Json};
use std::path::Path;

const AUDIO: [&str; 40] = [
    "mp3", "m4a", "mp4", "aac", "flac", "ogg", "oga", "opus", "wav", "wave", "aif", "aiff", "wma", "mid", "midi", "kar", "mod", "xm", "s3m", "it", "sid",
    "mptm", "669", "amf", "ams", "dbm", "dmf", "dsm", "far", "mdl", "med", "mo3", "mt2", "mtm", "okt", "psm", "ptm", "stm", "ult", "umx",
];

pub fn launch_targets() -> Vec<String> {
    std::env::args().skip(1).filter_map(|arg| target(&arg)).collect()
}

fn target(arg: &str) -> Option<String> {
    if arg.starts_with("nari://") {
        return Some(arg.to_owned());
    }
    let path = local_path(arg)?;
    let absolute = std::fs::canonicalize(&path).ok()?;
    (absolute.is_file() && is_audio(&absolute.to_string_lossy())).then(|| absolute.to_string_lossy().into_owned())
}

pub fn is_audio(name: &str) -> bool {
    AUDIO.contains(&crate::storage::extension(name).as_str())
}

fn local_path(arg: &str) -> Option<String> {
    let Some(rest) = arg.strip_prefix("file://") else {
        return (!arg.starts_with('-') && !arg.contains("://")).then(|| arg.to_owned());
    };
    let rest = rest.strip_prefix("localhost").unwrap_or(rest);
    let bytes = rest.as_bytes();
    let mut decoded = Vec::with_capacity(bytes.len());
    let mut index = 0;
    while index < bytes.len() {
        match (bytes[index], bytes.get(index + 1..index + 3)) {
            (b'%', Some(hex)) => {
                decoded.push(u8::from_str_radix(std::str::from_utf8(hex).ok()?, 16).ok()?);
                index += 3;
            }
            (byte, _) => {
                decoded.push(byte);
                index += 1;
            }
        }
    }
    String::from_utf8(decoded).ok()
}

pub fn song(uri: &str, name: &str, covers: &Path) -> Json {
    let name = if name.is_empty() { uri.rsplit(['/', '\\']).next().unwrap_or(uri) } else { name };
    let stem = name.rsplit_once('.').map_or(name, |(stem, _)| stem);
    let meta = crate::library::meta::read(uri, name).unwrap_or_default();
    let id = format!("file:{uri}");
    let cover = crate::library::meta::artwork(uri, name)
        .and_then(|bytes| {
            let format = image::guess_format(&bytes).ok()?;
            let extension = format.extensions_str().first()?;
            let target = covers.join(format!("{}.{extension}", crate::plugins::hex(&Md5::digest(id.as_bytes()))));
            crate::storage::write_atomically(&target, &bytes).ok()?;
            Some(target.to_string_lossy().into_owned())
        })
        .unwrap_or_default();
    let artist = meta.artists.join(", ");
    json!({
        "id": id,
        "title": if meta.title.is_empty() { stem.to_owned() } else { meta.title },
        "artist": artist,
        "artists": meta.artists,
        "album": meta.album,
        "duration": meta.duration,
        "uri": uri,
        "file_name": name,
        "cover": cover,
        "ephemeral": true,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn launch_arguments_become_files_or_links() {
        let folder = std::env::temp_dir().join(format!("nari-opened-{}", std::process::id()));
        std::fs::create_dir_all(&folder).unwrap();
        let song = folder.join("My Song.flac");
        std::fs::write(&song, b"not really flac").unwrap();
        let absolute = std::fs::canonicalize(&song).unwrap().to_string_lossy().into_owned();
        assert_eq!(target(&song.to_string_lossy()).as_deref(), Some(absolute.as_str()));
        let uri = format!("file://{}", absolute.replace(' ', "%20"));
        assert_eq!(target(&uri).as_deref(), Some(absolute.as_str()));
        assert_eq!(target("nari://plugin/x/y").as_deref(), Some("nari://plugin/x/y"));
        assert_eq!(target("--verbose"), None);
        assert_eq!(target(&folder.join("missing.mp3").to_string_lossy()), None);
        std::fs::write(folder.join("notes.txt"), b"hi").unwrap();
        assert_eq!(target(&folder.join("notes.txt").to_string_lossy()), None);
        let info = super::song(&absolute, "", &folder.join("covers"));
        assert_eq!(info["title"], "My Song");
        assert_eq!(info["ephemeral"], true);
        assert_eq!(info["id"], format!("file:{absolute}"));
        std::fs::remove_dir_all(folder).unwrap();
    }
}
