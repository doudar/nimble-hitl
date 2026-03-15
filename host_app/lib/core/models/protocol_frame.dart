class ProtocolFrame {
  const ProtocolFrame({
    required this.id,
    required this.kind,
    required this.type,
    required this.target,
    required this.timestamp,
    required this.payload,
  });

  final String id;
  final String kind;
  final String type;
  final String target;
  final DateTime timestamp;
  final Map<String, dynamic> payload;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'id': id,
      'kind': kind,
      'type': type,
      'target': target,
      'timestamp': timestamp.toIso8601String(),
      'payload': payload,
    };
  }

  factory ProtocolFrame.fromJson(Map<String, dynamic> json) {
    final rawTimestamp = json['timestamp'];
    DateTime parsedTimestamp;
    if (rawTimestamp is String) {
      parsedTimestamp = DateTime.tryParse(rawTimestamp) ?? DateTime.now();
    } else {
      // Firmware sends monotonic millis (int), not ISO-8601 wall clock time.
      parsedTimestamp = DateTime.now();
    }

    return ProtocolFrame(
      id: (json['id'] ?? '').toString(),
      kind: (json['kind'] ?? 'event').toString(),
      type: (json['type'] ?? 'unknown').toString(),
      target: (json['target'] ?? '').toString(),
      timestamp: parsedTimestamp,
      payload: Map<String, dynamic>.from(
        json['payload'] as Map? ?? const <String, dynamic>{},
      ),
    );
  }
}
