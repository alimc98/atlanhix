import 'dart:convert';

import '../../domain/entities/proxy_profile.dart';

/// Builds the *outbound* portion of engine configs for a normalized profile.
/// Split from the full-config generators so chains can embed outbounds with
/// custom tags/detours.
class OutboundBuilders {
  /// v0.4.4 mockup pill (TLS Fragment): when true every TCP-TLS outbound
  /// carries `tls.fragment: true` (sing-box ≥1.11 boolean form — schema
  /// verified against the bundled 1.14 engine via `sing-box check`).
  const OutboundBuilders({this.tlsFragment = false});

  final bool tlsFragment;

  // ---------------------------------------------------------------- sing-box

  /// sing-box outbound object for [p]; returns null when the profile must NOT
  /// be executed as a native sing-box outbound:
  ///  * AmneziaWG / MasterDNSVPN — external daemons;
  ///  * **Xray-owned profiles** (`effectiveCore == xray`) and
  ///    `Transport.xhttp` profiles — these MUST traverse the Xray upstream
  ///    via a SOCKS stub (detector decision controls the traffic path).
  /// Returning null makes the generator fall through to the
  /// `socksUpstreams` map; callers must supply the upstream for such
  /// profiles or the profile is skipped (and logged) — never native-built.
  Map<String, dynamic>? singBoxOutbound(ProxyProfile p,
      {required String tag, String? detourTag}) {
    // Invariant: the detector/user decision owns the traffic path. An
    // Xray-owned profile must never be built as a native sing-box outbound —
    // silently downgrading xhttp/plain-transport configs here is exactly the
    // "detector says Xray but sing-box connects directly" failure mode.
    if (p.effectiveCore == CoreKind.xray || p.transport == Transport.xhttp) {
      return null;
    }
    switch (p.protocol) {
      case ProxyProtocol.vmess:
        return _sbBase(p, 'vmess', tag, detourTag)
          ..['uuid'] = p.uuid
          ..['security'] = p.encryption ?? 'auto'
          ..['alter_id'] = p.alterId ?? 0;
      case ProxyProtocol.vless:
        return _sbBase(p, 'vless', tag, detourTag)
          ..['uuid'] = p.uuid
          ..['flow'] = p.flow;
      case ProxyProtocol.trojan:
        return _sbBase(p, 'trojan', tag, detourTag)..['password'] = p.password;
      case ProxyProtocol.shadowsocks:
        return _sbBase(p, 'shadowsocks', tag, detourTag)
          ..['method'] = p.ssMethod
          ..['password'] = p.password;
      case ProxyProtocol.hysteria2:
        return _sbBase(p, 'hysteria2', tag, detourTag)
          ..['password'] = p.password
          ..['up_mbps'] = p.hysteriaUpMbps
          ..['down_mbps'] = p.hysteriaDownMbps
          ..addAll({
            if (p.hysteriaObfsPassword != null)
              'obfs': {'type': 'salamander', 'password': p.hysteriaObfsPassword},
          });
      case ProxyProtocol.hysteria:
        return _sbBase(p, 'hysteria', tag, detourTag)
          ..['auth_str'] = p.password
          ..['up_mbps'] = p.hysteriaUpMbps
          ..['down_mbps'] = p.hysteriaDownMbps;
      case ProxyProtocol.tuic:
        return _sbBase(p, 'tuic', tag, detourTag)
          ..['uuid'] = p.tuicUuid
          ..['password'] = p.tuicToken
          ..['congestion_control'] = p.rawParams['congestion_control'] ?? 'bbr'
          ..['udp_relay_mode'] = p.rawParams['udp_relay_mode'] ?? 'native';
      case ProxyProtocol.anytls:
        return _sbBase(p, 'anytls', tag, detourTag)..['password'] = p.password;
      case ProxyProtocol.shadowtls:
        return _sbBase(p, 'shadowtls', tag, detourTag)
          ..['version'] = int.tryParse(p.rawParams['version'] ?? '3') ?? 3
          ..['password'] = p.password;
      case ProxyProtocol.naive:
        return _sbBase(p, 'naive', tag, detourTag)
          ..['username'] = p.uuid
          ..['password'] = p.password;
      case ProxyProtocol.socks:
        return {
          'type': 'socks',
          'tag': tag,
          'server': p.server,
          'server_port': p.port,
          'version': '5',
          if (p.uuid != null || p.password != null)
            'users': [
              {'username': p.uuid, 'password': p.password}
            ],
          if (detourTag != null) 'detour': detourTag,
        };
      case ProxyProtocol.http:
        return {
          'type': 'http',
          'tag': tag,
          'server': p.server,
          'server_port': p.port,
          if (p.uuid != null || p.password != null)
            'users': [
              {'username': p.uuid, 'password': p.password}
            ],
          if (detourTag != null) 'detour': detourTag,
        };
      case ProxyProtocol.ssh:
        return {
          'type': 'ssh',
          'tag': tag,
          'server': p.server,
          'server_port': p.port,
          'user': p.uuid ?? 'root',
          if (p.password != null) 'password': p.password,
          if (detourTag != null) 'detour': detourTag,
        };
      case ProxyProtocol.wireguard:
      case ProxyProtocol.masterDnsVpn:
      case ProxyProtocol.custom:
        return null; // endpoint / external daemon / passthrough
    }
  }

