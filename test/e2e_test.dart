import 'dart:convert';
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

Future<List<int>> readAllSocket(Socket s) async {
  final out = <int>[];
  await for (final chunk in s) {
    out.addAll(chunk);
  }
  return out;
}

void main() {
  final coresDir = Directory(
      '${Directory.current.path}${Platform.pathSeparator}cores'
      '${Platform.pathSeparator}${BinaryManager.platformDirName()}');
  final hasCores = coresDir.existsSync();

  late MockHttpServer http;
  late MockSocksServer socks;

  setUpAll(() async {
    http = MockHttpServer();
    socks = MockSocksServer();
    await http.start();
    await socks.start();
  });

  tearDownAll(() async {
    await http.stop();
    await socks.stop();
  });

  test('mock topology sanity: SOCKS5 → HTTP forwarding works', () async {
    final clientSock = await Socket.connect(
        InternetAddress.loopbackIPv4, socks.port,
        timeout: const Duration(seconds: 5));
    clientSock.add([
      0x05, 0x01, 0x00,
      0x05, 0x01, 0x00, 0x01, 127, 0, 0, 1,
      http.port >> 8, http.port & 0xFF,
    ]);
    clientSock.add(utf8.encode('GET /sanity HTTP/1.1\r\n'
        'Host: 127.0.0.1\r\nConnection: close\r\n\r\n'));
    final resp = await readAllSocket(clientSock)
        .timeout(const Duration(seconds: 8));
    clientSock.destroy();
    expect(utf8.decode(resp, allowMalformed: true),
        contains('NEXUS-E2E-OK path=/sanity'));
    expect(socks.connectTargets, contains('127.0.0.1:${http.port}'));
  });

  test('E2E NATIVE: sing-box ss-client → ss-server → destination', () async {
    if (!hasCores) {
      // ignore: avoid_print
      print('SKIPPED: cores not installed');
      return;
    }
    final bm = BinaryManager(appDir: coresDir);
    final sbInfo = await bm.inspect(CoreBinaryKind.singbox);
    if (sbInfo.status != 'available') return;

    final ssServer = await ManagedProcess.start(sbInfo.path!, [
      'run', '-c',
      await writeSsServerConfig(
          await Directory.systemTemp.createTemp('nexus-e2e-sssrv')),
    ]);
    addTearDown(() => ssServer.stop());

    final profile = ProxyProfile(
      id: 'e2e-native', name: 'native ss node',
      server: '127.0.0.1', port: ssServerPort,
      protocol: ProxyProtocol.shadowsocks,
      ssMethod: 'aes-128-gcm', password: 'e2e-pass-123',
    );

    final mgr = CoreManager(
      binaryManager: bm,
      workDir: await Directory.systemTemp.createTemp('nexus-e2e-native'),
    );
    addTearDown(() => mgr.dispose());
    final sw = Stopwatch()..start();
    final start = await mgr.startFor(
      profile,
      all: [profile],
      routing: BuiltinRoutingProfiles.all().first,
      dns: DnsSettings(mode: DnsMode.automatic),
    );
    expect(start.ok, isTrue, reason: start.message);
    // ignore: avoid_print
    print('METRIC native start(validate+ready): ${sw.elapsedMilliseconds} ms');

    final tester = LatencyTester();
    final probe = await tester.testHttpViaSocksProxy(
        '127.0.0.1', mgr.front.mixedPort,
        'http://127.0.0.1:${http.port}/native',
        timeout: const Duration(seconds: 8));
    expect(probe.ok, isTrue,
        reason: 'probe failed: ${probe.errorKind} ${probe.detail}');
    // ignore: avoid_print
    print('METRIC first-connection latency: ${probe.latencyMs} ms');

    expect(http.requests, contains('GET /native'));
    expect(socks.connectTargets, contains('127.0.0.1:${http.port}'),
        reason: 'traffic must traverse the ss-server');

    final before = mgr.front.traffic!;
    final probe2 = await tester.testHttpViaSocksProxy(
        '127.0.0.1', mgr.front.mixedPort,
        'http://127.0.0.1:${http.port}/more',
        timeout: const Duration(seconds: 8));
    expect(probe2.ok, isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    final after = mgr.front.traffic!;
    // ignore: avoid_print
    print('METRIC traffic before=${before.upBytes}/${before.downBytes} '
        'after=${after.upBytes}/${after.downBytes}');
    expect(after.upBytes + after.downBytes,
        greaterThan(before.upBytes + before.downBytes),
        reason: 'counters must reflect real traffic');

    final pid = start.pid!;
    await mgr.stop();
    expect(await processAlive(pid), isFalse, reason: 'sing-box must be gone');
  });

  test('E2E XRAY PATH: sing-box→Xray→destination (access-log proof)',
      () async {
    if (!hasCores) {
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

    final vlessPort = await PortAllocator.freePort(prefer: 33011);
    final serverDir = await Directory.systemTemp.createTemp('nexus-e2e-xrsrv');
    final serverCfg = File('${serverDir.path}/s.json');
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
      id: 'e2e-xray', name: 'xray vless node',
      server: '127.0.0.1', port: vlessPort,
      protocol: ProxyProtocol.vless,
      uuid: 'b831381d-6324-4d53-ad4f-8cda48b30811',
      security: Security.none,
      core: CoreKind.xray,
      userPinnedCore: CoreKind.xray,
    );

    final work = await Directory.systemTemp.createTemp('nexus-e2e-xray');
    final accessLog = '${work.path}${Platform.pathSeparator}access.log';
    final mgr = CoreManager(binaryManager: bm, workDir: work);
    addTearDown(() => mgr.dispose());
    await mgr.prepare();
    mgr.xray.accessLogPath = accessLog;

    final sw = Stopwatch()..start();
    final start = await mgr.startFor(
      profile,
      all: [profile],
      routing: BuiltinRoutingProfiles.all().first,
      dns: DnsSettings(mode: DnsMode.automatic),
    );
    expect(start.ok, isTrue, reason: start.message);
    // ignore: avoid_print
    print('METRIC xray-path start: ${sw.elapsedMilliseconds} ms');

    expect(mgr.front.status, RuntimeStatus.running);
    expect(mgr.xray.status, RuntimeStatus.running);

    final tester = LatencyTester();
    final probe = await tester.testHttpViaSocksProxy(
        '127.0.0.1', mgr.front.mixedPort,
        'http://127.0.0.1:${http.port}/xraypath',
        timeout: const Duration(seconds: 8));
    expect(probe.ok, isTrue,
        reason: 'probe failed: ${probe.errorKind} ${probe.detail}');

    expect(http.requests, contains('GET /xraypath'));

    final logFile = File(accessLog);
    final logText = await logFile.exists() ? await logFile.readAsString() : '';
    // ignore: avoid_print
    print('METRIC xray access log: ${logText.trim()}');
    expect(logText, contains('127.0.0.1:${http.port}'),
        reason: 'Xray access log must show the destination dial');

    final sbPid = start.pid!;
    final xrPid = mgr.xray.lastPid ?? 0;
    await mgr.stop();
    expect(await processAlive(sbPid), isFalse);
    if (xrPid > 0) {
      expect(await processAlive(xrPid), isFalse, reason: 'xray must be gone');
    }
  });

  test('E2E FAILOVER: dead first candidate → alive second wins', () async {
    if (!hasCores) {
      // ignore: avoid_print
      print('SKIPPED: cores not installed');
      return;
    }
    final bm = BinaryManager(appDir: coresDir);
    final sbInfo = await bm.inspect(CoreBinaryKind.singbox);
    if (sbInfo.status != 'available') return;

    final ssServer = await ManagedProcess.start(sbInfo.path!, [
      'run', '-c',
      await writeSsServerConfig(
          await Directory.systemTemp.createTemp('nexus-e2e-fo')),
    ]);
    addTearDown(() => ssServer.stop());

    final dead = ProxyProfile(
      id: 'dead-candidate', name: 'dead node',
      server: '127.0.0.1', port: 1,
      protocol: ProxyProtocol.shadowsocks,
      ssMethod: 'aes-128-gcm', password: 'x',
    );
    final alive = ProxyProfile(
      id: 'alive-candidate', name: 'alive node',
      server: '127.0.0.1', port: ssServerPort,
      protocol: ProxyProtocol.shadowsocks,
      ssMethod: 'aes-128-gcm', password: 'e2e-pass-123',
    );

    final mgr = CoreManager(
      binaryManager: bm,
      workDir: await Directory.systemTemp.createTemp('nexus-e2e-failover'),
    );
    addTearDown(() => mgr.dispose());

    final result = await mgr.startFor(
      dead,
      all: [dead, alive],
      routing: BuiltinRoutingProfiles.all().first,
      dns: DnsSettings(mode: DnsMode.automatic),
    );
    expect(result.ok, isTrue, reason: 'engine start should succeed');
    final probe = await LatencyTester().testHttpViaSocksProxy(
        '127.0.0.1', mgr.front.mixedPort,
        'http://127.0.0.1:${http.port}/failover-dead',
        timeout: const Duration(seconds: 6));
    expect(probe.ok, isFalse,
        reason: 'dead candidate must fail connectivity verification');

    final recovered = await mgr.startFor(
      alive,
      all: [dead, alive],
      routing: BuiltinRoutingProfiles.all().first,
      dns: DnsSettings(mode: DnsMode.automatic),
    );
    expect(recovered.ok, isTrue, reason: recovered.message);
    final probe2 = await LatencyTester().testHttpViaSocksProxy(
        '127.0.0.1', mgr.front.mixedPort,
        'http://127.0.0.1:${http.port}/failover-alive',
        timeout: const Duration(seconds: 8));
    expect(probe2.ok, isTrue,
        reason: 'alive candidate must pass connectivity verification');
    expect(http.requests, contains('GET /failover-alive'));
    await mgr.stop();
  });

  test('E2E CRASH RECOVERY: kill engine → classify → restart → verify',
      () async {
    if (!hasCores) {
      // ignore: avoid_print
      print('SKIPPED: cores not installed');
      return;
    }
    final bm = BinaryManager(appDir: coresDir);
    final sbInfo = await bm.inspect(CoreBinaryKind.singbox);
    if (sbInfo.status != 'available') return;

    final ssServer = await ManagedProcess.start(sbInfo.path!, [
      'run', '-c',
      await writeSsServerConfig(
          await Directory.systemTemp.createTemp('nexus-e2e-crash')),
    ]);
    addTearDown(() => ssServer.stop());

    final profile = ProxyProfile(
      id: 'crash-test', name: 'crash node',
      server: '127.0.0.1', port: ssServerPort,
      protocol: ProxyProtocol.shadowsocks,
      ssMethod: 'aes-128-gcm', password: 'e2e-pass-123',
    );

    final mgr = CoreManager(
      binaryManager: bm,
      workDir: await Directory.systemTemp.createTemp('nexus-e2e-crash'),
    );
    addTearDown(() => mgr.dispose());
    final start = await mgr.startFor(
      profile,
      all: [profile],
      routing: BuiltinRoutingProfiles.all().first,
      dns: DnsSettings(mode: DnsMode.automatic),
    );
    expect(start.ok, isTrue, reason: start.message);
    final oldPid = start.pid!;

    if (Platform.isWindows) {
      await Process.run('taskkill', ['/PID', '$oldPid', '/F']);
    } else {
      Process.killPid(oldPid, ProcessSignal.sigkill);
    }
    await Future<void>.delayed(const Duration(milliseconds: 500));

    final exit = mgr.front.lastExit;
    expect(exit, isNotNull, reason: 'exit watcher must fire on kill');
    expect(exit!.kind, isNot(CoreExitKind.clean));

    final recovered = await mgr.recoverFront(
      all: [profile],
      routing: BuiltinRoutingProfiles.all().first,
      dns: DnsSettings(mode: DnsMode.automatic),
    );
    expect(recovered, isTrue, reason: 'recovery must succeed');
    final probe = await LatencyTester().testHttpViaSocksProxy(
        '127.0.0.1', mgr.front.mixedPort,
        'http://127.0.0.1:${http.port}/recovered',
        timeout: const Duration(seconds: 8));
    expect(probe.ok, isTrue,
        reason: 'post-recovery probe must succeed: ${probe.detail}');
    expect(http.requests, contains('GET /recovered'));
    expect(mgr.front.lastPid, isNot(equals(oldPid)));
    await mgr.stop();
  });

  test('E2E LEAK TEST: 20 connect/disconnect cycles → 0 leaked', () async {
    if (!hasCores) {
      // ignore: avoid_print
      print('SKIPPED: cores not installed');
      return;
    }
    final bm = BinaryManager(appDir: coresDir);
    final sbInfo = await bm.inspect(CoreBinaryKind.singbox);
    if (sbInfo.status != 'available') return;

    final ssServer = await ManagedProcess.start(sbInfo.path!, [
      'run', '-c',
      await writeSsServerConfig(
          await Directory.systemTemp.createTemp('nexus-e2e-leak')),
    ]);
    addTearDown(() => ssServer.stop());

    final profile = ProxyProfile(
      id: 'leak-test', name: 'leak node',
      server: '127.0.0.1', port: ssServerPort,
      protocol: ProxyProtocol.shadowsocks,
      ssMethod: 'aes-128-gcm', password: 'e2e-pass-123',
    );

    final work = await Directory.systemTemp.createTemp('nexus-e2e-leak-mgr');
    final mgr = CoreManager(binaryManager: bm, workDir: work);
    addTearDown(() => mgr.dispose());
    final allPids = <int>[];

    for (var cycle = 0; cycle < 20; cycle++) {
      final r = await mgr.startFor(
        profile,
        all: [profile],
        routing: BuiltinRoutingProfiles.all().first,
        dns: DnsSettings(mode: DnsMode.automatic),
      );
      expect(r.ok, isTrue, reason: 'cycle $cycle: ${r.message}');
      if (r.pid != null) allPids.add(r.pid!);
      await mgr.stop();
    }

    for (final pid in allPids) {
      expect(await processAlive(pid), isFalse,
          reason: 'PID $pid leaked after 20 cycles');
    }
    final sbDir = Directory('${work.path}${Platform.pathSeparator}singbox');
    if (await sbDir.exists()) {
      expect(await sbDir.list().length, 0,
          reason: 'temp config files must be cleaned');
    }
    // ignore: avoid_print
    print('METRIC leak test: ${allPids.length} cycles, 0 leaked');
  });
}

