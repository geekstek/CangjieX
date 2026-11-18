#!/usr/bin/env python3
"""Verify the expanded installer that will be distributed, without installing it."""
import hashlib
import json
import plistlib
import struct
import subprocess
import sys
import uuid
from pathlib import Path
from xml.etree import ElementTree as ET

expanded, source_app, version = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]
distribution = ET.parse(expanded / "Distribution").getroot()
domains = distribution.find("domains")
assert domains is not None and domains.attrib == {
    "enable_anywhere": "false", "enable_currentUserHome": "true", "enable_localSystem": "false"
}, "Installer must only target the current user's home"
components = list(expanded.glob("*.pkg"))
minimum = distribution.find("volume-check/allowed-os-versions/os-version")
assert minimum is not None and minimum.get("min") == "11.0"
assert len(components) == 1, "Unexpected installer component"
component = components[0]
info = ET.parse(component / "PackageInfo").getroot()
assert info.get("identifier") == "io.github.geekstek.cangjiex.preview.pkg"
assert info.get("version") == version and info.get("install-location") == "/"
assert info.find("scripts") is None and not (component / "Scripts").exists(), "Installer must not execute scripts"
payload = component / "Payload"
app = payload / "Library/Input Methods/CangjieXPreview.app"
assert app.is_dir()
assert {p.name for p in (payload / "Library/Input Methods").iterdir()} == {"CangjieXPreview.app"}
assert {p.name for p in payload.iterdir()} == {"Library"}
assert {p.name for p in (payload / "Library").iterdir()} == {"Input Methods"}
for path in payload.rglob("*"):
    assert not path.is_symlink(), "Unexpected symlink in input method payload"
with (app / "Contents/Info.plist").open("rb") as stream:
    plist = plistlib.load(stream)
assert plist["CFBundleName"] == "倉頡星" and plist["CFBundleDisplayName"] == "倉頡星"
assert plist["CFBundleIdentifier"] == "io.github.geekstek.inputmethod.CangjieXPreview"
assert plist["CFBundleShortVersionString"] == version
assert plist["LSMinimumSystemVersion"] == "11.0"
assert plist["TISInputSourceID"] == plist["CFBundleIdentifier"]
bundle = info.find("bundle-version/bundle")
assert bundle is not None and bundle.get("id") == plist["CFBundleIdentifier"]
relocation = info.find("relocate")
assert relocation is None or not list(relocation), "Installer must not search for and relocate another app"
assert distribution.find("locator") is None and distribution.find("pkg-ref/relocate") is None
assert distribution.find("pkg-ref").get("onConclusion") == "RequireLogout", "Manual installation must explicitly require logout"
identity = json.loads((app / "Contents/Resources/RuntimeBuild.json").read_text())
for family, license, files in [
    ("Jigmo", "CC0-1.0", {"Jigmo2.ttf", "LICENSE.txt", "README.txt", "THANKS.txt"}),
    ("CNS11643", "OGDL-Taiwan-1.0", {"TW-Sung-Plus-98_1.ttf", "LICENSE.txt", "NOTICE.txt", "font-readme.txt"}),
]:
    fonts = app / "Contents/Resources/Fonts" / family
    font_manifest = json.loads((fonts / "manifest.json").read_text())
    assert font_manifest["license"] == license and font_manifest["modified"] is False
    assert set(font_manifest["files"]) == files
    for name, digest in font_manifest["files"].items():
        assert hashlib.sha256((fonts / name).read_bytes()).hexdigest() == digest, "Font resource mismatch: " + name
assert identity["version"] == version
uuid.UUID(identity["buildID"])
executable = (app / "Contents/MacOS/CangjieXPreview").read_bytes()
magic, slices = struct.unpack_from(">II", executable)
assert magic == 0xCAFEBABE and slices == 2, "Expected a two-slice universal executable"
for index in range(slices):
    _, _, offset, size, _ = struct.unpack_from(">IIIII", executable, 8 + index * 20)
    assert identity["buildID"].encode() in executable[offset:offset + size], "Executable slice must embed the matching runtime build identity"
for file in source_app.rglob("*"):
    if file.is_file():
        delivered = app / file.relative_to(source_app)
        assert hashlib.sha256(file.read_bytes()).digest() == hashlib.sha256(delivered.read_bytes()).digest(), str(file)
subprocess.run(["codesign", "--verify", "--strict", str(app)], check=True)
subprocess.run(["xcrun", "lipo", str(app / "Contents/MacOS/CangjieXPreview"), "-verify_arch", "arm64", "x86_64"], check=True)
maintenance = app / "Contents/MacOS/CangjieXMaintenance"
assert maintenance.is_file(), "Installer must include the input-source maintenance tool"
subprocess.run(["xcrun", "lipo", str(maintenance), "-verify_arch", "arm64", "x86_64"], check=True)
subprocess.run(["codesign", "--verify", "--strict", str(maintenance)], check=True)
print("PASS: installer payload/version/signature, both architectures, user-only destination, no scripts or legacy replacement.")
