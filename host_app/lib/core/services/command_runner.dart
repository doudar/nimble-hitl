import 'dart:async';
import 'dart:convert';
import 'dart:io';

class CommandInvocation {
  const CommandInvocation({
    required this.executable,
    required this.arguments,
  });

  final String executable;
  final List<String> arguments;
}

class CommandResult {
  const CommandResult({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
  });

  final int exitCode;
  final String stdout;
  final String stderr;
}

class CommandRunner {
  const CommandRunner();

  Future<CommandResult> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
  }) async {
    final result = await Process.run(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      runInShell: true,
    );

    return CommandResult(
      exitCode: result.exitCode,
      stdout: '${result.stdout}',
      stderr: '${result.stderr}',
    );
  }

  Future<CommandResult> runChecked(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
  }) async {
    final result = await run(
      executable,
      arguments,
      workingDirectory: workingDirectory,
    );

    if (result.exitCode != 0) {
      throw ProcessException(
        executable,
        arguments,
        result.stderr.isEmpty ? result.stdout : result.stderr,
        result.exitCode,
      );
    }

    return result;
  }

  Future<CommandResult> runCheckedAny(
    List<CommandInvocation> invocations, {
    String? workingDirectory,
  }) async {
    if (invocations.isEmpty) {
      throw ArgumentError.value(
          invocations, 'invocations', 'Must not be empty');
    }

    ProcessException? lastError;
    ProcessException? preferredError;

    for (var index = 0; index < invocations.length; index++) {
      final invocation = invocations[index];
      try {
        return await runChecked(
          invocation.executable,
          invocation.arguments,
          workingDirectory: workingDirectory,
        );
      } on ProcessException catch (error) {
        lastError = error;
        preferredError = _preferError(preferredError, error);
        final isLastAttempt = index == invocations.length - 1;
        if (!_isRetryableResolutionError(error)) {
          rethrow;
        }

        if (isLastAttempt) {
          throw preferredError;
        }
      }
    }

    throw preferredError ??
        lastError ??
        ProcessException(
          invocations.first.executable,
          invocations.first.arguments,
          'No command invocations were attempted.',
        );
  }

  ProcessException _preferError(
    ProcessException? current,
    ProcessException candidate,
  ) {
    if (current == null) {
      return candidate;
    }

    return _errorPriority(candidate) > _errorPriority(current)
        ? candidate
        : current;
  }

  int _errorPriority(ProcessException error) {
    final message = error.message.toLowerCase();
    if (message.contains('no module named')) {
      return 3;
    }
    if (message.contains('not recognized as an internal or external command') ||
        message.contains('the system cannot find the file specified') ||
        message.contains('cannot find the file specified') ||
        message.contains('no such file or directory') ||
        message.contains('not found')) {
      return 1;
    }

    return 2;
  }

  bool _isRetryableResolutionError(ProcessException error) {
    return _errorPriority(error) != 2;
  }

  Future<CommandResult> runStreamingCheckedAny(
    List<CommandInvocation> invocations, {
    String? workingDirectory,
    void Function(CommandInvocation invocation)? onInvocationStarted,
    void Function(String line)? onStdoutLine,
    void Function(String line)? onStderrLine,
  }) async {
    if (invocations.isEmpty) {
      throw ArgumentError.value(
          invocations, 'invocations', 'Must not be empty');
    }

    ProcessException? lastError;
    ProcessException? preferredError;

    for (var index = 0; index < invocations.length; index++) {
      final invocation = invocations[index];
      onInvocationStarted?.call(invocation);
      try {
        final result = await _runStreaming(
          invocation.executable,
          invocation.arguments,
          workingDirectory: workingDirectory,
          onStdoutLine: onStdoutLine,
          onStderrLine: onStderrLine,
        );
        if (result.exitCode != 0) {
          throw ProcessException(
            invocation.executable,
            invocation.arguments,
            result.stderr.isEmpty ? result.stdout : result.stderr,
            result.exitCode,
          );
        }
        return result;
      } on ProcessException catch (error) {
        lastError = error;
        preferredError = _preferError(preferredError, error);
        final isLastAttempt = index == invocations.length - 1;
        if (!_isRetryableResolutionError(error)) {
          rethrow;
        }

        if (isLastAttempt) {
          throw preferredError;
        }
      }
    }

    throw preferredError ??
        lastError ??
        ProcessException(
          invocations.first.executable,
          invocations.first.arguments,
          'No command invocations were attempted.',
        );
  }

  Future<CommandResult> _runStreaming(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    void Function(String line)? onStdoutLine,
    void Function(String line)? onStderrLine,
  }) async {
    final process = await Process.start(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      runInShell: true,
    );

    final stdoutLines = <String>[];
    final stderrLines = <String>[];
    final stdoutDone = Completer<void>();
    final stderrDone = Completer<void>();

    final stdoutSubscription = process.stdout
        .transform(systemEncoding.decoder)
        .transform(const LineSplitter())
        .listen(
      (line) {
        stdoutLines.add(line);
        onStdoutLine?.call(line);
      },
      onDone: () {
        if (!stdoutDone.isCompleted) {
          stdoutDone.complete();
        }
      },
      onError: (Object _, StackTrace __) {
        if (!stdoutDone.isCompleted) {
          stdoutDone.complete();
        }
      },
      cancelOnError: false,
    );

    final stderrSubscription = process.stderr
        .transform(systemEncoding.decoder)
        .transform(const LineSplitter())
        .listen(
      (line) {
        stderrLines.add(line);
        onStderrLine?.call(line);
      },
      onDone: () {
        if (!stderrDone.isCompleted) {
          stderrDone.complete();
        }
      },
      onError: (Object _, StackTrace __) {
        if (!stderrDone.isCompleted) {
          stderrDone.complete();
        }
      },
      cancelOnError: false,
    );

    final exitCode = await process.exitCode;

    // Some shell/process combinations on Windows can leave stream subscriptions
    // pending even after the child process exits. Bound waiting and then cancel.
    await Future.wait<void>(<Future<void>>[
      stdoutDone.future.timeout(const Duration(seconds: 2), onTimeout: () {}),
      stderrDone.future.timeout(const Duration(seconds: 2), onTimeout: () {}),
      stdoutSubscription.cancel(),
      stderrSubscription.cancel(),
    ]);

    return CommandResult(
      exitCode: exitCode,
      stdout: stdoutLines.join('\n'),
      stderr: stderrLines.join('\n'),
    );
  }
}
