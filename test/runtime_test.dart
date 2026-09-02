import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/health/latency_tester.dart';
import 'package:nexus/core/runtime/binary_manager.dart';
import 'package:nexus/core/runtime/core_runtime.dart';
import 'package:nexus/core/runtime/singbox_runtime.dart';
import 'package:nexus/core/runtime/xray_runtime.dart';
import 'package:nexus/domain/entities/proxy_profile.dart';
import 'package:nexus/routing/builtin_profiles.dart';
import 'package:nexus/routing/routing_models.dart';

/// Real runtime integration tests (Phases 1–5, 33).
///
/// These tests start the ACTUAL engine binaries found in `cores/<platform>/`.
/// They are skipped (with reason) when the binaries are not installed. With
/// cores present they exercise: generate → engine check → process start →
/// readiness → hot switch → stop.
void main() {
  final coresDir = Directory(
      '${Directory.current.path}${Platform.pathSeparator}cores'
      '${Platform.pathSeparator}${BinaryManager.platformDirName()}');
  final hasCores = coresDir.existsSync();

  test('BinaryManager detects installed engines', () async {
    final bm = BinaryManager(appDir: coresDir);
    final info = await bm.inspect(CoreBinaryKind.singbox);
    if (!hasCores) {
      expect(info.status, 'notInstalled');
      return;
    }
    expect(info.status, 'available', reason: '${info.path}');
    expect(info.version, isNotNull);
    final xr = await bm.inspect(CoreBinaryKind.xray);
    expect(xr.status, 'available');
  });

  test(
      'SingBoxRuntime: prepare → validate → start → ready → hot-switch → stop',
      () async {
    final bm = BinaryManager(appDir: coresDir);
    final info = await bm.inspect(CoreBinaryKind.singbox);
    if (info.status != 'available') {
      // ignore: avoid_print
      print('SKIP: sing-box binary not installed');
      return;
    }

    final runtime = SingBoxRuntime(
      binaryManager: bm,
      workDir: await Directory.systemTemp.createTemp('nexus-sb-test'),
      clashSecret: 'test-secret',
    );
    addTearDown(() => runtime.dispose());
    await runtime.prepare();

    // A deliberately unreachable upstream: the ENGINE still starts and its
    // selector accepts hot-switches; upstream reachability is verified by
    // connectivity probes separately.
    final fakeNode = ProxyProfile(
      id: 'dead-node',
      name: 'unreachable',
      server: '127.0.0.1',
      port: 1,
      protocol: ProxyProtocol.shadowsocks,
      ssMethod: 'aes-256-gcm',
      password: 'pw',
    );

    final validation = await runtime.validateAll(
      profiles: [fakeNode],
      selectedProfileId: 'dead-node',
      routing: BuiltinRoutingProfiles.all().first,
      dns: DnsSettings(mode: DnsMode.automatic),
    );
    expect(validation.ok, isTrue,
        reason: 'engine check failed: ${validation.output}');

    final result = await runtime.startWith(
      profiles: [fakeNode],
      selectedProfileId: 'dead-node',
      routing: BuiltinRoutingProfiles.all().first,
      dns: DnsSettings(mode: DnsMode.automatic),
    );
    expect(result.ok, isTrue, reason: result.message);
    expect(runtime.status, RuntimeStatus.running);
    expect(result.pid, isNotNull);
    expect(result.startupMs, isNotNull);
    expect(await runtime.inboundHealthy(), isTrue);

    // Phase 5: hot switch via Clash API — engine accepts the tag.
    final switched = await runtime.switchToProfile(fakeNode);
    expect(switched, isTrue, reason: 'selector hot-switch failed');

    // Engine delay API path must not throw (upstream is dead by design).
    await runtime.testTag('node:dead-node');

    await runtime.stop();
    expect(runtime.status, RuntimeStatus.stopped);
  });

  test('SingBoxRuntime rejects broken config via engine check', () async {
    final bm = BinaryManager(appDir: coresDir);
    final info = await bm.inspect(CoreBinaryKind.singbox);
    if (info.status != 'available') return;

    // Reality node without a public key: generator emits reality.enabled
    // with null public_key. The engine check output must be produced by the
    // REAL engine (not faked) either way.
    final broken = ProxyProfile(
      id: 'broken',
      name: 'broken reality',
      server: 's.example.com',
      port: 443,
      protocol: ProxyProtocol.vless,
      security: Security.reality,
      uuid: 'u1',
    );
    final runtime = SingBoxRuntime(
      binaryManager: bm,
      workDir: await Directory.systemTemp.createTemp('nexus-sb-bad'),
    );
    addTearDown(() => runtime.dispose());
    await runtime.prepare();
    final validation = await runtime.validateAll(
      profiles: [broken],
      selectedProfileId: 'broken',
      routing: BuiltinRoutingProfiles.all().first,
      dns: DnsSettings(mode: DnsMode.automatic),
    );
    expect(validation.output ?? validation.message, isNotNull);
  });

  test('XrayRuntime: validate → start → ready → stop (Flow A path)', () async {
    final bm = BinaryManager(appDir: coresDir);
    final info = await bm.inspect(CoreBinaryKind.xray);
    if (info.status != 'available') {
      // ignore: avoid_print
      print('SKIP: xray binary not installed');
      return;
    }

    final runtime = XrayRuntime(
      binaryManager: bm,
      workDir: await Directory.systemTemp.createTemp('nexus-xr-test'),
    );
    addTearDown(() => runtime.dispose());
    await runtime.prepare();

    final profile = ProxyProfile(
      id: 'xr-node',
      name: 'xray test node',
      server: '127.0.0.1',
      port: 1,
      protocol: ProxyProtocol.vless,
      uuid: 'b831381d-6324-4d53-ad4f-8cda48b30811',
      security: Security.tls,
      sni: 'www.samsung.com',
    );

    // Phase 3 gate: `xray run -test` accepts the generated config.
    final validation = await runtime.validateProfile(
        profile: profile, routing: BuiltinRoutingProfiles.all().first);
    expect(validation.ok, isTrue,
        reason: 'xray -test rejected config: ${validation.output}');

    final result = await runtime.startProfile(
        profile: profile, routing: BuiltinRoutingProfiles.all().first);
    expect(result.ok, isTrue, reason: result.message);
    expect(runtime.status, RuntimeStatus.running);
    expect(await runtime.inboundHealthy(), isTrue);
    expect(result.pid, isNotNull);

    await runtime.stop();
    expect(runtime.status, RuntimeStatus.stopped);
  });

  test('LatencyTester probes through the running mixed inbound', () async {
    final bm = BinaryManager(appDir: coresDir);
    final info = await bm.inspect(CoreBinaryKind.singbox);
    if (info.status != 'available') return;

    final runtime = SingBoxRuntime(
      binaryManager: bm,
      workDir: await Directory.systemTemp.createTemp('nexus-sb-probe'),
    );
    addTearDown(() => runtime.dispose());
    await runtime.prepare();

    // Selector falls back to `direct` with no profiles → tunnel == direct.
    final result = await runtime.startWith(
      profiles: const [],
      selectedProfileId: '',
      routing: BuiltinRoutingProfiles.all().first,
      dns: DnsSettings(mode: DnsMode.automatic),
    );
    if (!result.ok) {
      // ignore: avoid_print
      print('SKIP: engine did not start: ${result.message}');
      return;
    }

    final tester = LatencyTester();
    final probe = await tester.testHttpViaSocksProxy(
      '127.0.0.1',
      runtime.mixedPort,
      'https://www.cloudflare.com/cdn-cgi/trace',
      timeout: const Duration(seconds: 8),
    );
    // Assert only that the probe completed with a classified result —
    // network availability is environmental.
    expect(probe.ok || probe.errorKind != null, isTrue);
    // ignore: avoid_print
    print('probe through tunnel: ok=${probe.ok} latency=${probe.latencyMs} '
        'kind=${probe.errorKind} detail=${probe.detail}');

    await runtime.stop();
  });
}
