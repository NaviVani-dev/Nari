#![cfg_attr(any(target_os = "android", target_os = "ios"), allow(dead_code, unused_imports))]

#[cfg(target_os = "android")]
mod android;
#[cfg(target_os = "ios")]
mod ios;
mod analysis;
mod animation;
mod motion;
mod palette;
mod api;
mod audio;
mod cast;
mod device;
mod discord;
mod effects;
mod voices;
mod library;
mod history;
mod hls;
mod lyrics;
mod mpris;
mod opened;
mod player;
mod playlists;
mod plugins;
mod remote;
mod scrobble;
mod soundboard;
mod spectrum;
mod storage;
mod synth;
mod stream;
mod tray;
mod ts;
mod updates;
mod vault;
mod events;
mod webview;
#[cfg(any(windows, target_os = "macos"))]
#[path = "../webview/src/lib.rs"]
mod engine;

use godot::classes::{Engine, SceneTree};
use godot::init::{ExtensionLibrary, InitStage};
use godot::prelude::*;

use api::{MusicService, ServiceTicker};

struct MusicServiceExtension;

#[gdextension]
unsafe impl ExtensionLibrary for MusicServiceExtension {
    fn on_stage_init(stage: InitStage) {
        if stage != InitStage::Scene || Engine::singleton().is_editor_hint() {
            return;
        }
        let service = MusicService::new_alloc();
        Engine::singleton().register_singleton(&MusicService::class_id().to_string_name(), &service);
        Callable::from_fn("attach_ticker", |_| {
            attach_ticker();
            Variant::nil()
        })
        .call_deferred(&[]);
    }

    fn on_stage_deinit(stage: InitStage) {
        if stage != InitStage::Scene {
            return;
        }
        let name = MusicService::class_id().to_string_name();
        let mut engine = Engine::singleton();
        if !engine.has_singleton(&name) {
            return;
        }
        if let Some(service) = engine.get_singleton(&name) {
            engine.unregister_singleton(&name);
            service.free();
        }
    }
}

fn attach_ticker() {
    let Some(tree) = Engine::singleton()
        .get_main_loop()
        .and_then(|main_loop| main_loop.try_cast::<SceneTree>().ok())
    else {
        return;
    };
    tree.get_root().add_child(&ServiceTicker::new_alloc());
}
