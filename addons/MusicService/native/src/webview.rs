use godot::classes::display_server::HandleType;
use godot::classes::{Control, DisplayServer, IControl, ProjectSettings, SubViewportContainer, Viewport};
use godot::prelude::*;
use serde_json::{json, Value};

const SCREENS_META: &str = "screens";
const MAX_SIZE: f32 = 16384.0;
const MOBILE_AGENT: &str = "Mozilla/5.0 (Linux; Android 15; Pixel 9) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Mobile Safari/537.36";

#[derive(GodotClass)]
#[class(base = Control, init)]
pub struct WebView {
    #[export]
    url: GString,
    #[export]
    incognito: bool,
    #[export]
    #[init(val = true)]
    desktop_mode: bool,
    #[export]
    user_agent: GString,
    #[export]
    transparent: bool,
    #[export]
    devtools: bool,
    #[export]
    autoplay: bool,
    #[export(range = (0.25, 5.0, 0.05))]
    #[init(val = 1.0)]
    zoom: f64,
    #[export]
    scripts: PackedStringArray,
    #[export(enum = (Auto = 0, Window = 1, Second = 2))]
    screen: i32,
    view: Option<native::View>,
    evals: i64,
    config: String,
    shown: Value,
    loaded: GString,
    base: Base<Control>,
}

#[godot_api]
impl IControl for WebView {
    fn process(&mut self, _delta: f64) {
        let mut shown = self.layout();
        let mut config = self.config();
        config["screen"] = shown["screen"].clone();
        if config.to_string() != self.config {
            self.rebuild(config, &shown);
        }
        let Some(view) = &self.view else {
            return;
        };
        let mut command = json!({ "poll": true });
        shown["visible"] = json!(self.base().is_visible_in_tree());
        shown["zoom"] = json!(self.zoom);
        if shown != self.shown {
            command.as_object_mut().unwrap().extend(shown.as_object().unwrap().clone());
            self.shown = shown;
        }
        if self.url != self.loaded {
            command["url"] = json!(self.url.to_string());
            self.loaded = self.url.clone();
        }
        let reply = view.send(&command);
        for event in reply.as_array().into_iter().flatten() {
            let text = GString::from(event["text"].as_str().unwrap_or_default());
            let signal = match event["event"].as_str().unwrap_or_default() {
                "result" => {
                    let id = event["id"].as_i64().unwrap_or_default();
                    self.base_mut().emit_signal("script_result", &[id.to_variant(), text.to_variant()]);
                    continue;
                }
                "started" => "page_load_started",
                "finished" => {
                    self.url = text.clone();
                    self.loaded = text.clone();
                    "page_load_finished"
                }
                "title" => "title_changed",
                "message" => "ipc_message",
                _ => continue,
            };
            self.base_mut().emit_signal(signal, &[text.to_variant()]);
        }
    }

    fn exit_tree(&mut self) {
        self.view = None;
        self.config.clear();
    }
}

#[godot_api]
impl WebView {
    #[signal]
    fn page_load_started(url: GString);

    #[signal]
    fn page_load_finished(url: GString);

    #[signal]
    fn title_changed(title: GString);

    #[signal]
    fn ipc_message(message: GString);

    #[signal]
    fn script_result(id: i64, result: GString);

    #[func]
    fn is_available() -> bool {
        (!cfg!(target_os = "linux") || DisplayServer::singleton().get_name().to_string() == "X11") && native::available()
    }

    #[func]
    fn reload(&self) {
        self.send(json!({ "reload": true }));
    }

    #[func]
    fn go_back(&self) {
        self.send(json!({ "back": true }));
    }

    #[func]
    fn go_forward(&self) {
        self.send(json!({ "forward": true }));
    }

    #[func]
    fn eval(&mut self, script: GString) -> i64 {
        self.evals += 1;
        self.send(json!({ "eval": script.to_string(), "id": self.evals }));
        self.evals
    }

    #[func]
    fn get_cookies(&self, url: GString) -> GString {
        GString::from(self.send(json!({ "cookies": url.to_string() })).as_str().unwrap_or_default())
    }

    #[func]
    fn clear_browsing_data(&self) {
        self.send(json!({ "clear": true }));
    }

    #[func]
    fn load_html(&self, html: GString) {
        self.send(json!({ "html": html.to_string() }));
    }

    #[func]
    fn focus_page(&self, focused: bool) {
        self.send(json!({ "focus": focused }));
    }

    fn send(&self, command: Value) -> Value {
        self.view.as_ref().map_or(Value::Null, |view| view.send(&command))
    }

