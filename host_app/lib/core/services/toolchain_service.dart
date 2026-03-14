import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as path;

import '../models/device_profile.dart';
import 'command_runner.dart';
import 'runtime_environment.dart';

class ToolchainService {
  ToolchainService(this._runner, this._runtimeEnvironment);

  final CommandRunner _runner;
  final RuntimeEnvironment _runtimeEnvironment;

  Future<void> prepareFirmwareEnvironment({
    required DeviceProfile device,
    required String projectDirectory,
    required String nimbleCheckoutDirectory,
  }) async {
    final generated = File('$projectDirectory\\generated_env.ini');
    final envName = generatedEnvironmentNameFor(device);
    await generated.writeAsString(
      '''
[env:$envName]
extends = env:${environmentNameFor(device)}
build_flags =
  -DNIMBLE_SOURCE_PATH=\\"$nimbleCheckoutDirectory\\"
  -DDEVICE_ARCH=\\"${device.architecture}\\"
  -DDEVICE_FLASH_MB=${device.flashSizeMb}
  -DDEVICE_PSRAM_MB=${device.psramSizeMb}
''',
    );
  }

  Future<List<String>> prepareFirmwareEnvironments({
    required List<DeviceProfile> devices,
    required String projectDirectory,
    required String nimbleCheckoutDirectory,
  }) async {
    final generated = File('$projectDirectory\\generated_env.ini');
    final sectionsByEnv = <String, String>{};

    for (final device in devices) {
      final envName = generatedEnvironmentNameFor(device);
      sectionsByEnv.putIfAbsent(
        envName,
        () => '''
[env:$envName]
extends = env:${environmentNameFor(device)}
build_flags =
  -DNIMBLE_SOURCE_PATH=\\"$nimbleCheckoutDirectory\\"
  -DDEVICE_ARCH=\\"${device.architecture}\\"
  -DDEVICE_FLASH_MB=${device.flashSizeMb}
  -DDEVICE_PSRAM_MB=${device.psramSizeMb}
''',
      );
    }

    final content = sectionsByEnv.values.join('\n');
    await generated.writeAsString(content);
    return sectionsByEnv.keys.toList();
  }

  String environmentNameFor(DeviceProfile device) {
    final normalized = device.architecture.toLowerCase();
    if (normalized.contains('s3')) {
      return 'esp32s3';
    }
    if (normalized.contains('c3')) {
      return 'esp32c3';
    }
    return 'esp32';
  }

  String generatedEnvironmentNameFor(DeviceProfile device) =>
      'generated_${environmentNameFor(device)}';

  Future<void> buildAndFlash({
    required DeviceProfile device,
    required String projectDirectory,
    Duration timeout = const Duration(minutes: 8),
    void Function(String line)? onOutput,
  }) async {
    final env = generatedEnvironmentNameFor(device);
    try {
      await _runner.runStreamingCheckedAny(
        _runtimeEnvironment.resolveToolInvocations(
          commandNames: const <String>['pio', 'platformio'],
          pythonModule: 'platformio',
          arguments: <String>[
            'run',
            '--project-dir',
            projectDirectory,
            '--environment',
            env,
            '--target',
            'upload',
            '--upload-port',
            device.portName,
          ],
        ),
        onInvocationStarted: (invocation) {
          onOutput?.call(
            'Running ${invocation.executable} ${invocation.arguments.join(' ')}',
          );
        },
        onStdoutLine: onOutput,
        onStderrLine: onOutput,
      ).timeout(timeout);
    } on TimeoutException {
      throw TimeoutException(
        'Build and flash timed out for ${device.portName} after '
        '${timeout.inMinutes} minute(s).',
      );
    } on ProcessException catch (error) {
      throw _wrapPlatformIoResolutionError(error);
    }
  }

  Future<void> buildEnvironment({
    required String environment,
    required String projectDirectory,
    Duration timeout = const Duration(minutes: 8),
    void Function(String line)? onOutput,
  }) async {
    try {
      await _runner.runStreamingCheckedAny(
        _runtimeEnvironment.resolveToolInvocations(
          commandNames: const <String>['pio', 'platformio'],
          pythonModule: 'platformio',
          arguments: <String>[
            'run',
            '--project-dir',
            projectDirectory,
            '--environment',
            environment,
          ],
        ),
        onInvocationStarted: (invocation) {
          onOutput?.call(
            'Running ${invocation.executable} ${invocation.arguments.join(' ')}',
          );
        },
        onStdoutLine: onOutput,
        onStderrLine: onOutput,
      ).timeout(timeout);
    } on TimeoutException {
      throw TimeoutException(
        'Build timed out for environment $environment after '
        '${timeout.inMinutes} minute(s).',
      );
    } on ProcessException catch (error) {
      throw _wrapPlatformIoResolutionError(error);
    }
  }

  Future<void> uploadBuiltFirmware({
    required DeviceProfile device,
    required String projectDirectory,
    Duration timeout = const Duration(minutes: 4),
    void Function(String line)? onOutput,
  }) async {
    final env = generatedEnvironmentNameFor(device);
    try {
      await _runner.runStreamingCheckedAny(
        _runtimeEnvironment.resolveToolInvocations(
          commandNames: const <String>['pio', 'platformio'],
          pythonModule: 'platformio',
          arguments: <String>[
            'run',
            '--project-dir',
            projectDirectory,
            '--environment',
            env,
            '--target',
            'upload',
            '--upload-port',
            device.portName,
          ],
        ),
        onInvocationStarted: (invocation) {
          onOutput?.call(
            'Running ${invocation.executable} ${invocation.arguments.join(' ')}',
          );
        },
        onStdoutLine: onOutput,
        onStderrLine: onOutput,
      ).timeout(timeout);
    } on TimeoutException {
      throw TimeoutException(
        'Upload timed out for ${device.portName} after '
        '${timeout.inMinutes} minute(s).',
      );
    } on ProcessException catch (error) {
      throw _wrapPlatformIoResolutionError(error);
    }
  }

  Future<String> decodeCrashDump({
    required String decoderExecutable,
    required String elfPath,
    required String dumpPath,
  }) async {
    final result = await _runner.runChecked(
      _runtimeEnvironment.resolveExceptionDecoderExecutable(decoderExecutable),
      <String>['--elf', elfPath, '--input', dumpPath],
    );
    return result.stdout;
  }

  Object _wrapPlatformIoResolutionError(ProcessException error) {
    final message = error.message.toLowerCase();
    final isResolutionFailure = message
            .contains('no module named platformio') ||
        message.contains('not recognized as an internal or external command') ||
        message.contains('the system cannot find the file specified') ||
        message.contains('cannot find the file specified') ||
        message.contains('no such file or directory') ||
        message.contains('not found');

    if (!isResolutionFailure) {
      return error;
    }

    final bootstrapScript = path.join(
      _runtimeEnvironment.applicationRoot,
      'scripts',
      'bootstrap_windows_tools.ps1',
    );
    return StateError(
      'PlatformIO is not available. Run `$bootstrapScript` to install bundled '
      'Windows tools into `tools\\python`, or use the packaged Windows app.',
    );
  }
}
