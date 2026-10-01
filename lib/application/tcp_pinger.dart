import 'dart:async';
import 'dart:io';

import '../core/logger.dart';
import '../domain/entities/proxy_profile.dart';

/// One node's TCP ping result.
class TcpPingResult {
  const TcpPingResult({required this.ok, this.latencyMs});
  final bool ok;
  final int? latencyMs;
}

/// v0.6.0 §tcping — RAW TCP HANDSHAKE PING (the "پینگ‌ها هنوز بالاست" fix).
///
/// The node list previously showed ONLY real URL delays measured THROUGH
/// each node's live outbound (v0.4.9 design: "a bare TCP ping proves
/// nothing about the tunnel"). True — but every other client (v2rayNG,
/// Hiddify, NekoBox…) shows the TCP handshake time to server:port, and the
/// user reads those numbers as *the* ping. A URL test through a tunnel
/// stacks TCP + TLS + HTTP round-trips on top of the path, so it reads
/// several times higher than the number the user compares against.
///
/// This service measures the RAW TCP connect time to the node endpoint —
/// the same methodology as the other clients — while the existing REAL
/// sweep keeps producing the end-to-end numbers that Smart Switch, the
/// ladder and the health gates consume. Both write into the shared
/// [HealthStore]; the UI column reads `latencyMs ?? handshakeMs`, so a
/// tcping-only node (URL test not yet run / engine off) displays its TCP
/// number, and a node with both shows the REAL delay with tcping as the
/// handshake reference. The TCP result never carries `latencyMs`, so the
/// average/jitter stream and the URL-ladder selection math stay URL-only.
class TcpPinger {
  TcpPinger({this.timeout = const Duration(seconds: 4)});

  final Duration timeout;

  /// One node: TCP connect to server:port (domain resolved by the OS
  /// resolver, exactly like v2rayNG). No engine, no tunnel, no probe URL.
  Future<TcpPingResult> ping(ProxyProfile p) async {
    final sw = Stopwatch()..start();
    Socket? sock;
    try {
      sock = await Socket.connect(p.server, p.port, timeout: timeout);
      sw.stop();
      return TcpPingResult(ok: true, latencyMs: sw.elapsedMilliseconds);
    } on SocketException catch (e) {
      sw.stop();
      Logger.instance.info('tcp-pinger',
          'tcp ping ${p.name} failed after ${sw.elapsedMilliseconds}ms: ${e.message}');
      return const TcpPingResult(ok: false);
    } on TimeoutException {
      return const TcpPingResult(ok: false);
    } finally {
      sock?.destroy();
    }
  }

  /// A whole batch with bounded concurrency (one socket per node — a
  /// 100-node pool must not open 100 simultaneous SYNs on a phone radio).
  Future<Map<String, TcpPingResult>> pingBatch(
    List<ProxyProfile> nodes, {
    int concurrency = 8,
  }) async {
    final out = <String, TcpPingResult>{};
    var next = 0;
    Future<void> worker() async {
      while (next < nodes.length) {
        final p = nodes[next++];
        out[p.id] = await ping(p);
      }
    }

    await Future.wait(
        List.generate(concurrency.clamp(1, nodes.length), (_) => worker()));
    return out;
  }
}
