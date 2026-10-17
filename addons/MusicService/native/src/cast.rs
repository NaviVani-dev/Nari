use mdns_sd::{HostnameResolutionEvent, Receiver as Answers, ServiceDaemon, ServiceEvent, TryRecvError};
use opus_rs::{Application, OpusEncoder};
use rustls::client::danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier};
use rustls::pki_types::{CertificateDer, ServerName, UnixTime};
use rustls::{ClientConfig, ClientConnection, DigitallySignedStruct, SignatureScheme, StreamOwned};
use serde::Serialize;
use serde_json::{json, Value};
use std::collections::VecDeque;
use std::io::{ErrorKind, Read, Write};
use std::net::{IpAddr, Ipv4Addr, SocketAddr, TcpListener, TcpStream, UdpSocket};
use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64, Ordering};
use std::sync::mpsc::{channel, Receiver, Sender};
use std::sync::{Arc, Condvar, Mutex, MutexGuard, Weak};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use crate::audio::{CAST_RATE, CHANNELS};
use crate::events::Event;
use crate::player::Player;

const FRAME: usize = 960;
const WINDOW_PAGES: usize = 1500;
const NONE: u64 = u64::MAX;
const OPUS_BITRATE: i32 = 256_000;
const PRE_SKIP: u16 = 312;
const OGG_SERIAL: u32 = 0x4e41_5249;
const POLL: Duration = Duration::from_millis(25);
const WAIT: Duration = Duration::from_millis(100);
const WRITE_TIMEOUT: Duration = Duration::from_secs(5);
const CONNECT_TIMEOUT: Duration = Duration::from_secs(10);
const READ_SLICE: Duration = Duration::from_millis(250);
const PING_INTERVAL: Duration = Duration::from_secs(5);
const LAUNCH_TIMEOUT: Duration = Duration::from_secs(15);
const PLAYING_TIMEOUT: Duration = Duration::from_secs(20);
const RELOAD_INTERVAL: Duration = Duration::from_secs(2);
const STATUS_INTERVAL: Duration = Duration::from_secs(1);
const LOG_INTERVAL: Duration = Duration::from_secs(5);
const SETTLE: Duration = Duration::from_secs(2);
const RELOAD_LEAD: Duration = Duration::from_millis(150);
const DRAIN_PACE: f32 = 0.7;
const DRAIN_TARGET_MS: u64 = 2000;
const START_FILL_MS: u64 = 10_500;
const FILL_STEP_MS: u64 = 1000;
const FILL_LIMIT_MS: u64 = 20_000;
const DRAIN_STEP_MS: u64 = 1500;
const DRAIN_LIMIT_MS: u64 = 12_000;
const DRAIN_MARGIN_MS: u64 = 500;
const SMOOTH_LIMIT_MS: f64 = 1500.0;
const SMOOTHING: f64 = 0.25;
const ECHO_GRACE: Duration = Duration::from_millis(1500);
const FRAME_LIMIT: usize = 1024 * 1024;
pub const STREAM_PATH: &str = "/stream.ogg";
const COVER_PATH: &str = "/cover/";
const ALIVE_INTERVAL: Duration = Duration::from_secs(4);
const ALIVE_TIMEOUT: Duration = Duration::from_millis(800);
const RESOLVE_TIMEOUT_MS: u64 = 5000;
const CAPABILITY_VIDEO: u32 = 1;
const CAPABILITY_GROUP: u32 = 32;
const SERVICE_TYPE: &str = "_googlecast._tcp.local.";
const APP_ID: &str = "CC1AD845";
const CAST_PORT: u16 = 8009;
const SENDER: &str = "sender-0";
const PLATFORM: &str = "receiver-0";
const NS_CONNECTION: &str = "urn:x-cast:com.google.cast.tp.connection";
const NS_HEARTBEAT: &str = "urn:x-cast:com.google.cast.tp.heartbeat";
const NS_RECEIVER: &str = "urn:x-cast:com.google.cast.receiver";
const NS_MEDIA: &str = "urn:x-cast:com.google.cast.media";

pub struct Broadcast {
    window: Mutex<Window>,
    ready: Condvar,
    encoder: Mutex<Encoder>,
    headers: Vec<Vec<u8>>,
    art: Mutex<String>,
    flush_mark: AtomicU64,
    track_mark: AtomicU64,
    start: AtomicU64,
    client: AtomicU64,
    client_frames: AtomicU64,
    hungry: AtomicBool,
    pace: AtomicU32,
    epoch: Instant,
    origin: AtomicU64,
    heard: AtomicU64,
    heard_at: AtomicU64,
    heard_running: AtomicBool,
    followed: AtomicBool,
}

struct Window {
    pages: VecDeque<Vec<u8>>,
    head: u64,
}

struct Encoder {
    opus: OpusEncoder,
    granule: u64,
    packet: Vec<u8>,
}

fn ogg_crc(bytes: &[u8]) -> u32 {
    let mut crc = 0u32;
    for byte in bytes {
        crc ^= u32::from(*byte) << 24;
        for _ in 0..8 {
            crc = if crc & 0x8000_0000 != 0 { (crc << 1) ^ 0x04c1_1db7 } else { crc << 1 };
        }
    }
    crc
}

fn ogg_page(flags: u8, granule: u64, packet: &[u8]) -> Vec<u8> {
    let mut page = Vec::with_capacity(packet.len() + 27 + packet.len() / 255 + 1);
    page.extend_from_slice(b"OggS\0");
    page.push(flags);
    page.extend_from_slice(&granule.to_le_bytes());
    page.extend_from_slice(&OGG_SERIAL.to_le_bytes());
    page.extend_from_slice(&[0; 8]);
    let full = packet.len() / 255;
    page.push((full + 1) as u8);
    page.extend(std::iter::repeat_n(255u8, full));
    page.push((packet.len() % 255) as u8);
    page.extend_from_slice(packet);
    page
}

fn granule(page: &[u8]) -> u64 {
    u64::from_le_bytes(page[6..14].try_into().unwrap_or_default())
}

fn restamp(page: &mut [u8], granule: u64, sequence: u32) {
    page[6..14].copy_from_slice(&granule.to_le_bytes());
    seal(page, sequence);
}

fn seal(page: &mut [u8], sequence: u32) {
    page[18..22].copy_from_slice(&sequence.to_le_bytes());
    page[22..26].fill(0);
    let crc = ogg_crc(page);
    page[22..26].copy_from_slice(&crc.to_le_bytes());
}

fn opus_headers() -> Vec<Vec<u8>> {
    let mut head = Vec::new();
    head.extend_from_slice(b"OpusHead");
    head.push(1);
    head.push(CHANNELS as u8);
    head.extend_from_slice(&PRE_SKIP.to_le_bytes());
    head.extend_from_slice(&CAST_RATE.to_le_bytes());
    head.extend_from_slice(&0i16.to_le_bytes());
    head.push(0);
    let mut tags = Vec::new();
    tags.extend_from_slice(b"OpusTags");
    tags.extend_from_slice(&4u32.to_le_bytes());
    tags.extend_from_slice(b"Nari");
    tags.extend_from_slice(&0u32.to_le_bytes());
    let mut pages = vec![ogg_page(0x02, 0, &head), ogg_page(0, 0, &tags)];
    for (sequence, page) in pages.iter_mut().enumerate() {
        seal(page, sequence as u32);
    }
    pages
}

impl Broadcast {
    pub fn new() -> Option<Self> {
        let mut opus = OpusEncoder::new(CAST_RATE as i32, CHANNELS, Application::Audio).ok()?;
        opus.bitrate_bps = OPUS_BITRATE;
        Some(Self {
            window: Mutex::new(Window { pages: VecDeque::with_capacity(WINDOW_PAGES), head: 0 }),
            ready: Condvar::new(),
            encoder: Mutex::new(Encoder { opus, granule: 0, packet: vec![0; 4000] }),
            headers: opus_headers(),
            art: Mutex::new(String::new()),
            flush_mark: AtomicU64::new(NONE),
            track_mark: AtomicU64::new(NONE),
            start: AtomicU64::new(0),
            client: AtomicU64::new(0),
            client_frames: AtomicU64::new(0),
            hungry: AtomicBool::new(false),
            pace: AtomicU32::new(1.0f32.to_bits()),
            epoch: Instant::now(),
            origin: AtomicU64::new(0),
            heard: AtomicU64::new(0.0f64.to_bits()),
            heard_at: AtomicU64::new(0),
            heard_running: AtomicBool::new(false),
            followed: AtomicBool::new(false),
        })
    }

    fn lock(&self) -> MutexGuard<'_, Window> {
        self.window.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    pub fn push_pcm(&self, pcm: &[f32]) {
        let page = {
            let mut encoder = self.encoder.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
            let Encoder { opus, granule, packet } = &mut *encoder;
            let Ok(written) = opus.encode(pcm, FRAME, packet) else {
                return;
            };
            *granule += FRAME as u64;
            ogg_page(0, *granule, &packet[..written])
        };
        let mut window = self.lock();
        window.pages.push_back(page);
        while window.pages.len() > WINDOW_PAGES {
            window.pages.pop_front();
        }
        window.head += 1;
        self.ready.notify_all();
    }

