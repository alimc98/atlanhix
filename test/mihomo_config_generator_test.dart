import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/configgen/mihomo_config_generator.dart';
import 'package:nexus/domain/entities/proxy_profile.dart';
import 'package:nexus/routing/routing_models.dart';

ProxyProfile _xhttpNode({
  String? extra,
  Map<String, String> params = const {},
}) {
  final q = <String, String>{
    'type': 'xhttp',
    'security': 'tls',
    'sni': 'cdn.example.com',
    'fp': 'chrome',
    ...params,
    if (extra != null) 'extra': extra,
  };
  return ProxyProfile(
    id: 'x1',
    name: 'XHTTP node',
    server: '203.0.113.10',
    port: 443,
    protocol: ProxyProtocol.vless,
    transport: Transport.xhttp,
    security: Security.tls,
    uuid: '11111111-2222-3333-4444-555555555555',
    sni: 'cdn.example.com',
    fingerprint: 'chrome',
    path: '/upload',
    host: 'cdn.example.com',
    rawParams: q,
    rawConfig: 'vless://…',
    source: ProfileSource.uriImport,
  );
}

Map<String, dynamic> _opts(Map<String, dynamic> cfg) {
  final px = (cfg['proxies'] as List).first as Map<String, dynamic>;
  return px['xhttp-opts'] as Map<String, dynamic>;
}

