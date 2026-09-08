#!/usr/bin/env python3
"""Fixture tests for the Sunshine direct-app service installer."""

from __future__ import annotations

import json
import os
import plistlib
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).with_name("sunshine_service.py")


class SunshineServiceTest(unittest.TestCase):
    """Exercise staging, activation, state backup, and rollback without macOS launchd."""

    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.home = self.root / "home"
        self.home.mkdir()
        self.recovery = self.root / "recovery"
        self.runtime = self.home / "Applications/Sunshine.app/Contents/MacOS/Sunshine"
        self.runtime.parent.mkdir(parents=True)
        self.runtime.write_text("#!/bin/sh\nexit 0\n")
        self.runtime.chmod(0o755)
        self.config = self.home / ".config/sunshine-personal/config/sunshine.conf"
        self.config.parent.mkdir(parents=True)
        self.config.write_text("port = 47989\n")
        self.launch_agents = self.home / "Library/LaunchAgents"
        self.launch_agents.mkdir(parents=True)
        self.fake_log = self.root / "launchctl.log"
        self.fake_launchctl = self.root / "launchctl"
        self.fake_launchctl.write_text(
            """#!/bin/sh
set -eu
echo "$@" >> "$FAKE_LAUNCHCTL_LOG"
case "$1" in
  bootout)
    case "$2" in
      */com.clayne.sunshine)
        [ "${FAKE_FAIL_BOOTOUT_SUNSHINE:-0}" = 1 ] && exit 41
        ;;
    esac
    ;;
  print-disabled)
    cat <<'EOF'
disabled services = {
    "com.clayne.lumen" => false
    "com.clayne.sunshine.staging" => true
    "com.clayne.sunshine" => true
}
EOF
    ;;
  print)
    case "$2" in
      */com.clayne.lumen|*/com.clayne.sunshine.staging) exit 0 ;;
      */com.clayne.sunshine) [ "${FAKE_SUNSHINE_LOADED:-0}" = 1 ] && exit 0 ;;
    esac
    exit 1
    ;;
  enable)
    case "$2" in
      */com.clayne.sunshine) : > "$FAKE_LAUNCHCTL_LOG.sunshine-enabled" ;;
    esac
    ;;
  bootstrap)
    case "$3" in
      *com.clayne.sunshine.plist)
        [ -f "$FAKE_LAUNCHCTL_LOG.sunshine-enabled" ] || exit 42
        ;;
    esac
    ;;
esac
exit 0
"""
        )
        self.fake_launchctl.chmod(0o755)

    def tearDown(self) -> None:
        self.temp.cleanup()

    def run_tool(self, *arguments: str, check: bool = True) -> subprocess.CompletedProcess[str]:
        env = os.environ.copy()
        env["FAKE_LAUNCHCTL_LOG"] = str(self.fake_log)
        env["FAKE_SUNSHINE_LOADED"] = "1" if getattr(self, "sunshine_loaded", False) else "0"
        env["FAKE_FAIL_BOOTOUT_SUNSHINE"] = "1" if getattr(self, "fail_bootout", False) else "0"
        result = subprocess.run(
            [sys.executable, str(SCRIPT), *arguments],
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        if check and result.returncode:
            self.fail(f"service tool failed: {result.stderr}\n{result.stdout}")
        return result

    def common_args(self) -> tuple[str, ...]:
        return (
            "--home",
            str(self.home),
            "--recovery-dir",
            str(self.recovery),
            "--runtime",
            str(self.runtime),
            "--config",
            str(self.config),
            "--launchctl",
            str(self.fake_launchctl),
            "--uid",
            "501",
            "--user",
            "fixture",
        )

    def old_plist_paths(self) -> dict[str, Path]:
        return {
            "com.clayne.lumen": self.launch_agents / "com.clayne.lumen.plist",
            "com.clayne.sunshine.staging": self.home
            / ".config/sunshine-personal/service/com.clayne.sunshine.staging.plist",
        }

    def manifest_from_output(self, output: str) -> Path:
        line = output.strip().splitlines()[-1]
        return Path(line.split(": ", 1)[1])

    def test_default_stages_direct_plist_without_live_mutation(self) -> None:
        result = self.run_tool(*self.common_args())
        manifest_path = self.manifest_from_output(result.stdout)
        manifest = json.loads(manifest_path.read_text())
        self.assertEqual(manifest["mode"], "staged")
        self.assertFalse((self.launch_agents / "com.clayne.sunshine.plist").exists())

        with manifest_path.parent.joinpath("staged/com.clayne.sunshine.plist").open("rb") as handle:
            plist = plistlib.load(handle)
        self.assertEqual(plist["Label"], "com.clayne.sunshine")
        self.assertEqual(plist["ProgramArguments"], [str(self.runtime), str(self.config)])
        self.assertEqual(plist["LimitLoadToSessionType"], "Aqua")
        self.assertTrue(plist["KeepAlive"])
        self.assertTrue(plist["RunAtLoad"])
        self.assertEqual(plist["ExitTimeOut"], 20)
        self.assertEqual(plist["ThrottleInterval"], 15)

    def test_activation_disables_legacy_jobs_and_rollback_restores_state(self) -> None:
        old_contents: dict[str, bytes] = {}
        for label, path in self.old_plist_paths().items():
            path.parent.mkdir(parents=True, exist_ok=True)
            old_contents[label] = f"legacy {label}\n".encode()
            path.write_bytes(old_contents[label])

        result = self.run_tool(*self.common_args(), "--activate")
        manifest_path = self.manifest_from_output(result.stdout)
        manifest = json.loads(manifest_path.read_text())
        self.assertEqual(manifest["mode"], "active")
        self.assertEqual(
            manifest["old_plists"][1],
            str(self.home / ".config/sunshine-personal/service/com.clayne.sunshine.staging.plist"),
        )
        self.assertEqual(manifest["activation"]["old_jobs"][0]["disabled_state"], {"listed": True, "disabled": False})
        self.assertEqual(manifest["activation"]["old_jobs"][1]["disabled_state"], {"listed": True, "disabled": True})

        live = self.launch_agents / "com.clayne.sunshine.plist"
        self.assertTrue(live.is_file())
        with live.open("rb") as handle:
            self.assertEqual(plistlib.load(handle)["ProgramArguments"], [str(self.runtime), str(self.config)])
        for label, contents in old_contents.items():
            self.assertEqual(self.old_plist_paths()[label].read_bytes(), contents)

        log = self.fake_log.read_text()
        self.assertIn("bootout gui/501/com.clayne.lumen", log)
        self.assertIn("bootout gui/501/com.clayne.sunshine.staging", log)
        self.assertIn("disable gui/501/com.clayne.lumen", log)
        self.assertIn("disable gui/501/com.clayne.sunshine.staging", log)
        self.assertIn(f"bootstrap gui/501 {live}", log)
        self.assertIn("enable gui/501/com.clayne.sunshine", log)
        self.assertLess(
            log.index("enable gui/501/com.clayne.sunshine"),
            log.index(f"bootstrap gui/501 {live}"),
        )

        self.run_tool("--rollback", str(manifest_path), "--launchctl", str(self.fake_launchctl))
        rolled = json.loads(manifest_path.read_text())
        self.assertEqual(rolled["mode"], "rolled_back")
        self.assertFalse(live.exists())
        for label, contents in old_contents.items():
            self.assertEqual(self.old_plist_paths()[label].read_bytes(), contents)
        log = self.fake_log.read_text()
        self.assertIn("bootout gui/501/com.clayne.sunshine", log)
        self.assertIn(f"bootstrap gui/501 {self.launch_agents / 'com.clayne.lumen.plist'}", log)
        self.assertIn(
            f"bootstrap gui/501 {self.old_plist_paths()['com.clayne.sunshine.staging']}", log
        )
        self.assertIn("enable gui/501/com.clayne.lumen", log)
        self.assertIn("disable gui/501/com.clayne.sunshine.staging", log)

    def test_rollback_restores_an_existing_sunshine_plist(self) -> None:
        live = self.launch_agents / "com.clayne.sunshine.plist"
        original = b"prior Sunshine plist\n"
        live.write_bytes(original)
        live.chmod(stat.S_IRUSR | stat.S_IWUSR)
        self.sunshine_loaded = True
        # The fixture launchctl reports both legacy labels as loaded, so give
        # the safety check the plist paths needed for rollback.
        for label, path in self.old_plist_paths().items():
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(f"legacy {label}\n".encode())

        result = self.run_tool(*self.common_args(), "--activate")
        manifest_path = self.manifest_from_output(result.stdout)
        self.assertNotEqual(live.read_bytes(), original)

        self.run_tool("--rollback", str(manifest_path), "--launchctl", str(self.fake_launchctl))
        self.assertEqual(live.read_bytes(), original)
        self.assertEqual(stat.S_IMODE(live.stat().st_mode), 0o600)

    def test_rollback_stops_before_bootstrap_when_sunshine_will_not_stop(self) -> None:
        live = self.launch_agents / "com.clayne.sunshine.plist"
        live.write_bytes(b"prior Sunshine plist\n")
        live.chmod(0o600)
        self.sunshine_loaded = True
        for label, path in self.old_plist_paths().items():
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(f"legacy {label}\n".encode())

        result = self.run_tool(*self.common_args(), "--activate")
        manifest_path = self.manifest_from_output(result.stdout)
        self.fake_log.write_text("")
        self.fail_bootout = True

        failed = self.run_tool(
            "--rollback",
            str(manifest_path),
            "--launchctl",
            str(self.fake_launchctl),
            check=False,
        )
        self.assertNotEqual(failed.returncode, 0)
        self.assertTrue(live.exists())
        self.assertNotIn("bootstrap ", self.fake_log.read_text())
        manifest = json.loads(manifest_path.read_text())
        self.assertIn("rollback_error", manifest)


if __name__ == "__main__":
    unittest.main()