    pub fn mark_flush(&self) {
        let head = self.head();
        self.flush_mark.store(head, Ordering::Relaxed);
        self.restart_clock(head);
    }

    fn flush_pending(&self) -> bool {
        self.flush_mark.load(Ordering::Relaxed) != NONE
    }

    pub fn mark_track(&self) {
        self.track_mark.store(self.head(), Ordering::Relaxed);
    }

    fn take_flush(&self) -> Option<u64> {
        Some(self.flush_mark.swap(NONE, Ordering::Relaxed)).filter(|mark| *mark != NONE)
    }

    fn take_track(&self) -> Option<u64> {
        Some(self.track_mark.swap(NONE, Ordering::Relaxed)).filter(|mark| *mark != NONE)
    }

    fn start_at(&self, page: Option<u64>) {
        self.start.store(page.unwrap_or(NONE), Ordering::Relaxed);
        self.client.fetch_add(1, Ordering::Relaxed);
        self.client_frames.store(0, Ordering::Relaxed);
        self.restart_clock(page.unwrap_or_else(|| self.head()));
    }

    fn open_client(&self) -> (u64, u64) {
        let start = self.start.load(Ordering::Relaxed);
        let window = self.lock();
        let first = window.head - window.pages.len() as u64;
        let cursor = if start == NONE || start < first || start > window.head { window.head } else { start };
        self.origin.store(cursor, Ordering::Relaxed);
        (cursor, self.client.load(Ordering::Relaxed))
    }

    fn restart_clock(&self, origin: u64) {
        self.origin.store(origin, Ordering::Relaxed);
        self.heard_running.store(false, Ordering::Relaxed);
        self.heard.store(0.0f64.to_bits(), Ordering::Relaxed);
    }

    fn heard_ms(&self) -> f64 {
        let heard = f64::from_bits(self.heard.load(Ordering::Relaxed));
        if !self.heard_running.load(Ordering::Relaxed) {
            return heard;
        }
        let since = self.epoch.elapsed().saturating_sub(Duration::from_nanos(self.heard_at.load(Ordering::Relaxed)));
        heard + since.as_secs_f64() * 1000.0
    }

    fn hear(&self, media_ms: f64, running: bool) {
        let current = self.heard_ms();
        let steady = running && self.heard_running.load(Ordering::Relaxed) && (media_ms - current).abs() < SMOOTH_LIMIT_MS;
        let heard = if steady { current + (media_ms - current) * SMOOTHING } else { media_ms };
        self.heard.store(heard.max(0.0).to_bits(), Ordering::Relaxed);
        self.heard_at.store(self.epoch.elapsed().as_nanos() as u64, Ordering::Relaxed);
        self.heard_running.store(running, Ordering::Relaxed);
    }

    pub fn until_ms(&self, page: u64) -> u64 {
        if !self.followed.load(Ordering::Relaxed) {
            return 0;
        }
        let pages = page.saturating_sub(self.origin.load(Ordering::Relaxed));
        let queued = (pages * FRAME as u64 * 1000 / u64::from(CAST_RATE)) as f64;
        (queued - self.heard_ms()).max(0.0) as u64
    }

    fn sent(&self, client: u64, frames: u64) {
        if self.client.load(Ordering::Relaxed) == client {
            self.client_frames.store(frames, Ordering::Relaxed);
        }
    }

    fn sent_ms(&self) -> u64 {
        self.client_frames.load(Ordering::Relaxed) * 1000 / u64::from(CAST_RATE)
    }

    pub fn hungry(&self) -> bool {
        self.hungry.load(Ordering::Relaxed)
    }

    fn set_hungry(&self, hungry: bool) {
        self.hungry.store(hungry, Ordering::Relaxed);
    }

    pub fn pace(&self) -> f32 {
        f32::from_bits(self.pace.load(Ordering::Relaxed))
    }

    fn set_pace(&self, pace: f32) {
        self.pace.store(pace.to_bits(), Ordering::Relaxed);
    }

    pub fn delay_ms(&self) -> u64 {
        self.until_ms(self.head())
    }

    fn set_art(&self, path: &str) {
        *self.art.lock().unwrap_or_else(|poisoned| poisoned.into_inner()) = path.to_owned();
    }

    fn art(&self) -> String {
        self.art.lock().unwrap_or_else(|poisoned| poisoned.into_inner()).clone()
    }

    pub fn head(&self) -> u64 {
        self.lock().head
    }

    pub fn read(&self, cursor: &mut u64, out: &mut Vec<Vec<u8>>) {
        let mut window = self.lock();
        if window.head == *cursor {
            window = self.ready.wait_timeout(window, WAIT).unwrap_or_else(|poisoned| poisoned.into_inner()).0;
        }
        let start = window.head - window.pages.len() as u64;
        if *cursor < start {
            *cursor = start;
        }
        let offset = (*cursor - start) as usize;
        out.clear();
        out.extend(window.pages.range(offset..).cloned());
        *cursor = window.head;
    }
}

pub struct StreamServer {
    pub port: u16,
    pub secret: String,
    stop: Arc<AtomicBool>,
}

impl StreamServer {
    pub fn base(&self, host: impl std::fmt::Display) -> String {
        format!("http://{host}:{}/{}", self.port, self.secret)
    }
}

impl Drop for StreamServer {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
    }
}

pub fn serve(sink: Arc<Broadcast>) -> std::io::Result<StreamServer> {
    let listener = TcpListener::bind(("0.0.0.0", 0))?;
    listener.set_nonblocking(true)?;
    let port = listener.local_addr()?.port();
    let secret = crate::plugins::hex(&rand::random::<[u8; 16]>());
    let prefix = format!("/{secret}");
    let stop = Arc::new(AtomicBool::new(false));
    let stopped = stop.clone();
    std::thread::Builder::new().name("cast-serve".into()).spawn(move || {
        while !stopped.load(Ordering::Relaxed) {
            match listener.accept() {
                Ok((stream, _)) => {
                    let (sink, stopped, prefix) = (sink.clone(), stopped.clone(), prefix.clone());
                    let _ = std::thread::Builder::new().name("cast-stream".into()).spawn(move || stream_ogg(stream, sink, stopped, &prefix));
                }
                Err(error) if error.kind() == ErrorKind::WouldBlock => std::thread::sleep(POLL),
                Err(_) => break,
            }
        }
    })?;
    Ok(StreamServer { port, secret, stop })
}