    fn config(&self) -> Value {
        let agent = match self.desktop_mode || cfg!(target_os = "android") {
            _ if !self.user_agent.is_empty() => self.user_agent.to_string(),
            false => MOBILE_AGENT.into(),
            true => String::new(),
        };
        json!({
            "incognito": self.incognito,
            "desktop": self.desktop_mode,
            "user_agent": agent,
            "transparent": self.transparent,
            "devtools": self.devtools,
            "autoplay": self.autoplay,
            "scripts": self.scripts.as_slice().iter().map(|script| script.to_string()).collect::<Vec<_>>(),
        })
    }

    fn rebuild(&mut self, mut options: Value, layout: &Value) {
        self.config = options.to_string();
        self.view = None;
        self.shown = Value::Null;
        self.loaded = self.url.clone();
        let Some(window) = self.window() else {
            godot_warn!("WebView needs a native window (X11 on Linux)");
            return;
        };
        options["window"] = json!(window);
        options["display"] = json!(DisplayServer::singleton().window_get_native_handle(HandleType::DISPLAY_HANDLE));
        options["url"] = json!(self.url.to_string());
        options.as_object_mut().unwrap().extend(layout.as_object().unwrap().clone());
        options["visible"] = json!(self.base().is_visible_in_tree());
        options["data"] = json!(ProjectSettings::singleton().globalize_path("user://webview").to_string());
        self.view = native::View::create(&options);
        if self.view.is_none() {
            godot_warn!("WebView couldn't be created");
        }
    }

    fn window(&self) -> Option<u64> {
        let id = self.base().get_window()?.get_window_id();
        let server = DisplayServer::singleton();
        if cfg!(target_os = "android") {
            return Some(0);
        }
        if cfg!(target_os = "linux") && server.get_name().to_string() != "X11" {
            return None;
        }
        let kind = if cfg!(target_os = "macos") { HandleType::WINDOW_VIEW } else { HandleType::WINDOW_HANDLE };
        let handle = server.window_get_native_handle_ex(kind).window_id(id).done();
        (handle != 0).then_some(handle as u64)
    }

    fn second_screen(&self) -> Option<(usize, VarDictionary)> {
        let root = self.base().get_tree().get_root();
        if self.screen == 1 || !root.has_meta(SCREENS_META) {
            return None;
        }
        let own = self.base().get_viewport()?;
        let screens = root.get_meta(SCREENS_META).try_to::<VarArray>().ok()?;
        screens.iter_shared().enumerate().find_map(|(position, entry)| {
            let entry = entry.try_to::<VarDictionary>().ok()?;
            let viewport = entry.get("viewport")?.try_to::<Gd<Viewport>>().ok()?;
            (self.screen == 2 || viewport == own).then_some((position + 1, entry))
        })
    }

    fn window_transform(&self) -> Transform2D {
        let mut transform = self.base().get_global_transform_with_canvas();
        let mut viewport = self.base().get_viewport();
        while let Some(current) = viewport {
            transform = current.get_final_transform() * transform;
            let Some(container) = current.get_parent().and_then(|parent| parent.try_cast::<SubViewportContainer>().ok()) else {
                break;
            };
            let shrink = if container.is_stretch_enabled() { container.get_stretch_shrink() as f32 } else { 1.0 };
            transform = container.get_global_transform_with_canvas() * transform.scaled(Vector2::splat(shrink));
            viewport = container.get_viewport();
        }
        transform
    }

    fn layout(&self) -> Value {
        let size = self.base().get_size();
        let Some((index, screen)) = self.second_screen() else {
            let transform = self.window_transform();
            let (start, end) = (transform * Vector2::ZERO, transform * size);
            let (width, height) = ((end.x - start.x).round().clamp(1.0, MAX_SIZE), (end.y - start.y).round().clamp(1.0, MAX_SIZE));
            return json!({ "screen": 0, "bounds": [start.x.round(), start.y.round(), width, height], "view": [width, height], "rotation": 0 });
        };
        let viewport = self.base().get_viewport().map_or(Vector2::ONE, |viewport| viewport.get_visible_rect().size);
        let target = screen.get("size").and_then(|size| size.try_to::<Vector2>().ok()).unwrap_or(viewport);
        let rotation = screen.get("rotation").and_then(|rotation| rotation.try_to::<i64>().ok()).unwrap_or(0);
        let transform = self.base().get_global_transform_with_canvas();
        let (start, end) = (transform * Vector2::ZERO / viewport, transform * size / viewport);
        let (x, y, w, h) = (start.x, start.y, end.x - start.x, end.y - start.y);
        let (sx, sy, sw, sh) = match rotation {
            90 => (1.0 - y - h, x, h, w),
            180 => (1.0 - x - w, 1.0 - y - h, w, h),
            270 => (y, 1.0 - x - w, h, w),
            _ => (x, y, w, h),
        };
        let view = if rotation % 180 == 90 { [w * target.y, h * target.x] } else { [w * target.x, h * target.y] };
        json!({
            "screen": index,
            "bounds": [(sx * target.x).round(), (sy * target.y).round(), (sw * target.x).round().clamp(1.0, MAX_SIZE), (sh * target.y).round().clamp(1.0, MAX_SIZE)],
            "view": [view[0].round().clamp(1.0, MAX_SIZE), view[1].round().clamp(1.0, MAX_SIZE)],
            "rotation": rotation,
        })
    }
}

