#!/usr/bin/env python3
"""Stage, activate, and roll back Sunshine's direct macOS LaunchAgent.

The default operation is deliberately read-only with respect to the live
LaunchAgent and launchd state.  ``--activate`` is the explicit opt-in that
performs the launchctl changes; ``--rollback`` consumes the activation
manifest created by that operation.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import plistlib
import re
import shutil
import stat
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any, Iterable


LABEL = "com.clayne.sunshine"
DEFAULT_OLD_LABELS = ("com.clayne.lumen", "com.clayne.sunshine.staging")
DEFAULT_OLD_PLIST_RELATIVE = {
    "com.clayne.lumen": Path("Library/LaunchAgents/com.clayne.lumen.plist"),
    "com.clayne.sunshine.staging": Path(
        ".config/sunshine-personal/service/com.clayne.sunshine.staging.plist"
    ),
}
DEFAULT_WEB_PORT = 47990
SCHEMA_VERSION = 1


class ServiceError(RuntimeError):
    """Raised when a service operation cannot be completed safely."""


def _now() -> str:
    """Return a sortable local timestamp for manifests and staging paths."""

    return dt.datetime.now().astimezone().isoformat(timespec="seconds")


def _unlink(path: Path) -> None:
    """Remove a file or symlink without following the symlink."""

    if path.is_symlink() or path.is_file():
        path.unlink()
    elif path.exists():
        raise ServiceError(f"refusing to remove non-file path: {path}")


def _atomic_bytes(path: Path, content: bytes, mode: int = 0o644) -> None:
    """Atomically replace a regular file and apply its requested mode."""

    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    temporary_path = Path(temporary)
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(content)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary_path, mode)
        os.replace(temporary_path, path)
    finally:
        if temporary_path.exists():
            temporary_path.unlink()


def _atomic_json(path: Path, value: dict[str, Any]) -> None:
    """Write a human-readable manifest atomically."""

    content = (json.dumps(value, indent=2, sort_keys=True) + "\n").encode()
    _atomic_bytes(path, content)


def _plist_bytes(value: dict[str, Any]) -> bytes:
    """Serialize a LaunchAgent property list in portable XML form."""

    return plistlib.dumps(value, fmt=plistlib.FMT_XML, sort_keys=False)


def _path(value: str | Path, home: Path) -> Path:
    """Expand a user path, retaining relative paths relative to the cwd."""

    expanded = Path(value).expanduser()
    if not expanded.is_absolute():
        return (Path.cwd() / expanded).resolve()
    return expanded


def _default_runtime(home: Path) -> Path:
    """Return the selected Sunshine app executable for this home directory."""

    return home / "Applications/Sunshine.app/Contents/MacOS/Sunshine"


def _default_config(home: Path) -> Path:
    """Return the isolated Sunshine configuration used by the direct app."""

    return home / ".config/sunshine-personal/config/sunshine.conf"


def _plist(home: Path, runtime: Path, config: Path, user: str) -> dict[str, Any]:
    """Build a direct-app Aqua LaunchAgent property list."""

    return {
        "Label": LABEL,
        "ProgramArguments": [str(runtime), str(config)],
        "WorkingDirectory": str(home),
        "EnvironmentVariables": {
            "HOME": str(home),
            "LOGNAME": user,
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "USER": user,
        },
        "RunAtLoad": True,
        "KeepAlive": True,
        "ExitTimeOut": 20,
        "ThrottleInterval": 15,
        "LimitLoadToSessionType": "Aqua",
        "ProcessType": "Interactive",
        "StandardOutPath": str(home / "Library/Logs/sunshine.stdout.log"),
        "StandardErrorPath": str(home / "Library/Logs/sunshine.stderr.log"),
    }


def _snapshot(path: Path, backup_dir: Path, name: str) -> dict[str, Any]:
    """Snapshot a file or symlink and return enough metadata to restore it."""

    record: dict[str, Any] = {"path": str(path), "present": False, "kind": "absent"}
    if path.is_symlink():
        backup = backup_dir / f"{name}.symlink"
        backup_dir.mkdir(parents=True, exist_ok=True)
        backup.write_text(os.readlink(path))
        record.update({"present": True, "kind": "symlink", "backup": str(backup)})
    elif path.is_file():
        backup = backup_dir / name
        backup_dir.mkdir(parents=True, exist_ok=True)
        shutil.copy2(path, backup)
        record.update(
            {
                "present": True,
                "kind": "file",
                "backup": str(backup),
                "mode": stat.S_IMODE(path.stat().st_mode),
            }
        )
    elif path.exists():
        raise ServiceError(f"refusing to replace non-file path: {path}")
    return record


def _restore_snapshot(record: dict[str, Any]) -> None:
    """Restore a snapshot, or remove the target when it was originally absent."""

    path = Path(record["path"])
    kind = record.get("kind", "absent")
    if kind == "absent":
        _unlink(path)
        return
    if kind == "symlink":
        target = Path(record["backup"]).read_text()
        _unlink(path)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.symlink_to(target)
        return
    if kind != "file":
        raise ServiceError(f"unknown snapshot kind for {path}: {kind}")

    backup = Path(record["backup"])
    if not backup.is_file():
        raise ServiceError(f"snapshot is missing: {backup}")
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.restore.", dir=path.parent)
    temporary_path = Path(temporary)
    try:
        os.close(fd)
        shutil.copy2(backup, temporary_path)
        os.chmod(temporary_path, int(record.get("mode", 0o644)))
        os.replace(temporary_path, path)
    finally:
        if temporary_path.exists():
            temporary_path.unlink()


class LaunchCtl:
    """Small subprocess wrapper kept injectable for fixture tests."""

    def __init__(self, executable: Path, domain: str):
        self.executable = executable
        self.domain = domain

    def run(self, *arguments: str) -> subprocess.CompletedProcess[str]:
        """Run launchctl without a shell and capture its diagnostic output."""

        return subprocess.run(
            [str(self.executable), *arguments],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )

    def require(self, *arguments: str) -> None:
        """Run launchctl and raise with its stderr when it fails."""

        result = self.run(*arguments)
        if result.returncode:
            detail = result.stderr.strip() or result.stdout.strip() or "no diagnostic"
            raise ServiceError(f"launchctl {' '.join(arguments)} failed: {detail}")

    def best_effort(self, *arguments: str) -> None:
        """Run a cleanup launchctl command while tolerating an unloaded job."""

        self.run(*arguments)

    def loaded(self, label: str) -> bool:
        """Return whether launchd currently reports a job as loaded."""

        return self.run("print", f"{self.domain}/{label}").returncode == 0

    def disabled_states(self) -> dict[str, bool]:
        """Read launchd's disabled map for enabled-state backup."""

        result = self.run("print-disabled", self.domain)
        if result.returncode:
            detail = result.stderr.strip() or result.stdout.strip() or "no diagnostic"
            raise ServiceError(f"launchctl print-disabled failed: {detail}")
        return {
            label: value == "true"
            for label, value in re.findall(r'"([^"]+)"\s*=>\s*(true|false)', result.stdout)
        }


