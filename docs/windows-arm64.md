# Windows ARM64

This build path targets native Windows ARM64 (`aarch64-pc-windows-msvc`).
It builds the Rust music service and FFmpeg, uses the ARM64 WebView2 loader,
and exports with Godot's ARM64 Windows template. Existing x64 builds keep
their MinGW toolchain and output directory.

## Build in GitHub Actions

Run the **Windows ARM64** workflow from the Actions tab. It also runs on pushes
to `windows-arm64` and relevant pull requests. Download the
`Nari-windows-arm64` artifact after a successful run and extract both ZIP layers.
The workflow cross-compiles on Windows x64 with the ARM64 MSVC tools. A successful
build verifies binary architecture, but does not replace testing on an ARM PC.

## Build locally

Install these prerequisites:

- Python 3 and Rust, with `rustup target add aarch64-pc-windows-msvc`.
- Visual Studio C++ Build Tools with the ARM64 compiler/libraries and Windows SDK.
- LLVM with libclang; set `LIBCLANG_PATH` to its `bin` directory for bindgen.
- MSYS2 with `make`, `diffutils` and `pkgconf` installed in the MSYS environment.
- Ninja on PATH (Meson is downloaded automatically if it is not installed).
- Godot matching `GODOT_VERSION` in `scripts/common.py`, with its export templates.

Open a Visual Studio developer environment targeting ARM64 (either an ARM64 host
or an x64 host cross-compiling to ARM64). Set `MSYS2_BASH` to the full Windows
path of MSYS2's `usr/bin/bash.exe`, and set `GODOT` to the Godot editor executable.
Then run:

```text
python scripts/build.py plugins-windows-arm64
python scripts/build.py windows-arm64
```

The first command downloads checksum-verified FFmpeg, dav1d and libopenmpt sources,
builds the native dependencies, and stages them in
`addons/MusicService/bin/windows/arm64/`. FFmpeg and dav1d assembly are disabled for this
initial MSVC path to avoid requiring a separate assembler. dav1d is linked statically
into FFmpeg for AV1 decoding, and the Windows hardware-decoding options from `dev`
are enabled. The second command
creates `build/Nari-windows-arm64.zip`. Add `--debug` to export a debug executable.
These targets are explicit: the existing `all` build is unchanged because it
uses a different toolchain environment.

The exporter rejects missing libraries and non-ARM64 PE files before packaging,
including an accidentally copied x64 WebView2 loader. The Android-only AynThor
extension is excluded from desktop exports as in the existing presets.

## Validation before upstream submission

Run the build safeguard tests:

```text
python -m unittest discover -s scripts/tests -v
```

On Windows ARM64, launch the extracted application and check local playback,
seeking, gapless playback, effects, tracker/MIDI playback, WebView-based providers,
the tray, media controls, Discord presence, and restart. Check Task Manager's
Architecture column to confirm the application runs as ARM64.

The updater selects `Nari-windows-arm64.zip` for a native ARM64 executable. If an
upstream release does not yet contain that asset, it reports that no compatible
download is available instead of replacing the installation with x64. The release
source remains upstream; fork maintainers can distribute test builds as workflow
artifacts without changing the update source.

Do not describe ARM64 as tested or release-ready until the workflow and the
hardware checks have passed. No ARM64 prebuilt binaries are included in this patch.
