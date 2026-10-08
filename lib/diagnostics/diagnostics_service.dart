import 'dart:convert';
import 'dart:io';

import '../core/health/latency_tester.dart';
import '../core/logger.dart';
import '../core/runtime/core_manager.dart';
import '../core/runtime/core_runtime.dart';
import '../domain/entities/proxy_profile.dart';
import '../routing/routing_models.dart';

/// v0.3.0 §19 — real diagnostics subsystem.
///
/// Collects ONLY verifiable runtime facts: effective core, engine states,
/// real PIDs, binary versions, local ports, DNS/routing configuration,
/// startup duration, readiness, a fresh end-to-end probe, the last engine
/// exit reason, recent log lines, real traffic counters and platform facts.
/// Nothing is invented: every field is null/unavailable when its source is
/// not running. Secrets (uuids, passwords, keys) never enter the report —
/// log lines are redacted by the Logger itself.
///
/// v0.4.6: the probe section gained a LAYERED failure breakdown so the
/// report says WHERE the tunnel breaks (dns → tcp → tls → proxy → http —
/// the outermost layer that answered is the failing one) SIDE BY SIDE with
/// the active engine's redacted stderr tail (WHY the engine thinks so).
class DiagnosticsService {
  DiagnosticsService({
    required this.cores,
    required this.routing,
    required this.dns,
    this.testUrl = 'https://www.gstatic.com/generate_204',
  });

  final CoreManager cores;
  final RoutingProfile routing;
  final DnsSettings dns;
  final String testUrl;

  /// Collects the full report. [probe] performs a live HTTP probe through
  /// the front engine (the authoritative readiness check).
  Future<Map<String, dynamic>> collect({bool probe = true}) async {
    final sb = cores.front;
    final active = cores.activeProfile;

    final readiness = sb.status == RuntimeStatus.running
        ? await sb.inboundHealthy()
        : null;

    ProbeResult? probeResult;
    Map<String, dynamic>? layers;
    if (probe && sb.status == RuntimeStatus.running) {
      probeResult = await LatencyTester().testHttpViaSocksProxy(
        '127.0.0.1',
        sb.mixedPort,
        testUrl,
        timeout: const Duration(seconds: 8),
      );
      layers = await _layeredBreakdown();
    }

    return {
      'generatedAt': DateTime.now().toUtc().toIso8601String(),
      'platform': {
        'os': Platform.operatingSystem,
        'osVersion': Platform.operatingSystemVersion,
        'locale': Platform.localeName,
        'cores': Platform.numberOfProcessors,
      },
      'profile': active == null
          ? null
          : {
              'id': active.id,
              'name': active.name,
              'protocol': active.protocol.name,
              'transport': active.transport.name,
              'security': active.security.name,
              // effective core AFTER detector/pin resolution (§12)
              'effectiveCore': active.effectiveCore.name,
            },
      'engines': {
        'singbox': _engineSection(sb),
        'xray': _engineSection(cores.xray),
        'masterDnsVpn': _engineSection(cores.masterDnsVpn),
        'stormDns': _engineSection(cores.stormDns),
        'amneziaWg': _engineSection(cores.amneziaWg),
      },
      'ports': {
        'mixedInbound':
            sb.status == RuntimeStatus.running ? sb.mixedPort : null,
        'xraySocks': cores.xray.status == RuntimeStatus.running
            ? cores.xray.localPort
            : null,
        'mdvpnSocks': cores.masterDnsVpn.status == RuntimeStatus.running
            ? cores.masterDnsVpn.socksPort
            : null,
        'stormSocks': cores.stormDns.status == RuntimeStatus.running
            ? cores.stormDns.socksPort
            : null,
      },
      'dns': dns.toJson(),
      'routing': {
        'name': routing.name,
        'isBuiltin': routing.isBuiltin,
      },
      'startup': {'lastStartMs': cores.lastStartupMs},
      'readiness': {'inboundHealthy': readiness},
      'probe': probeResult == null
          ? (sb.status == RuntimeStatus.running
              ? null
              : 'skipped — engine not running')
          : {
              'ok': probeResult.ok,
              'latencyMs': probeResult.latencyMs,
              'errorKind': probeResult.errorKind,
              // no raw detail: error text could carry URLs/tokens
            },
      // v0.4.6: WHERE does the tunnel break? Layered probes alongside the
      // active engine's redacted stderr tail — one look answers both
      // "which layer" (outermost layer that answered = failing layer)
      // and "why" (what the engine actually logged).
      'failureAnalysis': layers == null
          ? null
          : {
              ...layers,
              'activeEngine': active?.effectiveCore.name,
              'engineTail': _engineTail(active),
            },
      'lastExit': cores.front.lastExit == null
          ? null
          : {
              'kind': cores.front.lastExit!.kind.name,
              'exitCode': cores.front.lastExit!.exitCode,
              'uptimeSec': cores.front.lastExit!.uptime.inSeconds,
            },
      'traffic': sb.traffic == null
          ? null
          : {
              'upBytes': sb.traffic!.upBytes,
              'downBytes': sb.traffic!.downBytes,
            },
      'recentLogs': _recentLogs(),
      'networkInterfaces': await _interfaces(),
    };
  }

