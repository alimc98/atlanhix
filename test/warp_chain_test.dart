import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/configgen/singbox_config_generator.dart';
import 'package:nexus/core/health/latency_tester.dart';
import 'package:nexus/core/runtime/binary_manager.dart';
import 'package:nexus/core/runtime/core_manager.dart';
import 'package:nexus/core/runtime/core_runtime.dart';
import 'package:nexus/domain/entities/proxy_profile.dart';
import 'package:nexus/routing/builtin_profiles.dart';
import 'package:nexus/routing/routing_models.dart';
import 'package:nexus/warp/warp_http.dart';
import 'package:nexus/warp/warp_registrar.dart';


/// v0.3.0 §8/§9 — WARP traffic chaining.
///
/// Tier 1 (always): chain materialization in the generated config.
/// Tier 2 (real binary): `sing-box check` accepts the chained config.
/// Tier 3 (opt-in, ATLANHIX_WARP_E2E=1): real Cloudflare registration + live
/// chain probe + egress identity check. No credentials are committed.
ProxyProfile _ssNode(String id, String server, int port) => ProxyProfile(
      id: id,
      name: 'node-$id',
      server: server,
      port: port,
      protocol: ProxyProtocol.shadowsocks,
      ssMethod: 'aes-128-gcm',
      password: 'chain-pass-1',
    );

WarpAccount _fakeAccount() => WarpAccount(
      deviceId: 'test-device',
      token: 't',
      privateKey: 'kJ3xXyQ7Wm9pR5tN2vB8sL4cH6dF1aG0eIuO9qZw8kA=',
      peerPublicKey: 'qF2FiW09KjRWd7pF5bEy9XU9pHc4uTMvE1S0aZnQVXM=',
      endpointV4: '162.159.193.10:2408',
      addressV4: '172.16.0.2/32',
      clientId: 'AQIDBAUGBw==',
    );

