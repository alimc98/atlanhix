import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/runtime/binary_manager.dart';
import 'package:nexus/core/runtime/core_manager.dart';
import 'package:nexus/domain/entities/proxy_profile.dart';
import 'package:nexus/protocols/importer.dart';
import 'package:nexus/routing/builtin_profiles.dart';
import 'package:nexus/routing/routing_models.dart';

/// v0.6.5 §mihomo-fix — REAL engine session check for the mihomo path.
///
/// Runs only when an actual mihomo binary is present (dev layout
/// `cores/<platform>-<arch>/mihomo…`); otherwise it skips, exactly like the
/// other runtime integration suites. The user report this pins:
/// «انجین mihomo هست، کانفیگ‌ها وصل نمیشن ولی عوض می‌کنیم وصل می‌شن» —
/// i.e. a mihomo-owned session must come UP through the app's own wiring:
///   CoreManager.startFor(core=mihomo)
///     → engine process up (Clash API ready on the app's port)
///     → the mixed inbound actually ACCEPTS client TCP dials
///     → the app's ClashApiClient talks to the running engine
void main() {
  test('mihomo session: startFor → engine up → mixed port accepts dials',
      () async {
    final exe = Platform.isWindows ? '.exe' : '';
    final candidates = [
      'cores${Platform.pathSeparator}'
          'windows-x64${Platform.pathSeparator}mihomo$exe',
      'cores${Platform.pathSeparator}linux-x64${Platform.pathSeparator}mihomo',
    ];
    final binary = candidates.map(File.new).firstWhere(
          (f) => f.existsSync(),
          orElse: () => File(''),
        );
    if (!binary.existsSync()) {
      // ignore: avoid_print
      print('SKIPPED: no mihomo binary found in cores/ (dev layout)');
      return;
    }

    final work = await Directory.systemTemp.createTemp('mihomo-e2e');
    final cores = CoreManager(
      binaryManager: BinaryManager(appDir: work),
      workDir: work,
    );
    var failures = 0;
    try {
      final profile = MultiFormatImporter()
          .import(
              'vless://8f2c41a8-1a2b-4c3d-9e10-fcafe0b12d34@203.0.113.11:443'
              '?security=tls&sni=cdn.example.com&type=ws&host=cdn.example.com'
              '&path=%2Fws#E2eNode')
          .profiles
          .first
        ..core = CoreKind.mihomo;

      final start = await cores.startFor(
        profile,
        all: [profile],
        routing: BuiltinRoutingProfiles.all().first,
        dns: DnsSettings(mode: DnsMode.automatic),
      );
      expect(start.ok, isTrue,
          reason:
              'startFor failed: ${start.message} '
              'stderr: ${cores.engineStderrTail(CoreKind.mihomo)}');
      if (!start.ok) return;

      // 1) mixed inbound accepts a client TCP dial (engine really serving).
      try {
        final sock = await Socket.connect('127.0.0.1', 2081,
            timeout: const Duration(seconds: 5));
        sock.destroy();
      } catch (e) {
        failures++;
        fail('mixed port 2081 does not accept dials: $e');
      }

      // 2) the app's ClashApiClient talks to the running engine.
      final alive = await cores.mihomo.api?.isAlive();
      expect(alive, isTrue, reason: 'Clash API not reachable after start');
    } finally {
      await cores.stop();
      if (await work.exists()) await work.delete(recursive: true);
    }
    expect(failures, 0);
  }, timeout: const Timeout(Duration(minutes: 2)));
}
