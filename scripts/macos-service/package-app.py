#!/usr/bin/env python3
"""Package an existing Sunshine build as a signed macOS application.

The script copies an already-built executable, its virtual-display helper, and
the selected assets into an isolated ``Sunshine.app`` bundle.  It never builds,
starts, or modifies a LaunchAgent.  A signing identity is mandatory: the
private key is left in the user's Keychain and is accessed only by
``/usr/bin/codesign``.
"""

from __future__ import annotations

import argparse
import datetime as dt
import os
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Iterable


BUNDLE_ID = "com.clayne.sunshine"
BUNDLE_NAME = "Sunshine"
SCRIPT_REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_ICON = SCRIPT_REPO_ROOT / "src_assets/macos/build/sunshine.icns"
DEFAULT_ENTITLEMENTS = SCRIPT_REPO_ROOT / "src_assets/macos/entitlements.plist"
VERSION_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")


class PackageError(RuntimeError):
    """Raised when a bundle cannot be staged or installed safely."""


def _run(*arguments: str, capture: bool = False) -> str:
    """Run a macOS tool without a shell and return captured output."""

    try:
        result = subprocess.run(
            list(arguments),
            check=True,
            text=True,
            stdout=subprocess.PIPE if capture else None,
            stderr=subprocess.STDOUT if capture else None,
        )
    except FileNotFoundError as error:
        raise PackageError(f"required macOS tool is missing: {arguments[0]}") from error
    except subprocess.CalledProcessError as error:
        detail = (error.stdout or "").strip()
        suffix = f": {detail}" if detail else ""
        raise PackageError(f"{arguments[0]} failed with status {error.returncode}{suffix}") from error
    return result.stdout or ""


def _path(value: str | Path, base: Path) -> Path:
    """Expand a path and resolve relative values against ``base``.

    The final component is deliberately not symlink-resolved.  An existing
    destination symlink must be replaced and backed up as a symlink rather
    than followed to an unrelated application bundle.
    """

    candidate = Path(value).expanduser()
    if not candidate.is_absolute():
        candidate = base / candidate
    return Path(os.path.abspath(candidate))


def _present(path: Path) -> bool:
    """Return true for a regular path or a symlink, including broken links."""

    return path.exists() or path.is_symlink()


def _require_file(path: Path, description: str, executable: bool = False) -> None:
    """Validate an input file before any destination is changed."""

    if not path.is_file():
        raise PackageError(f"{description} is not a file: {path}")
    if executable and not os.access(path, os.X_OK):
        raise PackageError(f"{description} is not executable: {path}")


def _require_directory(path: Path, description: str) -> None:
    """Validate an input directory before any destination is changed."""

    if not path.is_dir():
        raise PackageError(f"{description} is not a directory: {path}")


def _build_roots(repo: Path) -> list[Path]:
    """Return conventional local build roots in a stable order."""

    candidates = [repo / "build"]
    candidates.extend(sorted(repo.glob("cmake-build-*")))
    candidates.append(repo / "cmake-build")
    result: list[Path] = []
    for candidate in candidates:
        if candidate not in result and candidate.is_dir():
            result.append(candidate)
    return result


def _find_runtime(repo: Path, home: Path) -> Path:
    """Find a built Sunshine executable without using a machine-specific path."""

    candidates: list[Path] = []
    for root in _build_roots(repo):
        candidates.extend(
            [
                root / "Sunshine.app/Contents/MacOS/Sunshine",
                root / "sunshine",
                root / "Sunshine",
            ]
        )
    candidates.append(home / "Applications/Sunshine.app/Contents/MacOS/Sunshine")
    for candidate in candidates:
        if candidate.is_file():
            return candidate.resolve()
    searched = ", ".join(str(candidate) for candidate in candidates)
    raise PackageError(f"could not find a built Sunshine executable; pass --runtime (searched: {searched})")


