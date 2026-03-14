import 'package:flutter/material.dart';

import '../../core/models/device_profile.dart';
import '../../core/state/orchestrator_controller.dart';
import 'widgets/board_panel.dart';
import 'widgets/command_result_panel.dart';
import 'widgets/log_pane.dart';

class DashboardPage extends StatelessWidget {
  const DashboardPage({
    required this.controller,
    super.key,
  });

  final OrchestratorController controller;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final devices = controller.devices;
        return Scaffold(
          appBar: AppBar(
            title: const Text('NimBLE HITL Dashboard'),
            actions: <Widget>[
              IconButton(
                onPressed: controller.busy ? null : controller.refreshBranches,
                icon: const Icon(Icons.cloud_sync),
                tooltip: 'Refresh branches',
              ),
              IconButton(
                onPressed: controller.busy ? null : controller.discoverDevices,
                icon: const Icon(Icons.usb),
                tooltip: 'Discover devices',
              ),
              IconButton(
                onPressed: (controller.busy || controller.stressRunning)
                  ? null
                  : () => _runAndShowErrors(
                      context,
                      controller.flashDiscoveredDevices,
                    ),
                icon: const Icon(Icons.system_update_alt),
                tooltip: controller.stressRunning
                  ? 'Stop stress test before flashing'
                  : 'Build and flash',
              ),
              IconButton(
                onPressed: controller.busy
                    ? null
                    : (controller.stressRunning
                        ? controller.stopStressTest
                        : () => _runAndShowErrors(
                            context,
                            controller.startStressTest,
                          )),
                icon: Icon(controller.stressRunning ? Icons.stop : Icons.bolt),
                tooltip: controller.stressRunning
                    ? 'Stop stress test'
                    : 'Start stress test',
              ),
            ],
          ),
          body: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: <Widget>[
                _TopBar(controller: controller),
                const SizedBox(height: 16),
                CommandResultPanel(results: controller.commandResults),
                const SizedBox(height: 16),
                Expanded(
                  child: Row(
                    children: <Widget>[
                      Expanded(
                        child: _BoardColumn(
                          device: devices.isNotEmpty ? devices[0] : null,
                          controller: controller,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _BoardColumn(
                          device: devices.length > 1 ? devices[1] : null,
                          controller: controller,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({required this.controller});

  final OrchestratorController controller;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Wrap(
          spacing: 16,
          runSpacing: 12,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: <Widget>[
            ConstrainedBox(
              constraints: const BoxConstraints(minWidth: 200, maxWidth: 420),
              child: IntrinsicWidth(
                child: DropdownButtonFormField<String>(
                  decoration:
                      const InputDecoration(labelText: 'NimBLE-Arduino Branch'),
                  initialValue: controller.selectedBranch,
                  isExpanded: true,
                  items: controller.branches
                      .map((branch) => DropdownMenuItem<String>(
                            value: branch,
                            child: Text(branch),
                          ))
                      .toList(),
                  onChanged:
                      controller.busy ? null : controller.setSelectedBranch,
                ),
              ),
            ),
            FilledButton.tonal(
              onPressed:
                  controller.busy ? null : controller.checkoutSelectedBranch,
              child: const Text('Checkout branch'),
            ),
            OutlinedButton.icon(
              onPressed: controller.busy
                  ? null
                  : () => _showFirmwareBuildOptionsDialog(context, controller),
              icon: const Icon(Icons.tune),
              label: const Text('Firmware build options'),
            ),
            FilterChip(
              label: const Text('Leak alerts enabled'),
              selected: controller.leakDetectionEnabled,
              onSelected: (selected) {
                controller.updateLeakDetection(
                  enabled: selected,
                  thresholdBytes: controller.leakThresholdBytes,
                  thresholdPercent: controller.leakThresholdPercent,
                );
              },
            ),
            FilterChip(
              label: const Text('Loop stress script'),
              selected: controller.stressLoopEnabled,
              onSelected: controller.stressRunning
                  ? null
                  : controller.setStressLoopEnabled,
            ),
            if (controller.stressHasResults)
              ActionChip(
                avatar: Icon(
                  controller.stressFailCount == 0
                      ? Icons.check_circle
                      : Icons.cancel,
                  color: controller.stressFailCount == 0
                      ? Colors.green.shade700
                      : Theme.of(context).colorScheme.error,
                ),
                label: Text(
                  '${controller.stressPassCount} passed'
                  ' · ${controller.stressFailCount} failed',
                  style: TextStyle(
                    color: controller.stressFailCount == 0
                        ? Colors.green.shade700
                        : Theme.of(context).colorScheme.error,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                onPressed: () => _showStressResultsDialog(context, controller),
              ),
            SizedBox(
              width: 150,
              child: TextFormField(
                initialValue: '${controller.leakThresholdBytes}',
                decoration: const InputDecoration(labelText: 'Heap threshold'),
                keyboardType: TextInputType.number,
                onFieldSubmitted: (value) {
                  final parsed =
                      int.tryParse(value) ?? controller.leakThresholdBytes;
                  controller.updateLeakDetection(
                    enabled: controller.leakDetectionEnabled,
                    thresholdBytes: parsed,
                    thresholdPercent: controller.leakThresholdPercent,
                  );
                },
              ),
            ),
            SizedBox(
              width: 160,
              child: TextFormField(
                initialValue:
                    controller.leakThresholdPercent.toStringAsFixed(2),
                decoration: const InputDecoration(labelText: 'Drop threshold'),
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                onFieldSubmitted: (value) {
                  final parsed =
                      double.tryParse(value) ?? controller.leakThresholdPercent;
                  controller.updateLeakDetection(
                    enabled: controller.leakDetectionEnabled,
                    thresholdBytes: controller.leakThresholdBytes,
                    thresholdPercent: parsed,
                  );
                },
              ),
            ),
            Chip(
              avatar: controller.busy
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.check_circle_outline),
              label: Text(controller.statusMessage ?? 'Ready'),
            ),
          ],
        ),
      ),
    );
  }
}

void _showFirmwareBuildOptionsDialog(
  BuildContext context,
  OrchestratorController controller,
) {
  var ledEnabled = controller.activityLedEnabled;
  var ledGpioText = controller.activityLedGpio.toString();

  showDialog<void>(
    context: context,
    builder: (dialogContext) {
      return StatefulBuilder(
        builder: (context, setState) {
          return AlertDialog(
            title: const Text('Firmware build options'),
            content: SizedBox(
              width: 420,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    'These options are compiled into firmware and take effect after build and flash.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 12),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Activity LED enabled'),
                    subtitle: const Text('Blink heartbeat LED in firmware main loop'),
                    value: ledEnabled,
                    onChanged: (value) {
                      setState(() {
                        ledEnabled = value;
                      });
                    },
                  ),
                  const SizedBox(height: 8),
                  TextFormField(
                    initialValue: ledGpioText,
                    decoration: const InputDecoration(
                      labelText: 'Activity LED GPIO',
                      helperText: 'Valid range: 0-48',
                    ),
                    keyboardType: TextInputType.number,
                    onChanged: (value) {
                      ledGpioText = value;
                    },
                  ),
                ],
              ),
            ),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () {
                  final parsedGpio =
                      int.tryParse(ledGpioText) ?? controller.activityLedGpio;
                  _runAndShowErrors(
                    context,
                    () => controller.updateActivityLedSettings(
                      enabled: ledEnabled,
                      gpio: parsedGpio,
                    ),
                  );
                  Navigator.of(dialogContext).pop();
                },
                child: const Text('Apply'),
              ),
            ],
          );
        },
      );
    },
  );
}

