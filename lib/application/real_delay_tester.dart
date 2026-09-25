import '../../core/health/latency_tester.dart';
import '../../core/logger.dart';
import '../../domain/entities/proxy_profile.dart';

/// v0.4.9 §user — REAL delay test for the node list ("real delay url test …
/// ببین اصلا این کانفیگ وصل میشه یا نه").
///
/// The classic scheduler probe is a TCP connect to the node's IP — a 50ms
/// answer proves nothing about the TUNNEL (an Iran-internal tunnel IP pings
/// fast and still cannot fetch anything through the proxy). This service
/// measures the END-TO-END delay: HTTP GET of the probe URL THROUGH the
/// node's actual outbound. Two mechanisms, chosen per environment:
///
///  1. **In-engine** (Android + desktop while the front sing-box runs):
///     the front config carries the WHOLE runnable pool as selector
///     members (v0.4.8 Smart-Switch change), so every node tag is live in
///     the engine and the Clash-API delay test measures the real path
///     node → internet. Zero restarts, parallelizable.
///  2. **Transient desktop engine**: no running engine → (desktop only)
///     each candidate gets a temp sing-box process (mixed inbound +
///     single outbound), one HTTP fetch through it, process killed. Slow
///     but genuinely real. On Android this mechanism is unavailable —
///     nodes are reported "engine off" instead of faking a number.
///
/// Results land in the shared [HealthStore] via the caller, so the UI
/// latency column, Smart Switch and the ladder all see the same truth.
class RealDelayTester {
  RealDelayTester({required this.tester});

  final LatencyTester tester;

  /// The provider decides how to reach a node's live outbound tag.
  /// Contract: returns a FULL [ProbeResult] when the running engine
  /// actually measured the node (ok **or** timeout — both are real
  /// measurements); returns null ONLY when no engine is available right
  /// now (caller falls through to the next mechanism / 'engine-off').
  Future<ProbeResult?> Function(ProxyProfile p)? engineDelayTest;

  /// Desktop transient-engine provider (null on Android).
  Future<ProbeResult?> Function(ProxyProfile p)? transientTest;

  /// v0.4.9 §user: TRANSIENT in-app engine provider (Android). When no VPN
  /// is connected, the probe engine boots a consent-free libbox instance
  /// carrying the candidate nodes and measures the REAL URL delay through
  /// it — "test all nodes" works right after a fresh app open now.
  Future<Map<String, ProbeResult>> Function(List<ProxyProfile> batch)?
      transientBatchTest;


  String probeUrl = 'https://www.gstatic.com/generate_204';

  /// One node's real delay: ms when the tunnel REALLY fetched the URL,
  /// null otherwise (never a TCP-only number).
  Future<ProbeResult> test(ProxyProfile p) async {
    final r = await testBatch([p]);
    return r[p.id] ??
        ProbeResult(
            ok: false,
            latencyMs: null,
            errorKind: 'engine-off',
            detail: 'no engine to test through');
  }

  /// Batch of nodes through ONE mechanism decision — the sweep's entry
  /// point. Order: the live engine (when a VPN is connected) measures its
  /// own pool; otherwise the transient probe engine boots with the batch
  /// and every node is measured for real. Falls back per-node to [test]
  /// semantics when no batch mechanism is available.
  Future<Map<String, ProbeResult>> testBatch(List<ProxyProfile> nodes) async {
    if (nodes.isEmpty) return {};
    // 1) Live engine, when it is up. v0.4.9 §user-fix: probe the FIRST
       // node merely as an engine-liveness test; if the live engine is up
    // but does NOT contain some of the batch (filtered pool / Xray stubs
    // without a listener), only those nodes fall through to the transient
    // engine — the reachable ones still keep their REAL live measurements
    // (a full-batch fall-through used to overwrite them with timeouts).
    final eng = engineDelayTest;
    if (eng != null) {
      try {
        final probe = await eng(nodes.first);
        if (probe != null) {
          final out = <String, ProbeResult>{};
          for (final n in nodes) {
            final r = await _viaEngine(eng, n);
            out[n.id] = r;
          }
          // v0.4.9 §testall-fix: 'engine-off' from the LIVE engine used to
          // re-enter the transient probe with a DIFFERENT node set — which
          // RESTARTED the probe Box under this very sweep (device log:
          // two "probe engine UP" lines one second apart) and killed every
          // in-flight delay test, painting the whole list ×. The growth
          // decision belongs INSIDE the probe engine (union grow, never a
          // restart under a running sweep); here the overflow is answered
          // honestly instead.
          return out;
          // probe == null → engine off; fall through to the probe engine.
        }
      } catch (_) {
        // fall through to the transient engine
      }
    }
    // 2) Transient in-app engine (Android) / desktop transient process.
    final batch = transientBatchTest;
    if (batch != null) {
      try {
        final out = await batch(nodes);
        if (out.isNotEmpty) return out;
      } catch (e) {
        Logger.instance.debug('real-delay',
            'transient batch failed: ${Logger.redact(e.toString())}');
      }
    }
    // 3) Nothing measured — honest engine-off for every node.
    return {
      for (final n in nodes)
        n.id: ProbeResult(
            ok: false,
            latencyMs: null,
            errorKind: 'engine-off',
            detail: 'no running engine to test through'),
    };
  }

  Future<ProbeResult> _viaEngine(
    Future<ProbeResult?> Function(ProxyProfile p) eng,
    ProxyProfile p,
  ) async {
    try {
      final r = await eng(p);
      if (r != null) {
        Logger.instance.info('real-delay',
            '${p.name}: ${r.ok ? '${r.latencyMs}ms' : r.errorKind}');
        return r;
      }
    } catch (e) {
      Logger.instance.debug('real-delay',
          'engine test ${p.name} failed: ${Logger.redact(e.toString())}');
    }
    return ProbeResult(
        ok: false,
        latencyMs: null,
        errorKind: 'engine-off',
        detail: 'engine dropped mid-sweep');
  }
}
