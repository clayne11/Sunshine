#!/usr/bin/env python3
"""Fixture tests for the Sunshine application packager.

These tests exercise validation and replacement recovery with temporary files;
they never invoke codesign or replace a user's application bundle.
"""

from __future__ import annotations

import importlib.util
import tempfile
import unittest
from pathlib import Path
from unittest import mock


SCRIPT = Path(__file__).with_name("package-app.py")
SPEC = importlib.util.spec_from_file_location("package_app", SCRIPT)
if SPEC is None or SPEC.loader is None:  # pragma: no cover - import machinery failure
    raise RuntimeError(f"could not load {SCRIPT}")
PACKAGE_APP = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PACKAGE_APP)


class SunshinePackageTest(unittest.TestCase):
    """Exercise package validation and atomic replacement recovery."""

    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.runtime = self.root / "build/sunshine"
        self.helper = self.root / "build/vd_helper"
        self.assets = self.root / "build/assets"
        self.icon = self.root / "sunshine.icns"
        self.entitlements = self.root / "entitlements.plist"
        self.runtime.parent.mkdir(parents=True)
        self.runtime.write_text("runtime\n")
        self.helper.write_text("helper\n")
        self.runtime.chmod(0o755)
        self.helper.chmod(0o755)
        (self.assets / "web").mkdir(parents=True)
        (self.assets / "web/index.html").write_text("web\n")
        self.icon.write_bytes(b"icon")
        self.entitlements.write_text("<?xml version=\"1.0\"?><plist version=\"1.0\"><dict/></plist>\n")
        self.destination = self.root / "Applications/Sunshine.app"

    def tearDown(self) -> None:
        self.temp.cleanup()

    def package(self) -> tuple[Path, Path | None]:
        """Call the packager with fixture inputs."""

        return PACKAGE_APP.package(
            self.runtime,
            self.helper,
            self.assets,
            self.destination,
            "Sunshine Local Signing",
            self.icon,
            self.entitlements,
            "0.0.0",
        )

    def test_rejects_adhoc_identity_before_touching_destination(self) -> None:
        """The explicit identity requirement is checked before replacement."""

        self.destination.mkdir(parents=True)
        marker = self.destination / "marker"
        marker.write_text("prior\n")

        with self.assertRaisesRegex(PACKAGE_APP.PackageError, "ad-hoc signing"):
            PACKAGE_APP.package(
                self.runtime,
                self.helper,
                self.assets,
                self.destination,
                "-",
                self.icon,
                self.entitlements,
                "0.0.0",
            )

        self.assertEqual(marker.read_text(), "prior\n")
        self.assertFalse(list(self.root.glob("Sunshine.app.previous-*")))

    def test_restores_previous_destination_when_install_verification_fails(self) -> None:
        """A failed post-install verification restores the prior application."""

        self.destination.mkdir(parents=True)
        marker = self.destination / "marker"
        marker.write_text("prior\n")

        def verify(path: Path) -> None:
            # The pre-install staged check succeeds; the post-replacement check
            # fails, forcing _install_atomically through its rollback path.
            if path.parent == self.destination.parent:
                raise PACKAGE_APP.PackageError("fixture verification failure")

        with mock.patch.object(PACKAGE_APP, "_sign"), mock.patch.object(PACKAGE_APP, "_verify", side_effect=verify):
            with self.assertRaisesRegex(PACKAGE_APP.PackageError, "fixture verification failure"):
                self.package()

        self.assertTrue(self.destination.is_dir())
        self.assertEqual(marker.read_text(), "prior\n")
        self.assertFalse(list(self.root.glob("Sunshine.app.previous-*")))

    def test_resolves_runtime_inside_app_bundle(self) -> None:
        """An executable under Contents/MacOS resolves to its containing app."""

        bundle = self.root / "Input.app"
        executable = bundle / "Contents/MacOS/Sunshine"
        executable.parent.mkdir(parents=True)
        executable.write_text("runtime\n")

        resolved_executable, resolved_bundle = PACKAGE_APP._resolve_runtime(executable)
        self.assertEqual(resolved_executable, executable.resolve())
        self.assertEqual(resolved_bundle, bundle.resolve())

        resolved_executable, resolved_bundle = PACKAGE_APP._resolve_runtime(bundle)
        self.assertEqual(resolved_executable, executable.resolve())
        self.assertEqual(resolved_bundle, bundle.resolve())


if __name__ == "__main__":
    unittest.main()