fn stream_ogg(mut stream: TcpStream, sink: Arc<Broadcast>, stop: Arc<AtomicBool>, prefix: &str) {
    let _ = stream.set_nonblocking(false);
    let _ = stream.set_read_timeout(Some(Duration::from_secs(10)));
    let _ = stream.set_write_timeout(Some(WRITE_TIMEOUT));
    let _ = stream.set_nodelay(true);
    let Some((method, target, _, _)) = crate::plugins::serve::read(&stream) else {
        return;
    };
    let Some(target) = target.strip_prefix(prefix) else {
        let _ = stream.write_all(b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
        return;
    };
    if target.starts_with(COVER_PATH) {
        let art = sink.art();
        let (status, body) = match std::fs::read(&art) {
            Ok(bytes) if !art.is_empty() => ("200 OK", bytes),
            _ => ("404 Not Found", Vec::new()),
        };
        let kind = if art.to_lowercase().ends_with(".png") { "image/png" } else { "image/jpeg" };
        let head = format!("HTTP/1.1 {status}\r\nContent-Type: {kind}\r\nContent-Length: {}\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n", body.len());
        let _ = stream.write_all(head.as_bytes()).and_then(|()| stream.write_all(&body));
        return;
    }
    let head = "HTTP/1.1 200 OK\r\nContent-Type: audio/ogg\r\nCache-Control: no-cache, no-store\r\nAccept-Ranges: none\r\nConnection: close\r\n\r\n";
    if stream.write_all(head.as_bytes()).is_err() || method == "HEAD" {
        return;
    }
    for page in &sink.headers {
        if stream.write_all(page).is_err() {
            return;
        }
    }
    let (mut cursor, client) = sink.open_client();
    let mut pages = Vec::new();
    let mut sequence = sink.headers.len() as u32;
    let mut base = None;
    while !stop.load(Ordering::Relaxed) {
        sink.read(&mut cursor, &mut pages);
        for page in &mut pages {
            let original = granule(page);
            let rebased = original - *base.get_or_insert(original.saturating_sub(FRAME as u64));
            restamp(page, rebased, sequence);
            sequence += 1;
            if stream.write_all(page).is_err() {
                return;
            }
            sink.sent(client, rebased);
        }
    }
}

#[derive(Clone, Serialize)]
pub struct Device {
    pub id: String,
    pub name: String,
    pub model: String,
    pub kind: &'static str,
    #[serde(skip)]
    pub ip: Ipv4Addr,
    #[serde(skip)]
    pub port: u16,
    #[serde(skip)]
    fullname: String,
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Phase {
    Idle,
    Connecting,
    Casting,
    Error,
}

impl Phase {
    fn name(self) -> &'static str {
        match self {
            Phase::Idle => "idle",
            Phase::Connecting => "connecting",
            Phase::Casting => "casting",
            Phase::Error => "error",
        }
    }
}

struct State {
    phase: Phase,
    device: String,
    kind: &'static str,
    error: String,
    volume: f32,
    url: String,
    devices: Vec<Device>,
}

pub trait Host: Send + Sync {
    fn route(&self, sink: Option<Arc<Broadcast>>);
    fn set_playing(&self, playing: bool);
    fn media(&self) -> crate::mpris::Media;
}

struct PlayerHost(Weak<Mutex<Player>>);

impl PlayerHost {
    fn with(&self, act: impl FnOnce(&mut Player)) {
        if let Some(player) = self.0.upgrade() {
            act(&mut player.lock().unwrap_or_else(|poisoned| poisoned.into_inner()));
        }
    }
}

impl Host for PlayerHost {
    fn route(&self, sink: Option<Arc<Broadcast>>) {
        self.with(|player| player.set_cast(sink));
    }

    fn set_playing(&self, playing: bool) {
        self.with(|player| if playing { player.resume() } else { player.pause() });
    }

    fn media(&self) -> crate::mpris::Media {
        let mut media = crate::mpris::Media::default();
        self.with(|player| media = player.media());
        media
    }
}

struct Shared {
    state: Mutex<State>,
    events: Sender<Event>,
}

impl Shared {
    fn state(&self) -> MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    fn state_json(&self) -> String {
        let state = self.state();
        json!({
            "phase": state.phase.name(),
            "device": state.device,
            "kind": state.kind,
            "error": state.error,
            "volume": state.volume,
            "url": state.url,
        })
        .to_string()
    }

    fn set(&self, update: impl FnOnce(&mut State)) {
        update(&mut self.state());
        let _ = self.events.send(Event::CastState(self.state_json()));
    }

    fn fail(&self, error: &str) {
        self.set(|state| {
            state.phase = Phase::Error;
            state.error = error.to_owned();
        });
    }

    fn devices_json(&self) -> String {
        serde_json::to_string(&self.state().devices).unwrap_or_else(|_| "[]".into())
    }
}

pub struct Cast {
    shared: Arc<Shared>,
    host: Arc<dyn Host>,
    scan: Option<Scan>,
    session: Option<Session>,
}

struct Scan {
    daemon: ServiceDaemon,
    quit: Arc<AtomicBool>,
    thread: Option<JoinHandle<()>>,
}

struct Session {
    quit: Arc<AtomicBool>,
    thread: Option<JoinHandle<()>>,
    commands: Sender<Command>,
    _server: StreamServer,
}

enum Command {
    Volume(f32),
}

impl Cast {
    pub fn new(player: Weak<Mutex<Player>>, events: Sender<Event>) -> Self {
        Self::with_host(Arc::new(PlayerHost(player)), events)
    }

    fn with_host(host: Arc<dyn Host>, events: Sender<Event>) -> Self {
        let state = State { phase: Phase::Idle, device: String::new(), kind: "", error: String::new(), volume: -1.0, url: String::new(), devices: Vec::new() };
        Self { shared: Arc::new(Shared { state: Mutex::new(state), events }), host, scan: None, session: None }
    }

    pub fn scan(&mut self, enabled: bool) {
        if !enabled {
            if let Some(mut scan) = self.scan.take() {
                scan.quit.store(true, Ordering::Relaxed);
                let _ = scan.daemon.shutdown();
                if let Some(thread) = scan.thread.take() {
                    let _ = thread.join();
                }
                #[cfg(target_os = "android")]
                crate::android::system("multicast:off");
            }
            return;
        }
        if self.scan.is_some() {
            return;
        }
        #[cfg(target_os = "android")]
        crate::android::system("multicast:on");
        let Ok(daemon) = ServiceDaemon::new() else {
            return;
        };
        let Ok(found) = daemon.browse(SERVICE_TYPE) else {
            return;
        };
        self.shared.state().devices.clear();
        let _ = self.shared.events.send(Event::CastDevices(self.shared.devices_json()));
        let quit = Arc::new(AtomicBool::new(false));
        let (shared, stopped, resolver) = (self.shared.clone(), quit.clone(), daemon.clone());
        let thread = std::thread::Builder::new()
            .name("cast-scan".into())
            .spawn(move || {
                let mut unresolved: Vec<(Device, Answers<HostnameResolutionEvent>)> = Vec::new();
                let mut last_check = Instant::now();
                while !stopped.load(Ordering::Relaxed) {
                    if last_check.elapsed() > ALIVE_INTERVAL {
                        drop_silent(&shared);
                        last_check = Instant::now();
                    }
                    match found.recv_timeout(READ_SLICE) {
                        Ok(ServiceEvent::ServiceResolved(info)) => {
                            let device = Device {
                                id: info.get_property_val_str("id").unwrap_or(info.get_fullname()).to_owned(),
                                name: info.get_property_val_str("fn").unwrap_or(info.get_hostname()).to_owned(),
                                model: info.get_property_val_str("md").unwrap_or_default().to_owned(),
                                kind: kind_of(info.get_property_val_str("md").unwrap_or_default(), info.get_property_val_str("ca").and_then(|ca| ca.parse().ok()).unwrap_or(0)),
                                ip: info.get_addresses_v4().into_iter().next().unwrap_or(Ipv4Addr::UNSPECIFIED),
                                port: info.get_port(),
                                fullname: info.get_fullname().to_owned(),
                            };
                            unresolved.retain(|(waiting, _)| waiting.fullname != device.fullname);
                            if !device.ip.is_unspecified() {
                                add_device(&shared, device);
                            } else if let Ok(answers) = resolver.resolve_hostname(info.get_hostname(), Some(RESOLVE_TIMEOUT_MS)) {
                                unresolved.push((device, answers));
                            }
                        }
                        Ok(ServiceEvent::ServiceRemoved(_, fullname)) => {
                            unresolved.retain(|(waiting, _)| waiting.fullname != fullname);
                            shared.state().devices.retain(|known| known.fullname != fullname);
                            let _ = shared.events.send(Event::CastDevices(shared.devices_json()));
                        }
                        Ok(_) => {}
                        Err(_) if found.is_disconnected() => break,
                        Err(_) => {}
                    }
                    unresolved.retain_mut(|(device, answers)| loop {
                        match answers.try_recv() {
                            Ok(HostnameResolutionEvent::AddressesFound(_, addresses)) => {
                                let Some(ip) = addresses.iter().find_map(|address| match address.to_ip_addr() {
                                    IpAddr::V4(ip) => Some(ip),
                                    IpAddr::V6(_) => None,
                                }) else {
                                    continue;
                                };
                                device.ip = ip;
                                add_device(&shared, device.clone());
                                return false;
                            }
                            Ok(HostnameResolutionEvent::SearchTimeout(_) | HostnameResolutionEvent::SearchStopped(_)) => return false,
                            Ok(_) => {}
                            Err(TryRecvError::Empty) => return true,
                            Err(TryRecvError::Disconnected) => return false,
                        }
                    });
                }
            })
            .ok();
        self.scan = Some(Scan { daemon, quit, thread });
    }

    pub fn devices_json(&self) -> String {
        self.shared.devices_json()
    }

    pub fn state_json(&self) -> String {
        self.shared.state_json()
    }

    pub fn connect(&mut self, id: &str) -> bool {
        self.disconnect();
        let device = if id == "local" {
            None
        } else if let Some(address) = id.strip_prefix("ip:") {
            let (host, port) = address.split_once(':').unwrap_or((address, ""));
            let Ok(ip) = host.parse::<Ipv4Addr>() else {
                self.shared.fail("that is not an IPv4 address");
                return false;
            };
            Some(Device { id: id.to_owned(), name: host.to_owned(), model: String::new(), kind: "speaker", ip, port: port.parse().unwrap_or(CAST_PORT), fullname: String::new() })
        } else {
            let found = self.shared.state().devices.iter().find(|device| device.id == id).cloned();
            match found {
                Some(device) => Some(device),
                None => {
                    self.shared.fail("that device is no longer on the network");
                    return false;
                }
            }
        };
        let Some(sink) = Broadcast::new().map(Arc::new) else {
            self.shared.fail("couldn't start the Opus encoder");
            return false;
        };
        let server = match serve(sink.clone()) {
            Ok(server) => server,
            Err(error) => {
                self.shared.fail(&format!("couldn't open the audio stream: {error}"));
                return false;
            }
        };
        self.host.route(Some(sink.clone()));
        #[cfg(target_os = "android")]
        crate::android::system("wifi_lock:on");
        let quit = Arc::new(AtomicBool::new(false));
        let (commands, inbox) = channel();
        let thread = match device {
            Some(device) => {
                sink.followed.store(true, Ordering::Relaxed);
                self.shared.set(|state| {
                    state.phase = Phase::Connecting;
                    state.device = device.name.clone();
                    state.kind = device.kind;
                    state.error.clear();
                    state.volume = -1.0;
                });
                let (shared, host, stopped) = (self.shared.clone(), self.host.clone(), quit.clone());
                let (port, secret) = (server.port, server.secret.clone());
                std::thread::Builder::new()
                    .name("cast-session".into())
                    .spawn(move || {
                        let outcome = session(&device, port, &secret, &shared, host.as_ref(), &sink, &inbox, &stopped);
                        host.route(None);
                        match outcome {
                            Ok(()) => shared.set(|state| state.phase = Phase::Idle),
                            Err(error) => shared.fail(&error),
                        }
                    })
                    .ok()
            }
            None => {
                self.shared.set(|state| {
                    state.phase = Phase::Casting;
                    state.device = "local".into();
                    state.kind = "speaker";
                    state.error.clear();
                    state.url = format!("{}{STREAM_PATH}", server.base("127.0.0.1"));
                });
                None
            }
        };
        self.session = Some(Session { quit, thread, commands, _server: server });
        true
    }

    pub fn disconnect(&mut self) {
        let Some(mut session) = self.session.take() else {
            return;
        };
        session.quit.store(true, Ordering::Relaxed);
        #[cfg(target_os = "android")]
        crate::android::system("wifi_lock:off");
        match session.thread.take() {
            Some(thread) => {
                let _ = thread.join();
            }
            None => {
                self.host.route(None);
                self.shared.set(|state| state.phase = Phase::Idle);
            }
        }
    }

    pub fn reap(&mut self) {
        if self.session.as_ref().is_some_and(|session| session.thread.as_ref().is_some_and(JoinHandle::is_finished)) {
            self.disconnect();
        }
    }

    pub fn set_volume(&self, level: f32) {
        if let Some(session) = self.session.as_ref() {
            let _ = session.commands.send(Command::Volume(level.clamp(0.0, 1.0)));
        }
    }

}

impl Drop for Cast {
    fn drop(&mut self) {
        self.scan(false);
        self.disconnect();
    }
}

fn kind_of(model: &str, capabilities: u32) -> &'static str {
    let model = model.to_lowercase();
    if capabilities & CAPABILITY_GROUP != 0 || model.contains("group") {
        "group"
    } else if model.contains("hub") {
        "display"
    } else if capabilities & CAPABILITY_VIDEO != 0 {
        "tv"
    } else {
        "speaker"
    }
}

