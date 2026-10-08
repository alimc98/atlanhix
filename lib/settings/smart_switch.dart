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
/// class only decides WHICH node should be active right now.
///
/// v0.5.2 §user — THE PROFESSIONAL SHAPE the user asked for:
///
///   * marginPercent  — "Switch to a faster server only when it is faster
///     by N%" (default 30): the challenger's REAL delay must beat the
///     incumbent's by this PERCENTAGE (plus the legacy ms floor) before
///     the tunnel migrates — jitter-driven ping-pong is dead.
///   * activeRecheck  — "Recheck the server in use every N s" (default 30):
///     one cheap URL test of the ACTIVE node (dead-node detection at
///     30-second granularity, no pool cost).
///   * othersRescan   — "Re-measure the other servers every N min"
///     (default 10): a full REAL-delay batch over the REST of the pool
///     through the live engine (or the transient one when disconnected).
///
/// Pre-connect ladder (v0.5.2): `initialSweep` measures the WHOLE runnable
/// pool with REAL delay tests and recommends the fastest healthy node —
/// VpnSession awaits it at connect time when the switch is ON, so the
/// FIRST connect lands on the lowest-latency config instead of a random
/// health-store guess.
class SmartSwitch {
  SmartSwitch({
    required this.scheduler,
    required this.health,
    required this.interval,
    this.urlProbe,
    this.urlBatchProbe,
    this.marginMs = 0,
    this.marginPercent = 30,
    Duration? activeRecheckInterval,
    Duration? othersRescanInterval,
  })  : activeRecheckInterval =
            activeRecheckInterval ?? const Duration(seconds: 30),
        othersRescanInterval =
            othersRescanInterval ?? const Duration(minutes: 10);

  final TestScheduler scheduler;
  final HealthStore health;

  /// v0.4.8 §user: the REAL criterion — an in-tunnel URL test per
  /// candidate (HTTP GET through the node outbound), not the raw TCP
  /// ping to the node IP. The TCP ping only proves the IP answers; a
  /// config whose tunnel cannot actually fetch the probe URL kept
  /// winning the ladder on a healthy-looking ping. Null (no running
  /// engine / not supported) → falls back to the classic TCP probes.
  final Future<ProbeResult?> Function(ProxyProfile p)? urlProbe;

  /// v0.5.0 §perf-fix: batch provider — id → ProbeResult for the WHOLE pool
  /// in one engine boot + parallel delay tests. Preferred over [urlProbe].
  /// v0.5.2 §user: [onNode] fires once per LANDED measurement (parallel
  /// completion order, not batch order) so the UI can count real progress;
  /// providers that cannot report per-node simply ignore it.
  final Future<Map<String, ProbeResult>> Function(List<ProxyProfile> batch,
      {void Function(ProxyProfile p, int? ms)? onNode})? urlBatchProbe;

  /// Re-test period (legacy composite cadence; the pool rescan rides
  /// [othersRescanInterval] now). Mutated live from Settings.
  Duration interval;

  /// v0.5.2 §user — the % hysteresis: a challenger must beat the incumbent
  /// by ≥ this percentage on the REAL delay (and ≥ [marginMs] absolute as
  /// a floor for very fast nodes) to steal the connection.
  int marginPercent;

  /// v0.5.2 §user — legacy ms floor (Settings field kept working).
  int marginMs;

  /// v0.5.2 §user — active-node recheck cadence (default 30 s).
  Duration activeRecheckInterval;

  /// v0.5.2 §user — other-servers rescan cadence (default 10 min).
  Duration othersRescanInterval;

  Timer? _timer;
  Timer? _activeTimer;
  Timer? _rescanTimer;
  StreamSubscription<HealthRecord>? _resultsSub;
  bool _sweeping = false;
  int _sweepSeq = 0;

  /// Node the switcher currently recommends (may be null while sweeping).
  ProxyProfile? best;

  /// Fired whenever [best] CHANGES (new id) — VpnSession migrates the tunnel.
  final _changed = StreamController<ProxyProfile>.broadcast();
  Stream<ProxyProfile> get changes => _changed.stream;

