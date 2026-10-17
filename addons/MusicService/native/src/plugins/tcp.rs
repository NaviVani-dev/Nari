use super::thread::Message;
use mlua::{Lua, LuaString, Table, UserData, UserDataMethods, Value};
use std::io::{ErrorKind, Read, Write};
use std::net::{Shutdown, TcpStream, ToSocketAddrs};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::mpsc::Sender;
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant};

const CONNECT_TIMEOUT: f64 = 20.0;
const WRITE_TIMEOUT: Duration = Duration::from_secs(20);
const LISTEN_POLL: Duration = Duration::from_millis(100);
const CHUNK: usize = 64 * 1024;

static SOCKETS: AtomicU64 = AtomicU64::new(1);

enum Conn {
    Plain(TcpStream),
    Tls(Box<rustls::StreamOwned<rustls::ClientConnection, TcpStream>>),
}

impl Read for Conn {
    fn read(&mut self, buffer: &mut [u8]) -> std::io::Result<usize> {
        match self {
            Conn::Plain(stream) => stream.read(buffer),
            Conn::Tls(stream) => stream.read(buffer),
        }
    }
}

impl Write for Conn {
    fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
        match self {
            Conn::Plain(stream) => stream.write(bytes),
            Conn::Tls(stream) => stream.write(bytes),
        }
    }

    fn flush(&mut self) -> std::io::Result<()> {
        match self {
            Conn::Plain(stream) => stream.flush(),
            Conn::Tls(stream) => stream.flush(),
        }
    }
}

pub struct Socket {
    id: u64,
    conn: Arc<Mutex<Conn>>,
    raw: TcpStream,
    closed: Arc<AtomicBool>,
    listening: bool,
    pending: Vec<u8>,
    events: Sender<Message>,
}

fn tls_config() -> Arc<rustls::ClientConfig> {
    static CONFIG: OnceLock<Arc<rustls::ClientConfig>> = OnceLock::new();
    CONFIG
        .get_or_init(|| {
            let roots = rustls::RootCertStore { roots: webpki_roots::TLS_SERVER_ROOTS.to_vec() };
            Arc::new(
                rustls::ClientConfig::builder_with_provider(Arc::new(rustls::crypto::ring::default_provider()))
                    .with_safe_default_protocol_versions()
                    .expect("ring supports the default TLS versions")
                    .with_root_certificates(roots)
                    .with_no_client_auth(),
            )
        })
        .clone()
}

fn timed_out(kind: ErrorKind) -> bool {
    matches!(kind, ErrorKind::WouldBlock | ErrorKind::TimedOut)
}

impl Socket {
    fn connect(host: &str, port: u16, tls: bool, timeout: Duration, events: Sender<Message>) -> Result<Self, String> {
        let mut last = format!("couldn't find {host}");
        let mut connected = None;
        for address in (host, port).to_socket_addrs().map_err(|error| error.to_string())? {
            match TcpStream::connect_timeout(&address, timeout) {
                Ok(stream) => {
                    connected = Some(stream);
                    break;
                }
                Err(error) => last = error.to_string(),
            }
        }
        let raw = connected.ok_or(last)?;
        let _ = raw.set_nodelay(true);
        let stream = raw.try_clone().map_err(|error| error.to_string())?;
        let conn = if tls {
            let name = rustls::pki_types::ServerName::try_from(host.to_owned()).map_err(|error| error.to_string())?;
            let client = rustls::ClientConnection::new(tls_config(), name).map_err(|error| error.to_string())?;
            let mut stream = rustls::StreamOwned::new(client, stream);
            stream.sock.set_read_timeout(Some(timeout)).map_err(|error| error.to_string())?;
            while stream.conn.is_handshaking() {
                stream.conn.complete_io(&mut stream.sock).map_err(|error| error.to_string())?;
            }
            Conn::Tls(Box::new(stream))
        } else {
            Conn::Plain(stream)
        };
        Ok(Self {
            id: SOCKETS.fetch_add(1, Ordering::Relaxed),
            conn: Arc::new(Mutex::new(conn)),
            raw,
            closed: Arc::new(AtomicBool::new(false)),
            listening: false,
            pending: Vec::new(),
            events,
        })
    }

    fn send(&self, bytes: &[u8]) -> Result<(), String> {
        if self.closed.load(Ordering::Relaxed) {
            return Err("closed".into());
        }
        let _ = self.raw.set_write_timeout(Some(WRITE_TIMEOUT));
        let mut conn = self.conn.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        conn.write_all(bytes).and_then(|()| conn.flush()).map_err(|error| error.to_string())
    }