fn drop_silent(shared: &Shared) {
    let devices = shared.state().devices.clone();
    let silent: Vec<String> = devices
        .iter()
        .filter(|device| TcpStream::connect_timeout(&SocketAddr::from((device.ip, device.port)), ALIVE_TIMEOUT).is_err())
        .map(|device| device.id.clone())
        .collect();
    if silent.is_empty() {
        return;
    }
    shared.state().devices.retain(|device| !silent.contains(&device.id));
    let _ = shared.events.send(Event::CastDevices(shared.devices_json()));
}

fn add_device(shared: &Shared, device: Device) {
    {
        let mut state = shared.state();
        state.devices.retain(|known| known.id != device.id && known.fullname != device.fullname);
        state.devices.push(device);
        state.devices.sort_by(|a, b| a.name.cmp(&b.name));
    }
    let _ = shared.events.send(Event::CastDevices(shared.devices_json()));
}

fn local_ip(target: Ipv4Addr) -> Result<Ipv4Addr, String> {
    let socket = UdpSocket::bind("0.0.0.0:0").map_err(|error| error.to_string())?;
    socket.connect((target, CAST_PORT)).map_err(|error| error.to_string())?;
    match socket.local_addr().map_err(|error| error.to_string())?.ip() {
        IpAddr::V4(ip) => Ok(ip),
        IpAddr::V6(_) => Err("no IPv4 route to the device".into()),
    }
}

#[derive(Debug)]
struct NoVerify(Vec<SignatureScheme>);

impl ServerCertVerifier for NoVerify {
    fn verify_server_cert(&self, _: &CertificateDer<'_>, _: &[CertificateDer<'_>], _: &ServerName<'_>, _: &[u8], _: UnixTime) -> Result<ServerCertVerified, rustls::Error> {
        Ok(ServerCertVerified::assertion())
    }

    fn verify_tls12_signature(&self, _: &[u8], _: &CertificateDer<'_>, _: &DigitallySignedStruct) -> Result<HandshakeSignatureValid, rustls::Error> {
        Ok(HandshakeSignatureValid::assertion())
    }

    fn verify_tls13_signature(&self, _: &[u8], _: &CertificateDer<'_>, _: &DigitallySignedStruct) -> Result<HandshakeSignatureValid, rustls::Error> {
        Ok(HandshakeSignatureValid::assertion())
    }

    fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
        self.0.clone()
    }
}

fn tls_config() -> Result<Arc<ClientConfig>, String> {
    let provider = rustls::crypto::ring::default_provider();
    let schemes = provider.signature_verification_algorithms.supported_schemes();
    Ok(Arc::new(
        ClientConfig::builder_with_provider(Arc::new(provider))
            .with_safe_default_protocol_versions()
            .map_err(|error| error.to_string())?
            .dangerous()
            .with_custom_certificate_verifier(Arc::new(NoVerify(schemes)))
            .with_no_client_auth(),
    ))
}

#[derive(Default, Debug, PartialEq, Eq)]
struct Message {
    source: String,
    destination: String,
    namespace: String,
    payload: String,
}

fn put_varint(out: &mut Vec<u8>, mut value: u64) {
    loop {
        let byte = (value & 0x7f) as u8;
        value >>= 7;
        if value == 0 {
            out.push(byte);
            return;
        }
        out.push(byte | 0x80);
    }
}

fn put_text(out: &mut Vec<u8>, field: u8, text: &str) {
    out.push(field << 3 | 2);
    put_varint(out, text.len() as u64);
    out.extend_from_slice(text.as_bytes());
}

fn encode(namespace: &str, destination: &str, payload: &str) -> Vec<u8> {
    let mut body = vec![0x08, 0x00];
    put_text(&mut body, 2, SENDER);
    put_text(&mut body, 3, destination);
    put_text(&mut body, 4, namespace);
    body.extend_from_slice(&[0x28, 0x00]);
    put_text(&mut body, 6, payload);
    let mut frame = (body.len() as u32).to_be_bytes().to_vec();
    frame.extend(body);
    frame
}

fn get_varint(bytes: &[u8], at: &mut usize) -> Option<u64> {
    let mut value = 0u64;
    for shift in (0..64).step_by(7) {
        let byte = *bytes.get(*at)?;
        *at += 1;
        value |= u64::from(byte & 0x7f) << shift;
        if byte & 0x80 == 0 {
            return Some(value);
        }
    }
    None
}

fn decode(body: &[u8]) -> Option<Message> {
    let mut message = Message::default();
    let mut at = 0;
    while at < body.len() {
        let tag = get_varint(body, &mut at)?;
        match tag & 7 {
            0 => {
                get_varint(body, &mut at)?;
            }
            1 => at += 8,
            5 => at += 4,
            2 => {
                let length = get_varint(body, &mut at)? as usize;
                let text = body.get(at..at + length)?;
                at += length;
                let text = String::from_utf8_lossy(text).into_owned();
                match tag >> 3 {
                    2 => message.source = text,
                    3 => message.destination = text,
                    4 => message.namespace = text,
                    6 => message.payload = text,
                    _ => {}
                }
            }
            _ => return None,
        }
    }
    Some(message)
}

fn timed_out(kind: ErrorKind) -> bool {
    matches!(kind, ErrorKind::WouldBlock | ErrorKind::TimedOut)
}

struct Link {
    tls: StreamOwned<ClientConnection, TcpStream>,
    inbox: Vec<u8>,
    request_id: u64,
}

impl Link {
    fn open(device: &Device) -> Result<Self, String> {
        let address = SocketAddr::from((device.ip, device.port));
        let tcp = TcpStream::connect_timeout(&address, CONNECT_TIMEOUT).map_err(|error| format!("couldn't reach the device: {error}"))?;
        let _ = tcp.set_nodelay(true);
        tcp.set_read_timeout(Some(CONNECT_TIMEOUT)).map_err(|error| error.to_string())?;
        tcp.set_write_timeout(Some(WRITE_TIMEOUT)).map_err(|error| error.to_string())?;
        let name = ServerName::IpAddress(IpAddr::V4(device.ip).into());
        let client = ClientConnection::new(tls_config()?, name).map_err(|error| error.to_string())?;
        let mut tls = StreamOwned::new(client, tcp);
        while tls.conn.is_handshaking() {
            tls.conn.complete_io(&mut tls.sock).map_err(|error| format!("TLS handshake failed: {error}"))?;
        }
        tls.sock.set_read_timeout(Some(READ_SLICE)).map_err(|error| error.to_string())?;
        Ok(Self { tls, inbox: Vec::new(), request_id: 0 })
    }

