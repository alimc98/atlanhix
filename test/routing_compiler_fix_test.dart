import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/configgen/mihomo_config_generator.dart';
import 'package:nexus/domain/entities/proxy_profile.dart';
import 'package:nexus/routing/routing_compiler.dart';
import 'package:nexus/routing/routing_models.dart';

/// v0.6.9 §routing-fix — the compiler bugs that turned routing rules into
/// dead configs:
///
///  1. `protocol` compiled to `port` in the sing-box dialect — a BitTorrent
///     rule became `port: ["bittorrent"]`, which `sing-box check -c`
///     REJECTS, killing the WHOLE config (every connect died).
///  2. `geoip` still compiled to the legacy `geoip` route-rule item —
///     removed in sing-box 1.12, so `check -c` failed with "unknown field"
///     for anyone carrying a geoip rule.
///  3. Xray dropped `protocol`/`network` rules entirely (silently lossy).
///  4. mihomo dropped `PROTOCOL`/`NETWORK` rules although its rule set has
///     them first-class (Clash lineage).
void main() {
  final compiler = RoutingCompiler();

  RoutingRule rule(RuleMatchType t, List<String> patterns,
          RoutingAction a) =>
      RoutingRule(
          id: 'r-${t.name}', matchType: t, patterns: patterns, action: a);

  group('sing-box dialect', () {
    test('protocol rules compile to `protocol`, never `port`', () {
      final profile = RoutingProfile(id: 't', name: 't', rules: [
        rule(RuleMatchType.protocol, ['bittorrent'], RoutingAction.direct),
      ]);
      final rules = compiler.singBoxRules(profile);
      expect(rules, hasLength(1));
      expect(rules.single['protocol'], ['bittorrent']);
      expect(rules.single.containsKey('port'), isFalse,
          reason: 'port: ["bittorrent"] is rejected by `sing-box check -c` '
              'and used to take the WHOLE config down');
    });

    test('geoip country codes are dropped — never the removed `geoip` key',
        () {
      final profile = RoutingProfile(id: 't', name: 't', rules: [
        rule(RuleMatchType.geoip, ['ir', 'us'], RoutingAction.direct),
      ]);
      final rules = compiler.singBoxRules(profile);
      expect(rules, isEmpty,
          reason: 'a country-only geoip rule cannot compile without a '
              'downloaded rule-set; dropping ONE rule keeps the rest of the '
              'config (and the tunnel) alive');
      for (final r in rules) {
        expect(r.containsKey('geoip'), isFalse);
      }
    });

    test('geoip rules carrying literal CIDRs still compile to ip_cidr', () {
      final profile = RoutingProfile(id: 't', name: 't', rules: [
        rule(RuleMatchType.geoip, ['10.0.0.0/8', 'ir'], RoutingAction.direct),
      ]);
      final rules = compiler.singBoxRules(profile);
      expect(rules.single['ip_cidr'], ['10.0.0.0/8']);
      expect(rules.single.containsKey('geoip'), isFalse);
    });

    test('network rules keep the `network` field', () {
      final profile = RoutingProfile(id: 't', name: 't', rules: [
        rule(RuleMatchType.network, ['udp'], RoutingAction.direct),
      ]);
      final rules = compiler.singBoxRules(profile);
      expect(rules.single['network'], ['udp']);
    });
  });

  group('Xray dialect', () {
    test('protocol and network rules are no longer dropped', () {
      final profile = RoutingProfile(id: 't', name: 't', rules: [
        rule(RuleMatchType.protocol, ['bittorrent'], RoutingAction.direct),
        rule(RuleMatchType.network, ['udp', 'tcp'], RoutingAction.direct),
        rule(RuleMatchType.package, ['com.example.app'],
            RoutingAction.direct),
      ]);
      final xr =
          compiler.xrayRules(profile, proxyTag: 'proxy', warpTag: 'warp');
      expect(xr[0]['protocol'], ['bittorrent']);
      expect(xr[0]['outboundTag'], 'direct');
      expect(xr[1]['network'], 'udp,tcp');
      expect(xr, hasLength(2),
          reason: 'package stays unexpressible in Xray route rules');
    });
  });

  group('mihomo dialect', () {
    test('PROTOCOL / NETWORK rule strings are emitted, GEOIP stays skipped',
        () {
      final node = ProxyProfile(
        id: 'a',
        name: 'Node a',
        server: '203.0.113.10',
        port: 443,
        protocol: ProxyProtocol.shadowsocks,
        ssMethod: 'aes-128-gcm',
        password: 'ss-pass-1',
      );
      final cfg = MihomoConfigGenerator().build(
        profiles: [node],
        selectedId: node.id,
        routing: RoutingProfile(id: 't', name: 't', rules: [
          rule(RuleMatchType.protocol, ['bittorrent'], RoutingAction.direct),
          rule(RuleMatchType.network, ['udp'], RoutingAction.direct),
          rule(RuleMatchType.geoip, ['ir'], RoutingAction.direct),
        ]),
        dns: DnsSettings(),
      );
      final rules = (cfg['rules'] as List).cast<String>();
      expect(rules, contains('PROTOCOL,bittorrent,DIRECT'));
      expect(rules, contains('NETWORK,udp,DIRECT'));
      expect(rules.where((r) => r.startsWith('GEOIP')), isEmpty,
          reason: 'GEOIP needs mihomo\'s auto-downloaded database — skipped '
              'honestly, never shipped as a rule that cannot evaluate');
    });
  });
}
