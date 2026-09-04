import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/health/latency_tester.dart';
import 'package:nexus/core/primitives.dart';
import 'package:nexus/core/runtime/binary_manager.dart';
import 'package:nexus/core/runtime/core_manager.dart';
import 'package:nexus/core/runtime/core_process.dart';
import 'package:nexus/core/runtime/core_runtime.dart';
import 'package:nexus/core/runtime/core_runtime.dart';
import 'package:nexus/domain/entities/proxy_profile.dart';
import 'package:nexus/routing/builtin_profiles.dart';
import 'package:nexus/routing/routing_models.dart';

/// v0.3.2 §7 — FULL integration: sing-box front → MDVPN SOCKS upstream →
/// DNS tunnel → Internet. Gated by ATLANHIX_MDVPN_E2E=1 +
/// ATLANHIX_MDVPN_SERVER + ATLANHIX_MDVPN_KEY (+ ATLANHIX_MDVPN_BIN).
///
/// This is NOT the probe-only path: the request goes through the Atlanhix
/// sing-box mixed inbound, which routes to the MDVPN SOCKS stub, which
/// tunnels over DNS. Verifies the generated sing-box config carries the
/// correct upstream endpoint, plus crash recovery of the daemon behind a
/// running front engine.
void main() {
  test('§7 full chain: sing-box → MDVPN SOCKS → DNS tunnel → HTTP; '
      'daemon kill → upstream recovery → traffic', () async {
    final env = Platform.environment;
    if (env['ATLANHIX_MDVPN_E2E'] != '1') {
      // ignore: avoid_print
      print('SKIPPED: ATLANHIX_MDVPN_E2E=1 required');
      return;
    }
    final server = env['ATLANHIX_MDVPN_SERVER'];
    final key = env['ATLANHIX_MDVPN_KEY'];
    final binPath = env['ATLANHIX_MDVPN_BIN'];
    if (server == null ||
        key == null ||
        binPath == null ||
        !File(binPath).existsSync()) {
      fail('§7 requires ATLANHIX_MDVPN_SERVER/KEY/BIN (binary must exist)');
    }

    final coresDir =
        await Directory.systemTemp.createTemp('nexus-mdvpn7-cores');
    await File(binPath).copy(
        '${coresDir.path}${Platform.pathSeparator}'
        '${BinaryManager.binaryName(CoreBinaryKind.masterDnsVpn)}');

    final mgr = CoreManager(
      binaryManager: BinaryManager(userCoresDir: coresDir.path),
      workDir: await Directory.systemTemp.createTemp('nexus-mdvpn7'),
    );
    addTearDown(() => mgr.dispose());
    await mgr.prepare();

    final profile = ProxyProfile(
      id: 'mdvpn-full',
      name: 'mdvpn integration node',
      server: server,
      port: 53,
      protocol: ProxyProtocol.masterDnsVpn,
      core: CoreKind.masterDnsVpn,
      password: key, // → -k argv only
      rawParams: {'DOMAINS': server, 'DATA_ENCRYPTION_METHOD': '1'},
    );

    final sw = Stopwatch()..start();
    final start = await mgr.startFor(
      profile,
      all: [profile],
      routing: BuiltinRoutingProfiles.all().first,
      dns: DnsSettings(mode: DnsMode.automatic),
    );
    expect(start.ok, isTrue, reason: 'startFor failed: ${start.message}');
    expect(mgr.front.status, RuntimeStatus.running);
    expect(mgr.masterDnsVpn.status, RuntimeStatus.running);
    final daemonPid = mgr.masterDnsVpn.lastPid!;
    // ignore: avoid_print
    print('METRIC full-path start: ${sw.elapsedMilliseconds}ms '
        'singboxPid=${start.pid} mdvpnPid=$daemonPid '
        'mdvpnSocks=${mgr.masterDnsVpn.socksPort} '
        'frontMixed=${mgr.front.mixedPort}');
    _verifyWiring(mgr, profile);
    await _trafficAndRecovery(mgr, profile, start.pid!, daemonPid);
  }, timeout: const Timeout(Duration(minutes: 8)));
}

