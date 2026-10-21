#!/usr/bin/env python3
import argparse
import os
import re
import shutil
import subprocess
import urllib.request
from pathlib import Path

import aynthor
import music_service
from common import GODOT_VERSION, JOBS, ROOT, extract_zip, fail, godot_config_dir, godot_data_dir, gradle, info, override_preset, run

TEMPLATE_VERSION = f"{GODOT_VERSION}.stable"


def required(name):
    value = os.environ.get(name)
    if not value:
        fail(f"{name} is not set")
    return Path(value).resolve()


def remove_prebuilt_binaries():
    info("Removing prebuilt binaries")
    for path in (ROOT / "addons").glob("*/bin/**/*"):
        if path.suffix in (".aar", ".so", ".dll"):
            path.unlink()


def build_godot(godot_src):
    info("Godot editor and Android templates")
    if not os.environ.get("GODOT_EDITOR"):
        run("scons", f"-j{JOBS}", "platform=linuxbsd", "target=editor", cwd=godot_src)
    run("scons", f"-j{JOBS}", "platform=android", "target=template_release", "arch=arm64", cwd=godot_src)
    run("scons", f"-j{JOBS}", "platform=android", "target=template_release", "arch=x86_64",
        "generate_android_binaries=yes", cwd=godot_src)
    return os.environ.get("GODOT_EDITOR") or godot_src / "bin" / "godot.linuxbsd.editor.x86_64"


def godot_ndk_version(godot_src):
    detect = (godot_src / "platform" / "android" / "detect.py").read_text()
    match = re.search(r'def get_ndk_version\(\)[^\n]*\n\s*return "([^"]+)"', detect)
    if not match:
        fail("couldn't read the NDK version from Godot's platform/android/detect.py")
    return match.group(1)


def ensure_rust():
    if shutil.which("cargo"):
        return
    info("Installing Rust")
    with urllib.request.urlopen("https://sh.rustup.rs") as response:
        installer = response.read()
    subprocess.run(["sh", "-s", "--", "-y", "--profile", "minimal"], input=installer, check=True)
    os.environ["PATH"] = f"{Path.home() / '.cargo' / 'bin'}{os.pathsep}{os.environ['PATH']}"


def install_android_template(godot_src):
    info("Installing the Android build template")
    source_zip = godot_src / "bin" / "android_source.zip"
    templates = godot_data_dir() / "export_templates" / TEMPLATE_VERSION
    templates.mkdir(parents=True, exist_ok=True)
    shutil.copy(source_zip, templates)
    (templates / "version.txt").write_text(TEMPLATE_VERSION + "\n")

    android = ROOT / "android"
    shutil.rmtree(android, ignore_errors=True)
    (android / "build").mkdir(parents=True)
    extract_zip(source_zip, android / "build")
    (android / ".build_version").write_text(TEMPLATE_VERSION + "\n")
    (android / "build" / ".gdignore").touch()


def export_apk(godot, sdk, apk):
    info("Exporting")
    presets = ROOT / "export_presets.cfg"
    presets.write_text(override_preset(presets.read_text(), "Android", {"package/signed": "false", "custom_features": '"channel_fdroid"'}))

    settings = godot_config_dir() / f"editor_settings-{GODOT_VERSION.rsplit('.', 1)[0]}.tres"
    settings.parent.mkdir(parents=True, exist_ok=True)
    settings.write_text(
        '[gd_resource type="EditorSettings" format=3]\n\n'
        "[resource]\n"
        f'export/android/android_sdk_path = "{sdk}"\n'
        f'export/android/java_sdk_path = "{os.environ.get("JAVA_HOME", "")}"\n')

    run(godot, "--headless", "--path", ROOT, "--import", check=False)
    run(godot, "--headless", "--path", ROOT, "--import", check=False)
    run(godot, "--headless", "--path", ROOT, "--export-release", "Android", apk)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("apk", nargs="?", default="nari.apk", type=Path)
    apk = parser.parse_args().apk.resolve()

    godot_src = required("GODOT_SRC")
    sdk = required("ANDROID_HOME")
    os.environ["ANDROID_SDK_ROOT"] = str(sdk)
    os.environ["GODOT_CPP_PATH"] = str(required("GODOT_CPP"))
    ndk_version = godot_ndk_version(godot_src)
    os.environ["ANDROID_NDK_HOME"] = str(sdk / "ndk" / ndk_version)
    if os.environ.get("FFMPEG_SRC"):
        os.environ["FFMPEG_SOURCE"] = os.environ["FFMPEG_SRC"]
    if os.environ.get("DAV1D_SRC"):
        os.environ["DAV1D_SOURCE"] = os.environ["DAV1D_SRC"]

    remove_prebuilt_binaries()
    godot = build_godot(godot_src)

    info("AynThor native library")
    aynthor.prepare()
    aynthor.build_android(ndk_version)

    info("Nari native library")
    ensure_rust()
    run("rustup", "target", "add", "aarch64-linux-android", "x86_64-linux-android")
    music_service.build_android()

    info("Android plugin AARs")
    for plugin in ("AynThor", "MusicService"):
        run(gradle(), "assemble", "--no-daemon", cwd=ROOT / "addons" / plugin / "android")

    install_android_template(godot_src)
    export_apk(godot, sdk, apk)
    info(f"Done: {apk}")


if __name__ == "__main__":
    main()
