import 'dart:async';

import '../health/latency_tester.dart';
import '../../domain/entities/health.dart';
import '../../domain/entities/proxy_profile.dart';
import 'node_scorer.dart';

/// v0.3.0 §14 — Smart Connect candidate pipeline.
///
/// rank (NodeScorer) → cooldown filter → limited-concurrency TCP pre-probe
/// → ordered engine-start attempts (full HTTP verification happens in
/// [ConnectionController.connect]). A candidate is considered healthy only
/// after a real probe; parsing alone never qualifies.
///
/// Failed candidates enter a session-scoped cooldown and automatically
/// re-enter the pool when it expires (recovery of previously failed
/// candidates). Cooldowns are in-memory by design: a fresh app start must
/// never inherit stale "dead" verdicts.
class SmartConnectSelector {
  SmartConnectSelector({
    NodeScorer? scorer,
    this.maxConcurrentProbes = 6,
    this.preprobeTimeout = const Duration(seconds: 3),
    this.cooldown = const Duration(minutes: 3),
    this.maxPreprobeCandidates = 8,
    Future<ProbeResult> Function(ProxyProfile p, Duration timeout)? prober,
  })  : _scorer = scorer ?? NodeScorer(),
        _prober = prober ?? _defaultProber;

  final NodeScorer _scorer;
  final int maxConcurrentProbes;
  final Duration preprobeTimeout;
  final Duration cooldown;
  final int maxPreprobeCandidates;

  Future<ProbeResult> Function(ProxyProfile p, Duration timeout) _prober;

  static Future<ProbeResult> _defaultProber(
          ProxyProfile p, Duration timeout) async =>
      LatencyTester(defaultTimeout: timeout).testTcp(p.server, p.port,
          timeout: timeout);

  final Map<String, DateTime> _cooldownUntil = {};

  bool isCoolingDown(String profileId, {DateTime? now}) {
    final until = _cooldownUntil[profileId];
    if (until == null) return false;
    if ((now ?? DateTime.now()).isAfter(until)) {
      _cooldownUntil.remove(profileId); // recovery of previously failed
      return false;
    }
    return true;
  }

  void markFailed(String profileId, {DateTime? now}) {
    _cooldownUntil[profileId] = (now ?? DateTime.now()).add(cooldown);
  }

  int get coolingCount => _cooldownUntil.length;

  void clearCooldowns() => _cooldownUntil.clear();

  /// Ranked, enabled candidates minus cooling-down ones. If everything is
  /// cooling down, the pool is returned anyway ordered by soonest cooldown
  /// expiry — otherwise a fully-cooled list would deadlock Smart Connect.
  List<ProxyProfile> eligible(
    List<ProxyProfile> profiles,
    Map<String, NodeHealthStats> health,
    SelectionStrategy strategy, {
    DateTime? now,
  }) {
    final ranked = _scorer.rank(profiles, health, strategy).map((r) => r.$1);
    final t = now ?? DateTime.now();
    final hot = ranked.where((p) => !isCoolingDown(p.id, now: t)).toList();
    if (hot.isNotEmpty) return hot;
    final byExpiry = ranked.toList()
      ..sort((a, b) => (_cooldownUntil[a.id] ?? t)
          .compareTo(_cooldownUntil[b.id] ?? t));
    return byExpiry;
  }

  /// Limited-concurrency TCP pre-probe. Returns candidates whose server
  /// actually answered, preserving ranking order. Never throws — a probe
  /// error is just "no answer". Empty result means nothing answered.
  Future<List<(ProxyProfile, ProbeResult)>> preprobe(
    List<ProxyProfile> candidates, {
    int? concurrency,
  }) async {
    final pool = candidates.take(maxPreprobeCandidates).toList();
    final results = List<(ProxyProfile, ProbeResult)?>.filled(
        pool.length, null);
    var next = 0;
    var inFlight = 0;
    final k = concurrency ?? maxConcurrentProbes;

    Future<void> worker() async {
      while (true) {
        final i = next++;
        if (i >= pool.length) return;
        inFlight++;
        try {
          results[i] = (pool[i], await _prober(pool[i], preprobeTimeout));
        } catch (_) {
          results[i] = (
            pool[i],
            ProbeResult(ok: false, errorKind: 'tcp', detail: 'probe threw')
          );
        } finally {
          inFlight--;
        }
      }
    }

    await Future.wait(
        List.generate(pool.length < k ? pool.length : k, (_) => worker()));
    return results
        .whereType<(ProxyProfile, ProbeResult)>()
        .where((r) => r.$2.ok)
        .toList();
  }
}
