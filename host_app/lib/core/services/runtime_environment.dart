import 'dart:io';

import 'package:path/path.dart' as path;

import 'command_runner.dart';

class RuntimeEnvironment {
  RuntimeEnvironment._(this.applicationRoot);

  factory RuntimeEnvironment.detect() {
    return RuntimeEnvironment._(_detectApplicationRoot());
  }

  final String applicationRoot;

  String get bundledToolsDirectory => path.join(applicationRoot, 'tools');

  String resolvePythonExecutable() {
    return _resolveBundledFile(
      path.join(bundledToolsDirectory, 'python', 'python.exe'),
      fallback: 'python',
    );
  }

  String resolveExceptionDecoderExecutable(String requested) {
    if (path.isAbsolute(requested) || requested.contains('\\')) {
      return requested;
    }

    final candidates = <String>[
      path.join(bundledToolsDirectory, 'esp32-exception-decoder', requested),
      path.join(bundledToolsDirectory, 'esp32-exception-decoder', '$requested.exe'),
      path.join(bundledToolsDirectory, 'python', 'Scripts', requested),
      path.join(bundledToolsDirectory, 'python', 'Scripts', '$requested.exe'),
    ];

    for (final candidate in candidates) {
      if (File(candidate).existsSync()) {
        return candidate;
      }
    }

    return requested;
  }

  List<CommandInvocation> resolveToolInvocations({
    required List<String> commandNames,
    String? pythonModule,
    List<String> arguments = const <String>[],
  }) {
    final invocations = <CommandInvocation>[];
    final seen = <String>{};

    void addInvocation(String executable, List<String> commandArguments) {
      final key = '$executable\u0000${commandArguments.join('\u0000')}';
      if (!seen.add(key)) {
        return;
      }

      invocations.add(
        CommandInvocation(
          executable: executable,
          arguments: List<String>.unmodifiable(commandArguments),
        ),
      );
    }

    for (final commandName in commandNames) {
      if (path.isAbsolute(commandName) || commandName.contains('\\')) {
        addInvocation(commandName, arguments);
        continue;
      }

      for (final candidate in _bundledCommandCandidates(commandName)) {
        if (File(candidate).existsSync()) {
          addInvocation(candidate, arguments);
        }
      }

      addInvocation(commandName, arguments);
    }

    if (pythonModule != null) {
      final moduleArguments = <String>['-m', pythonModule, ...arguments];
      addInvocation(resolvePythonExecutable(), moduleArguments);
      if (Platform.isWindows) {
        addInvocation('py', moduleArguments);
      }
      addInvocation('python', moduleArguments);
    }

    return invocations;
  }

  String _resolveBundledFile(String candidate, {required String fallback}) {
    return File(candidate).existsSync() ? candidate : fallback;
  }

  List<String> _bundledCommandCandidates(String commandName) {
    final scriptsDirectory = path.join(bundledToolsDirectory, 'python', 'Scripts');
    final fileNames = <String>{
      commandName,
      if (!commandName.toLowerCase().endsWith('.exe')) '$commandName.exe',
      if (!commandName.toLowerCase().endsWith('.py')) '$commandName.py',
      if (!commandName.toLowerCase().endsWith('-script.py'))
        '$commandName-script.py',
    };
    final candidateDirectories = <String>[
      path.join(bundledToolsDirectory, commandName),
      scriptsDirectory,
    ];
    final matches = <String>{};

    for (final directory in candidateDirectories) {
      for (final fileName in fileNames) {
        matches.add(path.join(directory, fileName));
      }
    }

    return matches.toList();
  }

  static String _detectApplicationRoot() {
    final currentDirectory = Directory.current.path;
    final executableDirectory = File(Platform.resolvedExecutable).parent.path;
    final candidates = <String>{
      if (path.basename(currentDirectory).toLowerCase() == 'host_app')
        path.dirname(currentDirectory),
      currentDirectory,
      executableDirectory,
      path.dirname(executableDirectory),
    };

    for (final candidate in candidates) {
      if (_looksLikeApplicationRoot(candidate)) {
        return candidate;
      }
    }

    return path.basename(currentDirectory).toLowerCase() == 'host_app'
        ? path.dirname(currentDirectory)
        : currentDirectory;
  }

  static bool _looksLikeApplicationRoot(String candidate) {
    return Directory(path.join(candidate, 'firmware')).existsSync() &&
        Directory(path.join(candidate, 'shared')).existsSync();
  }
}
