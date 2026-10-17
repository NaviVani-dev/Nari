mod bridge;
mod crypto;
mod runtime;
pub(crate) mod sandbox;
pub(crate) mod serve;
mod tcp;
mod thread;

use md5::{Digest, Md5};
use sha1::Sha1;
use sha2::Sha256;
use base64::Engine as _;
use mlua::serde::{LuaSerdeExt, SerializeOptions};
use mlua::{Lua, LuaString, Table, Value};
use serde_json::{Map, Value as Json};
use std::io::Read;
use std::path::{Path, PathBuf};
use std::collections::HashMap;
use std::sync::mpsc::{channel, Sender};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, SystemTime};

const HTTP_TIMEOUT: Duration = Duration::from_secs(20);
const HTTP_RETRIES: u32 = 2;
const RETRY_BASE: Duration = Duration::from_millis(500);
const RETRY_WAIT_LIMIT: Duration = Duration::from_secs(60);
const RETRY_STATUSES: [u16; 4] = [429, 502, 503, 504];
const RANDOM_LIMIT: usize = 4096;
const RESOLVE_TIMEOUT: Duration = Duration::from_secs(30);
const STREAM_CHUNK: usize = 64 * 1024;
const STREAM_ERROR_LIMIT: u64 = 1024 * 1024;
const BODY_LIMIT: u64 = 64 * 1024 * 1024;
const COMMON: &str = include_str!("common.lua");

pub enum Inbox {
    Thread(i64, Json),
    ThreadFailed(i64, Failure),
    Error(Failure),
    Serve(u64, serve::Incoming),
    Http(u64, Result<Answer, String>),
    Log(String, String),
}

#[derive(Clone)]
pub struct Info {
    pub id: String,
    pub folder: PathBuf,
    pub data: PathBuf,
    pub policy: Arc<sandbox::Policy>,
}

#[derive(Default)]
struct Latest {
    track: Option<Json>,
    state: Option<Json>,
}

#[derive(Default)]
struct Hub {
    latest: Mutex<Latest>,
    threads: Mutex<Vec<Sender<thread::Message>>>,
    resolvers: Mutex<HashMap<String, (u64, Sender<thread::Message>)>>,
    sources: Mutex<HashMap<String, (u64, Sender<thread::Message>)>>,
    unsavable: Mutex<HashMap<String, u64>>,
    sealed: Mutex<HashMap<String, u64>>,
    named: Mutex<HashMap<(String, String), (u64, Sender<thread::Message>)>>,
}

fn hub() -> &'static Hub {
    static HUB: OnceLock<Hub> = OnceLock::new();
    HUB.get_or_init(Hub::default)
}

pub fn emit(event: &'static str, payload: Json) {
    let hub = hub();
    let mut latest = hub.latest.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    match event {
        "track" => latest.track = Some(payload.clone()),
        "state" => latest.state = Some(payload.clone()),
        _ => {}
    }
    hub.threads
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
        .retain(|sender| sender.send(thread::Message::Event(event, payload.clone())).is_ok());
}

pub fn resolve(uri: &str) -> Option<Result<String, String>> {
    let (scheme, id) = uri.split_once(':')?;
    let sender = hub()
        .resolvers
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
        .get(scheme)?
        .1
        .clone();
    let (reply, answer) = channel();
    sender
        .send(thread::Message::Resolve { scheme: scheme.to_owned(), id: id.to_owned(), reply })
        .ok()?;
    Some(
        answer
            .recv_timeout(RESOLVE_TIMEOUT)
            .unwrap_or_else(|_| Err(format!("the plugin that plays '{scheme}' did not answer"))),
    )
}

pub fn open_source(uri: &str) -> Option<Result<crate::stream::Stream, String>> {
    let (scheme, id) = uri.split_once(':')?;
    let sender = hub()
        .sources
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
        .get(scheme)?
        .1
        .clone();
    let (feed, stream) = crate::stream::channel(false, None);
    sender
        .send(thread::Message::Open { scheme: scheme.to_owned(), id: id.to_owned(), feed })
        .ok()?;
    if !stream.wait_ready(RESOLVE_TIMEOUT) {
        return Some(Err(format!("the plugin that plays '{scheme}' did not answer")));
    }
    Some(stream.early_error().map_or(Ok(stream), Err))
}

fn register_resolver(scheme: String, thread: u64, sender: Sender<thread::Message>) {
    hub()
        .resolvers
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
        .insert(scheme, (thread, sender));
}

fn register_named(plugin: &str, name: String, thread: u64, sender: Sender<thread::Message>) {
    hub().named.lock().unwrap_or_else(|poisoned| poisoned.into_inner()).insert((plugin.to_owned(), name), (thread, sender));
}

fn find_named(plugin: &str, name: &str) -> Option<(u64, Sender<thread::Message>)> {
    hub().named.lock().unwrap_or_else(|poisoned| poisoned.into_inner()).get(&(plugin.to_owned(), name.to_owned())).cloned()
}

pub fn savable(uri: &str) -> bool {
    let Some((scheme, _)) = uri.split_once(':') else {
        return true;
    };
    !hub().unsavable.lock().unwrap_or_else(|poisoned| poisoned.into_inner()).contains_key(scheme)
}

pub fn sealed(uri: &str) -> bool {
    let Some((scheme, _)) = uri.split_once(':') else {
        return false;
    };
    hub().sealed.lock().unwrap_or_else(|poisoned| poisoned.into_inner()).contains_key(scheme)
}

fn register_source(scheme: String, save: &str, thread: u64, sender: Sender<thread::Message>) {
    for (registry, wanted) in [(&hub().unsavable, "deny"), (&hub().sealed, "sealed")] {
        let mut marked = registry.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        if save == wanted {
            marked.insert(scheme.clone(), thread);
        } else {
            marked.remove(&scheme);
        }
    }
    hub()
        .sources
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
        .insert(scheme, (thread, sender));
}

fn forget_resolvers(thread: u64) {
    for registry in [&hub().resolvers, &hub().sources] {
        registry
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .retain(|_, (owner, _)| *owner != thread);
    }
    for registry in [&hub().unsavable, &hub().sealed] {
        registry.lock().unwrap_or_else(|poisoned| poisoned.into_inner()).retain(|_, owner| *owner != thread);
    }
    hub().named.lock().unwrap_or_else(|poisoned| poisoned.into_inner()).retain(|_, (owner, _)| *owner != thread);
}

fn subscribe(sender: Sender<thread::Message>) -> Vec<(&'static str, Json)> {
    let hub = hub();
    let latest = hub.latest.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    hub.threads
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
        .push(sender);
    let mut replay = Vec::new();
    if let Some(track) = latest.track.clone().filter(|track| !track.is_null()) {
        replay.push(("track", track));
        if let Some(state) = latest.state.clone() {
            replay.push(("state", state));
        }
    }
    replay
}

const MEMORY_LIMIT: usize = 128 * 1024 * 1024;
const TRACE_DEPTH: usize = 24;

#[derive(Debug, Default)]
pub struct Timeout(pub String);

