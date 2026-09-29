import 'dart:convert' show jsonDecode, jsonEncode;

import '../../domain/entities/proxy_profile.dart';
import '../../routing/routing_models.dart';

/// v0.5.3 — MIHOMO (Clash.Meta) CONFIG GENERATOR.
///
/// Translates Atlanhix [ProxyProfile]s into a mihomo config (JSON — mihomo
/// accepts JSON as YAML 1.2, and `-t` validates either spelling). The engine
/// runs as the THIRD STANDALONE core: it owns the proxying end-to-end (no
/// sing-box front, no :xray child) and serves mihomo's native Clash API —
/// the SAME API the app's SmartSwitch/RealDelayTester already speaks.
///
/// WHY A TRANSLATOR AT ALL: mihomo never sees share-URIs — its input is the
/// Clash proxy schema. Every advanced Xray link parameter the user imports
/// (`extra=<json>`, `xmux=`, padding spellings, `mode=packet`…) must be
/// translated into `xhttp-opts` fields HERE; that mapping is the whole
/// reason nodes "worked in v2rayNG but not in FlClash". Verified against
/// wiki.metacubex.one transport docs (2026-09): xhttp-opts carries mode,
/// x-padding-*, session-*, seq-*, uplink-*, reuse-settings (XMUX) and
/// download-settings.
class MihomoConfigGenerator {
  MihomoConfigGenerator({
    this.mixedPort = 2080,
    this.clashApiPort = '9097',
    this.clashSecret = '',
  });

  /// Convenience for callers that think in ints (the runtime's apiPort).
  /// Keeps `MihomoConfigGenerator(mixedPort: 2081, apiPort: 9099)` working.
  factory MihomoConfigGenerator.ports({required int mixedPort, required int apiPort, String secret = ''}) =>
      MihomoConfigGenerator(
          mixedPort: mixedPort, clashApiPort: '$apiPort', clashSecret: secret);

  /// Mixed (HTTP+SOCKS) listen port — desktop. Android child-process mode
  /// reuses the same config with `tun.enable=false` and this port only.
  final int mixedPort;
  final String clashApiPort;
  final String clashSecret;

  /// Build the FULL mihomo config for [profiles] with [selectedId] active.
  Map<String, dynamic> build({
    required List<ProxyProfile> profiles,
    required String selectedId,
    required RoutingProfile routing,
    required DnsSettings dns,
  }) {
    final proxies = <Map<String, dynamic>>[];
    for (final p in profiles) {
      final mp = proxyOf(p);
      if (mp != null) proxies.add(mp);
    }
    final names = [for (final pr in proxies) pr['name'] as String];
    return {
      // ── Inbounds: one mixed listener (HTTP+SOCKS). TUN is NOT enabled in
      // the child-process topology — the front tunnel (libbox) owns the TUN;
      // mihomo serves as the dial-out engine. A future standalone-desktop
      // TUN build flips enable + the platform specifics.
      'mixed-port': mixedPort,
      'allow-lan': false,
      'mode': 'rule',
      'log-level': 'info',
      'ipv6': false,
      // ── External controller: the app's RealDelayTester/SmartSwitch/
      // migration path talk THIS dialect already (ClashApiClient).
      'external-controller': '127.0.0.1:$clashApiPort',
      if (clashSecret.isNotEmpty) 'secret': clashSecret,
      // ── DNS: engine-internal resolvers; the app's bootstrap pin stays
      // responsible for resolving the NODE hostname before this config is
      // written (same discipline as the :xray child).
      'dns': {
        'enable': true,
        'listen': '127.0.0.1:10553',
        'default-nameserver': ['8.8.8.8', '1.1.1.1'],
        'nameserver': ['https://1.1.1.1/dns-query', 'https://8.8.8.8/dns-query'],
      },
      'proxies': proxies,
      'proxy-groups': [
        {
          'name': 'ATX',
          'type': 'select',
          'proxies': ['ATX-AUTO', ...names],
        },
        if (names.isNotEmpty)
          {
            // url-test group = the ladder INSIDE mihomo. The app's own
            // SmartSwitch still drives migration via the selector (ATX);
            // this group is the standalone-mode fallback.
            'name': 'ATX-AUTO',
            'type': 'url-test',
            'proxies': names,
            'url': 'https://www.gstatic.com/generate_204',
            'interval': 300,
            'tolerance': 80,
          },
      ],
      'rules': [
        ..._routingRules(routing),
        'MATCH,ATX',
      ],
    };
  }

  /// Serialize + pretty-print for the engine's `-f` file.
  String encode(Map<String, dynamic> cfg) => jsonEncode(cfg);

  // ─────────────────────────────────────────────────────────────────────
  // PROXY TRANSLATION
  // ─────────────────────────────────────────────────────────────────────

