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
