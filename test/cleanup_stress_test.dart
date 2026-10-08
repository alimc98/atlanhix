import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/health/latency_tester.dart';
import 'package:nexus/core/runtime/binary_manager.dart';
import 'package:nexus/core/runtime/core_manager.dart';
import 'package:nexus/core/runtime/core_process.dart';
import 'package:nexus/domain/entities/proxy_profile.dart';
import 'package:nexus/routing/builtin_profiles.dart';
import 'package:nexus/routing/routing_models.dart';

import 'helpers/mock_servers.dart';

/// v0.3.0 §20 — resource cleanup under stress + §15 switching metrics.
///
/// 50 connect/disconnect cycles (env-overridable: ATLANHIX_CLEANUP_CYCLES),
/// verifying zero leaked processes and zero leaked temp configs.
Future<bool> processAlive(int pid) async {
  if (!Platform.isWindows) return true;
  // v0.3.2 hardening: tasklist's PID filter is a substring match — a pid
  // like 314 also matches 3148/13145. Filter rows and match the PID column.
  final r = await Process.run('tasklist', ['/FO', 'CSV', '/NH']);
  final needle = ',$pid,';
  for (final line in '${r.stdout}'.split(RegExp(r'\r?\n'))) {
    final l = line.trim();
    if (l.isEmpty) continue;
    final cols = l.split('","');
    if (cols.length >= 2) {
      final rowPid = cols[1].replaceAll('"', '').trim();
      if (rowPid == '$pid') return true;
    } else if (l.contains(needle)) {
      return true;
    }
  }
  return false;
}

