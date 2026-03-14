import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;

import '../models/device_profile.dart';
import '../models/protocol_frame.dart';
import '../models/telemetry_snapshot.dart';
import '../services/command_runner.dart';
import '../services/device_discovery_service.dart';
import '../services/git_branch_service.dart';
import '../services/orchestrator_service.dart';
import '../services/runtime_environment.dart';
import '../services/toolchain_service.dart';

class OrchestratorController extends ChangeNotifier {
  OrchestratorController({
    required this.orchestratorService,
    required this.runtimeEnvironment,
  });

  factory OrchestratorController.bootstrap() {
    final runner = CommandRunner();
    final runtimeEnvironment = RuntimeEnvironment.detect();
    return OrchestratorController(
      runtimeEnvironment: runtimeEnvironment,
      orchestratorService: OrchestratorService(
        discoveryService: DeviceDiscoveryService(runner, runtimeEnvironment),
        gitBranchService: GitBranchService(runner),
        toolchainService: ToolchainService(runner, runtimeEnvironment),
      ),
    );
  }

  final OrchestratorService orchestratorService;
  final RuntimeEnvironment runtimeEnvironment;

  final List<String> _branches = <String>[];
  final Map<String, DeviceProfile> _devices = <String, DeviceProfile>{};
  final Map<String, List<String>> _logs = <String, List<String>>{};
  final Map<String, List<_ObservedFrame>> _frameHistory =
      <String, List<_ObservedFrame>>{};
  final Map<String, String> _deviceIdByPort = <String, String>{};
  final Map<String, List<String>> _capturedCrashLogs = <String, List<String>>{};
  final Map<String, int> _crashCaptureCountdown = <String, int>{};
  final Map<String, DateTime> _lastInboundFrameAt = <String, DateTime>{};
  final List<String> _commandResults = <String>[];

  bool _busy = false;
  bool _leakDetectionEnabled = true;
  int _leakThresholdBytes = 8192;
  double _leakThresholdPercent = 0.15;
  bool _activityLedEnabled = true;
  int _activityLedGpio = 2;
  String? _selectedBranch;
  String? _statusMessage;
  Timer? _telemetryTimer;
  int _frameSequence = 0;
  int _observedFrameSequence = 0;
  bool _stressLoopEnabled = false;
  bool _stressRunning = false;
  bool _stressStopRequested = false;
  bool _disposed = false;
  int _stressPassCount = 0;
  int _stressFailCount = 0;
  final List<_StressFailure> _stressFailures = <_StressFailure>[];

  List<String> get branches => List<String>.unmodifiable(_branches);
  List<DeviceProfile> get devices => _devices.values.toList()
    ..sort((left, right) => left.portName.compareTo(right.portName));
  List<String> get commandResults => List<String>.unmodifiable(_commandResults);
  bool get busy => _busy;
  bool get leakDetectionEnabled => _leakDetectionEnabled;
  int get leakThresholdBytes => _leakThresholdBytes;
  double get leakThresholdPercent => _leakThresholdPercent;
  bool get activityLedEnabled => _activityLedEnabled;
  int get activityLedGpio => _activityLedGpio;
  String? get selectedBranch => _selectedBranch;
  String? get statusMessage => _statusMessage;
  bool get stressLoopEnabled => _stressLoopEnabled;
  bool get stressRunning => _stressRunning;
  int get stressPassCount => _stressPassCount;
  int get stressFailCount => _stressFailCount;
  bool get stressHasResults => _stressPassCount + _stressFailCount > 0;
  List<_StressFailure> get stressFailures =>
      List<_StressFailure>.unmodifiable(_stressFailures);

  List<String> logsFor(String portName) =>
      List<String>.unmodifiable(_logs[portName] ?? const <String>[]);

  bool hasCapturedCrash(String portName) =>
      (_capturedCrashLogs[portName] ?? const <String>[]).isNotEmpty;

  String get stressScriptFilePath => _stressScriptPath;

  Future<Map<String, dynamic>> loadStressScriptDocument() async {
    final scriptFile = File(_stressScriptPath);
    if (!await scriptFile.exists()) {
      return <String, dynamic>{
        'description': 'Stress script editor document',
        'steps': <Map<String, dynamic>>[],
      };
    }

    final decoded = jsonDecode(await scriptFile.readAsString());
    if (decoded is Map<String, dynamic>) {
      return decoded;
    }

    throw const FormatException('Stress script must be a JSON object.');
  }

  Future<void> saveStressScriptDocument(Map<String, dynamic> document) async {
    final scriptFile = File(_stressScriptPath);
    await scriptFile.writeAsString(
      const JsonEncoder.withIndent('  ').convert(document),
    );
  }

  Future<void> initialize() async {
    try {
      await refreshBranches();
      await discoverDevices();
      if (_disposed) {
        return;
      }
      _telemetryTimer = Timer.periodic(
        const Duration(seconds: 3),
        (_) {
          unawaited(
            pollTelemetry().catchError((error) {
              if (!_disposed) {
                _appendCommandResult('telemetry polling failed: $error');
                notifyListeners();
              }
            }),
          );
        },
      );
    } catch (_) {
      _telemetryTimer?.cancel();
      rethrow;
    }
  }

