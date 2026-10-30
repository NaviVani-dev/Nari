#!/usr/bin/env python3
import argparse
import base64
import hashlib
import json
import os
import platform
import re
import shutil
import subprocess
import sys
import venv

import aynthor
import ios
import metadata
import music_service
from common import BUILD, ROOT, TOOLS, download, extract_zip, fail, godot, info, preset_overrides, run, warn, work_dir

CARGO_GENERATOR = ("https://raw.githubusercontent.com/flatpak/flatpak-builder-tools/"
                   "74697c75b630d7330e77250fc13cb5ea688d9479/cargo/flatpak-cargo-generator.py")

DESKTOP = {
    "linux": ("Linux (x64)", "Nari-linux-x64.zip", "Nari.zip"),
    "linux-arm64": ("Linux (arm64)", "Nari-linux-arm.zip", "Nari.zip"),
    "windows": ("Windows (x64)", "Nari-windows.zip", "Nari.exe"),
    "windows-arm64": ("Windows (arm64)", "Nari-windows-arm64.zip", "Nari.exe"),
    "macos": ("macOS", "Nari-macos.zip", "Nari.zip"),
}
LINUX_ARCHITECTURES = {"linux": ("amd64", "x86_64"), "linux-arm64": ("arm64", "aarch64")}
APPIMAGETOOL = "https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-{}.AppImage"
# ARM64 Windows uses a separate MSVC environment; keep it opt-in.
ALL = ["metadata", "plugins", *[target for target in DESKTOP if target != "windows-arm64"], "android", "aab", "ios", "pck"]
FLATPAK_URL = "https://cdn.narimusic.com/flatpak/repo/"
FLATHUB_REPO = "https://flathub.org/repo/flathub.flatpakrepo"
FLATPAK_SKIP = [
    ".git", ".godot", "build", "android",
    "addons/MusicService/native/target", "addons/MusicService/.build", "addons/MusicService/bin",
    "addons/MusicService/android/.gradle", "addons/MusicService/android/build", "addons/MusicService/android/plugin/build",
    "addons/AynThor/.build", "addons/AynThor/bin", "addons/AynThor/native",
    "addons/AynThor/android/.gradle", "addons/AynThor/android/build", "addons/AynThor/android/plugin/build",
]
SIDELOAD_PERMISSIONS = 'PackedStringArray("android.permission.REQUEST_INSTALL_PACKAGES")'
KEYSTORE_VARIABLES = ["GODOT_ANDROID_KEYSTORE_RELEASE_PATH", "GODOT_ANDROID_KEYSTORE_RELEASE_USER", "GODOT_ANDROID_KEYSTORE_RELEASE_PASSWORD"]


def godot_export(preset, destination, debug=False, channel="github", options=None):
    info(f"Exporting {preset} -> {destination.relative_to(ROOT)}")
    destination.parent.mkdir(parents=True, exist_ok=True)
    with preset_overrides(preset, {"custom_features": f'"channel_{channel}"', **(options or {})}):
        run(godot(), "--headless", "--path", ROOT, "--export-debug" if debug else "--export-release", preset, destination)


def export_desktop(target, debug):
    if target == "windows-arm64":
        music_service.validate_windows_arm64()
    preset, archive, exported = DESKTOP[target]
    staging = BUILD / "staging" / target
    shutil.rmtree(staging, ignore_errors=True)
    godot_export(preset, staging / exported, debug)
    if target == "windows-arm64":
        music_service.validate_arm64_files([staging / exported, *staging.rglob("*.dll")])
        for notice in ("FFMPEG-NOTICE.txt", "DAV1D-COPYING.txt"):
            shutil.copy(music_service.BIN / notice, staging)
    (BUILD / archive).unlink(missing_ok=True)
    if exported.endswith(".zip"):
        shutil.move(staging / exported, BUILD / archive)
    else:
        shutil.make_archive(str(BUILD / archive.removesuffix(".zip")), "zip", staging)
    shutil.rmtree(BUILD / "staging")
    info(f"Packed build/{archive}")
    if target in LINUX_ARCHITECTURES:
        build_deb(target, BUILD / archive)
        build_appimage(target, BUILD / archive)


def stage_linux(root, archive, app_id):
    shutil.rmtree(root, ignore_errors=True)
    extract_zip(archive, root / "opt" / "nari")
    desktop = root / "usr" / "share" / "applications"
    icons = root / "usr" / "share" / "icons" / "hicolor" / "512x512" / "apps"
    desktop.mkdir(parents=True)
    icons.mkdir(parents=True)
    shutil.copy(ROOT / "flatpak" / f"{app_id}.desktop", desktop)
    shutil.copy(ROOT / "metadata" / "icon.png", icons / f"{app_id}.png")


def appimagetool():
    found = shutil.which("appimagetool")
    if found:
        return found
    tool = TOOLS / "appimagetool"
    if not tool.exists():
        download(APPIMAGETOOL.format(platform.machine()), tool)
        tool.chmod(0o755)
    return str(tool)


