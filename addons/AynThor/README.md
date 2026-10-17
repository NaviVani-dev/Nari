# AynThor

Dual screen plugin for Android handhelds with a secondary display (Ayn Thor, Retroid Pocket 5,
RG DS). A `SubViewport` is blitted to the second physical display through a dedicated Vulkan
swapchain, and touches on that display are routed back into the same `SubViewport`.

Vendored from [flametime/Godot-Android-DS-plugin](https://github.com/flametime/Godot-Android-DS-plugin)
at commit `9539f25` (MIT, see `LICENSE`).

## Local changes over upstream

- **Desktop builds are debug-only editor stubs.** The whole native implementation is behind
  `#ifdef __ANDROID__`, so the Linux and Windows libraries only register the class
  (`is_window_available()` returns `false`) to keep the editor from logging
  `No GDExtension library found for current OS and architecture`. They are built with
  `target=template_debug` and mapped only as `linux.debug.x86_64` / `windows.debug.x86_64`.
  They are never packaged: the desktop export presets exclude `AynThor.gdextension`, and
  `AynThorManager` checks `ClassDB.class_exists("AynThorRenderer")` and does nothing without it.
- **Touch fix**, two stacked engine details, both required:
  - Upstream pushed only `InputEventScreenTouch`/`InputEventScreenDrag`. `BaseButton::gui_input`
    reacts to `InputEventMouseButton` and to the `ui_accept` action — never to a raw screen touch.
    Godot normally papers over this in `Input::_parse_input_event_impl`, which synthesizes a mouse
    event from touch (`input_devices/pointing/emulate_mouse_from_touch`, on by default), but
    `Viewport.push_input()` bypasses `Input` entirely. So no button could ever be pressed, at any
    coordinate. `AynThorManager` now replicates that emulation: it pushes the touch/drag event
    *and*, for the single pointer that owns the emulated cursor, a matching
    `InputEventMouseButton`/`InputEventMouseMotion`.
  - The emulated click alone still does nothing, because of `BaseButton::on_action_event`:

    ```cpp
    if (p_event->is_pressed() && (mouse_button.is_null() || status.hovering)) { ... }
    ```

    A *mouse* event requires `status.hovering`, which only `NOTIFICATION_MOUSE_ENTER` sets, which
    comes from `Viewport::_update_mouse_over()` — and that returns immediately when
    `is_attached_in_viewport()`, i.e. when the `SubViewport`'s parent is a `SubViewportContainer`.
    The engine expects the container to drive hover from the real mouse, and the second screen's
    container is parked off-screen at x = -10000, so hover was never established. Note the
    `mouse_button.is_null()` half of that condition: non-mouse events (the `ui_accept` action) skip
    the hover requirement, which is exactly why gamepad navigation always worked while touch never
    did. `AynThorManager` therefore reparents the viewport it is blitting out of its
    `SubViewportContainer` (`_update_detached_viewports`), and swaps which one is detached when the
    screens are swapped. A `SubViewport` renders and can be blitted just fine without a container;
    the container is only needed to *draw* it on the main display.
- **Secondary screen detection.** `has_second_screen()` plus a `DisplayManager.DisplayListener`
  for hotplug, so the game can pick a layout instead of assuming two screens.
- **The second screen survives system popups.** Upstream dismissed the `Presentation` in
  `onMainPause` and rebuilt it on resume, so a runtime permission dialog or the file picker
  (both pause the activity) blanked the second display. `onMainPause` now only dismisses it when
  the top activity of the app's own task is still the Godot activity, which means the user really
  left the app (Home, app switch). A permission dialog or a picker launched with
  `startActivityForResult` is already on top of that same task by the time the activity pauses, so
  the presentation stays up and shows the last frame while Godot is paused. `GodotPlugin` has no
  `onMainStop` hook, which is why the check lives in pause. Before Android 10
  (`TaskInfo.taskId`) it falls back to always dismissing. `init_screen` no longer rebuilds a
  presentation that is still showing, so resuming does not flicker or re-emit
  `second_screen_connected`.
- **Source is vendored**, upstream only shipped a prebuilt `dist/`.

### About the rotation

The renderer's rotation handling is upstream's, unchanged, and it should stay that way. The blit
mirrors X and Y unconditionally and the swapchain requests `preTransform` from
`VK_SURFACE_TRANSFORM_IDENTITY_BIT_KHR` plus `rotation_degrees`. Rewriting `preTransform` to
`capabilities.currentTransform` — which looks like the "correct" no-extra-composite path — breaks
the image by 90° on an Ayn Thor, because that panel reports `currentTransform = ROTATE_90` (its
1080x1240 panel is presented as a 1240x1080 logical display) and the compositor then stops
applying the rotation the pipeline was relying on.

Touch coordinates arrive in logical-display space (1240x1080 on an Ayn Thor), which is the same
space the `SubViewport` is resized to, and at the default `rotation_degrees = 180` the rendered
image is upright in that space. So the mapping at the default is the **identity** — upstream's
raw pass-through of coordinates was right. `AynThorManager` still normalizes by the surface size
(so a surface/viewport size mismatch cannot skew it) and rotates by
`rotation_degrees - 180`, so that changing the render rotation carries the touch mapping with it.

## Layout

```
android/      Gradle project producing the AAR (same shape as addons/MusicService)
native/       GDExtension sources + SConstruct
bin/          build outputs, committed so the project runs without a build step
.build/       godot-cpp clone and caches (gitignored)
```

`android/`, `native/` and `.build/` each carry a `.gdignore` so the editor never scans them —
without it their build intermediates end up packed into the exported APK's `assets/`.

### Binary names are not free-form

- `bin/libaynthor_native.so` (Android arm64) **must** keep exactly that name. Godot copies GDExtension
  libraries into the APK preserving their basename (`export_plugin.cpp`,
  `dst_path = "lib"/abi/p_so.path.get_file()`), and `System.loadLibrary("aynthor_native")` resolves
  to `libaynthor_native.so`. Renaming it makes the app die at startup with
  `UnsatisfiedLinkError: dlopen failed: library "libaynthor_native.so" not found`.
- The x86_64 build lives in `bin/x86_64/libaynthor_native.so` for the same reason: each ABI's
  library has to be called `libaynthor_native.so` inside the APK, so it gets its own folder.
- The Linux and Windows names are free, since Godot loads those through the paths in
  `AynThor.gdextension`.

## Building

`just build plugins` from the project root builds the debug Linux and Windows editor stubs, the
Android libraries (arm64 and x86_64) and the AAR.

Requirements:

- `podman` or `docker` — Linux target. It is **not** built with the host toolchain on purpose:
  a Fedora 44 build (glibc 2.43, GCC 16) will not load in a Godot editor that runs under the
  Flatpak Freedesktop runtime (`version 'GLIBC_ABI_GNU2_TLS' not found`).
  `linux-builder.Containerfile` pins Ubuntu 22.04 (glibc 2.35).
- `mingw64-gcc-c++` — Windows target

- Android SDK + NDK, expected at `$ANDROID_HOME` (the newest NDK in it is used) — Android target
- `scons`
- A JDK 17 and `gradle` — the AAR. If `gradle` is not on `PATH` the script downloads it into
  `build/tools/` at the project root; the JDK comes from `$JAVA_HOME`.

`godot-cpp` (branch `4.5`) is cloned into `.build/` on first run (or set `GODOT_CPP_PATH` to your own checkout). There is no `4.6` branch yet,
but `compatibility_minimum = "4.2"` makes the 4.5 build load fine under Godot 4.6.

`native/build_profile.json` trims the generated bindings to the engine classes this extension
actually touches. Without it, linking `libgodot-cpp.a` fails with `ar: Argument list too long`
(the full API generates enough objects that their absolute paths blow past the exec argument
limit), and every build takes several times longer. **If you use a new engine class in the C++,
add it to that file** or you will get a `godot_cpp/classes/<name>.hpp: No such file` error.

## Usage

The plugin **requires Vulkan** — it pulls the Vulkan instance and device straight off Godot's
`RenderingDevice`. If the second screen stays black and logcat shows
`Vulkan device or instance is null`, the Android build is running GL Compatibility: set
`renderer/rendering_method.mobile` to `mobile` in the project settings.

Scene setup: two `SubViewportContainer` nodes each holding a `SubViewport`, plus a `Node` with
`AynThorManager.gd` that references them.

### Picking a layout when there is no second screen

`AynThorManager` exposes `has_second_screen` and `second_screen_availability_changed`. The manager
is a child node, so its `_ready()` runs *before* the parent's — read the current value after
connecting rather than relying on the initial emission:

```gdscript
func _ready() -> void:
	$DSManager.second_screen_availability_changed.connect(_apply_layout)
	_apply_layout($DSManager.has_second_screen)
```

### Debugging touch

Tick `touch_logging` on the manager node. It turns on two logs:

- Kotlin, via `adb logcat -s AynThor`: one line per `MotionEvent`, with the raw coordinates and the
  `SurfaceView` size. Lines here mean Android is delivering touches to the presentation window.
  No lines at all would mean the device is not routing its digitizer to the secondary display,
  which no app-side change can fix. (On an Ayn Thor it does route them — display 4 reports
  `touch EXTERNAL` in `dumpsys display`.)
- GDScript, in the editor's remote debug console: the raw position, the surface size, and the
  mapped viewport position. Tap a control you can see and check that the mapped position falls
  inside it. If it is mirrored, the render rotation and the touch mapping disagree — change
  `rotation_degrees`, which carries the mapping with it.
