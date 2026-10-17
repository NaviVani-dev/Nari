use std::sync::mpsc::Sender;

use crate::events::Event;

pub const SHOW: &str = "show";
pub const TOGGLE: &str = "toggle";
pub const NEXT: &str = "next";
pub const PREVIOUS: &str = "previous";
pub const QUIT: &str = "quit";

const FAVICON: &[u8] = include_bytes!("../../../../icon.png");
const ICON_SIZES: [u32; 6] = [16, 22, 24, 32, 48, 64];
const TITLE_CHARS: usize = 40;

fn short(title: &str) -> String {
    if title.chars().count() <= TITLE_CHARS {
        return title.to_owned();
    }
    let cut: String = title.chars().take(TITLE_CHARS - 1).collect();
    format!("{}…", cut.trim_end())
}

#[cfg(target_os = "linux")]
const FALLBACK_ICON_NAME: &str = "multimedia-player";

#[cfg(any(target_os = "linux", windows, target_os = "macos"))]
mod favicon {
    use super::{FAVICON, ICON_SIZES};
    use image::{imageops::FilterType, DynamicImage, ImageFormat, RgbaImage};
    use std::sync::OnceLock;

    #[cfg(target_os = "linux")]
    pub fn all() -> impl Iterator<Item = &'static RgbaImage> {
        cache().iter()
    }

    #[cfg(any(windows, target_os = "macos"))]
    pub fn pick(size: u32) -> Option<&'static RgbaImage> {
        cache().iter().find(|image| image.width() == size)
    }

    fn cache() -> &'static Vec<RgbaImage> {
        static CACHE: OnceLock<Vec<RgbaImage>> = OnceLock::new();
        CACHE.get_or_init(|| {
            let Ok(icon) = image::load_from_memory_with_format(FAVICON, ImageFormat::Png) else {
                return Vec::new();
            };
            let Some(icon) = trim(&icon) else {
                return Vec::new();
            };
            ICON_SIZES
                .iter()
                .map(|size| {
                    icon.resize_exact(*size, *size, FilterType::Lanczos3)
                        .into_rgba8()
                })
                .collect()
        })
    }

    fn trim(icon: &DynamicImage) -> Option<DynamicImage> {
        let pixels = icon.to_rgba8();
        let mut bounds: Option<(u32, u32, u32, u32)> = None;
        for (x, y, pixel) in pixels.enumerate_pixels() {
            if pixel.0[3] == 0 {
                continue;
            }
            bounds = Some(match bounds {
                None => (x, y, x + 1, y + 1),
                Some((left, top, right, bottom)) => {
                    (left.min(x), top.min(y), right.max(x + 1), bottom.max(y + 1))
                }
            });
        }
        let (left, top, right, bottom) = bounds?;
        Some(
            DynamicImage::ImageRgba8(pixels).crop_imm(left, top, right - left, bottom - top),
        )
    }
}

#[cfg(target_os = "linux")]
mod platform {
    use super::*;
    use ksni::blocking::{Handle, TrayMethods};
    use ksni::menu::StandardItem;
    use ksni::{Category, Icon, MenuItem, Status, ToolTip};
    use std::path::Path;
    use std::sync::OnceLock;