def _state(disabled: dict[str, bool], label: str) -> dict[str, Any]:
    """Represent both an explicit disabled entry and an absent entry."""

    return {
        "listed": label in disabled,
        "disabled": bool(disabled.get(label, False)),
    }


def _restore_disabled(launchctl: LaunchCtl, label: str, state: dict[str, Any]) -> None:
    """Restore enabled semantics; launchctl has no portable delete-map command."""

    target = f"{launchctl.domain}/{label}"
    if state.get("listed") and state.get("disabled"):
        launchctl.require("disable", target)
    else:
        # enable restores both an explicit false entry and an originally
        # absent entry's behavior.  launchctl may retain a false map entry.
        launchctl.require("enable", target)


def _bootout(launchctl: LaunchCtl, label: str, was_loaded: bool) -> None:
    """Unload a known job strictly, while tolerating an already-unloaded one."""

    target = f"{launchctl.domain}/{label}"
    if was_loaded:
        launchctl.require("bootout", target)
    else:
        launchctl.best_effort("bootout", target)


def _old_labels(args: argparse.Namespace) -> tuple[str, ...]:
    """Resolve old service labels, allowing a deployment-specific override."""

    return tuple(args.old_label) if args.old_label else DEFAULT_OLD_LABELS


def _old_plists(args: argparse.Namespace, home: Path, labels: tuple[str, ...]) -> tuple[Path, ...]:
    """Resolve legacy plist locations, including Sunshine's staging path."""

    if args.old_plist:
        if len(args.old_plist) != len(labels):
            raise ServiceError("--old-plist must be repeated once for each --old-label")
        return tuple(_path(value, home) for value in args.old_plist)
    return tuple(
        home / DEFAULT_OLD_PLIST_RELATIVE.get(label, Path("Library/LaunchAgents") / f"{label}.plist")
        for label in labels
    )


