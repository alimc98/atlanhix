import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/logger.dart';
import 'package:nexus/core/runtime/binary_manager.dart';
import 'package:nexus/core/runtime/core_manager.dart';
import 'package:nexus/core/runtime/core_process.dart';
import 'package:nexus/core/runtime/core_runtime.dart';
import 'package:nexus/domain/entities/proxy_profile.dart';
import 'package:nexus/routing/builtin_profiles.dart';
import 'package:nexus/routing/routing_models.dart';

ProxyProfile _node(String id,
        {ProxyProtocol proto = ProxyProtocol.vless,
        CoreKind core = CoreKind.singbox}) =>
    ProxyProfile(
      id: id,
      name: 'n-$id',
      server: '$id.example.com',
      port: 443,
      protocol: proto,
      uuid: 'u-$id',
      core: core,
    );

void main() {
  group('ManagedProcess (Phase 1)', () {
    test('starts, reports running, and stops cleanly', () async {
      final exe = Platform.isWindows ? 'cmd' : 'sh';
      final args = Platform.isWindows
          ? ['/c', 'ping', '-n', '30', '127.0.0.1']
          : ['-c', 'sleep 30'];
      final p = await ManagedProcess.start(exe, args);
      expect(p.isRunning, isTrue);
      expect(p.pid, greaterThan(0));
      await p.stop();
      expect(p.isRunning, isFalse);
      expect(p.exitCode, isNotNull);
    });

    test('exit watcher fires with classified exit', () async {
      final exe = Platform.isWindows ? 'cmd' : 'sh';
      final args = Platform.isWindows ? ['/c', 'exit', '3'] : ['-c', 'exit 3'];
      final p = await ManagedProcess.start(exe, args);
      final code = await p.onExit.timeout(const Duration(seconds: 10));
      expect(code, 3);
      final kind = classifyExit(code, '', const Duration(milliseconds: 100));
      expect(kind, CoreExitKind.unknown);
    });

    test('PortAllocator returns free loopback ports', () async {
      final a = await PortAllocator.freePort();
      final b = await PortAllocator.freePort();
      expect(a, greaterThan(0));
      expect(b, greaterThan(0));
    });
  });

  group('Logger redaction (Phase 31)', () {
    test('redacts uuids, private keys and credential params', () {
      final red = Logger.redact;
      expect(red('uuid=550e8400-e29b-41d4-a716-446655440000'),
          isNot(contains('550e8400-e29b')));
      expect(red('PrivateKey = aBcDeFgHiJkLmNoPqRsTuVwXyZ='),
          isNot(contains('aBcDeFgHiJkLmNoPqRsTuVwXyZ=')));
      expect(red('password=hunter2'), isNot(contains('hunter2')));
    });
  });


group('CoreManager runtime orchestration (Phases 1/4/5)', () {
  final coresDir = Directory(
      '${Directory.current.path}${Platform.pathSeparator}cores'
      '${Platform.pathSeparator}${BinaryManager.platformDirName()}');
  final hasCores = coresDir.existsSync();

  test('start → running → hotSwitch verified → stop', () async {
    if (!hasCores) {
      // ignore: avoid_print
      print('SKIP: cores not installed');
      return;
    }
    final mgr = CoreManager(
      binaryManager: BinaryManager(appDir: coresDir),
      workDir: await Directory.systemTemp.createTemp('nexus-mgr'),
    );
    addTearDown(() => mgr.dispose());
    await mgr.prepare();

    final a = _node('node-a', proto: ProxyProtocol.shadowsocks)
      ..ssMethod = 'aes-256-gcm'
      ..password = 'ss-pass';
    final b = _node('node-b', proto: ProxyProtocol.trojan)
      ..password = 'trojan-pass';

    final start = await mgr.startFor(
      a,
      all: [a, b],
      routing: BuiltinRoutingProfiles.all().first,
      dns: DnsSettings(mode: DnsMode.automatic),
    );
    expect(start.ok, isTrue, reason: start.message);
    expect(mgr.front.status, RuntimeStatus.running);

    // Phase 5: same-family hot switch must succeed via Clash API.
    final hot = await mgr.hotSwitch(
      b,
      routing: BuiltinRoutingProfiles.all().first,
      dns: DnsSettings(mode: DnsMode.automatic),
    );
    expect(hot, isTrue, reason: 'selector swap failed');
    expect(mgr.front.status, RuntimeStatus.running,
        reason: 'engine must NOT restart on hot switch');

    await mgr.stop();
    expect(mgr.front.status, RuntimeStatus.stopped);
  });

  test('clean start/stop cycle is repeatable', () async {
    if (!hasCores) return;
    final mgr = CoreManager(
      binaryManager: BinaryManager(appDir: coresDir),
      workDir: await Directory.systemTemp.createTemp('nexus-mgr2'),
    );
    addTearDown(() => mgr.dispose());
    await mgr.prepare();
    final n = _node('c1', proto: ProxyProtocol.shadowsocks)
      ..ssMethod = 'aes-256-gcm'
      ..password = 'ss-pass';
    for (var i = 0; i < 2; i++) {
      final r = await mgr.startFor(
        n,
        all: [n],
        routing: BuiltinRoutingProfiles.all().first,
        dns: DnsSettings(mode: DnsMode.automatic),
      );
      expect(r.ok, isTrue, reason: 'cycle $i: ${r.message}');
      await mgr.stop();
    }
  });
});
}
