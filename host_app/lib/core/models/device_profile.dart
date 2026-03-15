import 'telemetry_snapshot.dart';

class DeviceProfile {
  const DeviceProfile({
    required this.portName,
    required this.architecture,
    required this.chipName,
    required this.flashSizeMb,
    required this.psramSizeMb,
    required this.telemetry,
    this.label,
    this.branch,
    this.connected = false,
    this.lastError,
  });

  final String portName;
  final String architecture;
  final String chipName;
  final int flashSizeMb;
  final int psramSizeMb;
  final String? label;
  final String? branch;
  final bool connected;
  final String? lastError;
  final TelemetrySnapshot telemetry;

  String get displayName => label ?? portName;

  DeviceProfile copyWith({
    String? architecture,
    String? chipName,
    int? flashSizeMb,
    int? psramSizeMb,
    String? label,
    String? branch,
    bool? connected,
    String? lastError,
    TelemetrySnapshot? telemetry,
  }) {
    return DeviceProfile(
      portName: portName,
      architecture: architecture ?? this.architecture,
      chipName: chipName ?? this.chipName,
      flashSizeMb: flashSizeMb ?? this.flashSizeMb,
      psramSizeMb: psramSizeMb ?? this.psramSizeMb,
      label: label ?? this.label,
      branch: branch ?? this.branch,
      connected: connected ?? this.connected,
      lastError: lastError ?? this.lastError,
      telemetry: telemetry ?? this.telemetry,
    );
  }
}

