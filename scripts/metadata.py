#!/usr/bin/env python3
import json
import re
import shutil
from string import Template
from xml.sax.saxutils import escape

from common import ROOT, TEMPLATES, output

META = ROOT / "metadata"
FLATPAK = ROOT / "flatpak"
FASTLANE = ROOT / "fastlane" / "metadata" / "android" / "en-US"


def write(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)
    print("wrote", path.relative_to(ROOT))


def replace(path, pattern, replacement):
    text = path.read_text()
    new, count = re.subn(pattern, replacement, text, flags=re.M)
    assert count, f"{pattern!r} not found in {path.relative_to(ROOT)}"
    if new != text:
        write(path, new)


def fill(template, **values):
    return Template((TEMPLATES / template).read_text()).substitute(values)


def indented(items, indent):
    return "\n".join(indent + item for item in items)


def check(data):
    assert len(data["name"]) <= 50, "name is over 50 characters"
    assert len(data["summary"]) <= 80, "summary is over 80 characters"
    for release in data["releases"]:
        assert len("\n".join(release["notes"])) <= 500, f"notes for {release['version']} are over 500 characters"
    assert data["screenshots"]["pc"], "Flathub needs at least one pc screenshot"
    for form, shots in data["screenshots"].items():
        for shot in shots:
            assert (META / "screenshots" / form / shot["file"]).is_file(), f"missing metadata/screenshots/{form}/{shot['file']}"


def metainfo(data, app_id, tag):
    raw = data["repository"].replace("github.com", "raw.githubusercontent.com")

    shots = [(shot, "pc", "") for shot in data["screenshots"]["pc"]]
    if data["mobile"]:
        shots += [(shot, "phone", ' environment="plasma-mobile"') for shot in data["screenshots"].get("phone", [])]
    screenshots = []
    for i, (shot, form, environment) in enumerate(shots):
        default = ' type="default"' if i == 0 else ""
        screenshots.append(
            f"<screenshot{default}{environment}>\n"
            f"      <image>{raw}/{tag}/metadata/screenshots/{form}/{shot['file']}</image>\n"
            f"      <caption>{escape(shot['caption'])}</caption>\n"
            f"    </screenshot>")

    releases = []
    for release in data["releases"]:
        notes = indented([f"<p>{escape(note)}</p>" for note in release["notes"]], "        ")
        releases.append(
            f'<release version="{release["version"]}" date="{release["date"]}">\n'
            f"      <description>\n{notes}\n      </description>\n"
            f"    </release>")

    controls = ["pointing", "keyboard", "gamepad"] + (["touch"] if data["mobile"] else [])
    return fill(
        "metainfo.xml",
        app_id=app_id,
        name=escape(data["name"]),
        summary=escape(data["summary"]),
        developer_id=data["developer"]["id"],
        developer_name=escape(data["developer"]["name"]),
        paragraphs=indented([f"<p>{escape(p)}</p>" for p in data["description"]], "    "),
        features=indented([f"<li>{escape(f)}</li>" for f in data["features"]], "      "),
        repository=data["repository"],
        screenshots=indented(screenshots, "    "),
        color_light=data["branding"]["light"],
        color_dark=data["branding"]["dark"],
        controls=indented([f"<control>{c}</control>" for c in controls], "    "),
        content_rating=indented([f'<content_attribute id="{key}">{value}</content_attribute>'
                                 for key, value in data["content_rating"].items()], "    "),
        releases=indented(releases, "    "),
    )


def desktop_entry(data, app_id):
    text = fill(
        "app.desktop",
        app_id=app_id,
        name=data["name"],
        summary=data["summary"],
        mime_types=";".join(data["mime_types"]),
        categories=";".join(data["desktop_categories"]),
        keywords=";".join(data["keywords"]),
    )
    if data["mobile"]:
        text += "X-Purism-FormFactor=Workstation;Mobile;\n"
    return text


def write_flatpak(data, app_id, tag):
    write(FLATPAK / f"{app_id}.metainfo.xml", metainfo(data, app_id, tag))
    write(FLATPAK / f"{app_id}.desktop", desktop_entry(data, app_id))
    manifest = FLATPAK / f"{app_id}.yml"
    replace(manifest, r"^(\s+tag: )v[\w.-]+$", rf"\g<1>{tag}")
    commit = output("git", "rev-list", "-n", "1", tag, cwd=ROOT)
    text = re.sub(r"^\s+commit: \w+\n", "", manifest.read_text(), flags=re.M)
    if commit:
        text = re.sub(r"^(\s+)(tag: .+)$", rf"\1\2\n\1commit: {commit}", text, count=1, flags=re.M)
    else:
        print(f"{tag} isn't tagged yet, run this again after tagging to pin its commit in the Flatpak manifest")
    write(manifest, text)
    replace(manifest, r"(/releases/download/)v[\w.-]+/", rf"\g<1>{tag}/")


def write_fastlane(data):
    write(FASTLANE / "title.txt", data["name"] + "\n")
    write(FASTLANE / "short_description.txt", data["summary"] + "\n")
    write(FASTLANE / "full_description.txt",
          "".join(f"<p>{escape(p)}</p>\n" for p in data["description"])
          + "<ul>\n" + "".join(f"<li>{escape(f)}</li>\n" for f in data["features"]) + "</ul>\n")
    for release in data["releases"]:
        write(FASTLANE / "changelogs" / f"{release['code']}.txt", "\n".join(release["notes"]) + "\n")

    images = FASTLANE / "images"
    images.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(META / "icon.png", images / "icon.png")
    for form, folder in (("phone", "phoneScreenshots"), ("pc", "tenInchScreenshots")):
        shutil.rmtree(images / folder, ignore_errors=True)
        (images / folder).mkdir()
        for i, shot in enumerate(data["screenshots"].get(form, []), 1):
            shutil.copyfile(META / "screenshots" / form / shot["file"], images / folder / f"{i}.png")
    print("copied icon and screenshots to", images.relative_to(ROOT))


def write_versions(data, latest):
    presets = ROOT / "export_presets.cfg"
    replace(presets, r"^version/code=\d+$", f"version/code={latest['code']}")
    replace(presets, r'^version/name=".*"$', f'version/name="{latest["version"]}"')
    replace(presets, r'^package/unique_name=".*"$', f'package/unique_name="{data["ids"]["android"]}"')
    project = ROOT / "project.godot"
    replace(project, r'^config/version=".*"$', f'config/version="{latest["version"]}"')
    replace(project, r'^config/name=".*"$', f'config/name="{data["name"]}"')
    replace(project, r'^config/description=".*"$', f'config/description="{data["summary"]}"')


def main():
    data = json.loads((META / "metadata.json").read_text())
    check(data)
    latest = data["releases"][0]
    tag = f"v{latest['version']}"
    write_flatpak(data, data["ids"]["flatpak"], tag)
    write_fastlane(data)
    write_versions(data, latest)


if __name__ == "__main__":
    main()