def build_appimage(target, archive):
    app_id = flatpak_id()
    arch = LINUX_ARCHITECTURES[target][1]
    root = BUILD / "staging" / f"appimage-{arch}"
    stage_linux(root, archive, app_id)
    shutil.copy(ROOT / "flatpak" / f"{app_id}.desktop", root)
    shutil.copy(ROOT / "metadata" / "icon.png", root / f"{app_id}.png")
    (root / "AppRun").write_text('#!/bin/sh\nexec "$(dirname "$(readlink -f "$0")")/opt/nari/Nari" "$@"\n')
    (root / "AppRun").chmod(0o755)
    appimage = BUILD / f"Nari-linux-{arch}.AppImage"
    appimage.unlink(missing_ok=True)
    run(appimagetool(), "--appimage-extract-and-run", root, appimage, env={"ARCH": arch})
    shutil.rmtree(root)
    info(f"Packed build/{appimage.name}")


def build_deb(target, archive):
    arch = LINUX_ARCHITECTURES[target][0]
    app_id = flatpak_id()
    version = json.loads((ROOT / "metadata" / "metadata.json").read_text())["releases"][0]["version"]
    root = BUILD / "staging" / f"deb-{arch}"
    stage_linux(root, archive, app_id)
    (root / "usr" / "bin").mkdir(parents=True)
    (root / "usr" / "bin" / "nari").symlink_to("/opt/nari/Nari")
    size = sum(file.stat().st_size for file in root.rglob("*") if file.is_file()) // 1024
    (root / "DEBIAN").mkdir()
    (root / "DEBIAN" / "control").write_text(
        "Package: nari\n"
        f"Version: {version}\n"
        "Section: sound\n"
        "Priority: optional\n"
        f"Architecture: {arch}\n"
        f"Installed-Size: {size}\n"
        "Maintainer: NaviVani-dev <noreply@narimusic.com>\n"
        "Homepage: https://narimusic.com\n"
        "Description: Beautiful feature-rich music player\n")
    deb = BUILD / f"Nari-linux-{arch}.deb"
    deb.unlink(missing_ok=True)
    run("dpkg-deb", "--root-owner-group", "-Zxz", "--build", root, deb)
    shutil.rmtree(root)
    info(f"Packed build/{deb.name}")


def has_release_keystore():
    if all(os.environ.get(name) for name in KEYSTORE_VARIABLES):
        return True
    credentials = ROOT / ".godot" / "export_credentials.cfg"
    return credentials.exists() and re.search(r'^keystore/release="[^"]+"', credentials.read_text(), flags=re.M)


def export_ios(debug):
    project = BUILD / "ios"
    shutil.rmtree(project, ignore_errors=True)
    project.mkdir(parents=True)
    template = f'"{ios.template().as_posix()}"'
    godot_export("iOS", project / "Nari.ipa", debug, options={
        "custom_template/debug": template, "custom_template/release": template, "application/app_store_team_id": '"UNSIGNED00"'})
    ios.package(project, BUILD / "Nari-ios.ipa")
    info("Install build/Nari-ios.ipa with SideStore, AltStore or Sideloadly")


def export_aab():
    if not has_release_keystore():
        fail("Google Play needs a signed bundle: set " + ", ".join(KEYSTORE_VARIABLES) + " (a .env file works too)")
    godot_export("Android", BUILD / "Nari.aab", channel="play", options={"gradle_build/export_format": "1"})
    info("Upload build/Nari.aab to Google Play")


def export_pack(pck):
    info(f"Exporting the Flatpak pack -> {pck.relative_to(ROOT)}")
    pck.parent.mkdir(parents=True, exist_ok=True)
    with preset_overrides("Linux (x64)", {"custom_features": '"channel_flatpak"'}):
        run(godot(), "--headless", "--path", ROOT, "--export-pack", "Linux (x64)", pck)
    return hashlib.sha256(pck.read_bytes()).hexdigest()


def export_pck():
    pck = BUILD / "flatpak" / "Nari.pck"
    digest = export_pack(pck)
    manifest = next((ROOT / "flatpak").glob("*.yml"))
    text, count = re.subn(r"(/Nari\.pck\n\s+sha256: )\S+", rf"\g<1>{digest}", manifest.read_text())
    if count != 1:
        fail(f"couldn't find the Nari.pck sha256 in {manifest.name}")
    manifest.write_text(text)
    info(f"Nari.pck sha256 {digest} written to {manifest.relative_to(ROOT)}")
    flatpak_cargo_sources()


def flatpak_cargo_sources():
    environment = TOOLS / "venv"
    python = environment / ("Scripts/python.exe" if sys.platform == "win32" else "bin/python")
    if not python.exists():
        venv.create(environment, with_pip=True)
        run(python, "-m", "pip", "install", "-q", "aiohttp", "tomlkit")
    generator = TOOLS / "flatpak-cargo-generator.py"
    if not generator.exists():
        download(CARGO_GENERATOR, generator)
    info("Generating flatpak/cargo-sources.json")
    run(python, generator, ROOT / "addons/MusicService/native/Cargo.lock", "-o", ROOT / "flatpak/cargo-sources.json")


