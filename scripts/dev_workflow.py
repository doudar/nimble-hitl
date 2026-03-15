#!/usr/bin/env python3
"""One-button cross-platform build workflow for NimBLE HITL.

This script orchestrates firmware and host builds with sensible defaults:
- Detects PlatformIO and Flutter executables.
- Builds firmware via PlatformIO.
- Runs Flutter pub get / analyze / test (optional).
- Builds desktop host app for the current OS.
"""

from __future__ import annotations

import argparse
import platform
import re
import shutil
import subprocess
import sys
from pathlib import Path


def _print_step(message: str) -> None:
    print(f"\n==> {message}")


def _run(cmd: list[str], cwd: Path) -> None:
    _print_step(f"Running: {' '.join(cmd)}")
    completed = subprocess.run(cmd, cwd=str(cwd))
    if completed.returncode != 0:
        raise SystemExit(completed.returncode)


def _first_executable(candidates: list[str | Path]) -> str | None:
    for candidate in candidates:
        if isinstance(candidate, Path):
            if candidate.exists():
                return str(candidate)
        else:
            resolved = shutil.which(candidate)
            if resolved:
                return resolved
    return None


def _detect_flutter(repo_root: Path) -> str:
    home = Path.home()
    system = platform.system().lower()
    candidates: list[str | Path] = []
    if system == "windows":
        candidates.extend(
            [
                home / ".puro" / "envs" / "stable" / "flutter" / "bin" / "flutter.bat",
                "flutter",
            ]
        )
    else:
        candidates.extend(
            [
                "flutter",
                home / ".puro" / "envs" / "stable" / "flutter" / "bin" / "flutter",
            ]
        )

    flutter = _first_executable(candidates)
    if not flutter:
        raise SystemExit(
            "Could not find Flutter. Install Flutter and ensure it is on PATH."
        )

    # On Windows, normalize to flutter.bat to avoid launching non-executable stubs.
    if system == "windows":
        flutter_path = Path(flutter)
        if flutter_path.suffix.lower() != ".bat":
            bat_path = flutter_path.with_suffix(".bat")
            if bat_path.exists():
                return str(bat_path)
    return flutter


def _detect_platformio(repo_root: Path) -> str:
    home = Path.home()
    system = platform.system().lower()

    candidates: list[str | Path] = []
    if system == "windows":
        candidates.extend(
            [
                home / ".platformio" / "penv" / "Scripts" / "platformio.exe",
                repo_root / "tools" / "python" / "Scripts" / "platformio.exe",
                "platformio",
                "pio",
            ]
        )
    else:
        candidates.extend(
            [
                home / ".platformio" / "penv" / "bin" / "platformio",
                "platformio",
                "pio",
            ]
        )

    platformio = _first_executable(candidates)
    if not platformio:
        raise SystemExit(
            "Could not find PlatformIO. Install PlatformIO CLI (pio/platformio)."
        )
    return platformio


def _desktop_target() -> str:
    system = platform.system().lower()
    if system == "windows":
        return "windows"
    if system == "darwin":
        return "macos"
    if system == "linux":
        return "linux"
    raise SystemExit(f"Unsupported OS for desktop build: {system}")


def _read_app_name(host_app: Path) -> str:
    pubspec = host_app / "pubspec.yaml"
    if not pubspec.exists():
        return "nimble_hitl_host"

    text = pubspec.read_text(encoding="utf-8", errors="ignore")
    match = re.search(r"^name:\s*([A-Za-z0-9_\-\.]+)\s*$", text, re.MULTILINE)
    if not match:
        return "nimble_hitl_host"
    return match.group(1)


def _launch_built_app(host_app: Path, target: str) -> None:
    app_name = _read_app_name(host_app)

    if target == "windows":
        exe = host_app / "build" / "windows" / "x64" / "runner" / "Release" / f"{app_name}.exe"
        if not exe.exists():
            raise SystemExit(f"Built executable not found: {exe}")
        _print_step(f"Launching: {exe}")
        subprocess.Popen([str(exe)], cwd=str(exe.parent))
        return

    if target == "macos":
        app_bundle = host_app / "build" / "macos" / "Build" / "Products" / "Release" / f"{app_name}.app"
        if not app_bundle.exists():
            raise SystemExit(f"Built app bundle not found: {app_bundle}")
        _print_step(f"Launching: {app_bundle}")
        subprocess.Popen(["open", str(app_bundle)])
        return

    if target == "linux":
        binary = host_app / "build" / "linux" / "x64" / "release" / "bundle" / app_name
        if not binary.exists():
            raise SystemExit(f"Built Linux binary not found: {binary}")
        _print_step(f"Launching: {binary}")
        subprocess.Popen([str(binary)], cwd=str(binary.parent))
        return

    raise SystemExit(f"Unsupported desktop target for launch: {target}")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="NimBLE HITL one-button build workflow")
    parser.add_argument("--skip-firmware", action="store_true", help="Skip PlatformIO firmware build")
    parser.add_argument("--skip-host", action="store_true", help="Skip Flutter host app build")
    parser.add_argument("--skip-analyze", action="store_true", help="Skip flutter analyze")
    parser.add_argument("--skip-test", action="store_true", help="Skip flutter test")
    parser.add_argument("--quick", action="store_true", help="Shortcut for --skip-analyze --skip-test")
    parser.add_argument("--launch", action="store_true", help="Launch the built desktop app after a successful host build")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    repo_root = Path(__file__).resolve().parents[1]
    host_app = repo_root / "host_app"

    if args.quick:
        args.skip_analyze = True
        args.skip_test = True

    if not args.skip_firmware:
        platformio = _detect_platformio(repo_root)
        _run([platformio, "run", "--project-dir", "firmware"], cwd=repo_root)

    if not args.skip_host:
        flutter = _detect_flutter(repo_root)
        _run([flutter, "pub", "get"], cwd=host_app)

        if not args.skip_analyze:
            _run([flutter, "analyze"], cwd=host_app)

        if not args.skip_test:
            _run([flutter, "test"], cwd=host_app)

        target = _desktop_target()
        _run([flutter, "build", target], cwd=host_app)

        if args.launch:
            _launch_built_app(host_app, target)

    _print_step("Workflow completed successfully.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
