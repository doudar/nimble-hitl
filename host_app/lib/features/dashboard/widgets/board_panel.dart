import 'package:flutter/material.dart';

import '../../../core/models/device_profile.dart';

class BoardPanel extends StatelessWidget {
  const BoardPanel({
    required this.device,
    required this.onConnect,
    required this.onDisconnect,
    required this.onDecodeCrash,
    required this.onSwitchTransport,
    super.key,
  });

  final DeviceProfile device;
  final VoidCallback onConnect;
  final VoidCallback onDisconnect;
  final VoidCallback? onDecodeCrash;
  final VoidCallback onSwitchTransport;

  @override
  Widget build(BuildContext context) {
    final telemetry = device.telemetry;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: <Widget>[
                Text(device.displayName, style: Theme.of(context).textTheme.titleLarge),
                Wrap(
                  spacing: 8,
                  children: <Widget>[
                    FilledButton.tonal(
                      onPressed: device.connected ? onDisconnect : onConnect,
                      child: Text(device.connected ? 'Disconnect' : 'Connect'),
                    ),
                    OutlinedButton(
                      onPressed: onDecodeCrash,
                      child: const Text('Decode crash'),
                    ),
                    OutlinedButton(
                      onPressed: onSwitchTransport,
                      child: Text('Use ${telemetry.transport == 'serial' ? 'BLE' : 'Serial'}'),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: <Widget>[
                _Fact(label: 'Architecture', value: device.architecture),
                _Fact(label: 'Chip', value: device.chipName),
                _Fact(label: 'Branch', value: device.branch ?? 'not checked out'),
                _Fact(label: 'Flash', value: '${device.flashSizeMb} MB'),
                _Fact(label: 'PSRAM', value: '${device.psramSizeMb} MB'),
                _Fact(label: 'Role', value: telemetry.activeRole),
                _Fact(label: 'MTU', value: '${telemetry.mtu}'),
                _Fact(label: 'Heap', value: '${telemetry.freeHeap}'),
                _Fact(label: 'Min Heap', value: '${telemetry.minimumFreeHeap}'),
                _Fact(label: 'Transport', value: telemetry.transport),
              ],
            ),
            if (telemetry.leakDetected) ...<Widget>[
              const SizedBox(height: 12),
              Text(
                telemetry.leakReason ?? 'Memory leak warning detected.',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.error,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
            if (device.lastError != null) ...<Widget>[
              const SizedBox(height: 12),
              Text(
                device.lastError!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Fact extends StatelessWidget {
  const _Fact({
    required this.label,
    required this.value,
  });

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 132,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(label, style: Theme.of(context).textTheme.labelMedium),
          const SizedBox(height: 6),
          Text(value, style: Theme.of(context).textTheme.titleMedium),
        ],
      ),
    );
  }
}

