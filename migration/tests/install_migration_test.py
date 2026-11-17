"""Exercise bundle replacement in a fake home; never register or stop an input method."""
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest


class InstallMigrationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="cjx upgrade test ")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.project = self.root / "project"
        self.home = self.root / "home"
        tools = self.project / "tools"
        tools.mkdir(parents=True)
        script = Path(__file__).resolve().parents[2] / "tools/install-migration-preview.sh"
        self.script = tools / script.name
        shutil.copy2(script, self.script)
        self.source = self.project / "build/migration/preview/CangjieXPreview.app"
        self.installed = self.home / "Library/Input Methods/CangjieXPreview.app"
        self.make_app(self.source)
        self.make_app(self.installed)
        self.obsolete = self.installed / "Contents/Resources/en.lproj/InfoPlist.strings"
        self.obsolete.parent.mkdir(parents=True)
        self.obsolete.write_text('CFBundleDisplayName = "CangjieX Preview";')
        self.data = self.home / "Library/Application Support/CangjieX Preview/settings.json"
        self.data.parent.mkdir(parents=True)
        self.data.write_bytes(b'{"synthetic":true}')
        self.legacy = self.home / "Library/Input Methods/CangjieX.app/untouched"
        self.legacy.parent.mkdir(parents=True)
        self.legacy.write_bytes(b"legacy sentinel")

    def make_app(self, app):
        macos = app / "Contents/MacOS"
        macos.mkdir(parents=True)
        plist = {"CFBundleIdentifier": "io.github.geekstek.inputmethod.CangjieXPreview",
                 "CFBundleExecutable": "CangjieXPreview", "CFBundlePackageType": "APPL"}
        (app / "Contents/Info.plist").write_bytes(plistlib.dumps(plist))
        shutil.copyfile("/usr/bin/true", macos / "CangjieXPreview")
        (macos / "CangjieXPreview").chmod(0o755)
        helper = macos / "CangjieXMaintenance"
        helper.write_text('#!/bin/bash\nset -eu\nif [[ "$1" == check && -e "$HOME/refuse" ]]; then exit 1; fi\nprintf "%s\\n" "$1" >> "$HOME/maintenance-calls"\n')
        helper.chmod(0o755)
        subprocess.run(["codesign", "--force", "--sign", "-", str(helper)], check=True, capture_output=True)
        subprocess.run(["codesign", "--force", "--sign", "-", str(app)], check=True, capture_output=True)

    def install(self):
        return subprocess.run(["bash", str(self.script)], env={**os.environ, "HOME": str(self.home)},
                              capture_output=True, text=True)

    def test_upgrade_replaces_old_resources_and_keeps_data_and_legacy(self):
        result = self.install()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.obsolete.exists())
        self.assertEqual(self.data.read_bytes(), b'{"synthetic":true}')
        self.assertEqual(self.legacy.read_bytes(), b"legacy sentinel")
        self.assertEqual((self.home / "maintenance-calls").read_text().splitlines(), ["check", "check", "activate"])
        self.assertEqual(list(self.installed.parent.glob(".cangjiex-update.*")), [])

    def test_preflight_refusal_preserves_installed_bundle(self):
        (self.home / "refuse").touch()
        result = self.install()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("CangjieX Preview", self.obsolete.read_text())
        self.assertFalse((self.home / "maintenance-calls").exists())
        self.assertEqual(self.data.read_bytes(), b'{"synthetic":true}')

    def test_linked_destination_is_refused(self):
        original = self.root / "another.app"
        self.installed.rename(original)
        self.installed.symlink_to(original, target_is_directory=True)
        result = self.install()
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(self.installed.is_symlink())
        self.assertTrue((original / self.obsolete.relative_to(self.installed)).exists())


if __name__ == "__main__":
    unittest.main()