    fn send(&mut self, namespace: &str, destination: &str, mut payload: Value) -> Result<u64, String> {
        self.request_id += 1;
        if payload.get("type").is_some_and(|kind| kind != "PING" && kind != "PONG" && kind != "CONNECT") {
            payload["requestId"] = json!(self.request_id);
        }
        let frame = encode(namespace, destination, &payload.to_string());
        self.tls.write_all(&frame).map_err(|error| format!("the device stopped listening: {error}"))?;
        Ok(self.request_id)
    }

    fn poll(&mut self) -> Result<Vec<Message>, String> {
        let mut buffer = [0u8; 8192];
        match self.tls.read(&mut buffer) {
            Ok(0) => return Err("the device hung up".into()),
            Ok(read) => self.inbox.extend_from_slice(&buffer[..read]),
            Err(error) if timed_out(error.kind()) => {}
            Err(error) => return Err(format!("the connection to the device broke: {error}")),
        }
        let mut messages = Vec::new();
        while self.inbox.len() >= 4 {
            let length = u32::from_be_bytes([self.inbox[0], self.inbox[1], self.inbox[2], self.inbox[3]]) as usize;
            if length > FRAME_LIMIT {
                return Err("the device sent an oversized frame".into());
            }
            if self.inbox.len() < 4 + length {
                break;
            }
            let frame: Vec<u8> = self.inbox.drain(..4 + length).skip(4).collect();
            if let Some(message) = decode(&frame) {
                messages.push(message);
            }
        }
        Ok(messages)
    }
}

fn note_volume(shared: &Shared, status: &Value) {
    if let Some(level) = status["status"]["volume"]["level"].as_f64() {
        shared.set(|state| state.volume = level as f32);
    }
}

fn running_app(status: &Value) -> Option<(String, String)> {
    status["status"]["applications"].as_array()?.iter().find(|app| app["appId"] == APP_ID).map(|app| {
        (app["transportId"].as_str().unwrap_or_default().to_owned(), app["sessionId"].as_str().unwrap_or_default().to_owned())
    })
}

fn log(text: &str) {
    #[cfg(not(test))]
    godot::global::godot_print!("[cast] {text}");
    #[cfg(test)]
    eprintln!("[cast] {text}");
}

struct Now {
    title: String,
    artist: String,
    album: String,
    art: String,
    playing: bool,
}

fn snapshot(host: &dyn Host) -> Now {
    let media = host.media();
    Now { title: media.title, artist: media.artists.join(", "), album: media.album, art: media.art, playing: media.playing }
}

struct Clock {
    media_ms: f64,
    at: Instant,
    running: bool,
    since: Instant,
}

impl Clock {
    fn heard_ms(&self) -> u64 {
        let extra = if self.running { self.at.elapsed().as_secs_f64() * 1000.0 } else { 0.0 };
        (self.media_ms + extra).max(0.0) as u64
    }
}