  /// One [ProxyProfile] → one mihomo proxy map (null = unsupported here —
  /// the engine-gate upstream already filtered; this is defense in depth).
  Map<String, dynamic>? proxyOf(ProxyProfile p) => switch (p.protocol) {
        ProxyProtocol.vless => _vless(p),
        ProxyProtocol.vmess => _vmess(p),
        ProxyProtocol.trojan => _trojan(p),
        ProxyProtocol.shadowsocks => _ss(p),
        _ => null,
      };

  Map<String, dynamic>? _vless(ProxyProfile p) {
    final tls = p.security == Security.tls || p.security == Security.reality;
    return {
      'name': p.name,
      'type': 'vless',
      'server': p.server,
      'port': p.port,
      'uuid': p.uuid,
      'udp': true,
      if (tls) 'tls': true,
      if (p.security == Security.reality) ...{
        'reality-opts': {
          'public-key': p.realityPublicKey,
          'short-id': p.realityShortId,
        },
      },
      if ((p.flow ?? '').isNotEmpty) 'flow': p.flow,
      'servername': p.sni ?? p.host ?? p.server,
      if ((p.fingerprint ?? '').isNotEmpty) 'client-fingerprint': p.fingerprint,
      if (p.alpn.isNotEmpty) 'alpn': p.alpn,
      if (p.allowInsecure) 'skip-cert-verify': true,
      ..._transport(p),
    };
  }

  Map<String, dynamic>? _vmess(ProxyProfile p) => {
        'name': p.name,
        'type': 'vmess',
        'server': p.server,
        'port': p.port,
        'uuid': p.uuid,
        'alterId': p.alterId ?? 0,
        'cipher': p.encryption == 'auto' || p.encryption == null
            ? 'auto'
            : p.encryption!,
        'udp': true,
        if (p.security != Security.none) 'tls': true,
        if ((p.sni ?? '').isNotEmpty) 'servername': p.sni,
        ..._transport(p),
      };

  Map<String, dynamic>? _trojan(ProxyProfile p) => {
        'name': p.name,
        'type': 'trojan',
        'server': p.server,
        'port': p.port,
        'password': p.password,
        'udp': true,
        'sni': p.sni ?? p.host ?? p.server,
        if ((p.fingerprint ?? '').isNotEmpty) 'client-fingerprint': p.fingerprint,
        if (p.allowInsecure) 'skip-cert-verify': true,
        ..._transport(p),
      };

  Map<String, dynamic>? _ss(ProxyProfile p) => {
        'name': p.name,
        'type': 'ss',
        'server': p.server,
        'port': p.port,
        'cipher': p.ssMethod,
        'password': p.password,
        'udp': true,
      };

  /// Transport layer: `network:` + the `-opts` block. xhttp carries the
  /// FULL translation (extra= JSON merged, then flat params layered on top
  /// — mirrors OutboundBuilders._xhttpSettings for the Xray engine).
  Map<String, dynamic> _transport(ProxyProfile p) {
    switch (p.transport) {
      case Transport.ws:
        return {
          'network': 'ws',
          'ws-opts': {
            'path': p.path ?? '/',
            if (p.host != null) 'headers': {'Host': p.host},
          },
        };
      case Transport.grpc:
        return {
          'network': 'grpc',
          'grpc-opts': {'grpc-service-name': p.serviceName ?? ''},
        };
      case Transport.h2:
        return {
          'network': 'h2',
          'h2-opts': {
            'path': p.path ?? '/',
            if (p.host != null) 'host': [p.host!],
          },
        };
      case Transport.httpupgrade:
        return {
          'network': 'httpupgrade',
          'httpupgrade-opts': {'path': p.path ?? '/', 'host': p.host ?? ''},
        };
      case Transport.xhttp:
        return {
          'network': 'xhttp',
          'xhttp-opts': _xhttpOpts(p),
        };
      case Transport.tcp:
      case Transport.quic:
      case Transport.none:
        return const {};
    }
  }

