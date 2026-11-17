#!/usr/bin/env python3
"""Verify the actual guided installer, including after mounting its disk image."""
import hashlib
import json
from pathlib import Path
import plistlib
import subprocess
import sys

installer, source, package = map(Path, sys.argv[1:])
info = plistlib.loads((installer / "Contents/Info.plist").read_bytes())
source_info = plistlib.loads((source / "Contents/Info.plist").read_bytes())
assert info["CFBundleIdentifier"] == "io.github.geekstek.cangjiex.installer"
assert info["CFBundleDisplayName"] == "倉頡星安裝器"
assert info["CFBundleShortVersionString"] == source_info["CFBundleShortVersionString"]
assert info["LSMinimumSystemVersion"] == "11.0"
resources = installer / "Contents/Resources"
metadata = json.loads((resources / "InstallerPayload.json").read_text())
assert metadata["identity"] == json.loads((source / "Contents/Resources/RuntimeBuild.json").read_text())
digest = hashlib.sha256(package.read_bytes()).hexdigest()
assert metadata["sha256"] == digest
assert hashlib.sha256((resources / "InstallerPayload.pkg").read_bytes()).hexdigest() == digest
subprocess.run(["codesign", "--verify", "--strict", str(installer)], check=True)
subprocess.run(["lipo", str(installer / "Contents/MacOS/CangjieXInstaller"), "-verify_arch", "arm64", "x86_64"], check=True)
print("PASS: guided installer version, exact payload digest, runtime build identity, signature and both architectures.")