  /// Fired right after a RESCAN (or the initial sweep) refreshes the pool's
  /// measurements even when the recommendation did NOT change — the node
  /// list's ping column reads this to repaint fresh numbers.
  final _measured = StreamController<void>.broadcast();
  Stream<void> get measured => _measured.stream;

  /// v0.5.2 §user — LIVE per-node ladder progress for the dashboard hero:
  /// start → one event per landed measurement → a finish event that closes
  /// the run (see [LadderProgress]). The latest event is kept and emitted
  /// to every NEW subscriber (a dashboard remounted mid-ladder — the shell
  /// unmounts tabs — resumes the count instead of waiting for node #1).
  final _progress = StreamController<LadderProgress>.broadcast();
  LadderProgress _lastProgress = LadderProgress.idle;
  Stream<LadderProgress> get progress => _progress.stream;

  /// Snapshot form of [progress] for read-once UIs.
  LadderProgress get ladderProgress => _lastProgress;

  /// Ladder-run counter — also DISAMBIGUATES two back-to-back runs with
  /// identical totals (stop→start re-emits nothing to a same-listener
  /// stream otherwise).
  int _ladderId = 0;

  void _reportStart(int total) {
    _lastProgress = LadderProgress._(++_ladderId, 0, total);
    _progress.add(_lastProgress);
  }

  void _reportNode(ProxyProfile p, int? ms) {
    final cur = _lastProgress;
    if (cur.id == LadderProgress.idle.id || cur.isFinish) return;
    _lastProgress = _NodeMeasured(cur.id, cur.done + 1, cur.total,
        ms: ms ?? 0, name: p.name);
    _progress.add(_lastProgress);
  }

  void _reportFinish() {
    final cur = _lastProgress;
    if (cur.id == LadderProgress.idle.id || cur.isFinish) return;
    // The finish keeps the last done/total — never resets to 0/n.
    _lastProgress = LadderProgress._(cur.id | LadderProgress._finishedFlag,
        cur.done, cur.total);
    _progress.add(_lastProgress);
  }

  void start(List<ProxyProfile> candidates, {String? currentId}) {
    stop();
    // v0.5.0 §user-fix (smart switch never switched): seed [best] from the
    // caller's incumbent BEFORE the first sweep finishes.
    if (currentId != null) {
      best = candidates.where((p) => p.id == currentId).firstOrNull;
    }
    _resultsSub = scheduler.results.listen((_) => _evaluate(candidates));
    _sweep(candidates, announce: true);
    _armTimers(candidates);
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _activeTimer?.cancel();
    _activeTimer = null;
    _rescanTimer?.cancel();
    _rescanTimer = null;
    _resultsSub?.cancel();
    _resultsSub = null;
    best = null;
    _sweepSeq++;
    // v0.5.2 §user: a stopped ladder closes its hero progress run —
    // "testing 3/11" must not outlive the sweep that printed it.
    _reportFinish();
  }

  /// Refreshes candidates + all cadences (subscription refresh / settings
  /// change). A no-op while the ladder is not running.
  void reconfigure(List<ProxyProfile> candidates,
      {required Duration newInterval, String? currentId}) {
    interval = newInterval;
    if (_timer == null && _resultsSub == null) return; // not running
    start(candidates, currentId: currentId ?? best?.id);
  }

  void _armTimers(List<ProxyProfile> candidates) {
    _timer?.cancel();
    if (interval.inSeconds > 0) {
      _timer = Timer.periodic(interval, (_) => _sweep(candidates));
    }
    _armActiveRecheck(candidates);
    _armRescan(candidates);
  }