def _common_values(args: argparse.Namespace) -> dict[str, Any]:
    """Resolve paths and identity values shared by stage and activation."""

    home = _path(args.home or str(Path.home()), Path.cwd())
    runtime = _path(args.runtime or str(_default_runtime(home)), home)
    config = _path(args.config or str(_default_config(home)), home)
    recovery = _path(
        args.recovery_dir or str(home / "Library/Application Support/Sunshine/service-recovery"),
        home,
    )
    user = args.user or os.environ.get("USER") or os.environ.get("LOGNAME") or "sunshine"
    uid = str(args.uid if args.uid is not None else os.getuid())
    labels = _old_labels(args)
    return {
        "home": home,
        "runtime": runtime,
        "config": config,
        "recovery": recovery,
        "user": user,
        "uid": uid,
        "domain": f"gui/{uid}",
        "launchctl": _path(args.launchctl or "/bin/launchctl", home),
        "web_port": args.web_port,
        "old_labels": labels,
        "old_plists": _old_plists(args, home, labels),
    }


def _stage(values: dict[str, Any]) -> tuple[Path, dict[str, Any]]:
    """Create an isolated plist and review manifest without touching launchd."""

    port = values["web_port"]
    if not isinstance(port, int) or not 1024 <= port <= 65535:
        raise ServiceError(f"web port must be an integer between 1024 and 65535: {port}")
    recovery = values["recovery"]
    recovery.mkdir(parents=True, exist_ok=True)
    stamp = dt.datetime.now().strftime("%Y%m%d-%H%M%S")
    session = Path(tempfile.mkdtemp(prefix=f"service-{stamp}-", dir=recovery))
    staged = session / "staged" / f"{LABEL}.plist"
    _atomic_bytes(
        staged,
        _plist_bytes(_plist(values["home"], values["runtime"], values["config"], values["user"])),
    )
    live = values["home"] / "Library/LaunchAgents" / f"{LABEL}.plist"
    manifest = {
        "schema": SCHEMA_VERSION,
        "mode": "staged",
        "created_at": _now(),
        "label": LABEL,
        "home": str(values["home"]),
        "uid": values["uid"],
        "domain": values["domain"],
        "user": values["user"],
        "runtime": str(values["runtime"]),
        "config": str(values["config"]),
        "web_port": values["web_port"],
        "launchctl": str(values["launchctl"]),
        "old_labels": list(values["old_labels"]),
        "old_plists": [str(path) for path in values["old_plists"]],
        "staged_plist": str(staged),
        "live_plist": str(live),
        "session_dir": str(session),
    }
    manifest_path = session / "manifest.json"
    manifest["manifest"] = str(manifest_path)
    _atomic_json(manifest_path, manifest)
    return manifest_path, manifest


def _validate_activation(values: dict[str, Any]) -> None:
    """Refuse activation until the requested executable and config are present."""

    runtime = values["runtime"]
    config = values["config"]
    if not runtime.is_file() or not os.access(runtime, os.X_OK):
        raise ServiceError(f"runtime is not executable: {runtime}")
    if not config.is_file():
        raise ServiceError(f"configuration file is missing: {config}")
    port = values["web_port"]
    if not isinstance(port, int) or not 1024 <= port <= 65535:
        raise ServiceError(f"web port must be an integer between 1024 and 65535: {port}")


def _activation_state(values: dict[str, Any], session: Path, launchctl: LaunchCtl) -> dict[str, Any]:
    """Capture launchd state needed for an exact service rollback."""

    disabled = launchctl.disabled_states()
    old_jobs: list[dict[str, Any]] = []
    for label, plist in zip(values["old_labels"], values["old_plists"]):
        loaded = launchctl.loaded(label)
        if loaded and not plist.is_file() and not plist.is_symlink():
            raise ServiceError(
                f"old loaded job {label} has no expected plist at {plist}; refusing irreversible activation"
            )
        old_jobs.append(
            {
                "label": label,
                "plist": str(plist),
                "loaded": loaded,
                "disabled_state": _state(disabled, label),
            }
        )

    live = values["home"] / "Library/LaunchAgents" / f"{LABEL}.plist"
    sunshine_loaded = launchctl.loaded(LABEL)
    if sunshine_loaded and not live.is_file() and not live.is_symlink():
        raise ServiceError(
            f"loaded {LABEL} has no expected plist at {live}; refusing irreversible activation"
        )
    return {
        "sunshine": {
            "label": LABEL,
            "plist": str(live),
            "loaded": sunshine_loaded,
            "disabled_state": _state(disabled, LABEL),
            "snapshot": _snapshot(live, session / "backup", "sunshine.plist"),
        },
        "old_jobs": old_jobs,
    }


