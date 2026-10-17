#!/usr/bin/env python3
import argparse
import json
import os
import re
import shutil
import subprocess
import tempfile
import threading
import time
from pathlib import Path
from string import Template

from common import ROOT, TEMPLATES, fail, godot, godot_user_dir, info

FILES = TEMPLATES / "screenshots"
SETS = ["pc", "phone", "dual"]
TIMEOUT = 300

ARTISTS = ["ABBA", "The Weeknd", "Olivia Dean", "Michael Jackson", "Charli xcx", "Madonna", "Tame Impala",
           "Sabrina Carpenter", "Silk Sonic", "Lady Gaga", "Wham!", "Dua Lipa"]
PLAYING_ALBUM = "After Hours"
PLAYING_SONG = "Blinding Lights"
FEATURED_ALBUM = "Thriller"


def default_music_dir():
    return Path(os.environ.get("NARI_DEMO_MUSIC") or os.environ.get("XDG_MUSIC_DIR") or Path.home() / "Music")


def link_or_copy(source, destination):
    try:
        os.link(source, destination)
    except OSError:
        shutil.copy2(source, destination)


def create_user_dir(user_dir, music):
    info(f"Creating {user_dir}")
    library = user_dir / "demo-music"
    found = [artist for artist in ARTISTS if (music / artist).is_dir()]
    if found:
        for artist in found:
            shutil.copytree(music / artist, library / artist, copy_function=link_or_copy)
        missing = sorted(set(ARTISTS) - set(found))
        if missing:
            print("not in your music folder, skipped:", ", ".join(missing))
    else:
        print(f"none of the demo artists are in {music}, using the whole folder")
        library = music

    (user_dir / "library").mkdir(parents=True, exist_ok=True)
    folders = {"music": [{"uri": str(library), "name": "Music", "document_id": str(library)}], "ignored": []}
    (user_dir / "library" / "folders.json").write_text(json.dumps(folders))
    (user_dir / "OOBE.txt").touch()
    shutil.copy(FILES / "settings.cfg", user_dir / "settings.cfg")
    lyrics = godot_user_dir("Nari") / "lyrics"
    if lyrics.is_dir():
        shutil.copytree(lyrics, user_dir / "lyrics", dirs_exist_ok=True)


def screens_main_scene(work):
    shutil.copy(FILES / "main.gd", work / "main.gd")
    scene = (ROOT / "main.tscn").read_text()
    scene = re.sub(r' uid="[^"]*"', "", scene.split("\n", 1)[0], count=1) + "\n" + scene.split("\n", 1)[1]
    scene, count = re.subn(r'^\[ext_resource type="Script" uid="[^"]*" path="res://main\.gd"',
                           f'[ext_resource type="Script" path="{(work / "main.gd").as_posix()}"', scene, flags=re.M)
    if not count:
        fail("main.tscn changed and its main.gd line wasn't found, update screens_main_scene()")
    path = work / "main.tscn"
    path.write_text(scene)
    return path


def run_godot(env):
    process = subprocess.Popen([godot(), "--path", ROOT], env={**os.environ, **env},
                               stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, errors="replace")
    timer = threading.Timer(TIMEOUT, process.kill)
    timer.start()
    for line in process.stdout:
        if "[screenshots]" in line:
            print(line, end="", flush=True)
    process.wait()
    timer.cancel()


def take(shot_set):
    out = ROOT / "metadata" / "screenshots" / shot_set
    out.mkdir(parents=True, exist_ok=True)
    started = time.time()
    run_godot({
        "NARI_SHOTS_SET": shot_set,
        "NARI_SHOTS_OUT": str(out),
        "NARI_SHOTS_ALBUM": PLAYING_ALBUM,
        "NARI_SHOTS_SONG": PLAYING_SONG,
        "NARI_SHOTS_FEATURED_ALBUM": FEATURED_ALBUM,
    })
    last = out / ("6-bottom.png" if shot_set == "dual" else "6.png")
    if not last.exists() or last.stat().st_mtime < started:
        fail(f"the {shot_set} screenshots failed")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("sets", nargs="*", choices=SETS, metavar="set", help="pc, phone or dual (default: all)")
    parser.add_argument("--music", type=Path, default=default_music_dir(), help="where to take the demo library from")
    parser.add_argument("--fresh", action="store_true", help="recreate the screenshot user folder")
    args = parser.parse_args()

    godot()
    override = ROOT / "override.cfg"
    if override.exists():
        fail(f"{override} already exists, not touching it")

    user_dir = godot_user_dir("NariScreenshots")
    if args.fresh:
        shutil.rmtree(user_dir, ignore_errors=True)
    if not user_dir.exists():
        create_user_dir(user_dir, args.music.expanduser())

    with tempfile.TemporaryDirectory() as temp:
        work = Path(temp)
        shutil.copy(FILES / "capture.gd", work / "capture.gd")
        override.write_text(Template((FILES / "override.cfg").read_text()).substitute(
            main_scene=screens_main_scene(work).as_posix(),
            capture_script=(work / "capture.gd").as_posix(),
        ))
        try:
            for shot_set in args.sets or SETS:
                take(shot_set)
        finally:
            override.unlink()
    info("Screenshots saved in metadata/screenshots/")


if __name__ == "__main__":
    main()
