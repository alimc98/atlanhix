import 'dart:convert';

import '../domain/entities/proxy_profile.dart';

/// v0.4.7 §user — pre-import screening for Xray-only transports and their
/// stream-shape requirements.
///
/// WHY: xhttp and mKCP run ONLY on the Xray core (the sing-box front cannot
/// express them — see `outbound_builders.singBoxOutbound`, which refuses to
/// build them natively). Each also carries optional stream requirements that
/// used to be dropped or silently mis-shaped by the generator:
///   * xhttp — `mode` spellings (the 26.x engine rejects the legacy ones),
///     `extra`/`xmux` JSON objects, `path`/`host`;
///   * mKCP — `headerType`/`header.type` (an http-obfs server NEEDS the
///     header; before the v0.4.6 §xray-fix the generator dropped it) and
///     `seed`.
/// The screener classifies these BEFORE a subscription is imported so the
/// importer can surface real counts (`engines`, `xrayOnly`, `risky`) instead
/// of the user discovering broken nodes at connect time.
///
/// Pure classifier: takes profiles, returns counts — no I/O, no repository.
class LinkScreener {
  const LinkScreener();

  /// Screening bucket for one profile.
  LinkScreenEntry screen(ProxyProfile p) {
    final causes = <String>[];
    final risks = <String>[];

    // ── Xray-exclusive transport? ──
    // The vmess parser maps `type=kcp|mkcp` to Transport.quic (the
    // "UDP family" bucket), so mKCP must ALSO be keyed off the raw param —
    // the same rule CoreManager.needsXrayUpstream applies at runtime.
    final isMkcp = p.rawParams['type'] == 'mkcp' ||
        p.rawParams['type'] == 'kcp' ||
        p.transport == Transport.quic;
    final isXhttp = p.transport == Transport.xhttp;
    final xrayOnly = isXhttp || isMkcp;

    if (isXhttp) {
      causes.add('xhttp runs on the Xray core only');
      final rawMode = _xhttpRawMode(p);
      if (rawMode == null) {
        risks.add('xhttp without an explicit mode — engine defaults apply');
      } else if (_legacyXhttpModes.containsKey(rawMode)) {
        risks.add('xhttp mode "$rawMode" is a legacy spelling the 26.x '
            'engine rejects (use "${_legacyXhttpModes[rawMode]}")');
      }
      if ((p.rawParams['extra'] ?? '').trim().isEmpty &&
          (p.rawParams['xmux'] ?? '').trim().isNotEmpty) {
        risks.add('xhttp carries xmux without an extra JSON object');
      }
      if (p.path == null || p.path!.trim().isEmpty) {
        risks.add('xhttp without a path');
      }
    } else if (isMkcp) {
      causes.add('mKCP runs on the Xray core only');
      final header = _headerType(p);
      if (header == null) {
        risks.add('mKCP without headerType — the engine default '
            '(none) only matches unobfuscated servers');
      } else if (_legacyKcpHeaders.contains(header)) {
        risks.add('mKCP headerType "$header" is not an engine enum');
      }
      if ((p.rawParams['seed'] ?? '').trim().isEmpty) {
        risks.add('mKCP without a seed — the server may require one');
      }
    }

    return LinkScreenEntry(
      engine: xrayOnly ? LinkScreenEngine.xrayOnly : LinkScreenEngine.shared,
      transport: isXhttp
          ? LinkScreenTransport.xhttp
          : (isMkcp ? LinkScreenTransport.mkcp : LinkScreenTransport.other),
      causes: causes,
      risks: risks,
    );
  }

