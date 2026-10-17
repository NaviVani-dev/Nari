use aes_gcm::aead::{Aead, KeyInit};
use aes_gcm::{Aes256Gcm, Nonce};
use std::path::{Path, PathBuf};
use std::sync::OnceLock;

const MAGIC: &[u8] = b"NARIV1";
const NONCE: usize = 12;
const KEY: usize = 32;

static ROOT: OnceLock<PathBuf> = OnceLock::new();
static MASTER: OnceLock<Option<[u8; KEY]>> = OnceLock::new();

pub fn init(root: PathBuf) {
    let _ = ROOT.set(root);
    std::thread::spawn(|| {
        master();
    });
}

pub fn is_sealed(bytes: &[u8]) -> bool {
    bytes.starts_with(MAGIC)
}

pub fn seal(plain: &[u8]) -> Option<Vec<u8>> {
    let cipher = Aes256Gcm::new_from_slice(master()?).ok()?;
    let nonce: [u8; NONCE] = std::array::from_fn(|_| rand::random());
    let sealed = cipher.encrypt(Nonce::from_slice(&nonce), plain).ok()?;
    Some([MAGIC, &nonce, &sealed].concat())
}

pub fn open(bytes: &[u8]) -> Option<Vec<u8>> {
    let body = bytes.strip_prefix(MAGIC)?;
    if body.len() < NONCE {
        return None;
    }
    let cipher = Aes256Gcm::new_from_slice(master()?).ok()?;
    cipher.decrypt(Nonce::from_slice(&body[..NONCE]), &body[NONCE..]).ok()
}

pub fn read(path: &Path) -> Option<Vec<u8>> {
    let bytes = std::fs::read(path).ok()?;
    if is_sealed(&bytes) {
        return open(&bytes);
    }
    let _ = write(path, &bytes);
    Some(bytes)
}

pub fn write(path: &Path, plain: &[u8]) -> std::io::Result<()> {
    let sealed = seal(plain).ok_or_else(|| std::io::Error::other("the private storage is unavailable"))?;
    crate::storage::write_atomically(path, &sealed)
}

fn master() -> Option<&'static [u8; KEY]> {
    MASTER.get_or_init(|| ROOT.get().and_then(|root| platform::load(root))).as_ref()
}

fn fresh() -> [u8; KEY] {
    std::array::from_fn(|_| rand::random())
}

fn key_of(bytes: &[u8]) -> Option<[u8; KEY]> {
    bytes.try_into().ok()
}

#[cfg(not(any(target_os = "android", windows)))]
fn key_file(root: &Path) -> Option<[u8; KEY]> {
    let path = root.join(".vault_key");
    if let Ok(stored) = std::fs::read(&path) {
        return key_of(&stored);
    }
    let key = fresh();
    write_key(&path, &key).ok()?;
    Some(key)
}

fn write_key(path: &Path, bytes: &[u8]) -> std::io::Result<()> {
    let partial = path.with_extension("partial");
    let mut options = std::fs::OpenOptions::new();
    options.write(true).create(true).truncate(true);
    #[cfg(unix)]
    std::os::unix::fs::OpenOptionsExt::mode(&mut options, 0o600);
    let written = options.open(&partial).and_then(|mut file| {
        std::io::Write::write_all(&mut file, bytes)?;
        file.sync_all()
    });
    match written.and_then(|_| std::fs::rename(&partial, path)) {
        Ok(()) => Ok(()),
        Err(error) => {
            let _ = std::fs::remove_file(&partial);
            Err(error)
        }
    }
}

#[cfg(any(target_os = "android", windows))]
fn wrapped_file(root: &Path, wrap: impl Fn(&[u8]) -> Option<Vec<u8>>, unwrap: impl Fn(&[u8]) -> Option<Vec<u8>>) -> Option<[u8; KEY]> {
    let path = root.join(".vault");
    if let Ok(stored) = std::fs::read(&path) {
        return unwrap(&stored).and_then(|key| key_of(&key));
    }
    let key = fresh();
    write_key(&path, &wrap(&key)?).ok()?;
    Some(key)
}

#[cfg(target_os = "android")]
mod platform {
    use super::*;
    use base64::Engine as _;

    pub fn load(root: &Path) -> Option<[u8; KEY]> {
        let call = |action: &str, bytes: &[u8]| {
            let answer = crate::android::vault(&format!("{action}:{}", base64::engine::general_purpose::STANDARD.encode(bytes)));
            base64::engine::general_purpose::STANDARD.decode(answer).ok().filter(|bytes| !bytes.is_empty())
        };
        wrapped_file(root, |key| call("wrap", key), |blob| call("unwrap", blob))
    }
}