  Future<void> refreshBranches() async {
    await _guard(() async {
      _statusMessage = 'Refreshing NimBLE-Arduino branches...';
      notifyListeners();
      final branches = await orchestratorService.listBranches();
      String? defaultBranch;
      if (branches.isNotEmpty) {
        try {
          defaultBranch = await orchestratorService.getDefaultBranch();
        } catch (_) {
          defaultBranch = null;
        }
      }
      _branches
        ..clear()
        ..addAll(branches);
      if (_selectedBranch == null || !_branches.contains(_selectedBranch)) {
        if (defaultBranch != null && _branches.contains(defaultBranch)) {
          _selectedBranch = defaultBranch;
        } else {
          _selectedBranch = _branches.isEmpty ? null : _branches.first;
        }
      }
    });
  }

  Future<void> discoverDevices() async {
    await _guard(() async {
      _statusMessage = 'Discovering connected ESP32 devices...';
      notifyListeners();
      final devices = await orchestratorService.discoverDevices();
      _devices
        ..clear()
        ..addEntries(
            devices.map((device) => MapEntry(device.portName, device)));
    });
  }

  Future<void> disconnectFromDevice(DeviceProfile device) async {
    await _guard(() async {
      _statusMessage = 'Disconnecting from ${device.portName}...';
      _appendCommandResult('${device.portName}: disconnecting serial transport.');
      _appendDeviceLog(device.portName, '[toolchain] Disconnecting serial transport');
      notifyListeners();
      await orchestratorService.disconnect(device.portName);
      _devices[device.portName] = device.copyWith(connected: false);
      _appendCommandResult('${device.portName}: serial transport disconnected.');
      _appendDeviceLog(device.portName, '[toolchain] Serial transport disconnected');
      notifyListeners();
    });
  }

  Future<void> connectToDevice(DeviceProfile device) async {
    await _guard(() async {
      _statusMessage = 'Connecting to ${device.portName}...';
      _appendCommandResult('${device.portName}: connecting serial transport.');
      _appendDeviceLog(
        device.portName,
        '[toolchain] Connecting serial transport',
      );
      notifyListeners();
      final connectStartedAt = DateTime.now();
      await orchestratorService.connect(device, _handleFrame);
      _devices[device.portName] = device.copyWith(connected: true);
      _appendCommandResult('${device.portName}: serial transport connected.');
      _appendDeviceLog(
        device.portName,
        '[toolchain] Serial transport connected',
      );

      _appendCommandResult(
          '${device.portName}: sending initial telemetry probe.');
      _appendDeviceLog(
        device.portName,
        '[toolchain] Sending initial telemetry probe',
      );
      await orchestratorService.sendFrame(
        device.portName,
        _makeFrame(
          target: device.portName,
          type: 'pollTelemetry',
          payload: <String, dynamic>{},
        ),
      );

      final receivedInboundFrame = await _waitForInboundFrame(
        device.portName,
        since: connectStartedAt,
      );
      if (!receivedInboundFrame) {
        _appendCommandResult(
          '${device.portName}: no inbound serial frames after connect.',
        );
        _appendDeviceLog(
          device.portName,
          '[toolchain] No inbound serial frames after connect',
        );
      }
      notifyListeners();
    });
  }

  Future<void> checkoutSelectedBranch() async {
    final branch = _selectedBranch;
    if (branch == null) {
      throw StateError('No branch selected');
    }

    await _guard(() => _checkoutSelectedBranch(branch));
  }

  Future<void> flashDiscoveredDevices() async {
    final branch = _selectedBranch;
    if (branch == null) {
      throw StateError('No branch selected');
    }

    await _guard(() async {
      final devicesToFlash = devices;
      if (devicesToFlash.isEmpty) {
        _statusMessage = 'No discovered devices are available to flash.';
        notifyListeners();
        return;
      }

      try {
        await _checkoutSelectedBranch(branch);
      } catch (error) {
        _appendCommandResult('branch checkout failed: $error');
        _statusMessage = 'Build and flash aborted: branch checkout failed.';
        notifyListeners();
        return;
      }
      _statusMessage =
          'Preparing ${devicesToFlash.length} device(s) for flashing...';
      notifyListeners();

      final prepareResults = await Future.wait(
        devicesToFlash.map(_prepareDeviceForFlashSafe),
      );
      final failures = <String>[
        ...prepareResults.whereType<String>(),
      ];

      late final List<String> environments;
      try {
        environments =
            await orchestratorService.toolchainService.prepareFirmwareEnvironments(
          devices: devicesToFlash,
          projectDirectory: _firmwareDirectory,
          nimbleCheckoutDirectory: _nimbleCheckoutDirectory,
          activityLedEnabled: _activityLedEnabled,
          activityLedGpio: _activityLedGpio,
        );
      } catch (error) {
        _appendCommandResult('firmware environment preparation failed: $error');
        _statusMessage = 'Build and flash aborted: environment prep failed.';
        notifyListeners();
        return;
      }

      var buildFailed = false;
      for (final environment in environments) {
        _statusMessage = 'Building firmware for $environment...';
        _appendCommandResult('build[$environment]: starting build');
        notifyListeners();
        try {
          await orchestratorService.toolchainService.buildEnvironment(
            environment: environment,
            projectDirectory: _firmwareDirectory,
            timeout: const Duration(minutes: 8),
            onOutput: (line) =>
                _appendCommandResult('build[$environment]: $line'),
          );
          _appendCommandResult('build[$environment]: completed');
        } catch (error) {
          buildFailed = true;
          failures.add('build[$environment]: $error');
          _appendCommandResult('build[$environment]: failed - $error');
        }
      }

      if (!buildFailed) {
        _statusMessage =
            'Uploading firmware to ${devicesToFlash.length} device(s) in parallel...';
        notifyListeners();
        final results = await Future.wait(
          devicesToFlash.map(_uploadSingleDevice),
        );
        failures.addAll(results.whereType<String>());
      } else {
        _appendCommandResult('upload skipped because one or more builds failed.');
      }

      _statusMessage = failures.isEmpty
          ? 'Build and flash completed for all devices.'
          : 'Build and flash finished with ${failures.length} failure(s).';
      notifyListeners();

      if (failures.isNotEmpty) {
        _appendCommandResult(
          'build and flash failures: ${failures.join(' | ')}',
        );
      }
    });
  }