  /// THE TRANSLATION THE USER ASKED FOR: Xray share-link `extra=<json>` +
  /// flat link params → mihomo `xhttp-opts`.
  ///
  /// Layering order (same contract as the Xray engine's settings builder):
  ///   1. extra= JSON (KEEP nested maps: reuse-settings, download-settings,
  ///      headers — 3x-ui nests them);
  ///   2. engine-name normalization (packet→packet-up, connect→stream-one);
  ///   3. flat link params layered over (x_padding_bytes etc.).
  /// Finally Xray-name → mihomo-name (camelCase → kebab-case per field).
  Map<String, dynamic> _xhttpOpts(ProxyProfile p) {
    final m = <String, dynamic>{};

    // 1) extra= JSON object (nested values preserved).
    final extra = p.rawParams['extra'];
    if (extra != null && extra.trim().isNotEmpty) {
      try {
        final j = _decodeJson(extra) as Map<String, dynamic>;
        j.forEach((String k, dynamic v) => m[_xrayKeyToMihomo(k)] = v);
      } catch (_) {/* malformed extra — flat params still mapped below */}
    }

    // 2) mode normalization to mihomo's enum spellings.
    var mode = p.rawParams['mode'] ?? m['mode'];
    mode = switch (mode) {
      'packet' => 'packet-up',
      'connect' => 'stream-one',
      _ => mode,
    };
    if (mode == null && p.security == Security.tls) mode = 'stream-one';
    if (mode != null) m['mode'] = mode;

    // 3) flat link params (Xray spellings actually seen in the wild).
    final flat = <String, String?>{
      'xPaddingBytes': p.rawParams['x_padding_bytes'] ??
          p.rawParams['xpaddingsize'] ??
          p.rawParams['xpaddingbytes'],
      'xPaddingKey': p.rawParams['xpaddingkey'],
      'xPaddingHeader': p.rawParams['xpaddingheader'],
      'xPaddingPlacement': p.rawParams['xpaddingplacement'],
      'xPaddingMethod': p.rawParams['xpaddingmethod'],
      'noGrpcHeader': p.rawParams['no_grpc_header'],
    };
    flat.forEach((k, v) {
      if (v != null && v.isNotEmpty) m[_xrayKeyToMihomo(k)] = v;
    });

    // xmux= link param (JSON) → reuse-settings (mihomo name for XMUX).
    if (!m.containsKey('reuse-settings')) {
      final xmuxRaw = p.rawParams['xmux'];
      if (xmuxRaw != null && xmuxRaw.trim().isNotEmpty) {
        try {
          final j = _decodeJson(xmuxRaw);
          if (j is Map<String, dynamic>) m['reuse-settings'] = j;
        } catch (_) {}
      }
    }

    // Path/host from the structured profile (extra may have omitted them).
    if (p.path != null) m['path'] = p.path;
    final h = p.host ?? p.sni;
    if (h != null && (m['host'] == null || (m['host'] as String).isEmpty)) {
      m['host'] = h;
    }
    return m;
  }

  /// Xray camelCase field → mihomo kebab-case field (only the fields the
  /// two engines name differently; mihomo tolerates the rest verbatim).
  String _xrayKeyToMihomo(String k) => switch (k) {
        'xmux' => 'reuse-settings',
        'downloadSettings' => 'download-settings',
        'xPaddingBytes' => 'x-padding-bytes',
        'xPaddingKey' => 'x-padding-key',
        'xPaddingHeader' => 'x-padding-header',
        'xPaddingPlacement' => 'x-padding-placement',
        'xPaddingMethod' => 'x-padding-method',
        'noGrpcHeader' => 'no-grpc-header',
        'scMaxEachPostBytes' => 'sc-max-each-post-bytes',
        'scMinPostsIntervalMs' => 'sc-min-posts-interval-ms',
        'uplinkHttpMethod' => 'uplink-http-method',
        'sessionPlacement' => 'session-placement',
        'sessionKey' => 'session-key',
        'seqPlacement' => 'seq-placement',
        'seqKey' => 'seq-key',
        _ => k,
      };

  dynamic _decodeJson(String raw) => jsonDecode(raw);

  // ─────────────────────────────────────────────────────────────────────
  // ROUTING — app RoutingProfile → mihomo rule strings. The app's routing
  // editor targets the sing-box dialect; the common matchers translate 1:1
  // (direct/proxy actions; warp/chain stay app-level and never reach here).
  // ─────────────────────────────────────────────────────────────────────
  List<String> _routingRules(RoutingProfile routing) {
    final out = <String>[];
    for (final r in routing.rules) {
      if (!r.enabled) continue;
      final target = switch (r.action) {
        RoutingAction.proxy || RoutingAction.chain => 'ATX',
        RoutingAction.block => 'REJECT',
        RoutingAction.direct || RoutingAction.warp => 'DIRECT',
      };
      for (final p in r.patterns) {
        final rule = switch (r.matchType) {
          RuleMatchType.domainFull => 'DOMAIN,$p,$target',
          RuleMatchType.domainSuffix => 'DOMAIN-SUFFIX,$p,$target',
          RuleMatchType.domainKeyword => 'DOMAIN-KEYWORD,$p,$target',
          RuleMatchType.ipCidr => 'IP-CIDR,$p,$target,no-resolve',
          RuleMatchType.port => 'DST-PORT,$p,$target',
          RuleMatchType.process || RuleMatchType.package =>
            'PROCESS-NAME,$p,$target',
          // geoip / protocol / network have no 1:1 mihomo string rule —
          // skipped honestly (the sing-box front config keeps them).
          RuleMatchType.geoip ||
          RuleMatchType.protocol ||
          RuleMatchType.network => null,
        };
        if (rule != null) out.add(rule);
      }
    }
    return out;
  }
}
