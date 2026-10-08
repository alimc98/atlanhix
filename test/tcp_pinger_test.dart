import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/application/tcp_pinger.dart';
import 'package:nexus/core/health/test_scheduler.dart';
import 'package:nexus/domain/entities/health.dart';
import 'package:nexus/domain/entities/proxy_profile.dart';

/// v0.6.0 §tcping — raw TCP handshake pinger + the display-only
/// `lastTcpMs` stream in HealthStore.
ProxyProfile _node({String id = 'n1', int port = 0}) => ProxyProfile(
      id: id,
      name: 'Node $id',
      server: '127.0.0.1',
      port: port,
      protocol: ProxyProtocol.vless,
    );

void main() {
  group('TcpPinger (v0.6.0 §tcping)', () {
    test('measures a live TCP handshake in ms', () async {
      final server = await ServerSocket.bind('127.0.0.1', 0);
      try {
        final r = await TcpPinger().ping(_node(port: server.port));
        expect(r.ok, isTrue);
        expect(r.latencyMs, isNotNull);
        expect(r.latencyMs!, lessThan(4000));
      } finally {
        await server.close();
      }
    });

    test('reports failure for a dead port (never hangs)', () async {
      // Port 1 on loopback is closed in every sane test environment.
      final r = await TcpPinger(timeout: const Duration(milliseconds: 800))
          .ping(_node(port: 1));
      expect(r.ok, isFalse);
      expect(r.latencyMs, isNull);
    }, timeout: const Timeout(Duration(seconds: 10)));

    test('pingBatch maps results by profile id', () async {
      final server = await ServerSocket.bind('127.0.0.1', 0);
      try {
        final res = await TcpPinger().pingBatch([
          _node(id: 'a', port: server.port),
          _node(id: 'dead', port: 1),
        ]);
        expect(res['a']?.ok, isTrue);
        expect(res['dead']?.ok, isFalse);
      } finally {
        await server.close();
      }
    }, timeout: const Timeout(Duration(seconds: 10)));
  });

  group('HealthStore lastTcpMs (v0.6.0 §tcping)', () {
    test('a TCP-only record feeds lastTcpMs but NOT latency stats', () {
      final store = HealthStore();
      store.record(HealthRecord(
        profileId: 'n1',
        at: DateTime.now(),
        ok: true,
        handshakeMs: 42, // TCP-only: latencyMs stays null on purpose
      ));
      final s = store.statsOf('n1')!;
      expect(s.lastTcpMs, 42);
      expect(s.lastLatencyMs, isNull); // URL stream untouched
      expect(s.avgLatencyMs, isNull);
      expect(s.state, NodeHealth.healthy);
    });

    test('a URL record (latencyMs) never overwrites lastTcpMs', () {
      final store = HealthStore();
      store.record(HealthRecord(
        profileId: 'n1',
        at: DateTime.now(),
        ok: true,
        handshakeMs: 42,
      ));
      store.record(HealthRecord(
        profileId: 'n1',
        at: DateTime.now(),
        ok: true,
        latencyMs: 900, // real URL test through the tunnel
        handshakeMs: 50,
      ));
      final s = store.statsOf('n1')!;
      expect(s.lastTcpMs, 42); // still the raw handshake number
      expect(s.lastLatencyMs, 900); // and the real URL delay
    });

    test('a failed TCP record marks the node timeout (honest dead)', () {
      final store = HealthStore();
      store.record(HealthRecord(
        profileId: 'n1',
        at: DateTime.now(),
        ok: false,
        errorKind: 'timeout',
      ));
      final s = store.statsOf('n1')!;
      expect(s.state, NodeHealth.timeout);
      expect(s.consecutiveFailures, 1);
    });
  });
}