  Future<String?> _prepareDeviceForFlashSafe(DeviceProfile device) async {
    try {
      await _prepareDeviceForFlash(device);
      return null;
    } catch (error) {
      _appendCommandResult(
        '${device.portName}: pre-flash disconnect failed - $error',
      );
      _appendDeviceLog(
        device.portName,
        '[toolchain] Pre-flash disconnect failed: $error',
      );
      return '${device.portName}: $error';
    }
  }

  Future<String?> _uploadSingleDevice(DeviceProfile device) async {
    try {
      _appendCommandResult('${device.portName}: starting firmware upload');
      _appendDeviceLog(device.portName, '[toolchain] Starting firmware upload');
      notifyListeners();

      await orchestratorService.toolchainService.uploadBuiltFirmware(
        device: device,
        projectDirectory: _firmwareDirectory,
        timeout: const Duration(minutes: 4),
        onOutput: (line) => _handleToolchainOutput(device.portName, line),
      );

      _appendCommandResult('${device.portName}: firmware upload completed.');
      _appendDeviceLog(device.portName, '[toolchain] Firmware upload completed');
      return null;
    } catch (error) {
      _appendCommandResult('${device.portName}: firmware upload failed - $error');
      _appendDeviceLog(device.portName, '[toolchain] Firmware upload failed: $error');
      return '${device.portName}: $error';
    } finally {
      await _reconnectDeviceAfterFlash(device);
    }
  }

  Future<void> pollTelemetry() async {
    if (_devices.isEmpty || _disposed) {
      return;
    }
    for (final device in devices.where((item) => item.connected)) {
      try {
        await orchestratorService.sendFrame(
          device.portName,
          _makeFrame(
            target: device.portName,
            type: 'pollTelemetry',
            payload: <String, dynamic>{},
          ),
        );
      } catch (error) {
        _appendCommandResult(
            '${device.portName}: telemetry poll failed - $error');
      }
    }
  }

  Future<void> startStressTest() async {
    if (_stressRunning) {
      return;
    }

    final connectedDevices = devices.where((item) => item.connected).toList();
    if (connectedDevices.isEmpty) {
      throw StateError(
          'Connect at least one device before starting stress test.');
    }

    _stressRunning = true;
    _stressStopRequested = false;
    _stressPassCount = 0;
    _stressFailCount = 0;
    _stressFailures.clear();
    _appendCommandResult('stress: preparing scripted test plan');
    notifyListeners();

    try {
      final steps = await _loadStressSteps();
      if (steps.isEmpty) {
        throw StateError('No stress steps are defined.');
      }

      var cycle = 0;
      do {
        cycle += 1;
        final cycleStartPass = _stressPassCount;
        final cycleStartFail = _stressFailCount;
        _appendCommandResult(
            'stress: starting cycle $cycle (${steps.length} step(s))');
        for (final step in steps) {
          if (_stressStopRequested || _disposed) {
            break;
          }
          await _executeStressStep(step, connectedDevices, cycle);
        }
        final cyclePass = _stressPassCount - cycleStartPass;
        final cycleFail = _stressFailCount - cycleStartFail;
        final cycleTag = cycleFail == 0 ? '[PASS]' : '[FAIL]';
        _appendCommandResult(
            '$cycleTag stress: cycle $cycle — $cyclePass passed, $cycleFail failed');
        notifyListeners();
      } while (_stressLoopEnabled && !_stressStopRequested && !_disposed);

      final totalTag = _stressFailCount == 0 ? '[PASS]' : '[FAIL]';
      _appendCommandResult(
        _stressStopRequested
            ? 'stress: stopped by user ($_stressPassCount passed, $_stressFailCount failed)'
            : '$totalTag stress: complete — $_stressPassCount passed, $_stressFailCount failed',
      );
    } finally {
      _stressRunning = false;
      _stressStopRequested = false;
      notifyListeners();
    }
  }

  void stopStressTest() {
    if (!_stressRunning) {
      return;
    }
    _stressStopRequested = true;
    _appendCommandResult('stress: stop requested');
    notifyListeners();
  }

  void setStressLoopEnabled(bool enabled) {
    _stressLoopEnabled = enabled;
    notifyListeners();
  }

  Future<void> switchTransport(DeviceProfile device, String transport) async {
    await orchestratorService.sendFrame(
      device.portName,
      _makeFrame(
        target: device.portName,
        type: 'switchControlTransport',
        payload: <String, dynamic>{'transport': transport},
      ),
    );
  }

  Future<void> updateActivityLedSettings({
    required bool enabled,
    required int gpio,
  }) async {
    if (gpio < 0 || gpio > 48) {
      throw RangeError.range(gpio, 0, 48, 'gpio');
    }

    _activityLedEnabled = enabled;
    _activityLedGpio = gpio;
    notifyListeners();
  }

