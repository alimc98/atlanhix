// v0.4.6 §user — REAL behavioral exercise of the fragment AUTO ladder:
// repeated connect→probe→disconnect cycles against a REAL xhttp node, with
// forced ladder progression and a persistence sanity sweep across restarts.
//
// Gated exactly like the other real-world E2E tests so NO credentials are
// ever committed; absent variables → clean SKIP, never a silent pass:
//
//   NEXUS_E2E_XHTTP_URI    vless://…type=xhttp share link (Xray-owned node)
//   ATLANHIX_LADDER_E2E=1  explicit opt-in (the cycles are slow: full engine
//                          restart per ladder rung)
//   ATLANHIX_LADDER_CYCLES number of connect/disconnect cycles (default 3)
//
// What is pinned here (the things unit tests CANNOT see):
//   1. the ladder actually progresses through real engine restarts and the
//      winning rung's generated config carries that rung's real parameters;
//   2. the per-node winner persists through a fresh cache instance and the
//      NEXT connect begins AT the winning rung (climb-order shortcut);
//   3. repeated stop()/startFor() cycles leak no engine processes;
//   4. a manual node (no subscriptionId) contributes NO per-sub stats — the
//      win-rate aggregation stays honest about its scope.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/fragmentation/fragment_ladder_cache.dart';
import 'package:nexus/core/fragmentation/fragment_profiles.dart';
import 'package:nexus/core/health/latency_tester.dart';
import 'package:nexus/core/runtime/binary_manager.dart';
import 'package:nexus/core/runtime/core_manager.dart';
import 'package:nexus/data/app_storage.dart';
import 'package:nexus/domain/entities/proxy_profile.dart';
import 'package:nexus/protocols/importer.dart';
import 'package:nexus/routing/builtin_profiles.dart';
import 'package:nexus/routing/routing_models.dart';
import 'package:nexus/settings/app_settings.dart';

import 'e2e_real_test.dart' show processAlive;
import 'helpers/mock_servers.dart';

Future<bool> _probe(LatencyTester tester, CoreManager cores,
    MockHttpServer http, String marker) async {
  final r = await tester.testHttpViaSocksProxy(
      '127.0.0.1', cores.front.mixedPort,
      'http://127.0.0.1:${http.port}/$marker',
      timeout: const Duration(seconds: 10));
  return r.ok;
}

String? _packetsOf(CoreManager cores, ProxyProfile p) {
  final frag = cores.fragmentFor(p);
  if (frag == null) return null;
  return frag.packets;
}

