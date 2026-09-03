import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/health/latency_tester.dart';
import 'package:nexus/core/runtime/binary_manager.dart';
import 'package:nexus/core/runtime/core_manager.dart';
import 'package:nexus/core/runtime/core_process.dart';
import 'package:nexus/core/scoring/smart_connect.dart';
import 'package:nexus/domain/entities/health.dart';
import 'package:nexus/domain/entities/proxy_profile.dart';
import 'package:nexus/routing/builtin_profiles.dart';
import 'package:nexus/routing/routing_models.dart';

import 'helpers/mock_servers.dart';

ProxyProfile _ss(String id, String host, int port) => ProxyProfile(
      id: id,
      name: 'n-$id',
      server: host,
      port: port,
      protocol: ProxyProtocol.shadowsocks,
      ssMethod: 'aes-128-gcm',
      password: 'sc-pass-1',
    );

void main() {
  group('§14 Smart Connect selector (unit, deterministic)', () {
    test('pre-probe filters unreachable candidates, keeps ranking order',
        () async {
      // Real loopback listener = a candidate that answers TCP.
      final alive = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(alive.close);
      final sel = SmartConnectSelector();
      final a = _ss('a', '127.0.0.1', 1); // nothing listens on port 1
      final b = _ss('b', '127.0.0.1', alive.port);
      final out = await sel.preprobe([a, b]);
      expect(out.map((r) => r.$1.id), ['b'],
          reason: 'dead candidate must not reach engine-start attempts');
    });

    test('failed candidates are skipped while alternatives exist, then '
        'recover after expiry', () async {
      final sel =
          SmartConnectSelector(cooldown: const Duration(milliseconds: 120));
      final a = _ss('a', '203.0.113.1', 443);
      final b = _ss('b', '203.0.113.2', 443);
      final now = DateTime.now();
      sel.markFailed('a', now: now);
      final health = <String, NodeHealthStats>{};
      expect(
          sel.eligible([a, b], health, SelectionStrategy.smart, now: now)
              .map((p) => p.id),
          ['b'],
          reason: 'cooled-down candidate must be skipped when a '
              'non-cooling alternative exists');
      // After expiry the candidate is automatically eligible again.
      final later = now.add(const Duration(milliseconds: 200));
      expect(
          sel.eligible([a, b], health, SelectionStrategy.smart, now: later)
              .map((p) => p.id),
          ['a', 'b'],
          reason: 'cooldown expiry must restore the candidate');
    });

    test('concurrency is capped at maxConcurrentProbes', () async {
      var inFlight = 0;
      var peak = 0;
      final sel = SmartConnectSelector(
        maxConcurrentProbes: 3,
        maxPreprobeCandidates: 12,
        prober: (p, t) async {
          inFlight++;
          if (inFlight > peak) peak = inFlight;
          await Future<void>.delayed(const Duration(milliseconds: 30));
          inFlight--;
          return ProbeResult(ok: true, latencyMs: 5);
        },
      );
      final cands = List.generate(10, (i) => _ss('c$i', '10.0.0.$i', 443));
      final out = await sel.preprobe(cands);
      expect(peak, lessThanOrEqualTo(3), reason: 'probe concurrency cap');
      expect(out.length, 10);
      expect(out.map((r) => r.$1.id).toList(), cands.map((c) => c.id).toList(),
          reason: 'ranking order must be preserved');
    });

    test('all-cooling pool does not deadlock: soonest expiry first', () {
      final sel = SmartConnectSelector();
      final a = _ss('a', 'x', 1);
      final b = _ss('b', 'y', 1);
      final now = DateTime.now();
      sel.markFailed('a', now: now); // expires first
      sel.markFailed('b', now: now.add(const Duration(minutes: 10)));
      final out = sel.eligible([b, a], {}, SelectionStrategy.smart, now: now);
      expect(out.map((p) => p.id).toList(), ['a', 'b']);
    });
  });

  test('§14 E2E: dead+alive pool → pre-probe → alive node carries traffic',
      () async {
    final coresDir = Directory(
        '${Directory.current.path}${Platform.pathSeparator}cores'
        '${Platform.pathSeparator}${BinaryManager.platformDirName()}');
    if (!coresDir.existsSync()) return;
    final bm = BinaryManager(appDir: coresDir);
    final sbInfo = await bm.inspect(CoreBinaryKind.singbox);
    if (sbInfo.status != 'available') return;

    final http = MockHttpServer();
    await http.start();
    addTearDown(http.stop);

    final dir = await Directory.systemTemp.createTemp('nexus-sc-e2e');
    final port = await PortAllocator.freePort(prefer: 33021);
    final cfg = File('${dir.path}${Platform.pathSeparator}ss.json');
    await cfg.writeAsString(
        '{"inbounds":[{"type":"shadowsocks","tag":"ss-in","listen":"127.0.0.1",'
        '"listen_port":$port,"method":"aes-128-gcm","password":"sc-pass-1"}],'
        '"outbounds":[{"type":"direct","tag":"direct"}]}',
        flush: true);
    final ssServer =
        await ManagedProcess.start(sbInfo.path!, ['run', '-c', cfg.path]);
    addTearDown(() => ssServer.stop());

    final dead = _ss('dead', '127.0.0.1', 1);
    final alive = _ss('alive', '127.0.0.1', port);

    // 1) selection: real TCP pre-probe on the pool.
    final sel = SmartConnectSelector();
    final pool = await sel.preprobe([dead, alive]);
    expect(pool.map((r) => r.$1.id).toList(), ['alive'],
        reason: 'selection must reject the dead candidate via real probe');
    final winner = pool.first.$1;

    // 2) connection: real engine start + full HTTP verify.
    final mgr = CoreManager(
      binaryManager: bm,
      workDir: await Directory.systemTemp.createTemp('nexus-sc-mgr'),
    );
    addTearDown(() => mgr.dispose());
    final sw = Stopwatch()..start();
    final start = await mgr.startFor(
      winner,
      all: [dead, alive],
      routing: BuiltinRoutingProfiles.all().first,
      dns: DnsSettings(mode: DnsMode.automatic),
    );
    expect(start.ok, isTrue, reason: start.message);
    final probe = await LatencyTester().testHttpViaSocksProxy('127.0.0.1',
        mgr.front.mixedPort, 'http://127.0.0.1:${http.port}/smart',
        timeout: const Duration(seconds: 8));
    expect(probe.ok, isTrue, reason: '${probe.errorKind} ${probe.detail}');
    expect(http.requests, contains('GET /smart'));
    // ignore: avoid_print
    print('METRIC smart-connect select+connect: ${sw.elapsedMilliseconds} ms');
    await mgr.stop();
  }, timeout: const Timeout(Duration(seconds: 120)));
}