    fn receive(&mut self, count: Option<usize>, timeout: Option<f64>) -> Result<Vec<u8>, String> {
        if self.listening {
            return Err("socket:receive() can't be used after socket:on_data()".into());
        }
        let wanted = count.unwrap_or(1).max(1);
        let deadline = timeout.map(|seconds| Instant::now() + Duration::from_secs_f64(seconds.max(0.001)));
        let mut chunk = vec![0u8; CHUNK];
        while self.pending.len() < wanted {
            if self.closed.load(Ordering::Relaxed) {
                return Err("closed".into());
            }
            let left = match deadline {
                Some(deadline) => {
                    let left = deadline.saturating_duration_since(Instant::now());
                    if left.is_zero() {
                        return Err("timeout".into());
                    }
                    Some(left)
                }
                None => None,
            };
            let _ = self.raw.set_read_timeout(left);
            let read = self.conn.lock().unwrap_or_else(|poisoned| poisoned.into_inner()).read(&mut chunk);
            match read {
                Ok(0) => return Err("closed".into()),
                Ok(read) => self.pending.extend_from_slice(&chunk[..read]),
                Err(error) if error.kind() == ErrorKind::Interrupted => {}
                Err(error) if timed_out(error.kind()) => {}
                Err(error) => return Err(error.to_string()),
            }
        }
        let take = count.unwrap_or(self.pending.len());
        let rest = self.pending.split_off(take);
        Ok(std::mem::replace(&mut self.pending, rest))
    }

    fn listen(&mut self) -> Result<(), String> {
        if self.listening {
            return Ok(());
        }
        self.listening = true;
        let (id, conn, closed, events) = (self.id, self.conn.clone(), self.closed.clone(), self.events.clone());
        let raw = self.raw.try_clone().map_err(|error| error.to_string())?;
        let pending = std::mem::take(&mut self.pending);
        if !pending.is_empty() {
            let _ = events.send(Message::Socket(id, pending));
        }
        std::thread::Builder::new()
            .name(format!("plugin-tcp-{id}"))
            .spawn(move || {
                let _ = raw.set_read_timeout(Some(LISTEN_POLL));
                let mut chunk = vec![0u8; CHUNK];
                while !closed.load(Ordering::Relaxed) {
                    let read = conn.lock().unwrap_or_else(|poisoned| poisoned.into_inner()).read(&mut chunk);
                    let message = match read {
                        Ok(0) => Message::SocketClosed(id, None),
                        Ok(read) => Message::Socket(id, chunk[..read].to_vec()),
                        Err(error) if error.kind() == ErrorKind::Interrupted || timed_out(error.kind()) => continue,
                        Err(error) => Message::SocketClosed(id, Some(error.to_string())),
                    };
                    let ended = matches!(message, Message::SocketClosed(..));
                    if events.send(message).is_err() || ended {
                        break;
                    }
                }
            })
            .map(|_| ())
            .map_err(|error| error.to_string())
    }

    fn close(&self) {
        self.closed.store(true, Ordering::Relaxed);
        let _ = self.raw.shutdown(Shutdown::Both);
    }
}

impl Drop for Socket {
    fn drop(&mut self) {
        self.close();
    }
}

fn problem(lua: &Lua, error: String) -> mlua::Result<(Value, Value)> {
    Ok((Value::Nil, Value::String(lua.create_string(error)?)))
}

impl UserData for Socket {
    fn add_methods<M: UserDataMethods<Self>>(methods: &mut M) {
        methods.add_method("id", |_, socket, ()| Ok(socket.id));
        methods.add_method("send", |lua, socket, bytes: LuaString| match socket.send(&bytes.as_bytes()) {
            Ok(()) => Ok((Value::Boolean(true), Value::Nil)),
            Err(error) => problem(lua, error),
        });
        methods.add_method_mut("receive", |lua, socket, (count, timeout): (Option<usize>, Option<f64>)| {
            match socket.receive(count, timeout) {
                Ok(bytes) => Ok((Value::String(lua.create_string(bytes)?), Value::Nil)),
                Err(error) => problem(lua, error),
            }
        });
        methods.add_method_mut("listen", |_, socket, ()| socket.listen().map_err(mlua::Error::runtime));
        methods.add_method("close", |_, socket, ()| {
            socket.close();
            Ok(())
        });
    }
}

pub fn install(lua: &Lua, events: Sender<Message>, policy: std::sync::Arc<super::sandbox::Policy>) -> mlua::Result<()> {
    lua.globals().set(
        "__nari_tcp",
        lua.create_function(move |lua, spec: Table| {
            policy.require_network("nari.tcp()")?;
            let host: String = spec.get("host")?;
            let port: u16 = spec.get("port")?;
            let tls = spec.get::<Option<bool>>("tls")?.unwrap_or(false);
            let timeout = Duration::from_secs_f64(spec.get::<Option<f64>>("timeout")?.unwrap_or(CONNECT_TIMEOUT).max(0.1));
            match Socket::connect(&host, port, tls, timeout, events.clone()) {
                Ok(socket) => Ok((Value::UserData(lua.create_userdata(socket)?), Value::Nil)),
                Err(error) => problem(lua, error),
            }
        })?,
    )
}
