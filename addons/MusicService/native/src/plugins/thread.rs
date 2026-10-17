use super::{find_named, forget_resolvers, from_lua, install, limit_memory, register_named, register_resolver, register_source, response, subscribe, to_lua, Failure, Inbox, Info, Request};
use crate::stream::Feed;
use mlua::{Function, HookTriggers, Lua, LuaString, Table, UserData, UserDataMethods, Value, VmState};
use super::serve;
use serde_json::Value as Json;
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{channel, Receiver, RecvTimeoutError, Sender};
use std::sync::atomic::AtomicU64;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

const THREAD: &str = include_str!("thread.lua");
const STOP_CHECK: u32 = 10_000;
const ASK_TIMEOUT: f64 = 20.0;

pub enum Message {
    Event(&'static str, Json),
    Data(Json),
    Resolve {
        scheme: String,
        id: String,
        reply: Sender<Result<String, String>>,
    },
    Open {
        scheme: String,
        id: String,
        feed: Feed,
    },
    Ask {
        value: Json,
        reply: Sender<Result<Json, String>>,
    },
    Socket(u64, Vec<u8>),
    SocketClosed(u64, Option<String>),
    Serve(u64, serve::Incoming),
    Stop,
}

#[derive(Default)]
struct Servers {
    next: u64,
    running: HashMap<u64, (serve::Server, Function)>,
}

struct Out(Arc<Mutex<Option<Feed>>>);

impl Out {
    fn with<T>(&self, action: impl FnOnce(&Feed) -> T) -> Option<T> {
        self.0.lock().unwrap_or_else(|poisoned| poisoned.into_inner()).as_ref().map(action)
    }
}

impl UserData for Out {
    fn add_methods<M: UserDataMethods<Self>>(methods: &mut M) {
        methods.add_method("write", |_, out, (bytes, offset): (LuaString, Option<u64>)| {
            Ok(out
                .with(|feed| match offset {
                    Some(offset) => feed.push_at(offset, &bytes.as_bytes()),
                    None => feed.push(&bytes.as_bytes()),
                })
                .unwrap_or(false))
        });
        methods.add_method("wanted", |_, out, ()| Ok(out.with(Feed::wanted).flatten()));
        methods.add_method("size", |_, out, size: Option<u64>| {
            out.with(|feed| feed.set_length(size));
            Ok(())
        });
        methods.add_method("live", |_, out, ()| {
            out.with(Feed::set_live);
            Ok(())
        });
        methods.add_method("closed", |_, out, ()| Ok(out.with(Feed::closed).unwrap_or(true)));
    }
}

static THREADS: AtomicU64 = AtomicU64::new(0);

pub struct Handle {
    sender: Sender<Message>,
    stop: Arc<AtomicBool>,
}

impl Handle {
    pub fn send(&self, value: Json) {
        let _ = self.sender.send(Message::Data(value));
    }
}

impl Drop for Handle {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
        let _ = self.sender.send(Message::Stop);
    }
}

pub fn spawn(info: Info, script: PathBuf, index: i64, outbox: Sender<Inbox>, name: Option<String>) -> Handle {
    let (sender, receiver) = channel();
    let thread = THREADS.fetch_add(1, Ordering::Relaxed);
    if let Some(name) = name {
        register_named(&info.id, name, thread, sender.clone());
    }
    let stop = Arc::new(AtomicBool::new(false));
    let handle = Handle { sender: sender.clone(), stop: stop.clone() };
    let name = format!("plugin-{}", info.id);
    let _ = std::thread::Builder::new().name(name).spawn(move || {
        let lua = Lua::new();
        limit_memory(&lua);
        let flag = stop.clone();
        let _ = lua.set_hook(HookTriggers::new().every_nth_instruction(STOP_CHECK), move |_, _| {
            if flag.load(Ordering::Relaxed) {
                Err(mlua::Error::runtime("the plugin was turned off"))
            } else {
                Ok(VmState::Continue)
            }
        });
        let result = run(&lua, &info, &script, index, &outbox, sender, receiver, &stop, thread);
        forget_resolvers(thread);
        if let Err(error) = result {
            if !stop.load(Ordering::Relaxed) {
                let _ = outbox.send(Inbox::ThreadFailed(index, Failure::of(&error)));
            }
        }
    });
    handle
}