#[cfg(windows)]
mod platform {
    use super::*;
    use windows_sys::Win32::Foundation::LocalFree;
    use windows_sys::Win32::Security::Cryptography::{CryptProtectData, CryptUnprotectData, CRYPT_INTEGER_BLOB};

    fn run(bytes: &[u8], protect: bool) -> Option<Vec<u8>> {
        let input = CRYPT_INTEGER_BLOB { cbData: bytes.len() as u32, pbData: bytes.as_ptr() as *mut u8 };
        let mut output = CRYPT_INTEGER_BLOB { cbData: 0, pbData: std::ptr::null_mut() };
        let done = unsafe {
            if protect {
                CryptProtectData(&input, std::ptr::null(), std::ptr::null(), std::ptr::null(), std::ptr::null(), 0, &mut output)
            } else {
                CryptUnprotectData(&input, std::ptr::null_mut(), std::ptr::null(), std::ptr::null(), std::ptr::null(), 0, &mut output)
            }
        };
        if done == 0 || output.pbData.is_null() {
            return None;
        }
        let result = unsafe { std::slice::from_raw_parts(output.pbData, output.cbData as usize).to_vec() };
        unsafe { LocalFree(output.pbData as _) };
        Some(result)
    }

    pub fn load(root: &Path) -> Option<[u8; KEY]> {
        wrapped_file(root, |key| run(key, true), |blob| run(blob, false))
    }
}

#[cfg(target_os = "macos")]
mod platform {
    use super::*;
    use security_framework::passwords::{get_generic_password, set_generic_password};

    const SERVICE: &str = "io.github.NaviVani_dev.Nari";
    const ACCOUNT: &str = "vault";
    const NOT_FOUND: i32 = -25300;

    pub fn load(root: &Path) -> Option<[u8; KEY]> {
        match get_generic_password(SERVICE, ACCOUNT) {
            Ok(stored) => key_of(&stored),
            Err(error) if error.code() == NOT_FOUND => {
                let key = fresh();
                match set_generic_password(SERVICE, ACCOUNT, &key) {
                    Ok(()) => Some(key),
                    Err(_) => key_file(root),
                }
            }
            Err(_) => key_file(root),
        }
    }
}

#[cfg(not(any(target_os = "linux", target_os = "android", target_os = "macos", windows)))]
mod platform {
    use super::*;

    pub fn load(root: &Path) -> Option<[u8; KEY]> {
        key_file(root)
    }
}

#[cfg(target_os = "linux")]
mod platform {
    use super::*;
    use sha2::{Digest, Sha256};
    use std::collections::HashMap;
    use std::time::Duration;
    use zbus::blocking::Connection;
    use zbus::zvariant::{ObjectPath, OwnedObjectPath, OwnedValue, Value};

    const SECRETS: &str = "org.freedesktop.secrets";
    const SERVICE_PATH: &str = "/org/freedesktop/secrets";
    const SERVICE: &str = "org.freedesktop.Secret.Service";
    const PROMPT_WAIT: Duration = Duration::from_secs(120);
    const PORTAL_WAIT: Duration = Duration::from_secs(10);

    type Secret = (OwnedObjectPath, Vec<u8>, Vec<u8>, String);

    pub fn load(root: &Path) -> Option<[u8; KEY]> {
        let from_system = if Path::new("/.flatpak-info").exists() { portal() } else { keyring() };
        from_system.or_else(|| key_file(root))
    }

    fn portal() -> Option<[u8; KEY]> {
        use std::io::Read;
        let connection = Connection::session().ok()?;
        let (mut reader, writer) = std::os::unix::net::UnixStream::pair().ok()?;
        reader.set_read_timeout(Some(PORTAL_WAIT)).ok()?;
        let options: HashMap<&str, Value> = HashMap::new();
        connection
            .call_method(
                Some("org.freedesktop.portal.Desktop"),
                "/org/freedesktop/portal/desktop",
                Some("org.freedesktop.portal.Secret"),
                "RetrieveSecret",
                &(zbus::zvariant::Fd::from(&writer), options),
            )
            .ok()?;
        drop(writer);
        let mut secret = Vec::new();
        reader.read_to_end(&mut secret).ok()?;
        if secret.is_empty() {
            return None;
        }
        Some(Sha256::digest(&secret).into())
    }

