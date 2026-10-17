use raw_window_handle::{HandleError, HasWindowHandle, RawWindowHandle, WindowHandle};
use serde_json::{json, Value};
use std::ffi::{c_char, c_void, CStr, CString};
use std::sync::{Arc, Mutex};
use wry::dpi::{PhysicalPosition, PhysicalSize};
use wry::{PageLoadEvent, Rect, WebContext, WebView, WebViewBuilder};

struct Parent(u64);

impl HasWindowHandle for Parent {
    fn window_handle(&self) -> Result<WindowHandle<'_>, HandleError> {
        #[cfg(windows)]
        let raw = RawWindowHandle::Win32(raw_window_handle::Win32WindowHandle::new(
            std::num::NonZeroIsize::new(self.0 as isize).ok_or(HandleError::Unavailable)?,
        ));
        #[cfg(target_os = "macos")]
        let raw = RawWindowHandle::AppKit(raw_window_handle::AppKitWindowHandle::new(
            std::ptr::NonNull::new(self.0 as *mut c_void).ok_or(HandleError::Unavailable)?,
        ));
        #[cfg(target_os = "linux")]
        let raw = RawWindowHandle::Xlib(raw_window_handle::XlibWindowHandle::new(self.0 as _));
        Ok(unsafe { WindowHandle::borrow_raw(raw) })
    }
}

struct View {
    webview: WebView,
    events: Arc<Mutex<Vec<Value>>>,
    _context: WebContext,
}

fn bounds(value: &Value) -> Option<Rect> {
    let numbers: Vec<f64> = value.as_array()?.iter().filter_map(Value::as_f64).collect();
    let [x, y, width, height] = numbers[..] else {
        return None;
    };
    Some(Rect {
        position: PhysicalPosition::new(x, y).into(),
        size: PhysicalSize::new(width.max(1.0), height.max(1.0)).into(),
    })
}

fn push(events: &Arc<Mutex<Vec<Value>>>, event: Value) {
    events.lock().unwrap_or_else(|poisoned| poisoned.into_inner()).push(event);
}

#[cfg(target_os = "linux")]
fn release_children(display: u64, window: u64) -> Result<(), String> {
    use x11_dl::xlib::*;
    let xlib = Xlib::open().map_err(|error| error.to_string())?;
    unsafe {
        let display = display as *mut Display;
        let mut attributes: XWindowAttributes = std::mem::zeroed();
        (xlib.XGetWindowAttributes)(display, window, &mut attributes);
        let mut changed: XSetWindowAttributes = std::mem::zeroed();
        changed.event_mask = attributes.your_event_mask & !(SubstructureNotifyMask | SubstructureRedirectMask);
        (xlib.XChangeWindowAttributes)(display, window, CWEventMask, &mut changed);
    }
    Ok(())
}

fn create(options: &Value) -> Result<View, String> {
    let text = |key: &str| options[key].as_str().filter(|value| !value.is_empty());
    let flag = |key: &str| options[key].as_bool().unwrap_or(false);
    let window = options["window"].as_u64().ok_or("the window has no native handle")?;
    #[cfg(target_os = "linux")]
    {
        release_children(options["display"].as_u64().ok_or("the X11 display is missing")?, window)?;
        gtk::gdk::set_allowed_backends("x11");
        gtk::init().map_err(|error| error.to_string())?;
    }
    let mut context = WebContext::new(text("data").map(Into::into));
    let events = Arc::new(Mutex::new(Vec::new()));
    let (loads, messages, titles) = (events.clone(), events.clone(), events.clone());
    let mut builder = WebViewBuilder::new_with_web_context(&mut context)
        .with_incognito(flag("incognito"))
        .with_transparent(flag("transparent"))
        .with_devtools(flag("devtools"))
        .with_autoplay(flag("autoplay"))
        .with_visible(flag("visible"))
        .with_focused(false)
        .with_accept_first_mouse(true)
        .with_on_page_load_handler(move |event, url| {
            let name = if matches!(event, PageLoadEvent::Started) { "started" } else { "finished" };
            push(&loads, json!({ "event": name, "text": url }))
        })
        .with_ipc_handler(move |request| push(&messages, json!({ "event": "message", "text": request.body() })))
        .with_document_title_changed_handler(move |title| push(&titles, json!({ "event": "title", "text": title })));
    for script in options["scripts"].as_array().into_iter().flatten().filter_map(Value::as_str) {
        builder = builder.with_initialization_script(script);
    }
    if let Some(agent) = text("user_agent") {
        builder = builder.with_user_agent(agent);
    }
    if let Some(rect) = bounds(&options["bounds"]) {
        builder = builder.with_bounds(rect);
    }
    builder = match text("html") {
        Some(html) => builder.with_html(html),
        None => builder.with_url(text("url").unwrap_or("about:blank")),
    };
    let webview = builder.build_as_child(&Parent(window)).map_err(|error| error.to_string())?;
    Ok(View { webview, events, _context: context })
}

