import hashlib
import os
import platform
import re
import shutil
import struct
import sys
from pathlib import Path

from common import (ROOT, JOBS, android_ndk, android_sdk, build_image, container_engine, download, download_tarball,
                    extract_zip, fail, gradle, info, output, outside_project, run, run_in_container, work_dir)

PLUGIN = ROOT / "addons" / "MusicService"
CRATE = PLUGIN / "native"
BIN = PLUGIN / "bin"
WORK = PLUGIN / ".build"

FFMPEG_VERSION = "8.0.1"
FFMPEG_SHA256 = "05ee0b03119b45c0bdb4df654b96802e909e0a752f72e4fe3794f487229e5a41"
DAV1D_VERSION = "1.5.4"
DAV1D_SHA256 = "686616b7c69eb88d44459391ab25cac13b6647a3b288835c5784e71c1514a5c5"
MESON_VERSION = "1.12.1"
MESON_SHA256 = "ab0a6ca09f8ef70c564c8241fb5a23957886a0b53fb58412b5e07eaf07dba743"
NINJA_VERSION = "1.13.2"
NINJA_BUILDS = {
    "x86_64": ("ninja-linux.zip", "5749cbc4e668273514150a80e387a957f933c6ed3f5f11e03fb30955e2bbead6"),
    "aarch64": ("ninja-linux-aarch64.zip", "fd2cacc8050a7f12a16a2e48f9e06fca5c14fc4c2bee2babb67b58be17a607fc"),
}
OPENMPT_VERSION = "0.8.9"
OPENMPT_SHA256 = "9273b88b67973cc69e54d748ab1b749399d6d07695f1c37d0c59f88b4106074f"
MACOS_SDK_VERSION = "14.5"
MACOS_SDK_SHA256 = "6e146275d19f027faa2e8354da5e0267513abf013b8f16ad65a231653a2b1c5d"
IOS_SDK_VERSION = "26.5"
IOS_SDK_SHA256 = "bed0f155d84e98ad8273b3bd57a0816ae5e772e1aa8539e6d79476221ce33173"
IOS_TARGET = "aarch64-apple-ios"
IOS_MINIMUM = "17.0"
WINDOWS_TARGET = "x86_64-pc-windows-gnu"
WINDOWS_ARM64_TARGET = "aarch64-pc-windows-msvc"
ANDROID_API = 26
LINUX_IMAGE = "music-service-linux-builder"
MACOS_IMAGE = "nari-macos-builder"
IOS_IMAGE = "nari-ios-builder"
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

ANDROID_FFMPEG_OPTIONS = [
    "--enable-jni", "--enable-mediacodec",
    *[f"--enable-decoder={name}_mediacodec" for name in ("h264", "hevc", "mpeg4", "vp8", "vp9", "av1")],
]
WINDOWS_FFMPEG_OPTIONS = [
    "--enable-d3d11va", "--enable-dxva2",
    *[f"--enable-hwaccel={name}_{api}" for name in ("h264", "hevc", "vp9", "av1") for api in ("d3d11va", "d3d11va2", "dxva2")],
]
MACOS_FFMPEG_OPTIONS = [
    "--enable-videotoolbox",
    *[f"--enable-hwaccel={name}_videotoolbox" for name in ("h264", "hevc", "mpeg4", "vp9", "av1")],
]


def ffmpeg_source():
    return Path(os.environ.get("FFMPEG_SOURCE") or WORK / f"ffmpeg-{FFMPEG_VERSION}")


def dav1d_source():
    return Path(os.environ.get("DAV1D_SOURCE") or WORK / f"dav1d-{DAV1D_VERSION}")


def openmpt_source():
    return Path(os.environ.get("OPENMPT_SOURCE") or WORK / "libopenmpt")