def _resolve_runtime(value: Path) -> tuple[Path, Path | None]:
    """Resolve an executable or an existing ``.app`` into its main binary."""

    value = value.resolve()
    if value.is_dir() and value.suffix == ".app":
        bundle = value
        executable = bundle / "Contents/MacOS/Sunshine"
        return executable, bundle
    bundle = None
    if value.parent.name == "MacOS" and value.parent.parent.parent.suffix == ".app":
        bundle = value.parent.parent.parent
    return value, bundle


def _find_helper(runtime: Path, source_bundle: Path | None, repo: Path, home: Path) -> Path:
    """Find the virtual-display helper adjacent to the selected runtime."""

    candidates: list[Path] = []
    if source_bundle:
        candidates.append(source_bundle / "Contents/MacOS/vd_helper")
    candidates.append(runtime.parent / "vd_helper")
    for root in _build_roots(repo):
        candidates.append(root / "vd_helper")
    candidates.append(home / "Applications/Sunshine.app/Contents/MacOS/vd_helper")
    for candidate in candidates:
        if candidate.is_file():
            return candidate.resolve()
    searched = ", ".join(str(candidate) for candidate in candidates)
    raise PackageError(f"could not find vd_helper; pass --helper (searched: {searched})")


def _find_assets(runtime: Path, source_bundle: Path | None, repo: Path) -> Path:
    """Find built web and application assets for the bundle."""

    candidates: list[Path] = []
    if source_bundle:
        candidates.append(source_bundle / "Contents/Resources/assets")
    for root in _build_roots(repo):
        candidates.append(root / "assets")
    for candidate in candidates:
        if (candidate / "web/index.html").is_file():
            return candidate.resolve()
    searched = ", ".join(str(candidate) for candidate in candidates)
    raise PackageError(f"could not find built assets; pass --assets (searched: {searched})")


def _source_code_paths(source_bundle: Path | None, staged: Path) -> None:
    """Copy optional nested code directories from an input application bundle."""

    if not source_bundle:
        return
    for relative in ("Contents/Frameworks", "Contents/PlugIns", "Contents/XPCServices"):
        source = source_bundle / relative
        if source.is_dir():
            shutil.copytree(source, staged / relative, symlinks=True)


def _nested_signing_targets(bundle: Path, helper: Path) -> list[Path]:
    """Return nested code paths, with the virtual-display helper first."""

    targets = [helper]
    code_roots = [bundle / "Contents/Frameworks", bundle / "Contents/PlugIns", bundle / "Contents/XPCServices"]
    nested_files: list[Path] = []
    nested_bundles: list[Path] = []
    for root in code_roots:
        if not root.is_dir():
            continue
        for path in root.rglob("*"):
            if path.is_symlink():
                continue
            if path.is_file() and os.access(path, os.X_OK):
                nested_files.append(path)
            elif path.is_dir() and path.suffix in {".app", ".bundle", ".framework", ".xpc"}:
                nested_bundles.append(path)

    # Sign executable leaves before their containing framework or bundle.
    targets.extend(sorted(nested_files, key=lambda path: (len(path.parts), str(path)), reverse=True))
    targets.extend(sorted(nested_bundles, key=lambda path: (len(path.parts), str(path)), reverse=True))
    return targets


def _sign(path: Path, identity: str, entitlements: Path | None = None) -> None:
    """Sign one code object with the explicit Keychain identity."""

    arguments = [
        "/usr/bin/codesign",
        "--force",
        "--timestamp=none",
        "--sign",
        identity,
    ]
    if entitlements:
        arguments.extend(["--entitlements", str(entitlements)])
    arguments.append(str(path))
    _run(*arguments)


def _verify(bundle: Path) -> None:
    """Verify the bundle signature and its property list."""

    _run("/usr/bin/codesign", "--verify", "--deep", "--strict", "--verbose=2", str(bundle))
    _run("/usr/bin/plutil", "-lint", str(bundle / "Contents/Info.plist"))
    with (bundle / "Contents/Info.plist").open("rb") as handle:
        info = plistlib.load(handle)
    if info.get("CFBundleIdentifier") != BUNDLE_ID:
        raise PackageError(f"unexpected bundle identifier in {bundle}")
    if info.get("CFBundleName") != BUNDLE_NAME or info.get("CFBundleExecutable") != BUNDLE_NAME:
        raise PackageError(f"unexpected Sunshine bundle metadata in {bundle}")


