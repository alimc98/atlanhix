import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/configgen/mihomo_config_generator.dart';
import 'package:nexus/domain/entities/proxy_profile.dart';
import 'package:nexus/protocols/adapters/clash_yaml.dart';
import 'package:nexus/routing/routing_models.dart';

/// v0.6.0 §xhttp-yaml — the "xhttp reality goes over tcp on mihomo" bug.
///
/// Root cause: the Clash YAML adapter's `_transport` switch had no
/// xhttp/splithttp case, so a subscription node emitted by a panel as
/// `network: xhttp` parsed to Transport.tcp AND its `xhttp-opts` block
/// (path/host/mode/xmux/padding) was dropped entirely. mihomo then received
/// a plain-TCP vless node — the exact user report. These pins lock the
/// parse → generate round-trip end to end.
const _realityXhttpYaml = '''
proxies:
  - name: XHTTP Reality
    type: vless
    server: 203.0.113.10
    port: 443
    uuid: b831381d-6324-4d53-ad4f-8cda48b30811
    network: xhttp
    tls: true
    servername: www.microsoft.com
    client-fingerprint: chrome
    reality-opts:
      public-key: SbVKOEMjK0sIlbwg4akyBg5mL5KZwwB-ed4eEE7YnRc
      short-id: "6ba85179"
    xhttp-opts:
      path: /upload
      host: cdn.example.com
      mode: stream-one
      x-padding-bytes: "100-200"
''';

final _routing = RoutingProfile(id: 'r', name: 'r', rules: []);
final _dns = DnsSettings(mode: DnsMode.automatic);

void main() {
  group('Clash YAML parser: network xhttp/splithttp (v0.6.0)', () {
    test('network: xhttp parses to Transport.xhttp — never tcp', () {
      final p = ClashYamlParser().parse(_realityXhttpYaml);
      expect(p.skipped, isEmpty);
      final node = p.profiles.single;
      expect(node.transport, Transport.xhttp);
      expect(node.security, Security.reality);
      expect(node.sni, 'www.microsoft.com');
      expect(node.path, '/upload');
      expect(node.host, 'cdn.example.com');
    });

    test('network: splithttp (Xray spelling) parses to Transport.xhttp', () {
      final p = ClashYamlParser().parse(_realityXhttpYaml
          .replaceFirst('network: xhttp', 'network: splithttp'));
      expect(p.profiles.single.transport, Transport.xhttp);
    });

    test('xhttp-opts survive into rawParams (kebab + link dialect + extra)',
        () {
      final p = ClashYamlParser().parse(_realityXhttpYaml);
      final r = p.profiles.single.rawParams;
      expect(r['mode'], 'stream-one');
      expect(r['x-padding-bytes'], '100-200');
      expect(r['xPaddingBytes'], '100-200'); // link dialect mirror
      expect(r['extra'], isNotNull);
      final extra = jsonDecode(r['extra']!) as Map<String, dynamic>;
      expect(extra['mode'], 'stream-one');
      expect(extra['path'], '/upload');
    });

    test('ws transport keeps parsing to ws (no regression)', () {
      final p = ClashYamlParser().parse('''
proxies:
  - name: WS node
    type: vless
    server: 203.0.113.11
    port: 443
    uuid: uuid-ws
    network: ws
    tls: true
    ws-opts:
      path: /wspath
      headers:
        Host: ws.example.com
''');
      final node = p.profiles.single;
      expect(node.transport, Transport.ws);
      expect(node.path, '/wspath');
      expect(node.host, 'ws.example.com');
      expect(node.rawParams, isEmpty);
    });

    test('tcp fallback still applies to unknown networks', () {
      final p = ClashYamlParser().parse('''
proxies:
  - name: Plain
    type: trojan
    server: 203.0.113.12
    port: 443
    password: pw
''');
      expect(p.profiles.single.transport, Transport.tcp);
    });
  });

  group('round-trip: parsed xhttp reality → mihomo config (v0.6.0)', () {
    test('generated node keeps network xhttp + full xhttp-opts', () {
      final parsed = ClashYamlParser().parse(_realityXhttpYaml);
      final node = parsed.profiles.single;
      final cfg = MihomoConfigGenerator.ports(mixedPort: 2081, apiPort: 9099)
          .build(
              profiles: [node],
              selectedId: node.id,
              routing: _routing,
              dns: _dns);
      final proxies = cfg['proxies'] as List;
      expect(proxies, isNotEmpty); // must NOT be dropped
      final px = proxies.first as Map<String, dynamic>;
      expect(px['type'], 'vless');
      expect(px['network'], 'xhttp');
      final opts = px['xhttp-opts'] as Map<String, dynamic>;
      expect(opts['path'], '/upload');
      expect(opts['host'], 'cdn.example.com');
      expect(opts['mode'], 'stream-one');
      expect(opts['x-padding-bytes'], '100-200');
      expect(px['tls'], true);
      expect((px['reality-opts'] as Map<dynamic, dynamic>)['public-key'],
          'SbVKOEMjK0sIlbwg4akyBg5mL5KZwwB-ed4eEE7YnRc');
      expect((px['reality-opts'] as Map<dynamic, dynamic>)['short-id'], '6ba85179');
    });

    test('ATX selector boots on the parsed xhttp node', () {
      final parsed = ClashYamlParser().parse(_realityXhttpYaml);
      final node = parsed.profiles.single;
      final cfg = MihomoConfigGenerator.ports(mixedPort: 2081, apiPort: 9099)
          .build(
              profiles: [node],
              selectedId: node.name,
              routing: _routing,
              dns: _dns);
      final groups = cfg['proxy-groups'] as List;
      final atx = groups.first as Map<String, dynamic>;
      expect(atx['type'], 'select');
      expect((atx['proxies'] as List).first, node.name);
    });

    test('reuse-settings (XMUX) survives parse → generate', () {
      final parsed = ClashYamlParser().parse('''
proxies:
  - name: XMUX node
    type: vless
    server: 203.0.113.13
    port: 443
    uuid: uuid-x
    network: xhttp
    tls: true
    xhttp-opts:
      path: /x
      mode: stream-up
      reuse-settings:
        maxConcurrency: "13-17"
        cMinReuse: "30000"
''');
      final node = parsed.profiles.single;
      expect(node.transport, Transport.xhttp);
      final cfg = MihomoConfigGenerator.ports(mixedPort: 2081, apiPort: 9099)
          .build(
              profiles: [node],
              selectedId: node.id,
              routing: _routing,
              dns: _dns);
      final px = (cfg['proxies'] as List).first as Map<String, dynamic>;
      final opts = px['xhttp-opts'] as Map<String, dynamic>;
      final reuse = opts['reuse-settings'];
      expect(reuse, isA<Map<dynamic, dynamic>>());
      expect((reuse as Map<dynamic, dynamic>)['maxConcurrency'], '13-17');
    });
  });
}