def fetch_sources():
    work_dir(WORK)
    ffmpeg = ffmpeg_source()
    if not (ffmpeg / "configure").exists():
        download_tarball(f"https://ffmpeg.org/releases/ffmpeg-{FFMPEG_VERSION}.tar.xz", ffmpeg, FFMPEG_SHA256)

    dav1d = dav1d_source()
    if not (dav1d / "meson.build").exists():
        download_tarball(f"https://downloads.videolan.org/pub/videolan/dav1d/{DAV1D_VERSION}/dav1d-{DAV1D_VERSION}.tar.xz", dav1d, DAV1D_SHA256)

    openmpt = openmpt_source()
    version_file = openmpt / ".version"
    if not version_file.exists() or version_file.read_text().strip() != OPENMPT_VERSION:
        shutil.rmtree(openmpt, ignore_errors=True)
        download_tarball(f"https://lib.openmpt.org/files/libopenmpt/src/libopenmpt-{OPENMPT_VERSION}+release.makefile.tar.gz", openmpt, OPENMPT_SHA256)
        version_file.write_text(OPENMPT_VERSION + "\n")
    os.environ["OPENMPT_SOURCE"] = str(openmpt)


def meson():
    found = os.environ.get("MESON") or shutil.which("meson")
    if found:
        return [found]
    source = WORK / f"meson-{MESON_VERSION}"
    if not (source / "meson.py").exists():
        download_tarball(f"https://files.pythonhosted.org/packages/source/m/meson/meson-{MESON_VERSION}.tar.gz", source, MESON_SHA256)
    return [sys.executable, source / "meson.py"]


def ninja():
    found = os.environ.get("NINJA") or shutil.which("ninja")
    if found:
        return Path(found)
    binary = WORK / f"ninja-{NINJA_VERSION}" / "ninja"
    if not binary.exists():
        name, sha256 = NINJA_BUILDS["aarch64" if platform.machine() in ("aarch64", "arm64") else "x86_64"]
        archive = download(f"https://github.com/ninja-build/ninja/releases/download/v{NINJA_VERSION}/{name}", binary.parent / name)
        if hashlib.sha256(archive.read_bytes()).hexdigest() != sha256:
            archive.unlink()
            fail(f"{name} doesn't match its sha256")
        extract_zip(archive, binary.parent)
        archive.unlink()
    return binary


def meson_cross_file(system, cpu, c, ar, ranlib, strip, flags=(), link_flags=()):
    listed = lambda values: "[" + ", ".join(f"'{value}'" for value in values) + "]"
    return (f"[binaries]\nc = {listed([c])}\nar = '{ar}'\nranlib = '{ranlib}'\nstrip = '{strip}'\n\n"
            f"[built-in options]\nc_args = {listed(flags)}\nc_link_args = {listed([*flags, *link_flags])}\n\n"
            f"[host_machine]\nsystem = '{system}'\ncpu_family = '{cpu}'\ncpu = '{cpu}'\nendian = 'little'\n")


def build_dav1d(name, cpu, cross=None, env=None):
    prefix = WORK / "dav1d" / name
    assembly = cpu == "aarch64" or shutil.which("nasm") is not None
    options = [f"--prefix={prefix}", "--libdir=lib", "--buildtype=release", "--default-library=static",
               "-Denable_tools=false", "-Denable_tests=false", "-Denable_examples=false", f"-Denable_asm={str(assembly).lower()}"]
    cross_file = meson_cross_file(cpu=cpu, **cross) if cross else ""
    configuration = "\n".join([*options, cross_file])
    stamp = prefix / "options.txt"
    if (prefix / "lib" / "pkgconfig" / "dav1d.pc").is_file() and stamp.is_file() and stamp.read_text() == configuration:
        return prefix
    info(f"Building dav1d ({name})")
    build = WORK / "dav1d" / f"build-{name}"
    shutil.rmtree(build, ignore_errors=True)
    shutil.rmtree(prefix, ignore_errors=True)
    build.mkdir(parents=True)
    if cross:
        (build / "cross.ini").write_text(cross_file)
        options += ["--cross-file", build / "cross.ini"]
    tools = {**(env or {}), "NINJA": ninja()}
    run(*meson(), "setup", build, dav1d_source(), *options, env=tools)
    run(tools["NINJA"], "-C", build, f"-j{JOBS}", "install", env=tools)
    stamp.write_text(configuration)
    return prefix