impl std::fmt::Display for Timeout {
    fn fmt(&self, formatter: &mut std::fmt::Formatter) -> std::fmt::Result {
        if !self.0.is_empty() {
            write!(formatter, "{}: ", self.0)?;
        }
        write!(formatter, "the script ran for more than {} seconds without stopping, so it was stopped", runtime::TIME_LIMIT.as_secs())
    }
}

impl std::error::Error for Timeout {}

#[derive(Clone, Debug, Default)]
pub struct Failure {
    pub message: String,
    pub trace: String,
    pub fatal: bool,
}

impl Failure {
    pub fn of(error: &mlua::Error) -> Self {
        match error {
            mlua::Error::CallbackError { traceback, cause } => {
                let mut failure = Self::of(cause);
                if failure.trace.is_empty() {
                    failure.trace = trace_of(traceback);
                }
                failure
            }
            mlua::Error::WithContext { cause, .. } => Self::of(cause),
            mlua::Error::RuntimeError(message) => {
                let (message, trace) = message.split_once("\nstack traceback:").unwrap_or((message, ""));
                Self { message: message.to_owned(), trace: trace_of(trace), fatal: false }
            }
            mlua::Error::SyntaxError { message, .. } => Self { message: message.clone(), ..Self::default() },
            mlua::Error::MemoryError(_) => Self {
                message: format!("the script used more than {} MB of memory, so it was stopped", MEMORY_LIMIT / 1024 / 1024),
                fatal: true,
                ..Self::default()
            },
            mlua::Error::ExternalError(inner) if inner.downcast_ref::<Timeout>().is_some() => {
                Self { message: inner.to_string(), fatal: true, ..Self::default() }
            }
            other => Self { message: other.to_string(), ..Self::default() },
        }
    }

    pub fn message(message: String, trace: String) -> Self {
        Self { message, trace: trace_of(&trace), fatal: false }
    }
}

fn trace_of(trace: &str) -> String {
    trace
        .trim()
        .trim_start_matches("stack traceback:")
        .lines()
        .map(str::trim)
        .filter(|line| !line.is_empty() && !line.starts_with("[C]") && !line.starts_with("nari/"))
        .collect::<Vec<_>>()
        .join("\n")
}

fn digest(lua: &Lua, bytes: &[u8], raw: Option<bool>) -> mlua::Result<Value> {
    if raw.unwrap_or(false) {
        lua.create_string(bytes).map(Value::String)
    } else {
        lua.create_string(hex(bytes)).map(Value::String)
    }
}

fn traceback(lua: &Lua) -> String {
    let mut lines = Vec::new();
    for level in 1..TRACE_DEPTH {
        let Some(line) = lua.inspect_stack(level, |debug| {
            let source = debug.source();
            let file = source.short_src.map(|file| file.into_owned()).unwrap_or_default();
            if source.what == "C" || file.starts_with("nari/") {
                return None;
            }
            let place = match debug.names().name {
                Some(name) => format!("in function '{name}'"),
                None if source.what == "main" => "in main chunk".to_owned(),
                None => format!("in function <{file}:{}>", source.line_defined.unwrap_or(0)),
            };
            Some(format!("{file}:{}: {place}", debug.current_line().unwrap_or(0)))
        }) else {
            break;
        };
        lines.extend(line);
    }
    lines.join("\n")
}

fn limit_memory(lua: &Lua) {
    let _ = lua.set_memory_limit(MEMORY_LIMIT);
}

fn report(id: &str, error: &mlua::Error) {
    notify(id, &Failure::of(error));
}

fn notify(id: &str, failure: &Failure) {
    let Some(tree) = <godot::classes::Engine as godot::obj::Singleton>::singleton()
        .get_main_loop()
        .and_then(|main_loop| main_loop.try_cast::<godot::classes::SceneTree>().ok())
    else {
        return;
    };
    let Some(mut plugins) = tree.get_root().get_node_or_null("Plugins") else {
        return;
    };
    plugins.call_deferred(
        "report_error",
        &[
            godot::prelude::ToGodot::to_variant(&id),
            godot::prelude::ToGodot::to_variant(&failure.message),
            godot::prelude::ToGodot::to_variant(&failure.trace),
            godot::prelude::ToGodot::to_variant(&failure.fatal),
        ],
    );
}

fn to_lua(lua: &Lua, value: &Json) -> mlua::Result<Value> {
    lua.to_value_with(
        value,
        SerializeOptions::new()
            .serialize_none_to_null(false)
            .serialize_unit_to_null(false),
    )
}

fn from_lua(lua: &Lua, value: Value) -> mlua::Result<Json> {
    lua.from_value::<Json>(value)
}

