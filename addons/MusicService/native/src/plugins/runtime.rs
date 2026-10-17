use super::{bridge, sandbox, serve, from_lua, install, limit_memory, notify, report, response, thread, to_lua, Failure, Inbox, Info, Request, Timeout};
use godot::classes::{Object, ProjectSettings};
use godot::prelude::*;
use mlua::{Function, HookTriggers, Lua, MultiValue, Table, Value, VmState};
use std::cell::{Cell, RefCell};
use std::collections::HashMap;
use std::path::PathBuf;
use std::rc::Rc;
use std::sync::Arc;
use std::sync::mpsc::{channel, Receiver};
use std::time::{Duration, Instant};

const PRELUDE: &str = include_str!("prelude.lua");
pub const TIME_LIMIT: Duration = Duration::from_secs(3);
const WATCH_EVERY: u32 = 10_000;

struct Watch {
    depth: Cell<u32>,
    since: Cell<Instant>,
    tripped: Cell<bool>,
}

fn watch(lua: &Lua) {
    lua.set_app_data(Watch { depth: Cell::new(0), since: Cell::new(Instant::now()), tripped: Cell::new(false) });
    let _ = lua.set_hook(HookTriggers::new().every_nth_instruction(WATCH_EVERY), |lua, debug| {
        let Some(watch) = lua.app_data_ref::<Watch>() else {
            return Ok(VmState::Continue);
        };
        if watch.depth.get() > 0 && watch.since.get().elapsed() > TIME_LIMIT {
            watch.tripped.set(true);
            let file = debug.source().short_src.map(|file| file.into_owned()).unwrap_or_default();
            let at = match debug.current_line() {
                Some(line) if !file.starts_with("nari/") => format!("{file}:{line}"),
                _ => String::new(),
            };
            return Err(mlua::Error::external(Timeout(at)));
        }
        Ok(VmState::Continue)
    });
}

fn tripped(lua: &Lua) -> bool {
    lua.app_data_ref::<Watch>().is_some_and(|watch| watch.tripped.get())
}

pub fn guarded<R>(lua: &Lua, id: &str, run: impl FnOnce() -> mlua::Result<R>) -> Option<R> {
    if let Some(watch) = lua.app_data_ref::<Watch>() {
        if watch.depth.get() == 0 {
            watch.since.set(Instant::now());
            watch.tripped.set(false);
        }
        watch.depth.set(watch.depth.get() + 1);
    }
    let result = run();
    let timed_out = lua.app_data_ref::<Watch>().is_some_and(|watch| {
        watch.depth.set(watch.depth.get().saturating_sub(1));
        watch.depth.get() == 0 && watch.tripped.get()
    });
    match result {
        Ok(value) if !timed_out => Some(value),
        Ok(_) => {
            report(id, &mlua::Error::external(Timeout::default()));
            None
        }
        Err(error) => {
            let mut failure = Failure::of(&error);
            if timed_out && !failure.fatal {
                failure = Failure::of(&mlua::Error::external(Timeout::default()));
            }
            notify(id, &failure);
            None
        }
    }
}

struct State {
    lua: Lua,
    id: String,
    inbox: Receiver<Inbox>,
    _alive: Rc<()>,
}

#[derive(Default)]
struct Pending {
    next: u64,
    requests: HashMap<u64, Function>,
    threads: HashMap<i64, thread::Handle>,
    servers: HashMap<u64, (serve::Server, Function)>,
}

#[derive(GodotClass)]
#[class(base = RefCounted, init)]
pub struct LuaRuntime {
    state: RefCell<Option<State>>,
}