def ffmpeg_prefix(name):
    return WORK / "ffmpeg" / name


def build_ffmpeg(name, *options, dav1d=None, env=None):
    prefix = ffmpeg_prefix(name)
    if dav1d:
        options = (*options, "--enable-libdav1d", "--enable-decoder=libdav1d", "--pkg-config=pkg-config", "--pkg-config-flags=--static")
        env = {**(env or {}), "PKG_CONFIG_LIBDIR": dav1d / "lib" / "pkgconfig"}
    configuration = "\n".join(map(str, [*FFMPEG_OPTIONS, *options]))
    stamp = prefix / "options.txt"
    if (prefix / "include").is_dir() and stamp.is_file() and stamp.read_text() == configuration:
        return
    info(f"Building FFmpeg ({name})")
    build = WORK / "ffmpeg" / f"build-{name}"
    shutil.rmtree(build, ignore_errors=True)
    shutil.rmtree(prefix, ignore_errors=True)
    build.mkdir(parents=True)
    run(ffmpeg_source() / "configure", f"--prefix={prefix}", *FFMPEG_OPTIONS, *options, cwd=build, env=env)
    run("make", f"-j{JOBS}", cwd=build, env=env)
    run("make", "install", cwd=build, env=env)
    stamp.write_text(configuration)


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
    run("cargo", "build", "--release", "-j", JOBS, *args, cwd=CRATE, env=env)


def container(engine, image, function, target_dir):
    fetch_sources()
    env = {
        "MUSIC_SERVICE_IN_CONTAINER": 1,
        "CARGO_HOME": CRATE / "target" / "container-cargo",
        "CARGO_TARGET_DIR": CRATE / "target" / target_dir,
        "FFMPEG_SOURCE": ffmpeg_source(),
        "DAV1D_SOURCE": dav1d_source(),
        "OPENMPT_SOURCE": openmpt_source(),
    }
    mounts = [path for path in (ffmpeg_source(), dav1d_source(), openmpt_source()) if outside_project(path)]
    info(f"Running {function} inside {image}")
    run_in_container(engine, image, "music_service", function, env=env, mounts=mounts)


def linux_container(function):
    engine = container_engine()
    build_image(engine, LINUX_IMAGE, PLUGIN / "linux-builder.Containerfile")
    container(engine, LINUX_IMAGE, function, "container")


def build_linux_ffmpeg():
    build_ffmpeg("linux-x86_64", dav1d=build_dav1d("linux-x86_64", "x86_64"))


def build_linux():
    if not IN_CONTAINER:
        return linux_container("build_linux")

    target_dir = cargo_target_dir()
    build_linux_ffmpeg()
    info(f"cargo build (linux x86_64, glibc {platform.libc_ver()[1]})")
    cargo_build("--workspace", env={"FFMPEG_DIR": ffmpeg_prefix("linux-x86_64")})
    for lib in ("libnari.so", "libnari_webview.so"):
        shutil.copy(target_dir / "release" / lib, BIN / "linux")
    stage_ffmpeg("linux-x86_64", BIN / "linux")

    arm64_dav1d = build_dav1d("linux-arm64", "aarch64", cross={
        "system": "linux", "c": "aarch64-linux-gnu-gcc", "ar": "aarch64-linux-gnu-ar", "ranlib": "aarch64-linux-gnu-ranlib",
        "strip": "aarch64-linux-gnu-strip"})
    build_ffmpeg("linux-arm64", "--enable-cross-compile", "--arch=aarch64", "--target-os=linux",
                 "--cross-prefix=aarch64-linux-gnu-", dav1d=arm64_dav1d)
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
    windows_dav1d = build_dav1d("windows-x86_64", "x86_64", cross={
        "system": "windows", "c": "x86_64-w64-mingw32-gcc", "ar": "x86_64-w64-mingw32-ar", "ranlib": "x86_64-w64-mingw32-ranlib",
        "strip": "x86_64-w64-mingw32-strip"})
    build_ffmpeg("windows-x86_64", "--enable-cross-compile", "--arch=x86_64", "--target-os=mingw32",
                 "--cross-prefix=x86_64-w64-mingw32-", *WINDOWS_FFMPEG_OPTIONS, dav1d=windows_dav1d)
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


