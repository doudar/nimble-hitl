class TelemetrySnapshot {
  const TelemetrySnapshot({
    required this.freeHeap,
    required this.minimumFreeHeap,
    required this.mtu,
    required this.activeRole,
    required this.transport,
    required this.updatedAt,
    this.leakDetected = false,
    this.leakReason,
  });

  factory TelemetrySnapshot.empty() {
    return TelemetrySnapshot(
      freeHeap: 0,
      minimumFreeHeap: 0,
      mtu: 23,
      activeRole: 'idle',
      transport: 'serial',
      updatedAt: DateTime.fromMillisecondsSinceEpoch(0),
    );
  }

  final int freeHeap;
  final int minimumFreeHeap;
  final int mtu;
  final String activeRole;
  final String transport;
  final bool leakDetected;
  final String? leakReason;
  final DateTime updatedAt;

  TelemetrySnapshot copyWith({
    int? freeHeap,
    int? minimumFreeHeap,
    int? mtu,
    String? activeRole,
    String? transport,
    bool? leakDetected,
    String? leakReason,
    DateTime? updatedAt,
  }) {
    return TelemetrySnapshot(
      freeHeap: freeHeap ?? this.freeHeap,
      minimumFreeHeap: minimumFreeHeap ?? this.minimumFreeHeap,
      mtu: mtu ?? this.mtu,
      activeRole: activeRole ?? this.activeRole,
      transport: transport ?? this.transport,
      leakDetected: leakDetected ?? this.leakDetected,
      leakReason: leakReason ?? this.leakReason,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  factory TelemetrySnapshot.fromPayload(Map<String, dynamic> payload) {
    final updatedAtValue = payload['updatedAt'];
    final updatedAt = switch (updatedAtValue) {
      int milliseconds => DateTime.fromMillisecondsSinceEpoch(milliseconds),
      double milliseconds =>
        DateTime.fromMillisecondsSinceEpoch(milliseconds.toInt()),
      String isoString =>
        DateTime.tryParse(isoString) ?? DateTime.now(),
      _ => DateTime.now(),
    };

    return TelemetrySnapshot(
      freeHeap: payload['freeHeap'] as int? ?? 0,
      minimumFreeHeap: payload['minimumFreeHeap'] as int? ?? 0,
      mtu: payload['mtu'] as int? ?? 23,
      activeRole: payload['activeRole'] as String? ?? 'idle',
      transport: payload['transport'] as String? ?? 'serial',
      leakDetected: payload['leakDetected'] as bool? ?? false,
      leakReason: payload['leakReason'] as String?,
      updatedAt: updatedAt,
    );
  }
}

