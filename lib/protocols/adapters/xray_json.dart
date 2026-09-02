import 'dart:convert';
import '../../domain/entities/proxy_profile.dart';
import '../../domain/errors/app_error.dart';

/// Extracts outbound proxies from an Xray/V2Ray JSON config. The full config
/// remains importable as a *custom* Xray profile (passthrough).
class XrayJsonParser {
  ({List<ProxyProfile> profiles, List<String> skipped}) parse(String text) {
    dynamic doc;
    try {
      doc = jsonDecode(text);
    } on FormatException catch (e) {
      throw ParseError('This file is not valid JSON.',
          likelyCauses: ['Expected an Xray/V2Ray configuration'], raw: e.message);
    }
    if (doc is! Map) {
      throw ParseError('Xray config must be a JSON object.', raw: text);
    }
    final profiles = <ProxyProfile>[];
    final skipped = <String>[];
    final outbounds = doc['outbounds'];
    if (outbounds is! List) {
      throw ParseError('No `outbounds` array found in the Xray configuration.',
          raw: text);
    }
    for (final o in outbounds) {
      if (o is! Map) continue;
      final m = o.cast<String, dynamic>();
      final protocol = '${m['protocol'] ?? ''}';
      final tag = '${m['tag'] ?? protocol}';
      const proxyProtocols = {
        'vmess', 'vless', 'trojan', 'shadowsocks', 'socks', 'http', 'wireguard',
      };
      if (!proxyProtocols.contains(protocol)) continue; // freedom/blackhole/dns
      final settings = m['settings'] is Map
          ? (m['settings'] as Map).cast<String, dynamic>()
          : <String, dynamic>{};
      final stream = m['streamSettings'] is Map
          ? (m['streamSettings'] as Map).cast<String, dynamic>()
          : <String, dynamic>{};
      final p = _fromOutbound(m, settings, stream, tag, protocol, skipped);
      if (p != null) profiles.add(p);
    }
    return (profiles: profiles, skipped: skipped);
  }

  ProxyProfile? _fromOutbound(
      Map<String, dynamic> m,
      Map<String, dynamic> settings,
      Map<String, dynamic> stream,
      String tag,
      String protocol,
      List<String> skipped) {
    final vnext = settings['vnext'];
    List<dynamic> servers;
    if (vnext is List && vnext.isNotEmpty) {
      servers = vnext;
    } else if (settings['servers'] is List &&
        (settings['servers'] as List).isNotEmpty) {
      servers = settings['servers'] as List;
    } else {
      skipped.add('$tag: no servers in outbound');
      return null;
    }
        final s0 = (servers.first as Map).cast<String, dynamic>();
    final address = '${s0['address'] ?? ''}';
    final port = int.tryParse('${s0['port'] ?? ''}');
    if (address.isEmpty || port == null) {
      skipped.add('$tag: server address/port missing');
      return null;
    }
    final security = '${stream['security'] ?? 'none'}';
    Map<String, dynamic> sub(String key) =>
        stream[key] is Map ? (stream[key] as Map).cast<String, dynamic>() : {};
    final tlsSettings = sub('tlsSettings');
    final realitySettings = sub('realitySettings');
    final wsSettings = sub('wsSettings');
    final grpcSettings = sub('grpcSettings');
    final network = '${stream['network'] ?? 'tcp'}';
    final securityKind = switch (security) {
      'reality' => Security.reality,
      'tls' => Security.tls,
      _ => Security.none,
    };
    final users = s0['users'] is List ? (s0['users'] as List).firstOrNull : null;
    final user = users is Map ? users.cast<String, dynamic>() : <String, dynamic>{};
    String? nz(dynamic v) => (v == null || v.toString().isEmpty) ? null : v.toString();
    return ProxyProfile(
      id: Ids.newId(),
      name: tag,
      server: address,
      port: port,
      protocol: switch (protocol) {
        'vmess' => ProxyProtocol.vmess,
        'vless' => ProxyProtocol.vless,
        'trojan' => ProxyProtocol.trojan,
        'shadowsocks' => ProxyProtocol.shadowsocks,
        'socks' => ProxyProtocol.socks,
        'http' => ProxyProtocol.http,
        _ => ProxyProtocol.custom,
      },
      transport: switch (network) {
        'ws' => Transport.ws,
        'grpc' => Transport.grpc,
        'h2' => Transport.h2,
        'httpupgrade' => Transport.httpupgrade,
        'xhttp' || 'splithttp' => Transport.xhttp,
        _ => Transport.tcp,
      },
      security: securityKind,
      uuid: nz(user['id']),
      alterId: int.tryParse('${user['alterId'] ?? 0}'),
      encryption: nz(user['encryption']),
      flow: nz(user['flow']),
      sni: nz(realitySettings['serverName'] ?? tlsSettings['serverName']),
      fingerprint: nz(realitySettings['fingerprint'] ?? tlsSettings['fingerprint']),
      allowInsecure: tlsSettings['allowInsecure'] == true,
      path: nz(wsSettings['path']),
      host: wsSettings['headers'] is Map
          ? ((wsSettings['headers'] as Map)['Host'] ?? '').toString()
          : null,
      serviceName: nz(grpcSettings['serviceName']),
      realityPublicKey: nz(realitySettings['publicKey']),
      realityShortId: nz(realitySettings['shortId']),
      realitySpiderX: nz(realitySettings['spiderX']),
      rawConfig: jsonEncode(m),
      source: ProfileSource.fileImport,
    );
  }
}