fn install(lua: &Lua, info: &Info) -> mlua::Result<Table> {
    let package: Table = lua.globals().get("package")?;
    package.set("path", format!("{}/?.lua", info.folder.to_string_lossy()))?;
    let nari = lua.create_table()?;
    let plugin = lua.create_table()?;
    plugin.set("id", info.id.as_str())?;
    plugin.set("folder", info.folder.to_string_lossy().as_ref())?;
    plugin.set("data", info.data.join(&info.id).to_string_lossy().as_ref())?;
    nari.set("plugin", plugin)?;
    let id = info.id.clone();
    lua.globals().set(
        "__nari_log",
        lua.create_function(move |_, (_level, text): (String, String)| {
            godot::global::godot_print!("[plugin {id}] {text}");
            Ok(())
        })?,
    )?;
    nari.set(
        "json_encode",
        lua.create_function(|lua, value: Value| {
            serde_json::to_string(&from_lua(lua, value)?).map_err(mlua::Error::external)
        })?,
    )?;
    nari.set(
        "json_decode",
        lua.create_function(|lua, text: String| {
            to_lua(lua, &serde_json::from_str::<Json>(&text).map_err(mlua::Error::external)?)
        })?,
    )?;
    nari.set(
        "md5",
        lua.create_function(|lua, (text, raw): (LuaString, Option<bool>)| digest(lua, &Md5::digest(text.as_bytes()), raw))?,
    )?;
    nari.set(
        "sha1",
        lua.create_function(|lua, (text, raw): (LuaString, Option<bool>)| digest(lua, &Sha1::digest(text.as_bytes()), raw))?,
    )?;
    nari.set(
        "sha256",
        lua.create_function(|lua, (text, raw): (LuaString, Option<bool>)| digest(lua, &Sha256::digest(text.as_bytes()), raw))?,
    )?;
    nari.set(
        "hmac_sha256",
        lua.create_function(|lua, (key, text, raw): (LuaString, LuaString, Option<bool>)| {
            digest(lua, &crypto::hmac::<Sha256>(&key.as_bytes(), &text.as_bytes()), raw)
        })?,
    )?;
    nari.set(
        "base64_encode",
        lua.create_function(|_, (data, url_safe): (LuaString, Option<bool>)| {
            Ok(if url_safe.unwrap_or(false) {
                base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(data.as_bytes())
            } else {
                base64::engine::general_purpose::STANDARD.encode(data.as_bytes())
            })
        })?,
    )?;
    nari.set(
        "base64_decode",
        lua.create_function(|lua, text: String| {
            let text = text.trim().trim_end_matches('=');
            let bytes = base64::engine::general_purpose::STANDARD_NO_PAD
                .decode(text)
                .or_else(|_| base64::engine::general_purpose::URL_SAFE_NO_PAD.decode(text))
                .map_err(|_| mlua::Error::runtime("nari.base64_decode(): the text isn't valid base64"))?;
            lua.create_string(bytes)
        })?,
    )?;
    nari.set(
        "random_bytes",
        lua.create_function(|lua, count: usize| {
            if count > RANDOM_LIMIT {
                return Err(mlua::Error::runtime(format!("nari.random_bytes(): ask for {RANDOM_LIMIT} bytes or less")));
            }
            lua.create_string((0..count).map(|_| rand::random::<u8>()).collect::<Vec<_>>())
        })?,
    )?;
    let file = info.data.join(format!("{}.json", info.id));
    let private = info.data.join(format!("{}.private", info.id));
    let (reading, reading_private) = (file.clone(), private.clone());
    nari.set(
        "get",
        lua.create_function(move |lua, key: String| {
            if let Some(value) = stored_value(&reading_private, &key, read_private).map_err(mlua::Error::external)? {
                return to_lua(lua, &value);
            }
            let value = stored_value(&reading, &key, read_data).map_err(mlua::Error::external)?;
            to_lua(lua, value.as_ref().unwrap_or(&Json::Null))
        })?,
    )?;
    nari.set(
        "set",
        lua.create_function(move |lua, (key, value, options): (String, Value, Option<Table>)| {
            let value = from_lua(lua, value)?;
            let wants_private = options.map(|options| options.get::<Option<bool>>("private")).transpose()?.flatten().unwrap_or(false);
            let _guard = data_lock();
            let mut stored = stored_map(&file, read_data).map_err(mlua::Error::external)?;
            let mut hidden = stored_map(&private, read_private).map_err(mlua::Error::external)?;
            let secret = wants_private || hidden.contains_key(&key);
            let removed_plain = stored.remove(&key).is_some();
            let removed_hidden = hidden.remove(&key).is_some();
            match (value, secret) {
                (Json::Null, _) => {}
                (value, true) => {
                    hidden.insert(key, value);
                }
                (value, false) => {
                    stored.insert(key, value);
                }
            }
            if secret || removed_hidden {
                crate::vault::write(&private, &serde_json::to_vec(&hidden).map_err(mlua::Error::external)?).map_err(mlua::Error::external)?;
                remember(&private, hidden);
            }
            if !secret || removed_plain {
                write_data(&file, &stored).map_err(mlua::Error::external)?;
                remember(&file, stored);
            }
            Ok(())
        })?,
    )?;
    crypto::install(lua, &nari)?;
    lua.globals().set("__nari_traceback", lua.create_function(|lua, ()| Ok(traceback(lua)))?)?;
    lua.globals().set("nari", &nari)?;
    sandbox::restrict_lua(lua, &info.policy)?;
    sandbox::permissions_global(lua, &info.policy)?;
    lua.load(COMMON).set_name("@nari/common.lua").exec()?;
    Ok(nari)
}

pub(crate) fn hex(bytes: &[u8]) -> String {
    const DIGITS: &[u8; 16] = b"0123456789abcdef";
    let mut text = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        text.push(DIGITS[usize::from(byte >> 4)] as char);
        text.push(DIGITS[usize::from(byte & 0x0f)] as char);
    }
    text
}

type Stamp = (SystemTime, u64);

struct Stored {
    stamp: Stamp,
    values: Map<String, Json>,
}

fn stored_cache() -> std::sync::MutexGuard<'static, HashMap<PathBuf, Stored>> {
    static CACHE: OnceLock<Mutex<HashMap<PathBuf, Stored>>> = OnceLock::new();
    CACHE.get_or_init(Mutex::default).lock().unwrap_or_else(|poisoned| poisoned.into_inner())
}

fn stamp_of(file: &Path) -> Option<Stamp> {
    let meta = std::fs::metadata(file).ok()?;
    Some((meta.modified().ok()?, meta.len()))
}

fn stored_value(file: &Path, key: &str, read: fn(&Path) -> Result<Map<String, Json>, String>) -> Result<Option<Json>, String> {
    let Some(stamp) = stamp_of(file) else {
        return Ok(None);
    };
    if let Some(entry) = stored_cache().get(file).filter(|entry| entry.stamp == stamp) {
        return Ok(entry.values.get(key).cloned());
    }
    let values = read(file)?;
    let value = values.get(key).cloned();
    stored_cache().insert(file.to_path_buf(), Stored { stamp, values });
    Ok(value)
}

fn stored_map(file: &Path, read: fn(&Path) -> Result<Map<String, Json>, String>) -> Result<Map<String, Json>, String> {
    let cached = stamp_of(file).and_then(|stamp| {
        stored_cache().get(file).filter(|entry| entry.stamp == stamp).map(|entry| entry.values.clone())
    });
    match cached {
        Some(values) => Ok(values),
        None => read(file),
    }
}

fn remember(file: &Path, values: Map<String, Json>) {
    match stamp_of(file) {
        Some(stamp) => {
            stored_cache().insert(file.to_path_buf(), Stored { stamp, values });
        }
        None => {
            stored_cache().remove(file);
        }
    }
}

fn data_lock() -> std::sync::MutexGuard<'static, ()> {
    static LOCK: Mutex<()> = Mutex::new(());
    LOCK.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
}

pub struct Request {
    method: String,
    url: String,
    headers: Vec<(String, String)>,
    body: Vec<u8>,
    save: Option<PathBuf>,
    retries: u32,
}

pub struct Answer {
    status: u16,
    body: Vec<u8>,
    path: Option<PathBuf>,
    headers: Vec<(String, String)>,
    attempts: u32,
}

impl Request {
    fn from_table(table: &Table, info: &Info) -> mlua::Result<Self> {
        let mut headers = Vec::new();
        if let Some(pairs) = table.get::<Option<Table>>("headers")? {
            for pair in pairs.pairs::<String, String>() {
                headers.push(pair?);
            }
        }
        let save = match table.get::<Option<String>>("save")? {
            Some(file) => {
                let relative = Path::new(&file);
                if file.is_empty() || !relative.components().all(|part| matches!(part, std::path::Component::Normal(_))) {
                    return Err(mlua::Error::runtime("nari.http(): 'save' must be a path inside the plugin data folder"));
                }
                Some(info.data.join(&info.id).join(relative))
            }
            None => None,
        };
        Ok(Self {
            method: table.get::<Option<String>>("method")?.unwrap_or_else(|| "GET".into()).to_uppercase(),
            url: table.get("url")?,
            headers,
            body: table.get::<Option<LuaString>>("body")?.map(|body| body.as_bytes().to_vec()).unwrap_or_default(),
            save,
            retries: table.get::<Option<u32>>("retries")?.unwrap_or(HTTP_RETRIES).min(10),
        })
    }