  /// v0.5.2 §user — "Recheck the server in use every N s": one URL test of
  /// the ACTIVE node only. A dead incumbent surfaces to [_evaluate] within
  /// one cycle and is abandoned immediately (the margin never pins the
  /// tunnel to a corpse).
  void _armActiveRecheck(List<ProxyProfile> candidates) {
    _activeTimer?.cancel();
    if (activeRecheckInterval.inSeconds <= 0) return;
    _activeTimer = Timer.periodic(activeRecheckInterval, (_) async {
      final incumbent = best;
      if (incumbent == null || _sweeping) return;
      final probe = urlProbe;
      if (probe == null) return; // engine handles it via scheduler instead
      try {
        final r = await probe(incumbent);
        if (r == null || r.errorKind == 'engine-off') return;
        health.record(HealthRecord(
          profileId: incumbent.id,
          at: DateTime.now(),
          ok: r.ok,
          latencyMs: r.latencyMs,
          errorKind: r.errorKind,
        ));
        _measured.add(null);
        _evaluate(candidates);
      } catch (_) {/* one bad recheck never kills the ladder */}
    });
  }

  /// v0.5.2 §user — "Re-measure the other servers every N min": a full
  /// batch over the REST of the pool (the incumbent is refreshed by the
  /// active recheck on its own cadence).
  void _armRescan(List<ProxyProfile> candidates) {
    _rescanTimer?.cancel();
    if (othersRescanInterval.inMinutes <= 0) return;
    _rescanTimer = Timer.periodic(othersRescanInterval, (_) {
      final incumbent = best;
      _sweep([
        for (final p in candidates)
          if (p.id != incumbent?.id) p,
      ]);
    });
  }

  /// v0.5.2 §user — PRE-CONNECT LADDER: measures the runnable pool with
  /// REAL delay tests (batch provider, one engine boot) and sets [best]
  /// to the fastest healthy node.
  ///
  /// v0.5.5 §user ("تا کانکت رو می‌زنی باید سریع بره روی تست کانفیگ‌ها و
  /// بعد وصل شه"): the ladder used to block the connect until the WHOLE
  /// batch settled (up to 9 s) — the tunnel handshake only started AFTER
  /// the last node answered. Now:
  ///   * [maxWait] defaults to 3.5 s — the connect's TOTAL ladder budget.
  ///     Every measurement still lands in the health store and the armed
  ///     switch keeps optimizing after the tunnel is up (migration);
  ///   * the future returns EARLY the moment a first healthy node exists
  ///     ([earlyPick] channel) — the handshake starts while the rest of
  ///     the pool is still measuring.
  /// The full measurement set always finishes in the background; only the
  /// connect's WAIT is bounded.
  Future<void> initialSweep(
    List<ProxyProfile> candidates, {
    Duration maxWait = const Duration(milliseconds: 3500),
    void Function(ProxyProfile node)? earlyPick,
  }) async {
    // v0.5.2 §user: announced runs feed the hero's live count. If a sweep
    // is ALREADY in flight (resume re-arm racing the connect tap) this
    // call no-ops inside [_sweep] and the in-flight run's own count keeps
    // showing — honest, never a reset-to-zero mid-run.
    final sweep = _sweep(candidates, announce: true);
    if (earlyPick == null) {
      await sweep.timeout(maxWait, onTimeout: () {});
      return;
    }
    // ── Early handover: first healthy node wins the tunnel start. ──
    // The future COMPLETES at the handover — the sweep keeps measuring in
    // the background (hero count, fresh pings, post-connect migration);
    // the caller starts the handshake right away. Three wake sources:
    //   1. a healthy node ALREADY in the store (previous session) — instant,
    //   2. the first landed measurement with a real ms (per-node channel;
    //      health.record only lands AFTER the whole batch, so the fresh
    //      ms IS the health evidence here — ms>0, a failed probe is 0),
    //   3. maxWait — the connect is never held longer than the budget.
    var picked = false;
    void handOver(ProxyProfile p) {
      if (picked) return;
      picked = true;
      earlyPick(p);
    }

    final cached = _bestHealthy(candidates);
    if (cached != null) {
      best ??= cached; // the incumbent for the post-connect hysteresis
      handOver(cached);
      return; // sweep continues unawaited
    }
    final done = Completer<void>();
    late final StreamSubscription<void> sub;
    sub = _progress.stream.listen((e) {
      if (picked || done.isCompleted) return;
      final name = e.lastName;
      final ms = e.lastMs ?? 0;
      if (name == null || e.isFinish || ms <= 0) return;
      for (final p in candidates) {
        if (p.name == name) {
          // Seed the incumbent directly (NOT via _changed — the session's
          // migration path must not fire mid-connect); the post-connect
          // _evaluate then applies its margin logic normally.
          best = p;
          handOver(p);
          if (!done.isCompleted) done.complete();
          break;
        }
      }
    });
    try {
      await Future.any([done.future, sweep.timeout(maxWait)]);
      // Sweep closed (or cap hit) without an early pick: hand over the
      // ladder's conclusion — may be null; the caller then falls back to
      // the health-store pick.
      final b = best;
      if (!picked && b != null) handOver(b);
    } on TimeoutException {
      // The cap fired mid-sweep: leave the sweep running, honor the budget.
    } finally {
      await sub.cancel();
    }
  }

