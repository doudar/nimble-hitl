import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_libserialport/flutter_libserialport.dart';

import '../models/protocol_frame.dart';
import 'protocol_codec.dart';

/// Native serial transport with explicit polling.
///
/// We intentionally avoid `SerialPortReader` because it has shown flaky
/// behavior on Windows after device resets/re-enumeration. Polling
/// `bytesAvailable` keeps the read loop simple and deterministic.
class SerialTransport {
  SerialTransport({
    required this.portName,
    required this.baudRate,
  });

  final String portName;
  final int baudRate;
  final ProtocolCodec _codec = ProtocolCodec();
  final StreamController<ProtocolFrame> _frames =
      StreamController<ProtocolFrame>.broadcast();

  SerialPort? _port;
  Timer? _pollTimer;
  bool _reportedFirstRx = false;
  int _pollErrorCount = 0;

  Stream<ProtocolFrame> get frames => _frames.stream;

  Future<void> open() async {
    final port = SerialPort(portName);
    if (!port.openReadWrite()) {
      port.dispose();
      throw StateError('Unable to open serial port $portName');
    }

    final config = SerialPortConfig();
    config.baudRate = baudRate;
    config.bits = 8;
    config.stopBits = 1;
    config.parity = SerialPortParity.none;
    config.dtr = SerialPortDtr.off;
    config.rts = SerialPortRts.off;
    config.cts = SerialPortCts.ignore;
    config.dsr = SerialPortDsr.ignore;
    config.setFlowControl(SerialPortFlowControl.none);
    port.config = config;
    config.dispose();

    _port = port;
    _reportedFirstRx = false;
    _pollErrorCount = 0;
    _pollTimer = Timer.periodic(const Duration(milliseconds: 20), (_) {
      final activePort = _port;
      if (activePort == null || !activePort.isOpen || _frames.isClosed) {
        return;
      }

      try {
        final available = activePort.bytesAvailable;
        if (available <= 0) {
          return;
        }

        final chunk = activePort.read(available);
        if (chunk.isEmpty) {
          return;
        }

        if (!_reportedFirstRx) {
          _reportedFirstRx = true;
          _frames.add(
            ProtocolFrame(
              id: 'serial-rx-${DateTime.now().microsecondsSinceEpoch}',
              kind: 'log',
              type: 'serial-rx',
              target: portName,
              timestamp: DateTime.now(),
              payload: <String, dynamic>{
                'message': '[serial] received ${chunk.length} byte(s)',
              },
            ),
          );
        }

        for (final frame
            in _codec.decodeChunk(chunk, fallbackTarget: portName)) {
          _frames.add(
            ProtocolFrame(
              id: frame.id,
              kind: frame.kind,
              type: frame.type,
              target: portName,
              timestamp: frame.timestamp,
              payload: frame.payload,
            ),
          );
        }
      } catch (error) {
        // Keep polling; transient read errors can happen during USB jitter.
        _pollErrorCount += 1;
        if (_pollErrorCount <= 3) {
          _frames.add(
            ProtocolFrame(
              id: 'serial-read-error-${DateTime.now().microsecondsSinceEpoch}',
              kind: 'log',
              type: 'serial-read-error',
              target: portName,
              timestamp: DateTime.now(),
              payload: <String, dynamic>{
                'message': '[serial] read error: $error',
              },
            ),
          );
        }
      }
    });

    if (!_frames.isClosed) {
      _frames.add(
        ProtocolFrame(
          id: 'serial-open-${DateTime.now().microsecondsSinceEpoch}',
          kind: 'log',
          type: 'serial-open',
          target: portName,
          timestamp: DateTime.now(),
          payload: <String, dynamic>{
            'message': '[serial] opened $portName @ $baudRate',
          },
        ),
      );
    }
  }

  Future<void> send(ProtocolFrame frame) async {
    final port = _port;
    if (port == null || !port.isOpen) {
      throw StateError('Serial port $portName is not open');
    }
    final bytes = _codec.encodeFrame(frame);
    final written = port.write(Uint8List.fromList(bytes));
    if (written != bytes.length) {
      throw StateError('Short write to $portName: $written/${bytes.length}');
    }
  }

  Future<void> close() async {
    _pollTimer?.cancel();
    _pollTimer = null;
    // Null the port reference before close/dispose so any timer tick that
    // was already enqueued will see null via _port and exit early.
    final port = _port;
    _port = null;
    if (!_frames.isClosed) {
      await _frames.close();
    }
    // Brief delay so the Windows kernel can drain any pending I/O completions
    // from the last poll before we tear down the native handle. Without this,
    // libserialport triggers a _CrtIsValidHeapPointer assertion on Windows.
    await Future<void>.delayed(const Duration(milliseconds: 100));
    port?.close();
  }
}