    fn pixmaps() -> &'static Vec<Icon> {
        static PIXMAPS: OnceLock<Vec<Icon>> = OnceLock::new();
        PIXMAPS.get_or_init(|| {
            favicon::all()
                .map(|image| {
                    let mut data = image.as_raw().clone();
                    for pixel in data.chunks_exact_mut(4) {
                        pixel.rotate_right(1);
                    }
                    Icon {
                        width: image.width() as i32,
                        height: image.height() as i32,
                        data,
                    }
                })
                .collect()
        })
    }

    struct Item {
        events: Sender<Event>,
        title: String,
        playing: bool,
        cover: Vec<u8>,
    }

    fn cover_png(path: &str) -> Vec<u8> {
        let mut png = Vec::new();
        if let Ok(image) = image::open(path) {
            let _ = image
                .thumbnail(64, 64)
                .write_to(&mut std::io::Cursor::new(&mut png), image::ImageFormat::Png);
        }
        png
    }

    impl Item {
        fn send(&self, command: &str) {
            let _ = self.events.send(Event::TrayCommand(command.to_owned()));
        }
    }

    impl ksni::Tray for Item {
        fn id(&self) -> String {
            "nari".into()
        }

        fn category(&self) -> Category {
            Category::ApplicationStatus
        }

        fn title(&self) -> String {
            "Nari".into()
        }

        fn status(&self) -> Status {
            Status::Active
        }

        fn icon_name(&self) -> String {
            if pixmaps().is_empty() {
                FALLBACK_ICON_NAME.into()
            } else {
                String::new()
            }
        }

        fn icon_pixmap(&self) -> Vec<Icon> {
            pixmaps().clone()
        }

        fn tool_tip(&self) -> ToolTip {
            ToolTip {
                title: "Nari".into(),
                description: self.title.clone(),
                ..ToolTip::default()
            }
        }

        fn activate(&mut self, _x: i32, _y: i32) {
            self.send(SHOW);
        }

        fn secondary_activate(&mut self, _x: i32, _y: i32) {
            self.send(SHOW);
        }

        fn menu(&self) -> Vec<MenuItem<Self>> {
            let mut items = Vec::new();
            if !self.title.is_empty() {
                items.push(
                    StandardItem {
                        label: short(&self.title).replace('_', "__"),
                        icon_data: self.cover.clone(),
                        activate: Box::new(|this: &mut Self| this.send(SHOW)),
                        ..StandardItem::default()
                    }
                    .into(),
                );
                items.push(MenuItem::Separator);
            }
            items.push(
                StandardItem {
                    label: if self.playing { "Pause" } else { "Play" }.into(),
                    activate: Box::new(|this: &mut Self| this.send(TOGGLE)),
                    ..StandardItem::default()
                }
                .into(),
            );
            items.push(
                StandardItem {
                    label: "Previous".into(),
                    activate: Box::new(|this: &mut Self| this.send(PREVIOUS)),
                    ..StandardItem::default()
                }
                .into(),
            );
            items.push(
                StandardItem {
                    label: "Next".into(),
                    activate: Box::new(|this: &mut Self| this.send(NEXT)),
                    ..StandardItem::default()
                }
                .into(),
            );
            items.push(MenuItem::Separator);
            items.push(
                StandardItem {
                    label: "Show Nari".into(),
                    activate: Box::new(|this: &mut Self| this.send(SHOW)),
                    ..StandardItem::default()
                }
                .into(),
            );
            items.push(
                StandardItem {
                    label: "Quit".into(),
                    activate: Box::new(|this: &mut Self| this.send(QUIT)),
                    ..StandardItem::default()
                }
                .into(),
            );
            items
        }

        fn watcher_offline(&self, reason: ksni::OfflineReason) -> bool {
            godot::global::godot_error!("MusicService tray host offline: {reason:?}");
            true
        }
    }

    pub struct Tray {
        handle: Handle<Item>,
    }

    impl Tray {
        pub fn new(events: Sender<Event>) -> Option<Self> {
            let item = Item {
                events,
                title: String::new(),
                playing: false,
                cover: Vec::new(),
            };
            match item
                .disable_dbus_name(Path::new("/.flatpak-info").exists())
                .assume_sni_available(true)
                .spawn()
            {
                Ok(handle) => Some(Self { handle }),
                Err(error) => {
                    godot::global::godot_error!("MusicService tray unavailable: {error}");
                    None
                }
            }
        }

        pub fn set_state(&self, title: String, playing: bool, cover: String) {
            let cover = cover_png(&cover);
            let _ = self.handle.update(move |item: &mut Item| {
                item.title = title;
                item.playing = playing;
                item.cover = cover;
            });
        }

        pub fn shutdown(&self) {
            self.handle.shutdown().wait();
        }
    }
}

#[cfg(windows)]
mod platform {
    use super::*;
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::sync::{Arc, Mutex};
    use std::thread::JoinHandle;
    use tray_icon::menu::{Menu, MenuEvent, MenuItem as WinMenuItem, PredefinedMenuItem};
    use tray_icon::{Icon, TrayIconBuilder, TrayIconEvent};
    use windows_sys::Win32::UI::WindowsAndMessaging::{
        DispatchMessageW, PeekMessageW, TranslateMessage, MSG, PM_REMOVE,
    };

    struct State {
        title: String,
        playing: bool,
    }

    pub struct Tray {
        state: Arc<Mutex<State>>,
        quit: Arc<AtomicBool>,
        worker: Option<JoinHandle<()>>,
    }

    impl Tray {
        pub fn new(events: Sender<Event>) -> Option<Self> {
            let state = Arc::new(Mutex::new(State {
                title: String::new(),
                playing: false,
            }));
            let quit = Arc::new(AtomicBool::new(false));
            let worker = {
                let state = state.clone();
                let quit = quit.clone();
                std::thread::spawn(move || run(events, state, quit))
            };
            Some(Self {
                state,
                quit,
                worker: Some(worker),
            })
        }

        pub fn set_state(&self, title: String, playing: bool, _cover: String) {
            if let Ok(mut state) = self.state.lock() {
                state.title = title;
                state.playing = playing;
            }
        }

        pub fn shutdown(&self) {
            self.quit.store(true, Ordering::SeqCst);
        }
    }