  Future<void> decodeCapturedCrash(DeviceProfile device) async {
    final crashLines = _capturedCrashLogs[device.portName] ?? const <String>[];
    if (crashLines.isEmpty) {
      throw StateError(
          'No captured crash trace is available for ${device.portName}');
    }

    await _guard(() async {
      final tempDirectory =
          await Directory.systemTemp.createTemp('nimble-hitl');
      try {
        final dumpFile = File(
          path.join(tempDirectory.path, '${device.portName}_crash_trace.txt'),
        );
        await dumpFile.writeAsString(crashLines.join('\n'));

        final environmentName = orchestratorService.toolchainService
            .generatedEnvironmentNameFor(device);
        final elfPath = path.join(
          _firmwareDirectory,
          '.pio',
          'build',
          environmentName,
          'firmware.elf',
        );
        final decoded =
            await orchestratorService.toolchainService.decodeCrashDump(
          decoderExecutable: 'esp32-exception-decoder',
          elfPath: elfPath,
          dumpPath: dumpFile.path,
        );

        _appendCommandResult('${device.portName}: crash trace decoded');
        _logs.putIfAbsent(device.portName, () => <String>[]).add(decoded);
      } finally {
        await tempDirectory.delete(recursive: true);
      }
    });
  }

  void setSelectedBranch(String? branch) {
    _selectedBranch = branch;
    notifyListeners();
  }

  void updateLeakDetection({
    required bool enabled,
    required int thresholdBytes,
    required double thresholdPercent,
  }) {
    _leakDetectionEnabled = enabled;
    _leakThresholdBytes = thresholdBytes;
    _leakThresholdPercent = thresholdPercent;
    notifyListeners();
  }

