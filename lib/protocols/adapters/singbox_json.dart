import 'dart:convert';
import '../../domain/entities/proxy_profile.dart';
import '../../domain/errors/app_error.dart';

/// Extracts proxy outbounds (and wireguard endpoints) from a sing-box config
/// and normalizes them into profiles. Non-proxy outbounds (direct/block/
/// selector/urltest/dns) are ignored; the original document stays available
/// for the custom-config passthrough path.
class SingBoxJsonParser {
  ({List<ProxyProfile> profiles, List<String> skipped}) parse(String text) {
    dynamic doc;
    try {
      doc = jsonDecode(text);
    } on FormatException catch (e) {
      throw ParseError('This file is not valid JSON.',
          likelyCauses: ['Expected a sing-box configuration'], raw: e.message);
    }
    if (doc is! Map) {
      throw ParseError('sing-box config must be a JSON object.', raw: text);
    }
    final profiles = <ProxyProfile>[];
    final skipped = <String>[];
    final outbounds = doc['outbounds'];
    if (outbounds is List) {
      for (final o in outbounds) {
        if (o is! Map) continue;
        final p = _fromOutbound(o.cast<String, dynamic>(), skipped);
        if (p != null) profiles.add(p);
      }
    }
    final endpoints = doc['endpoints'];
    if (endpoints is List) {
      for (final e in endpoints) {
        if (e is! Map) continue;
        final p = _fromWireguardEndpoint(e.cast<String, dynamic>(), skipped);
        if (p != null) profiles.add(p);
      }
    }
    return (profiles: profiles, skipped: skipped);
  }

  ProxyProfile? _fromOutbound(Map<String, dynamic> o, List<String> skipped) {
    final type = '${o['type'] ?? ''}';
    final tag = '${o['tag'] ?? type}';
    const proxyTypes = {
      'shadowsocks', 'vmess', 'vless', 'trojan', 'hysteria', 'hysteria2',
      'tuic', 'socks', 'http', 'ssh', 'anytls', 'shadowtls', 'naive',
    };
    if (!proxyTypes.contains(type)) return null;
    final server = '${o['server'] ?? ''}';
    final port = int.tryParse('${o['server_port'] ?? ''}');
    if (server.isEmpty || port == null) {
      skipped.add('$tag: missing server/server_port');
      return null;
    }
    final tls =
        o['tls'] is Map ? (o['tls'] as Map).cast<String, dynamic>() : null;
    final security = tls != null && tls['enabled'] == true
        ? ((tls['reality']?['enabled'] == true)
            ? Security.reality
            : Security.tls)
        : Security.none;
    final transport = o['transport'] is Map
        ? (o['transport'] as Map).cast<String, dynamic>()
        : null;
    final trType = transport?['type']?.toString();
    final p = ProxyProfile(
      id: Ids.newId(),
      name: tag,
      server: server,
      port: port,
      protocol: switch (type) {
        'shadowsocks' => ProxyProtocol.shadowsocks,
        'vmess' => ProxyProtocol.vmess,
        'vless' => ProxyProtocol.vless,
        'trojan' => ProxyProtocol.trojan,
        'hysteria2' => ProxyProtocol.hysteria2,
        'hysteria' => ProxyProtocol.hysteria,
        'tuic' => ProxyProtocol.tuic,
        'socks' => ProxyProtocol.socks,
        'http' => ProxyProtocol.http,
        'ssh' => ProxyProtocol.ssh,
        'anytls' => ProxyProtocol.anytls,
        'shadowtls' => ProxyProtocol.shadowtls,
        'naive' => ProxyProtocol.naive,
        _ => ProxyProtocol.custom,
      },
      transport: switch (trType) {
        'ws' => Transport.ws,
        'grpc' => Transport.grpc,
        'http' => Transport.h2,
        'httpupgrade' => Transport.httpupgrade,
        _ => Transport.tcp,
      },
      security: security,
      uuid: (o['uuid'] ?? '') as String?,
      password: (o['password'] ?? '') as String?,
      alterId: int.tryParse('${o['alter_id'] ?? 0}'),
      sni: tls?['server_name'] as String?,
      allowInsecure: tls?['insecure'] == true,
      alpn: (tls?['alpn'] as List?)?.map((e) => e.toString()).toList() ?? const [],
      flow: _nz(o['flow']),
      path: transport?['path'] as String?,
      host: transport?['headers'] is Map
          ? ((transport?['headers'] as Map)['Host'] ?? '').toString()
          : null,
      serviceName: transport?['service_name'] as String?,
      ssMethod: _nz(o['method']),
      rawConfig: jsonEncode(o),
      source: ProfileSource.fileImport,
    );
    if (security == Security.reality && tls != null) {
      final reality = (tls['reality'] as Map?)?.cast<String, dynamic>();
      p.realityPublicKey = reality?['public_key'] as String?;
      p.realityShortId = reality?['short_id'] as String?;
      p.fingerprint = (tls['utls']?['fingerprint'] ?? '') as String?;
    }
    return p;
  }

  static String? _nz(dynamic v) =>
      (v == null || v.toString().isEmpty) ? null : v.toString();

  ProxyProfile? _fromWireguardEndpoint(
      Map<String, dynamic> e, List<String> skipped) {
    if (e['type'] != 'wireguard') {
      skipped.add('endpoint type ${e['type']} not importable yet');
      return null;
    }
    final peers = e['peers'];
    if (peers is! List || peers.isEmpty) {
      skipped.add('${e['tag']}: wireguard endpoint has no peers');
      return null;
    }
    final peer = (peers.first as Map).cast<String, dynamic>();
    final address = '${peer['address'] ?? ''}';
    final port = int.tryParse('${peer['port'] ?? ''}');
    if (address.isEmpty || port == null) {
      skipped.add('${e['tag']}: peer address/port missing');
      return null;
    }
    final reserved = (peer['reserved'] as List?)
        ?.map((x) => int.tryParse('$x') ?? 0)
        .toList();
    return ProxyProfile(
      id: Ids.newId(),
      name: '${e['tag'] ?? 'WireGuard'}',
      server: address,
      port: port,
      protocol: ProxyProtocol.wireguard,
      core: CoreKind.wireguardSingbox,
      wireguard: WireGuardConfig(
        privateKey: '${e['private_key'] ?? ''}',
        peerPublicKey: '${peer['public_key'] ?? ''}',
        endpointHost: address,
        endpointPort: port,
        preSharedKey: (peer['pre_shared_key'] ?? '') as String?,
        allowedIps: (peer['allowed_ips'] as List?)
                ?.map((x) => x.toString())
                .toList() ??
            const ['0.0.0.0/0', '::/0'],
        addresses:
            (e['address'] as List?)?.map((x) => x.toString()).toList() ?? const [],
        mtu: int.tryParse('${e['mtu'] ?? ''}'),
        persistentKeepalive:
            int.tryParse('${peer['persistent_keepalive_interval'] ?? ''}'),
        reserved: reserved,
      ),
      rawConfig: jsonEncode(e),
      source: ProfileSource.fileImport,
    );
  }
}