  Map<String, dynamic> _sbBase(
      ProxyProfile p, String type, String tag, String? detourTag) {
    // QUIC outbounds carry their own TLS 1.3 — uTLS would be rejected
    // ("unsupported usage for uTLS", measured on device 2026-09-13).
    final quic = type == 'hysteria' || type == 'hysteria2' || type == 'tuic';
    final tls =
        p.security != Security.none ? _sbTls(p, quic: quic) : null;
    return {
      'type': type,
      'tag': tag,
      'server': p.server,
      'server_port': p.port,
      if (tls != null) 'tls': tls,
      if (p.transport != Transport.none) 'transport': _sbTransport(p),
      if (detourTag != null) 'detour': detourTag,
    };
  }

  Map<String, dynamic>? _sbTls(ProxyProfile p, {bool quic = false}) {
    if (p.security == Security.none) return null;
    final echPem = _echPemFromProfile(p);
    return {
      'enabled': true,
      'server_name': p.sni ?? p.host,
      'insecure': p.allowInsecure,
      if (p.alpn.isNotEmpty) 'alpn': p.alpn,
      // uTLS is a TCP-TLS stack feature: sing-box rejects it on QUIC
      // outbounds (hysteria / hysteria2 / tuic) with
      // "unsupported usage for uTLS" — measured on device 2026-09-13
      // (ro.hixyz.ir hysteria2 node). QUIC has its own TLS 1.3 inside the
      // transport; the imported `fp=` hint is not applicable there.
      if (p.fingerprint != null && !quic)
        'utls': {'enabled': true, 'fingerprint': p.fingerprint},
      // TLS Fragment pill: TCP-TLS only (QUIC stacks reject it).
      if (tlsFragment && !quic) 'fragment': true,
      // ECH (Encrypted ClientHello): subscriptions carry it as the `ech=`
      // URI param (base64 DER ECHConfigList) or `echBase64` in clash-style
      // tls objects. sing-box consumes it as a PEM block typed exactly
      // "ECH CONFIGS" whose DER bytes ARE the full ECHConfigList — verified
      // against the bundled engine (common/tls/ech.go v1.14.0: pem.Decode +
      // block.Type != "ECH CONFIGS" -> error; SetECHConfigList(block.Bytes))
      // and by `sing-box check` on a generated config (2026-09-13). Without
      // this, ECH-only servers reject the handshake ("Connection terminated
      // during handshake" — measured on hysteria2 uk/ro nodes, same day).
      if (echPem != null) 'ech': {'enabled': true, 'config': [echPem]},
      if (p.security == Security.reality)
        'reality': {
          'enabled': true,
          'public_key': p.realityPublicKey,
          'short_id': p.realityShortId ?? '',
        },
    };
  }

