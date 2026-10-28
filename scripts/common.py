import hashlib
import os
import platform
import re
import shutil
import struct
import subprocess
import sys
import urllib.request
import zipfile
import zlib
from contextlib import contextmanager
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TEMPLATES = ROOT / "scripts" / "templates"
BUILD = ROOT / "build"
TOOLS = BUILD / "tools"

GODOT_VERSION = "4.7.2"
GRADLE_VERSION = "9.5.0"
JOBS = int(os.environ.get("NARI_JOBS") or os.cpu_count() or 1)
PRESETS = ROOT / "export_presets.cfg"


def load_env_file():
    env_file = ROOT / ".env"
    if not env_file.is_file():
        return
    for line in env_file.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        key = key.strip()
        value = value.strip().strip('"').strip("'")
        if value and not os.environ.get(key):
            os.environ[key] = os.path.expanduser(value)


load_env_file()


def info(message):
    print(f"\033[0;34m==> {message}\033[0m", flush=True)


def warn(message):
    print(f"\033[0;33mwarning: {message}\033[0m", file=sys.stderr, flush=True)


def fail(message):
    print(f"\033[0;31merror: {message}\033[0m", file=sys.stderr, flush=True)
    sys.exit(1)


def run(*command, cwd=None, env=None, check=True, stdin=None):
    command = [str(part) for part in command]
    full_env = {**os.environ, **{key: str(value) for key, value in env.items()}} if env else None
    result = subprocess.run(command, cwd=cwd, env=full_env, input=stdin)
    if check and result.returncode != 0:
        fail(f"`{' '.join(command)}` exited with code {result.returncode}")
    return result.returncode


def override_preset(text, preset, values):
    blocks = re.split(r"(?m)^(?=\[preset\.\d+\]$)", text)
    found = False
    for index, block in enumerate(blocks):
        if not re.search(rf'^name="{re.escape(preset)}"$', block, flags=re.M):
            continue
        found = True
        for key, value in values.items():
            block, count = re.subn(rf"^{re.escape(key)}=.*$", lambda _: f"{key}={value}", block, flags=re.M)
            if count != 1:
                fail(f"{key} not found in the {preset} preset")
        blocks[index] = block
    if not found:
        fail(f"no export preset called {preset}")
    return "".join(blocks)


@contextmanager
def preset_overrides(preset, values):
    original = PRESETS.read_text()
    PRESETS.write_text(override_preset(original, preset, values))
    try:
        yield
    finally:
        PRESETS.write_text(original)


def output(*command, cwd=None):
    return subprocess.run([str(part) for part in command], cwd=cwd, capture_output=True, text=True).stdout.strip()


def work_dir(path):
    path.mkdir(parents=True, exist_ok=True)
    (path / ".gdignore").touch()
    return path


def download(url, destination):
    info(f"Downloading {url}")
    destination.parent.mkdir(parents=True, exist_ok=True)
    partial = destination.with_name(destination.name + ".part")
    with urllib.request.urlopen(url) as response, open(partial, "wb") as file:
        shutil.copyfileobj(response, file)
    partial.replace(destination)
    return destination


def fetch_range(url, start, end):
    request = urllib.request.Request(url, headers={"Range": f"bytes={start}-{end}"})
    with urllib.request.urlopen(request) as response:
        return response.read()


def download_zip_member(url, member, destination):
    info(f"Downloading {member} from {url}")
    with urllib.request.urlopen(urllib.request.Request(url, method="HEAD")) as response:
        total = int(response.headers["Content-Length"])
    tail = fetch_range(url, max(0, total - 65536), total - 1)
    end = tail.rfind(b"PK\x05\x06")
    size, offset = struct.unpack("<II", tail[end + 12:end + 20])
    locator = tail.rfind(b"PK\x06\x07")
    if locator >= 0:
        record = struct.unpack("<Q", tail[locator + 8:locator + 16])[0]
        size, offset = struct.unpack("<QQ", fetch_range(url, record + 40, record + 55))
    directory = fetch_range(url, offset, offset + size - 1)
    position = 0
    while position < len(directory):
        method = struct.unpack("<H", directory[position + 10:position + 12])[0]
        packed, unpacked = struct.unpack("<II", directory[position + 20:position + 28])
        name_size, extra_size, comment_size = struct.unpack("<HHH", directory[position + 28:position + 34])
        local = struct.unpack("<I", directory[position + 42:position + 46])[0]
        name = directory[position + 46:position + 46 + name_size].decode()
        extra = directory[position + 46 + name_size:position + 46 + name_size + extra_size]
        field = 0
        while field < len(extra):
            tag, length = struct.unpack("<HH", extra[field:field + 4])
            if tag == 1:
                values = list(struct.unpack(f"<{length // 8}Q", extra[field + 4:field + 4 + length]))
                unpacked = values.pop(0) if unpacked == 0xFFFFFFFF else unpacked
                packed = values.pop(0) if packed == 0xFFFFFFFF else packed
                local = values.pop(0) if local == 0xFFFFFFFF else local
            field += 4 + length
        if name == member:
            header = fetch_range(url, local, local + 29)
            start = local + 30 + sum(struct.unpack("<HH", header[26:30]))
            data = fetch_range(url, start, start + packed - 1)
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(zlib.decompress(data, -15) if method == 8 else data)
            return destination
        position += 46 + name_size + extra_size + comment_size
    fail(f"{member} isn't inside {url}")


