// Regression coverage for the v0.4.6 desktop-Xray DNS failure (2026-09).
//
// Failure shape: Xray generated with `dns.servers: ['1.1.1.1', 'localhost']`.
// Verified against Xray-core app/dns/dns.go: without EnableParallelQuery
// (default FALSE per infra/conf/dns.go) the DNS module runs a SERIAL query
// whose server order starts ROUND-ROBIN (sortClients). So:
//   * 1.1.1.1 is dead on IR mobile data (measured, Mi 9T 2026-09-13) and the
//     carrier `localhost` resolver poison-answers blocked domains with a
//     private sinkhole (10.10.34.x) — the round-robin hands the lookup to
//     the poisoned server every other query;
//   * domain-addressed nodes (every xhttp CDN front) then dial a dead IP
//     and the TLS handshake dies — while the SAME nodes connect on the
//     Android path, which pins a clean-resolved IP before engine start.
//
// Contract: the generated Xray DNS object carries ONLY clean, platform-
// appropriate resolvers, never `localhost`.
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/configgen/xray_config_generator.dart';
import 'package:nexus/domain/entities/proxy_profile.dart';
import 'package:nexus/routing/builtin_profiles.dart';

ProxyProfile _vlessXhttpTls() => ProxyProfile(
      id: 'xdns-1',
      name: 'xhttp dns node',
      server: 'cdn.example.com',
      port: 443,
      protocol: ProxyProtocol.vless,
      transport: Transport.xhttp,
      security: Security.tls,
      uuid: 'u1',
      sni: 'cdn.example.com',
      host: 'cdn.example.com',
      path: '/api',
      rawParams: {'mode': 'auto', 'type': 'xhttp'},
    );

void main() {
  group('Xray DNS shape (desktop poison-race regression)', () {
    final gen = XrayConfigGenerator();

    List<String> serversOf(Map<String, dynamic> cfg) =>
        List<String>.from(((cfg['dns'] as Map)['servers'] as List));

    test('default config never contains localhost', () {
      final cfg = gen.generate(
        profile: _vlessXhttpTls(),
        localSocksPort: 2081,
        routing: BuiltinRoutingProfiles.all().first,
      );
      expect(serversOf(cfg), isNot(contains('localhost')));
    });

    test('default servers are the clean resolver pair (non-empty, unique)',
        () {
      final cfg = gen.generate(
        profile: _vlessXhttpTls(),
        localSocksPort: 2081,
        routing: BuiltinRoutingProfiles.all().first,
      );
      final servers = serversOf(cfg);
      expect(servers, isNotEmpty);
      expect(servers.length, XrayConfigGenerator.defaultCleanServers.length);
      expect(servers.toSet().length, servers.length,
          reason: 'duplicate resolvers only add latency');
    });

    test('explicit dnsServer override wins and stays de-duplicated', () {
      final cfg = gen.generate(
        profile: _vlessXhttpTls(),
        localSocksPort: 2081,
        routing: BuiltinRoutingProfiles.all().first,
        dnsServer: '8.8.8.8',
      );
      final servers = serversOf(cfg);
      expect(servers.first, '8.8.8.8');
      expect(servers.where((s) => s == '8.8.8.8').length, 1);
      expect(servers, isNot(contains('localhost')));
    });

    test('UseIPv4 strategy is preserved (AAAA sinkhole class)', () {
      final cfg = gen.generate(
        profile: _vlessXhttpTls(),
        localSocksPort: 2081,
        routing: BuiltinRoutingProfiles.all().first,
      );
      expect((cfg['dns'] as Map)['queryStrategy'], 'UseIPv4');
    });
  });
}
