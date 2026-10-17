#!/usr/bin/env python3
import argparse
import hashlib
import os
import re
import shutil
import sys
import venv

import aynthor
import metadata
import music_service
from common import BUILD, ROOT, TOOLS, download, fail, godot, info, preset_overrides, run, work_dir

CARGO_GENERATOR = ("https://raw.githubusercontent.com/flatpak/flatpak-builder-tools/"
                   "74697c75b630d7330e77250fc13cb5ea688d9479/cargo/flatpak-cargo-generator.py")

DESKTOP = {
    "linux": ("Linux (x64)", "Nari-linux-x64.zip", "Nari.zip"),
    "linux-arm64": ("Linux (arm64)", "Nari-linux-arm.zip", "Nari.zip"),
    "windows": ("Windows (x64)", "Nari-windows.zip", "Nari.exe"),
    "macos": ("macOS", "Nari-macos.zip", "Nari.zip"),
}
ALL = ["metadata", "plugins", *DESKTOP, "android", "aab", "pck"]
SIDELOAD_PERMISSIONS = 'PackedStringArray("android.permission.REQUEST_INSTALL_PACKAGES")'
KEYSTORE_VARIABLES = ["GODOT_ANDROID_KEYSTORE_RELEASE_PATH", "GODOT_ANDROID_KEYSTORE_RELEASE_USER", "GODOT_ANDROID_KEYSTORE_RELEASE_PASSWORD"]


def godot_export(preset, destination, debug=False, channel="github", options=None):
    info(f"Exporting {preset} -> {destination.relative_to(ROOT)}")
    destination.parent.mkdir(parents=True, exist_ok=True)
    with preset_overrides(preset, {"custom_features": f'"channel_{channel}"', **(options or {})}):
        run(godot(), "--headless", "--path", ROOT, "--export-debug" if debug else "--export-release", preset, destination)


def export_desktop(target, debug):
    preset, archive, exported = DESKTOP[target]
    staging = BUILD / "staging" / target
    shutil.rmtree(staging, ignore_errors=True)
    godot_export(preset, staging / exported, debug)
    (BUILD / archive).unlink(missing_ok=True)
    if exported.endswith(".zip"):
        shutil.move(staging / exported, BUILD / archive)
    else:
        shutil.make_archive(str(BUILD / archive.removesuffix(".zip")), "zip", staging)
    shutil.rmtree(BUILD / "staging")
    info(f"Packed build/{archive}")


def has_release_keystore():
    if all(os.environ.get(name) for name in KEYSTORE_VARIABLES):
        return True
    credentials = ROOT / ".godot" / "export_credentials.cfg"
    return credentials.exists() and re.search(r'^keystore/release="[^"]+"', credentials.read_text(), flags=re.M)


def export_aab():
    if not has_release_keystore():
        fail("Google Play needs a signed bundle: set " + ", ".join(KEYSTORE_VARIABLES) + " (a .env file works too)")
    godot_export("Android", BUILD / "Nari.aab", channel="play", options={"gradle_build/export_format": "1"})
    info("Upload build/Nari.aab to Google Play")


def export_pck():
    pck = BUILD / "flatpak" / "Nari.pck"
    info(f"Exporting the Flatpak pack -> {pck.relative_to(ROOT)}")
    pck.parent.mkdir(parents=True, exist_ok=True)
    with preset_overrides("Linux (x64)", {"custom_features": '"channel_flatpak"'}):
        run(godot(), "--headless", "--path", ROOT, "--export-pack", "Linux (x64)", pck)
    digest = hashlib.sha256(pck.read_bytes()).hexdigest()
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


def main():
    parser = argparse.ArgumentParser(usage="build.py [target ...] [--debug]")
    parser.add_argument("targets", nargs="*", choices=[*ALL, "test", "all"], metavar="target",
                        help=f"{', '.join(ALL)}, test or all (default)")
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
        elif target == "test":
            music_service.test()
        elif target in DESKTOP:
            export_desktop(target, args.debug)
        elif target == "android":
            godot_export("Android", BUILD / "Nari.apk", args.debug, options={"permissions/custom_permissions": SIDELOAD_PERMISSIONS})
        elif target == "aab":
            export_aab()
        elif target == "pck":
            export_pck()
    info("Done")


if __name__ == "__main__":
    main()
