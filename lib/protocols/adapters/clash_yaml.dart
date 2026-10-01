import 'dart:convert' show jsonEncode;

import 'package:yaml/yaml.dart';
import '../../domain/entities/proxy_profile.dart';
import '../../domain/errors/app_error.dart';

/// Parses Clash / Clash.Meta `proxies:` lists into normalized profiles.
/// Unsupported proxy types are reported, never silently dropped.
class ClashYamlParser {
  ({List<ProxyProfile> profiles, List<String> skipped}) parse(String text) {
    final profiles = <ProxyProfile>[];
    final skipped = <String>[];
    dynamic doc;
    try {
      doc = loadYaml(text);
    } on YamlException catch (e) {
      throw ParseError('This Clash configuration is not valid YAML.',
          likelyCauses: ['Indentation or syntax error'], raw: e.message);
    }
    if (doc is! YamlMap) {
      throw ParseError('This Clash configuration has no proxies section.',
          raw: 'root is not a map');
    }
    final proxies = doc['proxies'];
    if (proxies is! YamlList) {
      throw ParseError('No `proxies:` list found in the Clash configuration.',
          raw: text.length > 200 ? '${text.substring(0, 200)}…' : text);
    }
    for (final item in proxies) {
      if (item is! YamlMap) {
        skipped.add('non-object proxy entry');
        continue;
      }
      final m = (item as Map).cast<String, dynamic>();
      try {
        profiles.add(_parseProxy(m));
      } on FormatException catch (e) {
        skipped.add('${m['name'] ?? 'unnamed'}: ${e.message}');
      } on ParseError catch (e) {
        skipped.add('${m['name'] ?? 'unnamed'}: ${e.userMessage}');
      }
    }
    return (profiles: profiles, skipped: skipped);
  }

  ProxyProfile _parseProxy(Map<String, dynamic> m) {
    final type = (m['type'] ?? '').toString().toLowerCase();
    final server = (m['server'] ?? '').toString();
    final port = int.tryParse('${m['port'] ?? ''}');
    if (server.isEmpty || port == null) {
      throw const FormatException('server/port missing');
    }
    final name = (m['name'] ?? '$server:$port').toString();
    switch (type) {
      case 'vmess':
        return _vmess(m, name, server, port);
      case 'vless':
        return _vless(m, name, server, port);
      case 'trojan':
        return _trojan(m, name, server, port);
      case 'ss':
        return _ss(m, name, server, port);
      case 'hysteria2':
      case 'hy2':
        return _hy2(m, name, server, port);
      case 'hysteria':
        return _hy1(m, name, server, port);
      case 'tuic':
        return _tuic(m, name, server, port);
      case 'http':
      case 'https':
      case 'socks5':
        return _httpSocks(m, name, server, port, type);
      case 'anytls':
        return _anytls(m, name, server, port);
      default:
        throw FormatException('unsupported clash type "$type"');
    }
  }

  ProxyProfile _vmess(Map<String, dynamic> m, String name, String server, int port) {
    return ProxyProfile(
      id: Ids.newId(),
      name: name,
      server: server,
      port: port,
      protocol: ProxyProtocol.vmess,
      transport: _transport((m['network'] ?? 'tcp').toString()),
      security: m['tls'] == true ? Security.tls : Security.none,
      uuid: (m['uuid'] ?? '').toString(),
      alterId: int.tryParse('${m['alterId'] ?? 0}') ?? 0,
      encryption: (m['cipher'] ?? 'auto').toString(),
      sni: _sni(m),
      host: _transportHost(m),
      path: _transportPath(m),
      serviceName: _grpcName(m),
      fingerprint: _fp(m),
      allowInsecure: m['skip-cert-verify'] == true,
      rawParams: _xhttpParams(m),
      source: ProfileSource.fileImport,
    );
  }

  ProxyProfile _vless(Map<String, dynamic> m, String name, String server, int port) {
    final reality = m['reality-opts'];
    return ProxyProfile(
      id: Ids.newId(),
      name: name,
      server: server,
      port: port,
      protocol: ProxyProtocol.vless,
      transport: _transport((m['network'] ?? 'tcp').toString()),
      security: reality != null
          ? Security.reality
          : (m['tls'] == true ? Security.tls : Security.none),
      uuid: (m['uuid'] ?? '').toString(),
      flow: (m['flow'] ?? '') as String?,
      sni: _sni(m),
      host: _transportHost(m),
      path: _transportPath(m),
      serviceName: _grpcName(m),
      fingerprint: _fp(m),
      allowInsecure: m['skip-cert-verify'] == true,
      realityPublicKey:
          reality is Map ? (reality['public-key'] ?? '').toString() : null,
      realityShortId:
          reality is Map ? (reality['short-id'] ?? '').toString() : null,
      rawParams: _xhttpParams(m),
      source: ProfileSource.fileImport,
    );
  }

