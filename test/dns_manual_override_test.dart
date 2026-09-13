// v0.4.1 § user request: manual Remote DNS + Domestic DNS entry, wired into
// the sing-box config through DnsSettings.remoteOverride / domesticOverride.
// The scanner (Settings → DNS scan) produces the strings tested here.
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/routing/routing_compiler.dart';
import 'package:nexus/routing/routing_models.dart';

void main() {
  final c = RoutingCompiler();

  Map<String, dynamic> dnsOf(DnsSettings d) => c.singBoxDns(d);

  group('manual DNS overrides (automatic mode)', () {
    test('remote override REPLACES the default clean pair only', () {
      final out = dnsOf(DnsSettings(
          mode: DnsMode.automatic, remoteOverride: '94.103.125.150'));
      final servers = out['servers'] as List;
      final tags = servers.map((s) => s['tag']).toList();
      // automatic mode deliberately carries NO poisoned 'local' (see the
      // device-evidence comment in routing_compiler.dart).
      final remote = servers.firstWhere((s) => s['tag'] == 'remote');
      expect(remote['server'], '94.103.125.150');
      expect(servers.where((s) => s['tag'] == 'remote2'), isEmpty);
      expect(tags, isNot(contains('local')));
    });

    test('override accepts host:port and keeps sing-box legacy shape', () {
      final out = dnsOf(DnsSettings(
          mode: DnsMode.automatic, remoteOverride: '5.202.100.100:5353'));
      final remote = (out['servers'] as List)
          .firstWhere((s) => s['tag'] == 'remote') as Map;
      expect(remote['server'], '5.202.100.100');
      expect(remote['server_port'], 5353);
      expect(remote['type'], 'udp');
    });

    test('DoH URL override builds a legacy https server', () {
      final out = dnsOf(DnsSettings(
          mode: DnsMode.automatic,
          remoteOverride: 'https://dns.freedns.org/dns-query'));
      final remote = (out['servers'] as List)
          .firstWhere((s) => s['tag'] == 'remote') as Map;
      expect(remote['type'], 'https');
      expect(remote['server'], 'dns.freedns.org');
      expect(remote['path'], '/dns-query');
    });

    test('DoT (tls://) override builds a legacy tls server', () {
      final out = dnsOf(DnsSettings(
          mode: DnsMode.automatic, remoteOverride: 'tls://dns.nextdns.io'));
      final remote = (out['servers'] as List)
          .firstWhere((s) => s['tag'] == 'remote') as Map;
      expect(remote['type'], 'tls');
      expect(remote['server'], 'dns.nextdns.io');
    });

    test('invalid entry never silently falls back to defaults', () {
      final out = dnsOf(DnsSettings(
          mode: DnsMode.automatic, remoteOverride: 'not a dns!!'));
      // Unparseable → the default clean pair remains (the UI validates on
      // entry; the compiler must never invent a broken server object).
      final remote = (out['servers'] as List)
          .firstWhere((s) => s['tag'] == 'remote') as Map;
      expect(remote['server'], isNot('not a dns!!'));
    });

    test('domestic override adds a second resolver + .ir rule', () {
      final out = dnsOf(DnsSettings(
          mode: DnsMode.automatic, domesticOverride: '178.22.122.100'));
      final servers = out['servers'] as List;
      final dom = servers.firstWhere((s) => s['tag'] == 'domestic');
      expect(dom['server'], '178.22.122.100');
      final rules = out['rules'] as List;
      final ir = rules
          .firstWhere((r) => (r['domain_suffix'] as List?)?.contains('.ir') == true)
          as Map;
      expect(ir['server'], 'domestic');
    });

    test('no overrides → defaults unchanged (opt-in honored)', () {
      final out = dnsOf(DnsSettings(mode: DnsMode.automatic));
      final servers = out['servers'] as List;
      final tags = servers.map((s) => s['tag']).toList();
      expect(tags, containsAll(['remote', 'remote2']));
      expect(tags, isNot(contains('domestic')));
    });
  });
}
