import hashlib
import os
import platform
import re
import shutil
from pathlib import Path

from common import (ROOT, JOBS, android_ndk, android_sdk, build_image, container_engine, download,
                    download_tarball, fail, gradle, info, output, outside_project, run, run_in_container, work_dir)

PLUGIN = ROOT / "addons" / "MusicService"
CRATE = PLUGIN / "native"
BIN = PLUGIN / "bin"
WORK = PLUGIN / ".build"

FFMPEG_VERSION = "8.0.1"
FFMPEG_SHA256 = "05ee0b03119b45c0bdb4df654b96802e909e0a752f72e4fe3794f487229e5a41"
OPENMPT_VERSION = "0.8.9"
OPENMPT_SHA256 = "9273b88b67973cc69e54d748ab1b749399d6d07695f1c37d0c59f88b4106074f"
MACOS_SDK_VERSION = "14.5"
MACOS_SDK_SHA256 = "6e146275d19f027faa2e8354da5e0267513abf013b8f16ad65a231653a2b1c5d"
WINDOWS_TARGET = "x86_64-pc-windows-gnu"
ANDROID_API = 26
LINUX_IMAGE = "music-service-linux-builder"
MACOS_IMAGE = "nari-macos-builder"
IN_CONTAINER = bool(os.environ.get("MUSIC_SERVICE_IN_CONTAINER"))

FFMPEG_LIBS = {"avutil": 60, "avcodec": 62, "avformat": 62, "swscale": 9}

FFMPEG_OPTIONS = [
    "--disable-static", "--enable-shared", "--enable-small", "--disable-programs", "--disable-doc", "--disable-debug",
    "--disable-x86asm", "--disable-gpl", "--disable-nonfree", "--disable-autodetect", "--disable-everything",
    "--disable-avdevice", "--disable-avfilter", "--disable-swresample", "--disable-network", "--disable-hwaccels",
    "--disable-bzlib", "--disable-iconv", "--disable-lzma", "--disable-zlib",
    "--enable-avcodec", "--enable-avformat", "--enable-avutil", "--enable-swscale",
    "--enable-protocol=file", "--enable-demuxer=mov", "--enable-demuxer=matroska",
    *[f"--enable-parser={name}" for name in ("h264", "hevc", "mpeg4video", "vp8", "vp9", "av1")],
    *[f"--enable-decoder={name}" for name in ("h264", "hevc", "mpeg4", "vp8", "vp9", "av1")],
]


def ffmpeg_source():
    return Path(os.environ.get("FFMPEG_SOURCE") or WORK / f"ffmpeg-{FFMPEG_VERSION}")


def openmpt_source():
    return Path(os.environ.get("OPENMPT_SOURCE") or WORK / "libopenmpt")


def fetch_sources():
    work_dir(WORK)
    ffmpeg = ffmpeg_source()
    if not (ffmpeg / "configure").exists():
        download_tarball(f"https://ffmpeg.org/releases/ffmpeg-{FFMPEG_VERSION}.tar.xz", ffmpeg, FFMPEG_SHA256)

    openmpt = openmpt_source()
    version_file = openmpt / ".version"
    if not version_file.exists() or version_file.read_text().strip() != OPENMPT_VERSION:
        shutil.rmtree(openmpt, ignore_errors=True)
        download_tarball(f"https://lib.openmpt.org/files/libopenmpt/src/libopenmpt-{OPENMPT_VERSION}+release.makefile.tar.gz", openmpt, OPENMPT_SHA256)
        version_file.write_text(OPENMPT_VERSION + "\n")
    os.environ["OPENMPT_SOURCE"] = str(openmpt)


def ffmpeg_prefix(name):
    return WORK / "ffmpeg" / name


def build_ffmpeg(name, *options, env=None):
    prefix = ffmpeg_prefix(name)
    if (prefix / "include").is_dir():
        return
    info(f"Building FFmpeg ({name})")
    build = WORK / "ffmpeg" / f"build-{name}"
    shutil.rmtree(build, ignore_errors=True)
    shutil.rmtree(prefix, ignore_errors=True)
    build.mkdir(parents=True)
    run(ffmpeg_source() / "configure", f"--prefix={prefix}", *FFMPEG_OPTIONS, *options, cwd=build, env=env)
    run("make", f"-j{JOBS}", cwd=build, env=env)
    run("make", "install", cwd=build, env=env)