def validate_arm64_files(files):
    """Reject missing, malformed, x64 and ARM64EC binaries before packaging."""
    for path in files:
        try:
            with Path(path).open("rb") as binary:
                if binary.read(2) != b"MZ":
                    raise ValueError("missing DOS header")
                binary.seek(0x3C)
                offset, = struct.unpack("<I", binary.read(4))
                binary.seek(offset)
                if binary.read(4) != b"PE\0\0":
                    raise ValueError("missing PE header")
                machine, = struct.unpack("<H", binary.read(2))
                if machine != 0xAA64:
                    raise ValueError(f"machine 0x{machine:04X}, expected ARM64 (0xAA64)")
        except (OSError, ValueError, struct.error) as error:
            fail(f"{path}: {error}. Rebuild with `just build plugins-windows-arm64`.")


def validate_windows_arm64():
    out = BIN / "windows" / "arm64"
    required = ["nari.dll", "WebView2Loader.dll", *[f"{lib}-{major}.dll" for lib, major in FFMPEG_LIBS.items()]]
    validate_arm64_files([out / name for name in required])
    validate_arm64_files(out.glob("*.dll"))


def build_windows_arm64_dav1d():
    prefix = WORK / "dav1d/windows-arm64"
    build = WORK / "dav1d/build-windows-arm64"
    info("Building dav1d (Windows ARM64 MSVC)")
    options = [f"--prefix={prefix}", "--libdir=lib", "--buildtype=release", "--default-library=static",
               "-Db_vscrt=md", "-Denable_tools=false", "-Denable_tests=false", "-Denable_examples=false",
               "-Denable_asm=false", "--cross-file", ROOT / "scripts/windows_arm64_msvc.ini"]
    tools = {"NINJA": ninja()}
    reconfigure = ["--reconfigure"] if (build / "build.ninja").exists() else []
    run(*meson(), "setup", *reconfigure, build, dav1d_source(), *options, env=tools)
    run(tools["NINJA"], "-C", build, f"-j{JOBS}", "install", env=tools)
    # dav1d deliberately uses the .a suffix even for MSVC COFF archives.
    shutil.copy(prefix / "lib/libdav1d.a", prefix / "lib/dav1d.lib")
    return prefix


def build_windows_arm64_ffmpeg():
    if platform.system() != "Windows":
        fail("Windows ARM64 uses MSVC: run this target from a Windows ARM64 developer environment")
    for tool in ("cargo", "cl", "link"):
        if not shutil.which(tool):
            fail(f"{tool} not found: install Rust and the MSVC ARM64 C++ tools, then open an ARM64 developer prompt")
    bash = os.environ.get("MSYS2_BASH")
    if not bash or not Path(bash).is_file():
        fail("Set MSYS2_BASH to MSYS2's usr/bin/bash.exe (with make, diffutils and pkgconf installed)")
    fetch_sources()
    dav1d = build_windows_arm64_dav1d()
    prefix = ffmpeg_prefix("windows-arm64")
    # MSVC FFmpeg needs a POSIX shell; Cargo and cc-rs use the developer environment directly.
    run(bash, ROOT / "scripts/windows_arm64_ffmpeg.sh", ffmpeg_source(),
        WORK / "ffmpeg/build-windows-arm64", prefix, str(JOBS), dav1d,
        *FFMPEG_OPTIONS, *WINDOWS_FFMPEG_OPTIONS,
        "--enable-libdav1d", "--enable-decoder=libdav1d", "--pkg-config=pkg-config", "--pkg-config-flags=--static",
        env={"MSVC_BIN": str(Path(shutil.which("cl")).parent)})
    # FFmpeg installs MSVC import libraries beside the DLLs; ffmpeg-sys searches lib/.
    (prefix / "lib").mkdir(parents=True, exist_ok=True)
    for lib in FFMPEG_LIBS:
        shutil.copy(prefix / "bin" / f"{lib}.lib", prefix / "lib")
    return prefix


