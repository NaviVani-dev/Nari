use std::collections::HashMap;
use std::io::{BufRead, BufReader, Read, Write};
use std::net::{TcpListener, TcpStream};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{channel, Sender};
use std::sync::Arc;
use std::time::Duration;

const POLL: Duration = Duration::from_millis(25);
const READ_TIMEOUT: Duration = Duration::from_secs(10);
const ANSWER_TIMEOUT: Duration = Duration::from_secs(30);
const BODY_LIMIT: usize = 1024 * 1024;
const HEADER_LIMIT: usize = 100;
const HEAD_BYTES_LIMIT: u64 = 64 * 1024;

pub struct Incoming {
    pub method: String,
    pub path: String,
    pub query: HashMap<String, String>,
    pub headers: HashMap<String, String>,
    pub body: String,
    pub reply: Sender<Outgoing>,
}

pub struct Outgoing {
    pub status: u16,
    pub headers: Vec<(String, String)>,
    pub body: String,
}

impl Outgoing {
    pub fn text(status: u16, body: &str) -> Self {
        Self { status, headers: Vec::new(), body: body.to_owned() }
    }
}

pub struct Server {
    pub port: u16,
    stop: Arc<AtomicBool>,
}

impl Drop for Server {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
    }
}

pub fn start(port: u16, deliver: impl Fn(Incoming) -> bool + Clone + Send + 'static) -> std::io::Result<Server> {
    let listener = TcpListener::bind(("127.0.0.1", port))?;
    listener.set_nonblocking(true)?;
    let port = listener.local_addr()?.port();
    let stop = Arc::new(AtomicBool::new(false));
    let stopped = stop.clone();
    std::thread::Builder::new().name(format!("plugin-serve-{port}")).spawn(move || {
        while !stopped.load(Ordering::Relaxed) {
            match listener.accept() {
                Ok((stream, _)) => {
                    let deliver = deliver.clone();
                    let _ = std::thread::Builder::new().name("plugin-serve-request".into()).spawn(move || answer(stream, deliver));
                }
                Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => std::thread::sleep(POLL),
                Err(_) => break,
            }
        }
    })?;
    Ok(Server { port, stop })
}

fn answer(mut stream: TcpStream, deliver: impl Fn(Incoming) -> bool) {
    let _ = stream.set_nonblocking(false);
    let _ = stream.set_read_timeout(Some(READ_TIMEOUT));
    let outgoing = match read(&stream) {
        Some((method, target, headers, body)) => {
            let (path, query) = target.split_once('?').unwrap_or((target.as_str(), ""));
            let (reply, replies) = channel();
            let incoming = Incoming { method, path: decode(path, false), query: parse_query(query), headers, body, reply };
            if !deliver(incoming) {
                Outgoing::text(503, "the plugin was turned off")
            } else {
                replies.recv_timeout(ANSWER_TIMEOUT).unwrap_or_else(|_| Outgoing::text(504, "the plugin didn't answer"))
            }
        }
        None => Outgoing::text(400, "bad request"),
    };
    let mut head = format!("HTTP/1.1 {} {}\r\nContent-Length: {}\r\nConnection: close\r\n", outgoing.status, reason(outgoing.status), outgoing.body.len());
    if !outgoing.headers.iter().any(|(name, _)| name.eq_ignore_ascii_case("content-type")) {
        head.push_str("Content-Type: text/html; charset=utf-8\r\n");
    }
    for (name, value) in &outgoing.headers {
        if !name.contains(['\r', '\n']) && !value.contains(['\r', '\n']) && !name.eq_ignore_ascii_case("content-length") {
            head.push_str(&format!("{name}: {value}\r\n"));
        }
    }
    head.push_str("\r\n");
    let _ = stream.write_all(head.as_bytes());
    let _ = stream.write_all(outgoing.body.as_bytes());
}