  /// ECHConfigList (base64 DER) carried by a profile -> the sing-box PEM
  /// block format. Returns null when absent or unparseable.
  ///
  /// Sources, in priority order: `ech` / `echBase64` in the profile's
  /// preserved raw params (hysteria/vless/trojan URI params, clash-style tls
  /// object). The block type MUST be "ECH CONFIGS" (sing-box's pem decoder
  /// rejects any other) and MUST be a single block (it checks `rest` empty).
  static String? _echPemFromProfile(ProxyProfile p) {
    final raw = p.rawParams['ech'] ?? p.rawParams['echBase64'];
    if (raw == null || raw.isEmpty) return null;
    List<int> der;
    try {
      der = base64.decode(raw);
    } on FormatException {
      try {
        der = base64Url.decode(raw);
      } on FormatException {
        return null; // never emit a corrupt ECH block
      }
    }
    final b64 = base64.encode(der);
    final lines = <String>[
      for (var i = 0; i < b64.length; i += 64) b64.substring(i, i + 64 > b64.length ? b64.length : i + 64)
    ];
    return '-----BEGIN ECH CONFIGS-----\n${lines.join('\n')}\n-----END ECH CONFIGS-----';
  }

  Map<String, dynamic>? _sbTransport(ProxyProfile p) {
    switch (p.transport) {
      case Transport.ws:
        return {
          'type': 'ws',
          'path': p.path ?? '/',
          if (p.host != null) 'headers': {'Host': p.host},
          if (p.rawParams['early-data'] != null)
            'max_early_data': int.tryParse(p.rawParams['early-data']!),
        };
      case Transport.grpc:
        return {'type': 'grpc', 'service_name': p.serviceName ?? p.path ?? ''};
      case Transport.h2:
        return {
          'type': 'http',
          'path': p.path ?? '/',
          if (p.host != null) 'host': [p.host],
        };
      case Transport.httpupgrade:
        return {
          'type': 'httpupgrade',
          'path': p.path ?? '/',
          if (p.host != null) 'host': p.host,
        };
      case Transport.xhttp:
      case Transport.quic:
      case Transport.tcp:
      case Transport.none:
        return null;
    }
  }

  /// sing-box `endpoints` entry for WireGuard (native profiles + WARP).
  Map<String, dynamic>? singBoxWireguardEndpoint(ProxyProfile p,
      {required String tag, String? detourTag}) {
    final wg = p.wireguard;
    if (wg == null) return null;
    return {
      'type': 'wireguard',
      'tag': tag,
      'address': wg.addresses.isNotEmpty
          ? wg.addresses
          : ['172.16.0.2/32', 'fd01:5ca1:ab1e:80fa:ab85:6eea:213f:f4a5/128'],
      'private_key': wg.privateKey,
      'mtu': wg.mtu ?? 1408,
      'peers': [
        {
          'address': wg.endpointHost,
          'port': wg.endpointPort,
          'public_key': wg.peerPublicKey,
          if (wg.preSharedKey != null) 'pre_shared_key': wg.preSharedKey,
          'allowed_ips': wg.allowedIps,
          if (wg.persistentKeepalive != null)
            'persistent_keepalive_interval': wg.persistentKeepalive,
          if (wg.reserved != null && wg.reserved!.length == 3)
            'reserved': wg.reserved,
        }
      ],
      if (detourTag != null) 'detour': detourTag,
    };
  }

  // ------------------------------------------------------------------- Xray