  Map<String, dynamic> _engineSection(CoreRuntime rt) => {
        'status': rt.status.name,
        'pid': rt.lastPid,
      };

  /// v0.4.6 — WHERE does the tunnel break? Probes the chain layer by layer
  /// with the SAME layered tester the health engine uses:
  ///   dns → tcp(node:443) → tls(node:443) → http-through-proxy(tunnel).
  /// The outermost layer that ANSWERED is where the path stops working:
  ///   * dns fails  → resolver problem (carrier poison / no network);
  ///   * tcp fails  → server down, wrong port, ISP reset;
  ///   * tls fails  → SNI/cert/Reality mismatch, fingerprint blocked;
  ///   * all pass + proxy probe failed → protocol/auth problem INSIDE the
  ///     tunnel (engine logs are authoritative — see engineTail).
  /// [ProxyProtocol.hysteria2]/[tuic] speak UDP/QUIC: plain TCP to :443
  /// answers nothing even on a healthy node — the tcp/tls verdicts are
  /// then reported as 'n/a (UDP transport)' instead of a false failure.
  Future<Map<String, dynamic>> _layeredBreakdown() async {
    final active = cores.activeProfile;
    final tester = LatencyTester();
    final udpTransport = active != null &&
        (active.protocol == ProxyProtocol.hysteria2 ||
            active.protocol == ProxyProtocol.hysteria ||
            active.protocol == ProxyProtocol.tuic);

    final tcp = (active == null || udpTransport)
        ? null
        : await tester.testTcp(active.server, active.port);
    final tls = (tcp == null || !tcp.ok || udpTransport)
        ? null
        : await tester.testTls(active!.server, active.port);

    String? verdict(ProbeResult? r, String label) {
      if (r == null) return udpTransport ? 'n/a (UDP transport)' : 'skipped';
      if (r.ok) return 'ok (${r.latencyMs ?? r.handshakeMs ?? '?'}ms)';
      // redact: socket error text could embed URLs/credentials — the report
      // must stay copy-paste safe (same discipline as Logger).
      return 'FAIL — ${Logger.redact(label)}';
    }

    final dnsOk = tcp == null ? null : tcp.errorKind != 'dns';
    String failingLayer;
    if (udpTransport) {
      failingLayer = 'proxy'; // TCP/TLS probes cannot judge UDP transports
    } else if (tcp != null && !tcp.ok) {
      failingLayer = tcp.errorKind == 'dns' ? 'dns' : 'tcp';
    } else if (tls != null && !tls.ok) {
      failingLayer = 'tls';
    } else {
      failingLayer = 'proxy'; // innermost: protocol/auth inside the tunnel
    }

    return {
      'failingLayer': failingLayer,
      'dns': dnsOk == null ? null : (dnsOk ? 'reachable' : 'FAIL — resolver'),
      'tcp': verdict(tcp, tcp?.detail ?? 'no TCP answer'),
      'tls': verdict(tls, tls?.detail ?? 'handshake failed'),
      // note: dns/tcp/tls target the NODE endpoint directly from the host;
      // the tunnel probe itself lives in the 'probe' section above.
    };
  }

