import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/net/bootstrap_dns.dart';
import 'package:nexus/domain/entities/proxy_profile.dart';

ProxyProfile _profile({String server = 'ro.hixyz.ir', int port = 443}) {
  return ProxyProfile(
    id: 'ro-ss',
    name: 'ro-ss',
    server: server,
    port: port,
    protocol: ProxyProtocol.shadowsocks,
    transport: Transport.none,
    password: 'p@ss',
  );
}

void main() {
  group('BootstrapResolver.isPublicV4 — sinkhole rejection', () {
    test('accepts public unicast', () {
      expect(BootstrapResolver.isPublicV4('178.22.122.100'), isTrue);
      expect(BootstrapResolver.isPublicV4('192.227.211.124'), isTrue);
      expect(BootstrapResolver.isPublicV4('8.8.8.8'), isTrue);
    });

    test('rejects MCI poison shapes', () {
      expect(BootstrapResolver.isPublicV4('10.10.34.36'), isFalse);
      expect(BootstrapResolver.isPublicV4('100.64.5.6'), isFalse);
      expect(BootstrapResolver.isPublicV4('169.254.1.1'), isFalse);
      expect(BootstrapResolver.isPublicV4('127.0.0.1'), isFalse);
      expect(BootstrapResolver.isPublicV4('224.0.0.5'), isFalse);
      expect(BootstrapResolver.isPublicV4('2001:4188::1'), isFalse);
      expect(BootstrapResolver.isPublicV4('not-an-ip'), isFalse);
    });
  });

  group('BootstrapResolver — pin, cache, heal', () {
    test('returns a public pinned IP for a hostname', () async {
      var calls = 0;
      final r = BootstrapResolver(lookup: (host) async {
        calls++;
        return ['185.55.226.26'];
      });
      expect(await r.resolve('ro.hixyz.ir'), '185.55.226.26');
      // cached: a second connect does not re-resolve
      expect(await r.resolve('ro.hixyz.ir'), '185.55.226.26');
      expect(calls, 1);
    });

    test('sinkhole-only answers yield no pin', () async {
      final r = BootstrapResolver(lookup: (h) async => ['10.10.34.36']);
      expect(await r.resolve('n2.meta-design.ir'), isNull);
    });

    test('stale pin survives a failed re-resolve', () async {
      var first = true;
      final r = BootstrapResolver(
        ttl: Duration.zero, // always revalidate
        lookup: (h) async {
          if (first) {
            first = false;
            return ['8.8.8.8'];
          }
          return const <String>[];
        },
      );
      expect(await r.resolve('h'), '8.8.8.8');
      expect(await r.resolve('h'), '8.8.8.8'); // stale-while-error
    });

    test('evict forces a re-resolve', () async {
      var calls = 0;
      final r = BootstrapResolver(lookup: (h) async {
        calls++;
        return ['1.1.1.1'];
      });
      await r.resolve('h');
      r.evict('h');
      await r.resolve('h');
      expect(calls, 2);
    });

    test('addressFor passes through IP literals and empty servers', () async {
      final r = BootstrapResolver(lookup: (h) async => ['8.8.8.8']);
      expect(await r.addressFor(_profile(server: '192.227.211.124')), isNull);
      expect(await r.addressFor(_profile(server: '  ')), isNull);
    });

    test('concurrent resolves of one host share a single lookup', () async {
      var calls = 0;
      final r = BootstrapResolver(lookup: (h) async {
        calls++;
        await Future<void>.delayed(const Duration(milliseconds: 30));
        return ['4.2.2.0'];
      });
      final both = await Future.wait([r.resolve('h'), r.resolve('h')]);
      expect(both, ['4.2.2.0', '4.2.2.0']);
      expect(calls, 1);
    });
  });

  group('profile pinning preserves TLS identity', () {
    test('copyWith(server:) swaps endpoint, keeps SNI/Host', () {
      final p = _profile(server: 'ro.hixyz.ir').copyWith(
        server: '185.55.226.26',
        sni: 'ro.hixyz.ir',
        host: 'ro.hixyz.ir',
      );
      expect(p.server, '185.55.226.26');
      expect(p.sni, 'ro.hixyz.ir');
      expect(p.host, 'ro.hixyz.ir');
      expect(p.port, 443);
      expect(p.protocol, ProxyProtocol.shadowsocks);
    });
  });

  group('resolver pool hygiene', () {
    test('all pool entries are public IPv4', () {
      for (final s in BootstrapResolver.resolverPool) {
        expect(BootstrapResolver.isPublicV4(s), isTrue, reason: s);
      }
    });

    test('pool includes the MCI-reachable Shecan resolver', () {
      expect(BootstrapResolver.resolverPool, contains('178.22.122.100'));
    });
  });
}
