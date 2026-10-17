import os
import shutil

from common import (ROOT, JOBS, android_ndk, android_sdk, build_image, container_engine, gradle, info, outside_project, run,
                    run_in_container, work_dir)

PLUGIN = ROOT / "addons" / "AynThor"
NATIVE = PLUGIN / "native"
BIN = PLUGIN / "bin"
WORK = PLUGIN / ".build"

GODOT_CPP_BRANCH = "4.5"
ANDROID_API = 24
LINUX_IMAGE = "aynthor-linux-builder"
IN_CONTAINER = bool(os.environ.get("AYNTHOR_IN_CONTAINER"))


def ensure_godot_cpp():
    if os.environ.get("GODOT_CPP_PATH"):
        return
    checkout = WORK / "godot-cpp"
    if not checkout.is_dir():
        info(f"Cloning godot-cpp {GODOT_CPP_BRANCH}")
        run("git", "clone", "--depth", "1", "--recursive", "-b", GODOT_CPP_BRANCH,
            "https://github.com/godotengine/godot-cpp", checkout)


def scons(*args, env=None):
    ensure_godot_cpp()
    info(f"scons {' '.join(args)}")
    run("scons", *args, f"-j{JOBS}", "build_profile=build_profile.json", cwd=NATIVE, env=env)


def build_linux():
    if not IN_CONTAINER:
        engine = container_engine()
        ensure_godot_cpp()
        build_image(engine, LINUX_IMAGE, PLUGIN / "linux-builder.Containerfile")
        info(f"Building the AynThor Linux library inside {LINUX_IMAGE}")
        env = {"AYNTHOR_IN_CONTAINER": 1}
        mounts = []
        if os.environ.get("GODOT_CPP_PATH"):
            env["GODOT_CPP_PATH"] = os.environ["GODOT_CPP_PATH"]
            if outside_project(env["GODOT_CPP_PATH"]):
                mounts.append(env["GODOT_CPP_PATH"])
        return run_in_container(engine, LINUX_IMAGE, "aynthor", "build_linux", env=env, mounts=mounts)

    scons("platform=linux", "arch=x86_64", "target=template_debug")
    shutil.copy(NATIVE / "bin" / "libaynthor_native.linux.template_debug.x86_64.so",
                BIN / "libaynthor_native.linux.x86_64.debug.so")


def build_windows():
    scons("platform=windows", "arch=x86_64", "target=template_debug", "use_mingw=yes")
    shutil.copy(NATIVE / "bin" / "libaynthor_native.windows.template_debug.x86_64.dll",
                BIN / "libaynthor_native.windows.x86_64.debug.dll")


def build_android(ndk_version=None):
    sdk = android_sdk()
    ndk_version = ndk_version or android_ndk(sdk).name
    outputs = {"arm64": BIN / "libaynthor_native.so", "x86_64": BIN / "x86_64" / "libaynthor_native.so"}
    for arch, destination in outputs.items():
        scons("platform=android", f"arch={arch}", "target=template_release",
              f"android_api_level={ANDROID_API}", f"ndk_version={ndk_version}", env={"ANDROID_HOME": sdk})
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy(NATIVE / "bin" / f"libaynthor_native.android.template_release.{arch}.so", destination)


def build_aar():
    gradle_binary = gradle()
    info(f"Building the AynThor AAR with {gradle_binary}")
    run(gradle_binary, "assemble", "--no-daemon", cwd=PLUGIN / "android")


def prepare():
    work_dir(WORK)
    for folder in ("debug", "release", "x86_64"):
        (BIN / folder).mkdir(parents=True, exist_ok=True)


def build():
    prepare()
    build_linux()
    build_windows()
    build_android()
    build_aar()