#[allow(clippy::too_many_arguments)]
fn session(device: &Device, port: u16, secret: &str, shared: &Shared, host: &dyn Host, sink: &Broadcast, commands: &Receiver<Command>, quit: &AtomicBool) -> Result<(), String> {
    let base = format!("http://{}:{port}/{secret}", local_ip(device.ip)?);
    let url = format!("{base}{STREAM_PATH}");
    shared.set(|state| state.url = url.clone());
    log(&format!("connecting to {} at {}, stream {url}", device.name, device.ip));
    let mut link = Link::open(device)?;
    link.send(NS_CONNECTION, PLATFORM, json!({ "type": "CONNECT" }))?;
    link.send(NS_RECEIVER, PLATFORM, json!({ "type": "LAUNCH", "appId": APP_ID }))?;
    let started = Instant::now();
    let (transport, session_id) = loop {
        if quit.load(Ordering::Relaxed) {
            return Ok(());
        }
        if started.elapsed() > LAUNCH_TIMEOUT {
            return Err("the device didn't start its player".into());
        }
        let mut found = None;
        for message in link.poll()? {
            let payload: Value = serde_json::from_str(&message.payload).unwrap_or_default();
            if message.namespace == NS_HEARTBEAT && payload["type"] == "PING" {
                link.send(NS_HEARTBEAT, PLATFORM, json!({ "type": "PONG" }))?;
            }
            if message.namespace != NS_RECEIVER {
                continue;
            }
            if payload["type"] == "LAUNCH_ERROR" {
                return Err(format!("the device refused to launch the player ({})", payload["reason"].as_str().unwrap_or("unknown")));
            }
            if payload["type"] == "RECEIVER_STATUS" {
                note_volume(shared, &payload);
            }
            if let Some(app) = running_app(&payload) {
                found = Some(app);
            }
        }
        if let Some(app) = found {
            break app;
        }
    };
    log(&format!("player launched in {} ms", started.elapsed().as_millis()));
    link.send(NS_CONNECTION, &transport, json!({ "type": "CONNECT" }))?;
    let mut loads = 0u64;
    let mut load = |link: &mut Link, now: &Now, start: Option<u64>| -> Result<u64, String> {
        loads += 1;
        sink.set_art(&now.art);
        sink.start_at(start);
        sink.set_hungry(true);
        sink.set_pace(1.0);
        let mut metadata = json!({ "metadataType": 3, "title": now.title, "artist": now.artist, "albumName": now.album });
        if now.art.starts_with("http") {
            metadata["images"] = json!([{ "url": now.art }]);
        } else if !now.art.is_empty() {
            metadata["images"] = json!([{ "url": format!("{base}{COVER_PATH}{loads}.jpg") }]);
        }
        log(&format!("load #{loads} \"{}\" from page {}", now.title, start.map_or("live".into(), |page| page.to_string())));
        link.send(
            NS_MEDIA,
            &transport,
            json!({
                "type": "LOAD",
                "sessionId": session_id,
                "autoplay": now.playing,
                "media": { "contentId": url, "contentType": "audio/ogg", "streamType": "LIVE", "metadata": metadata },
            }),
        )
    };
    let _ = sink.take_flush();
    let _ = sink.take_track();
    let mut now = snapshot(host);
    load(&mut link, &now, Some(0))?;
    let mut last_load = Instant::now();
    let mut stale_session: Option<u64> = None;
    let mut media_session: Option<u64> = None;
    let mut clock: Option<Clock> = None;
    let mut pending_track: Option<(Instant, u64)> = None;
    let mut sent_playing = now.playing;
    let mut remote_paused = false;
    let mut quiet_until = Instant::now() + ECHO_GRACE;
    let mut last_ping = Instant::now();
    let mut last_status = Instant::now();
    let mut last_log = Instant::now();
    let mut target_ms = DRAIN_TARGET_MS;
    let mut fill_ms = START_FILL_MS;
    let mut filling = true;
    let mut last_state = String::new();
    let mut heard = false;
    let mut waiting_since: Option<Instant> = None;
    loop {
        if quit.load(Ordering::Relaxed) {
            let _ = link.send(NS_RECEIVER, PLATFORM, json!({ "type": "STOP", "sessionId": session_id }));
            return Ok(());
        }
        while let Ok(command) = commands.try_recv() {
            match command {
                Command::Volume(level) => {
                    link.send(NS_RECEIVER, PLATFORM, json!({ "type": "SET_VOLUME", "volume": { "level": level } }))?;
                }
            }
        }
        let fresh = snapshot(host);
        if fresh.playing != sent_playing {
            remote_paused = false;
            if let Some(session) = media_session {
                link.send(NS_MEDIA, &transport, json!({ "type": if fresh.playing { "PLAY" } else { "PAUSE" }, "mediaSessionId": session }))?;
                quiet_until = Instant::now() + ECHO_GRACE;
            }
            sent_playing = fresh.playing;
        }
        now = fresh;
        let mut reload = None;
        if let Some(mark) = sink.take_flush() {
            pending_track = None;
            reload = Some(Some(mark));
        } else if let Some(mark) = sink.take_track() {
            let wait = Duration::from_millis(sink.until_ms(mark)).saturating_sub(RELOAD_LEAD);
            log(&format!("next track reaches the speaker in {} ms", wait.as_millis()));
            pending_track = Some((Instant::now() + wait, mark));
        }
        if let Some((at, mark)) = pending_track {
            if Instant::now() >= at {
                pending_track = None;
                reload = Some(Some(mark));
            }
        }
        if let Some(start) = reload {
            load(&mut link, &now, start)?;
            filling = true;
            last_load = Instant::now();
            stale_session = media_session.take();
            clock = None;
            quiet_until = Instant::now() + ECHO_GRACE;
        }
        for message in link.poll()? {
            let payload: Value = serde_json::from_str(&message.payload).unwrap_or_default();
            let kind = payload["type"].as_str().unwrap_or_default();
            match message.namespace.as_str() {
                NS_HEARTBEAT if kind == "PING" => {
                    link.send(NS_HEARTBEAT, PLATFORM, json!({ "type": "PONG" }))?;
                }
                NS_CONNECTION if kind == "CLOSE" => return Err("the device closed the connection".into()),
                NS_RECEIVER if kind == "RECEIVER_STATUS" => {
                    if running_app(&payload).is_none_or(|(id, _)| id != transport) {
                        return Err("the device stopped the player".into());
                    }
                    note_volume(shared, &payload);
                }
                NS_MEDIA if kind == "MEDIA_STATUS" => {
                    let Some(status) = payload["status"].as_array().and_then(|list| list.first()) else {
                        continue;
                    };
                    let session = status["mediaSessionId"].as_u64();
                    if session.is_some() && session == stale_session {
                        continue;
                    }
                    if session.is_some() {
                        media_session = session;
                    }
                    let echo = Instant::now() < quiet_until;
                    let state = status["playerState"].as_str().unwrap_or_default();
                    let running = state == "PLAYING";
                    if let Some(seconds) = status["currentTime"].as_f64() {
                        let since = clock.as_ref().filter(|old| old.running == running).map_or_else(Instant::now, |old| old.since);
                        clock = Some(Clock { media_ms: seconds * 1000.0, at: Instant::now(), running, since });
                    } else if let Some(old) = clock.as_mut() {
                        if old.running != running {
                            old.media_ms = old.heard_ms() as f64;
                            old.at = Instant::now();
                            old.running = running;
                            old.since = Instant::now();
                        }
                    }
                    if let Some(clock) = clock.as_ref().filter(|_| !sink.flush_pending()) {
                        sink.hear(clock.media_ms + if clock.running { clock.at.elapsed().as_secs_f64() * 1000.0 } else { 0.0 }, clock.running);
                    }
                    match state {
                        "PLAYING" | "BUFFERING" => {
                            heard = true;
                            if shared.state().phase != Phase::Casting {
                                shared.set(|state| state.phase = Phase::Casting);
                            }
                            if state == "PLAYING" {
                                if sink.hungry() && !filling {
                                    log(&format!("playing with {} ms buffered", sink.sent_ms().saturating_sub(clock.as_ref().map_or(0, Clock::heard_ms))));
                                    sink.set_hungry(false);
                                }
                            } else if now.playing {
                                if !sink.hungry() && !echo {
                                    if last_load.elapsed() > SETTLE {
                                        target_ms = (target_ms + DRAIN_STEP_MS).min(DRAIN_LIMIT_MS);
                                        sink.set_pace(1.0);
                                        log(&format!("the speaker ran dry, keeping {target_ms} ms buffered from now on"));
                                    } else {
                                        fill_ms = (fill_ms + FILL_STEP_MS).min(FILL_LIMIT_MS);
                                        filling = true;
                                        log(&format!("the speaker wanted more before starting, filling {fill_ms} ms from now on"));
                                    }
                                }
                                sink.set_hungry(true);
                            }
                            last_state = state.to_owned();
                            if remote_paused && !now.playing {
                                log("resumed from the speaker");
                                host.set_playing(true);
                                sent_playing = true;
                                remote_paused = false;
                                sink.set_hungry(true);
                            }
                        }
                        "PAUSED" => {
                            last_state = state.to_owned();
                            sink.set_hungry(false);
                            if now.playing && !echo {
                                log("paused from the speaker");
                                host.set_playing(false);
                                sent_playing = false;
                                remote_paused = true;
                            }
                        }
                        "IDLE" if last_load.elapsed() > RELOAD_INTERVAL => {
                            log(&format!("the speaker went idle ({}), reloading", status["idleReason"].as_str().unwrap_or("no reason")));
                            load(&mut link, &now, None)?;
                            filling = true;
                            last_load = Instant::now();
                            stale_session = media_session.take();
                            clock = None;
                            quiet_until = Instant::now() + ECHO_GRACE;
                        }
                        _ => {}
                    }
                }
                NS_MEDIA if kind == "LOAD_FAILED" => return Err("the device rejected the audio stream".into()),
                _ => {}
            }
        }
        if filling && sink.sent_ms() >= fill_ms {
            filling = false;
            if last_state == "PLAYING" && sink.hungry() {
                log(&format!("filled {} ms, the speaker is playing", sink.sent_ms()));
                sink.set_hungry(false);
            }
        }
        let delay = sink.sent_ms().saturating_sub(clock.as_ref().map_or(0, Clock::heard_ms));
        let settled = clock.as_ref().is_some_and(|clock| clock.running && clock.since.elapsed() > SETTLE);
        if settled && !sink.hungry() {
            let pace = if delay > target_ms + DRAIN_MARGIN_MS { DRAIN_PACE } else if delay <= target_ms { 1.0 } else { sink.pace() };
            if pace != sink.pace() {
                log(&format!("{} at {delay} ms buffered", if pace < 1.0 { "draining" } else { "holding" }));
                sink.set_pace(pace);
            }
        }
        if last_log.elapsed() > LOG_INTERVAL && now.playing {
            log(&format!("buffer {delay} ms, target {target_ms} ms, pace {}, {}", sink.pace(), if sink.hungry() { "filling" } else { "steady" }));
            last_log = Instant::now();
        }
        if let Some(session) = media_session.filter(|_| last_status.elapsed() > STATUS_INTERVAL) {
            link.send(NS_MEDIA, &transport, json!({ "type": "GET_STATUS", "mediaSessionId": session }))?;
            last_status = Instant::now();
        }
        if !heard {
            match (now.playing, waiting_since) {
                (false, _) => waiting_since = None,
                (true, None) => waiting_since = Some(Instant::now()),
                (true, Some(since)) if since.elapsed() > PLAYING_TIMEOUT => {
                    return Err("the device never started playing; a firewall may be blocking Nari".into());
                }
                _ => {}
            }
        }
        if last_ping.elapsed() > PING_INTERVAL {
            link.send(NS_HEARTBEAT, PLATFORM, json!({ "type": "PING" }))?;
            last_ping = Instant::now();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use rustls::pki_types::{PrivateKeyDer, PrivatePkcs8KeyDer};
    use rustls::{ServerConfig, ServerConnection};

    fn silence() -> Vec<f32> {
        vec![0.0; FRAME * CHANNELS]
    }

    #[test]
    fn slow_readers_skip_to_the_window_start() {
        let sink = Broadcast::new().unwrap();
        let (mut fast, mut slow) = (sink.head(), sink.head());
        let mut out = Vec::new();
        sink.push_pcm(&silence());
        sink.read(&mut fast, &mut out);
        assert_eq!((out.len(), fast), (1, 1));
        assert!(out[0].starts_with(b"OggS"));
        for _ in 0..WINDOW_PAGES + 5 {
            sink.push_pcm(&silence());
        }
        sink.read(&mut slow, &mut out);
        assert_eq!(out.len(), WINDOW_PAGES, "the slow reader only gets what is still in the window");
        sink.read(&mut fast, &mut out);
        assert_eq!(fast, slow);
        sink.read(&mut fast, &mut out);
        assert!(out.is_empty(), "no data arrives after waiting");
    }

    #[test]
    fn the_delay_follows_pushed_audio_and_the_speaker_clock() {
        let sink = Broadcast::new().unwrap();
        for _ in 0..10 {
            sink.push_pcm(&silence());
        }
        assert_eq!(sink.delay_ms(), 0, "without a speaker to follow there is no delay");
        sink.followed.store(true, Ordering::Relaxed);
        sink.start_at(Some(4));
        for _ in 0..50 {
            sink.push_pcm(&silence());
        }
        assert_eq!(sink.delay_ms(), 56 * 20, "nothing heard yet, so everything since the start is ahead of the speaker");
        sink.hear(300.0, false);
        assert_eq!(sink.delay_ms(), 56 * 20 - 300);
        sink.hear(400.0, true);
        sink.hear(1000.0, true);
        let smoothed = sink.heard_ms();
        assert!(smoothed > 400.0 && smoothed < 700.0, "small corrections ease in: {smoothed}");
        sink.hear(5000.0, true);
        assert!(sink.heard_ms() >= 5000.0, "big jumps snap");
        sink.mark_flush();
        assert_eq!(sink.delay_ms(), 0, "a flush restarts the clock at the newest page");
    }

    #[test]
    fn devices_get_an_icon_from_their_capabilities() {
        assert_eq!(kind_of("MiTV-AYFR0", 266_757), "tv");
        assert_eq!(kind_of("Chromecast", 5), "tv");
        assert_eq!(kind_of("Google Nest Hub", 5), "display");
        assert_eq!(kind_of("Google Home Mini", 2052), "speaker");
        assert_eq!(kind_of("Google Cast Group", 2084), "group");
    }

    #[test]
    fn ogg_pages_carry_a_valid_crc_and_lacing() {
        let packet = vec![7u8; 600];
        let mut page = ogg_page(0, 1920, &packet);
        seal(&mut page, 5);
        assert_eq!(&page[0..5], b"OggS\0");
        assert_eq!(u64::from_le_bytes(page[6..14].try_into().unwrap()), 1920);
        assert_eq!(u32::from_le_bytes(page[18..22].try_into().unwrap()), 5);
        assert_eq!((page[26], page[27], page[28], page[29]), (3, 255, 255, 90));
        assert_eq!(page.len(), 27 + 3 + 600);
        let stored = u32::from_le_bytes(page[22..26].try_into().unwrap());
        let mut check = page.clone();
        check[22..26].fill(0);
        assert_eq!(ogg_crc(&check), stored);
        assert_eq!(ogg_crc(b"123456789"), 0x89a1_897f, "known Ogg CRC vector");
        let headers = opus_headers();
        assert_eq!(&headers[0][28..36], b"OpusHead");
        assert_eq!(headers[0][5], 0x02, "the id header is the beginning of stream");
        assert_eq!(&headers[1][28..36], b"OpusTags");
    }

    fn pull(stream: &mut TcpStream, wanted: usize) -> Vec<u8> {
        let mut got = Vec::new();
        let mut buffer = [0; 4096];
        let started = Instant::now();
        while got.len() < wanted && started.elapsed() < Duration::from_secs(5) {
            match stream.read(&mut buffer) {
                Ok(0) | Err(_) => break,
                Ok(n) => got.extend_from_slice(&buffer[..n]),
            }
        }
        got
    }

    fn fetch(url: &str, wanted: usize) -> Vec<u8> {
        let (host, path) = url.trim_start_matches("http://").split_once('/').unwrap();
        let mut stream = TcpStream::connect(host).unwrap();
        stream.write_all(format!("GET /{path} HTTP/1.1\r\nHost: {host}\r\n\r\n").as_bytes()).unwrap();
        stream.set_read_timeout(Some(Duration::from_secs(2))).unwrap();
        pull(&mut stream, wanted)
    }

    fn body_of(response: &[u8]) -> &[u8] {
        let at = response.windows(4).position(|w| w == b"\r\n\r\n").unwrap() + 4;
        &response[at..]
    }

    #[test]
    fn serves_an_endless_ogg_stream() {
        let sink = Arc::new(Broadcast::new().unwrap());
        let server = serve(sink.clone()).unwrap();
        for _ in 0..10 {
            sink.push_pcm(&silence());
        }
        sink.mark_flush();
        let mark = sink.take_flush().unwrap();
        assert_eq!(mark, 10);
        sink.start_at(Some(mark - 4));
        let producer = {
            let sink = sink.clone();
            std::thread::spawn(move || {
                for _ in 0..60 {
                    sink.push_pcm(&silence());
                    std::thread::sleep(Duration::from_millis(10));
                }
            })
        };
        assert!(fetch(&format!("http://127.0.0.1:{}{STREAM_PATH}", server.port), 3000).starts_with(b"HTTP/1.1 404"));
        let got = fetch(&format!("{}{STREAM_PATH}", server.base("127.0.0.1")), 3000);
        producer.join().unwrap();
        let text = String::from_utf8_lossy(&got[..120]).into_owned();
        assert!(text.starts_with("HTTP/1.1 200 OK\r\n") && text.contains("Content-Type: audio/ogg"), "{text}");
        let body = body_of(&got);
        assert!(body.starts_with(b"OggS"));
        let mut sequences = Vec::new();
        let mut granules = Vec::new();
        let mut at = 0;
        while at + 27 <= body.len() && &body[at..at + 4] == b"OggS" {
            let segments = body[at + 26] as usize;
            let length: usize = body[at + 27..at + 27 + segments].iter().map(|b| *b as usize).sum();
            let end = at + 27 + segments + length;
            if end > body.len() {
                break;
            }
            let mut page = body[at..end].to_vec();
            let stored = u32::from_le_bytes(page[22..26].try_into().unwrap());
            page[22..26].fill(0);
            assert_eq!(ogg_crc(&page), stored, "page crc");
            sequences.push(u32::from_le_bytes(page[18..22].try_into().unwrap()));
            granules.push(granule(&page));
            at = end;
        }
        assert!(sequences.len() >= 5, "got {} pages", sequences.len());
        assert_eq!(sequences[..3], [0, 1, 2]);
        assert!(sequences.windows(2).all(|pair| pair[1] == pair[0] + 1), "{sequences:?}");
        assert_eq!(granules[2..5], [960, 1920, 2880], "the client starts at the mark and its clock starts at zero");
        assert_eq!(sink.sent_ms(), *granules.last().unwrap() * 1000 / 48000);
        sink.start_at(None);
        assert_eq!(sink.open_client().0, sink.head(), "without a mark clients join live");
        sink.start_at(Some(0));
        assert_eq!(sink.open_client().0, sink.head() - 70, "old marks clamp to what the window still has");
        drop(server);
    }

    #[test]
    fn cast_frames_round_trip_and_match_the_wire_format() {
        let frame = encode("urn:x-cast:test", "receiver-0", r#"{"type":"PING"}"#);
        let mut expected = vec![0x08, 0x00, 0x12, 8];
        expected.extend_from_slice(b"sender-0");
        expected.extend_from_slice(&[0x1a, 10]);
        expected.extend_from_slice(b"receiver-0");
        expected.extend_from_slice(&[0x22, 15]);
        expected.extend_from_slice(b"urn:x-cast:test");
        expected.extend_from_slice(&[0x28, 0x00, 0x32, 15]);
        expected.extend_from_slice(br#"{"type":"PING"}"#);
        let mut wire = (expected.len() as u32).to_be_bytes().to_vec();
        wire.extend(&expected);
        assert_eq!(frame, wire);
        let message = decode(&frame[4..]).unwrap();
        assert_eq!(
            message,
            Message { source: "sender-0".into(), destination: "receiver-0".into(), namespace: "urn:x-cast:test".into(), payload: r#"{"type":"PING"}"#.into() }
        );
        let mut long = Vec::new();
        put_varint(&mut long, 300);
        assert_eq!(long, [0xac, 0x02]);
        assert!(decode(&[0x12, 0x05, b'a']).is_none(), "truncated strings are rejected");
    }

    struct TestHost {
        routed: Mutex<Vec<bool>>,
        sink: Mutex<Option<Arc<Broadcast>>>,
        playing: AtomicBool,
        id: Mutex<String>,
        art: String,
    }

    impl TestHost {
        fn sink(&self) -> Arc<Broadcast> {
            self.sink.lock().unwrap().clone().unwrap()
        }
    }

    impl Host for TestHost {
        fn route(&self, sink: Option<Arc<Broadcast>>) {
            self.routed.lock().unwrap().push(sink.is_some());
            if sink.is_some() {
                *self.sink.lock().unwrap() = sink;
            }
        }

        fn set_playing(&self, playing: bool) {
            self.playing.store(playing, Ordering::Relaxed);
        }

        fn media(&self) -> crate::mpris::Media {
            let id = self.id.lock().unwrap().clone();
            crate::mpris::Media {
                title: format!("Song {id}"),
                id,
                artists: vec!["Probe".into()],
                album: "Album".into(),
                art: self.art.clone(),
                playing: self.playing.load(Ordering::Relaxed),
                has_song: true,
                ..Default::default()
            }
        }
    }

    struct FakeReceiver {
        port: u16,
        seen: Arc<Mutex<Vec<String>>>,
        fetched: Arc<Mutex<Vec<(String, Vec<u8>)>>>,
    }

    fn fake_receiver() -> FakeReceiver {
        let cert = CertificateDer::from(include_bytes!("../fixtures/cast_receiver.crt.der").to_vec());
        let key = PrivateKeyDer::Pkcs8(PrivatePkcs8KeyDer::from(include_bytes!("../fixtures/cast_receiver.key.der").to_vec()));
        let config = Arc::new(
            ServerConfig::builder_with_provider(Arc::new(rustls::crypto::ring::default_provider()))
                .with_safe_default_protocol_versions()
                .unwrap()
                .with_no_client_auth()
                .with_single_cert(vec![cert], key)
                .unwrap(),
        );
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        let seen = Arc::new(Mutex::new(Vec::new()));
        let fetched = Arc::new(Mutex::new(Vec::new()));
        let (seen_by, fetched_by) = (seen.clone(), fetched.clone());
        std::thread::spawn(move || {
            let (tcp, _) = listener.accept().unwrap();
            let mut tls = StreamOwned::new(ServerConnection::new(config).unwrap(), tcp);
            let mut inbox = Vec::new();
            let mut buffer = [0u8; 8192];
            let mut level = 0.4;
            let reply = |tls: &mut StreamOwned<ServerConnection, TcpStream>, namespace: &str, payload: Value| {
                let mut body = vec![0x08, 0x00];
                put_text(&mut body, 2, "receiver-0");
                put_text(&mut body, 3, SENDER);
                put_text(&mut body, 4, namespace);
                body.extend_from_slice(&[0x28, 0x00]);
                put_text(&mut body, 6, &payload.to_string());
                let mut frame = (body.len() as u32).to_be_bytes().to_vec();
                frame.extend(body);
                tls.write_all(&frame).unwrap();
            };
            let status = |level: f64, running: bool| {
                let apps = if running { json!([{ "appId": APP_ID, "sessionId": "s1", "transportId": "t1" }]) } else { json!([]) };
                json!({ "type": "RECEIVER_STATUS", "requestId": 0, "status": { "applications": apps, "volume": { "level": level, "muted": false } } })
            };
            let mut session = 0;
            let media = |session: u64, state: &str| json!({ "type": "MEDIA_STATUS", "requestId": 0, "status": [{ "mediaSessionId": session, "playerState": state, "currentTime": 0.0 }] });
            loop {
                let read = match tls.read(&mut buffer) {
                    Ok(0) | Err(_) => return,
                    Ok(read) => read,
                };
                inbox.extend_from_slice(&buffer[..read]);
                while inbox.len() >= 4 {
                    let length = u32::from_be_bytes([inbox[0], inbox[1], inbox[2], inbox[3]]) as usize;
                    if inbox.len() < 4 + length {
                        break;
                    }
                    let frame: Vec<u8> = inbox.drain(..4 + length).skip(4).collect();
                    let message = decode(&frame).unwrap();
                    let payload: Value = serde_json::from_str(&message.payload).unwrap();
                    let kind = payload["type"].as_str().unwrap().to_owned();
                    seen_by.lock().unwrap().push(format!("{}:{kind}", message.destination));
                    match kind.as_str() {
                        "LAUNCH" => reply(&mut tls, NS_RECEIVER, status(level, true)),
                        "PING" => reply(&mut tls, NS_HEARTBEAT, json!({ "type": "PONG" })),
                        "SET_VOLUME" => {
                            level = payload["volume"]["level"].as_f64().unwrap();
                            reply(&mut tls, NS_RECEIVER, status(level, true));
                            if (level - 0.11).abs() < 0.001 {
                                reply(&mut tls, NS_MEDIA, media(session, "PAUSED"));
                            }
                            if (level - 0.12).abs() < 0.001 {
                                reply(&mut tls, NS_MEDIA, media(session, "BUFFERING"));
                            }
                        }
                        "LOAD" => {
                            let url = payload["media"]["contentId"].as_str().unwrap().to_owned();
                            let title = payload["media"]["metadata"]["title"].as_str().unwrap_or_default().to_owned();
                            let image = payload["media"]["metadata"]["images"][0]["url"].as_str().unwrap_or_default().to_owned();
                            let stream = fetch(&url, 4000);
                            let cover = if image.is_empty() { Vec::new() } else { fetch(&image, 100_000) };
                            fetched_by.lock().unwrap().push((title, [stream, b"||".to_vec(), cover].concat()));
                            session += 1;
                            reply(&mut tls, NS_MEDIA, media(session, if payload["autoplay"].as_bool().unwrap_or(true) { "PLAYING" } else { "PAUSED" }));
                        }
                        "PAUSE" => reply(&mut tls, NS_MEDIA, media(session, "PAUSED")),
                        "PLAY" => reply(&mut tls, NS_MEDIA, media(session, "PLAYING")),
                        "GET_STATUS" => reply(&mut tls, NS_MEDIA, media(session, "PLAYING")),
                        "STOP" => {
                            reply(&mut tls, NS_RECEIVER, status(level, false));
                            return;
                        }
                        _ => {}
                    }
                }
            }
        });
        FakeReceiver { port, seen, fetched }
    }

    fn wait_until(what: &str, mut ready: impl FnMut() -> bool) {
        let started = Instant::now();
        while !ready() {
            assert!(started.elapsed() < Duration::from_secs(10), "timed out waiting for {what}");
            std::thread::sleep(Duration::from_millis(20));
        }
    }

    #[test]
    fn casts_to_a_fake_receiver() {
        let receiver = fake_receiver();
        let (events, inbox) = channel();
        let art = std::env::temp_dir().join("nari_cast_test_cover.jpg");
        std::fs::write(&art, b"JPEGDATA").unwrap();
        let host = Arc::new(TestHost {
            routed: Mutex::new(Vec::new()),
            sink: Mutex::new(None),
            playing: AtomicBool::new(true),
            id: Mutex::new("one".into()),
            art: art.to_string_lossy().into_owned(),
        });
        let mut cast = Cast::with_host(host.clone(), events);
        cast.shared.state().devices.push(Device {
            id: "abc".into(),
            name: "Fake speaker".into(),
            model: "Test".into(),
            kind: "speaker",
            ip: Ipv4Addr::LOCALHOST,
            port: receiver.port,
            fullname: "fake._googlecast._tcp.local.".into(),
        });
        assert!(!cast.connect("missing"), "unknown ids fail");
        assert!(cast.connect("abc"));
        let phase = |cast: &Cast| cast.shared.state().phase;
        wait_until("casting", || phase(&cast) == Phase::Casting);
        let sink = host.sink();
        assert!(sink.hungry(), "a fresh load bursts until the speaker holds enough");
        wait_until("the speaker volume", || cast.shared.state().volume > 0.39);
        cast.set_volume(0.8);
        wait_until("the new volume", || (cast.shared.state().volume - 0.8).abs() < 0.001);
        let seen_count = |what: &str| receiver.seen.lock().unwrap().iter().filter(|seen| seen.as_str() == what).count();
        {
            let fetched = receiver.fetched.lock().unwrap();
            let (title, bytes) = &fetched[0];
            assert_eq!(title, "Song one");
            let text = String::from_utf8_lossy(bytes).into_owned();
            assert!(text.starts_with("HTTP/1.1 200 OK") && text.contains("audio/ogg"), "{text}");
            assert!(body_of(bytes).starts_with(b"OggS"));
            assert!(text.ends_with("JPEGDATA"), "the cover is served: {}", &text[text.len() - 80..]);
        }
        host.set_playing(false);
        wait_until("the pause", || seen_count("t1:PAUSE") == 1);
        host.set_playing(true);
        wait_until("the play", || seen_count("t1:PLAY") == 1);
        std::thread::sleep(ECHO_GRACE);
        cast.set_volume(0.11);
        wait_until("the receiver pausing the app", || !host.playing.load(Ordering::Relaxed));
        cast.set_volume(0.12);
        wait_until("the receiver resuming the app while it buffers", || host.playing.load(Ordering::Relaxed));
        assert!(sink.hungry(), "a buffering speaker gets a burst");
        *host.id.lock().unwrap() = "two".into();
        sink.mark_flush();
        wait_until("the reload after a skip", || seen_count("t1:LOAD") == 2);
        wait_until("the new title", || receiver.fetched.lock().unwrap().len() == 2);
        assert_eq!(receiver.fetched.lock().unwrap()[1].0, "Song two");
        sink.mark_flush();
        wait_until("the reload after a seek in the same song", || seen_count("t1:LOAD") == 3);
        *host.id.lock().unwrap() = "three".into();
        sink.mark_track();
        wait_until("the reload when the speaker reaches the next song", || seen_count("t1:LOAD") == 4);
        wait_until("the third title", || receiver.fetched.lock().unwrap().len() == 4);
        assert_eq!(receiver.fetched.lock().unwrap()[3].0, "Song three");
        cast.disconnect();
        wait_until("the stop", || receiver.seen.lock().unwrap().last().is_some_and(|last| last == "receiver-0:STOP"));
        let seen = receiver.seen.lock().unwrap().clone();
        assert_eq!(&seen[..4], ["receiver-0:CONNECT", "receiver-0:LAUNCH", "t1:CONNECT", "t1:LOAD"]);
        assert!(seen.contains(&"receiver-0:SET_VOLUME".to_owned()));
        assert_eq!(phase(&cast), Phase::Idle);
        assert_eq!(*host.routed.lock().unwrap(), [true, false], "audio went to the cast sink and came back");
        let states: Vec<String> = inbox.try_iter().filter_map(|event| match event {
            Event::CastState(state) => Some(serde_json::from_str::<Value>(&state).unwrap()["phase"].as_str().unwrap().to_owned()),
            _ => None,
        }).collect();
        assert_eq!(states.first().map(String::as_str), Some("error"));
        assert!(states.contains(&"connecting".to_owned()) && states.contains(&"casting".to_owned()));
        assert_eq!(states.last().map(String::as_str), Some("idle"));
        let _ = std::fs::remove_file(art);
    }
}