#[allow(clippy::too_many_arguments)]
fn run(
    lua: &Lua,
    info: &Info,
    script: &PathBuf,
    index: i64,
    outbox: &Sender<Inbox>,
    sender: Sender<Message>,
    receiver: Receiver<Message>,
    stop: &Arc<AtomicBool>,
    thread: u64,
) -> mlua::Result<()> {
    let nari: Table = install(lua, info)?;
    let http_info = info.clone();
    nari.set(
        "http",
        lua.create_function(move |lua, (request, callback): (Table, Option<Function>)| {
            http_info.policy.require_network("nari.http()")?;
            let stream = request.get::<Option<Function>>("stream")?;
            let parsed = Request::from_table(&request, &http_info)?;
            let result = match stream {
                Some(stream) => parsed.stream(|chunk| {
                    let keep = stream.call::<Value>(lua.create_string(chunk)?)?;
                    Ok::<bool, mlua::Error>(!matches!(keep, Value::Boolean(false)))
                })?,
                None => parsed.send(),
            };
            let (value, error) = response(lua, result)?;
            if let Some(callback) = callback {
                callback.call::<()>((value.clone(), error.clone()))?;
            }
            Ok((value, error))
        })?,
    )?;
    nari.set(
        "analyze",
        lua.create_function(|lua, (uri, options): (String, Option<Value>)| {
            let options = options.map(|options| from_lua(lua, options)).transpose()?.unwrap_or_default();
            match crate::analysis::analyze(&uri, &options) {
                Ok(result) => Ok((to_lua(lua, &result)?, Value::Nil)),
                Err(error) => Ok((Value::Nil, Value::String(lua.create_string(&error)?))),
            }
        })?,
    )?;
    let logs = outbox.clone();
    lua.globals().set(
        "__nari_log",
        lua.create_function(move |_, (level, text): (String, String)| {
            let _ = logs.send(Inbox::Log(level, text));
            Ok(())
        })?,
    )?;
    let errors = outbox.clone();
    let stopping = stop.clone();
    lua.globals().set(
        "__nari_report",
        lua.create_function(move |_, (message, trace): (String, Option<String>)| {
            if stopping.load(Ordering::Relaxed) {
                return Ok(());
            }
            let _ = errors.send(Inbox::Error(Failure::message(message, trace.unwrap_or_default())));
            Ok(())
        })?,
    )?;
    let outbox = outbox.clone();
    nari.set(
        "send",
        lua.create_function(move |lua, value: Value| {
            let _ = outbox.send(Inbox::Thread(index, from_lua(lua, value)?));
            Ok(())
        })?,
    )?;
    let started = Instant::now();
    lua.globals().set(
        "__nari_clock",
        lua.create_function(move |_, ()| Ok(started.elapsed().as_secs_f64()))?,
    )?;
    let own = sender.clone();
    let resolver_policy = info.policy.clone();
    lua.globals().set(
        "__nari_register_resolver",
        lua.create_function(move |_, scheme: String| {
            resolver_policy.require_network("nari.resolver()")?;
            register_resolver(scheme, thread, own.clone());
            Ok(())
        })?,
    )?;
    let own = sender.clone();
    lua.globals().set(
        "__nari_register_source",
        lua.create_function(move |_, (scheme, save): (String, String)| {
            register_source(scheme, &save, thread, own.clone());
            Ok(())
        })?,
    )?;
    super::tcp::install(lua, sender.clone(), info.policy.clone())?;
    lua.set_app_data(Servers::default());
    let own = sender.clone();
    let serve_policy = info.policy.clone();
    lua.globals().set(
        "__nari_serve_start",
        lua.create_function(move |lua, (handler, port): (Function, Option<u16>)| {
            serve_policy.require_network("nari.serve()")?;
            let mut servers = lua.app_data_mut::<Servers>().ok_or_else(|| mlua::Error::runtime("the thread stopped"))?;
            servers.next += 1;
            let key = servers.next;
            let events = own.clone();
            let server = serve::start(port.unwrap_or(0), move |incoming| events.send(Message::Serve(key, incoming)).is_ok())
                .map_err(|error| mlua::Error::runtime(format!("nari.serve(): {error}")))?;
            let port = server.port;
            servers.running.insert(key, (server, handler));
            Ok((key, port))
        })?,
    )?;
    lua.globals().set(
        "__nari_serve_stop",
        lua.create_function(|lua, key: u64| {
            if let Some(mut servers) = lua.app_data_mut::<Servers>() {
                servers.running.remove(&key);
            }
            Ok(())
        })?,
    )?;
    let plugin = info.id.clone();
    lua.globals().set(
        "__nari_ask_thread",
        lua.create_function(move |lua, (name, value, timeout): (String, Value, Option<f64>)| {
            let Some((owner, target)) = find_named(&plugin, &name) else {
                return Ok((Value::Nil, Value::String(lua.create_string(format!("no thread is called '{name}'"))?)));
            };
            if owner == thread {
                return Err(mlua::Error::runtime("nari.ask(): a thread can't ask itself"));
            }
            let (reply, answer) = channel();
            if target.send(Message::Ask { value: from_lua(lua, value)?, reply }).is_err() {
                return Ok((Value::Nil, Value::String(lua.create_string(format!("the thread '{name}' stopped"))?)));
            }
            let wait = Duration::from_secs_f64(timeout.unwrap_or(ASK_TIMEOUT).max(0.0));
            match answer.recv_timeout(wait) {
                Ok(Ok(value)) => Ok((to_lua(lua, &value)?, Value::Nil)),
                Ok(Err(problem)) => Ok((Value::Nil, Value::String(lua.create_string(problem)?))),
                Err(RecvTimeoutError::Timeout) => Ok((Value::Nil, Value::String(lua.create_string("timeout")?))),
                Err(RecvTimeoutError::Disconnected) => Ok((Value::Nil, Value::String(lua.create_string("no answer")?))),
            }
        })?,
    )?;
    lua.load(THREAD).set_name("@nari/thread.lua").exec()?;
    let source = std::fs::read_to_string(script).map_err(mlua::Error::external)?;
    let name = script.strip_prefix(&info.folder).unwrap_or(script).display().to_string();
    lua.load(source).set_name(format!("@{name}")).exec()?;
    let emit: Function = lua.globals().get("__nari_emit")?;
    let tick: Function = lua.globals().get("__nari_tick")?;
    let resolve: Function = lua.globals().get("__nari_resolve")?;
    let open: Function = lua.globals().get("__nari_source")?;
    let ask: Function = lua.globals().get("__nari_ask")?;
    let socket_data: Function = lua.globals().get("__nari_socket")?;
    let socket_closed: Function = lua.globals().get("__nari_socket_closed")?;
    for (event, payload) in subscribe(sender) {
        emit.call::<()>((event, to_lua(lua, &payload)?))?;
    }
    loop {
        let wait: Option<f64> = tick.call(())?;
        let message = match wait {
            Some(seconds) => receiver.recv_timeout(Duration::from_secs_f64(seconds)),
            None => receiver.recv().map_err(|_| RecvTimeoutError::Disconnected),
        };
        if stop.load(Ordering::Relaxed) {
            return Ok(());
        }
        match message {
            Ok(Message::Event(event, payload)) => emit.call::<()>((event, to_lua(lua, &payload)?))?,
            Ok(Message::Data(value)) => emit.call::<()>(("message", to_lua(lua, &value)?))?,
            Ok(Message::Resolve { scheme, id, reply }) => {
                let answer = resolve
                    .call::<(Option<String>, Option<String>)>((scheme, id))
                    .map_err(|error| error.to_string())
                    .and_then(|(url, error)| url.ok_or_else(|| error.unwrap_or_else(|| "no stream was found".to_owned())));
                let _ = reply.send(answer);
            }
            Ok(Message::Open { scheme, id, feed }) => {
                let slot = Arc::new(Mutex::new(Some(feed)));
                let problem = lua
                    .create_userdata(Out(slot.clone()))
                    .and_then(|out| open.call::<Option<String>>((scheme, id, out)))
                    .unwrap_or_else(|error| Some(error.to_string()));
                let feed = slot.lock().unwrap_or_else(|poisoned| poisoned.into_inner()).take();
                if let (Some(feed), Some(problem)) = (feed, problem) {
                    feed.fail(problem);
                }
            }
            Ok(Message::Ask { value, reply }) => {
                let slot = Mutex::new(Some(reply));
                let answer = lua.create_function(move |lua, (value, problem): (Value, Option<String>)| {
                    if let Some(reply) = slot.lock().unwrap_or_else(|poisoned| poisoned.into_inner()).take() {
                        let _ = reply.send(match problem {
                            Some(problem) => Err(problem),
                            None => Ok(from_lua(lua, value)?),
                        });
                    }
                    Ok(())
                })?;
                ask.call::<()>((to_lua(lua, &value)?, answer))?;
            }
            Ok(Message::Socket(id, bytes)) => socket_data.call::<()>((id, lua.create_string(bytes)?))?,
            Ok(Message::SocketClosed(id, problem)) => socket_closed.call::<()>((id, problem))?,
            Ok(Message::Serve(key, incoming)) => {
                let handler = lua.app_data_ref::<Servers>().and_then(|servers| servers.running.get(&key).map(|(_, handler)| handler.clone()));
                let reply = incoming.reply.clone();
                let outgoing = match handler {
                    Some(handler) => super::runtime::serve_request(lua, &handler, incoming).unwrap_or_else(|error| {
                        let _ = lua.globals().get::<Function>("__nari_report").and_then(|report| report.call::<()>((error.to_string(), Value::Nil)));
                        serve::Outgoing::text(500, "the plugin failed while answering")
                    }),
                    None => serve::Outgoing::text(503, "the server was stopped"),
                };
                let _ = reply.send(outgoing);
            }
            Ok(Message::Stop) | Err(RecvTimeoutError::Disconnected) => return Ok(()),
            Err(RecvTimeoutError::Timeout) => {}
        }
    }
}