  /// Fastest HEALTHY candidate from the current store, or null.
  ProxyProfile? _bestHealthy(List<ProxyProfile> candidates) {
    ProxyProfile? winner;
    var bestLat = 1 << 30;
    for (final p in candidates) {
      final s = health.statsOf(p.id);
      if (s == null || s.state != NodeHealth.healthy) continue;
      final lat = s.lastLatencyMs ?? s.avgLatencyMs;
      if (lat != null && lat < bestLat) {
        bestLat = lat;
        winner = p;
      }
    }
    return winner;
  }

  Future<void> _sweep(List<ProxyProfile> candidates,
      {bool announce = false}) async {
    if (_sweeping || candidates.isEmpty) return;
    _sweeping = true;
    final seq = ++_sweepSeq;
    // v0.5.2 §user: ladder progress. Only USER-FACING runs (the pre-connect
    // ladder, the connect-time start()) announce — background rechecks and
    // rescans must not flash numbers on the hero.
    final void Function(ProxyProfile p, int? ms)? onNode =
        announce ? _reportNode : null;
    if (announce) _reportStart(candidates.length);
    try {
      final batchProbe = urlBatchProbe;
      final probe = urlProbe;
      if (batchProbe != null) {
        // v0.5.0 §perf-fix: the WHOLE pool in one call — one engine boot,
        // parallel measurements, zero mid-sweep restarts.
        // v0.5.2 §user: the provider reports each landed measurement
        // through [onNode], so the hero counts along with the PARALLEL
        // batch (measured-when-landed, not in candidate order).
        Map<String, ProbeResult> results = const {};
        try {
          results = await batchProbe(candidates, onNode: onNode);
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
        _measured.add(null);
        _evaluate(candidates);
      } else if (probe != null) {
        // v0.4.8 §user: in-tunnel URL tests — chunked so a big pool does
        // not stampede the engine's API.
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
              onNode?.call(p, r.latencyMs);
            } catch (_) {/* one bad probe never kills the sweep */}
          }));
        }
        _measured.add(null);
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
      // v0.5.2 §user: an announced run always closes its progress (a
      // timed-out ladder included); stop() may have closed it earlier —
      // the guard makes the second close a no-op.
      if (announce) _reportFinish();
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
      final score = _score(health.statsOf(p.id));
      if (score > bestScore) {
        winner = p;
        bestScore = score;
      }
    }
    if (winner == null) return;
    final incumbent = best?.id;
    if (winner.id == incumbent) return;

    // ── Hysteresis (v0.5.2 §user): a DEAD/UNUSABLE incumbent is always
    // abandoned; a healthy incumbent is only traded when the challenger is
    // healthy AND beats it by the PERCENT margin on the REAL delay (with
    // the legacy ms value as a floor); an unknown challenger never
    // displaces a working node.
    final incumbentStats =
        incumbent == null ? null : health.statsOf(incumbent);
    final challengerHealthy = _isHealthy(winner);
    if (incumbent != null) {
      // v0.5.2 §fix: an incumbent WITHOUT recorded stats (never probed —
      // e.g. a stale currentId handed to start()) counts as UNKNOWN, not
      // usable: the first sweep must be able to replace it like the dead
      // case. The old `!…isUsable` branch only fired for RECORDED-bad.
      final incumbentUsable = incumbentStats?.isUsable ?? false;
      if (!incumbentUsable) {
        // Incumbent is dead or unmeasured — migrate unconditionally.
      } else if (!challengerHealthy) {
        return; // never trade a working node for an unknown one
      } else {
        final curLat = (incumbentStats!.lastLatencyMs ??
                incumbentStats.avgLatencyMs ??
                5000)
            .clamp(1, 100000);
        final nextLat = (health.statsOf(winner.id)?.lastLatencyMs ??
                health.statsOf(winner.id)?.avgLatencyMs ??
                5000)
            .clamp(1, 100000);
        // "faster by N%": the challenger must clear BOTH gates — the
        // percent bar AND the absolute ms floor (0 disables the floor; a
        // positive floor protects fast nodes: 30% of 40 ms is 12 ms, so a
        // 20 ms floor decides where the percentage is noise).
        final needed = curLat * (1 - marginPercent / 100.0);
        if (nextLat > needed) return; // not enough of a PERCENT lead
        if (marginMs > 0 && (curLat - nextLat) < marginMs) return;
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
          'score=$bestScore, margin=$marginPercent%/$marginMs)');
      _changed.add(winner);
    }
  }

  bool _isHealthy(ProxyProfile p) =>
      health.statsOf(p.id)?.state == NodeHealth.healthy;

  /// v0.5.0 §user-2 — COMPOSITE ranking: latency + jitter + success rate,
  /// healthy-first. See the original design note in v0.5.0 docs; the score
  /// stays the ranking authority while the PERCENT margin governs MIGRATION.
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

  /// Point value of an unmeasured node: strictly below every measured
  /// healthy node.
  static const int _unknownScore = 0;

  /// Candidates for the ladder: everything connect() would accept.
  static List<ProxyProfile> candidatesOf(List<ProxyProfile> all) =>
      all.where((p) => p.enabled && AndroidNodeSupport.isRunnable(p)).toList();

  void dispose() {
    stop();
    _changed.close();
    _measured.close();
    _progress.close();
  }
}