def build_windows_arm64():
    build_windows_arm64_ffmpeg()
    build_windows_arm64_service()


def build_windows_arm64_service():
    prefix = ffmpeg_prefix("windows-arm64")
    cargo_build("--locked", "--target", WINDOWS_ARM64_TARGET,
                env={"FFMPEG_DIR": prefix, "OPENMPT_SOURCE": openmpt_source()})
    release = cargo_target_dir() / WINDOWS_ARM64_TARGET / "release"
    out = BIN / "windows" / "arm64"
    out.mkdir(parents=True, exist_ok=True)
    loaders = sorted(release.glob("build/webview2-com-sys-*/out/arm64/WebView2Loader.dll"),
                     key=lambda path: path.stat().st_mtime, reverse=True)
    if not loaders:
        fail("ARM64 WebView2Loader.dll not found in the Cargo build output")
    shutil.copy(release / "nari.dll", out)
    shutil.copy(loaders[0], out)
    stage_ffmpeg("windows-arm64", out)
    validate_windows_arm64()


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
        android_dav1d = build_dav1d(f"android-{folder}", arch, cross={
            "system": "android", "c": clang, "ar": tools / "llvm-ar", "ranlib": tools / "llvm-ranlib", "strip": tools / "llvm-strip"})
        build_ffmpeg(f"android-{folder}", "--enable-cross-compile", "--target-os=android", f"--arch={arch}",
                     f"--cross-prefix={tools / target}-", f"--cc={clang}", f"--cxx={clang}++",
                     f"--ar={tools / 'llvm-ar'}", f"--ranlib={tools / 'llvm-ranlib'}", f"--nm={tools / 'llvm-nm'}",
                     f"--strip={tools / 'llvm-strip'}", f"--sysroot={toolchain / 'sysroot'}", *ANDROID_FFMPEG_OPTIONS,
                     dav1d=android_dav1d)
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
        macos_dav1d = build_dav1d(f"macos-{folder}", arch, env=env, cross={
            "system": "darwin", "c": f"{prefix}-clang", "ar": f"{prefix}-ar", "ranlib": f"{prefix}-ranlib", "strip": f"{prefix}-strip",
            "flags": [f"-mmacosx-version-min={minimum}"]})
        build_ffmpeg(f"macos-{folder}", "--enable-cross-compile", "--target-os=darwin", f"--arch={arch}",
                     f"--cc={prefix}-clang", f"--cxx={prefix}-clang++", f"--ar={prefix}-ar", f"--ranlib={prefix}-ranlib",
                     f"--nm={prefix}-nm", f"--strip={prefix}-strip",
                     f"--extra-cflags=-mmacosx-version-min={minimum}", f"--extra-ldflags=-mmacosx-version-min={minimum}",
                     *MACOS_FFMPEG_OPTIONS, dav1d=macos_dav1d, env=env)
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


def ios_image(engine):
    macos_image(engine)
    sdk_dir = work_dir(WORK) / "ios-sdk"
    sdk = sdk_dir / f"iPhoneOS{IOS_SDK_VERSION}.sdk.zip"
    if not sdk.exists():
        download(f"https://github.com/xybp888/iOS-SDKs/releases/download/iOS{IOS_SDK_VERSION}-SDKs/{sdk.name}", sdk)
    if hashlib.sha256(sdk.read_bytes()).hexdigest() != IOS_SDK_SHA256:
        fail(f"{sdk} doesn't match its sha256, delete it and try again")
    build_image(engine, IOS_IMAGE, PLUGIN / "ios-builder.Containerfile", sdk_dir)


