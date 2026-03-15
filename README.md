# NimBLE HITL Testing Suite

This repository contains a greenfield implementation of a Hardware-in-the-Loop (HITL) test harness for `h2zero/NimBLE-Arduino`.

## Repository layout

- `host_app/`: Flutter desktop operator console for discovery, flashing, orchestration, telemetry, and logging.
- `firmware/`: ESP32/Arduino test firmware that exposes NimBLE behavior through a structured command protocol.
- `shared/`: Shared protocol contract and operation catalog used by both sides.
- `objectives.txt`: Original delivery objectives.

## Architecture

The host application is the source of truth. It enumerates serial devices, profiles each board through CLI tooling, checks out the selected `nimble-arduino` branch, generates board-specific build parameters, flashes both devices, and then drives test execution over a newline-delimited JSON protocol.

The firmware is a state-driven execution engine. It accepts commands over Serial, optionally exposes a control service over BLE, and reports telemetry, events, responses, and crash context back to the host. NimBLE server/client roles can be torn down and rebuilt without rebooting, enabling the role-swap and stress scenarios described in `objectives.txt`.

## Module mapping

- **Module 1:** `host_app/lib/core/services/device_discovery_service.dart`, `git_branch_service.dart`, and `toolchain_service.dart`
- **Module 2:** `host_app/lib/core/services/protocol_codec.dart`, `serial_transport.dart`, and `firmware/src/app/command_protocol.*`
- **Module 3:** `host_app/lib/core/state/orchestrator_controller.dart`, `shared/nimble_operation_catalog.json`, and `firmware/src/app/nimble_engine.*`
- **Module 4:** `host_app/lib/core/state/orchestrator_controller.dart`, `toolchain_service.dart`, `firmware/src/app/device_state.*`, and `telemetry_reporter.*`
- **Module 5:** `host_app/lib/features/dashboard/`
- **Module 6:** `firmware/src/main.cpp` plus the `firmware/src/app/` modules

## Key workflows

1. Discover ports and profile hardware with `esptool.py`.
2. List remote NimBLE-Arduino branches with `git ls-remote`.
3. Clone or update a local checkout for the selected branch.
4. Generate the PlatformIO environment matching each board profile.
5. Build and flash the firmware to both ESP32 targets.
6. Connect over serial, start telemetry polling, and orchestrate dynamic NimBLE scenarios.
7. Surface structured command results separately from raw serial logs in the dashboard.

## Shared command protocol

The protocol contract lives in `shared\protocol_contract.json`. Frames are JSON objects delimited by `\n`:

```json
{
  "id": "cmd-0001",
  "kind": "command",
  "type": "configureServer",
  "target": "board-a",
  "timestamp": "2026-03-14T00:00:00.000Z",
  "payload": {
    "serviceUuid": "180D",
    "characteristicUuid": "2A37"
  }
}
```

## Implementation notes

- The Flutter app intentionally isolates process execution, serial transport, discovery, and orchestration so they can be mocked independently.
- The build/flash workflow now disconnects any active serial session before PlatformIO upload so COM ports are released cleanly for flashing, and streams toolchain output into the dashboard while build/upload is running.
- The firmware keeps transport, telemetry, and NimBLE state management in separate modules to make extension for wider API coverage straightforward.
- The initial command catalog is representative rather than exhaustive; the surrounding architecture is designed for expanding into full API coverage without restructuring the system.
- The Windows installer flow is designed around a self-contained, per-user installation that bundles a portable Python runtime plus `platformio`, the Python `esptool` package, and a native `esptool.exe`.

## Windows installer automation

- `.github\workflows\windows-installer.yml` defines the Windows CI/release pipeline for GitHub-hosted builds, runs on pushes to `main`, force-updates a rolling `main-latest` tag, and refreshes the matching GitHub release assets each run.
- The same workflow also runs on `v*` tag pushes to publish versioned installer releases.
- `scripts\stage_windows_bundle.ps1` stages the Flutter Windows release output together with `firmware\`, `shared\`, a bundled Python toolchain, and a native `esptool.exe` download from Espressif releases.
- `scripts\bootstrap_windows_tools.ps1` bootstraps the same repo-local Windows toolchain for a source checkout by downloading embedded Python, installing `platformio`/`esptool`, and extracting a native `esptool.exe` into `tools\`.
- `installer\windows\nimble_hitl.iss` compiles a per-user Inno Setup installer that deploys the self-contained release under `%LOCALAPPDATA%\Programs\NimBLE HITL`.
- At runtime the host app prefers bundled native tools such as `tools\esptool\esptool.exe`, then bundled tool entrypoints from `tools\python\Scripts\`, then bundled `tools\python\python.exe`, while still falling back to system-installed `esptool`, `pio`, or Python module launches in a source checkout.

## Implementation steps

1. Open `host_app`, run `flutter pub get`, and build or run the Windows desktop shell.
2. On a fresh Windows source checkout, run `powershell -ExecutionPolicy Bypass -File .\scripts\bootstrap_windows_tools.ps1` once so `tools\python\` and `tools\esptool\` exist locally.
3. Use the branch dropdown to fetch and select the target `nimble-arduino` branch.
4. Connect two ESP32 boards, then use the discovery action to profile architecture, flash size, and PSRAM.
5. Build and flash through the dashboard so `generated_env.ini` is produced for the profiled targets.
6. Connect each board over serial, verify telemetry appears, and trigger stress passes from the top bar.
7. If a board emits a crash backtrace into the raw log pane, use the **Decode crash** action after a successful build has produced the matching ELF file.
8. Extend `shared/nimble_operation_catalog.json` and the `NimbleEngine` command handlers to add broader API coverage.

## One-button cross-platform build

- Run the orchestrator script directly from the repository root:
  - `python scripts/dev_workflow.py` on Windows
  - `python3 scripts/dev_workflow.py` on Linux/macOS
- The script will:
  - Build firmware via PlatformIO.
  - Run `flutter pub get`.
  - Run `flutter analyze` and `flutter test`.
  - Build the host desktop target for the current platform (`windows`, `macos`, or `linux`).
- For faster local iterations, skip analyze/test:
  - `python scripts/dev_workflow.py --quick`
  - `python3 scripts/dev_workflow.py --quick`
- In VS Code, run task **One Button: Build + Launch (Cross Platform)** for a full one-button workflow.
- `Ctrl+Shift+B` uses the same one-button build+launch task by default.

## Validation status

- `flutter pub get`, `flutter analyze`, `flutter test`, and `flutter build windows` were executed successfully for `host_app`.
- `python -m platformio run --project-dir firmware` was executed successfully for the default `esp32` firmware environment.
- JSON assets were validated locally.
- `esp32-exception-decoder` and real hardware flashing/runtime validation still need to be verified in the target environment.

## Next steps

1. Install `esp32-exception-decoder` and connect real ESP32 targets for flash/runtime validation.
2. Run `flutter pub get` inside `host_app` if dependencies are not already resolved.
3. Run the desktop app with `flutter run -d windows` from `host_app`.
4. Build and flash the firmware with `python -m platformio run --project-dir firmware --environment generated_esp32 --target upload`.
5. Run or adapt `.github\workflows\windows-installer.yml` once the repository is on GitHub to publish bundled Windows installers.
6. Expand the operation catalog to cover the remaining NimBLE API surface you care about most.