def _write_activation_plist(manifest: dict[str, Any]) -> None:
    """Install the staged direct-app plist atomically at its live path."""

    staged = Path(manifest["staged_plist"])
    live = Path(manifest["live_plist"])
    if not staged.is_file():
        raise ServiceError(f"staged plist is missing: {staged}")
    _atomic_bytes(live, staged.read_bytes())


def _activate(values: dict[str, Any]) -> Path:
    """Activate Sunshine after writing a complete rollback manifest."""

    _validate_activation(values)
    manifest_path, manifest = _stage(values)
    session = Path(manifest["session_dir"])
    launchctl = LaunchCtl(values["launchctl"], values["domain"])
    manifest["mode"] = "activation-pending"
    try:
        manifest["activation"] = _activation_state(values, session, launchctl)
        _atomic_json(manifest_path, manifest)
        _write_activation_plist(manifest)

        for job in manifest["activation"]["old_jobs"]:
            _bootout(launchctl, job["label"], job["loaded"])
        _bootout(launchctl, LABEL, manifest["activation"]["sunshine"]["loaded"])
        for label in values["old_labels"]:
            launchctl.require("disable", values["domain"] + "/" + label)
        # A previously disabled Sunshine label rejects bootstrap on macOS.
        # Enable it first; the new service is intentionally enabled.
        launchctl.require("enable", values["domain"] + "/" + LABEL)
        launchctl.require("bootstrap", values["domain"], manifest["live_plist"])
        manifest["mode"] = "active"
        manifest["activated_at"] = _now()
        _atomic_json(manifest_path, manifest)
    except Exception as error:
        manifest["error"] = str(error)
        _atomic_json(manifest_path, manifest)
        if "activation" not in manifest:
            raise ServiceError(f"activation was not started: {error}") from error
        try:
            _rollback(manifest, launchctl, quiet=True)
        except Exception as rollback_error:
            raise ServiceError(f"activation failed ({error}); rollback failed ({rollback_error})") from error
        raise ServiceError(f"activation failed and was rolled back: {error}") from error
    return manifest_path