    impl Drop for Tray {
        fn drop(&mut self) {
            self.quit.store(true, Ordering::SeqCst);
            if let Some(worker) = self.worker.take() {
                let _ = worker.join();
            }
        }
    }

    fn icon() -> Option<Icon> {
        let image = favicon::pick(32)?;
        Icon::from_rgba(image.as_raw().clone(), image.width(), image.height()).ok()
    }

    fn run(events: Sender<Event>, state: Arc<Mutex<State>>, quit: Arc<AtomicBool>) {
        let toggle = WinMenuItem::new("Play", true, None);
        let previous = WinMenuItem::new("Previous", true, None);
        let next = WinMenuItem::new("Next", true, None);
        let show = WinMenuItem::new("Show Nari", true, None);
        let exit = WinMenuItem::new("Quit", true, None);
        let menu = Menu::new();
        let _ = menu.append_items(&[
            &toggle,
            &previous,
            &next,
            &PredefinedMenuItem::separator(),
            &show,
            &exit,
        ]);
        let mut builder = TrayIconBuilder::new().with_menu(Box::new(menu));
        builder = match icon() {
            Some(icon) => builder.with_icon(icon),
            None => builder,
        };
        let tray = match builder.with_tooltip("Nari").build() {
            Ok(tray) => tray,
            Err(error) => {
                godot::global::godot_error!("MusicService tray unavailable: {error}");
                return;
            }
        };
        let mut shown = String::new();
        let mut was_playing = false;
        while !quit.load(Ordering::SeqCst) {
            let mut message: MSG = unsafe { std::mem::zeroed() };
            while unsafe { PeekMessageW(&mut message, std::ptr::null_mut(), 0, 0, PM_REMOVE) } != 0 {
                unsafe {
                    TranslateMessage(&message);
                    DispatchMessageW(&message);
                }
            }
            while let Ok(event) = MenuEvent::receiver().try_recv() {
                let command = match event.id() {
                    id if *id == toggle.id() => TOGGLE,
                    id if *id == previous.id() => PREVIOUS,
                    id if *id == next.id() => NEXT,
                    id if *id == show.id() => SHOW,
                    id if *id == exit.id() => QUIT,
                    _ => continue,
                };
                let _ = events.send(Event::TrayCommand(command.to_owned()));
            }
            while let Ok(event) = TrayIconEvent::receiver().try_recv() {
                if matches!(
                    event,
                    TrayIconEvent::Click {
                        button: tray_icon::MouseButton::Left,
                        button_state: tray_icon::MouseButtonState::Up,
                        ..
                    }
                ) {
                    let _ = events.send(Event::TrayCommand(SHOW.to_owned()));
                }
            }
            if let Ok(state) = state.lock() {
                if state.title != shown || state.playing != was_playing {
                    shown = state.title.clone();
                    was_playing = state.playing;
                    toggle.set_text(if was_playing { "Pause" } else { "Play" });
                    let _ = tray.set_tooltip(Some(if shown.is_empty() {
                        "Nari".to_owned()
                    } else {
                        format!("Nari — {}", short(&shown))
                    }));
                }
            }
            std::thread::sleep(std::time::Duration::from_millis(50));
        }
    }
}

#[cfg(target_os = "macos")]
mod platform {
    use super::*;
    use std::cell::RefCell;
    use tray_icon::menu::{Menu, MenuEvent, MenuId, MenuItem as MacMenuItem, PredefinedMenuItem};
    use tray_icon::{Icon, TrayIcon, TrayIconBuilder};

    pub struct Tray {
        icon: RefCell<Option<TrayIcon>>,
        toggle: MacMenuItem,
    }

    impl Tray {
        pub fn new(events: Sender<Event>) -> Option<Self> {
            let toggle = MacMenuItem::new("Play", true, None);
            let previous = MacMenuItem::new("Previous", true, None);
            let next = MacMenuItem::new("Next", true, None);
            let show = MacMenuItem::new("Show Nari", true, None);
            let exit = MacMenuItem::new("Quit", true, None);
            let menu = Menu::new();
            menu.append_items(&[&toggle, &previous, &next, &PredefinedMenuItem::separator(), &show, &exit]).ok()?;
            let commands: Vec<(MenuId, &'static str)> = vec![
                (toggle.id().clone(), TOGGLE),
                (previous.id().clone(), PREVIOUS),
                (next.id().clone(), NEXT),
                (show.id().clone(), SHOW),
                (exit.id().clone(), QUIT),
            ];
            MenuEvent::set_event_handler(Some(move |event: MenuEvent| {
                if let Some((_, command)) = commands.iter().find(|(id, _)| *id == *event.id()) {
                    let _ = events.send(Event::TrayCommand((*command).to_owned()));
                }
            }));
            let mut builder = TrayIconBuilder::new().with_menu(Box::new(menu)).with_tooltip("Nari");
            if let Some(image) = favicon::pick(48) {
                if let Ok(icon) = Icon::from_rgba(image.as_raw().clone(), image.width(), image.height()) {
                    builder = builder.with_icon(icon);
                }
            }
            let icon = match builder.build() {
                Ok(icon) => icon,
                Err(error) => {
                    godot::global::godot_error!("MusicService tray unavailable: {error}");
                    return None;
                }
            };
            Some(Self { icon: RefCell::new(Some(icon)), toggle })
        }