pub(crate) fn read(stream: &TcpStream) -> Option<(String, String, HashMap<String, String>, String)> {
    let mut reader = BufReader::new(stream.take(HEAD_BYTES_LIMIT + BODY_LIMIT as u64));
    let mut line = String::new();
    reader.read_line(&mut line).ok()?;
    let mut parts = line.split_whitespace();
    let method = parts.next()?.to_uppercase();
    let target = parts.next()?.to_owned();
    let mut headers = HashMap::new();
    for _ in 0..HEADER_LIMIT {
        line.clear();
        if reader.read_line(&mut line).ok()? == 0 || line.trim().is_empty() {
            break;
        }
        if let Some((name, value)) = line.split_once(':') {
            headers.insert(name.trim().to_lowercase(), value.trim().to_owned());
        }
    }
    let length = headers.get("content-length").and_then(|value| value.parse::<usize>().ok()).unwrap_or(0);
    if length > BODY_LIMIT {
        return None;
    }
    let mut body = vec![0; length];
    reader.read_exact(&mut body).ok()?;
    Some((method, target, headers, String::from_utf8_lossy(&body).into_owned()))
}

fn parse_query(query: &str) -> HashMap<String, String> {
    query
        .split('&')
        .filter(|pair| !pair.is_empty())
        .map(|pair| {
            let (name, value) = pair.split_once('=').unwrap_or((pair, ""));
            (decode(name, true), decode(value, true))
        })
        .collect()
}

fn decode(text: &str, plus_is_space: bool) -> String {
    let bytes = text.as_bytes();
    let hex = |byte: u8| (byte as char).to_digit(16).map(|digit| digit as u8);
    let mut out = Vec::with_capacity(bytes.len());
    let mut index = 0;
    while index < bytes.len() {
        let escaped = (bytes[index] == b'%' && index + 2 < bytes.len())
            .then(|| Some(hex(bytes[index + 1])? * 16 + hex(bytes[index + 2])?))
            .flatten();
        match (escaped, bytes[index]) {
            (Some(byte), _) => {
                out.push(byte);
                index += 3;
                continue;
            }
            (None, b'+') if plus_is_space => out.push(b' '),
            (None, byte) => out.push(byte),
        }
        index += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

fn reason(status: u16) -> &'static str {
    match status {
        200 => "OK",
        201 => "Created",
        204 => "No Content",
        301 => "Moved Permanently",
        302 => "Found",
        400 => "Bad Request",
        401 => "Unauthorized",
        403 => "Forbidden",
        404 => "Not Found",
        500 => "Internal Server Error",
        503 => "Service Unavailable",
        504 => "Gateway Timeout",
        _ => "Status",
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn serves_requests_through_the_inbox() {
        let (outbox, inbox) = channel();
        let server = start(0, move |incoming| outbox.send(incoming).is_ok()).unwrap();
        let port = server.port;
        assert!(start(port, |_| true).is_err(), "a fixed port that is taken fails");
        let client = std::thread::spawn(move || {
            let mut stream = TcpStream::connect(("127.0.0.1", port)).unwrap();
            stream
                .write_all(b"POST /callback%20here?code=a%2Bb&state=x+y HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n\r\nhello")
                .unwrap();
            let mut text = String::new();
            stream.read_to_string(&mut text).unwrap();
            text
        });
        let Ok(incoming) = inbox.recv_timeout(Duration::from_secs(5)) else {
            panic!("no request arrived");
        };
        assert_eq!((incoming.method.as_str(), incoming.path.as_str(), incoming.body.as_str()), ("POST", "/callback here", "hello"));
        assert_eq!(incoming.query.get("code").map(String::as_str), Some("a+b"));
        assert_eq!(incoming.query.get("state").map(String::as_str), Some("x y"));
        incoming
            .reply
            .send(Outgoing { status: 302, headers: vec![("Location".into(), "/done".into())], body: "bye".into() })
            .unwrap();
        let text = client.join().unwrap();
        assert!(text.starts_with("HTTP/1.1 302 Found\r\n") && text.contains("Location: /done") && text.ends_with("bye"), "{text}");
        drop(server);
    }
}
