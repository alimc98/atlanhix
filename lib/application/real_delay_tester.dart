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
  /// Returns null when in-engine testing is unavailable right now.
  Future<int?> Function(ProxyProfile p)? engineDelayTest;

  /// Desktop transient-engine provider (null on Android).
  Future<ProbeResult?> Function(ProxyProfile p)? transientTest;


  String probeUrl = 'https://www.gstatic.com/generate_204';

  /// One node's real delay: ms when the tunnel REALLY fetched the URL,
  /// null otherwise (never a TCP-only number).
  Future<ProbeResult> test(ProxyProfile p) async {
    // 1) Preferred: the running engine measures its own outbound.
    final eng = engineDelayTest;
    if (eng != null) {
      try {
        final ms = await eng(p);
        if (ms != null) return ProbeResult(ok: true, latencyMs: ms);
        return ProbeResult(
            ok: false, latencyMs: null, errorKind: 'timeout',
            detail: 'engine delay test failed');
      } catch (e) {
        Logger.instance.debug('real-delay',
            'engine test ${p.name} failed: ${Logger.redact(e.toString())}');
      }
    }
    // 2) Desktop fallback: transient engine per node.
    final tt = transientTest;
    if (tt != null) {
      try {
        final r = await tt(p);
        if (r != null) return r;
      } catch (e) {
        Logger.instance.debug('real-delay',
            'transient test ${p.name} failed: ${Logger.redact(e.toString())}');
      }
    }
    // 3) No engine available — do NOT fake a TCP result as a delay.
    return ProbeResult(
        ok: false, latencyMs: null, errorKind: 'engine-off',
        detail: 'no running engine to test through');
  }
}