def flatpak_id():
    return json.loads((ROOT / "metadata" / "metadata.json").read_text())["ids"]["flatpak"]


def flatpak_builder():
    if shutil.which("flatpak-builder"):
        return ["flatpak-builder"]
    return ["flatpak", "run", f"--filesystem={ROOT}", "org.flatpak.Builder"]


def local_manifest(app_id, pck, folder):
    text = (ROOT / "flatpak" / f"{app_id}.yml").read_text()
    skip = "".join(f"          - {path}\n" for path in FLATPAK_SKIP)
    text, sources = re.subn(r"      - type: git\n(?:        .+\n)+",
                            lambda _: f"      - type: dir\n        path: {ROOT}\n        skip:\n{skip}", text)
    text, packs = re.subn(r"      - type: file\n        url: \S+/Nari\.pck\n        sha256: \S+\n",
                          lambda _: f"      - type: file\n        path: {pck}\n", text)
    text, crates = re.subn(r"^      - cargo-sources\.json$", lambda _: f"      - {ROOT / 'flatpak' / 'cargo-sources.json'}", text, flags=re.M)
    if (sources, packs, crates) != (1, 1, 1):
        fail("the Flatpak manifest changed, update local_manifest() in scripts/build.py")
    manifest = folder / f"{app_id}.yml"
    manifest.write_text(text)
    return manifest


def flatpak_key(key):
    if not key:
        return ""
    exported = subprocess.run(["gpg", "--export", key], capture_output=True).stdout
    if not exported:
        fail(f"gpg has no public key for NARI_FLATPAK_GPG_KEY={key}")
    return base64.b64encode(exported).decode()


def write_flatpak_files(app_id, folder, url, key):
    signature = f"GPGKey={key}\n" if key else ""
    (folder / "nari.flatpakref").write_text(
        "[Flatpak Ref]\n"
        f"Name={app_id}\n"
        "Branch=master\n"
        "Title=Nari\n"
        f"Url={url}\n"
        f"RuntimeRepo={FLATHUB_REPO}\n"
        "IsRuntime=false\n"
        "Homepage=https://narimusic.com\n"
        + signature)
    (folder / "nari.flatpakrepo").write_text(
        "[Flatpak Repo]\n"
        "Title=Nari\n"
        f"Url={url}\n"
        "Homepage=https://narimusic.com\n"
        "Comment=Nari's own Flatpak repository\n"
        + signature)


def build_flatpak():
    app_id = flatpak_id()
    folder = work_dir(BUILD / "flatpak")
    pck = folder / "Nari.pck"
    export_pack(pck)
    flatpak_cargo_sources()
    manifest = local_manifest(app_id, pck, folder)
    repo = folder / "repo"
    info(f"Building {app_id} into {repo.relative_to(ROOT)}")
    run(*flatpak_builder(), "--user", "--install-deps-from=flathub", "--force-clean", "--disable-rofiles-fuse",
        f"--state-dir={folder / 'state'}", f"--repo={repo}", folder / "builddir", manifest)

    key = os.environ.get("NARI_FLATPAK_GPG_KEY", "")
    signing = [f"--gpg-sign={key}"] if key else []
    if key:
        run("flatpak", "build-sign", repo, app_id, *signing)
    run("flatpak", "build-update-repo", "--generate-static-deltas", "--prune", *signing, repo)

    url = os.environ.get("NARI_FLATPAK_URL") or FLATPAK_URL
    write_flatpak_files(app_id, folder, url, flatpak_key(key))
    info(f"Upload {repo.relative_to(ROOT)}/ to {url}, and build/flatpak/nari.flatpakref and nari.flatpakrepo to the website")
    if not key:
        warn("The repository isn't signed: set NARI_FLATPAK_GPG_KEY before publishing it")


def main():
    parser = argparse.ArgumentParser(usage="build.py [target ...] [--debug]")
    parser.add_argument("targets", nargs="*", choices=[*ALL, "windows-arm64", "plugins-windows-arm64", "test", "flatpak", "all"], metavar="target",
                        help=f"{', '.join(ALL)}, windows-arm64, plugins-windows-arm64, test, flatpak or all (default)")
    parser.add_argument("--debug", action="store_true", help="export debug builds instead of release")
    args = parser.parse_args()

    work_dir(BUILD)
    targets = args.targets or ["all"]
    for target in ALL if "all" in targets else targets:
        if target == "metadata":
            metadata.main()
        elif target == "plugins":
            music_service.build()
            aynthor.build()
        elif target == "plugins-windows-arm64":
            music_service.build_windows_arm64()
        elif target == "test":
            music_service.test()
        elif target in DESKTOP:
            export_desktop(target, args.debug)
        elif target == "android":
            godot_export("Android", BUILD / "Nari.apk", args.debug, options={
                "permissions/custom_permissions": SIDELOAD_PERMISSIONS, "architectures/x86_64": "false"})
        elif target == "aab":
            export_aab()
        elif target == "ios":
            export_ios(args.debug)
        elif target == "pck":
            export_pck()
        elif target == "flatpak":
            build_flatpak()
    info("Done")


if __name__ == "__main__":
    main()