  /// Redacted stderr tail of the ACTIVE engine (xray for upstream nodes,
  /// sing-box otherwise) — the WHY next to the layer verdicts. Empty when
  /// nothing has been logged; never throws when no engine has run.
  String _engineTail(ProxyProfile? active) {
    if (active == null) return '';
    final engine = active.effectiveCore == CoreKind.xray
        ? CoreKind.xray
        : CoreKind.singbox;
    return cores.engineStderrTail(engine);
  }

  List<String> _recentLogs() {
    final buf = Logger.instance.buffer;
    final from = buf.length > 40 ? buf.length - 40 : 0;
    return buf.skip(from).map((l) {
      final ts = l.at.toIso8601String().substring(11, 19);
      return '$ts [${l.level.name}] ${l.scope}: ${l.message}';
    }).toList();
  }

  Future<List<String>> _interfaces() async {
    try {
      final list = await NetworkInterface.list();
      return list
          .map((i) => '${i.name}: ${i.addresses.map((a) => a.address).join(', ')}')
          .toList();
    } catch (_) {
      return const ['unavailable'];
    }
  }

  /// Human-readable render (log-safe, secret-free).
  static String renderText(Map<String, dynamic> r) {
    final b = StringBuffer('Atlanhix diagnostics report\n');
    void section(String title, Map<String, dynamic>? m) {
      b.writeln('— $title');
      if (m == null || m.isEmpty) {
        b.writeln('  (none)');
        return;
      }
      m.forEach((k, v) => b.writeln('  $k: ${v ?? 'unavailable'}'));
    }

    b.writeln('generated: ${r['generatedAt']}');
    section('platform', r['platform'] as Map<String, dynamic>?);
    section('active profile', r['profile'] as Map<String, dynamic>?);
    final engines = r['engines'] as Map<String, dynamic>;
    for (final e in engines.entries) {
      final v = e.value as Map;
      b.writeln('— engine ${e.key}: ${v['status']}'
          ' pid=${v['pid'] ?? 'n/a'}');
    }
    section('ports', r['ports'] as Map<String, dynamic>?);
    section('dns', r['dns'] as Map<String, dynamic>?);
    section('routing', r['routing'] as Map<String, dynamic>?);
    section('startup', r['startup'] as Map<String, dynamic>?);
    section('readiness', r['readiness'] as Map<String, dynamic>?);
    b.writeln('— probe: ${jsonEncode(r['probe'])}');
    final fa = r['failureAnalysis'] as Map<String, dynamic>?;
    if (fa != null) {
      b.writeln('— failure analysis (layered)');
      b.writeln('  failingLayer: ${fa['failingLayer']}');
      b.writeln('  dns: ${fa['dns'] ?? 'skipped'}');
      b.writeln('  tcp: ${fa['tcp'] ?? 'skipped'}');
      b.writeln('  tls: ${fa['tls'] ?? 'skipped'}');
      b.writeln('  activeEngine: ${fa['activeEngine'] ?? 'n/a'}');
      final tail = (fa['engineTail'] as String?) ?? '';
      b.writeln(tail.isEmpty
          ? '  engineTail: (no engine output)'
          : '  engineTail: $tail');
    }
    section('last engine exit', r['lastExit'] as Map<String, dynamic>?);
    section('traffic counters', r['traffic'] as Map<String, dynamic>?);
    b.writeln('— network interfaces:');
    for (final i in r['networkInterfaces'] as List) {
      b.writeln('  $i');
    }
    b.writeln('— recent logs (last 40, redacted):');
    for (final l in r['recentLogs'] as List) {
      b.writeln('  $l');
    }
    return b.toString();
  }
}