def build_ios():
    if not IN_CONTAINER:
        engine = container_engine()
        ios_image(engine)
        return container(engine, IOS_IMAGE, "build_ios", "container-ios")

    sdk = os.environ["IOS_SDK"]
    flags = [f"--target=arm64-apple-ios{IOS_MINIMUM}", f"-isysroot{sdk}"]
    dav1d = build_dav1d("ios-arm64", "aarch64", cross={
        "system": "darwin", "c": "clang", "ar": "llvm-ar", "ranlib": "llvm-ranlib", "strip": "llvm-strip",
        "flags": flags, "link_flags": ["-fuse-ld=lld"]})
    build_ffmpeg("ios-arm64", "--enable-cross-compile", "--target-os=darwin", "--arch=aarch64",
                 "--cc=clang", "--cxx=clang++", "--ar=llvm-ar", "--ranlib=llvm-ranlib", "--nm=llvm-nm", "--strip=llvm-strip",
                 f"--extra-cflags={' '.join(flags)}", f"--extra-ldflags={' '.join(flags)} -fuse-ld=lld",
                 "--disable-shared", "--enable-static", *MACOS_FFMPEG_OPTIONS, dav1d=dav1d)
    info("cargo build (ios arm64)")
    frameworks = ["VideoToolbox", "CoreMedia", "CoreVideo", "CoreFoundation", "CoreServices", "Security"]
    link = [*flags, "-fuse-ld=lld", f"-L{dav1d / 'lib'}", "-ldav1d", *[part for name in frameworks for part in ("-framework", name)]]
    cargo_build("--target", IOS_TARGET, env={
        "SDKROOT": sdk,
        "IPHONEOS_DEPLOYMENT_TARGET": IOS_MINIMUM,
        "FFMPEG_DIR": ffmpeg_prefix("ios-arm64"),
        "CC_aarch64_apple_ios": "clang",
        "CXX_aarch64_apple_ios": "clang++",
        "AR_aarch64_apple_ios": "llvm-ar",
        "CFLAGS_aarch64_apple_ios": " ".join(flags),
        "CXXFLAGS_aarch64_apple_ios": " ".join(flags),
        "CARGO_TARGET_AARCH64_APPLE_IOS_LINKER": "clang",
        "CARGO_TARGET_AARCH64_APPLE_IOS_RUSTFLAGS": " ".join(f"-Clink-arg={part}" for part in link),
        "BINDGEN_EXTRA_CLANG_ARGS_aarch64_apple_ios": f"--sysroot={sdk} -isystem {sdk}/usr/include --target=arm64-apple-ios{IOS_MINIMUM}",
    })

    framework = BIN / "ios" / "libnari.framework"
    shutil.rmtree(framework, ignore_errors=True)
    framework.mkdir(parents=True)
    shutil.copy(cargo_target_dir() / IOS_TARGET / "release" / "libnari.dylib", framework / "libnari")
    run("llvm-install-name-tool", "-id", "@rpath/libnari.framework/libnari", framework / "libnari")
    (framework / "Info.plist").write_text(
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
        '<plist version="1.0">\n<dict>\n'
        '\t<key>CFBundleExecutable</key>\n\t<string>libnari</string>\n'
        '\t<key>CFBundleIdentifier</key>\n\t<string>io.github.navivani-dev.nari.libnari</string>\n'
        '\t<key>CFBundleName</key>\n\t<string>libnari</string>\n'
        '\t<key>CFBundlePackageType</key>\n\t<string>FMWK</string>\n'
        '\t<key>CFBundleShortVersionString</key>\n\t<string>1.0</string>\n'
        '\t<key>CFBundleVersion</key>\n\t<string>1</string>\n'
        '\t<key>CFBundleSupportedPlatforms</key>\n\t<array>\n\t\t<string>iPhoneOS</string>\n\t</array>\n'
        f'\t<key>MinimumOSVersion</key>\n\t<string>{IOS_MINIMUM}</string>\n'
        '</dict>\n</plist>\n')


def build_aar():
    gradle_binary = gradle()
    info(f"Building the MusicService AAR with {gradle_binary}")
    run(gradle_binary, "assemble", "--no-daemon", cwd=PLUGIN / "android")


def test():
    if not IN_CONTAINER:
        return linux_container("test")
    build_linux_ffmpeg()
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
    build_ios()
    build_aar()
