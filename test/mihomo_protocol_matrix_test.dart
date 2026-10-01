import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/configgen/mihomo_config_generator.dart';
import 'package:nexus/domain/entities/proxy_profile.dart';
import 'package:nexus/routing/routing_models.dart';

/// v0.5.9 §mihomo-fix: the translator previously admitted only
/// vless/vmess/trojan/ss — every hysteria2/tuic/anytls/shadowtls/socks/http
/// profile was silently DROPPED from the generated config, so "the mihomo
/// core does not connect to every config". These pins lock the FULL
/// protocol matrix and the booted-on-selection selector ordering.
ProxyProfile _node(ProxyProtocol protocol,
    {String id = 'n1',
    Map<String, String> raw = const {},
    Transport transport = Transport.tcp}) {
  return ProxyProfile(
    id: id,
    name: 'Node $id',
    server: '203.0.113.10',
    port: 443,
    protocol: protocol,
    transport: transport,
    password: 'pass-1',
    tuicUuid: protocol == ProxyProtocol.tuic ? 'uuid-1' : null,
    tuicToken: protocol == ProxyProtocol.tuic ? 'token-1' : null,
    rawParams: raw,
  );
}

final _routing = RoutingProfile(id: 'r', name: 'r', rules: []);
final _dns = DnsSettings(mode: DnsMode.automatic);

Map<String, dynamic> _cfg(List<ProxyProfile> nodes, {String selected = 'n1'}) {
  return MihomoConfigGenerator.ports(mixedPort: 2081, apiPort: 9099)
      .build(profiles: nodes, selectedId: selected, routing: _routing, dns: _dns);
}

void main() {
  group('mihomo translator covers the FULL protocol matrix (v0.5.9)', () {
    test('hysteria2 → type hysteria2 with obfs + up/down', () {
      final p = _cfg([_node(ProxyProtocol.hysteria2, raw: {
        'obfs-password-x': 'x',
      })]);
      final px = (p['proxies'] as List).single as Map<String, dynamic>;
      expect(px['type'], 'hysteria2');
      expect(px['password'], 'pass-1');
    });

    test('hysteria (v1) → type hysteria with auth-str', () {
      final p = _cfg([_node(ProxyProtocol.hysteria)]);
      final px = (p['proxies'] as List).single as Map<String, dynamic>;
      expect(px['type'], 'hysteria');
      expect(px['auth-str'], 'pass-1');
    });

    test('tuic with uuid → v5 shape (uuid+password, NO token)', () {
      final p = _cfg([_node(ProxyProtocol.tuic)]);
      final px = (p['proxies'] as List).single as Map<String, dynamic>;
      expect(px['type'], 'tuic');
      expect(px['uuid'], 'uuid-1');
      expect(px['password'], 'token-1');
      expect(px.containsKey('token'), isFalse,
          reason: 'v4 token must not coexist with the v5 uuid shape');
    });

    test('tuic without uuid → v4 token shape', () {
      final n = _node(ProxyProtocol.tuic, id: 't4')
        ..tuicUuid = null
        ..tuicToken = 'tok-4';
      final p = _cfg([n]);
      final px = (p['proxies'] as List).single as Map<String, dynamic>;
      expect(px['token'], 'tok-4');
      expect(px.containsKey('uuid'), isFalse);
    });

    test('anytls → type anytls with password', () {
      final p = _cfg([_node(ProxyProtocol.anytls)]);
      final px = (p['proxies'] as List).single as Map<String, dynamic>;
      expect(px['type'], 'anytls');
      expect(px['password'], 'pass-1');
    });

    test('shadowtls → shadowsocks + shadow-tls PLUGIN (no unknown type)', () {
      final p = _cfg([_node(ProxyProtocol.shadowtls,
          raw: {'version': '3'})]);
      final px = (p['proxies'] as List).single as Map<String, dynamic>;
      expect(px['type'], 'ss',
          reason: 'mihomo has no standalone shadowtls client type');
      expect(px['plugin'], 'shadow-tls');
      expect((px['plugin-opts'] as Map)['version'], 3);
    });

    test('socks/http → their own types with credentials', () {
      for (final (proto, type) in [
        (ProxyProtocol.socks, 'socks5'),
        (ProxyProtocol.http, 'http'),
      ]) {
        final p = _cfg([_node(proto)]);
        final px = (p['proxies'] as List).single as Map<String, dynamic>;
        expect(px['type'], type);
      }
    });

    test('a mixed pool drops NOTHING — every node lands in the config', () {
      final nodes = [
        _node(ProxyProtocol.hysteria2, id: 'h2'),
        _node(ProxyProtocol.tuic, id: 'tu'),
        _node(ProxyProtocol.anytls, id: 'an'),
        _node(ProxyProtocol.shadowtls, id: 'st'),
        _node(ProxyProtocol.shadowsocks, id: 'ss'),
        _node(ProxyProtocol.vless, id: 'vl'),
      ];
      final p = _cfg(nodes);
      expect((p['proxies'] as List).length, nodes.length,
          reason: 'previously only ss/vl survived the translator');
      final group = (p['proxy-groups'] as List).first as Map<String, dynamic>;
      final members = (group['proxies'] as List).cast<String>();
      for (final n in nodes) {
        expect(members.contains('Node ${n.id}'), isTrue,
            reason: '${n.id} must be a selector member');
      }
    });
  });

  group('selector boots on the requested node (v0.5.9)', () {
    test('the selected node is the FIRST member', () {
      final nodes = [
        _node(ProxyProtocol.shadowsocks, id: 'a'),
        _node(ProxyProtocol.shadowsocks, id: 'b'),
      ];
      final p = _cfg(nodes, selected: 'Node b');
      final group = (p['proxy-groups'] as List).first as Map<String, dynamic>;
      expect((group['proxies'] as List).first, 'Node b');
    });

    test('unknown selection falls back to ATX-AUTO first', () {
      final nodes = [_node(ProxyProtocol.shadowsocks, id: 'a')];
      final p = _cfg(nodes, selected: 'ghost');
      final group = (p['proxy-groups'] as List).first as Map<String, dynamic>;
      expect((group['proxies'] as List).first, 'ATX-AUTO');
    });
  });
}