  Future<void> _guard(Future<void> Function() action) async {
    if (_disposed) {
      return;
    }
    _busy = true;
    notifyListeners();
    try {
      await action();
      _statusMessage = 'Ready';
    } catch (error) {
      _statusMessage = '$error';
      rethrow;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  void _handleFrame(ProtocolFrame frame) {
    if (_disposed) {
      return;
    }
    _lastInboundFrameAt[frame.target] = DateTime.now();
    _observedFrameSequence += 1;
    final history =
        _frameHistory.putIfAbsent(frame.target, () => <_ObservedFrame>[]);
    history.add(_ObservedFrame(sequence: _observedFrameSequence, frame: frame));
    if (history.length > 400) {
      history.removeRange(0, history.length - 400);
    }

    final maybeDeviceId = frame.payload['deviceId'];
    if (maybeDeviceId != null) {
      _deviceIdByPort[frame.target] = maybeDeviceId.toString();
    }

    if (frame.kind != 'telemetry' && frame.type != 'pollTelemetry') {
      final logMessage = frame.kind == 'log'
          ? (frame.payload['message']?.toString() ?? '${frame.payload}')
          : '${frame.payload}';
      final logLine = '[${frame.kind}] ${frame.type}: $logMessage';
      _logs.putIfAbsent(frame.target, () => <String>[]).add(logLine);
      _captureCrashTrace(frame, logMessage);
    }

    if ((frame.kind == 'response' || frame.kind == 'event') &&
        frame.type != 'pollTelemetry') {
      _appendCommandResult('${frame.target}: ${frame.type}');
    }

    if (frame.kind == 'telemetry') {
      final current = _devices[frame.target];
      if (current != null) {
        final telemetry =
            _applyLeakRules(TelemetrySnapshot.fromPayload(frame.payload));
        _devices[frame.target] = current.copyWith(telemetry: telemetry);
      }
    }

    notifyListeners();
  }

  TelemetrySnapshot _applyLeakRules(TelemetrySnapshot telemetry) {
    if (!_leakDetectionEnabled) {
      return telemetry.copyWith(leakDetected: false, leakReason: null);
    }

    final minimum = telemetry.minimumFreeHeap;
    final free = telemetry.freeHeap;
    final percentDrop = free == 0 ? 0 : (free - minimum) / free;
    final leakDetected =
        minimum < _leakThresholdBytes || percentDrop >= _leakThresholdPercent;

    return telemetry.copyWith(
      leakDetected: leakDetected,
      leakReason: leakDetected
          ? 'Minimum heap $minimum bytes, drop ${(percentDrop * 100).toStringAsFixed(1)}%'
          : null,
      updatedAt: DateTime.now(),
    );
  }

  void _appendCommandResult(String result) {
    _commandResults.insert(0, '${DateTime.now().toIso8601String()}  $result');
    if (_commandResults.length > 40) {
      _commandResults.removeLast();
    }
  }

  Future<void> _prepareDeviceForFlash(DeviceProfile device) async {
    if (!device.connected) {
      return;
    }

    _appendCommandResult(
      '${device.portName}: disconnecting serial transport before flashing.',
    );
    _appendDeviceLog(
      device.portName,
      '[toolchain] Disconnecting serial transport before flashing',
    );
    try {
      await orchestratorService
          .disconnect(device.portName)
          .timeout(const Duration(seconds: 15));
    } on TimeoutException {
      throw TimeoutException(
        'Timed out while disconnecting ${device.portName} before flashing.',
      );
    }
    final current = _devices[device.portName];
    if (current != null) {
      _devices[device.portName] = current.copyWith(connected: false);
    }
  }

  Future<void> _reconnectDeviceAfterFlash(DeviceProfile device) async {
    _appendCommandResult(
      '${device.portName}: reconnecting serial transport after flashing.',
    );
    _appendDeviceLog(
      device.portName,
      '[toolchain] Reconnecting serial transport after flashing',
    );
    notifyListeners();

    // Give Windows and the board time to finish USB serial re-enumeration.
    await Future<void>.delayed(const Duration(seconds: 4));

    try {
      final reconnectStartedAt = DateTime.now();
      await orchestratorService
          .connect(device, _handleFrame)
          .timeout(const Duration(seconds: 15));
      final current = _devices[device.portName] ?? device;
      _devices[device.portName] = current.copyWith(connected: true);
      _appendCommandResult(
        '${device.portName}: serial transport reconnected.',
      );
      _appendDeviceLog(
          device.portName, '[toolchain] Serial transport reconnected');

      _appendCommandResult(
        '${device.portName}: sending initial telemetry probe.',
      );
      _appendDeviceLog(
        device.portName,
        '[toolchain] Sending initial telemetry probe',
      );
      await orchestratorService.sendFrame(
        device.portName,
        _makeFrame(
          target: device.portName,
          type: 'pollTelemetry',
          payload: <String, dynamic>{},
        ),
      );

      final receivedInboundFrame = await _waitForInboundFrame(
        device.portName,
        since: reconnectStartedAt,
      );
      if (!receivedInboundFrame) {
        _appendCommandResult(
          '${device.portName}: no inbound serial frames after reconnect on assigned port.',
        );
        _appendDeviceLog(
          device.portName,
          '[toolchain] No inbound serial frames after reconnect on assigned port',
        );
      }
    } catch (error) {
      _appendCommandResult(
        '${device.portName}: reconnect failed after flashing - $error',
      );
      _appendDeviceLog(
        device.portName,
        '[toolchain] Reconnect failed after flashing: $error',
      );
      final current = _devices[device.portName];
      if (current != null) {
        _devices[device.portName] = current.copyWith(connected: false);
      }
    }

    notifyListeners();
  }

  Future<bool> _waitForInboundFrame(
    String portName, {
    required DateTime since,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      final observedAt = _lastInboundFrameAt[portName];
      if (observedAt != null && observedAt.isAfter(since)) {
        return true;
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    return false;
  }

  void _handleToolchainOutput(String portName, String line) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) {
      return;
    }

    _appendCommandResult('$portName: $trimmed');
    _appendDeviceLog(portName, '[toolchain] $trimmed');
    if (!_disposed) {
      notifyListeners();
    }
  }

  void _appendDeviceLog(String portName, String line) {
    _logs.putIfAbsent(portName, () => <String>[]).add(line);
    final logLines = _logs[portName]!;
    if (logLines.length > 400) {
      logLines.removeRange(0, logLines.length - 400);
    }
  }

  ProtocolFrame _makeFrame({
    required String target,
    required String type,
    required Map<String, dynamic> payload,
  }) {
    _frameSequence += 1;
    return ProtocolFrame(
      id: 'cmd-${_frameSequence.toString().padLeft(4, '0')}',
      kind: 'command',
      type: type,
      target: target,
      timestamp: DateTime.now(),
      payload: payload,
    );
  }

  Future<void> _checkoutSelectedBranch(String branch) async {
    _statusMessage = 'Checking out NimBLE-Arduino branch $branch...';
    notifyListeners();
    await orchestratorService.gitBranchService.cloneOrCheckout(
      branch: branch,
      checkoutDirectory: _nimbleCheckoutDirectory,
    );
    for (final device in devices) {
      _devices[device.portName] = device.copyWith(branch: branch);
    }
  }

  void _captureCrashTrace(ProtocolFrame frame, String logMessage) {
    final portName = frame.target;
    final crashMarkers = <String>[
      'Guru Meditation',
      'Backtrace:',
      'abort()',
      'rst:0x'
    ];
    final shouldStartCapture =
        crashMarkers.any((marker) => logMessage.contains(marker));

    if (shouldStartCapture) {
      _capturedCrashLogs.putIfAbsent(portName, () => <String>[]).clear();
      _crashCaptureCountdown[portName] = 24;
      _appendCommandResult('$portName: crash trace captured');
    }

    final remaining = _crashCaptureCountdown[portName];
    if (remaining != null && remaining > 0) {
      _capturedCrashLogs
          .putIfAbsent(portName, () => <String>[])
          .add(logMessage);
      _crashCaptureCountdown[portName] = remaining - 1;
    }
  }

  String get _repoRoot => runtimeEnvironment.applicationRoot;
  String get _nimbleCheckoutDirectory =>
      path.join(_repoRoot, 'nimble_arduino_checkout');
  String get _firmwareDirectory => path.join(_repoRoot, 'firmware');

  String get _stressScriptPath =>
      path.join(_repoRoot, 'shared', 'stress_test_script.json');

  String get _operationCatalogPath =>
      path.join(_repoRoot, 'shared', 'nimble_operation_catalog.json');

  Future<List<_StressStep>> _loadStressSteps() async {
    final scriptFile = File(_stressScriptPath);
    if (await scriptFile.exists()) {
      final decoded = jsonDecode(await scriptFile.readAsString());
      if (decoded is Map<String, dynamic>) {
        final rawSteps = decoded['steps'];
        if (rawSteps is List) {
          return rawSteps
              .whereType<Map>()
              .map((raw) => _StressStep.fromJson(
                    Map<String, dynamic>.from(raw),
                  ))
              .toList();
        }
      }
      _appendCommandResult(
          'stress: script exists but has invalid format, using catalog fallback');
    }

    final catalogFile = File(_operationCatalogPath);
    if (!await catalogFile.exists()) {
      return <_StressStep>[];
    }

    final decoded = jsonDecode(await catalogFile.readAsString());
    if (decoded is! Map<String, dynamic>) {
      return <_StressStep>[];
    }
    final areas = decoded['coverageAreas'];
    if (areas is! List) {
      return <_StressStep>[];
    }

    final steps = <_StressStep>[];
    for (final area in areas.whereType<Map>()) {
      final operations = area['operations'];
      if (operations is! List) {
        continue;
      }
      for (final operation in operations) {
        if (operation is! String) {
          continue;
        }
        final mapped = _mapOperationToStressStep(operation);
        if (mapped != null) {
          steps.add(mapped);
        }
      }
    }

    _appendCommandResult(
        'stress: using generated plan from operation catalog (${steps.length} step(s))');
    return steps;
  }

  _StressStep? _mapOperationToStressStep(String operation) {
    switch (operation) {
      case 'init':
        return const _StressStep(name: 'init', command: 'handshake');
      case 'setDeviceName':
        return const _StressStep(
          name: 'setDeviceName',
          command: 'setDeviceName',
          payload: <String, dynamic>{'name': 'nimble-hitl-stress'},
        );
      case 'setMTU':
      case 'mtuRandomization':
        return const _StressStep(
          name: 'setMtu',
          command: 'setMtu',
          payload: <String, dynamic>{'mtu': 185},
        );
      case 'setSecurityAuth':
      case 'setSecurityPasskey':
      case 'securityReconfiguration':
        return const _StressStep(
          name: 'setSecurity',
          command: 'setSecurity',
          payload: <String, dynamic>{
            'bond': true,
            'mitm': false,
            'secureConnection': true,
            'passkey': 123456,
          },
        );
      case 'createServer':
      case 'createService':
      case 'createCharacteristic':
      case 'createDescriptor':
      case 'startService':
        return const _StressStep(
            name: 'configureServer', command: 'configureServer');
      case 'startAdvertising':
        return const _StressStep(
            name: 'startAdvertising', command: 'startAdvertising');
      case 'stopAdvertising':
        return const _StressStep(
            name: 'stopAdvertising', command: 'stopAdvertising');
      case 'notify':
        return const _StressStep(
          name: 'notifyCharacteristic',
          command: 'notifyCharacteristic',
          payload: <String, dynamic>{'value': 'stress-notify'},
        );
      case 'createClient':
        return const _StressStep(
            name: 'configureClient', command: 'configureClient');
      case 'disconnect':
        return const _StressStep(
            name: 'disconnectPeer', command: 'disconnectPeer');
      case 'readValue':
        return const _StressStep(
            name: 'readCharacteristic', command: 'readCharacteristic');
      case 'writeValue':
        return const _StressStep(
          name: 'writeCharacteristic',
          command: 'writeCharacteristic',
          payload: <String, dynamic>{'value': 'stress-write'},
        );
      case 'rapidRoleSwap':
        return const _StressStep(name: 'swapRole', command: 'swapRole');
      case 'advertisingMutation':
        return const _StressStep(
          name: 'configureAdvertising',
          command: 'configureAdvertising',
          payload: <String, dynamic>{'scanResponse': true},
        );
      case 'highFrequencyNotify':
        return const _StressStep(
          name: 'highFrequencyNotify',
          command: 'notifyCharacteristic',
          payload: <String, dynamic>{'value': 'hf-notify'},
          repeat: 20,
          delayMs: 20,
        );
      case 'telemetryPolling':
        return const _StressStep(
            name: 'pollTelemetry', command: 'pollTelemetry');
      default:
        return null;
    }
  }

  Future<void> _executeStressStep(
    _StressStep step,
    List<DeviceProfile> connectedDevices,
    int cycle,
  ) async {
    final targets = _resolveStepTargets(step.target, connectedDevices);
    if (targets.isEmpty) {
      _appendCommandResult(
          'stress: skipped ${step.name} (target "${step.target}" not available)');
      return;
    }

    for (var run = 0; run < step.repeat; run += 1) {
      for (final target in targets) {
        if (_stressStopRequested || _disposed) {
          return;
        }

        final sinceSequence = _observedFrameSequence;

        if (step.command.isNotEmpty) {
          try {
            final payload = _resolvePayloadTemplates(
              step.payload,
              target: target,
              connectedDevices: connectedDevices,
              cycle: cycle,
              run: run,
            );
            await orchestratorService.sendFrame(
              target.portName,
              _makeFrame(
                target: target.portName,
                type: step.command,
                payload: payload,
              ),
            );
            if (step.expectation == null) {
              _appendCommandResult(
                  '${target.portName}: stress ${step.name}');
            }
          } catch (error) {
            _stressFailCount++;
            final reason = error.toString();
            _stressFailures.add(_StressFailure(
              port: target.portName,
              stepName: step.name,
              reason: reason,
              cycle: cycle,
            ));
            _appendCommandResult(
              '[FAIL] ${target.portName}: ${step.name} — $reason',
            );
            notifyListeners();
            continue;
          }
        }

        final expectation = step.expectation;
        if (expectation != null) {
          final matched = await _waitForStressExpectation(
            expectation,
            sourceDevice: target,
            connectedDevices: connectedDevices,
            sinceSequence: sinceSequence,
            cycle: cycle,
            run: run,
          );
          if (matched) {
            _stressPassCount++;
            _appendCommandResult('[PASS] ${target.portName}: ${step.name}');
          } else {
            _stressFailCount++;
            _stressFailures.add(_StressFailure(
              port: target.portName,
              stepName: step.name,
              reason: 'expectation timed out',
              cycle: cycle,
            ));
            _appendCommandResult(
              '[FAIL] ${target.portName}: ${step.name} — expectation timed out',
            );
          }
          notifyListeners();
        }

        if (step.delayMs > 0) {
          await Future<void>.delayed(Duration(milliseconds: step.delayMs));
        }
      }
    }
  }

  List<DeviceProfile> _resolveStepTargets(
    String selector,
    List<DeviceProfile> connectedDevices,
  ) {
    if (connectedDevices.isEmpty) {
      return const <DeviceProfile>[];
    }

    switch (selector.toLowerCase()) {
      case 'all':
      case 'each':
        return connectedDevices;
      case 'first':
        return <DeviceProfile>[connectedDevices.first];
      case 'second':
        return connectedDevices.length > 1
            ? <DeviceProfile>[connectedDevices[1]]
            : const <DeviceProfile>[];
      default:
        final matched = connectedDevices
            .where((device) =>
                device.portName.toLowerCase() == selector.toLowerCase())
            .toList();
        return matched;
    }
  }

  Map<String, dynamic> _resolvePayloadTemplates(
    Map<String, dynamic> payload, {
    required DeviceProfile target,
    required List<DeviceProfile> connectedDevices,
    required int cycle,
    required int run,
  }) {
    final resolved = <String, dynamic>{};
    payload.forEach((key, value) {
      resolved[key] = _resolveTemplateValue(
        value,
        target: target,
        connectedDevices: connectedDevices,
        cycle: cycle,
        run: run,
      );
    });
    return resolved;
  }

  dynamic _resolveTemplateValue(
    dynamic value, {
    required DeviceProfile target,
    required List<DeviceProfile> connectedDevices,
    required int cycle,
    required int run,
  }) {
    if (value is Map) {
      final mapped = <String, dynamic>{};
      value.forEach((key, item) {
        mapped[key.toString()] = _resolveTemplateValue(
          item,
          target: target,
          connectedDevices: connectedDevices,
          cycle: cycle,
          run: run,
        );
      });
      return mapped;
    }
    if (value is List) {
      return value
          .map((item) => _resolveTemplateValue(
                item,
                target: target,
                connectedDevices: connectedDevices,
                cycle: cycle,
                run: run,
              ))
          .toList();
    }
    if (value is! String) {
      return value;
    }

    final first = connectedDevices.isNotEmpty ? connectedDevices.first : null;
    final second = connectedDevices.length > 1 ? connectedDevices[1] : null;
    final other = connectedDevices.firstWhere(
      (device) => device.portName != target.portName,
      orElse: () => target,
    );

    var result = value;
    result = result.replaceAll('{{cycle}}', cycle.toString());
    result = result.replaceAll('{{run}}', run.toString());
    result = result.replaceAll('{{targetPort}}', target.portName);
    result = result.replaceAll('{{firstPort}}', first?.portName ?? '');
    result = result.replaceAll('{{secondPort}}', second?.portName ?? '');
    result = result.replaceAll('{{otherPort}}', other.portName);

    final firstId = first != null ? _deviceIdByPort[first.portName] ?? '' : '';
    final secondId =
        second != null ? _deviceIdByPort[second.portName] ?? '' : '';
    final otherId = _deviceIdByPort[other.portName] ?? '';
    result = result.replaceAll('{{firstDeviceId}}', firstId);
    result = result.replaceAll('{{secondDeviceId}}', secondId);
    result = result.replaceAll('{{otherDeviceId}}', otherId);
    result =
        result.replaceAll('{{firstDeviceAddress}}', _formatBleAddress(firstId));
    result = result.replaceAll(
        '{{secondDeviceAddress}}', _formatBleAddress(secondId));
    result =
        result.replaceAll('{{otherDeviceAddress}}', _formatBleAddress(otherId));
    return result;
  }

  String _formatBleAddress(String rawDeviceId) {
    final hex = rawDeviceId.toLowerCase().replaceAll(RegExp('[^0-9a-f]'), '');
    if (hex.isEmpty) {
      return '';
    }
    final normalized = hex.length >= 12
        ? hex.substring(hex.length - 12)
        : hex.padLeft(12, '0');
    final parts = <String>[];
    for (var index = 0; index < normalized.length; index += 2) {
      parts.add(normalized.substring(index, index + 2));
    }
    return parts.join(':');
  }

  Future<bool> _waitForStressExpectation(
    _StressExpectation expectation, {
    required DeviceProfile sourceDevice,
    required List<DeviceProfile> connectedDevices,
    required int sinceSequence,
    required int cycle,
    required int run,
  }) async {
    final deadline =
        DateTime.now().add(Duration(milliseconds: expectation.timeoutMs));

    while (DateTime.now().isBefore(deadline)) {
      if (_stressStopRequested || _disposed) {
        return false;
      }

      final ports = expectation.resolvePorts(sourceDevice, connectedDevices);
      for (final port in ports) {
        final history = _frameHistory[port] ?? const <_ObservedFrame>[];
        for (final observed in history) {
          if (observed.sequence <= sinceSequence) {
            continue;
          }
          final frame = observed.frame;
          if (expectation.kind != null && frame.kind != expectation.kind) {
            continue;
          }
          if (expectation.type != null && frame.type != expectation.type) {
            continue;
          }

          final expectedMessage = expectation.messageContains == null
              ? null
              : _resolveTemplateValue(
                  expectation.messageContains,
                  target: sourceDevice,
                  connectedDevices: connectedDevices,
                  cycle: cycle,
                  run: run,
                ).toString();
          if (expectedMessage != null) {
            final actualMessage =
                frame.payload['message']?.toString() ?? '${frame.payload}';
            if (!actualMessage.contains(expectedMessage)) {
              continue;
            }
          }

          var payloadMatches = true;
          expectation.payloadContains.forEach((key, expectedValue) {
            if (!payloadMatches) {
              return;
            }
            final resolvedExpected = _resolveTemplateValue(
              expectedValue,
              target: sourceDevice,
              connectedDevices: connectedDevices,
              cycle: cycle,
              run: run,
            );
            final actual = _resolvePayloadField(frame.payload, key);
            if ('$actual' != '$resolvedExpected') {
              payloadMatches = false;
            }
          });

          if (payloadMatches) {
            return true;
          }
        }
      }

      await Future<void>.delayed(const Duration(milliseconds: 50));
    }

    return false;
  }

  dynamic _resolvePayloadField(Map<String, dynamic> payload, String keyPath) {
    dynamic value = _resolvePath(payload, keyPath);
    if (value != null) {
      return value;
    }

    // Most firmware responses place command data under payload.data.
    final nested = payload['data'];
    if (nested is Map) {
      value = _resolvePath(Map<String, dynamic>.from(nested), keyPath);
      if (value != null) {
        return value;
      }
    }

    return null;
  }

  dynamic _resolvePath(Map<String, dynamic> root, String keyPath) {
    if (keyPath.isEmpty) {
      return null;
    }
    final segments = keyPath.split('.');
    dynamic current = root;
    for (final segment in segments) {
      if (current is! Map) {
        return null;
      }
      final map = Map<String, dynamic>.from(current);
      if (!map.containsKey(segment)) {
        return null;
      }
      current = map[segment];
    }
    return current;
  }

  @override
  void dispose() {
    _disposed = true;
    _stressStopRequested = true;
    _telemetryTimer?.cancel();
    unawaited(orchestratorService.dispose());
    super.dispose();
  }
}

class _StressStep {
  const _StressStep({
    required this.name,
    required this.command,
    this.payload = const <String, dynamic>{},
    this.target = 'each',
    this.repeat = 1,
    this.delayMs = 80,
    this.expectation,
  });

  final String name;
  final String command;
  final Map<String, dynamic> payload;
  final String target;
  final int repeat;
  final int delayMs;
  final _StressExpectation? expectation;

  factory _StressStep.fromJson(Map<String, dynamic> json) {
    final repeat = (json['repeat'] as num?)?.toInt() ?? 1;
    final delayMs = (json['delayMs'] as num?)?.toInt() ?? 80;
    final expectationJson = json['expect'];
    return _StressStep(
      name: (json['name'] ?? json['command'] ?? 'step').toString(),
      command: (json['command'] ?? '').toString(),
      payload: Map<String, dynamic>.from(
        json['payload'] as Map? ?? const <String, dynamic>{},
      ),
      target: (json['target'] ?? 'each').toString(),
      repeat: repeat < 1 ? 1 : repeat,
      delayMs: delayMs < 0 ? 0 : delayMs,
      expectation: expectationJson is Map
          ? _StressExpectation.fromJson(
              Map<String, dynamic>.from(expectationJson))
          : null,
    );
  }
}

class _StressExpectation {
  const _StressExpectation({
    this.device = 'same',
    this.kind,
    this.type,
    this.messageContains,
    this.payloadContains = const <String, dynamic>{},
    this.timeoutMs = 5000,
  });

  final String device;
  final String? kind;
  final String? type;
  final String? messageContains;
  final Map<String, dynamic> payloadContains;
  final int timeoutMs;

  factory _StressExpectation.fromJson(Map<String, dynamic> json) {
    return _StressExpectation(
      device: (json['device'] ?? 'same').toString(),
      kind: json['kind']?.toString(),
      type: json['type']?.toString(),
      messageContains: json['messageContains']?.toString(),
      payloadContains: Map<String, dynamic>.from(
        json['payloadContains'] as Map? ?? const <String, dynamic>{},
      ),
      timeoutMs: (json['timeoutMs'] as num?)?.toInt() ?? 5000,
    );
  }

  List<String> resolvePorts(
    DeviceProfile sourceDevice,
    List<DeviceProfile> connectedDevices,
  ) {
    switch (device.toLowerCase()) {
      case 'same':
        return <String>[sourceDevice.portName];
      case 'other':
        return connectedDevices
            .where((item) => item.portName != sourceDevice.portName)
            .map((item) => item.portName)
            .toList();
      case 'first':
        return connectedDevices.isNotEmpty
            ? <String>[connectedDevices.first.portName]
            : const <String>[];
      case 'second':
        return connectedDevices.length > 1
            ? <String>[connectedDevices[1].portName]
            : const <String>[];
      case 'all':
        return connectedDevices.map((item) => item.portName).toList();
      default:
        final matched = connectedDevices
            .where(
                (item) => item.portName.toLowerCase() == device.toLowerCase())
            .map((item) => item.portName)
            .toList();
        return matched;
    }
  }
}

class _ObservedFrame {
  const _ObservedFrame({required this.sequence, required this.frame});

  final int sequence;
  final ProtocolFrame frame;
}

class _StressFailure {
  const _StressFailure({
    required this.port,
    required this.stepName,
    required this.reason,
    required this.cycle,
  });

  final String port;
  final String stepName;
  final String reason;
  final int cycle;
}