fn send(view: &View, command: &Value) -> Value {
    let webview = &view.webview;
    let mut reply = Value::Null;
    for (name, value) in command.as_object().into_iter().flatten() {
        let text = value.as_str().unwrap_or_default();
        let _ = match name.as_str() {
            "bounds" => bounds(value).map_or(Ok(()), |rect| webview.set_bounds(rect)),
            "visible" => webview.set_visible(value.as_bool().unwrap_or(true)),
            "url" => webview.load_url(text),
            "html" => webview.load_html(text),
            "eval" => {
                let (events, id) = (view.events.clone(), command["id"].clone());
                webview.evaluate_script_with_callback(text, move |result| push(&events, json!({ "event": "result", "id": id, "text": result })))
            }
            "cookies" => webview.cookies_for_url(text).map(|cookies| {
                let pairs: Vec<String> = cookies.iter().map(|cookie| format!("{}={}", cookie.name(), cookie.value())).collect();
                reply = json!(pairs.join("; "));
            }),
            "clear" => webview.clear_all_browsing_data(),
            "zoom" => webview.zoom(value.as_f64().unwrap_or(1.0)),
            "reload" => webview.reload(),
            "back" => webview.go_back(),
            "forward" => webview.go_forward(),
            "focus" if value.as_bool() == Some(true) => webview.focus(),
            "focus" => webview.focus_parent(),
            "poll" => {
                #[cfg(target_os = "linux")]
                while gtk::events_pending() {
                    gtk::main_iteration_do(false);
                }
                reply = Value::Array(std::mem::take(&mut *view.events.lock().unwrap_or_else(|poisoned| poisoned.into_inner())));
                Ok(())
            }
            _ => Ok(()),
        };
    }
    reply
}

unsafe fn parse(text: *const c_char) -> Value {
    serde_json::from_str(&CStr::from_ptr(text).to_string_lossy()).unwrap_or_default()
}

#[no_mangle]
pub extern "C" fn nari_webview_ready() -> bool {
    wry::webview_version().is_ok()
}

#[no_mangle]
pub unsafe extern "C" fn nari_webview_create(options: *const c_char) -> *mut c_void {
    match create(&parse(options)) {
        Ok(view) => Box::into_raw(Box::new(view)).cast(),
        Err(problem) => {
            eprintln!("WebView: {problem}");
            std::ptr::null_mut()
        }
    }
}

#[no_mangle]
pub unsafe extern "C" fn nari_webview_send(view: *mut c_void, command: *const c_char) -> *mut c_char {
    let reply = send(&*(view as *const View), &parse(command));
    CString::new(reply.to_string()).unwrap_or_default().into_raw()
}

#[no_mangle]
pub unsafe extern "C" fn nari_webview_free(text: *mut c_char) {
    if !text.is_null() {
        drop(CString::from_raw(text));
    }
}

#[no_mangle]
pub unsafe extern "C" fn nari_webview_destroy(view: *mut c_void) {
    if view.is_null() {
        return;
    }
    let view = Box::from_raw(view as *mut View);
    let _ = view.webview.set_visible(false);
    drop(view);
    #[cfg(target_os = "linux")]
    {
        while gtk::events_pending() {
            gtk::main_iteration_do(false);
        }
        if let Some(display) = gtk::gdk::Display::default() {
            display.flush();
        }
    }
}
