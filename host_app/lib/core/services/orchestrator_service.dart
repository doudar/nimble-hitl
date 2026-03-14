import 'dart:async';

import '../models/device_profile.dart';
import '../models/protocol_frame.dart';
import 'device_discovery_service.dart';
import 'git_branch_service.dart';
import 'serial_transport.dart';
import 'toolchain_service.dart';

class OrchestratorService {
  OrchestratorService({
    required this.discoveryService,
    required this.gitBranchService,
    required this.toolchainService,
  });

  final DeviceDiscoveryService discoveryService;
  final GitBranchService gitBranchService;
  final ToolchainService toolchainService;

  final Map<String, SerialTransport> _transports = <String, SerialTransport>{};
  final Map<String, StreamSubscription<ProtocolFrame>> _subscriptions =
      <String, StreamSubscription<ProtocolFrame>>{};

  Future<List<DeviceProfile>> discoverDevices() => discoveryService.discoverDevices();

  Future<List<String>> listBranches() => gitBranchService.listRemoteBranches();

  Future<String?> getDefaultBranch() => gitBranchService.getRemoteDefaultBranch();

  Future<void> connect(
    DeviceProfile device,
    void Function(ProtocolFrame frame) onFrame,
  ) async {
    await disconnect(device.portName);
    final transport = SerialTransport(portName: device.portName, baudRate: 921600);
    try {
      await transport.open();
      _transports[device.portName] = transport;
      _subscriptions[device.portName] = transport.frames.listen(onFrame);
    } catch (_) {
      await transport.close();
      rethrow;
    }
  }

  Future<void> disconnect(String portName) async {
    await _subscriptions.remove(portName)?.cancel();
    await _transports.remove(portName)?.close();
  }

  Future<void> sendFrame(String portName, ProtocolFrame frame) async {
    final transport = _transports[portName];
    if (transport == null) {
      throw StateError('Transport for $portName is not connected');
    }
    await transport.send(frame);
  }

  Future<void> dispose() async {
    for (final portName in _transports.keys.toList()) {
      await disconnect(portName);
    }
  }
}