  /// Xray outbound object. Returns null when Xray cannot run this profile.
  Map<String, dynamic>? xrayOutbound(ProxyProfile p,
      {required String tag, String? followByTag}) {
    switch (p.protocol) {
      case ProxyProtocol.vmess:
        return _xrBase(p, 'vmess', tag, followByTag)
          ..['settings'] = {
            'vnext': [
              {
                'address': p.server,
                'port': p.port,
                'users': [
                  {
                    'id': p.uuid,
                    'alterId': p.alterId ?? 0,
                    'security': p.encryption ?? 'auto',
                  }
                ],
              }
            ],
          };
      case ProxyProtocol.vless:
        return _xrBase(p, 'vless', tag, followByTag)
          ..['settings'] = {
            'vnext': [
              {
                'address': p.server,
                'port': p.port,
                'users': [
                  {
                    'id': p.uuid,
                    // v0.4.4 fix: forward verbatim — the 26.x links carry a
                    // post-quantum string ('mlkem768x25519plus.native.0rtt.…')
                    // that Xray 26.3.27 REQUIRES to match the server. Fallback
                    // is 'none': 'auto' is VMESS-only and 26.3.27 hard-rejects
                    // it for VLESS (phone log: unsupported "encryption": auto).
                    // Profiles stored BEFORE the encryption-codec fix keep it
                    // only in rawParams — read from there too, else these
                    // nodes (all 4 PQ Reality ones) die in config parse.
                    'encryption': p.encryption ??
                        p.rawParams['encryption'] ??
                        'none',
                    if (p.flow != null) 'flow': p.flow,
                  }
                ],
              }
            ],
          };
      case ProxyProtocol.trojan:
        return _xrBase(p, 'trojan', tag, followByTag)
          ..['settings'] = {
            'servers': [
              {'address': p.server, 'port': p.port, 'password': p.password},
            ],
          };
      case ProxyProtocol.shadowsocks:
        return _xrBase(p, 'shadowsocks', tag, followByTag)
          ..['settings'] = {
            'servers': [
              {
                'address': p.server,
                'port': p.port,
                'method': p.ssMethod,
                'password': p.password,
              }
            ],
          };
      case ProxyProtocol.socks:
      case ProxyProtocol.http:
        return _xrBase(p, p.protocol == ProxyProtocol.socks ? 'socks' : 'http',
                tag, followByTag)
          ..['settings'] = {
            'servers': [
              {
                'address': p.server,
                'port': p.port,
                if (p.uuid != null)
                  'users': [
                    {'user': p.uuid, 'pass': p.password}
                  ],
              }
            ],
          };
      default:
        return null; // not executable by Xray
    }
  }

  Map<String, dynamic> _xrBase(
      ProxyProfile p, String protocol, String tag, String? followByTag) {
    return {
      'protocol': protocol,
      'tag': tag,
      'streamSettings': _xrStream(p),
      if (followByTag != null)
        'proxySettings': {'tag': followByTag, 'transportLayer': true},
      'mux': {'enabled': false, 'concurrency': -1},
    };
  }

  Map<String, dynamic> _xrStream(ProxyProfile p) {
    final s = <String, dynamic>{'network': _xrNetwork(p.transport)};
    switch (p.security) {
      case Security.reality:
        s['security'] = 'reality';
        s['realitySettings'] = ({
          'show': false,
          'serverName': p.sni ?? p.host,
          'publicKey': p.realityPublicKey,
          'shortId': p.realityShortId ?? '',
          if (p.realitySpiderX != null) 'spiderX': p.realitySpiderX,
          'fingerprint': p.fingerprint ?? 'chrome',
          if ((p.rawParams['mldsa65Verify'] ?? '').isNotEmpty)
            'mldsa65Verify': p.rawParams['mldsa65Verify'],
        });
      case Security.tls:
        s['security'] = 'tls';
        s['tlsSettings'] = ({
          'serverName': p.sni ?? p.host,
          'allowInsecure': p.allowInsecure,
          // ALPN default (3x-ui audit, engine-verified): xhttp over plain
          // TLS is HTTP/1.1-shaped; emitting no alpn lets Xray default to
          // h2, which fronts (nginx/CDN serving http/1.1 on /api) reset in
          // handshake — the Ghodrat signature.
          'alpn': p.alpn.isNotEmpty
              ? p.alpn
              : (p.transport == Transport.xhttp
                  ? const ['http/1.1']
                  : const []),
          if (p.fingerprint != null) 'fingerprint': p.fingerprint,
        }..removeWhere((k, v) => v is List && v.isEmpty));
      case Security.none:
        break;
    }
    // FinalMask (Xray 26.x late-layer obfuscation): lives at
    // streamSettings.finalmask (lowercase) — verified against the bundled
    // 26.3.27 binary (sudoku/noise shapes OK). Inside tlsSettings it is a
    // silent no-op (also verified) — hence this placement.
    final fmRaw = p.rawParams['finalmask'] ?? p.rawParams['finalMask'];
    if (fmRaw != null && fmRaw.trim().isNotEmpty) {
      try {
        final j = jsonDecode(fmRaw);
        if (j is Map || j is List) s['finalmask'] = j;
      } catch (_) {/* malformed — omit; node still dials without the mask */}
    }
    switch (p.transport) {
      case Transport.ws:
        s['wsSettings'] = {
          'path': p.path ?? '/',
          if (p.host != null) 'headers': {'Host': p.host},
        };
      case Transport.grpc:
        s['grpcSettings'] = {
          'serviceName': p.serviceName ?? p.path ?? '',
          'multiMode': false,
        };
      case Transport.h2:
        s['httpSettings'] = {
          'path': p.path ?? '/',
          if (p.host != null) 'host': [p.host],
        };
      case Transport.httpupgrade:
        s['httpupgradeSettings'] = {
          'path': p.path ?? '/',
          if (p.host != null) 'host': p.host,
        };
      case Transport.xhttp:
        s['xhttpSettings'] = _xhttpSettings(p);
      case Transport.tcp:
      case Transport.quic:
      case Transport.none:
        break;
    }
    return s;
  }