void main() {
  test('REAL xhttp node: fragment AUTO ladder behavioral cycles (env-gated)',
      () async {
    final uri = Platform.environment['NEXUS_E2E_XHTTP_URI'];
    final enabled = Platform.environment['ATLANHIX_LADDER_E2E'] == '1';
    if (uri == null || uri.isEmpty || !enabled) {
      // ignore: avoid_print
      print('SKIPPED: set NEXUS_E2E_XHTTP_URI + ATLANHIX_LADDER_E2E=1 '
          'to run the ladder behavioral cycles');
      return;
    }
    final cycles =
        int.tryParse(Platform.environment['ATLANHIX_LADDER_CYCLES'] ?? '3') ??
            3;

    final imported = MultiFormatImporter().import(uri);
    expect(imported.profiles, isNotEmpty, reason: 'URI must parse');
    final profile = imported.profiles.first
      ..core = CoreKind.xray // xhttp ⇒ Xray-owned (detector parity)
      ..subscriptionId = null; // manual URI — no subscription scope

    // Real persistence: a JsonStore over a temp dir, exactly like prod.
    final storeDir =
        await Directory.systemTemp.createTemp('nexus-ladder-e2e-store');
    addTearDown(() => storeDir.deleteSync(recursive: true));
    final store = JsonStore(directory: storeDir);
    await store.load();
    final ladder = FragmentLadderCache(store);

    final http = MockHttpServer();
    await http.start();
    addTearDown(http.stop);

    final coresDir = Directory(
        '${Directory.current.path}${Platform.pathSeparator}cores'
        '${Platform.pathSeparator}${BinaryManager.platformDirName()}');
    final cores = CoreManager(
      binaryManager: BinaryManager(appDir: coresDir),
      workDir: await Directory.systemTemp.createTemp('nexus-ladder-e2e'),
    );
    addTearDown(() => cores.dispose());
    await cores.prepare();
    cores.xray.accessLogPath =
        '${cores.xrayWorkDir}${Platform.pathSeparator}access.log';
    cores.tlsFragmentEnabled = true;
    cores.fragmentPreset = FragmentPreset.auto;
    cores.fragmentLadder = ladder;

    final tester = LatencyTester();
    final pids = <int>[];
    final routing = BuiltinRoutingProfiles.all().first;
    final dns = DnsSettings(mode: DnsMode.automatic);
    var sawAWin = false;
    String? winningRungId;

    for (var cycle = 1; cycle <= cycles; cycle++) {
      // ---- FRESH CONNECT: rewind the ladder, then start+probe ----------
      cores.beginAutoLadder(profile);
      // ignore: avoid_print
      print('LADDER[cycle $cycle] climb order: ${cores.autoLadderOrder}');

      var connected = false;
      String? cycleWinnerId;
      // The climb order holds exactly 3 rungs; step 0 probes the starting
      // rung without advancing, steps 1..2 advance then probe.
      for (var step = 0; step < cores.autoLadderOrder.length; step++) {
        if (step > 0) {
          expect(cores.advanceAutoLadder(), isTrue,
              reason: 'climb order must have a next rung mid-ladder');
          await cores.stop(); // mid-ladder restart, like connect()
        }
        final rung = cores.currentAutoFragment!;
        final start = await cores.startFor(
          profile,
          all: [profile],
          routing: routing,
          dns: dns,
        );
        expect(start.ok, isTrue,
            reason: 'engine start failed at rung ${rung.id}: '
                '${start.message}');
        if (start.pid != null) pids.add(start.pid!);
        final ok = await _probe(tester, cores, http, 'c$cycle-s$step');
        // Manual node (subscriptionId == null) → the cache no-ops this by
        // design; the call still exercises the real recording path.
        await ladder.recordRungAttempt(profile.subscriptionId, rung,
            won: ok);
        // ignore: avoid_print
        print('LADDER[cycle $cycle] rung=${rung.id} '
            'packets=${_packetsOf(cores, profile)} probe=$ok');
        if (ok) {
          connected = true;
          sawAWin = true;
          cycleWinnerId = rung.id;
          await ladder.recordWinner(profile.id, rung);
          break;
        }
      }
      // The REAL ladder in ConnectionController wraps through all rungs and
      // then reports an honest failure; here a win is REQUIRED — the node
      // was given by the operator and must serve through SOME rung.
      expect(connected, isTrue,
          reason: 'no fragment rung served the real node in cycle $cycle');
      winningRungId = cycleWinnerId;

      // ---- DISCONNECT: hygiene -----------------------------------------
      await cores.stop();
      for (final pid in pids) {
        expect(await processAlive(pid), isFalse,
            reason: 'engine process $pid leaked after cycle $cycle');
      }
      pids.clear();
    }

    // ---- PERSISTENCE SANITY: next connect starts at the winner ----------
    expect(sawAWin, isTrue);
    final reloaded = FragmentLadderCache(store);
    final winner = reloaded.winnerFor(profile.id);
    expect(winner, isNotNull,
        reason: 'the winning rung must survive a cache instance change');
    expect(winner!.id, winningRungId);

    cores.beginAutoLadder(profile);
    expect(cores.autoLadderOrder.first,
        FragmentPresets.all.indexWhere((p) => p.id == winner.id),
        reason: 'the next connect must START at the proven rung');
    expect(cores.currentAutoFragment!.id, winner.id);

    // Manual node ⇒ per-subscription stats stay empty (scope honesty).
    expect(reloaded.statsFor(null), isEmpty);
    expect(reloaded.bestRungFor(null), isNull);
  }, timeout: const Timeout(Duration(minutes: 10)));
}