def _rollback(manifest: dict[str, Any], launchctl: LaunchCtl | None = None, quiet: bool = False) -> None:
    """Restore the pre-activation plist and launchd state from a manifest."""

    if manifest.get("schema") != SCHEMA_VERSION or manifest.get("label") != LABEL:
        raise ServiceError("manifest is not a Sunshine service manifest")
    if manifest.get("mode") not in {"active", "activation-pending"}:
        raise ServiceError(f"manifest is not active or pending: {manifest.get('mode')}")

    if launchctl is None:
        launchctl = LaunchCtl(Path(manifest["launchctl"]), str(manifest["domain"]))
    domain = str(manifest["domain"])
    activation = manifest.get("activation") or {}
    sunshine = activation.get("sunshine")
    if not sunshine:
        raise ServiceError("manifest has no Sunshine launchd snapshot")

    errors: list[str] = []

    def attempt(description: str, operation: Any) -> None:
        try:
            operation()
        except Exception as error:  # pragma: no cover - exercised by real launchctl failures
            errors.append(f"{description}: {error}")

    for job in [*activation.get("old_jobs", []), sunshine]:
        label = str(job["label"])
        attempt(
            f"bootout {label}",
            lambda label=label: _bootout(launchctl, label, launchctl.loaded(label)),
        )
    if errors:
        message = "; ".join(errors)
        manifest["rollback_error"] = message
        manifest["rollback_failed_at"] = _now()
        _atomic_json(Path(manifest["manifest"]), manifest)
        raise ServiceError(f"rollback stopped before plist restore/bootstrap: {message}")

    attempt(
        "restore Sunshine plist",
        lambda: _restore_snapshot(sunshine["snapshot"]),
    )

    jobs_to_bootstrap = [job for job in activation.get("old_jobs", []) if job.get("loaded")]
    if sunshine.get("loaded") and sunshine["snapshot"].get("present"):
        jobs_to_bootstrap.append(sunshine)

    # An old job that was disabled needs a temporary enable for bootstrap.
    # Jobs that were not loaded can have their final state restored immediately.
    for job in [*activation.get("old_jobs", []), sunshine]:
        if job not in jobs_to_bootstrap:
            label = str(job["label"])
            attempt(
                f"restore enabled state for {label}",
                lambda label=label, job=job: _restore_disabled(
                    launchctl, label, job["disabled_state"]
                ),
            )
        else:
            label = str(job["label"])
            attempt(
                f"temporarily enable {label}",
                lambda label=label: launchctl.require("enable", f"{domain}/{label}"),
            )

    for job in activation.get("old_jobs", []):
        if not job.get("loaded"):
            continue
        plist = Path(job["plist"])
        attempt(
            f"bootstrap {job['label']}",
            lambda plist=plist: launchctl.require("bootstrap", domain, str(plist)),
        )
    if sunshine in jobs_to_bootstrap:
        attempt(
            f"bootstrap {LABEL}",
            lambda: launchctl.require("bootstrap", domain, str(sunshine["plist"])),
        )

    for job in activation.get("old_jobs", []):
        label = str(job["label"])
        attempt(
            f"restore enabled state for {label}",
            lambda label=label, job=job: _restore_disabled(
                launchctl, label, job["disabled_state"]
            ),
        )
    attempt(
        f"restore enabled state for {LABEL}",
        lambda: _restore_disabled(launchctl, LABEL, sunshine["disabled_state"]),
    )

    if errors:
        message = "; ".join(errors)
        manifest["rollback_error"] = message
        manifest["rollback_failed_at"] = _now()
        _atomic_json(Path(manifest["manifest"]), manifest)
        raise ServiceError(message)
    manifest["mode"] = "rolled_back"
    manifest["rolled_back_at"] = _now()
    _atomic_json(Path(manifest["manifest"]), manifest)
    if not quiet:
        print(f"Rolled back {LABEL}: {manifest['manifest']}")


def _parser() -> argparse.ArgumentParser:
    """Build the command-line interface."""

    parser = argparse.ArgumentParser(
        description="Stage or explicitly activate Sunshine's direct-app Aqua LaunchAgent."
    )
    operation = parser.add_mutually_exclusive_group()
    operation.add_argument("--activate", action="store_true", help="write the plist and mutate launchd")
    operation.add_argument("--rollback", metavar="MANIFEST", help="restore an activation manifest")
    parser.add_argument("--home", help=argparse.SUPPRESS)
    parser.add_argument("--runtime", help="Sunshine executable (default: Sunshine.app)")
    parser.add_argument("--config", help="Sunshine config path")
    parser.add_argument("--recovery-dir", help="staging and rollback root")
    parser.add_argument("--web-port", type=int, default=DEFAULT_WEB_PORT, help="documented UI port")
    parser.add_argument("--launchctl", help=argparse.SUPPRESS)
    parser.add_argument("--uid", type=int, help=argparse.SUPPRESS)
    parser.add_argument("--user", help=argparse.SUPPRESS)
    parser.add_argument(
        "--old-label",
        action="append",
        help="legacy label to boot out and disable (repeatable; defaults to Lumen labels)",
    )
    parser.add_argument(
        "--old-plist",
        action="append",
        help="legacy plist path matching each --old-label (repeatable)",
    )
    return parser


def main(argv: Iterable[str] | None = None) -> int:
    """Run the requested service operation and print its reviewable artifact."""

    args = _parser().parse_args(list(argv) if argv is not None else None)
    try:
        if args.rollback:
            manifest_path = _path(args.rollback, Path.cwd())
            manifest = json.loads(manifest_path.read_text())
            launch_path = _path(args.launchctl, Path(manifest["home"])) if args.launchctl else None
            launch = LaunchCtl(launch_path, str(manifest["domain"])) if launch_path else None
            _rollback(manifest, launch)
            return 0

        values = _common_values(args)
        if args.activate:
            manifest_path = _activate(values)
            print(f"Activated {LABEL}; rollback manifest: {manifest_path}")
        else:
            manifest_path, _ = _stage(values)
            print(f"Staged direct-app plist; review manifest: {manifest_path}")
        return 0
    except (OSError, ServiceError, json.JSONDecodeError, KeyError) as error:
        print(f"sunshine_service: {error}", file=sys.stderr)
        return 78


if __name__ == "__main__":
    raise SystemExit(main())
