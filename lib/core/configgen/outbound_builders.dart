import '../../domain/entities/proxy_profile.dart';

/// Builds the *outbound* portion of engine configs for a normalized profile.
/// Split from the full-config generators so chains can embed outbounds with
/// custom tags/detours.
class OutboundBuilders {
  const OutboundBuilders();

  // ---------------------------------------------------------------- sing-box

  /// sing-box outbound object for [p]; returns null when the profile must not
  /// be executed by sing-box (AmneziaWG, MasterDNSVPN run as external daemons).
  Map<String, dynamic>? singBoxOutbound(ProxyProfile p,
      {required String tag, String? detourTag}) {
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
    final tls = p.security != Security.none ? _sbTls(p) : null;
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

  Map<String, dynamic>? _sbTls(ProxyProfile p) {
    if (p.security == Security.none) return null;
    return {
      'enabled': true,
      'server_name': p.sni ?? p.host,
      'insecure': p.allowInsecure,
      if (p.alpn.isNotEmpty) 'alpn': p.alpn,
      if (p.fingerprint != null)
        'utls': {'enabled': true, 'fingerprint': p.fingerprint},
      if (p.security == Security.reality)
        'reality': {
          'enabled': true,
          'public_key': p.realityPublicKey,
          'short_id': p.realityShortId ?? '',
        },
    };
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
                    'encryption': p.encryption ?? 'none',
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
        s['realitySettings'] = {
          'show': false,
          'serverName': p.sni ?? p.host,
          'publicKey': p.realityPublicKey,
          'shortId': p.realityShortId ?? '',
          if (p.realitySpiderX != null) 'spiderX': p.realitySpiderX,
          'fingerprint': p.fingerprint ?? 'chrome',
        };
      case Security.tls:
        s['security'] = 'tls';
        s['tlsSettings'] = {
          'serverName': p.sni ?? p.host,
          'allowInsecure': p.allowInsecure,
          if (p.alpn.isNotEmpty) 'alpn': p.alpn,
          if (p.fingerprint != null) 'fingerprint': p.fingerprint,
        };
      case Security.none:
        break;
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
        s['xhttpSettings'] = {
          'path': p.path ?? '/',
          'host': p.host,
          'mode': p.rawParams['mode'] ?? 'auto',
        };
      case Transport.tcp:
      case Transport.quic:
      case Transport.none:
        break;
    }
    return s;
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