def _remove(path: Path) -> None:
    """Remove a staged bundle or symlink without following a symlink."""

    if path.is_symlink() or path.is_file():
        path.unlink()
    elif path.is_dir():
        shutil.rmtree(path)


def _backup_path(destination: Path) -> Path:
    """Choose a unique same-directory path for an atomic previous-bundle backup."""

    stamp = dt.datetime.now().strftime("%Y%m%d-%H%M%S")
    base = destination.with_name(f"{destination.name}.previous-{stamp}")
    candidate = base
    suffix = 1
    while _present(candidate):
        candidate = base.with_name(f"{base.name}-{suffix:02d}")
        suffix += 1
    return candidate


def _install_atomically(staged: Path, destination: Path) -> Path | None:
    """Atomically replace the destination and restore it if verification fails."""

    previous: Path | None = None
    moved_previous = False
    try:
        if _present(destination):
            previous = _backup_path(destination)
            os.replace(destination, previous)
            moved_previous = True
        os.replace(staged, destination)
        try:
            _verify(destination)
        except Exception:
            _remove(destination)
            raise
    except Exception:
        if moved_previous and previous and _present(previous) and not _present(destination):
            os.replace(previous, destination)
        raise
    return previous


def _bundle_info(version: str) -> dict[str, object]:
    """Build the stable Sunshine application metadata."""

    return {
        "CFBundleIdentifier": BUNDLE_ID,
        "CFBundleName": BUNDLE_NAME,
        "CFBundleDisplayName": BUNDLE_NAME,
        "CFBundleExecutable": BUNDLE_NAME,
        "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": version,
        "CFBundleVersion": version,
        "CFBundleIconFile": "sunshine.icns",
        "LSApplicationCategoryType": "public.app-category.utilities",
        "LSUIElement": True,
        "NSMicrophoneUsageDescription": "Sunshine requires access to your microphone to stream audio.",
        "NSAudioCaptureUsageDescription": "Sunshine requires access to system audio to capture and stream audio output.",
        "NSScreenCaptureUsageDescription": "Sunshine requires access to screen recording to capture and stream your screen content.",
        "NSLocalNetworkUsageDescription": "Sunshine advertises itself on your local network via Bonjour so Moonlight clients can discover this host.",
        "NSBonjourServices": ["_nvstream._tcp"],
    }


def package(
    runtime: Path,
    helper: Path,
    assets: Path,
    destination: Path,
    identity: str,
    icon: Path,
    entitlements: Path,
    version: str,
    config: Path | None = None,
) -> tuple[Path, Path | None]:
    """Stage, sign, verify, and atomically install a Sunshine application."""

    if not identity.strip() or identity.strip() == "-":
        raise PackageError("--signing-identity must name a Keychain certificate; ad-hoc signing is not supported")
    if not VERSION_PATTERN.fullmatch(version):
        raise PackageError(f"invalid bundle version: {version}")
    if destination.name != "Sunshine.app":
        raise PackageError("--destination must name Sunshine.app")

    runtime, source_bundle = _resolve_runtime(runtime)
    _require_file(runtime, "Sunshine runtime", executable=True)
    _require_file(helper, "vd_helper", executable=True)
    _require_directory(assets, "assets")
    _require_file(icon, "application icon")
    _require_file(entitlements, "application entitlements")
    if config is not None:
        _require_file(config, "optional config")

    destination = Path(os.path.abspath(destination.expanduser()))
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="Sunshine.app.tmp-", dir=destination.parent) as temporary:
        staged = Path(temporary) / "Sunshine.app"
        macos = staged / "Contents/MacOS"
        resources = staged / "Contents/Resources"
        macos.mkdir(parents=True)
        resources.mkdir(parents=True)

        staged_runtime = macos / BUNDLE_NAME
        staged_helper = macos / "vd_helper"
        shutil.copy2(runtime, staged_runtime)
        shutil.copy2(helper, staged_helper)
        staged_runtime.chmod(0o755)
        staged_helper.chmod(0o755)
        _source_code_paths(source_bundle, staged)
        shutil.copy2(icon, resources / "sunshine.icns")
        shutil.copytree(assets, resources / "assets", symlinks=True)

        with (staged / "Contents/Info.plist").open("wb") as handle:
            plistlib.dump(_bundle_info(version), handle, fmt=plistlib.FMT_XML, sort_keys=False)

        # Nested code must be signed before the enclosing application.
        for target in _nested_signing_targets(staged, staged_helper):
            _sign(target, identity)
        _sign(staged, identity, entitlements)
        _verify(staged)

        previous = _install_atomically(staged, destination)
    return destination, previous