def extract_zip(archive, destination):
    with zipfile.ZipFile(archive) as zip_file:
        for entry in zip_file.infolist():
            path = Path(zip_file.extract(entry, destination))
            mode = entry.external_attr >> 16
            if mode and not entry.is_dir():
                path.chmod(mode & 0o777)


def download_tarball(url, destination, sha256):
    archive = download(url, destination.parent / url.rsplit("/", 1)[-1])
    if hashlib.sha256(archive.read_bytes()).hexdigest() != sha256:
        archive.unlink()
        fail(f"{url} doesn't match its sha256")
    destination.mkdir(parents=True, exist_ok=True)
    run("tar", "-xf", archive, "--strip-components=1", "-C", destination)
    archive.unlink()


def godot():
    path = os.environ.get("GODOT") or shutil.which("godot") or shutil.which("godot4")
    if not path or not Path(path).is_file():
        fail(f"Godot {GODOT_VERSION} not found. Put it on PATH or set GODOT=/path/to/godot (a .env file works too)")
    return path


def android_sdk():
    candidates = [
        os.environ.get("ANDROID_HOME"),
        os.environ.get("ANDROID_SDK_ROOT"),
        "~/Android/Sdk",
        "~/Library/Android/sdk",
        "~/AppData/Local/Android/Sdk",
    ]
    for candidate in candidates:
        if candidate and Path(candidate).expanduser().is_dir():
            return Path(candidate).expanduser()
    fail("Android SDK not found. Set ANDROID_HOME=/path/to/sdk")


def android_ndk(sdk):
    if os.environ.get("ANDROID_NDK_HOME"):
        return Path(os.environ["ANDROID_NDK_HOME"])
    versions = sorted((sdk / "ndk").glob("*"), key=lambda path: [int(n) for n in path.name.split(".") if n.isdigit()])
    if not versions:
        fail(f"No NDK found in {sdk / 'ndk'}. Install one with the SDK manager or set ANDROID_NDK_HOME")
    return versions[-1]


def gradle():
    found = os.environ.get("GRADLE") or shutil.which("gradle")
    if found:
        return found
    home = TOOLS / f"gradle-{GRADLE_VERSION}"
    binary = home / "bin" / ("gradle.bat" if platform.system() == "Windows" else "gradle")
    if not binary.exists():
        archive = download(f"https://services.gradle.org/distributions/gradle-{GRADLE_VERSION}-bin.zip", TOOLS / "gradle.zip")
        extract_zip(archive, TOOLS)
        archive.unlink()
    return binary


def container_engine():
    engine = shutil.which("podman") or shutil.which("docker")
    if not engine:
        fail("This target needs podman or docker")
    return engine


def build_image(engine, image, containerfile, context=None):
    if context:
        run(engine, "build", "-t", image, "-f", containerfile, context)
    else:
        run(engine, "build", "-t", image, "-", stdin=containerfile.read_bytes())


def run_in_container(engine, image, module, function, env=None, mounts=()):
    command = [engine, "run", "--rm", "-w", ROOT, "-e", f"NARI_JOBS={JOBS}"]
    for path in {str(ROOT), *map(str, mounts)}:
        command += ["-v", f"{path}:{path}:z"]
    for key, value in (env or {}).items():
        command += ["-e", f"{key}={value}"]
    if Path(engine).name == "docker" and hasattr(os, "getuid"):
        command += ["--user", f"{os.getuid()}:{os.getgid()}"]
    code = f"import sys; sys.path.insert(0, 'scripts'); import {module}; {module}.{function}()"
    run(*command, image, "python3", "-c", code)


def outside_project(path):
    return not Path(path).resolve().is_relative_to(ROOT)


def godot_user_dir(name):
    system = platform.system()
    if system == "Windows":
        base = Path(os.environ["APPDATA"])
    elif system == "Darwin":
        base = Path.home() / "Library" / "Application Support"
    else:
        base = Path(os.environ.get("XDG_DATA_HOME") or Path.home() / ".local" / "share")
    return base / name


def godot_data_dir():
    system = platform.system()
    if system == "Windows":
        return Path(os.environ["APPDATA"]) / "Godot"
    if system == "Darwin":
        return Path.home() / "Library" / "Application Support" / "Godot"
    return Path(os.environ.get("XDG_DATA_HOME") or Path.home() / ".local" / "share") / "godot"


def godot_config_dir():
    if platform.system() in ("Windows", "Darwin"):
        return godot_data_dir()
    return Path(os.environ.get("XDG_CONFIG_HOME") or Path.home() / ".config") / "godot"