  ProxyProfile _trojan(Map<String, dynamic> m, String name, String server, int port) {
    return ProxyProfile(
      id: Ids.newId(),
      name: name,
      server: server,
      port: port,
      protocol: ProxyProtocol.trojan,
      transport: _transport((m['network'] ?? 'tcp').toString()),
      security: Security.tls,
      password: (m['password'] ?? '').toString(),
      sni: _sni(m),
      host: _transportHost(m),
      path: _transportPath(m),
      serviceName: _grpcName(m),
      allowInsecure: m['skip-cert-verify'] == true,
      alpn: (m['alpn'] as List?)?.map((e) => e.toString()).toList() ?? const [],
      rawParams: _xhttpParams(m),
      source: ProfileSource.fileImport,
    );
  }

  ProxyProfile _ss(Map<String, dynamic> m, String name, String server, int port) {
    return ProxyProfile(
      id: Ids.newId(),
      name: name,
      server: server,
      port: port,
      protocol: ProxyProtocol.shadowsocks,
      ssMethod: (m['cipher'] ?? '').toString(),
      password: (m['password'] ?? '').toString(),
      source: ProfileSource.fileImport,
    );
  }

  ProxyProfile _hy2(Map<String, dynamic> m, String name, String server, int port) {
    return ProxyProfile(
      id: Ids.newId(),
      name: name,
      server: server,
      port: port,
      protocol: ProxyProtocol.hysteria2,
      security: Security.tls,
      password: (m['password'] ?? m['auth'] ?? '').toString(),
      sni: _sni(m),
      allowInsecure: m['skip-cert-verify'] == true,
      hysteriaObfsPassword: m['obfs-password']?.toString(),
      hysteriaUpMbps: int.tryParse('${m['up'] ?? ''}'),
      hysteriaDownMbps: int.tryParse('${m['down'] ?? ''}'),
      rawParams: {
        if (m['obfs'] != null) 'obfs': '${m['obfs']}',
        if (m['ports'] != null) 'mport': '${m['ports']}',
      },
      source: ProfileSource.fileImport,
    );
  }

  ProxyProfile _hy1(Map<String, dynamic> m, String name, String server, int port) {
    return ProxyProfile(
      id: Ids.newId(),
      name: name,
      server: server,
      port: port,
      protocol: ProxyProtocol.hysteria,
      security: Security.tls,
      password: (m['auth-str'] ?? m['auth_str'] ?? '').toString(),
      sni: _sni(m),
      allowInsecure: m['skip-cert-verify'] == true,
      hysteriaUpMbps: int.tryParse('${m['up'] ?? ''}'),
      hysteriaDownMbps: int.tryParse('${m['down'] ?? ''}'),
      source: ProfileSource.fileImport,
    );
  }

  ProxyProfile _tuic(Map<String, dynamic> m, String name, String server, int port) {
    return ProxyProfile(
      id: Ids.newId(),
      name: name,
      server: server,
      port: port,
      protocol: ProxyProtocol.tuic,
      security: Security.tls,
      tuicUuid: (m['uuid'] ?? '').toString(),
      tuicToken: (m['password'] ?? '').toString(),
      sni: _sni(m),
      allowInsecure: m['skip-cert-verify'] == true,
      alpn: (m['alpn'] as List?)?.map((e) => e.toString()).toList() ??
          const ['h3'],
      rawParams: {
        if (m['congestion-controller'] != null)
          'congestion_control': '${m['congestion-controller']}',
        if (m['udp-relay-mode'] != null)
          'udp_relay_mode': '${m['udp-relay-mode']}',
      },
      source: ProfileSource.fileImport,
    );
  }

  ProxyProfile _httpSocks(Map<String, dynamic> m, String name, String server,
      int port, String type) {
    return ProxyProfile(
      id: Ids.newId(),
      name: name,
      server: server,
      port: port,
      protocol:
          type.startsWith('http') ? ProxyProtocol.http : ProxyProtocol.socks,
      security: type == 'https' ? Security.tls : Security.none,
      uuid: (m['username'] ?? '') as String?,
      password: (m['password'] ?? '') as String?,
      source: ProfileSource.fileImport,
    );
  }

  ProxyProfile _anytls(Map<String, dynamic> m, String name, String server, int port) {
    return ProxyProfile(
      id: Ids.newId(),
      name: name,
      server: server,
      port: port,
      protocol: ProxyProtocol.anytls,
      security: Security.tls,
      password: (m['password'] ?? '').toString(),
      sni: _sni(m),
      allowInsecure: m['skip-cert-verify'] == true,
      source: ProfileSource.fileImport,
    );
  }

