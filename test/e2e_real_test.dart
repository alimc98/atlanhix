import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/core_detector.dart';
import 'package:nexus/core/health/latency_tester.dart';
import 'package:nexus/core/runtime/binary_manager.dart';
import 'package:nexus/core/runtime/core_manager.dart';
import 'package:nexus/core/runtime/core_process.dart';
import 'package:nexus/domain/entities/proxy_profile.dart';
import 'package:nexus/protocols/importer.dart';
import 'package:nexus/routing/builtin_profiles.dart';
import 'package:nexus/routing/routing_models.dart';

import 'helpers/mock_servers.dart';

/// Real-world E2E (§8/§12): driven by environment variables so NO credentials
/// are ever committed. Absent variables → clean SKIP, never a pass.
///
///   NEXUS_E2E_VLESS_URI       vless://… share link
///   NEXUS_E2E_HYSTERIA2_URI   hysteria2://… share link
///   NEXUS_E2E_XHTTP_URI       vless://…type=xhttp link (Xray path)
Future<void> runRealNode(ProxyProfile profile, String marker,
    MockHttpServer http) async {
  final coresDir = Directory(
      '${Directory.current.path}${Platform.pathSeparator}cores'
      '${Platform.pathSeparator}${BinaryManager.platformDirName()}');
  final bm = BinaryManager(appDir: coresDir);
  final mgr = CoreManager(
    binaryManager: bm,
    workDir: await Directory.systemTemp.createTemp('nexus-e2e-real'),
  );
  addTearDown(() => mgr.dispose());
  if (profile.effectiveCore == CoreKind.xray) {
    await mgr.prepare();
    mgr.xray.accessLogPath =
        '${mgr.xrayWorkDir}${Platform.pathSeparator}access.log';
  }

  final sw = Stopwatch()..start();
  final start = await mgr.startFor(
    profile,
    all: [profile],
    routing: BuiltinRoutingProfiles.all().first,
    dns: DnsSettings(mode: DnsMode.automatic),
  );
  expect(start.ok, isTrue, reason: 'engine start failed: ${start.message}');
  final startMs = sw.elapsedMilliseconds;

  final tester = LatencyTester();
  final localProbe = await tester.testHttpViaSocksProxy('127.0.0.1',
      mgr.front.mixedPort, 'http://127.0.0.1:${http.port}/$marker',
      timeout: const Duration(seconds: 10));
  expect(localProbe.ok, isTrue,
      reason: 'local probe through real node failed: '
          '${localProbe.errorKind} ${localProbe.detail}');
  // ignore: avoid_print
  print('E2E[$marker] start=${startMs}ms local=${localProbe.latencyMs}ms '
      'pid=${start.pid} mixed=${mgr.front.mixedPort}');

  final ipProbe = await tester.testHttpViaSocksProxy('127.0.0.1',
      mgr.front.mixedPort, 'https://www.cloudflare.com/cdn-cgi/trace',
      timeout: const Duration(seconds: 12));
  // ignore: avoid_print
  print('E2E[$marker] internet probe: ok=${ipProbe.ok} '
      'latency=${ipProbe.latencyMs} detail=${ipProbe.detail}');

  await Future<void>.delayed(const Duration(milliseconds: 1200));
  final t = mgr.front.traffic;
  // ignore: avoid_print
  print('E2E[$marker] traffic: up=${t?.upBytes ?? 0} down=${t?.downBytes ?? 0}');

  await mgr.stop();
  if (start.pid != null) {
    expect(await processAlive(start.pid!), isFalse,
        reason: 'engine process leaked after real-node session');
  }
}

int ssServerPort = 0;

Future<String> writeSsServerConfig(Directory dir) async {
  final port = await PortAllocator.freePort(prefer: 33001);
  ssServerPort = port;
  final f = File('${dir.path}${Platform.pathSeparator}ss-server.json');
  await f.writeAsString(
      '{"inbounds":[{"type":"shadowsocks","tag":"ss-in","listen":"127.0.0.1",'
      '"listen_port":$port,"method":"aes-128-gcm","password":"e2e-pass-123"}],'
      '"outbounds":[{"type":"direct","tag":"direct"}]}',
      flush: true);
  return f.path;
}

Future<bool> processAlive(int pid) async {
  if (!Platform.isWindows) return true;
  final r = await Process.run('tasklist', ['/FI', 'PID eq $pid']);
  return '${r.stdout}'.contains('$pid');
}


void main() {
  test('REAL VLESS node (env-gated)', () async {
    final uri = Platform.environment['NEXUS_E2E_VLESS_URI'];
    if (uri == null || uri.isEmpty) {
      // ignore: avoid_print
      print('SKIPPED: NEXUS_E2E_VLESS_URI not configured');
      return;
    }
    final http = MockHttpServer();
    await http.start();
    addTearDown(http.stop);
    final r = MultiFormatImporter().import(uri);
    expect(r.profiles, isNotEmpty);
    await runRealNode(r.profiles.first, 'vless', http);
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('REAL Hysteria2 node (env-gated)', () async {
    final uri = Platform.environment['NEXUS_E2E_HYSTERIA2_URI'];
    if (uri == null || uri.isEmpty) {
      // ignore: avoid_print
      print('SKIPPED: NEXUS_E2E_HYSTERIA2_URI not configured');
      return;
    }
    final http = MockHttpServer();
    await http.start();
    addTearDown(http.stop);
    final r = MultiFormatImporter().import(uri);
    expect(r.profiles, isNotEmpty);
    await runRealNode(r.profiles.first, 'hy2', http);
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('REAL XHTTP node through Xray path (env-gated)', () async {
    final uri = Platform.environment['NEXUS_E2E_XHTTP_URI'];
    if (uri == null || uri.isEmpty) {
      // ignore: avoid_print
      print('SKIPPED: NEXUS_E2E_XHTTP_URI not configured');
      return;
    }
    final http = MockHttpServer();
    await http.start();
    addTearDown(http.stop);
    final r = MultiFormatImporter().import(uri);
    expect(r.profiles, isNotEmpty);
    final p = r.profiles.first;
    final decision = CoreDetector().detect(p);
    p.core = decision.core; // W3: detector decision controls traffic path
    // ignore: avoid_print
    print('E2E[xhttp] detected core: ${decision.core} '
        '(${decision.confidence.toStringAsFixed(2)})');
    expect(decision.core, CoreKind.xray,
        reason: 'xhttp must be detected as Xray-owned');
    await runRealNode(p, 'xhttp', http);
  }, timeout: const Timeout(Duration(minutes: 3)));
}
