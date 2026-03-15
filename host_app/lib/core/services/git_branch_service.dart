import 'dart:io';

import 'command_runner.dart';

class GitBranchService {
  GitBranchService(this._runner);

  final CommandRunner _runner;

  static const remoteUrl = 'https://github.com/h2zero/nimble-arduino.git';

  Future<List<String>> listRemoteBranches() async {
    final result = await _runner.runChecked(
      'git',
      <String>['ls-remote', '--heads', remoteUrl],
    );

    return result.stdout
        .split('\n')
        .where((line) => line.contains('refs/heads/'))
        .map((line) => line.split('refs/heads/').last.trim())
        .where((branch) => branch.isNotEmpty)
        .toList()
      ..sort();
  }

  Future<String?> getRemoteDefaultBranch() async {
    final result = await _runner.runChecked(
      'git',
      <String>['ls-remote', '--symref', remoteUrl, 'HEAD'],
    );

    for (final line in result.stdout.split('\n')) {
      final trimmed = line.trim();
      if (!trimmed.startsWith('ref: ')) {
        continue;
      }

      final parts = trimmed.split(RegExp(r'\s+'));
      if (parts.length < 3 || parts.last != 'HEAD') {
        continue;
      }

      const branchPrefix = 'refs/heads/';
      final branchRef = parts[1];
      if (branchRef.startsWith(branchPrefix)) {
        return branchRef.substring(branchPrefix.length);
      }
    }

    return null;
  }

  Future<void> cloneOrCheckout({
    required String branch,
    required String checkoutDirectory,
  }) async {
    final directory = Directory(checkoutDirectory);
    if (!directory.existsSync()) {
      await _runner.runChecked(
        'git',
        <String>['clone', '--branch', branch, '--single-branch', remoteUrl, checkoutDirectory],
      );
      return;
    }

    await _runner.runChecked('git', <String>['fetch', '--all'], workingDirectory: checkoutDirectory);
    await _runner.runChecked('git', <String>['checkout', branch], workingDirectory: checkoutDirectory);
    await _runner.runChecked('git', <String>['pull', '--ff-only'], workingDirectory: checkoutDirectory);
  }
}

