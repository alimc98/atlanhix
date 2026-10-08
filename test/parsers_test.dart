import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/domain/entities/proxy_profile.dart';
import 'package:nexus/domain/errors/app_error.dart';
import 'package:nexus/protocols/adapters/vmess.dart';
import 'package:nexus/protocols/adapters/vless.dart';
import 'package:nexus/protocols/adapters/trojan.dart';
import 'package:nexus/protocols/adapters/shadowsocks.dart';
import 'package:nexus/protocols/adapters/hysteria2.dart';
import 'package:nexus/protocols/adapters/wireguard_conf.dart';
import 'package:nexus/protocols/importer.dart';

String _b64Url(String s) {
  final bytes = Uint8List.fromList(utf8.encode(s));
  final std = base64Encode(bytes);
  return std.replaceAll('+', '-').replaceAll('/', '_').replaceAll('=', '');
}

String _b64(String s) => Uri.encodeComponent(_b64Url(s));

void main() {
  group('VMess parser', () {
    test('parses base64 JSON vmess link', () {
      const json =
          '{"ps":"Tokyo 01","add":"jp.example.com","port":"443","id":'
          '"b831381d-6324-4d53-ad4f-8cda48b30811","aid":"0","net":"ws",'
          '"host":"cdn.example.com","path":"/ws","tls":"tls"}';
      final link = 'vmess://${_b64(json)}';
      final p = VmessParser().parse(link);
      expect(p.protocol, ProxyProtocol.vmess);
      expect(p.server, 'jp.example.com');
      expect(p.port, 443);
      expect(p.uuid, 'b831381d-6324-4d53-ad4f-8cda48b30811');
      expect(p.transport, Transport.ws);
      expect(p.security, Security.tls);
      expect(p.host, 'cdn.example.com');
      expect(p.name, 'Tokyo 01');
    });

    test('rejects malformed vmess payload with typed error', () {
      expect(
        () => VmessParser().parse('vmess://!!!not-base64!!!'),
        throwsA(isA<ParseError>()),
      );
    });
  });

  group('VLESS parser', () {
    test('parses reality + xhttp link', () {
      final p = VlessParser().parse(
        'vless://b831381d-6324-4d53-ad4f-8cda48b30811@example.com:443'
        '?encryption=none&security=reality&sni=www.microsoft.com'
        '&fp=chrome&pbk=SbVKOEMjK0sIlbwg4akyBg5mL5KZwwB-ed4eEE7YnRc'
        '&sid=6ba85179&type=xhttp&flow=xtls-rprx-vision#London%2001',
      );
      expect(p.protocol, ProxyProtocol.vless);
      expect(p.security, Security.reality);
      expect(p.transport, Transport.xhttp);
      expect(p.flow, 'xtls-rprx-vision');
      expect(p.realityPublicKey, isNotEmpty);
      expect(p.sni, 'www.microsoft.com');
      expect(p.name, 'London 01');
    });

    test('round-trips through export', () {
      final p = VlessParser().parse(
        'vless://uuid-abc@example.com:8443?security=tls&type=ws&path=%2Fw'
        '&host=cdn.example.com#Test',
      );
      final exp = VlessParser().export(p);
      final reparsed = VlessParser().parse(exp);
      expect(reparsed.server, 'example.com');
      expect(reparsed.transport, Transport.ws);
      expect(reparsed.security, Security.tls);
    });
  });

  group('Trojan parser', () {
    test('parses trojan link with ws transport', () {
      final p = TrojanParser().parse(
        'trojan://pass123@t.example.com:443?security=tls&type=ws'
        '&path=%2Ftrojan&host=x.example.com#Trojan%20Node',
      );
      expect(p.protocol, ProxyProtocol.trojan);
      expect(p.password, 'pass123');
      expect(p.transport, Transport.ws);
    });
  });

  group('Shadowsocks parser', () {
    test('parses SIP002 format', () {
      final userInfo = _b64Url('aes-256-gcm:test-pass');
      final p = ShadowsocksParser()
          .parse('ss://$userInfo@ss.example.com:8388#SS%20Node');
      expect(p.protocol, ProxyProtocol.shadowsocks);
      expect(p.ssMethod, 'aes-256-gcm');
      expect(p.password, 'test-pass');
    });

    test('parses legacy base64 format', () {
      final body = _b64Url('chacha20-ietf-poly1305:pw@1.2.3.4:9999');
      final p = ShadowsocksParser().parse('ss://$body#legacy');
      expect(p.server, '1.2.3.4');
      expect(p.ssMethod, 'chacha20-ietf-poly1305');
    });
  });

  group('Hysteria2 parser', () {
    test('parses hysteria2 with obfs and bandwidth', () {
      final p = Hysteria2Parser().parse(
        'hysteria2://letmein@hy.example.com:443?sni=hy.example.com'
        '&insecure=1&obfs=salamander&obfs-password=obfspass'
        '&upmbps=100&downmbps=500&mport=20000-30000#HY2',
      );
      expect(p.protocol, ProxyProtocol.hysteria2);
      expect(p.password, 'letmein');
      expect(p.hysteriaObfsPassword, 'obfspass');
      expect(p.hysteriaUpMbps, 100);
      expect(p.rawParams['mport'], '20000-30000');
    });
  });


group('WireGuard/AWG parser', () {
  test('parses plain wg-quick conf', () {
    const conf = '''
[Interface]
PrivateKey = aBcDeFgHiJkLmNoPqRsTuVwXyZ0123456789abcdefg=
Address = 10.2.0.2/32
DNS = 1.1.1.1
MTU = 1420

[Peer]
PublicKey = 9lRrFVj0PNiRVI4jXln5h+2ruLw4TQ/1H7IxdP0KCVc=
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = vpn.example.com:51820
PersistentKeepalive = 25
''';
    final p = WireGuardConfParser().parse(conf, fileName: 'my-wg');
    expect(p.protocol, ProxyProtocol.wireguard);
    expect(p.server, 'vpn.example.com');
    expect(p.port, 51820);
    expect(p.wireguard!.dns, ['1.1.1.1']);
    expect(p.amnezia, isNull);
  });

  test('detects AmneziaWG parameters', () {
    const conf = '''
[Interface]
PrivateKey = aBcDeFgHiJkLmNoPqRsTuVwXyZ0123456789abcdefg=
Address = 10.2.0.2/32
Jc = 4
Jmin = 40
Jmax = 70
S1 = 86
S2 = 142
H1 = 1234567

[Peer]
PublicKey = 9lRrFVj0PNiRVI4jXln5h+2ruLw4TQ/1H7IxdP0KCVc=
AllowedIPs = 0.0.0.0/0
Endpoint = 1.2.3.4:51820
''';
    final p = WireGuardConfParser().parse(conf);
    expect(p.amnezia, isNotNull);
    expect(p.amnezia!.jc, 4);
    // v0.4.8: header values are strings (single value or "N-M" range per
    // AWG 3.x) — the endpoint builder emits int-or-String from them.
    expect(p.amnezia!.h1, '1234567');
    expect(p.core, CoreKind.amneziaWg);
    final exported = WireGuardConfParser().exportConf(p);
    expect(exported, contains('Jc = 4'));
    expect(exported, contains('H1 = 1234567'));
  });

  test('rejects conf without private key', () {
    expect(
      () => WireGuardConfParser().parse('[Interface]\n[Peer]\nEndpoint=x:1'),
      throwsA(isA<ParseError>()),
    );
  });
});

group('Multi-format importer', () {
  final importer = MultiFormatImporter();

  test('imports URI list', () {
    final r = importer.import(
      'vless://u@example.com:443?security=tls&type=tcp#a\n'
      'trojan://pw@t.example.com:443#b\n',
    );
    expect(r.profiles, hasLength(2));
    expect(r.format, SourceFormat.uriList);
  });

  test('imports base64 subscription body', () {
    final body = _b64Url(
      'trojan://pw@t1.example.com:443#n1\ntrojan://pw@t2.example.com:443#n2',
    );
    final r = importer.import(body);
    expect(r.format, SourceFormat.base64UriList);
    expect(r.profiles, hasLength(2));
  });

  test('imports Clash YAML with skip reporting', () {
    const yaml = '''
proxies:
  - name: ss-node
    type: ss
    server: 1.2.3.4
    port: 8388
    cipher: aes-256-gcm
    password: pw
  - name: weird-node
    type: mieru
    server: 1.2.3.4
    port: 1234
''';
    final r = importer.import(yaml);
    expect(r.profiles, hasLength(1));
    expect(r.profiles.first.protocol, ProxyProtocol.shadowsocks);
    expect(r.warnings, isNotEmpty, reason: 'unsupported types must be reported');
  });

  test('imports sing-box JSON with wireguard endpoint', () {
    const json = '''
{
  "outbounds": [
    {"type": "vless", "tag": "main", "server": "s.example.com",
     "server_port": 443, "uuid": "u1",
     "tls": {"enabled": true, "server_name": "s.example.com"}},
    {"type": "selector", "tag": "proxy", "outbounds": ["main"]}
  ],
  "endpoints": [
    {"type": "wireguard", "tag": "wg-ep", "private_key": "pk=",
     "peers": [{"address": "5.6.7.8", "port": 2408,
                "public_key": "ppk=", "allowed_ips": ["0.0.0.0/0"],
                "reserved": [1, 2, 3]}]}
  ]
}
''';
    final r = importer.import(json);
    expect(r.profiles, hasLength(2));
    final wg =
        r.profiles.firstWhere((p) => p.protocol == ProxyProtocol.wireguard);
    expect(wg.wireguard!.reserved, [1, 2, 3]);
    expect(wg.core, CoreKind.wireguardSingbox);
  });

  test('imports Xray JSON outbounds', () {
    const json = '''
{
  "inbounds": [{"port": 10808}],
  "outbounds": [
    {"protocol": "vless", "tag": "xr",
     "settings": {"vnext": [{"address": "x.example.com", "port": 443,
       "users": [{"id": "u1", "encryption": "none",
                  "flow": "xtls-rprx-vision"}]}]},
     "streamSettings": {"network": "tcp", "security": "reality",
       "realitySettings": {"serverName": "www.samsung.com",
         "publicKey": "pbk", "shortId": "ab12",
         "fingerprint": "chrome"}}},
    {"protocol": "freedom", "tag": "direct"}
  ]
}
''';
    final r = importer.import(json);
    expect(r.profiles, hasLength(1));
    final p = r.profiles.first;
    expect(p.security, Security.reality);
    expect(p.flow, 'xtls-rprx-vision');
    expect(p.realityShortId, 'ab12');
  });

  test('throws friendly error on unknown payload', () {
    expect(
      () => importer.import('this is not a config'),
      throwsA(isA<ParseError>()),
    );
  });
});
}