def stage_ffmpeg(name, destination):
    prefix = ffmpeg_prefix(name)
    destination.mkdir(parents=True, exist_ok=True)
    for lib, major in FFMPEG_LIBS.items():
        if name.startswith("windows"):
            shutil.copy(prefix / "bin" / f"{lib}-{major}.dll", destination)
        elif name.startswith("android"):
            shutil.copy(prefix / "lib" / f"lib{lib}.so", destination)
        else:
            shutil.copy(prefix / "lib" / f"lib{lib}.so.{major}", destination)


def cargo_target_dir():
    return Path(os.environ.get("CARGO_TARGET_DIR") or CRATE / "target")


def cargo_build(*args, env=None):
    run("cargo", "build", "--release", *args, cwd=CRATE, env=env)


def container(engine, image, function, target_dir):
    fetch_sources()
    env = {
        "MUSIC_SERVICE_IN_CONTAINER": 1,
        "CARGO_HOME": CRATE / "target" / "container-cargo",
        "CARGO_TARGET_DIR": CRATE / "target" / target_dir,
        "FFMPEG_SOURCE": ffmpeg_source(),
        "OPENMPT_SOURCE": openmpt_source(),
    }
    mounts = [path for path in (ffmpeg_source(), openmpt_source()) if outside_project(path)]
    info(f"Running {function} inside {image}")
    run_in_container(engine, image, "music_service", function, env=env, mounts=mounts)


def linux_container(function):
    engine = container_engine()
    build_image(engine, LINUX_IMAGE, PLUGIN / "linux-builder.Containerfile")
    container(engine, LINUX_IMAGE, function, "container")


def build_linux():
    if not IN_CONTAINER:
        return linux_container("build_linux")

    target_dir = cargo_target_dir()
    build_ffmpeg("linux-x86_64")
    info(f"cargo build (linux x86_64, glibc {platform.libc_ver()[1]})")
    cargo_build("--workspace", env={"FFMPEG_DIR": ffmpeg_prefix("linux-x86_64")})
    for lib in ("libnari.so", "libnari_webview.so"):
        shutil.copy(target_dir / "release" / lib, BIN / "linux")
    stage_ffmpeg("linux-x86_64", BIN / "linux")

    build_ffmpeg("linux-arm64", "--enable-cross-compile", "--arch=aarch64", "--target-os=linux",
                 "--cross-prefix=aarch64-linux-gnu-")
    info("cargo build (linux arm64)")
    cargo_build("--workspace", "--target", "aarch64-unknown-linux-gnu", env={
        "FFMPEG_DIR": ffmpeg_prefix("linux-arm64"),
        "CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_LINKER": "aarch64-linux-gnu-gcc",
        "CC_aarch64_unknown_linux_gnu": "aarch64-linux-gnu-gcc",
        "CXX_aarch64_unknown_linux_gnu": "aarch64-linux-gnu-g++",
        "PKG_CONFIG_ALLOW_CROSS": 1,
        "PKG_CONFIG_PATH": "/usr/lib/aarch64-linux-gnu/pkgconfig:/opt/arm64-pkgconfig",
        "BINDGEN_EXTRA_CLANG_ARGS": "--sysroot=/usr/aarch64-linux-gnu",
    })
    for lib in ("libnari.so", "libnari_webview.so"):
        shutil.copy(target_dir / "aarch64-unknown-linux-gnu" / "release" / lib, BIN / "linux" / "arm64")
    stage_ffmpeg("linux-arm64", BIN / "linux" / "arm64")


def winpthread_dll():
    gcc = "x86_64-w64-mingw32-gcc"
    candidates = [
        Path(output(gcc, "-print-sysroot") or "/nonexistent") / "mingw" / "bin" / "libwinpthread-1.dll",
        Path(output(gcc, "-print-file-name=libwinpthread-1.dll")),
        Path("/usr/x86_64-w64-mingw32/sys-root/mingw/bin/libwinpthread-1.dll"),
        Path("/usr/x86_64-w64-mingw32/lib/libwinpthread-1.dll"),
    ]
    for candidate in candidates:
        if candidate.is_file():
            return candidate
    fail("libwinpthread-1.dll not found, is the MinGW toolchain installed?")


