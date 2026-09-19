// v0.4.7 §loop-fix — the :xray child process has NO VpnService.protect hook
// (gomobile libv2ray is banned next to libbox's go.Seq), so its sockets are
// uid-routed into the TUN like any other app traffic. The fix: front-config
// route rules `ip_cidr → direct` for every IP the child dials directly, so
// its traffic escapes through the front engine's PROTECTED dialer instead of
// looping into the child's own SOCKS listener (device evidence 2026-09-17:
// child outbound source fdfe:dcba:9876::1 = the TUN's own address, dying
// with `software caused connection abort`).
//
// These tests pin the bypass-cidr SHAPING (pure function) and the front
// config SHAPE (rules placed before user rules / final, direct outbound
// referenced only by ip_is_private otherwise).
import 'package:flutter_test/flutter_test.dart';

import 'package:nexus/core/configgen/singbox_config_generator.dart';
import 'package:nexus/core/configgen/xray_config_generator.dart';
import 'package:nexus/domain/entities/proxy_profile.dart';
import 'package:nexus/routing/routing_models.dart';

ProxyProfile _xhttpNode({String server = '45.13.38.166'}) => ProxyProfile(
      id: 'xhttp-bypass-test',
      name: 'xhttp bypass node',
      protocol: ProxyProtocol.vless,
      server: server,
      port: 443,
      core: CoreKind.unknown,
      transport: Transport.xhttp,
      rawParams: {'type': 'xhttp', 'security': 'reality'},
    );

void main() {
  group('XrayConfigGenerator.childDialBypassCidrs', () {
    test('pinned server IPv4 becomes a /32 cidr', () {
      final p = _xhttpNode();
      final cidrs = XrayConfigGenerator.childDialBypassCidrs(p);
      expect(cidrs, contains('45.13.38.166/32'));
    });

    test('IPv6 server becomes a /128 cidr', () {
      final p = _xhttpNode(server: '2a0c:9f00:1234::1');
      final cidrs = XrayConfigGenerator.childDialBypassCidrs(p);
      expect(cidrs, contains('2a0c:9f00:1234::1/128'));
    });

    test('loopback / private / CGNAT servers are never bypassed', () {
      for (final bad in ['127.0.0.1', '10.0.0.8', '192.168.1.4', '100.99.2.3']) {
        final cidrs =
            XrayConfigGenerator.childDialBypassCidrs(_xhttpNode(server: bad));
        expect(cidrs, isNot(contains('$bad/32')), reason: bad);
      }
    });

    test('hostname server is skipped (no bogus prefix)', () {
      final cidrs = XrayConfigGenerator.childDialBypassCidrs(
          _xhttpNode(server: 'cdnuk.hixyz.ir'));
      expect(cidrs.where((c) => c.contains('hixyz')), isEmpty);
    });

    test('explicit DNS entries contribute their literal IPs', () {
      final cidrs = XrayConfigGenerator.childDialBypassCidrs(
        _xhttpNode(),
        dns: DnsSettings(
          mode: DnsMode.custom,
          primary: '178.22.122.100',
          secondary: '5.202.100.100:53',
          remoteOverride: 'https://dns.google/dns-query',
        ),
      );
      expect(cidrs, contains('178.22.122.100/32'));
      expect(cidrs, contains('5.202.100.100/32')); // :port stripped
      expect(cidrs.where((c) => c.contains('dns.google')), isEmpty);
    });

    test('output is sorted and deduplicated', () {
      final cidrs = XrayConfigGenerator.childDialBypassCidrs(
        _xhttpNode(),
        dns: DnsSettings(mode: DnsMode.custom, primary: '45.13.38.166'),
      );
      final sorted = [...cidrs]..sort();
      expect(cidrs, sorted);
      expect(cidrs.toSet().length, cidrs.length);
    });
  });

  group('front sing-box config carries the child bypass rules', () {
    final routing = RoutingProfile(id: 'r', name: 'r', rules: const []);
    test('bypassCidrs become direct rules placed before the final', () {
      final cfg = SingBoxConfigGenerator().generate(
        runnableProfiles: [],
        routing: routing,
        dns: DnsSettings(),
        selectedTag: 'direct',
        socksUpstreams: const {},
        bypassCidrs: const ['45.13.38.166/32', '2a0c:9f00:1234::1/128'],
      );
      final rules = (cfg['route']['rules'] as List).cast<Map<String, dynamic>>();
      final bypassRules = rules
          .where((r) => r['ip_cidr'] != null && r['outbound'] == 'direct')
          .toList();
      expect(bypassRules.map((r) => (r['ip_cidr'] as List).first),
          containsAll(['45.13.38.166/32', '2a0c:9f00:1234::1/128']));
      // They must precede the private rule? No — AFTER ip_is_private but
      // BEFORE user rules/final. Verify position: after the private rule,
      // before any user rule (routing defaults add none here).
      final privateIdx =
          rules.indexWhere((r) => r['ip_is_private'] != null || r['ip_is_private'] == true);
      final firstBypass = rules.indexOf(bypassRules.first);
      expect(firstBypass, greaterThan(privateIdx));
      expect(cfg['route']['final'], 'proxy');
    });

    test('no bypassCidrs → no ip_cidr direct rules (desktop unchanged)', () {
      final cfg = SingBoxConfigGenerator().generate(
        runnableProfiles: [],
        routing: routing,
        dns: DnsSettings(),
        selectedTag: 'direct',
      );
      final rules = (cfg['route']['rules'] as List).cast<Map<String, dynamic>>();
      expect(rules.where((r) => r['ip_cidr'] != null), isEmpty);
    });
  });
}