#[godot_api]
impl LuaRuntime {
    #[func]
    fn start(&self, plugin: Gd<Object>, id: GString, folder: GString, main: GString, permissions: PackedStringArray) -> GString {
        let settings = ProjectSettings::singleton();
        let globalize = |path: &str| PathBuf::from(settings.globalize_path(path).to_string());
        let data = globalize("user://plugin_data");
        let folder_path = globalize(&folder.to_string());
        let permissions: Vec<String> = permissions.as_slice().iter().map(GString::to_string).collect();
        let policy = sandbox::Policy::new(
            &permissions,
            sandbox::Roots {
                user: &globalize("user://"),
                folder: &folder_path,
                data: &data.join(id.to_string()),
                downloads: &globalize("user://downloads").join(id.to_string()),
            },
        );
        let _ = std::fs::create_dir_all(data.join(id.to_string()));
        let info = Info { id: id.to_string(), folder: folder_path, data, policy: Arc::new(policy) };
        let lua = Lua::new();
        limit_memory(&lua);
        watch(&lua);
        let alive = Rc::new(());
        let (sender, inbox) = channel();
        let setup = (|| -> mlua::Result<()> {
            let nari = install(&lua, &info)?;
            nari.get::<Table>("plugin")?.set("path", folder.to_string())?;
            bridge::install(&lua, &info.id, Rc::downgrade(&alive), info.policy.clone())?;
            lua.set_app_data(Pending::default());
            lua.globals().set("__nari_plugin", bridge::object(&lua, plugin)?)?;
            let requests = sender.clone();
            let http_info = info.clone();
            nari.set(
                "http",
                lua.create_function(move |lua, (request, callback): (Table, Function)| {
                    http_info.policy.require_network("nari.http()")?;
                    if request.contains_key("stream")? {
                        return Err(mlua::Error::runtime("nari.http(): 'stream' only works in background threads"));
                    }
                    let request = Request::from_table(&request, &http_info)?;
                    let key = {
                        let mut pending = lua.app_data_mut::<Pending>().ok_or_else(stopped)?;
                        pending.next += 1;
                        let key = pending.next;
                        pending.requests.insert(key, callback);
                        key
                    };
                    let requests = requests.clone();
                    std::thread::spawn(move || {
                        let _ = requests.send(Inbox::Http(key, request.send()));
                    });
                    Ok(())
                })?,
            )?;
            let threads = sender.clone();
            let thread_info = info.clone();
            nari.set(
                "__thread_start",
                lua.create_function(move |lua, (file, name): (String, Option<String>)| {
                    let mut pending = lua.app_data_mut::<Pending>().ok_or_else(stopped)?;
                    pending.next += 1;
                    let index = pending.next as i64;
                    let script = thread_info.folder.join(&file);
                    thread_info.policy.check(&script.to_string_lossy(), false).map_err(mlua::Error::runtime)?;
                    if !script.is_file() {
                        return Err(mlua::Error::runtime(format!("nari.thread(): '{file}' does not exist")));
                    }
                    pending.threads.insert(index, thread::spawn(thread_info.clone(), script, index, threads.clone(), name));
                    Ok(index)
                })?,
            )?;
            let servers = sender.clone();
            let serve_policy = info.policy.clone();
            nari.set(
                "__serve_start",
                lua.create_function(move |lua, (handler, port): (Function, Option<u16>)| {
                    serve_policy.require_network("nari.serve()")?;
                    let mut pending = lua.app_data_mut::<Pending>().ok_or_else(stopped)?;
                    pending.next += 1;
                    let key = pending.next;
                    let outbox = servers.clone();
                    let server = serve::start(port.unwrap_or(0), move |incoming| outbox.send(Inbox::Serve(key, incoming)).is_ok())
                        .map_err(|error| mlua::Error::runtime(format!("nari.serve(): {error}")))?;
                    let port = server.port;
                    pending.servers.insert(key, (server, handler));
                    Ok((key, port))
                })?,
            )?;
            nari.set(
                "__serve_stop",
                lua.create_function(|lua, key: u64| {
                    lua.app_data_mut::<Pending>().ok_or_else(stopped)?.servers.remove(&key);
                    Ok(())
                })?,
            )?;
            nari.set(
                "__thread_send",
                lua.create_function(|lua, (index, value): (i64, Value)| {
                    let value = from_lua(lua, value)?;
                    if let Some(handle) = lua.app_data_ref::<Pending>().ok_or_else(stopped)?.threads.get(&index) {
                        handle.send(value);
                    }
                    Ok(())
                })?,
            )?;
            nari.set(
                "__thread_stop",
                lua.create_function(|lua, index: i64| {
                    lua.app_data_mut::<Pending>().ok_or_else(stopped)?.threads.remove(&index);
                    Ok(())
                })?,
            )?;
            let id = info.id.clone();
            lua.globals().set(
                "__nari_report",
                lua.create_function(move |lua, (message, trace): (String, Option<String>)| {
                    if !tripped(lua) {
                        notify(&id, &Failure::message(message, trace.unwrap_or_default()));
                    }
                    Ok(())
                })?,
            )?;
            lua.load(PRELUDE).set_name("@nari/prelude.lua").exec()?;
            bridge::lock(&lua);
            Ok(())
        })();
        *self.state.borrow_mut() = Some(State { lua: lua.clone(), id: info.id.clone(), inbox, _alive: alive });
        if let Err(error) = setup {
            self.stop();
            report(&info.id, &error);
            return GString::from(Failure::of(&error).message.as_str());
        }
        let started = guarded(&lua, &info.id, || {
            let path = info.folder.join(main.to_string());
            info.policy.check(&path.to_string_lossy(), false).map_err(mlua::Error::runtime)?;
            let source = std::fs::read_to_string(&path)
                .map_err(|error| mlua::Error::runtime(format!("can't read '{main}': {error}")))?;
            lua.load(source).set_name(format!("@{main}")).exec()?;
            lua.globals().get::<Function>("__nari_started")?.call::<()>(())
        });
        match started {
            Some(()) => GString::new(),
            None => {
                self.stop();
                GString::from("the plugin failed to start")
            }
        }
    }

