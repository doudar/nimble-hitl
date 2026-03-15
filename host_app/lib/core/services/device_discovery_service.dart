import 'dart:io';

import '../models/device_profile.dart';
import '../models/telemetry_snapshot.dart';
import 'command_runner.dart';
import 'runtime_environment.dart';

class DeviceDiscoveryService {
  DeviceDiscoveryService(this._runner, this._runtimeEnvironment);

  final CommandRunner _runner;
  final RuntimeEnvironment _runtimeEnvironment;

  Future<List<DeviceProfile>> discoverDevices() async {
    final ports = await _listPorts();
    final devices = <DeviceProfile>[];

    for (final port in ports) {
      try {
        devices.add(await _profilePort(port));
      } catch (error) {
        devices.add(
          DeviceProfile(
            portName: port,
            architecture: 'unknown',
            chipName: 'unknown',
            flashSizeMb: 0,
            psramSizeMb: 0,
            telemetry: TelemetrySnapshot.empty(),
            lastError: '$error',
          ),
        );
      }
    }

    return devices;
  }

  Future<List<String>> _listPorts() async {
    final result = Platform.isWindows
        ? await _runner.runChecked(
            'powershell',
            <String>[
              '-NoProfile',
              '-Command',
              "[System.IO.Ports.SerialPort]::GetPortNames() | Sort-Object",
            ],
          )
        : await _runner.runChecked(
            'sh',
            <String>[
              '-lc',
              "printf '%s\n' /dev/tty.* /dev/ttyUSB* /dev/ttyACM* 2>/dev/null",
            ],
          );

    return result.stdout
        .split(RegExp(r'[\r\n]+'))
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty && !line.endsWith('*'))
        .toList();
  }

  Future<DeviceProfile> _profilePort(String port) async {
    final chip = await _runner.runCheckedAny(
      _runtimeEnvironment.resolveToolInvocations(
        commandNames: const <String>['esptool'],
        pythonModule: 'esptool',
        arguments: <String>['--port', port, 'chip_id'],
      ),
    );
    final flash = await _runner.runCheckedAny(
      _runtimeEnvironment.resolveToolInvocations(
        commandNames: const <String>['esptool'],
        pythonModule: 'esptool',
        arguments: <String>['--port', port, 'flash_id'],
      ),
    );

    final chipName = _extract(chip.stdout, RegExp(r'Chip is ([^\r\n]+)')) ?? 'ESP32';
    final architecture = _extract(
          chip.stdout,
          RegExp(r'Detecting chip type\.\.\. ([^\r\n]+)'),
        ) ??
        chipName;
    final flashSizeRaw =
        _extract(flash.stdout, RegExp(r'Detected flash size: ([0-9]+)MB')) ?? '0';
    final psramMb =
        int.tryParse(_extract(chip.stdout, RegExp(r'PSRAM: ([0-9]+)MB')) ?? '0') ?? 0;

    return DeviceProfile(
      portName: port,
      architecture: architecture,
      chipName: chipName,
      flashSizeMb: int.tryParse(flashSizeRaw) ?? 0,
      psramSizeMb: psramMb,
      telemetry: TelemetrySnapshot.empty(),
    );
  }

  String? _extract(String source, RegExp pattern) {
    final match = pattern.firstMatch(source);
    return match?.group(1)?.trim();
  }
}