void main() {
  test('§20 CLEANUP: 50 connect/disconnect cycles → zero leaks', () async {
    final coresDir = Directory(
        '${Directory.current.path}${Platform.pathSeparator}cores'
        '${Platform.pathSeparator}${BinaryManager.platformDirName()}');
    if (!coresDir.existsSync()) {
      // ignore: avoid_print
      print('SKIPPED: cores not installed');
      return;
    }
    final bm = BinaryManager(appDir: coresDir);
    final sbInfo = await bm.inspect(CoreBinaryKind.singbox);
    if (sbInfo.status != 'available') return;

    final cycles =
        int.tryParse(Platform.environment['ATLANHIX_CLEANUP_CYCLES'] ?? '50') ??
            50;

    final http = MockHttpServer();
    await http.start();
    addTearDown(http.stop);

    final dir = await Directory.systemTemp.createTemp('nexus-cl50');
    final port = await PortAllocator.freePort(prefer: 33041);
    final cfg = File('${dir.path}${Platform.pathSeparator}ss.json');
    await cfg.writeAsString(
        '{"inbounds":[{"type":"shadowsocks","tag":"ss-in","listen":"127.0.0.1",'
        '"listen_port":$port,"method":"aes-128-gcm","password":"cl-pass-1"}],'
        '"outbounds":[{"type":"direct","tag":"direct"}]}',
        flush: true);
    final ssServer =
        await ManagedProcess.start(sbInfo.path!, ['run', '-c', cfg.path]);
    addTearDown(() => ssServer.stop());

    final profile = ProxyProfile(
      id: 'cl50',
      name: 'cleanup node',
      server: '127.0.0.1',
      port: port,
      protocol: ProxyProtocol.shadowsocks,
      ssMethod: 'aes-128-gcm',
      password: 'cl-pass-1',
    );

    final work = await Directory.systemTemp.createTemp('nexus-cl50-mgr');
    final mgr = CoreManager(binaryManager: bm, workDir: work);
    addTearDown(() => mgr.dispose());
    final allPids = <int>[];
    final durations = <int>[];

    for (var cycle = 0; cycle < cycles; cycle++) {
      final sw = Stopwatch()..start();
      final r = await mgr.startFor(
        profile,
        all: [profile],
        routing: BuiltinRoutingProfiles.all().first,
        dns: DnsSettings(mode: DnsMode.automatic),
      );
      expect(r.ok, isTrue, reason: 'cycle $cycle: ${r.message}');
      if (r.pid != null) allPids.add(r.pid!);
      if (cycle % 10 == 0) {
        // Every 10th cycle carries real traffic to keep the path honest.
        final p = await LatencyTester().testHttpViaSocksProxy('127.0.0.1',
            mgr.front.mixedPort, 'http://127.0.0.1:${http.port}/c$cycle',
            timeout: const Duration(seconds: 6));
        expect(p.ok, isTrue, reason: 'cycle $cycle traffic probe failed');
      }
      await mgr.stop();
      durations.add(sw.elapsedMilliseconds);
    }

    for (final pid in allPids) {
      expect(await processAlive(pid), isFalse,
          reason: 'PID $pid leaked after $cycles cycles');
    }
    final sbDir = Directory('${work.path}${Platform.pathSeparator}singbox');
    if (await sbDir.exists()) {
      expect(await sbDir.list().length, 0,
          reason: 'temp config files must be cleaned');
    }
    final avg = durations.reduce((a, b) => a + b) ~/ durations.length;
    // ignore: avoid_print
    print('METRIC cleanup: $cycles cycles, 0 leaked, avg cycle $avg ms, '
        'max ${durations.reduce((a, b) => a > b ? a : b)} ms');
  }, timeout: const Timeout(Duration(minutes: 12)));

  test('§15 FAST SWITCH: hot switch vs full switch timing', () async {
    final coresDir = Directory(
        '${Directory.current.path}${Platform.pathSeparator}cores'
        '${Platform.pathSeparator}${BinaryManager.platformDirName()}');
    if (!coresDir.existsSync()) {
      // ignore: avoid_print
      print('SKIPPED: cores not installed');
      return;
    }
    final bm = BinaryManager(appDir: coresDir);
    final sbInfo = await bm.inspect(CoreBinaryKind.singbox);
    if (sbInfo.status != 'available') return;

    final http = MockHttpServer();
    await http.start();
    addTearDown(http.stop);

    final dir = await Directory.systemTemp.createTemp('nexus-fs');
    final port = await PortAllocator.freePort(prefer: 33042);
    final cfg = File('${dir.path}${Platform.pathSeparator}ss.json');
    await cfg.writeAsString(
        '{"inbounds":[{"type":"shadowsocks","tag":"ss-in","listen":"127.0.0.1",'
        '"listen_port":$port,"method":"aes-128-gcm","password":"fs-pass-1"}],'
        '"outbounds":[{"type":"direct","tag":"direct"}]}',
        flush: true);
    final ssServer =
        await ManagedProcess.start(sbInfo.path!, ['run', '-c', cfg.path]);
    addTearDown(() => ssServer.stop());

    final a = ProxyProfile(
      id: 'fs-a', name: 'switch A', server: '127.0.0.1', port: port,
      protocol: ProxyProtocol.shadowsocks, ssMethod: 'aes-128-gcm',
      password: 'fs-pass-1',
    );
    final b = ProxyProfile(
      id: 'fs-b', name: 'switch B', server: '127.0.0.1', port: port,
      protocol: ProxyProtocol.shadowsocks, ssMethod: 'aes-128-gcm',
      password: 'fs-pass-1',
    );

    final mgr = CoreManager(
      binaryManager: bm,
      workDir: await Directory.systemTemp.createTemp('nexus-fs-mgr'),
    );
    addTearDown(() => mgr.dispose());
    final start = await mgr.startFor(
      a,
      all: [a, b],
      routing: BuiltinRoutingProfiles.all().first,
      dns: DnsSettings(mode: DnsMode.automatic),
    );
    expect(start.ok, isTrue, reason: start.message);

    // Hot switch: selector swap, engine must NOT restart.
    final pidBefore = start.pid!;
    final swHot = Stopwatch()..start();
    final hot = await mgr.hotSwitch(
      b,
      routing: BuiltinRoutingProfiles.all().first,
      dns: DnsSettings(mode: DnsMode.automatic),
    );
    swHot.stop();
    expect(hot, isTrue, reason: 'hot switch failed');
    expect(mgr.front.lastPid, pidBefore,
        reason: 'hot switch must not restart the engine');
    final probeHot = await LatencyTester().testHttpViaSocksProxy('127.0.0.1',
        mgr.front.mixedPort, 'http://127.0.0.1:${http.port}/hot',
        timeout: const Duration(seconds: 8));
    expect(probeHot.ok, isTrue, reason: 'traffic broken after hot switch');

    // Full switch: startFor restart path.
    final swFull = Stopwatch()..start();
    final full = await mgr.startFor(
      a,
      all: [a, b],
      routing: BuiltinRoutingProfiles.all().first,
      dns: DnsSettings(mode: DnsMode.automatic),
    );
    swFull.stop();
    expect(full.ok, isTrue, reason: full.message);

    // ignore: avoid_print
    print('METRIC hot-switch: ${swHot.elapsedMilliseconds} ms, '
        'full-switch: ${swFull.elapsedMilliseconds} ms');
    await mgr.stop();
  }, timeout: const Timeout(Duration(seconds: 120)));
}