    #[func]
    fn emit(&self, event: GString, args: VarArray) {
        let Some((lua, id)) = self.lua() else {
            return;
        };
        guarded(&lua, &id, || {
            let mut values = vec![Value::String(lua.create_string(event.to_string())?)];
            for arg in args.iter_shared() {
                values.push(bridge::to_lua(&lua, &arg)?);
            }
            lua.globals().get::<Function>("__nari_emit")?.call::<()>(MultiValue::from_iter(values))
        });
    }

    #[func]
    fn pump(&self) {
        let messages: Vec<Inbox> = match self.state.borrow().as_ref() {
            Some(state) => state.inbox.try_iter().collect(),
            None => return,
        };
        let Some((lua, id)) = self.lua() else {
            return;
        };
        for message in messages {
            guarded(&lua, &id, || match message {
                Inbox::Thread(index, value) => to_lua(&lua, &value).and_then(|value| {
                    lua.globals().get::<Function>("__nari_thread_message")?.call::<()>((index, value))
                }),
                Inbox::ThreadFailed(index, failure) => {
                    notify(&id, &Failure { message: format!("a background thread stopped: {}", failure.message), ..failure.clone() });
                    lua.globals()
                        .get::<Function>("__nari_thread_failed")
                        .and_then(|failed| failed.call::<()>((index, failure.message)))
                }
                Inbox::Error(failure) => {
                    notify(&id, &failure);
                    Ok(())
                }
                Inbox::Log(level, text) => lua.globals().get::<Function>("__nari_log")?.call::<()>((level, text)),
                Inbox::Serve(key, incoming) => {
                    let handler = lua.app_data_ref::<Pending>().and_then(|pending| pending.servers.get(&key).map(|(_, handler)| handler.clone()));
                    let reply = incoming.reply.clone();
                    let outgoing = match handler {
                        Some(handler) => guarded(&lua, &id, || serve_request(&lua, &handler, incoming))
                            .unwrap_or_else(|| serve::Outgoing::text(500, "the plugin failed while answering")),
                        None => serve::Outgoing::text(503, "the server was stopped"),
                    };
                    let _ = reply.send(outgoing);
                    Ok(())
                }
                Inbox::Http(key, result) => {
                    let callback = lua.app_data_mut::<Pending>().and_then(|mut pending| pending.requests.remove(&key));
                    match callback {
                        Some(callback) => response(&lua, result).and_then(|args| callback.call::<()>(args)),
                        None => Ok(()),
                    }
                }
            });
            if self.state.borrow().is_none() {
                return;
            }
        }
    }

    #[func]
    fn stop(&self) {
        let Some(state) = self.state.borrow_mut().take() else {
            return;
        };
        if let Ok(emit) = state.lua.globals().get::<Function>("__nari_emit") {
            guarded(&state.lua, &state.id, || emit.call::<()>("disable"));
        }
        state.lua.remove_app_data::<Pending>();
        bridge::cleanup(&state.lua);
    }

    fn lua(&self) -> Option<(Lua, String)> {
        self.state.borrow().as_ref().map(|state| (state.lua.clone(), state.id.clone()))
    }
}

pub(super) fn serve_request(lua: &Lua, handler: &Function, incoming: serve::Incoming) -> mlua::Result<serve::Outgoing> {
    let request = lua.create_table()?;
    request.set("method", incoming.method)?;
    request.set("path", incoming.path)?;
    request.set("query", incoming.query)?;
    request.set("headers", incoming.headers)?;
    request.set("body", incoming.body)?;
    Ok(match handler.call::<Value>(request)? {
        Value::Nil => serve::Outgoing::text(204, ""),
        Value::String(text) => serve::Outgoing::text(200, &text.to_str()?),
        Value::Table(answer) => {
            let mut headers = Vec::new();
            if let Some(pairs) = answer.get::<Option<Table>>("headers")? {
                for pair in pairs.pairs::<String, String>() {
                    headers.push(pair?);
                }
            }
            serve::Outgoing {
                status: answer.get::<Option<u16>>("status")?.unwrap_or(200),
                headers,
                body: answer.get::<Option<String>>("body")?.unwrap_or_default(),
            }
        }
        _ => return Err(mlua::Error::runtime("nari.serve(): the handler must return a string, a table or nothing")),
    })
}

fn stopped() -> mlua::Error {
    mlua::Error::runtime("the plugin was turned off")
}
