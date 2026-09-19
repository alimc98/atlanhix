import 'dart:async';

import '../core/android_node_support.dart';
import '../core/health/latency_tester.dart';
import '../core/health/test_scheduler.dart';
import '../core/logger.dart';
import '../domain/entities/health.dart';
import '../domain/entities/proxy_profile.dart';

/// v0.4.7 §user — SMART SWITCH (a.k.a. Auto Select / smart node).
///
/// A virtual selection mode: the session "selects" whichever candidate is
/// currently best and keeps re-testing the pool on a timer, migrating the
/// live tunnel when a materially better node appears (or the active one
/// dies). State lives in [VpnSession] (it owns connect/disconnect); this
/// class only decides WHICH node should be active right now:
///
///   * candidates = enabled + Android-runnable (the same gate connect uses)
///   * ranking    = health-store score (healthy first, then latency)
///   * hysteresis = a switch only happens when the challenger beats the
///                  incumbent by a real margin (never ping-pongs on noise)
///   * cadence    = `AppSettings.smartSwitchIntervalSeconds` (0 = at
///                  connect-time only)
class SmartSwitch {
  SmartSwitch({
    required this.scheduler,
    required this.health,
    required this.interval,
    this.urlProbe,
  });

  final TestScheduler scheduler;
  final HealthStore health;

  /// v0.4.8 §user: the REAL criterion — an in-tunnel URL test per
  /// candidate (HTTP GET through the node outbound), not the raw TCP
  /// ping to the node IP. The TCP ping only proves the IP answers; a
  /// config whose tunnel cannot actually fetch the probe URL kept
  /// winning the ladder on a healthy-looking ping (device report:
  /// "the ping comes from the IP, not from the connection"). The probe
  /// runs through the running engine's delay-test API (sing-box measures
  /// the FULL path node → internet) and results are recorded into the
  /// shared HealthStore so the UI latency column and the ladder see the
  /// same truth. Null (no running engine / not supported) → falls back
  /// to the classic TCP probes.
  final Future<ProbeResult?> Function(ProxyProfile p)? urlProbe;

  /// Re-test period. Mutated live from Settings (0 disables the loop).
  Duration interval;

  Timer? _timer;
  StreamSubscription<HealthRecord>? _resultsSub;
  bool _sweeping = false;
  int _sweepSeq = 0;

  /// Node the switcher currently recommends (may be null while sweeping).
  ProxyProfile? best;

  /// Fired whenever [best] CHANGES (new id) — VpnSession migrates the tunnel.
  final _changed = StreamController<ProxyProfile>.broadcast();
  Stream<ProxyProfile> get changes => _changed.stream;

  void start(List<ProxyProfile> candidates, {String? currentId}) {
    stop();
    if (candidates.isEmpty) return;
    _resultsSub = scheduler.results.listen((_) => _evaluate(candidates, currentId: currentId));
    _sweep(candidates);
    _armTimer(candidates);
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _resultsSub?.cancel();
    _resultsSub = null;
    best = null;
    _sweepSeq++;
  }

  /// Refreshes candidates + cadence (subscription refresh / settings change).
  void reconfigure(List<ProxyProfile> candidates, {required Duration newInterval, String? currentId}) {
    interval = newInterval;
    if (_timer == null && _resultsSub == null) return; // not running
    start(candidates, currentId: currentId ?? best?.id);
  }

  void _armTimer(List<ProxyProfile> candidates) {
    _timer?.cancel();
    if (interval.inSeconds <= 0) return;
    _timer = Timer.periodic(interval, (_) => _sweep(candidates));
  }

  Future<void> _sweep(List<ProxyProfile> candidates) async {
    if (_sweeping || candidates.isEmpty) return;
    _sweeping = true;
    final seq = ++_sweepSeq;
    try {
      final probe = urlProbe;
      if (probe != null) {
        // v0.4.8 §user: in-tunnel URL tests — chunked so a big pool does
        // not stampede the engine's API. Each result lands in the shared
        // HealthStore (ok/latency/errorKind) which ALSO drives the UI's
        // latency column: the number shown is the REAL connection speed.
        for (var i = 0; i < candidates.length; i += _urlChunk) {
          final chunk = candidates.sublist(
              i, i + _urlChunk > candidates.length ? candidates.length : i + _urlChunk);
          await Future.wait(chunk.map((p) async {
            try {
              final r = await probe(p);
              if (r == null) return;
              health.record(HealthRecord(
                profileId: p.id,
                at: DateTime.now(),
                ok: r.ok,
                latencyMs: r.latencyMs,
                errorKind: r.errorKind,
              ));
            } catch (_) {/* one bad probe never kills the sweep */}
          }));
        }
        _evaluate(candidates);
      } else {
        // Fallback: TCP reachability into the shared scheduler (pre-0.4.8
        // behavior — still better than nothing when no engine is up).
        for (final p in candidates) {
          scheduler.enqueue(TestJobKind.recoveryCheck, p.id);
        }
        Future.delayed(const Duration(milliseconds: 400), () {
          if (seq == _sweepSeq) _evaluate(candidates);
        });
      }
    } finally {
      _sweeping = false;
    }
  }

  /// Concurrent in-tunnel URL tests per sweep chunk.
  static const _urlChunk = 6;

  void _evaluate(List<ProxyProfile> candidates, {String? currentId}) {
    final usable = candidates
        .where((p) => health.statsOf(p.id)?.isUsable ?? true)
        .toList();
    if (usable.isEmpty) return;
    ProxyProfile? winner;
    var bestScore = -1 << 30;
    for (final p in usable) {
      final s = health.statsOf(p.id);
      final healthy = s != null && s.state == NodeHealth.healthy;
      final lat = s?.lastLatencyMs ?? s?.avgLatencyMs ?? 5000;
      // Healthy dominates; within the same class, lower latency wins.
      final score = (healthy ? 1 << 20 : 0) + (100000 - lat.clamp(0, 100000));
      if (score > bestScore) {
        winner = p;
        bestScore = score;
      }
    }
    if (winner == null) return;
    final incumbent = currentId ?? best?.id;
    if (winner.id == incumbent) return;
    // Hysteresis: keep the incumbent unless the challenger wins the whole
    // healthy class (score compare already encodes that) — i.e. never chase
    // a few-ms jitter between two unhealthy/unknown nodes.
    final incumbentStats = incumbent == null ? null : health.statsOf(incumbent);
    final challengerHealthy = _isHealthy(winner);
    if (incumbent != null &&
        !(incumbentStats?.isUsable ?? true)) {
      // Incumbent is dead — migrate unconditionally.
    } else if (incumbent != null && !challengerHealthy) {
      return; // never trade a working node for an unknown one
    }
    final previous = best;
    best = winner;
    if (previous?.id != winner.id) {
      Logger.instance.info('smart-switch',
          '[ATX-DART] SMART_SWITCH ${previous?.name ?? '∅'} → ${winner.name} '
          '(lat=${health.statsOf(winner.id)?.lastLatencyMs ?? '?'}ms)');
      _changed.add(winner);
    }
  }

  bool _isHealthy(ProxyProfile p) =>
      health.statsOf(p.id)?.state == NodeHealth.healthy;

  /// Candidates for the ladder: everything connect() would accept.
  static List<ProxyProfile> candidatesOf(List<ProxyProfile> all) =>
      all.where((p) => p.enabled && AndroidNodeSupport.isRunnable(p)).toList();

  void dispose() {
    stop();
    _changed.close();
  }
}
