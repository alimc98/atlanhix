import 'dart:async';
import 'dart:math' show sqrt;

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
///   * ranking    = health-store COMPOSITE score (v0.5.0 §user-2):
///                  healthy first, then latency (0–1000) + success rate
///                  (0–500) + jitter (0–200) — a steady node beats a
///                  spiky one at the same nominal latency
///   * hysteresis = a switch only happens when the challenger beats the
///                  incumbent by a real margin ([marginMs] on the same
///                  composite score, never ping-pongs on noise) — the
///                  margin is a user-settable field, not a hard-coded win
///   * cadence    = `AppSettings.smartSwitchIntervalSeconds` (0 = at
///                  connect-time only)
class SmartSwitch {
  SmartSwitch({
    required this.scheduler,
    required this.health,
    required this.interval,
    this.urlProbe,
    this.urlBatchProbe,
    this.marginMs = 0,
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
  ///
  /// v0.5.0 §perf-fix: prefer [urlBatchProbe] — the WHOLE candidate pool in
  /// ONE call. The per-node [urlProbe] remains supported (used only when no
  /// batch provider is wired) but a per-node probe re-entered the transient
  /// engine per candidate: every new node id REBUILT the probe Box and all
  /// parallel measurements died mid-sweep — the switch "never worked" and
  /// the pings took forever.
  final Future<ProbeResult?> Function(ProxyProfile p)? urlProbe;

  /// v0.5.0 §perf-fix: batch provider — id → ProbeResult for the WHOLE pool
  /// in one engine boot + parallel delay tests. Preferred over [urlProbe].
  final Future<Map<String, ProbeResult>> Function(List<ProxyProfile> batch)?
      urlBatchProbe;

  /// Re-test period. Mutated live from Settings (0 disables the loop).
  Duration interval;

  /// v0.5.0 §user — the tolerance the user asked for: a challenger must
  /// beat the incumbent by at least THIS much on the COMPOSITE ranking
  /// score (v0.5.0 §user-2: latency + jitter + success rate) to steal the
  /// connection. The scale stays latency-shaped, so the field keeps its
  /// "milliseconds better" intuition — but a steadier challenger (less
  /// jitter / higher success rate) can now clear the bar with a smaller
  /// latency lead. 0 = any strictly-better healthy challenger wins.
  /// Raised from Settings (Smart Switch tolerance field) it stops
  /// jitter-driven ping-pong on pools of similar nodes; a dead incumbent
  /// is ALWAYS migrated regardless of the margin.
  int marginMs;

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
    // v0.5.0 §user-fix (smart switch never switched): seed [best] from the
    // caller's incumbent BEFORE the first sweep finishes. The old code left
    // [best] null for the whole first sweep, so `_evaluate` compared its
    // fresh winner against the STALE `currentId` parameter and silently
    // re-elected the dead incumbent as "no change" — the card showed ON,
    // the log said SMART_SWITCH ∅ → X, and the tunnel never moved.
    if (currentId != null) {
      best = candidates.where((p) => p.id == currentId).firstOrNull;
    }
    _resultsSub = scheduler.results.listen((_) => _evaluate(candidates));
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
  void reconfigure(List<ProxyProfile> candidates,
      {required Duration newInterval, String? currentId}) {
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
      final batchProbe = urlBatchProbe;
      final probe = urlProbe;
      if (batchProbe != null) {
        // v0.5.0 §perf-fix: the WHOLE pool in one call — one engine boot,
        // parallel measurements, zero mid-sweep restarts.
        Map<String, ProbeResult> results = const {};
        try {
          results = await batchProbe(candidates);
        } catch (_) {/* a dead provider never kills the sweep */}
        final now = DateTime.now();
        for (final p in candidates) {
          final r = results[p.id];
          if (r == null || r.errorKind == 'engine-off') continue;
          health.record(HealthRecord(
            profileId: p.id,
            at: now,
            ok: r.ok,
            latencyMs: r.latencyMs,
            errorKind: r.errorKind,
          ));
        }
        _evaluate(candidates);
      } else if (probe != null) {
        // v0.4.8 §user: in-tunnel URL tests — chunked so a big pool does
        // not stampede the engine's API. Each result lands in the shared
        // HealthStore (ok/latency/errorKind) which ALSO drives the UI's
        // latency column: the number shown is the REAL connection speed.
        for (var i = 0; i < candidates.length; i += _urlChunk) {
          final chunk = candidates.sublist(i,
              i + _urlChunk > candidates.length ? candidates.length : i + _urlChunk);
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

  void _evaluate(List<ProxyProfile> candidates) {
    final usable = candidates
        .where((p) => health.statsOf(p.id)?.isUsable ?? true)
        .toList();
    if (usable.isEmpty) return;
    ProxyProfile? winner;
    var bestScore = -1 << 30;
    for (final p in usable) {
      // v0.5.0 §user-2: COMPOSITE ranking — latency + jitter + success
      // rate, healthy-first. See [_score].
      final score = _score(health.statsOf(p.id));
      if (score > bestScore) {
        winner = p;
        bestScore = score;
      }
    }
    if (winner == null) return;
    final incumbent = best?.id;
    if (winner.id == incumbent) return;

    // v0.5.0 §user — hysteresis with a REAL tolerance field:
    //   * a DEAD/UNUSABLE incumbent is always abandoned (the margin must
    //     never pin the tunnel to a node that cannot carry traffic);
    //   * a healthy incumbent is only traded when the challenger is itself
    //     healthy AND beats it by [marginMs] (0 = pure score comparison —
    //     the challenger must win the whole healthy class);
    //   * an unknown challenger never displaces a working node.
    final incumbentStats = incumbent == null ? null : health.statsOf(incumbent);
    final challengerHealthy = _isHealthy(winner);
    if (incumbent != null) {
      if (!(incumbentStats?.isUsable ?? true)) {
        // Incumbent is dead — migrate unconditionally.
      } else if (!challengerHealthy) {
        return; // never trade a working node for an unknown one
      } else {
        // v0.5.0 §user-2: the margin rides the COMPOSITE score now — a
        // challenger with less jitter and a better success rate needs a
        // smaller latency lead to win, because its score genuinely is
        // higher. (The legacy field keeps a latency-shaped intuition:
        // score margins land in the same order of magnitude as ms —
        // composite [pts] = incumbent [pts] + [marginMs] → migrate.)
        final cur = _score(incumbentStats);
        final next = _score(health.statsOf(winner.id));
        if (next <= cur + marginMs) return; // not enough of a margin
      }
    }
    final previous = best;
    best = winner;
    if (previous?.id != winner.id) {
      final ws = health.statsOf(winner.id);
      Logger.instance.info('smart-switch',
          '[ATX-DART] SMART_SWITCH ${previous?.name ?? '∅'} → ${winner.name} '
          '(lat=${ws?.lastLatencyMs ?? '?'}ms, jit=${ws?.jitterMs ?? '?'}ms, '
          'ok=${((ws?.successRate ?? 0) * 100).round()}%, '
          'score=$bestScore, margin=$marginMs)');
      _changed.add(winner);
    }
  }

  bool _isHealthy(ProxyProfile p) =>
      health.statsOf(p.id)?.state == NodeHealth.healthy;

  /// v0.5.0 §user-2 — COMPOSITE ranking: latency + jitter + success rate,
  /// healthy-first.
  ///
  /// The old score was latency-only. Three user-visible pathologies came
  /// from that: a fast-but-flaky node outranked a slower rock-solid one
  /// (jitter invisible), a node with a lucky 100 ms sample but a 40%
  /// success rate kept winning (failure history invisible), and every
  /// margin decision was a raw ms race. The composite fixes all three:
  ///
  ///   * latency (0–1000 pts): [NodeHealthStats.lastLatencyMs], falling back
  ///     to avg and then the 5000 ms dead-worthless baseline — linear over
  ///     1 s, i.e. the same ordering the old score had;
  ///   * jitter (0–200 pts): HealthStore stores the recent VARIANCE (ms²)
  ///     over the last ≤5 samples — the score consumes its SQUARE ROOT
  ///     (stdDev, ms) so the penalty stays latency-comparable: 100±80 ms
  ///     loses 80 pts, 100±20 ms loses 20. A node with NO history yet
  ///     (fewer than 2 samples) scores the NEUTRAL middle (100) — never a
  ///     phantom perfect-stability bonus over a measured-steady rival.
  ///   * success rate (0–500 pts): share of OK probes in the recent
  ///     20-sample window — a 60%-up node can never outrank a 100%-up one.
  ///
  /// Ordering note: on the SAME health class the latency block spans
  /// ±1000 while jitter+success contribute 0–700, so the composite never
  /// elevates an unknown (latency 5000 → ~0 pts) over a measured fast
  /// node — the healthy-dominance and known-better-than-unknown
  /// invariants of the legacy score are preserved. The scale is
  /// milliseconds-compatible ON PURPOSE: [marginMs] (the user's "Smart
  /// Switch tolerance" field) keeps its latency-only intuition — a 60 ms
  /// margin demand means "be ~60 ms better OR noticeably steadier".
  static int _score(NodeHealthStats? s) {
    if (s == null) return _unknownScore;
    final healthy = s.state == NodeHealth.healthy ? 1 << 20 : 0;
    final lat = (s.lastLatencyMs ?? s.avgLatencyMs ?? 5000).clamp(0, 100000);
    final latPts = (1000 - (lat / 1000) * 1000).clamp(0, 1000).round();
    // jitterMs is a VARIANCE (ms²) — consume its square root so the
    // penalty is linear in stdDev (ms) and stays latency-comparable.
    final stdDev = s.jitterMs == null ? null : sqrt(s.jitterMs!);
    final jitPts =
        stdDev == null ? 100 : (200 - stdDev.clamp(0.0, 200.0)).round();
    final okPts = ((s.successRate.clamp(0, 1)) * 500).round();
    return healthy + latPts + jitPts + okPts;
  }

  /// Point value of an unmeasured node: latency falls back to 5000 ms
  /// (0/1000 pts), no jitter/success history (0/700 pts), unknown class —
  /// strictly below every measured healthy node, matching the legacy
  /// behavior of `_evaluate`.
  static const int _unknownScore = 0;

  /// Candidates for the ladder: everything connect() would accept.
  static List<ProxyProfile> candidatesOf(List<ProxyProfile> all) =>
      all.where((p) => p.enabled && AndroidNodeSupport.isRunnable(p)).toList();

  void dispose() {
    stop();
    _changed.close();
  }
}

extension _FirstOrNull<E> on Iterable<E> {
  E? get firstOrNull => isEmpty ? null : first;
}
