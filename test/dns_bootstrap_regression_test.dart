// Regression coverage for the Mi 9T / MCI DNS-poisoning failure (2026-09-13).
//
// Device evidence: with route.default_domain_resolver pointing at the carrier
// `local` resolver, blocked domains — including the hysteria2 node host
// `us.hixyz.ir` — answered with a sinkhole IP (10.10.34.36 instead of the real
// 192.227.211.124). sing-box then dialed the sinkhole and the TLS handshake
// died: HEALTH_CHECK kind=tls "Connection terminated during handshake".
//
// Contract: outbound bootstrap must use the clean resolver for automatic and
// fakeip modes, while honoring an explicit user DNS choice.
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/configgen/singbox_config_generator.dart';
import 'package:nexus/routing/routing_models.dart';

void main() {
  group('default_domain_resolver bootstrap (DNS poisoning regression)', () {
    test('automatic mode bootstraps through the clean remote resolver', () {
      expect(
        SingBoxConfigGenerator.defaultResolver(DnsSettings(
            mode: DnsMode.automatic)),
        {'server': 'remote'},
      );
    });

    test('fakeip mode bootstraps through the clean remote resolver', () {
      expect(
        SingBoxConfigGenerator.defaultResolver(
            DnsSettings(mode: DnsMode.fakeip)),
        {'server': 'remote'},
      );
    });

    test('explicit system DNS is honored as selected (not silently upgraded)',
        () {
      expect(
        SingBoxConfigGenerator.defaultResolver(DnsSettings(
            mode: DnsMode.system)),
        {'server': 'local'},
      );
    });

    test('explicit custom/doh/dot choices keep their own resolver tag', () {
      expect(
        SingBoxConfigGenerator.defaultResolver(
            DnsSettings(mode: DnsMode.custom, primary: '9.9.9.9')),
        {'server': 'custom'},
      );
      expect(
        SingBoxConfigGenerator.defaultResolver(DnsSettings(
            mode: DnsMode.doh,
            dohUrl: 'https://dns.google/dns-query')),
        {'server': 'doh'},
      );
      expect(
        SingBoxConfigGenerator.defaultResolver(
            DnsSettings(mode: DnsMode.dot, dotHost: 'dns.google')),
        {'server': 'dot'},
      );
    });

    test('generated config: bootstrap resolver exists in dns.servers', () {
      final cfg = SingBoxConfigGenerator().generate(
        runnableProfiles: const [],
        routing: RoutingProfile(id: 'r', name: 'r', rules: const []),
        dns: DnsSettings(mode: DnsMode.automatic),
        options: const SingBoxOptions(enableTun: false),
        selectedTag: 'direct',
      );
      final route = cfg['route'] as Map<String, dynamic>;
      final resolver = route['default_domain_resolver'] as Map;
      expect(resolver['server'], isNot('local'));
      final servers = (cfg['dns'] as Map)['servers'] as List;
      expect(
        servers.any((s) => s['tag'] == resolver['server']),
        isTrue,
        reason: 'the bootstrap resolver must exist in dns.servers',
      );
    });
  });
}
