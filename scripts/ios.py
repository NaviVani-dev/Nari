import json
import os
import plistlib
import re
import shutil
import zipfile
from pathlib import Path

import music_service
from common import GODOT_VERSION, TOOLS, container_engine, download_zip_member, godot_data_dir, info, run, run_in_container

TEMPLATES_URL = f"https://github.com/godotengine/godot/releases/download/{GODOT_VERSION}-stable/Godot_v{GODOT_VERSION}-stable_export_templates.tpz"
NAME = "Nari"
STUBS = """#include <stdbool.h>
#include <stdint.h>

typedef struct {
	uint32_t platform;
	uint32_t version;
} dyld_build_version_t;

extern bool _availability_version_check(uint32_t count, dyld_build_version_t versions[]);

char _swift_FORCE_LOAD_$_swiftCompatibility56;
char _swift_FORCE_LOAD_$_swiftCompatibilityConcurrency;

int32_t __isPlatformVersionAtLeast(uint32_t platform, uint32_t major, uint32_t minor, uint32_t subminor) {
	dyld_build_version_t version = {platform, (major << 16) | ((minor & 0xff) << 8) | (subminor & 0xff)};
	return _availability_version_check(1, &version);
}
"""


def template():
    installed = godot_data_dir() / "export_templates" / f"{GODOT_VERSION}.stable" / "ios.zip"
    if installed.exists():
        return installed
    path = TOOLS / f"godot-ios-{GODOT_VERSION}.zip"
    if not path.exists():
        download_zip_member(TEMPLATES_URL, "templates/ios.zip", path)
    return path


def link():
    project = Path(os.environ["NARI_IOS_PROJECT"])
    sdk = os.environ["IOS_SDK"]
    flags = [f"--target=arm64-apple-ios{music_service.IOS_MINIMUM}", f"-isysroot{sdk}"]
    objects = project / "objects"
    objects.mkdir(exist_ok=True)
    (objects / "stubs.c").write_text(STUBS)
    info("Compiling the iOS launcher")
    run("clang", *flags, "-O2", "-c", objects / "stubs.c", "-o", objects / "stubs.o")
    run("clang++", *flags, "-O2", "-std=c++17", "-c", project / NAME / "dummy.cpp", "-o", objects / "dummy.o")
    info("Linking the iOS executable")
    run("clang++", *flags, "-fuse-ld=lld", f"-L{sdk}/usr/lib/swift", "-Wl,-rpath,/usr/lib/swift",
        "-Wl,-rpath,@executable_path/Frameworks", "-Wl,-dead_strip", "-Wl,--icf=all",
        objects / "dummy.o", objects / "stubs.o", project / f"{NAME}.xcframework/ios-arm64/libgodot.a",
        project / "MoltenVK.xcframework/ios-arm64/libMoltenVK.a", "-o", objects / NAME)
    run("llvm-strip", "-x", objects / NAME)


def build_settings(project):
    text = (project / f"{NAME}.xcodeproj/project.pbxproj").read_text()
    settings = {}
    for key, value in re.findall(r"^\s+(\w+) = (.+);$", text, flags=re.M):
        settings.setdefault(key, value.strip('"'))
    settings["EXECUTABLE_NAME"] = settings["PRODUCT_NAME"]
    return settings


def copy_icons(project, app):
    folder = project / NAME / "Images.xcassets/AppIcon.appiconset"
    names = []
    for image in json.loads((folder / "Contents.json").read_text())["images"]:
        if image.get("platform") != "ios" or "filename" not in image or "scale" not in image:
            continue
        base = f"AppIcon{image['size']}"
        shutil.copy(folder / image["filename"], app / f"{base}@{image['scale']}.png")
        if base not in names:
            names.append(base)
    return names


def info_plist(project, icons):
    settings = build_settings(project)
    text = re.sub(r"\$\((\w+)\)", lambda match: settings.get(match.group(1), ""), (project / NAME / f"{NAME}-Info.plist").read_text())
    data = plistlib.loads(text.encode())
    data.pop("UILaunchStoryboardName", None)
    icon_set = {"CFBundlePrimaryIcon": {"CFBundleIconFiles": icons}}
    data.update({
        "UILaunchScreen": {},
        "MinimumOSVersion": music_service.IOS_MINIMUM,
        "CFBundleSupportedPlatforms": ["iPhoneOS"],
        "UIDeviceFamily": [1, 2],
        "DTPlatformName": "iphoneos",
        "DTSDKName": f"iphoneos{music_service.IOS_SDK_VERSION}",
        "CFBundleIcons": icon_set,
        "CFBundleIcons~ipad": icon_set,
    })
    return plistlib.dumps(data)


def package(project, destination):
    engine = container_engine()
    music_service.ios_image(engine)
    run_in_container(engine, music_service.IOS_IMAGE, "ios", "link", env={"NARI_IOS_PROJECT": project})
    payload = project / "Payload"
    shutil.rmtree(payload, ignore_errors=True)
    app = payload / f"{NAME}.app"
    app.mkdir(parents=True)
    shutil.copy(project / "objects" / NAME, app / NAME)
    for name in (f"{NAME}.pck", "PrivacyInfo.xcprivacy"):
        shutil.copy(project / name, app / name)
    shutil.copytree(project / NAME / "en.lproj", app / "en.lproj")
    for framework in (project / NAME / "dylibs").rglob("*.framework"):
        shutil.copytree(framework, app / "Frameworks" / framework.name)
    (app / "Info.plist").write_bytes(info_plist(project, copy_icons(project, app)))
    destination.unlink(missing_ok=True)
    with zipfile.ZipFile(destination, "w", zipfile.ZIP_DEFLATED) as ipa:
        for path in sorted(payload.rglob("*")):
            ipa.write(path, path.relative_to(project))
    info(f"Packed {destination.name}")
