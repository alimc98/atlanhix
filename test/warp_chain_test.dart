import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/configgen/singbox_config_generator.dart';
import 'package:nexus/core/health/latency_tester.dart';
import 'package:nexus/core/runtime/binary_manager.dart';
import 'package:nexus/core/runtime/core_manager.dart';
import 'package:nexus/domain/entities/proxy_profile.dart';
import 'package:nexus/protocols/adapters/wireguard_conf.dart';
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

  // v0.4.8 §user — the AWG-3.1 contract documented in
  // docs/android/V0.4.8_AMNEZIAWG_LIBBOX.md: an account carrying AWG params
  // MUST surface jc/jmin/jmax/s1/s2/h1..h4 on the wireguard endpoint (the
  // forked libbox executes them; upstream silently strips unknown fields —
  // these tests pin the CLIENT side of that handshake regardless of which
  // AAR is bundled). Plain WARP must stay byte-identical (no AWG keys).
  group('§30 AmneziaWG 3.1 params ride the wireguard endpoint', () {
    final gen = SingBoxConfigGenerator();
    final node = _ssNode('n1', '203.0.113.10', 8388);

    Map<String, dynamic> warpEndpoint(Map<String, dynamic> cfg) =>
        (cfg['endpoints'] as List)
            .firstWhere((e) => (e as Map)['tag'] == 'warp')
            as Map<String, dynamic>;

    test('account with AWG params emits jc/jmin/jmax/s1/s2/h1..h4', () {
      final a = _fakeAccount();
      final awg = WarpAccount(
        deviceId: a.deviceId,
        token: a.token,
        privateKey: a.privateKey,
        peerPublicKey: a.peerPublicKey,
        endpointV4: a.endpointV4,
        addressV4: a.addressV4,
        clientId: a.clientId,
        awgJc: 5,
        awgJmin: 50,
        awgJmax: 200,
        awgS1: 100,
        awgS2: 100,
        awgS3: 60,
        awgS4: 60,
        awgH1: '123456',
        awgH2: '234567',
        awgH3: '1000-2000',
        awgH4: '456789',
        awgI1: '<b 0x0102030405060708><r 12>',
        awgHpk: 'kF9uPQ0mSFRlZmF1bHRrZXltYXRlcmlhbDEyMzQ1Njc4OTA=',
      );
      expect(awg.hasAmneziaParams, isTrue);
      final cfg = gen.generate(
        runnableProfiles: [node],
        routing: BuiltinRoutingProfiles.all().first,
        dns: DnsSettings(mode: DnsMode.automatic),
        selectedTag: 'node:n1',
        warpProfile: WarpRegistrar.profileFor(awg),
        chainWarpOutside: true,
      );
      final w = warpEndpoint(cfg);
      expect(w['jc'], 5);
      expect(w['jmin'], 50);
      expect(w['jmax'], 200);
      expect(w['s1'], 100);
      expect(w['s2'], 100);
      expect(w['s3'], 60);
      expect(w['s4'], 60);
      // Header values arrive int-or-range-String per the fork schema.
      expect(w['h1'], 123456);
      expect(w['h2'], 234567);
      expect(w['h3'], '1000-2000');
      expect(w['h4'], 456789);
      // AWG 3.x extras.
      expect(w['i1'], '<b 0x0102030405060708><r 12>');
      expect(w['hpk'], 'kF9uPQ0mSFRlZmF1bHRrZXltYXRlcmlhbDEyMzQ1Njc4OTA=');
      // The generated profile is tagged so the UI/diagnostics can show it.
      expect(WarpRegistrar.profileFor(awg).tags, contains('awg-3.1'));
    });

    test('plain WARP account emits NO awg fields', () {
      final cfg = gen.generate(
        runnableProfiles: [node],
        routing: BuiltinRoutingProfiles.all().first,
        dns: DnsSettings(mode: DnsMode.automatic),
        selectedTag: 'node:n1',
        warpProfile: WarpRegistrar.profileFor(_fakeAccount()),
        chainWarpOutside: true,
      );
      final w = warpEndpoint(cfg);
      for (final k in const [
        'jc', 'jmin', 'jmax', 's1', 's2', 's3', 's4',
        'h1', 'h2', 'h3', 'h4', 'i1', 'i2', 'i3', 'i4', 'i5', 'hpk', 'padding'
      ]) {
        expect(w.containsKey(k), isFalse,
            reason: 'plain WARP must not carry the AWG key "k"'.replaceFirst('k', k));
      }
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

  test('§30b: a wg-quick .conf with AWG 3.x headers imports the full set',
      () {
    final conf = '''
[Interface]
PrivateKey = kJ3xXyQ7Wm9pR5tN2vB8sL4cH6dF1aG0eIuO9qZw8kA=
Address = 172.16.0.2/32
Jc = 5
Jmin = 40
Jmax = 70
S1 = 15
S2 = 15
S3 = 60
S4 = 60
H1 = 100000-800000
H2 = 1000000-8000000
H3 = 3
H4 = 4
I1 = <b 0x1603030001><t>
Hpk = kF9uPQ0mSFRlZmF1bHRrZXltYXRlcmlhbDEyMzQ1Njc4OTA=

[Peer]
PublicKey = qF2FiW09KjRWd7pF5bEy9XU9pHc4uTMvE1S0aZnQVXM=
Endpoint = 162.159.193.10:2408
AllowedIPs = 0.0.0.0/0
''';
    final p = WireGuardConfParser().parse(conf, fileName: 'awg31.conf');
    final a = p.amnezia!;
    expect(a.jc, 5);
    expect(a.s3, 60);
    expect(a.s4, 60);
    // Ranges survive as strings; single values normalize to plain digits.
    expect(a.h1, '100000-800000');
    expect(a.h3, '3');
    expect(a.i1, '<b 0x1603030001><t>');
    expect(a.headerProtectionKey,
        'kF9uPQ0mSFRlZmF1bHRrZXltYXRlcmlhbDEyMzQ1Njc4OTA=');
    // Nothing leaked into the unknown-params bucket.
    expect(a.extra, isEmpty);
  });

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