def build_windows():
    fetch_sources()
    build_ffmpeg("windows-x86_64", "--enable-cross-compile", "--arch=x86_64", "--target-os=mingw32",
                 "--cross-prefix=x86_64-w64-mingw32-")
    info("cargo build (windows)")
    cargo_build("--target", WINDOWS_TARGET, env={"FFMPEG_DIR": ffmpeg_prefix("windows-x86_64")})
    release = cargo_target_dir() / WINDOWS_TARGET / "release"
    shutil.copy(release / "nari.dll", BIN / "windows")
    loaders = sorted(release.glob("build/webview2-com-sys-*/out/x64/WebView2Loader.dll"))
    if not loaders:
        fail("WebView2Loader.dll not found in the cargo build output")
    shutil.copy(loaders[0], BIN / "windows")
    stage_ffmpeg("windows-x86_64", BIN / "windows")
    shutil.copy(winpthread_dll(), BIN / "windows")


def build_android():
    sdk = android_sdk()
    ndk = android_ndk(sdk)
    prebuilt = sorted((ndk / "toolchains" / "llvm" / "prebuilt").glob("*"))
    if not prebuilt:
        fail(f"{ndk} doesn't look like an NDK")
    toolchain = prebuilt[0]
    tools = toolchain / "bin"
    fetch_sources()

    for target, folder, arch in [("aarch64-linux-android", "arm64", "aarch64"), ("x86_64-linux-android", "x86_64", "x86_64")]:
        clang = tools / f"{target}{ANDROID_API}-clang"
        build_ffmpeg(f"android-{folder}", "--enable-cross-compile", "--target-os=android", f"--arch={arch}",
                     f"--cross-prefix={tools / target}-", f"--cc={clang}", f"--cxx={clang}++",
                     f"--ar={tools / 'llvm-ar'}", f"--ranlib={tools / 'llvm-ranlib'}", f"--nm={tools / 'llvm-nm'}",
                     f"--strip={tools / 'llvm-strip'}", f"--sysroot={toolchain / 'sysroot'}")
        info(f"cargo build (android {folder})")
        variable = target.replace("-", "_")
        cargo_build("--target", target, env={
            "FFMPEG_DIR": ffmpeg_prefix(f"android-{folder}"),
            f"CC_{variable}": clang,
            f"CXX_{variable}": f"{clang}++",
            f"AR_{variable}": tools / "llvm-ar",
            f"CXXSTDLIB_{variable}": "c++_static",
            f"BINDGEN_EXTRA_CLANG_ARGS_{variable}": f"--sysroot={toolchain / 'sysroot'} --target={target}{ANDROID_API}",
            f"CARGO_TARGET_{variable.upper()}_LINKER": clang,
            f"CARGO_TARGET_{variable.upper()}_RUSTFLAGS": "-C link-arg=-lc++abi",
        })
        out = BIN / "android" / folder
        out.mkdir(parents=True, exist_ok=True)
        shutil.copy(cargo_target_dir() / target / "release" / "libnari.so", out)
        stage_ffmpeg(f"android-{folder}", out)


def macos_image(engine):
    sdk_dir = work_dir(WORK) / "macos-sdk"
    sdk = sdk_dir / f"MacOSX{MACOS_SDK_VERSION}.sdk.tar.xz"
    if not sdk.exists():
        download(f"https://github.com/joseluisq/macosx-sdks/releases/download/{MACOS_SDK_VERSION}/{sdk.name}", sdk)
    if hashlib.sha256(sdk.read_bytes()).hexdigest() != MACOS_SDK_SHA256:
        fail(f"{sdk} doesn't match its sha256, delete it and try again")
    build_image(engine, MACOS_IMAGE, PLUGIN / "macos-builder.Containerfile", sdk_dir)


