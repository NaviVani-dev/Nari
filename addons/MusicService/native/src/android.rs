use jni::objects::{GlobalRef, JClass, JObject, JString, JValue};
use jni::sys::{jboolean, jint, jlong, JNI_VERSION_1_6};
use jni::{JNIEnv, JavaVM};
use std::ffi::c_void;
use std::sync::mpsc::{channel, Sender};
use std::sync::{Mutex, OnceLock, Weak};
use std::time::Duration;

use crate::events::{Bridge, Event};
use crate::player::Player;
// ANDROID IS A PAIN IN THE FUCKING ASS, I FUCKING HATE YOU GOOGLE
const STRING_TO_STRING: &str = "(Ljava/lang/String;)Ljava/lang/String;";
const STRING_TO_VOID: &str = "(Ljava/lang/String;)V";
const STRING_TO_FLAG: &str = "(Ljava/lang/String;)Z";
const STRING_TO_INT: &str = "(Ljava/lang/String;)I";

static VM: OnceLock<JavaVM> = OnceLock::new();
static CLASS: OnceLock<GlobalRef> = OnceLock::new();
static CONTEXT: OnceLock<GlobalRef> = OnceLock::new();
static EVENTS: Mutex<Option<Sender<Event>>> = Mutex::new(None);
static COMMANDS: Mutex<Option<Sender<(String, i64)>>> = Mutex::new(None);
const DRIVE_INTERVAL: Duration = Duration::from_millis(250);

#[no_mangle]
pub extern "system" fn JNI_OnLoad(vm: JavaVM, _reserved: *mut c_void) -> jint {
    let _ = VM.set(vm);
    JNI_VERSION_1_6
}

pub fn java_vm() -> Option<*mut c_void> {
    VM.get().map(|vm| vm.get_java_vm_pointer().cast())
}

pub fn attach(events: Sender<Event>) {
    *EVENTS.lock().unwrap() = Some(events);
}

pub fn drive(player: Weak<Mutex<Player>>) {
    let (commands, receiver) = channel();
    *COMMANDS.lock().unwrap() = Some(commands);
    std::thread::spawn(move || {
        let mut session = String::new();
        loop {
            let command = receiver.recv_timeout(DRIVE_INTERVAL).ok();
            let Some(player) = player.upgrade() else {
                return;
            };
            let state = {
                let mut player = player.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
                if let Some((name, value)) = command {
                    player.command(&name, value);
                }
                player.tick();
                player.session_json()
            };
            if state != session {
                update_session(&state);
                session = state;
            }
        }
    });
}

pub fn ready() -> bool {
    CLASS.get().is_some() && CONTEXT.get().is_some()
}

fn send(bridge: Bridge) {
    if let Some(events) = EVENTS.lock().unwrap().as_ref() {
        let _ = events.send(Event::Bridge(bridge));
    }
}

fn invoke<T>(run: impl FnOnce(&mut JNIEnv, &JClass) -> jni::errors::Result<T>) -> Option<T> {
    let vm = VM.get()?;
    let class = CLASS.get()?;
    let mut env = vm.attach_current_thread_permanently().ok()?;
    let class: &JClass = class.as_obj().into();
    let result = env.with_local_frame(8, |env| run(env, class));
    if env.exception_check().unwrap_or(false) {
        let _ = env.exception_describe();
        let _ = env.exception_clear();
        return None;
    }
    result.ok()
}

fn with_text<T>(
    name: &str,
    signature: &str,
    value: &str,
    read: impl FnOnce(&mut JNIEnv, jni::objects::JValueOwned) -> jni::errors::Result<T>,
) -> Option<T> {
    invoke(|env, class| {
        let argument = env.new_string(value)?;
        let result = env.call_static_method(class, name, signature, &[JValue::Object(&argument)])?;
        read(env, result)
    })
}

fn to_string(env: &mut JNIEnv, value: jni::objects::JValueOwned) -> jni::errors::Result<String> {
    let object = value.l()?;
    if object.is_null() {
        return Ok(String::new());
    }
    Ok(env.get_string(&JString::from(object))?.into())
}