/// §7 wiring proof: the generated sing-box stub must point at the RUNNING
/// daemon's SOCKS port.
void _verifyWiring(CoreManager mgr, ProxyProfile profile) {
  final sb = mgr.front as dynamic;
  final cfg = (sb.buildConfig([profile],
          selectedProfileId: profile.id,
          routing: BuiltinRoutingProfiles.all().first,
          dns: DnsSettings(mode: DnsMode.automatic),
          socksUpstreams: {
            profile.id: (
              host: '127.0.0.1',
              port: mgr.masterDnsVpn.socksPort
            )
          }) as Map<String, dynamic>);
  final stubs = (cfg['outbounds'] as List)
      .where((o) => o is Map && o['type'] == 'socks')
      .cast<Map>()
      .toList();
  expect(stubs, isNotEmpty,
      reason: 'sing-box config must contain the MDVPN SOCKS stub');
  expect(stubs.first['server'], '127.0.0.1');
  expect(stubs.first['server_port'], mgr.masterDnsVpn.socksPort,
      reason: 'stub endpoint must equal the RUNNING daemon port');
  // ignore: avoid_print
  print('METRIC stub endpoint: 127.0.0.1:${stubs.first['server_port']} '
      '(matches running daemon)');
}

/// Real traffic through the FULL chain, then daemon kill + upstream-scoped
/// recovery + traffic again + cleanup.
Future<void> _trafficAndRecovery(
    CoreManager mgr, ProxyProfile profile, int sbPid, int daemonPid) async {
  final tester = LatencyTester();
  final probe = await tester.testHttpViaSocksProxy('127.0.0.1',
      mgr.front.mixedPort, 'https://www.gstatic.com/generate_204',
      timeout: const Duration(seconds: 60));
  expect(probe.ok, isTrue,
      reason: 'HTTP through the FULL MDVPN chain failed: '
          '${probe.errorKind} ${probe.detail}');
  final before = mgr.front.traffic;
  // ignore: avoid_print
  print('METRIC full-chain HTTP: ${probe.latencyMs}ms '
      'traffic-before: up=${before?.upBytes} down=${before?.downBytes}');

  // Kill the daemon BEHIND the running front engine.
  if (Platform.isWindows) {
    await Process.run('taskkill', ['/PID', '$daemonPid', '/F']);
  } else {
    Process.killPid(daemonPid, ProcessSignal.sigkill);
  }
  await Future<void>.delayed(const Duration(milliseconds: 800));
  expect(mgr.masterDnsVpn.lastExit, isNotNull,
      reason: 'daemon exit watcher must fire');
  expect(mgr.masterDnsVpn.lastExit!.kind, isNot(CoreExitKind.clean));
  expect(mgr.front.status, RuntimeStatus.running,
      reason: 'front engine must survive the upstream crash');

  final recovered = await mgr.recoverEngine(
    CoreKind.masterDnsVpn,
    all: [profile],
    routing: BuiltinRoutingProfiles.all().first,
    dns: DnsSettings(mode: DnsMode.automatic),
  );
  expect(recovered, isTrue, reason: 'upstream recovery failed');
  expect(mgr.masterDnsVpn.lastPid, isNot(equals(daemonPid)),
      reason: 'recovered daemon must be a NEW process');
  expect(mgr.masterDnsVpn.probe(), completion(isTrue),
      reason: 'recovered daemon must present SOCKS5 readiness');

  final probe2 = await tester.testHttpViaSocksProxy('127.0.0.1',
      mgr.front.mixedPort, 'https://www.gstatic.com/generate_204',
      timeout: const Duration(seconds: 60));
  expect(probe2.ok, isTrue,
      reason: 'post-recovery HTTP through the chain failed: '
          '${probe2.errorKind} ${probe2.detail}');
  final after = mgr.front.traffic;
  // ignore: avoid_print
  print('METRIC recovery HTTP: ${probe2.latencyMs}ms '
      'newPid=${mgr.masterDnsVpn.lastPid} '
      'traffic-after: up=${after?.upBytes} down=${after?.downBytes}');

  Future<bool> alive(int pid) async {
    if (!Platform.isWindows) return true;
    final r = await Process.run('tasklist', ['/FI', 'PID eq $pid']);
    return '${r.stdout}'.contains('$pid');
  }

  // Capture pids BEFORE stop() — lastPid nulls once the runtime stops.
  final recoveredPid = mgr.masterDnsVpn.lastPid!;
  await mgr.stop();
  expect(await alive(daemonPid), isFalse, reason: 'old daemon leaked');
  expect(await alive(recoveredPid), isFalse,
      reason: 'recovered daemon leaked');
  expect(await alive(sbPid), isFalse, reason: 'sing-box leaked');
  // ignore: avoid_print
  print('METRIC cleanup: all processes gone');
}
