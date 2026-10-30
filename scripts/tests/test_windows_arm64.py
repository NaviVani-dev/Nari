import contextlib
import io
import re
import struct
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import build
import music_service
from common import ROOT, override_preset


def pe(path, machine=0xAA64):
    data = bytearray(0x86)
    data[:2] = b"MZ"
    struct.pack_into("<I", data, 0x3C, 0x80)
    data[0x80:0x84] = b"PE\0\0"
    struct.pack_into("<H", data, 0x84, machine)
    path.write_bytes(data)
    return path


class WindowsArm64Tests(unittest.TestCase):
    def test_rejects_incompatible_and_broken_binaries(self):
        with tempfile.TemporaryDirectory() as folder, contextlib.redirect_stderr(io.StringIO()):
            path = Path(folder) / "nari.dll"
            music_service.validate_arm64_files([pe(path)])
            for machine in (0x8664, 0x14C, 0xA641):
                with self.subTest(machine=machine), self.assertRaises(SystemExit):
                    music_service.validate_arm64_files([pe(path, machine)])
            for data in (b"", b"MZ", b"not a PE file"):
                path.write_bytes(data)
                with self.subTest(data=data), self.assertRaises(SystemExit):
                    music_service.validate_arm64_files([path])
            with self.assertRaises(SystemExit):
                music_service.validate_arm64_files([Path(folder) / "missing.dll"])

    def test_all_required_dependencies_must_be_arm64(self):
        with tempfile.TemporaryDirectory() as folder, contextlib.redirect_stderr(io.StringIO()):
            out = Path(folder) / "windows/arm64"
            out.mkdir(parents=True)
            names = ["nari.dll", "WebView2Loader.dll", "avcodec-62.dll", "avformat-62.dll", "avutil-60.dll", "swscale-9.dll"]
            for name in names:
                pe(out / name)
            with patch.object(music_service, "BIN", Path(folder)):
                music_service.validate_windows_arm64()
                pe(out / "WebView2Loader.dll", 0x8664)
                with self.assertRaises(SystemExit):
                    music_service.validate_windows_arm64()

    def test_export_stops_before_godot_if_libraries_are_missing(self):
        with tempfile.TemporaryDirectory() as folder, patch.object(music_service, "BIN", Path(folder)), \
                patch.object(build, "godot_export") as export, contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit):
                build.export_desktop("windows-arm64", False)
            export.assert_not_called()

    def test_presets_and_dependency_paths(self):
        text = (ROOT / "export_presets.cfg").read_text()
        presets = re.findall(r'^\[preset\.(\d+)\]$', text, re.M)
        self.assertEqual(len(presets), len(set(presets)))
        self.assertIn('name="iOS"', text)
        self.assertIn("ios", build.ALL)
        self.assertNotIn("windows-arm64", build.ALL)
        self.assertEqual(len(re.findall(r'^name="Windows \(arm64\)"$', text, re.M)), 1)
        changed = override_preset(text, "Windows (arm64)", {"custom_features": '"channel_github"'})
        block = next(block for block in re.split(r'(?m)^(?=\[preset\.\d+\]$)', changed)
                     if 'name="Windows (arm64)"' in block)
        self.assertIn('binary_format/architecture="arm64"', block)
        self.assertIn('addons/AynThor/AynThor.gdextension', block)
        self.assertIn('custom_features="channel_github"', block)
        extension = (ROOT / "addons/MusicService/MusicService.gdextension").read_text()
        for mode in ("debug", "release"):
            self.assertIn(f'windows.{mode}.arm64 = "res://addons/MusicService/bin/windows/arm64/nari.dll"', extension)
            dependencies = extension.split(f"windows.{mode}.arm64 = {{", 1)[1].split("}", 1)[0]
            self.assertNotIn("winpthread", dependencies)
            self.assertEqual(dependencies.count("/windows/arm64/"), 5)


if __name__ == "__main__":
    unittest.main()