def _parser() -> argparse.ArgumentParser:
    """Build the command-line interface."""

    parser = argparse.ArgumentParser(
        description="Package and sign an existing Sunshine build as Sunshine.app."
    )
    parser.add_argument(
        "--signing-identity",
        required=True,
        help="explicit Keychain code-signing certificate name or SHA-1 fingerprint",
    )
    parser.add_argument("--runtime", type=Path, help="built Sunshine executable or .app")
    parser.add_argument("--helper", type=Path, help="built vd_helper executable")
    parser.add_argument("--assets", type=Path, help="built assets directory containing web/index.html")
    parser.add_argument("--config", type=Path, help="optional config to validate; never copied into the app")
    parser.add_argument(
        "--destination",
        type=Path,
        help="output path (default: ~/Applications/Sunshine.app)",
    )
    parser.add_argument(
        "--icon",
        type=Path,
        default=DEFAULT_ICON,
        help="application icon (default: repository macOS icon)",
    )
    parser.add_argument(
        "--entitlements",
        type=Path,
        default=DEFAULT_ENTITLEMENTS,
        help="application entitlements (default: repository macOS entitlements)",
    )
    parser.add_argument("--version", default="0.0.0", help="bundle version (default: 0.0.0)")
    parser.add_argument(
        "--repo",
        type=Path,
        default=SCRIPT_REPO_ROOT,
        help=argparse.SUPPRESS,
    )
    parser.add_argument("--home", type=Path, default=Path.home(), help=argparse.SUPPRESS)
    return parser


def main(argv: Iterable[str] | None = None) -> int:
    """Resolve inputs and package the requested Sunshine application."""

    args = _parser().parse_args(list(argv) if argv is not None else None)
    try:
        home = _path(args.home, Path.cwd())
        repo = _path(args.repo, Path.cwd())
        runtime = _path(args.runtime, repo) if args.runtime else _find_runtime(repo, home)
        runtime, source_bundle = _resolve_runtime(runtime)
        helper = _path(args.helper, repo) if args.helper else _find_helper(runtime, source_bundle, repo, home)
        assets = _path(args.assets, repo) if args.assets else _find_assets(runtime, source_bundle, repo)
        destination = _path(args.destination, home) if args.destination else home / "Applications/Sunshine.app"
        icon = _path(args.icon, repo)
        entitlements = _path(args.entitlements, repo)
        config = _path(args.config, home) if args.config else None
        installed, previous = package(
            runtime,
            helper,
            assets,
            destination,
            args.signing_identity,
            icon,
            entitlements,
            args.version,
            config,
        )
    except (OSError, PackageError) as error:
        print(f"package-app: {error}", file=sys.stderr)
        return 78

    print(f"Installed signed bundle: {installed}")
    if previous:
        print(f"Previous bundle backup: {previous}")
    print(f"Bundle identifier: {BUNDLE_ID}")
    print("Signature verified with codesign --verify --deep --strict.")
    print("The optional config input, when provided, was validated but never copied into the bundle.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
