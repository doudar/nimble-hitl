import 'dart:convert';

import '../models/protocol_frame.dart';

class ProtocolCodec {
  final StringBuffer _buffer = StringBuffer();
  int _rawFrameSequence = 0;

  List<ProtocolFrame> decodeChunk(
    List<int> bytes, {
    String fallbackTarget = '',
  }) {
    _buffer.write(utf8.decode(bytes, allowMalformed: true));
    final frames = <ProtocolFrame>[];
    final content = _buffer.toString();
    final lines = content.split(RegExp(r'\r\n|[\r\n]'));

    _buffer.clear();
    final endsWithDelimiter = content.endsWith('\n') || content.endsWith('\r');
    if (!endsWithDelimiter) {
      _buffer.write(lines.removeLast());
    }

    for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) {
        continue;
      }
      try {
        final decoded = jsonDecode(trimmed) as Map<String, dynamic>;
        frames.add(ProtocolFrame.fromJson(decoded));
      } catch (_) {
        _rawFrameSequence += 1;
        frames.add(
          ProtocolFrame(
            id: 'raw-${_rawFrameSequence.toString().padLeft(4, '0')}',
            kind: 'log',
            type: 'raw',
            target: fallbackTarget,
            timestamp: DateTime.now(),
            payload: <String, dynamic>{'message': trimmed},
          ),
        );
      }
    }

    return frames;
  }

  List<int> encodeFrame(ProtocolFrame frame) {
    return utf8.encode('${jsonEncode(frame.toJson())}\n');
  }
}