    fn send(self) -> Result<Answer, String> {
        let mut attempt = 0;
        loop {
            attempt += 1;
            let result = self.attempt();
            let wait = match &result {
                Ok(answer) if RETRY_STATUSES.contains(&answer.status) => Some(retry_after(&answer.headers)),
                Ok(_) => None,
                Err(_) => Some(None),
            };
            match wait {
                Some(wait) if attempt <= self.retries => std::thread::sleep(wait.unwrap_or_else(|| backoff(attempt))),
                _ => return result.map(|answer| Answer { attempts: attempt, ..answer }),
            }
        }
    }

    fn open(&self, agent: &ureq::Agent) -> Result<(u16, Vec<(String, String)>, ureq::http::Response<ureq::Body>), String> {
        let mut builder = ureq::http::Request::builder().method(self.method.as_str()).uri(self.url.as_str());
        for (name, value) in &self.headers {
            builder = builder.header(name, value);
        }
        let request = builder.body(self.body.clone()).map_err(|error| error.to_string())?;
        let response = agent.run(request).map_err(|error| error.to_string())?;
        let status = response.status().as_u16();
        let headers = response
            .headers()
            .iter()
            .map(|(name, value)| (name.as_str().to_lowercase(), String::from_utf8_lossy(value.as_bytes()).into_owned()))
            .collect::<Vec<_>>();
        Ok((status, headers, response))
    }

    fn stream<E>(&self, mut sink: impl FnMut(&[u8]) -> Result<bool, E>) -> Result<Result<Answer, String>, E> {
        let mut attempt = 0;
        loop {
            attempt += 1;
            let mut delivered = false;
            let result = match self.open(stream_agent()) {
                Ok((status, headers, mut response)) if (200..300).contains(&status) => {
                    let mut reader = response.body_mut().as_reader();
                    let mut chunk = vec![0u8; STREAM_CHUNK];
                    let mut outcome = Ok(Answer { status, body: Vec::new(), path: None, headers, attempts: 1 });
                    loop {
                        match reader.read(&mut chunk) {
                            Ok(0) => break,
                            Ok(read) => {
                                delivered = true;
                                if !sink(&chunk[..read])? {
                                    break;
                                }
                            }
                            Err(error) if error.kind() == std::io::ErrorKind::Interrupted => {}
                            Err(error) => {
                                outcome = Err(error.to_string());
                                break;
                            }
                        }
                    }
                    outcome
                }
                Ok((status, headers, mut response)) => {
                    let mut body = Vec::new();
                    let _ = response.body_mut().as_reader().take(STREAM_ERROR_LIMIT).read_to_end(&mut body);
                    Ok(Answer { status, body, path: None, headers, attempts: 1 })
                }
                Err(error) => Err(error),
            };
            let wait = match &result {
                Ok(answer) if RETRY_STATUSES.contains(&answer.status) => Some(retry_after(&answer.headers)),
                Err(_) if !delivered => Some(None),
                _ => None,
            };
            match wait {
                Some(wait) if attempt <= self.retries => std::thread::sleep(wait.unwrap_or_else(|| backoff(attempt))),
                _ => return Ok(result.map(|answer| Answer { attempts: attempt, ..answer })),
            }
        }
    }

    fn attempt(&self) -> Result<Answer, String> {
        let (status, headers, mut response) = self.open(agent())?;
        let mut reader = response.body_mut().as_reader();
        let Some(path) = self.save.clone() else {
            let body = read_capped(&mut reader, BODY_LIMIT)?;
            return Ok(Answer { status, body, path: None, headers, attempts: 1 });
        };
        if (200..300).contains(&status) {
            save_body(&mut reader, &path).map_err(|error| error.to_string())?;
        }
        Ok(Answer { status, body: Vec::new(), path: Some(path), headers, attempts: 1 })
    }
}

fn read_capped(reader: &mut impl Read, limit: u64) -> Result<Vec<u8>, String> {
    let mut body = Vec::new();
    reader.take(limit + 1).read_to_end(&mut body).map_err(|error| error.to_string())?;
    if body.len() as u64 > limit {
        return Err(format!("the answer is bigger than {} MB, save it to a file instead", limit / 1024 / 1024));
    }
    Ok(body)
}

fn save_body(reader: &mut impl Read, path: &Path) -> std::io::Result<()> {
    if let Some(folder) = path.parent() {
        std::fs::create_dir_all(folder)?;
    }
    let partial = path.with_extension("part");
    let copied = std::fs::File::create(&partial).and_then(|mut file| std::io::copy(reader, &mut file));
    if let Err(error) = copied.and_then(|_| std::fs::rename(&partial, path)) {
        let _ = std::fs::remove_file(&partial);
        return Err(error);
    }
    Ok(())
}

fn retry_after(headers: &[(String, String)]) -> Option<Duration> {
    headers
        .iter()
        .find(|(name, _)| name == "retry-after")
        .and_then(|(_, value)| value.trim().parse::<f64>().ok())
        .filter(|seconds| seconds.is_finite() && *seconds >= 0.0)
        .map(|seconds| Duration::from_secs_f64(seconds).min(RETRY_WAIT_LIMIT))
}

fn backoff(attempt: u32) -> Duration {
    let base = RETRY_BASE * 2u32.pow(attempt.saturating_sub(1).min(6));
    base + base.mul_f64(rand::random::<f64>() * 0.5)
}

fn response(lua: &Lua, result: Result<Answer, String>) -> mlua::Result<(Value, Option<String>)> {
    match result {
        Ok(answer) => {
            let table = lua.create_table()?;
            table.set("status", answer.status)?;
            table.set("body", lua.create_string(answer.body)?)?;
            table.set("attempts", answer.attempts)?;
            let headers = lua.create_table()?;
            for (name, value) in answer.headers {
                let value = match headers.get::<Option<String>>(name.as_str())? {
                    Some(earlier) => format!("{earlier}\n{value}"),
                    None => value,
                };
                headers.set(name, value)?;
            }
            table.set("headers", headers)?;
            if let Some(path) = answer.path {
                table.set("path", path.to_string_lossy().as_ref())?;
            }
            Ok((Value::Table(table), None))
        }
        Err(error) => Ok((Value::Nil, Some(error))),
    }
}

fn agent() -> &'static ureq::Agent {
    static AGENT: OnceLock<ureq::Agent> = OnceLock::new();
    AGENT.get_or_init(|| {
        ureq::Agent::config_builder()
            .timeout_global(Some(HTTP_TIMEOUT))
            .http_status_as_error(false)
            .build()
            .into()
    })
}

fn stream_agent() -> &'static ureq::Agent {
    static AGENT: OnceLock<ureq::Agent> = OnceLock::new();
    AGENT.get_or_init(|| {
        ureq::Agent::config_builder()
            .timeout_connect(Some(HTTP_TIMEOUT))
            .timeout_recv_response(Some(HTTP_TIMEOUT))
            .http_status_as_error(false)
            .build()
            .into()
    })
}

fn read_data(file: &Path) -> Result<Map<String, Json>, String> {
    match std::fs::read_to_string(file) {
        Ok(text) => serde_json::from_str(&text).map_err(|error| format!("{}: {error}", file.display())),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(Map::new()),
        Err(error) => Err(error.to_string()),
    }
}

