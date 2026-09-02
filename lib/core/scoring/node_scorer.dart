import '../../domain/entities/health.dart';
import '../../domain/entities/proxy_profile.dart';

/// Computed score parts (kept for UI explanation).
class ScoreBreakdown {
  ScoreBreakdown({
    required this.total,
    required this.latency,
    required this.successRate,
    required this.stability,
    required this.recentHealth,
    required this.userPriority,
    required this.failurePenalty,
  });

  final double total;
  final double latency;
  final double successRate;
  final double stability;
  final double recentHealth;
  final double userPriority;
  final double failurePenalty;
}

/// Weights per selection strategy (§12).
class ScoringWeights {
  const ScoringWeights({
    this.latency = 0.45,
    this.successRate = 0.25,
    this.stability = 0.15,
    this.recentHealth = 0.10,
    this.priority = 0.05,
  });

  final double latency;
  final double successRate;
  final double stability;
  final double recentHealth;
  final double priority;

  static const balanced = ScoringWeights();

  static final lowestLatency = ScoringWeights(
    latency: 0.75,
    successRate: 0.15,
    stability: 0.05,
    recentHealth: 0.05,
    priority: 0.0,
  );

  static final mostStable = ScoringWeights(
    latency: 0.10,
    successRate: 0.45,
    stability: 0.30,
    recentHealth: 0.10,
    priority: 0.05,
  );

  static final smart = ScoringWeights(
    latency: 0.35,
    successRate: 0.30,
    stability: 0.20,
    recentHealth: 0.10,
    priority: 0.05,
  );
}

/// Scores nodes from 0..100 using cached health aggregates.
class NodeScorer {
  NodeScorer({this.failurePenaltyPerStrike = 12.0, this.maxPenalty = 45});

  final double failurePenaltyPerStrike;
  final double maxPenalty;

  ScoreBreakdown score(
    ProxyProfile p,
    NodeHealthStats? stats,
    SelectionStrategy strategy,
  ) {
    final w = switch (strategy) {
      SelectionStrategy.lowestLatency => ScoringWeights.lowestLatency,
      SelectionStrategy.mostStable => ScoringWeights.mostStable,
      SelectionStrategy.balanced => ScoringWeights.balanced,
      SelectionStrategy.manualPriority => ScoringWeights.balanced,
      SelectionStrategy.smart => ScoringWeights.smart,
    };

    // Latency: 0-100 mapped from 30 ms (best) to 1500 ms (worst).
    final lat = stats?.lastLatencyMs;
    final latencyScore = lat == null
        ? 35.0
        : (100.0 - ((lat - 30).clamp(0, 1470) / 1470) * 100.0).clamp(0, 100)
            .toDouble();

    final success =
        ((stats?.successRate ?? 0) * 100).clamp(0, 100).toDouble();

    // Stability: low jitter + consistent recent success.
    final jitter = stats?.jitterMs ?? 60;
    final stabilityScore =
        (100.0 - (jitter / 4).clamp(0, 60)).clamp(0, 100).toDouble();

    final recent = stats == null
        ? 40.0
        : stats.consecutiveFailures == 0
            ? 100.0
            : (100.0 - stats.consecutiveFailures * 25).clamp(0, 100)
                .toDouble();

    final priorityScore =
        ((int.tryParse(p.metadata['priority'] ?? '50') ?? 50)).toDouble();

    final penalty = ((stats?.consecutiveFailures ?? 0) * failurePenaltyPerStrike)
        .clamp(0, maxPenalty)
        .toDouble();

    final total = w.latency * latencyScore +
        w.successRate * success +
        w.stability * stabilityScore +
        w.recentHealth * recent +
        w.priority * priorityScore -
        penalty;

    return ScoreBreakdown(
      total: total.clamp(0, 100),
      latency: latencyScore,
      successRate: success,
      stability: stabilityScore,
      recentHealth: recent,
      userPriority: priorityScore,
      failurePenalty: penalty,
    );
  }

  /// Ranks all candidates; never returns profiles the health system marked
  /// unusable unless nothing else exists.
  List<(ProxyProfile, ScoreBreakdown)> rank(
    List<ProxyProfile> profiles,
    Map<String, NodeHealthStats> health,
    SelectionStrategy strategy,
  ) {
    final scored = profiles
        .where((p) => p.enabled)
        .map((p) => (p, score(p, health[p.id], strategy)))
        .toList()
      ..sort((a, b) => b.$2.total.compareTo(a.$2.total));
    final usable =
        scored.where((s) => health[s.$1.id]?.isUsable ?? true).toList();
    return usable.isEmpty ? scored : usable;
  }
}
