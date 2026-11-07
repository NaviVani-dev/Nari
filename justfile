python := if os_family() == "windows" { "python" } else { "python3" }

[private]
default:
    @just --list

build *targets:
    {{python}} scripts/build.py {{targets}}

test:
    {{python}} scripts/build.py test

generate-metadata:
    {{python}} scripts/metadata.py

take-screenshots *args:
    {{python}} scripts/take_screenshots.py {{args}}

fdroid apk="nari.apk":
    {{python}} scripts/fdroid.py {{apk}}

export-background:
    XDG_DATA_HOME="$(mktemp -d)" "$({{python}} -c 'import sys; sys.path[0] = "scripts"; from common import godot; print(godot())')" --path . --fixed-fps 60 --quit-after 6000 --write-movie build/background.avi res://ui/shared/BG.tscn && ffmpeg -y -v error -i build/background.avi -c:v libopenh264 -b:v 16M -an -pix_fmt yuv420p build/background.mp4 && rm build/background.avi