#[cfg(not(target_os = "android"))]
mod native {
    use serde_json::Value;
    use std::ffi::{c_char, c_void, CStr, CString};

    struct Api {
        ready: unsafe extern "C" fn() -> bool,
        create: unsafe extern "C" fn(*const c_char) -> *mut c_void,
        send: unsafe extern "C" fn(*mut c_void, *const c_char) -> *mut c_char,
        free: unsafe extern "C" fn(*mut c_char),
        destroy: unsafe extern "C" fn(*mut c_void),
    }

    #[cfg(target_os = "ios")]
    fn api() -> Option<&'static Api> {
        None
    }

    #[cfg(any(windows, target_os = "macos"))]
    fn api() -> Option<&'static Api> {
        use crate::engine::*;
        static API: Api = Api { ready: nari_webview_ready, create: nari_webview_create, send: nari_webview_send, free: nari_webview_free, destroy: nari_webview_destroy };
        Some(&API)
    }

    #[cfg(target_os = "linux")]
    fn api() -> Option<&'static Api> {
        static API: std::sync::OnceLock<Option<(libloading::Library, Api)>> = std::sync::OnceLock::new();
        API.get_or_init(|| unsafe {
            let library = libloading::Library::new("libnari_webview.so")
                .map_err(|error| {
                    godot::global::godot_warn!("WebView needs WebKitGTK 4.1: {error}");
                })
                .ok()?;
            let api = Api {
                ready: *library.get(b"nari_webview_ready\0").ok()?,
                create: *library.get(b"nari_webview_create\0").ok()?,
                send: *library.get(b"nari_webview_send\0").ok()?,
                free: *library.get(b"nari_webview_free\0").ok()?,
                destroy: *library.get(b"nari_webview_destroy\0").ok()?,
            };
            Some((library, api))
        })
        .as_ref()
        .map(|(_, api)| api)
    }

    pub fn available() -> bool {
        api().is_some_and(|api| unsafe { (api.ready)() })
    }

    pub struct View(*mut c_void, &'static Api);

    impl View {
        pub fn create(options: &Value) -> Option<Self> {
            let api = api()?;
            let options = CString::new(options.to_string()).ok()?;
            let handle = unsafe { (api.create)(options.as_ptr()) };
            (!handle.is_null()).then(|| Self(handle, api))
        }

        pub fn send(&self, command: &Value) -> Value {
            let Ok(command) = CString::new(command.to_string()) else {
                return Value::Null;
            };
            unsafe {
                let reply = (self.1.send)(self.0, command.as_ptr());
                let value = serde_json::from_str(&CStr::from_ptr(reply).to_string_lossy()).unwrap_or_default();
                (self.1.free)(reply);
                value
            }
        }
    }

    impl Drop for View {
        fn drop(&mut self) {
            unsafe { (self.1.destroy)(self.0) }
        }
    }
}

#[cfg(target_os = "android")]
mod native {
    use serde_json::{json, Value};

    pub fn available() -> bool {
        true
    }

    pub struct View(i64);

    impl View {
        pub fn create(options: &Value) -> Option<Self> {
            let reply = crate::android::webview(&json!({ "create": options }).to_string());
            serde_json::from_str::<Value>(&reply).ok()?["handle"].as_i64().map(Self)
        }

        pub fn send(&self, command: &Value) -> Value {
            let mut command = command.clone();
            command["handle"] = json!(self.0);
            serde_json::from_str(&crate::android::webview(&command.to_string())).unwrap_or_default()
        }
    }

    impl Drop for View {
        fn drop(&mut self) {
            crate::android::webview(&json!({ "handle": self.0, "destroy": true }).to_string());
        }
    }
}