void main() {
  final gen = MihomoConfigGenerator();

  group('xhttp translation (the FlClash-gap the user reported)', () {
    test('extra= JSON maps to mihomo field names, nested values preserved',
        () {
      final node = _xhttpNode(extra: jsonEncode({
        'mode': 'packet-up',
        'xPaddingBytes': '100-1000',
        'noGrpcHeader': true,
        'xmux': {
          'maxConcurrency': '16-32',
          'maxConnections': 3,
          'cMaxReuseTimes': 0,
          'hMaxRequestTimes': '600-900',
          'hKeepAlivePeriod': 0,
        },
        'downloadSettings': {
          'path': '/dl',
          'host': 'dl.example.com',
        },
      }));
      final cfg = gen.build(
        profiles: [node],
        selectedId: 'x1',
        routing: RoutingProfile(
            id: 'empty', name: 'empty', rules: const [], isBuiltin: true),
        dns: DnsSettings(mode: DnsMode.automatic),
      );
      final o = _opts(cfg);
      expect(o['mode'], 'packet-up');
      expect(o['x-padding-bytes'], '100-1000');
      expect(o['no-grpc-header'], true);
      // xmux → reuse-settings (mihomo's name for XMUX), nested intact.
      final reuse = o['reuse-settings'] as Map<String, dynamic>;
      expect(reuse['maxConcurrency'], '16-32');
      expect(reuse['maxConnections'], 3);
      // downloadSettings → download-settings, nested intact.
      final dl = o['download-settings'] as Map<String, dynamic>;
      expect(dl['path'], '/dl');
      expect(dl['host'], 'dl.example.com');
      // path/host from the profile fill in the basic fields.
      expect(o['path'], '/upload');
      expect(o['host'], 'cdn.example.com');
    });

    test('flat link params layer OVER extra= and old spellings normalize',
        () {
      final node = _xhttpNode(
        extra: jsonEncode({'xPaddingBytes': '100-1000', 'mode': 'packet'}),
        params: {'xpaddingkey': 'x_padding', 'mode': 'connect'},
      );
      final o = _opts(gen.build(
        profiles: [node],
        selectedId: 'x1',
        routing: RoutingProfile(
            id: 'e', name: 'e', rules: const [], isBuiltin: true),
        dns: DnsSettings(mode: DnsMode.automatic),
      ));
      // connect (INCY-era) → stream-one; the flat param won the layering.
      expect(o['mode'], 'stream-one');
      expect(o['x-padding-key'], 'x_padding');
      expect(o['x-padding-bytes'], '100-1000');
    });

    test('no extra at all: mode defaults to stream-one on plain TLS', () {
      final o = _opts(gen.build(
        profiles: [_xhttpNode()],
        selectedId: 'x1',
        routing: RoutingProfile(
            id: 'e', name: 'e', rules: const [], isBuiltin: true),
        dns: DnsSettings(mode: DnsMode.automatic),
      ));
      expect(o['mode'], 'stream-one');
      expect(o['path'], '/upload');
    });

    test('the generated config is valid JSON the engine accepts as YAML',
        () {
      final cfg = gen.build(
        profiles: [_xhttpNode(extra: jsonEncode({'mode': 'stream-up'}))],
        selectedId: 'x1',
        routing: RoutingProfile(
            id: 'e', name: 'e', rules: const [], isBuiltin: true),
        dns: DnsSettings(mode: DnsMode.automatic),
      );
      final text = gen.encode(cfg);
      expect(jsonDecode(text), isA<Map<String, dynamic>>());
    });
  });

  group('non-xhttp transports + routing', () {
    test('ws/reality translate cleanly', () {
      final p = ProxyProfile(
        id: 'w1',
        name: 'WS',
        server: 'a.b.c',
        port: 443,
        protocol: ProxyProtocol.vless,
        transport: Transport.ws,
        security: Security.reality,
        uuid: 'u1',
        sni: 'sni.example',
        realityPublicKey: 'pbk1',
        realityShortId: 'ab12',
        path: '/ws',
      );
      final cfg = gen.build(
        profiles: [p],
        selectedId: 'w1',
        routing: RoutingProfile(
            id: 'e', name: 'e', rules: const [], isBuiltin: true),
        dns: DnsSettings(mode: DnsMode.automatic),
      );
      final px = (cfg['proxies'] as List).single as Map<String, dynamic>;
      expect(px['network'], 'ws');
      expect(px['tls'], true);
      expect((px['reality-opts'] as Map)['public-key'], 'pbk1');
      expect((px['ws-opts'] as Map)['path'], '/ws');
    });

    test('app routing rules translate: suffix/ip/keyword + REJECT', () {
      final cfg = gen.build(
        profiles: const [],
        selectedId: '',
        routing: RoutingProfile(id: 'r', name: 'r', isBuiltin: true, rules: [
          RoutingRule(
              id: '1',
              matchType: RuleMatchType.domainSuffix,
              patterns: ['ir'],
              action: RoutingAction.direct),
          RoutingRule(
              id: '2',
              matchType: RuleMatchType.ipCidr,
              patterns: ['10.0.0.0/8'],
              action: RoutingAction.direct),
          RoutingRule(
              id: '3',
              matchType: RuleMatchType.domainKeyword,
              patterns: ['ads'],
              action: RoutingAction.block),
        ]),
        dns: DnsSettings(mode: DnsMode.automatic),
      );
      final rules = (cfg['rules'] as List).cast<String>();
      expect(rules.contains('DOMAIN-SUFFIX,ir,DIRECT'), isTrue);
      expect(rules.contains('IP-CIDR,10.0.0.0/8,DIRECT,no-resolve'), isTrue);
      expect(rules.contains('DOMAIN-KEYWORD,ads,REJECT'), isTrue);
      expect(rules.last, 'MATCH,ATX');
    });

    test('unsupported protocols are skipped (no crash, honest pool)', () {
      final p = ProxyProfile(
        id: 'm1',
        name: 'MDVPN',
        server: 'a.b',
        port: 1,
        protocol: ProxyProtocol.masterDnsVpn,
      );
      final cfg = gen.build(
        profiles: [p],
        selectedId: 'm1',
        routing: RoutingProfile(
            id: 'e', name: 'e', rules: const [], isBuiltin: true),
        dns: DnsSettings(mode: DnsMode.automatic),
      );
      expect(cfg['proxies'], isEmpty);
    });
  });
}