def build_macos():
    if not IN_CONTAINER:
        engine = container_engine()
        macos_image(engine)
        return container(engine, MACOS_IMAGE, "build_macos", "container-macos")

    osxcross = Path(os.environ["OSXCROSS_ROOT"]) / "target"
    darwin = next(match.group(1) for name in os.listdir(osxcross / "bin")
                  if (match := re.fullmatch(r"x86_64-apple-(darwin[\d.]*)-clang", name)))
    sdk = next((osxcross / "SDK").glob("MacOSX*.sdk"))
    lipo = f"x86_64-apple-{darwin}-lipo"
    install_name_tool = f"x86_64-apple-{darwin}-install_name_tool"
    out = BIN / "macos"
    out.mkdir(parents=True, exist_ok=True)

    for target, folder, arch, minimum in [("x86_64-apple-darwin", "x86_64", "x86_64", "10.15"),
                                          ("aarch64-apple-darwin", "arm64", "aarch64", "11.0")]:
        prefix = f"{arch}-apple-{darwin}"
        env = {"MACOSX_DEPLOYMENT_TARGET": minimum}
        build_ffmpeg(f"macos-{folder}", "--enable-cross-compile", "--target-os=darwin", f"--arch={arch}",
                     f"--cc={prefix}-clang", f"--cxx={prefix}-clang++", f"--ar={prefix}-ar", f"--ranlib={prefix}-ranlib",
                     f"--nm={prefix}-nm", f"--strip={prefix}-strip",
                     f"--extra-cflags=-mmacosx-version-min={minimum}", f"--extra-ldflags=-mmacosx-version-min={minimum}", env=env)
        info(f"cargo build (macos {folder})")
        variable = target.replace("-", "_")
        cargo_build("--target", target, env={
            **env,
            "FFMPEG_DIR": ffmpeg_prefix(f"macos-{folder}"),
            f"CC_{variable}": f"{prefix}-clang",
            f"CXX_{variable}": f"{prefix}-clang++",
            f"AR_{variable}": f"{prefix}-ar",
            f"CARGO_TARGET_{variable.upper()}_LINKER": f"{prefix}-clang",
            f"BINDGEN_EXTRA_CLANG_ARGS_{variable}": f"--sysroot={sdk} -isystem {sdk}/usr/include --target={target}",
        })

    info("lipo (macos universal)")
    target_dir = cargo_target_dir()
    run(lipo, "-create", "-output", out / "libnari.macos.dylib",
        target_dir / "x86_64-apple-darwin/release/libnari.dylib", target_dir / "aarch64-apple-darwin/release/libnari.dylib")
    dylibs = [f"lib{lib}.{major}.dylib" for lib, major in FFMPEG_LIBS.items()]
    for dylib in dylibs:
        run(lipo, "-create", "-output", out / dylib,
            ffmpeg_prefix("macos-x86_64") / "lib" / dylib, ffmpeg_prefix("macos-arm64") / "lib" / dylib)

    for file in out.glob("*.dylib"):
        run(install_name_tool, "-id", f"@loader_path/{file.name}", file)
        for dylib in dylibs:
            for folder in ("macos-x86_64", "macos-arm64"):
                output(install_name_tool, "-change", ffmpeg_prefix(folder) / "lib" / dylib, f"@loader_path/{dylib}", file)


def build_aar():
    gradle_binary = gradle()
    info(f"Building the MusicService AAR with {gradle_binary}")
    run(gradle_binary, "assemble", "--no-daemon", cwd=PLUGIN / "android")


def test():
    if not IN_CONTAINER:
        return linux_container("test")
    build_ffmpeg("linux-x86_64")
    info("cargo test")
    lib = ffmpeg_prefix("linux-x86_64")
    run("cargo", "test", cwd=CRATE, env={"FFMPEG_DIR": lib, "LD_LIBRARY_PATH": lib / "lib"})


def build():
    (BIN / "linux" / "arm64").mkdir(parents=True, exist_ok=True)
    (BIN / "windows").mkdir(parents=True, exist_ok=True)
    test()
    build_linux()
    build_windows()
    build_android()
    build_macos()
    build_aar()
