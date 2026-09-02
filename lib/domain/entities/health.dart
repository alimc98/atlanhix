/// Node health states shown in UI (§10).
enum NodeHealth {
  unknown,
  checking,
  healthy,
  degraded,
  timeout,
  offline,
  blocked,
  coreError,
  configError,
}

/// One probe result against a node.
class HealthRecord {
  HealthRecord({
    required this.profileId,
    required this.at,
    required this.ok,
    this.latencyMs,
    this.handshakeMs,
    this.httpOk,
    this.dnsOk,
    this.errorKind,
  });

  final String profileId;
  final DateTime at;
  final bool ok;
  final int? latencyMs;
  final int? handshakeMs;
  final bool? httpOk;
  final bool? dnsOk;
  final String? errorKind;
}

/// Derived, cached aggregate for a node.
class NodeHealthStats {
  NodeHealthStats({
    this.lastLatencyMs,
    this.avgLatencyMs,
    this.jitterMs,
    this.successRate = 0,
    this.consecutiveFailures = 0,
    this.lastSuccess,
    this.lastChecked,
    this.state = NodeHealth.unknown,
    this.sampleCount = 0,
  });

  int? lastLatencyMs;
  int? avgLatencyMs;
  int? jitterMs;
  double successRate;
  int consecutiveFailures;
  DateTime? lastSuccess;
  DateTime? lastChecked;
  NodeHealth state;
  int sampleCount;

  bool get isUsable =>
      state == NodeHealth.healthy ||
      state == NodeHealth.degraded ||
      state == NodeHealth.unknown;
}

/// Strategy for ranking nodes (§12).
enum SelectionStrategy { lowestLatency, mostStable, balanced, manualPriority, smart }
