import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/health/latency_tester.dart';
import 'package:nexus/core/runtime/binary_manager.dart';
import 'package:nexus/core/runtime/core_manager.dart';
import 'package:nexus/core/runtime/core_process.dart';
import 'package:nexus/core/runtime/core_runtime.dart';
import 'package:nexus/domain/entities/proxy_profile.dart';
import 'package:nexus/routing/builtin_profiles.dart';
import 'package:nexus/routing/routing_models.dart';

import 'helpers/mock_servers.dart';

/// v0.3.0 §17 — Xray upstream crash recovery.
///
/// v0.2.1 proved front-engine (sing-box) crash recovery. Here the *upstream*
/// (Xray) is SIGKILLed mid-connection: detection → daemon-scoped rebuild
/// (front engine keeps running) → traffic verified again → new PID.
Future<bool> processAlive(int pid) async {
  if (!Platform.isWindows) return true;
  final r = await Process.run('tasklist', ['/FI', 'PID eq $pid']);
  return '${r.stdout}'.contains('$pid');
}

void main() {
  test('E2E XRAY CRASH: kill xray → detect → recover upstream → traffic',
      () async {
    final coresDir = Directory(
        '${Directory.current.path}${Platform.pathSeparator}cores'
        '${Platform.pathSeparator}${BinaryManager.platformDirName()}');
    if (!coresDir.existsSync()) {
      // ignore: avoid_print
      print('SKIPPED: cores not installed');
      return;
    }
    final bm = BinaryManager(appDir: coresDir);
    final xrInfo = await bm.inspect(CoreBinaryKind.xray);
    final sbInfo = await bm.inspect(CoreBinaryKind.singbox);
    if (xrInfo.status != 'available' || sbInfo.status != 'available') {
      // ignore: avoid_print
      print('SKIPPED: engines not fully installed');
      return;
    }

    final http = MockHttpServer();
    await http.start();
    addTearDown(http.stop);

    // Real Xray VLESS server (destination side).
    final vlessPort = await PortAllocator.freePort(prefer: 33031);
    final serverDir = await Directory.systemTemp.createTemp('nexus-xrc-srv');
    final serverCfg = File('${serverDir.path}${Platform.pathSeparator}s.json');
    await serverCfg.writeAsString(
        '{"log":{"loglevel":"warning"},'
        '"inbounds":[{"port":$vlessPort,"protocol":"vless",'
        '"settings":{"decryption":"none","clients":[{"id":'
        '"b831381d-6324-4d53-ad4f-8cda48b30811"}]},'
        '"streamSettings":{"network":"tcp"}}],'
        '"outbounds":[{"protocol":"freedom","tag":"direct"}]}',
        flush: true);
    final vlessServer =
        await ManagedProcess.start(xrInfo.path!, ['run', '-c', serverCfg.path]);
    addTearDown(() => vlessServer.stop());

    final profile = ProxyProfile(
      id: 'xray-crash',
      name: 'xray vless node',
      server: '127.0.0.1',
      port: vlessPort,
      protocol: ProxyProtocol.vless,
      uuid: 'b831381d-6324-4d53-ad4f-8cda48b30811',
      security: Security.none,
      core: CoreKind.xray,
      userPinnedCore: CoreKind.xray,
    );

    final mgr = CoreManager(
      binaryManager: bm,
      workDir: await Directory.systemTemp.createTemp('nexus-xrc-mgr'),
    );
    addTearDown(() => mgr.dispose());
    await mgr.prepare();
    final start = await mgr.startFor(
      profile,
      all: [profile],
      routing: BuiltinRoutingProfiles.all().first,
      dns: DnsSettings(mode: DnsMode.automatic),
    );
    expect(start.ok, isTrue, reason: start.message);
    expect(mgr.xray.status, RuntimeStatus.running);
    final oldXrayPid = mgr.xray.lastPid!;
    final sbPid = start.pid!;

    final probe0 = await LatencyTester().testHttpViaSocksProxy('127.0.0.1',
        mgr.front.mixedPort, 'http://127.0.0.1:${http.port}/before',
        timeout: const Duration(seconds: 8));
    expect(probe0.ok, isTrue, reason: 'baseline probe failed');

    // Kill ONLY the Xray upstream, mid-connection.
    if (Platform.isWindows) {
      await Process.run('taskkill', ['/PID', '$oldXrayPid', '/F']);
    } else {
      Process.killPid(oldXrayPid, ProcessSignal.sigkill);
    }
    await Future<void>.delayed(const Duration(milliseconds: 600));

    // §17: detection must fire.
    final exit = mgr.xray.lastExit;
    expect(exit, isNotNull, reason: 'xray exit watcher must fire on kill');
    expect(exit!.kind, isNot(CoreExitKind.clean));

    // The front engine must still be alive (daemon-scoped recovery).
    expect(mgr.front.status, RuntimeStatus.running,
        reason: 'front engine must survive an upstream crash');
    expect(await processAlive(sbPid), isTrue);

    // Recover and verify NEW pid + traffic.
    final recovered = await mgr.recoverEngine(
      CoreKind.xray,
      all: [profile],
      routing: BuiltinRoutingProfiles.all().first,
      dns: DnsSettings(mode: DnsMode.automatic),
    );
    expect(recovered, isTrue, reason: 'upstream recovery failed');
    expect(mgr.xray.lastPid, isNot(equals(oldXrayPid)),
        reason: 'recovered xray must be a new process');

    final probe1 = await LatencyTester().testHttpViaSocksProxy('127.0.0.1',
        mgr.front.mixedPort, 'http://127.0.0.1:${http.port}/after',
        timeout: const Duration(seconds: 8));
    expect(probe1.ok, isTrue,
        reason: 'post-recovery probe failed: ${probe1.detail}');
    expect(http.requests, contains('GET /after'));

    await mgr.stop();
    expect(await processAlive(oldXrayPid), isFalse);
    expect(await processAlive(sbPid), isFalse,
        reason: 'front engine must be gone after stop');
  }, timeout: const Timeout(Duration(seconds: 120)));
}