fn text_call(name: &str, value: &str) -> Option<String> {
    with_text(name, STRING_TO_STRING, value, to_string)
}

fn void_call(name: &str, value: &str) {
    with_text(name, STRING_TO_VOID, value, |_, _| Ok(()));
}

pub fn webview(request: &str) -> String {
    text_call("webview", request).unwrap_or_default()
}

pub fn open_fd(uri: &str) -> i32 {
    with_text("openFd", STRING_TO_INT, uri, |_, value| value.i()).unwrap_or(-1)
}

pub fn discover(request: &str) -> String {
    text_call("discover", request).unwrap_or_else(|| "{}".to_owned())
}

pub fn has_permission(kind: &str) -> bool {
    with_text("hasPermission", STRING_TO_FLAG, kind, |_, value| value.z()).unwrap_or(false)
}

pub fn request_permission(kind: &str) {
    void_call("requestPermission", kind);
}

pub fn pick(kind: &str) {
    void_call("pick", kind);
}

pub fn release_folder(uri: &str) {
    void_call("releaseFolder", uri);
}

pub fn system(query: &str) -> String {
    text_call("system", query).unwrap_or_default()
}

pub fn update_session(state: &str) {
    void_call("updateSession", state);
}

pub fn vault(request: &str) -> String {
    text_call("vault", request).unwrap_or_default()
}

pub fn discord(payload: &str) {
    void_call("discord", payload);
}

#[no_mangle]
pub extern "system" fn Java_org_navivani_musicservice_NariBridge_init(
    env: JNIEnv,
    class: JClass,
    context: JObject,
) {
    let Some(vm) = VM.get() else {
        return;
    };
    if CONTEXT.get().is_none() {
        if let Ok(global) = env.new_global_ref(&context) {
            unsafe {
                ndk_context::initialize_android_context(
                    vm.get_java_vm_pointer().cast(),
                    global.as_obj().as_raw().cast(),
                );
            }
            let _ = CONTEXT.set(global);
        }
    }
    if let Ok(global) = env.new_global_ref(class) {
        let _ = CLASS.set(global);
    }
}

fn read(env: &mut JNIEnv, value: &JString) -> String {
    env.get_string(value).map(String::from).unwrap_or_default()
}

#[no_mangle]
pub extern "system" fn Java_org_navivani_musicservice_NariBridge_onPicked(
    mut env: JNIEnv,
    _class: JClass,
    kind: JString,
    value: JString,
) {
    let kind = read(&mut env, &kind);
    let value = read(&mut env, &value);
    send(Bridge::Picked { kind, value });
}

#[no_mangle]
pub extern "system" fn Java_org_navivani_musicservice_NariBridge_onPermission(
    mut env: JNIEnv,
    _class: JClass,
    kind: JString,
    granted: jboolean,
) {
    let kind = read(&mut env, &kind);
    send(Bridge::Permission {
        kind,
        granted: granted != 0,
    });
}

#[no_mangle]
pub extern "system" fn Java_org_navivani_musicservice_NariBridge_onLibraryChanged(
    _env: JNIEnv,
    _class: JClass,
) {
    send(Bridge::LibraryChanged);
}

#[no_mangle]
pub extern "system" fn Java_org_navivani_musicservice_NariBridge_onCommand(
    mut env: JNIEnv,
    _class: JClass,
    name: JString,
    value: jlong,
) {
    let name = read(&mut env, &name);
    if let Some(commands) = COMMANDS.lock().unwrap().as_ref() {
        let _ = commands.send((name, value));
    }
}

#[no_mangle]
pub extern "system" fn Java_org_navivani_musicservice_NariBridge_onLink(
    mut env: JNIEnv,
    _class: JClass,
    url: JString,
) {
    if let Ok(url) = env.get_string(&url) {
        send(Bridge::Link(url.into()));
    }
}

#[no_mangle]
pub extern "system" fn Java_org_navivani_musicservice_NariBridge_onNowPlaying(
    _env: JNIEnv,
    _class: JClass,
) {
    send(Bridge::NowPlaying);
}