void main() {
  group('§8 WARP chain materialization (unit)', () {
    final gen = SingBoxConfigGenerator();
    final node = _ssNode('n1', '203.0.113.10', 8388);

    test('warp-outside: every node outbound dials through the warp endpoint',
        () {
      final cfg = gen.generate(
        runnableProfiles: [node],
        routing: BuiltinRoutingProfiles.all().first,
        dns: DnsSettings(mode: DnsMode.automatic),
        selectedTag: 'node:n1',
        warpProfile: WarpRegistrar.profileFor(_fakeAccount()),
        chainWarpOutside: true,
      );
      final endpoints = cfg['endpoints'] as List;
      final warp = endpoints.firstWhere((e) => e['tag'] == 'warp') as Map;
      expect(warp['type'], 'wireguard');
      expect(warp['address'], contains('172.16.0.2/32'));
      expect(warp['peers'].first['address'] as String,
          startsWith('162.159.193.10'));

      final stub = (cfg['outbounds'] as List)
          .firstWhere((o) => o['tag'] == 'node:n1') as Map;
      expect(stub['detour'], 'warp',
          reason: 'node traffic must be dialed THROUGH the warp endpoint');
    });

    test('warp-inside direction is selectable', () {
      final cfg = gen.generate(
        runnableProfiles: [node],
        routing: BuiltinRoutingProfiles.all().first,
        dns: DnsSettings(mode: DnsMode.automatic),
        selectedTag: 'node:n1',
        warpProfile: WarpRegistrar.profileFor(_fakeAccount()),
        chainWarpOutside: false,
      );
      final stub = (cfg['outbounds'] as List)
          .firstWhere((o) => o['tag'] == 'node:n1') as Map;
      expect(stub.containsKey('detour'), isFalse,
          reason: 'inside-direction: node dials directly');
    });

    test('no warpProfile → plain topology, no detour anywhere', () {
      final cfg = gen.generate(
        runnableProfiles: [node],
        routing: BuiltinRoutingProfiles.all().first,
        dns: DnsSettings(mode: DnsMode.automatic),
        selectedTag: 'node:n1',
      );
      expect(cfg.containsKey('endpoints'), isFalse);
      final stub = (cfg['outbounds'] as List)
          .firstWhere((o) => o['tag'] == 'node:n1') as Map;
      expect(stub.containsKey('detour'), isFalse);
    });
  });

  test('§9 tier2: sing-box accepts the chained config (real binary check)',
      () async {
    final coresDir = Directory(
        '${Directory.current.path}${Platform.pathSeparator}cores'
        '${Platform.pathSeparator}${BinaryManager.platformDirName()}');
    if (!coresDir.existsSync()) return;
    final bm = BinaryManager(appDir: coresDir);
    final sb = await bm.inspect(CoreBinaryKind.singbox);
    if (sb.status != 'available') return;

    final mgr = CoreManager(
      binaryManager: bm,
      workDir: await Directory.systemTemp.createTemp('nexus-warp-chain'),
    );
    addTearDown(() => mgr.dispose());
    await mgr.prepare();
    final node = _ssNode('n1', '203.0.113.10', 8388);
    final v = await mgr.front.validateAll(
      profiles: [node],
      selectedProfileId: node.id,
      routing: BuiltinRoutingProfiles.all().first,
      dns: DnsSettings(mode: DnsMode.automatic),
      warpProfile: WarpRegistrar.profileFor(_fakeAccount()),
      chainWarpOutside: true,
    );
    expect(v.ok, isTrue,
        reason: 'chained config rejected: ${v.output ?? v.message}');
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('§9 tier3 (ATLANHIX_WARP_E2E=1): live WARP chain carries traffic',
      () async {
    if (Platform.environment['ATLANHIX_WARP_E2E'] != '1') {
      // ignore: avoid_print
      print('SKIPPED: set ATLANHIX_WARP_E2E=1 for the live WARP chain E2E');
      return;
    }
    final coresDir = Directory(
        '${Directory.current.path}${Platform.pathSeparator}cores'
        '${Platform.pathSeparator}${BinaryManager.platformDirName()}');
    if (!coresDir.existsSync()) return;
    final bm = BinaryManager(appDir: coresDir);
    final sb = await bm.inspect(CoreBinaryKind.singbox);
    if (sb.status != 'available') return;

    // Real device registration against the Cloudflare API (no stored creds).
    final acct = await WarpRegistrar(http: HttpWarpApi()).register();
    final warpProfile = WarpRegistrar.profileFor(acct);

    final mgr = CoreManager(
      binaryManager: bm,
      workDir: await Directory.systemTemp.createTemp('nexus-warp-live'),
    );
    addTearDown(() => mgr.dispose());
    // The chain under test is warp (outer) — the node hop is exercised by
    // tier3-xray; here we prove the warp endpoint itself tunnels traffic.
    final node = _ssNode('n1', '162.159.193.10', 2408);
    final start = await mgr.startFor(
      node,
      all: [node],
      routing: BuiltinRoutingProfiles.all().first,
      dns: DnsSettings(mode: DnsMode.automatic),
      warpProfile: warpProfile,
      chainWarpOutside: true,
    );
    expect(start.ok, isTrue,
        reason: 'chained engine start failed: ${start.message}');

    final tester = LatencyTester();
    final trace = await tester.testHttpViaSocksProxy(
        '127.0.0.1', mgr.front.mixedPort,
        'https://www.cloudflare.com/cdn-cgi/trace',
        timeout: const Duration(seconds: 20));
    expect(trace.ok, isTrue,
        reason: 'probe through WARP chain failed: ${trace.errorKind}');
    expect(trace.detail, isNotNull);
    expect(trace.detail!, contains('warp='),
        reason: 'egress must be a WARP edge');
    // ignore: avoid_print
    print('WARP E2E trace: ${trace.detail!.split('\n').firstWhere(
        (l) => l.startsWith('warp='), orElse: () => 'warp=unknown')}');
    await mgr.stop();
  }, timeout: const Timeout(Duration(minutes: 3)));
}