extension _FirstOrNull<E> on Iterable<E> {
  E? get firstOrNull => isEmpty ? null : first;
}

/// v0.5.2 §user — LIVE LADDER PROGRESS: the per-node heartbeat the
/// dashboard hero reads while the pre-connect ladder runs
/// ("testing 5/11… 180 ms" instead of a bare "Connecting…").
///
/// * [done]/[total] — nodes measured so far / in this ladder run. A
///   finish emits the SAME done/total it ended with (never 0/n — a
///   failed sweep must not blank a half-drawn progress).
/// * [lastMs]/[lastName] — the measurement that JUST landed, for the
///   "… 180 ms" suffix. Null on start/finish sentinels.
/// * [id] — monotonic ladder-run id; `int.max` is the UI sentinel for
///   "idle, hide the progress text". `int.min` — "one node just
///   finished" — is private to this library.
class LadderProgress {
  const LadderProgress._(this.id, this.done, this.total,
      {this.lastMs, this.lastName});

  /// Sentinel: no ladder running. id 0 is NEVER a real run id (runs are
  /// counted from 1) — and unlike an all-ones sentinel it keeps the
  /// isFinish bit-arithmetic honest for the idle value.
  static final LadderProgress idle = LadderProgress._(0, 0, 0);
  static const int _finishedFlag = 1 << 62;

  final int id;
  final int done;
  final int total;
  final int? lastMs;
  final String? lastName;

  /// This event closes a run — the next one must NOT continue it.
  bool get isFinish => id & _finishedFlag != 0;

  @override
  String toString() => 'LadderProgress #$id $done/$total'
      '${lastMs == null ? '' : ' ${lastMs}ms'}';
}

/// Internal: the "one node measured" event (kept out of the public API
/// surface — the UI only needs [SmartSwitch.progress]).
class _NodeMeasured extends LadderProgress {
  const _NodeMeasured(super.id, super.done, super.total,
      {required int ms, required String name})
      : super._(lastMs: ms, lastName: name);
}