Future<void> _runAndShowErrors(
    BuildContext context, Future<void> Function() action) async {
  try {
    await action();
  } catch (error) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text('$error'), backgroundColor: Colors.red.shade700),
      );
    }
  }
}

void _showStressResultsDialog(
    BuildContext context, OrchestratorController controller) {
  final failures = controller.stressFailures;
  showDialog<void>(
    context: context,
    builder: (context) {
      return AlertDialog(
        title: Row(
          children: [
            Icon(
              controller.stressFailCount == 0
                  ? Icons.check_circle
                  : Icons.cancel,
              color: controller.stressFailCount == 0
                  ? Colors.green.shade700
                  : Theme.of(context).colorScheme.error,
            ),
            const SizedBox(width: 8),
            Text(
              '${controller.stressPassCount} passed'
              ' · ${controller.stressFailCount} failed',
            ),
          ],
        ),
        content: SelectionArea(
          child: SizedBox(
            width: 560,
            child: failures.isEmpty
                ? const Text('All checks passed — no failures to show.')
                : ListView.separated(
                    shrinkWrap: true,
                    itemCount: failures.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final f = failures[index];
                      return ListTile(
                        leading: Icon(Icons.cancel,
                            color: Theme.of(context).colorScheme.error,
                            size: 20),
                        title: Text('${f.stepName}  [cycle ${f.cycle}]'),
                        subtitle: Text('${f.port} — ${f.reason}'),
                      );
                    },
                  ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      );
    },
  );
}

class _BoardColumn extends StatelessWidget {
  const _BoardColumn({
    required this.device,
    required this.controller,
  });

  final DeviceProfile? device;
  final OrchestratorController controller;

  @override
  Widget build(BuildContext context) {
    if (device == null) {
      return const Card(
        child: Center(
          child: Text('Connect two ESP32 targets to populate this pane.'),
        ),
      );
    }

    return Column(
      children: <Widget>[
        BoardPanel(
          device: device!,
          onConnect: () => _runAndShowErrors(context, () => controller.connectToDevice(device!)),
          onDisconnect: () => _runAndShowErrors(context, () => controller.disconnectFromDevice(device!)),
          onDecodeCrash: controller.hasCapturedCrash(device!.portName)
              ? () => controller.decodeCapturedCrash(device!)
              : null,
          onSwitchTransport: () => controller.switchTransport(
            device!,
            device!.telemetry.transport == 'serial' ? 'ble' : 'serial',
          ),
        ),
        const SizedBox(height: 12),
        Expanded(
          child: LogPane(
            title: '${device!.displayName} raw log',
            lines: controller.logsFor(device!.portName),
          ),
        ),
      ],
    );
  }
}