  /// Xray 26.x xhttpSettings: honor the link's `extra` JSON object when
  /// present ({mode, xPaddingBytes, xPaddingHeader, ...}) and layer the
  /// flat params over it — this is the shape the XTLS spec documents and
  /// what these subscription links actually require.


  static Map<String, dynamic> _xhttpSettings(ProxyProfile p) {
    final m = <String, dynamic>{};
    final extra = p.rawParams['extra'];
    if (extra != null && extra.trim().isNotEmpty) {
      try {
        final j = jsonDecode(extra);
        if (j is Map) {
          // KEEP nested values (headers{}, xmux{}, downloadSettings{}) —
          // 3x-ui nests them in extra; scalar-only filtering used to drop
          // xmux silently.
          j.forEach((k, v) {
            if (k is String) m[k] = v;
          });
        }
      } catch (_) {/* malformed extra — flat params still emitted below */}
    }
    var mode = p.rawParams['mode'] ?? m['mode'];
    // INCY-era spellings → engine enums (26.3.27 hard-rejects the old ones).
    mode = switch (mode) {
      'packet' => 'packet-up',
      'connect' => 'stream-one',
      _ => mode,
    };
    // Xray resolves 'auto' per security layer (REALITY→stream-one/H2,
    // TLS→packet-up). When the link left it unspecified on plain TLS,
    // XTLS guidance is stream-one — emit it explicitly, never 'auto'.
    if (mode == null && p.security == Security.tls) mode = 'stream-one';
    if (mode != null) m['mode'] = mode;
    // Flat padding param spellings actually produced in the wild.
    for (final pair in const [
      ['x_padding_bytes', 'xPaddingBytes'],
      ['xpaddingsize', 'xPaddingBytes'],
      ['xpaddingbytes', 'xPaddingBytes'],
      ['xpaddingkey', 'xPaddingKey'],
      ['xpaddingheader', 'xPaddingHeader'],
      ['xpaddingplacement', 'xPaddingPlacement'],
      ['xpaddingmethod', 'xPaddingMethod'],
    ]) {
      final v = p.rawParams[pair[0]] ?? p.rawParams[pair[1]];
      if (v != null && v.isNotEmpty) m[pair[1]] = v;
    }
    // xmux: engine name inside xhttpSettings (verified OK); link-level
    // camelCase spellings (MaxConcurrentUploads…) are NOT engine names.
    if (!m.containsKey('xmux')) {
      final xmuxRaw = p.rawParams['xmux'];
      if (xmuxRaw != null && xmuxRaw.trim().isNotEmpty) {
        try {
          final j = jsonDecode(xmuxRaw);
          if (j is Map<String, dynamic>) m['xmux'] = j;
        } catch (_) {}
      }
    }
    if (p.path != null) m['path'] = p.path;
    // `host` = HTTP Host header; Xray accepts the SNI/default when absent.
    final h = p.host ?? p.sni;
    if (h != null) m['host'] = h;
    return m;
  }

  static String _xrNetwork(Transport t) => switch (t) {
        Transport.ws => 'ws',
        Transport.grpc => 'grpc',
        Transport.h2 => 'h2',
        Transport.httpupgrade => 'httpupgrade',
        Transport.xhttp => 'xhttp',
        Transport.quic => 'mKCP',
        _ => 'raw',
      };
}