  /// Screening a whole payload: counts + per-cause tallies.
  LinkScreenSummary screenAll(Iterable<ProxyProfile> profiles) {
    var xrayOnly = 0;
    var risky = 0;
    final causeCounts = <String, int>{};
    final perTransport = <LinkScreenTransport, int>{};
    for (final p in profiles) {
      final e = screen(p);
      if (e.engine == LinkScreenEngine.xrayOnly) xrayOnly++;
      if (e.isRisky) risky++;
      perTransport.update(e.transport, (n) => n + 1, ifAbsent: () => 1);
      for (final c in e.risks) {
        causeCounts[c] = (causeCounts[c] ?? 0) + 1;
      }
    }
    return LinkScreenSummary(
      total: perTransport.values.fold(0, (a, b) => a + b),
      xrayOnly: xrayOnly,
      risky: risky,
      causeCounts: Map.unmodifiable(causeCounts),
      perTransport: Map.unmodifiable(perTransport),
    );
  }

  /// The link's xhttp `mode` (flat param or the nested `extra` object),
  /// AS WRITTEN (legacy spellings preserved so the caller can flag them) —
  /// null when the link left it off.
  String? _xhttpRawMode(ProxyProfile p) {
    var mode = p.rawParams['mode'];
    if ((mode == null || mode.trim().isEmpty)) {
      final extra = p.rawParams['extra'];
      if (extra != null && extra.trim().isNotEmpty) {
        try {
          final decoded = jsonDecode(extra);
          if (decoded is Map && decoded['mode'] is String) {
            mode = decoded['mode'] as String;
          }
        } on FormatException {
          // malformed extra — the flat params are the only signal
        }
      }
    }
    return (mode == null || mode.trim().isEmpty) ? null : mode;
  }

  /// `headerType`/`header-type`/clash-style header JSON — null when absent.
  String? _headerType(ProxyProfile p) {
    final raw = p.rawParams['headerType'] ?? p.rawParams['header-type'];
    if (raw != null && raw.trim().isNotEmpty) return raw.trim();
    final hdr = p.rawParams['header'];
    if (hdr == null) return null;
    try {
      final j = jsonDecode(hdr);
      if (j is Map) {
        final t = j['type'] ??
            (j['request'] is Map ? (j['request'] as Map)['type'] : null);
        if (t is String && t.isNotEmpty) return t;
      }
    } on FormatException {
      // malformed header JSON — treat as absent
    }
    return null;
  }

  static const _legacyXhttpModes = <String, String>{
    'packet': 'packet-up',
    'connect': 'stream-one',
  };

  static const _legacyKcpHeaders = <String>{
    'srtp',
    'utp',
    'wechat-video',
    'dtls',
    'wireguard',
  };
}  /// Screening result for ONE profile.
class LinkScreenEntry {
  const LinkScreenEntry({
    required this.engine,
    required this.transport,
    required this.causes,
    this.risks = const [],
  });

  final LinkScreenEngine engine;
  final LinkScreenTransport transport;

  /// Everything worth reporting: the transport notice (for Xray-only nodes)
  /// plus the shape [risks]. Human-readable and redaction-safe — parameter
  /// wording only, never endpoints or credentials.
  final List<String> causes;

  /// Stream-shape risks ONLY (mode/headerType/seed/path classes) — excludes
  /// the inherent "needs the Xray core" notice, so `isRisky` distinguishes
  /// "Xray-only but well-shaped" from "Xray-only and likely broken".
  final List<String> risks;

  bool get isRisky => risks.isNotEmpty;
}

enum LinkScreenEngine {
  /// Runs on BOTH cores (sing-box native).
  shared,

  /// Runs on the Xray core only (xhttp / mKCP).
  xrayOnly,
}

enum LinkScreenTransport { xhttp, mkcp, other }

/// Aggregate of [LinkScreener.screenAll].
class LinkScreenSummary {
  const LinkScreenSummary({
    required this.total,
    required this.xrayOnly,
    required this.risky,
    required this.causeCounts,
    required this.perTransport,
  });

  final int total;
  final int xrayOnly;
  final int risky;
  final Map<String, int> causeCounts;
  final Map<LinkScreenTransport, int> perTransport;

  bool get hasFindings => xrayOnly > 0 || risky > 0;
}
