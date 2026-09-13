import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/dns_scanner.dart';

void main() {
  group('DnsScanner pure logic', () {
    test('private/CGNAT/benchmark ranges are flagged non-public', () {
      for (final ip in [
        '10.10.34.36', // the measured MCI sinkhole
        '172.16.0.1',
        '192.168.1.1',
        '127.0.0.1',
        '169.254.1.1',
        '100.64.0.1', // CGNAT
        '198.18.0.1', // benchmark (our fakeip range)
        'fd00::1',
      ]) {
        expect(DnsScanner.isNonPublic(ip), isTrue, reason: '$ip must be non-public');
      }
      for (final ip in [
        '192.227.211.124',
        '1.1.1.1',
        '8.8.8.8',
        '2001:4860::1'
      ]) {
        expect(DnsScanner.isNonPublic(ip), isFalse, reason: '$ip must be public');
      }
    });

    test('probe target label renders transports honestly', () {
      const udp = DnsProbeTarget(name: 'X', host: '1.2.3.4');
      expect(udp.label, 'X (UDP:53)');
      const tcp =
          DnsProbeTarget(name: 'X', host: '1.2.3.4', transport: DnsTransport.tcp);
      expect(tcp.label, 'X (TCP:53)');
      const doh = DnsProbeTarget(
          name: 'X', host: 'x.doh', transport: DnsTransport.doh, port: 443);
      expect(doh.label, 'X (DoH:443)');
    });
  });

  // Real network only when reachable; never fails offline CI on a closed
  // laptop — the verdict is printed for the operator instead.
  test('live probe: Cloudflare UDP must answer clean', () async {
    final r = await DnsScanner().probe(const DnsProbeTarget(
        name: 'Cloudflare', host: '1.1.1.1'));
    // ignore: avoid_print
    print('LIVE PROBE: $r');
    if (r.reachable) {
      expect(r.verdict, DnsPoisonVerdict.clean);
    }
  }, timeout: const Timeout(Duration(seconds: 15)));
}