  /// v0.6.0 §xhttp-yaml: `xhttp`/`splithttp` MUST parse to [Transport.xhttp].
  /// Before this the fallback swallowed them into Transport.tcp — a Clash-
  /// dialect xhttp node imported from a subscription connected as plain TCP
  /// (the user-visible "xhttp reality goes over tcp on mihomo" bug). The
  /// structured path/host now also come from the transport's own opts block
  /// (xhttp-opts first — ws-opts kept for legacy spellings).
  static Transport _transport(String net) => switch (net) {
        'ws' => Transport.ws,
        'grpc' => Transport.grpc,
        'h2' => Transport.h2,
        'httpupgrade' => Transport.httpupgrade,
        'xhttp' || 'splithttp' => Transport.xhttp,
        _ => Transport.tcp,
      };

  /// path for the ACTIVE transport: xhttp-opts > ws-opts (older Clash
  /// writers stored everything under ws-opts regardless of network).
  static String? _transportPath(Map<String, dynamic> m) {
    final x = m['xhttp-opts'];
    if (x is Map) {
      final v = x['path'];
      if (v != null && v.toString().isNotEmpty) return v.toString();
    }
    return _wsPath(m);
  }

  static String? _transportHost(Map<String, dynamic> m) {
    final x = m['xhttp-opts'];
    if (x is Map) {
      final v = x['host'];
      if (v != null && v.toString().isNotEmpty) return v.toString();
    }
    return _wsHost(m);
  }

  /// Flatten the xhttp-opts map into rawParams (string values) so the
  /// downstream generators (mihomo `xhttp-opts`, Xray settings) can rebuild
  /// the full transport — mode, padding fields, reuse/download settings…
  /// all survive the import round-trip.
  ///
  /// Three spellings coexist in the wild (mihomo kebab-case, Xray link
  /// camelCase, the `extra=` JSON blob) — the app's generators read the
  /// LINK dialect, so every kebab field also lands under its Xray link
  /// name, and the whole map is mirrored into `extra` (nested maps/lists
  /// preserved) which both engines merge verbatim.
  static Map<String, String> _xhttpParams(Map<String, dynamic> m) {
    final x = m['xhttp-opts'];
    if (x is! Map) return const {};
    final out = <String, String>{};
    final extra = <String, dynamic>{};
    x.forEach((k, v) {
      if (v == null) return;
      out[k.toString()] = v is Map || v is List ? jsonEncode(v) : '$v';
      extra[k.toString()] = v; // native types inside the extra blob
    });
    const camelOf = <String, String>{
      'reuse-settings': 'xmux',
      'download-settings': 'downloadSettings',
      'x-padding-bytes': 'xPaddingBytes',
      'x-padding-key': 'xPaddingKey',
      'x-padding-header': 'xPaddingHeader',
      'x-padding-placement': 'xPaddingPlacement',
      'x-padding-method': 'xPaddingMethod',
      'no-grpc-header': 'noGrpcHeader',
      'sc-max-each-post-bytes': 'scMaxEachPostBytes',
      'sc-min-posts-interval-ms': 'scMinPostsIntervalMs',
      'uplink-http-method': 'uplinkHttpMethod',
      'session-placement': 'sessionPlacement',
      'session-key': 'sessionKey',
      'seq-placement': 'seqPlacement',
      'seq-key': 'seqKey',
    };
    camelOf.forEach((kebab, link) {
      if (!x.containsKey(kebab)) return;
      final v = x[kebab];
      if (v == null) return;
      out[link] = v is Map || v is List ? jsonEncode(v) : '$v';
      extra[link] = v;
    });
    if (extra.isNotEmpty) out['extra'] = jsonEncode(extra);
    return out;
  }

  static String? _sni(Map<String, dynamic> m) {
    final v = m['servername'] ?? m['sni'];
    return (v == null || v.toString().isEmpty) ? null : v.toString();
  }

  static String? _fp(Map<String, dynamic> m) {
    final v = m['client-fingerprint'];
    return (v == null || v.toString().isEmpty) ? null : v.toString();
  }

  static String? _grpcName(Map<String, dynamic> m) {
    final g = m['grpc-opts'];
    if (g is Map) {
      final n = g['grpc-service-name'];
      return (n == null || n.toString().isEmpty) ? null : n.toString();
    }
    return null;
  }

  static String? _wsPath(Map<String, dynamic> m) {
    final ws = m['ws-opts'];
    if (ws is Map) return ws['path']?.toString();
    return null;
  }

  static String? _wsHost(Map<String, dynamic> m) {
    final ws = m['ws-opts'];
    if (ws is Map && ws['headers'] is Map) {
      final h = ws['headers']['Host'];
      return (h == null || h.toString().isEmpty) ? null : h.toString();
    }
    return null;
  }
}