    fn keyring() -> Option<[u8; KEY]> {
        let connection = Connection::session().ok()?;
        let (_, session): (OwnedValue, OwnedObjectPath) = connection
            .call_method(Some(SECRETS), SERVICE_PATH, Some(SERVICE), "OpenSession", &("plain", Value::from("")))
            .ok()?
            .body()
            .deserialize()
            .ok()?;
        let attributes = HashMap::from([("application", "nari"), ("purpose", "private-settings")]);
        let (unlocked, locked): (Vec<OwnedObjectPath>, Vec<OwnedObjectPath>) = connection
            .call_method(Some(SECRETS), SERVICE_PATH, Some(SERVICE), "SearchItems", &(attributes.clone(),))
            .ok()?
            .body()
            .deserialize()
            .ok()?;
        let mut items = unlocked;
        if items.is_empty() && !locked.is_empty() {
            let (opened, prompt): (Vec<OwnedObjectPath>, OwnedObjectPath) = connection
                .call_method(Some(SECRETS), SERVICE_PATH, Some(SERVICE), "Unlock", &(locked.clone(),))
                .ok()?
                .body()
                .deserialize()
                .ok()?;
            items = if prompt.as_str() == "/" { opened } else if confirm(&connection, &prompt) { locked } else { Vec::new() };
        }
        if let Some(item) = items.first() {
            let secrets: HashMap<OwnedObjectPath, Secret> = connection
                .call_method(Some(SECRETS), SERVICE_PATH, Some(SERVICE), "GetSecrets", &(vec![item.clone()], &session))
                .ok()?
                .body()
                .deserialize()
                .ok()?;
            return secrets.into_values().next().and_then(|(_, _, value, _)| key_of(&value));
        }
        create(&connection, &session, attributes)
    }

    fn create(connection: &Connection, session: &OwnedObjectPath, attributes: HashMap<&str, &str>) -> Option<[u8; KEY]> {
        let collection: OwnedObjectPath = connection
            .call_method(Some(SECRETS), SERVICE_PATH, Some(SERVICE), "ReadAlias", &("default",))
            .ok()?
            .body()
            .deserialize()
            .ok()?;
        if collection.as_str() == "/" {
            return None;
        }
        let key = fresh();
        let properties: HashMap<&str, Value> = HashMap::from([
            ("org.freedesktop.Secret.Item.Label", Value::from("Nari private settings")),
            ("org.freedesktop.Secret.Item.Attributes", Value::from(attributes)),
        ]);
        let secret = (ObjectPath::from(session), Vec::<u8>::new(), key.to_vec(), "application/octet-stream");
        let (item, prompt): (OwnedObjectPath, OwnedObjectPath) = connection
            .call_method(Some(SECRETS), collection.as_str(), Some("org.freedesktop.Secret.Collection"), "CreateItem", &(properties, secret, true))
            .ok()?
            .body()
            .deserialize()
            .ok()?;
        let created = item.as_str() != "/" || (prompt.as_str() != "/" && confirm(connection, &prompt));
        created.then_some(key)
    }

    fn confirm(connection: &Connection, prompt: &OwnedObjectPath) -> bool {
        let Ok(proxy) = zbus::blocking::Proxy::new(connection, SECRETS, prompt.as_str(), "org.freedesktop.Secret.Prompt") else {
            return false;
        };
        let Ok(mut completed) = proxy.receive_signal("Completed") else {
            return false;
        };
        if proxy.call_method("Prompt", &("",)).is_err() {
            return false;
        }
        let (sender, receiver) = std::sync::mpsc::channel();
        std::thread::spawn(move || {
            let dismissed = completed.next().and_then(|message| message.body().deserialize::<(bool, OwnedValue)>().ok()).map(|(dismissed, _)| dismissed);
            let _ = sender.send(dismissed);
        });
        matches!(receiver.recv_timeout(PROMPT_WAIT), Ok(Some(false)))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn seals_and_opens_with_a_device_key() {
        let root = std::env::temp_dir().join(format!("nari-vault-{}", std::process::id()));
        std::fs::create_dir_all(&root).unwrap();
        let _ = ROOT.set(root.clone());
        let _ = MASTER.set(Some(fresh()));
        let sealed = seal(b"token=abc").unwrap();
        assert!(is_sealed(&sealed) && !sealed.windows(9).any(|window| window == b"token=abc"));
        assert_eq!(open(&sealed).unwrap(), b"token=abc");
        let mut tampered = sealed.clone();
        *tampered.last_mut().unwrap() ^= 1;
        assert!(open(&tampered).is_none());
        let plain = root.join("old.json");
        std::fs::write(&plain, b"{\"a\":1}").unwrap();
        assert_eq!(read(&plain).unwrap(), b"{\"a\":1}");
        assert!(is_sealed(&std::fs::read(&plain).unwrap()));
        assert_eq!(read(&plain).unwrap(), b"{\"a\":1}");
        std::fs::remove_dir_all(root).unwrap();
    }
}