fn read_private(file: &Path) -> Result<Map<String, Json>, String> {
    if !file.exists() {
        return Ok(Map::new());
    }
    let bytes = crate::vault::read(file).ok_or_else(|| format!("{}: the private storage couldn't be opened", file.display()))?;
    serde_json::from_slice(&bytes).map_err(|error| format!("{}: {error}", file.display()))
}

fn write_data(file: &Path, stored: &Map<String, Json>) -> std::io::Result<()> {
    crate::storage::write_atomically(file, &serde_json::to_vec(stored)?)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use std::sync::mpsc::{channel, RecvTimeoutError};

    fn folder(name: &str, files: &[(&str, &str)]) -> Info {
        let folder = std::env::temp_dir().join(format!("nari-{name}-{}", std::process::id()));
        std::fs::create_dir_all(&folder).unwrap();
        for (file, source) in files {
            std::fs::write(folder.join(file), source).unwrap();
        }
        Info { id: name.into(), data: folder.clone(), folder, policy: Arc::new(sandbox::Policy::unrestricted()) }
    }

    fn failure_of(info: &Info, script: &str) -> (bool, Failure) {
        let (outbox, inbox) = channel();
        let _handle = thread::spawn(info.clone(), info.folder.join(script), 1, outbox, None);
        match inbox.recv_timeout(Duration::from_secs(20)).unwrap() {
            Inbox::ThreadFailed(1, failure) => (true, failure),
            Inbox::Error(failure) => (false, failure),
            _ => panic!("unexpected message"),
        }
    }

    fn flaky_server(failures: usize) -> (String, std::thread::JoinHandle<usize>) {
        use std::io::{BufRead, BufReader, Write};
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let url = format!("http://{}/", listener.local_addr().unwrap());
        let handle = std::thread::spawn(move || {
            let mut served = 0;
            for stream in listener.incoming().take(failures + 1) {
                let mut stream = stream.unwrap();
                let mut reader = BufReader::new(stream.try_clone().unwrap());
                let mut line = String::new();
                while reader.read_line(&mut line).unwrap() > 2 {
                    line.clear();
                }
                served += 1;
                let reply = if served <= failures {
                    "HTTP/1.1 503 Busy\r\nRetry-After: 0\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".to_owned()
                } else {
                    "HTTP/1.1 200 OK\r\nX-Token: abc\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok".to_owned()
                };
                stream.write_all(reply.as_bytes()).unwrap();
            }
            served
        });
        (url, handle)
    }

    fn request(url: &str, retries: u32) -> Request {
        Request { method: "GET".into(), url: url.into(), headers: Vec::new(), body: Vec::new(), save: None, retries }
    }

    #[test]
    fn repeated_headers_reach_lua_joined_by_lines() {
        let lua = Lua::new();
        let headers = vec![("set-cookie".to_owned(), "a=1; Path=/".to_owned()), ("x-one".to_owned(), "1".to_owned()), ("set-cookie".to_owned(), "b=2".to_owned())];
        let answer = Answer { status: 200, body: Vec::new(), path: None, headers, attempts: 1 };
        let (Value::Table(table), None) = response(&lua, Ok(answer)).unwrap() else {
            panic!("no response table");
        };
        let headers: Table = table.get("headers").unwrap();
        assert_eq!(headers.get::<String>("set-cookie").unwrap(), "a=1; Path=/\nb=2");
        assert_eq!(headers.get::<String>("x-one").unwrap(), "1");
    }

    #[test]
    fn http_retries_busy_servers_and_keeps_headers() {
        let (url, server) = flaky_server(2);
        let answer = request(&url, 2).send().unwrap();
        assert_eq!((answer.status, answer.body.as_slice(), answer.attempts), (200, &b"ok"[..], 3));
        assert!(answer.headers.contains(&("x-token".to_owned(), "abc".to_owned())));
        assert_eq!(server.join().unwrap(), 3);
        let (url, server) = flaky_server(1);
        let answer = request(&url, 0).send().unwrap();
        assert_eq!((answer.status, answer.attempts), (503, 1));
        drop(server);
        assert_eq!(retry_after(&[("retry-after".into(), "999".into())]), Some(RETRY_WAIT_LIMIT));
        assert!(backoff(3) >= RETRY_BASE * 4);
    }

    #[test]
    fn hex_and_capped_bodies() {
        assert_eq!(hex(&[0x00, 0x0f, 0xa5, 0xff]), "000fa5ff");
        assert_eq!(read_capped(&mut &b"12345"[..], 5).unwrap(), b"12345");
        assert!(read_capped(&mut &b"123456"[..], 5).is_err());
    }

    #[test]
    fn http_keeps_binary_bodies() {
        use std::io::{Read, Write};
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let url = format!("http://{}/", listener.local_addr().unwrap());
        let server = std::thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let mut received = Vec::new();
            let mut chunk = [0u8; 1024];
            while !received.ends_with(&[0xff, 0x00, 0x80]) {
                let count = stream.read(&mut chunk).unwrap();
                received.extend_from_slice(&chunk[..count]);
            }
            stream.write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 4\r\nConnection: close\r\n\r\n\x00\xfe\xff\x80").unwrap();
        });
        let answer = Request { method: "POST".into(), body: vec![0xff, 0x00, 0x80], ..request(&url, 0) }.send().unwrap();
        assert_eq!(answer.body, vec![0x00, 0xfe, 0xff, 0x80]);
        server.join().unwrap();
    }

    #[test]
    fn threads_stream_http_and_talk_tcp() {
        use std::io::{BufRead, BufReader, Write};
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        std::thread::spawn(move || {
            for connection in listener.incoming() {
                let mut stream = connection.unwrap();
                let mut reader = BufReader::new(stream.try_clone().unwrap());
                let mut line = String::new();
                reader.read_line(&mut line).unwrap();
                if line.starts_with("GET") {
                    while reader.read_line(&mut line).unwrap() > 2 {
                        line.clear();
                    }
                    let body = vec![b'z'; 200_000];
                    write!(stream, "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n", body.len()).unwrap();
                    let _ = stream.write_all(&body);
                    continue;
                }
                stream.write_all(line.to_uppercase().as_bytes()).unwrap();
                stream.write_all(b"\x00\xffpushed").unwrap();
            }
        });
        let info = folder(
            "network",
            &[(
                "worker.lua",
                &format!(
                    r#"
                    local total, chunks = 0, 0
                    local response = nari.http({{ url = "http://127.0.0.1:{port}/big", stream = function(chunk)
                        total = total + #chunk
                        chunks = chunks + 1
                    end }})
                    local first = nari.http({{ url = "http://127.0.0.1:{port}/big", stream = function(chunk) return false end }})
                    local socket = assert(nari.tcp({{ host = "127.0.0.1", port = {port} }}))
                    socket:send("hello\n")
                    local echo = socket:receive(6, 5)
                    local binary = socket:receive(2, 5)
                    local missing, problem = nari.tcp({{ host = "127.0.0.1", port = 1, timeout = 2 }})
                    local pushed = ""
                    socket:on_data(function(bytes) pushed = pushed .. bytes end)
                    socket:on_close(function()
                        nari.send({{ total = total, many = chunks > 1, status = response.status, first = first.status,
                            echo = echo, binary = binary == "\0\255", pushed = pushed, refused = missing == nil and problem ~= nil }})
                    end)
                    "#
                ),
            )],
        );
        let (outbox, inbox) = channel();
        let _handle = thread::spawn(info.clone(), info.folder.join("worker.lua"), 5, outbox, None);
        let Ok(Inbox::Thread(5, value)) = inbox.recv_timeout(Duration::from_secs(10)) else {
            panic!("the script didn't answer");
        };
        assert_eq!(value, json!({ "total": 200_000, "many": true, "status": 200, "first": 200, "echo": "HELLO\n", "binary": true, "pushed": "pushed", "refused": true }));
        std::fs::remove_dir_all(info.folder).unwrap();
    }

    #[test]
    fn named_threads_answer_questions_later() {
        let info = folder(
            "asking",
            &[
                (
                    "session.lua",
                    r#"
                    nari.on("ask", function(question, reply)
                        if question.now then return { got = question.now } end
                        if question.fail then error("broken question") end
                        nari.after(0.05, function() reply({ later = question.later }) end)
                    end)
                    "#,
                ),
                (
                    "client.lua",
                    r#"
                    nari.on("message", function()
                        local now = nari.ask("session", { now = 1 })
                        local later = nari.ask("session", { later = "key" })
                        local _, failed = nari.ask("session", { fail = true })
                        local _, nobody = nari.ask("nobody", {})
                        local _, slow = nari.ask("session", { silent = true }, 0.01)
                        local ok = pcall(nari.ask, "client", {})
                        nari.send({ now = now.got, later = later.later, failed = failed, nobody = nobody, self = ok })
                    end)
                    "#,
                ),
            ],
        );
        let (outbox, inbox) = channel();
        let _session = thread::spawn(info.clone(), info.folder.join("session.lua"), 1, outbox.clone(), Some("session".into()));
        let client = thread::spawn(info.clone(), info.folder.join("client.lua"), 2, outbox, Some("client".into()));
        std::thread::sleep(Duration::from_millis(100));
        client.send(json!(null));
        let value = loop {
            match inbox.recv_timeout(Duration::from_secs(10)).unwrap() {
                Inbox::Thread(2, value) => break value,
                Inbox::Error(_) => {}
                _ => panic!("unexpected message"),
            }
        };
        assert_eq!(value["now"], 1);
        assert_eq!(value["later"], "key");
        assert!(value["failed"].as_str().unwrap().contains("broken question"), "{value}");
        assert!(value["nobody"].as_str().unwrap().contains("nobody"));
        assert_eq!(value["self"], false);
        std::fs::remove_dir_all(info.folder).unwrap();
    }

    #[test]
    fn sources_jump_to_what_the_player_wants() {
        use std::io::{Read, Seek, SeekFrom};
        let info = folder(
            "jumping",
            &[(
                "worker.lua",
                r#"
                nari.source("jump", function(id, out)
                    out:size(1000)
                    local at = 0
                    while at < 1000 do
                        local wanted = out:wanted()
                        if wanted and wanted ~= at then at = wanted end
                        local piece = string.rep(string.char(at % 256), 1)
                        for i = 1, 99 do piece = piece .. string.char((at + i) % 256) end
                        if not out:write(piece:sub(1, math.min(100, 1000 - at)), at) then return end
                        at = at + 100
                        local seen = 0
                        while out:wanted() == nil and seen < 5 do seen = seen + 1 end
                    end
                end)
                nari.send("ready")
                "#,
            )],
        );
        let (outbox, inbox) = channel();
        let _handle = thread::spawn(info.clone(), info.folder.join("worker.lua"), 6, outbox, None);
        assert!(matches!(inbox.recv_timeout(Duration::from_secs(5)), Ok(Inbox::Thread(6, _))));
        let mut stream = open_source("jump:x").unwrap().unwrap();
        stream.seek(SeekFrom::Start(700)).unwrap();
        let mut piece = [0u8; 4];
        stream.read_exact(&mut piece).unwrap();
        assert_eq!(piece, [700u32 as u8, 701u32 as u8, 702u32 as u8, 703u32 as u8]);
        std::fs::remove_dir_all(info.folder).unwrap();
    }

    #[test]
    fn sealed_sources_save_what_they_choose() {
        let info = folder("sealed", &[("worker.lua", r#"nari.source("vault", function(id, out) out:write(id:match("%?save$") and "locked" or "plain") end, { save = "sealed" }) nari.send("ready")"#)]);
        let (outbox, inbox) = channel();
        let handle = thread::spawn(info.clone(), info.folder.join("worker.lua"), 4, outbox, None);
        assert!(matches!(inbox.recv_timeout(Duration::from_secs(5)), Ok(Inbox::Thread(4, _))));
        assert!(sealed("vault:abc") && savable("vault:abc") && !sealed("other:abc"));
        let target = info.folder.join("out");
        crate::audio::save("vault:abc?save", target.to_str().unwrap()).unwrap();
        assert_eq!(std::fs::read_to_string(&target).unwrap(), "locked");
        drop(handle);
        let _ = inbox.recv_timeout(Duration::from_secs(5));
        assert!(!sealed("vault:abc"), "the seal goes away with the thread");
        std::fs::remove_dir_all(info.folder).unwrap();
    }

    #[test]
    fn unsavable_sources_refuse_saving() {
        let info = folder("locked", &[("worker.lua", r#"nari.source("locked", function(id, out) out:write("x") end, { save = false }) nari.source("open", function() end) nari.send("ready")"#)]);
        let (outbox, inbox) = channel();
        let handle = thread::spawn(info.clone(), info.folder.join("worker.lua"), 2, outbox, None);
        assert!(matches!(inbox.recv_timeout(Duration::from_secs(5)), Ok(Inbox::Thread(2, _))));
        assert!(!savable("locked:abc"));
        assert!(savable("open:abc") && savable("/music/song.mp3"));
        assert!(crate::audio::save("locked:abc", info.folder.join("out").to_str().unwrap()).is_err());
        assert!(!info.folder.join("out").exists());
        drop(handle);
        let _ = inbox.recv_timeout(Duration::from_secs(5));
        assert!(savable("locked:abc"), "the lock goes away with the thread");
        std::fs::remove_dir_all(info.folder).unwrap();
    }

    #[test]
    fn crypto_helpers_match_known_vectors() {
        let info = folder(
            "crypto",
            &[(
                "crypto.lua",
                r#"
                local verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
                local random = nari.random_bytes(32)
                nari.send({
                    challenge = nari.base64_encode(nari.sha256(verifier, true), true),
                    hmac = nari.hmac_sha256("Jefe", "what do ya want for nothing?"),
                    sha = nari.sha256("abc"),
                    plain = nari.base64_encode("hi?>"),
                    back = nari.base64_decode(nari.base64_encode("hi?>", true)),
                    random = #random,
                    hmac1 = nari.hmac("sha1", "key", "The quick brown fox jumps over the lazy dog"),
                    raw = #nari.sha1("abc", true) + #nari.md5("abc", true),
                    aes = nari.base64_encode(nari.cipher({ algorithm = "aes-ecb", key = string.rep("\0", 16), decrypt = false }):update(string.rep("\0", 16))),
                    dh = nari.base64_encode(nari.modpow("\2", "\10", "\255\255")),
                })
                "#,
            )],
        );
        let (outbox, inbox) = channel();
        let _handle = thread::spawn(info.clone(), info.folder.join("crypto.lua"), 4, outbox, None);
        let Ok(Inbox::Thread(4, value)) = inbox.recv_timeout(Duration::from_secs(5)) else {
            panic!("the script didn't answer");
        };
        assert_eq!(value["challenge"], "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM");
        assert_eq!(value["hmac"], "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843");
        assert_eq!(value["sha"], "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
        assert_eq!(value["plain"], "aGk/Pg==");
        assert_eq!(value["back"], "hi?>");
        assert_eq!(value["random"], 32);
        assert_eq!(value["hmac1"], "de7c9b85b8b78aa6bc8a7a36f70a90701c9db4d9");
        assert_eq!(value["raw"], 36);
        assert_eq!(value["aes"], "ZulL1O+KLDuITPpZyjQrLg==");
        assert_eq!(value["dh"], "BAA=");
        std::fs::remove_dir_all(info.folder).unwrap();
    }

    #[test]
    fn script_errors_come_back_readable() {
        let info = folder(
            "broken",
            &[
                ("syntax.lua", "local x = (\n"),
                ("nil.lua", "local song\nprint(song.title)"),
                ("exit.lua", "os.exit(1)"),
                ("handler.lua", "nari.after(0, function() local a = nil; a.b = 1 end)"),
                ("module.lua", "require('helper')"),
                ("helper.lua", "local y = nil\nreturn y.z"),
                ("memory.lua", "local t, s = {}, string.rep('x', 1024 * 1024)\nfor i = 1, 1000 do t[i] = s .. i end"),
            ],
        );
        let (stopped, failure) = failure_of(&info, "syntax.lua");
        assert!(stopped && failure.message.starts_with("syntax.lua:"), "{failure:?}");
        let (stopped, failure) = failure_of(&info, "nil.lua");
        assert!(stopped && failure.message.starts_with("nil.lua:2: attempt to index a nil value"), "{failure:?}");
        let (_, failure) = failure_of(&info, "exit.lua");
        assert!(failure.message.contains("os.exit() is not available"), "{failure:?}");
        let (stopped, failure) = failure_of(&info, "handler.lua");
        assert!(!stopped && failure.message.starts_with("handler.lua:1:") && failure.trace.contains("handler.lua"), "{failure:?}");
        let (_, failure) = failure_of(&info, "module.lua");
        assert!(failure.message.starts_with("helper.lua:2:"), "{failure:?}");
        let (stopped, failure) = failure_of(&info, "memory.lua");
        assert!(stopped && failure.fatal && failure.message.contains("memory"), "{failure:?}");
        std::fs::remove_dir_all(info.folder).unwrap();
    }

    #[test]
    fn threads_see_the_current_track_and_talk_to_main() {
        let info = folder(
            "worker",
            &[
                ("shout.lua", "return function(text) return text .. '!' end"),
                (
                    "worker.lua",
                    r#"
                    local shout = require("shout")
                    local title
                    nari.on("track", function(song) title = song.title end)
                    nari.on("message", function(message)
                        nari.set("hash", nari.md5("abc") .. nari.sha1("abc"))
                        nari.send({ echo = shout(message.text), track = title, hash = nari.get("hash") })
                    end)
                    nari.after(0.05, function() nari.send({ timer = true }) end)
                    "#,
                ),
            ],
        );
        emit("track", json!({ "title": "Song" }));
        emit("state", json!({ "playing": true }));
        let (outbox, inbox) = channel();
        let handle = thread::spawn(info.clone(), info.folder.join("worker.lua"), 7, outbox, None);
        handle.send(json!({ "text": "ping" }));
        let mut replies = Vec::new();
        while replies.len() < 2 {
            match inbox.recv_timeout(Duration::from_secs(5)).unwrap() {
                Inbox::Thread(7, value) => replies.push(value),
                _ => panic!("unexpected message"),
            }
        }
        assert!(replies.contains(&json!({ "echo": "ping!", "track": "Song", "hash": "900150983cd24fb0d6963f7d28e17f72a9993e364706816aba3e25717850c26c9cd0d89d" })));
        assert!(replies.contains(&json!({ "timer": true })));
        drop(handle);
        assert!(matches!(inbox.recv_timeout(Duration::from_secs(5)), Err(RecvTimeoutError::Disconnected)));
        std::fs::remove_dir_all(info.folder).unwrap();
    }

    #[test]
    fn threads_answer_web_requests_without_main() {
        use std::io::{Read, Write};
        let info = folder(
            "server",
            &[(
                "worker.lua",
                r#"
                local server = nari.serve(function(request)
                    if request.path == "/fail" then
                        error("broken")
                    end
                    return { status = 201, body = "got " .. request.query.code }
                end)
                nari.send({ port = server.port })
                "#,
            )],
        );
        let (outbox, inbox) = channel();
        let handle = thread::spawn(info.clone(), info.folder.join("worker.lua"), 3, outbox, None);
        let Ok(Inbox::Thread(3, value)) = inbox.recv_timeout(Duration::from_secs(5)) else {
            panic!("the thread didn't start its server");
        };
        let port = value["port"].as_u64().unwrap() as u16;
        let fetch = |path: &str| {
            let mut stream = std::net::TcpStream::connect(("127.0.0.1", port)).unwrap();
            write!(stream, "GET {path} HTTP/1.1\r\nHost: x\r\n\r\n").unwrap();
            let mut text = String::new();
            stream.read_to_string(&mut text).unwrap();
            text
        };
        let ok = fetch("/login?code=abc");
        assert!(ok.starts_with("HTTP/1.1 201") && ok.ends_with("got abc"), "{ok}");
        assert!(fetch("/fail").starts_with("HTTP/1.1 500"));
        assert!(matches!(inbox.recv_timeout(Duration::from_secs(5)), Ok(Inbox::Error(_))));
        drop(handle);
        std::fs::remove_dir_all(info.folder).unwrap();
    }

    #[test]
    fn threads_resolve_their_own_uris() {
        let info = folder(
            "resolver",
            &[(
                "worker.lua",
                r#"
                nari.resolver("demo", function(id)
                    if id == "broken" then error("no stream") end
                    return "https://example.com/" .. id
                end)
                nari.send("ready")
                "#,
            )],
        );
        let (outbox, inbox) = channel();
        let handle = thread::spawn(info.clone(), info.folder.join("worker.lua"), 3, outbox, None);
        assert!(matches!(inbox.recv_timeout(Duration::from_secs(5)), Ok(Inbox::Thread(3, _))));
        assert_eq!(resolve("demo:abc"), Some(Ok("https://example.com/abc".to_owned())));
        assert!(matches!(resolve("demo:broken"), Some(Err(error)) if error.contains("no stream")));
        assert_eq!(resolve("elsewhere:abc"), None);
        assert_eq!(resolve("/music/song.mp3"), None);
        assert!(matches!(inbox.recv_timeout(Duration::from_secs(5)), Ok(Inbox::Error(failure)) if failure.message.contains("no stream")));
        drop(handle);
        assert!(matches!(inbox.recv_timeout(Duration::from_secs(5)), Err(RecvTimeoutError::Disconnected)));
        assert_eq!(resolve("demo:abc"), None);
        std::fs::remove_dir_all(info.folder).unwrap();
    }

    #[test]
    fn threads_serve_their_own_bytes() {
        use std::io::Read;
        use symphonia::core::io::MediaSource;
        let info = folder(
            "source",
            &[(
                "worker.lua",
                r#"
                nari.source("bytes", function(id, out)
                    if id == "broken" then error("nothing to send") end
                    if id == "radio" then
                        out:live()
                        while out:write(string.rep("r", 4096)) do end
                        return
                    end
                    out:size(6)
                    out:write("ab")
                    out:write(id)
                end)
                nari.send("ready")
                "#,
            )],
        );
        let (outbox, inbox) = channel();
        let handle = thread::spawn(info.clone(), info.folder.join("worker.lua"), 4, outbox, None);
        assert!(matches!(inbox.recv_timeout(Duration::from_secs(5)), Ok(Inbox::Thread(4, _))));
        let mut stream = open_source("bytes:cdef").unwrap().unwrap();
        assert_eq!(stream.byte_len(), Some(6));
        let mut text = String::new();
        stream.read_to_string(&mut text).unwrap();
        assert_eq!(text, "abcdef");
        assert!(matches!(open_source("bytes:broken"), Some(Err(error)) if error.contains("nothing to send")));
        let mut radio = open_source("bytes:radio").unwrap().unwrap();
        assert!(radio.watch().live() && !radio.is_seekable());
        let mut piece = [0u8; 16];
        radio.read_exact(&mut piece).unwrap();
        assert_eq!(&piece, b"rrrrrrrrrrrrrrrr");
        drop(radio);
        assert!(open_source("elsewhere:x").is_none());
        let mut again = open_source("bytes:zzzz").unwrap().unwrap();
        text.clear();
        again.read_to_string(&mut text).unwrap();
        assert_eq!(text, "abzzzz", "the thread is free again after the live stream closed");
        drop(handle);
        let _ = inbox.recv_timeout(Duration::from_secs(5));
        std::fs::remove_dir_all(info.folder).unwrap();
    }

    fn sandboxed(info: Info, permissions: &[&str]) -> Info {
        let permissions: Vec<String> = permissions.iter().map(|permission| permission.to_string()).collect();
        let policy = sandbox::Policy::new(
            &permissions,
            sandbox::Roots { user: &info.data, folder: &info.folder, data: &info.data.join(&info.id), downloads: &info.data.join("downloads") },
        );
        Info { policy: Arc::new(policy), ..info }
    }

    #[test]
    fn sandboxed_threads_need_permissions_and_stay_in_their_folders() {
        let info = sandboxed(
            folder(
                "boxed",
                &[(
                    "worker.lua",
                    r#"
                    local data = nari.plugin.data
                    local wrote = io.open(data .. "/note.txt", "w")
                    local made = wrote ~= nil
                    if wrote then wrote:write("kept") wrote:close() end
                    local http_ok, http_problem = pcall(nari.http, { url = "http://127.0.0.1:1/" })
                    local tcp_ok = pcall(nari.tcp, { host = "127.0.0.1", port = 1 })
                    local read_ok = pcall(io.open, "/etc/hostname", "r")
                    local escape_ok = pcall(require, "../../escape")
                    nari.set("count", 3)
                    nari.send({ made = made, http = http_ok, problem = tostring(http_problem), tcp = tcp_ok, read = read_ok,
                        escape = escape_ok, count = nari.get("count"), execute = os.execute == nil })
                    "#,
                )],
            ),
            &[],
        );
        std::fs::create_dir_all(info.data.join("boxed")).unwrap();
        let (outbox, inbox) = channel();
        let _handle = thread::spawn(info.clone(), info.folder.join("worker.lua"), 9, outbox, None);
        let value = match inbox.recv_timeout(Duration::from_secs(10)) {
            Ok(Inbox::Thread(9, value)) => value,
            Ok(Inbox::ThreadFailed(_, failure) | Inbox::Error(failure)) => panic!("the script failed: {failure:?}"),
            _ => panic!("the script didn't answer"),
        };
        assert_eq!(value["made"], true);
        assert_eq!(value["http"], false);
        assert!(value["problem"].as_str().unwrap().contains("\"network\" permission"), "{value}");
        assert_eq!((value["tcp"].as_bool(), value["read"].as_bool(), value["escape"].as_bool()), (Some(false), Some(false), Some(false)));
        assert_eq!(value["count"], 3);
        assert_eq!(value["execute"], true);
        assert_eq!(std::fs::read_to_string(info.data.join("boxed/note.txt")).unwrap(), "kept");
        std::fs::remove_dir_all(info.folder).unwrap();
    }

    #[test]
    fn stored_values_come_from_the_cache_until_the_file_changes() {
        let folder = std::env::temp_dir().join(format!("nari-stored-{}", std::process::id()));
        std::fs::create_dir_all(&folder).unwrap();
        let file = folder.join("demo.json");
        std::fs::write(&file, r#"{"a":1}"#).unwrap();
        assert_eq!(stored_value(&file, "a", read_data).unwrap(), Some(json!(1)));
        std::thread::sleep(Duration::from_millis(20));
        std::fs::write(&file, r#"{"a":22}"#).unwrap();
        assert_eq!(stored_value(&file, "a", read_data).unwrap(), Some(json!(22)));
        let mut changed = stored_map(&file, read_data).unwrap();
        changed.insert("b".into(), json!(true));
        write_data(&file, &changed).unwrap();
        remember(&file, changed);
        assert_eq!(stored_value(&file, "b", read_data).unwrap(), Some(json!(true)));
        std::fs::remove_file(&file).unwrap();
        assert_eq!(stored_value(&file, "a", read_data).unwrap(), None);
        std::fs::remove_dir_all(folder).unwrap();
    }

    #[test]
    fn stopping_a_plugin_breaks_endless_loops_and_keeps_broken_data() {
        let info = folder(
            "stuck",
            &[("worker.lua", r#"nari.on("message", function() pcall(nari.set, "x", 1) while true do end end)"#)],
        );
        std::fs::write(info.data.join("stuck.json"), "{broken").unwrap();
        let (outbox, inbox) = channel();
        let handle = thread::spawn(info.clone(), info.folder.join("worker.lua"), 1, outbox, None);
        handle.send(json!(null));
        std::thread::sleep(Duration::from_millis(100));
        drop(handle);
        assert!(matches!(inbox.recv_timeout(Duration::from_secs(5)), Err(RecvTimeoutError::Disconnected)));
        assert_eq!(std::fs::read_to_string(info.data.join("stuck.json")).unwrap(), "{broken");
        std::fs::remove_dir_all(info.folder).unwrap();
    }
}