        pub fn set_state(&self, title: String, playing: bool, _cover: String) {
            self.toggle.set_text(if playing { "Pause" } else { "Play" });
            if let Some(icon) = self.icon.borrow().as_ref() {
                let _ = icon.set_tooltip(Some(if title.is_empty() { "Nari".to_owned() } else { format!("Nari — {}", short(&title)) }));
            }
        }

        pub fn shutdown(&self) {
            self.icon.borrow_mut().take();
        }
    }
}

#[cfg(not(any(target_os = "linux", windows, target_os = "macos")))]
mod platform {
    use super::*;

    pub struct Tray;

    impl Tray {
        pub fn new(_events: Sender<Event>) -> Option<Self> {
            None
        }

        pub fn set_state(&self, _title: String, _playing: bool, _cover: String) {}

        pub fn shutdown(&self) {}
    }
}

pub use platform::Tray;

#[cfg(target_os = "linux")]
pub fn set_window_visible(visible: bool) -> bool {
    use godot::classes::display_server::HandleType;
    use godot::classes::DisplayServer;
    use godot::obj::Singleton;
    use std::ffi::{c_int, c_ulong, c_void};
    use std::sync::OnceLock;

    type Display = *mut c_void;
    static X11: OnceLock<Option<libloading::Library>> = OnceLock::new();

    let server = DisplayServer::singleton();
    if server.get_name().to_string() != "X11" {
        return false;
    }
    let Some(x11) = X11.get_or_init(|| unsafe { libloading::Library::new("libX11.so.6").ok() })
    else {
        return false;
    };
    let display = server.window_get_native_handle(HandleType::DISPLAY_HANDLE) as Display;
    let window = server.window_get_native_handle(HandleType::WINDOW_HANDLE) as c_ulong;
    if display.is_null() || window == 0 {
        return false;
    }
    unsafe {
        let (Ok(screen), Ok(withdraw), Ok(map), Ok(flush)) = (
            x11.get::<unsafe extern "C" fn(Display) -> c_int>(b"XDefaultScreen"),
            x11.get::<unsafe extern "C" fn(Display, c_ulong, c_int) -> c_int>(b"XWithdrawWindow"),
            x11.get::<unsafe extern "C" fn(Display, c_ulong) -> c_int>(b"XMapRaised"),
            x11.get::<unsafe extern "C" fn(Display) -> c_int>(b"XFlush"),
        ) else {
            return false;
        };
        if visible {
            map(display, window);
        } else {
            withdraw(display, window, screen(display));
        }
        flush(display);
    }
    true
}

#[cfg(windows)]
pub fn set_window_visible(visible: bool) -> bool {
    use godot::classes::display_server::HandleType;
    use godot::classes::DisplayServer;
    use godot::obj::Singleton;
    use windows_sys::Win32::UI::WindowsAndMessaging::{ShowWindow, SW_HIDE, SW_SHOW};

    let window = DisplayServer::singleton().window_get_native_handle(HandleType::WINDOW_HANDLE);
    if window == 0 {
        return false;
    }
    unsafe { ShowWindow(window as _, if visible { SW_SHOW } else { SW_HIDE }) };
    true
}

#[cfg(target_os = "macos")]
pub fn set_window_visible(visible: bool) -> bool {
    use godot::classes::display_server::HandleType;
    use godot::classes::DisplayServer;
    use godot::obj::Singleton;
    use objc2::MainThreadMarker;
    use objc2_app_kit::{NSApplication, NSWindow};

    let handle = DisplayServer::singleton().window_get_native_handle(HandleType::WINDOW_HANDLE);
    let Some(mtm) = MainThreadMarker::new() else {
        return false;
    };
    if handle == 0 {
        return false;
    }
    let window = unsafe { &*(handle as *const NSWindow) };
    if visible {
        #[allow(deprecated)]
        NSApplication::sharedApplication(mtm).activateIgnoringOtherApps(true);
        window.makeKeyAndOrderFront(None);
    } else {
        window.orderOut(None);
    }
    true
}

#[cfg(not(any(target_os = "linux", windows, target_os = "macos")))]
pub fn set_window_visible(_visible: bool) -> bool {
    false
}
