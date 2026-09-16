// v0.4.6 §user — fragment AUTO ladder regression tests.
//
// The AUTO preset must:
//  1) start every connect at the SAFE rung (conservative), or at a node's
//     persisted winning rung from the ladder cache;
//  2) climb conservative → default → aggressive ONLY on failed probes,
//     driven explicitly by CoreManager.advanceAutoLadder();
//  3) emit the escalated rung's real fragment parameters into the Xray
//     config (the profile actually changes between attempts);
//  4) persist the winning rung per node id (structure only — no identity).
//
// These tests pin the pure state machine + mapping + persistence without
// spawning real engines; the shape of the generated configs is verified
// against XrayConfigGenerator directly.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/configgen/xray_config_generator.dart';
import 'package:nexus/core/fragmentation/fragment_ladder_cache.dart';
import 'package:nexus/core/fragmentation/fragment_profiles.dart';
import 'package:nexus/core/runtime/binary_manager.dart';
import 'package:nexus/core/runtime/core_manager.dart';
import 'package:nexus/data/app_storage.dart';
import 'package:nexus/domain/entities/proxy_profile.dart';
import 'package:nexus/routing/builtin_profiles.dart';
import 'package:nexus/settings/app_settings.dart';

ProxyProfile _vlessXhttpTls() => ProxyProfile(
      id: 'auto-node-1',
      name: 'auto node',
      server: 'cdn.example.com',
      port: 443,
      protocol: ProxyProtocol.vless,
      transport: Transport.xhttp,
      security: Security.tls,
      uuid: 'u1',
      sni: 'cdn.example.com',
      path: '/api',
    );

Map<String, dynamic> _configWith(CoreManager cores, ProxyProfile p) =>
    XrayConfigGenerator().generate(
      profile: p,
      localSocksPort: 2081,
      routing: BuiltinRoutingProfiles.all().first,
      fragment: cores.fragmentFor(p),
    );

String _fragmentPackets(Map<String, dynamic> cfg) {
  final frag = (cfg['outbounds'] as List)
      .firstWhere((o) => (o as Map)['tag'] == 'fragment-out') as Map;
  return ((frag['settings'] as Map)['fragment'] as Map)['packets'] as String;
}

void main() {
  group('AUTO ladder state machine (CoreManager)', () {
    test('fixed presets never climb; AUTO climbs the safe order', () {
      final work = Directory.systemTemp.createTempSync('nexus-auto-fixed');
      final cores = CoreManager(
        binaryManager: BinaryManager(appDir: work),
        workDir: work,
      );
      addTearDown(() {
        cores.dispose();
        work.deleteSync(recursive: true);
      });

      // Fixed: advanceAutoLadder is always a no-op.
      cores.fragmentPreset = FragmentPreset.conservative;
      expect(cores.advanceAutoLadder(), isFalse);

      // AUTO: exactly two climbs to reach aggressive, then exhaustion.
      cores.tlsFragmentEnabled = true;
      cores.fragmentPreset = FragmentPreset.auto;
      expect(cores.autoLadderOrder, [0, 1, 2],
          reason: 'no winner/suggestion → plain conservative-first order');
      expect(cores.currentAutoFragment!.id, 'conservative',
          reason: 'AUTO must start at the safe rung');
      expect(cores.advanceAutoLadder(), isTrue);
      expect(cores.currentAutoFragment!.id, 'default');
      expect(cores.advanceAutoLadder(), isTrue);
      expect(cores.currentAutoFragment!.id, 'aggressive');
      expect(cores.currentAutoFragment!.id, 'aggressive',
          reason: 'last rung re-emits itself, not an overflow');
      expect(cores.advanceAutoLadder(), isFalse,
          reason: 'the ladder must STOP at aggressive');
    });

    test('stop() keeps the climb; beginAutoLadder is the ONLY rewind',
        () async {
      final work = Directory.systemTemp.createTempSync('nexus-auto-reset');
      final cores = CoreManager(
        binaryManager: BinaryManager(appDir: work),
        workDir: work,
      );
      addTearDown(() {
        cores.dispose();
        work.deleteSync(recursive: true);
      });
      cores.tlsFragmentEnabled = true;
      cores.fragmentPreset = FragmentPreset.auto;
      cores.advanceAutoLadder();
      cores.advanceAutoLadder();
      expect(cores.currentAutoFragment!.id, 'aggressive');
      // Engine restarts happen BETWEEN rungs — stop() must NOT rewind the
      // ladder, or the escalation loop would loop rung 0↔1 forever.
      cores.stop();
      expect(cores.currentAutoFragment!.id, 'aggressive',
          reason: 'stop() keeps the climbed position');
      // A fresh connect rewinds exactly here.
      cores.beginAutoLadder(_vlessXhttpTls());
      expect(cores.currentAutoFragment!.id, 'conservative',
          reason: 'every fresh connect starts from rung 0');
      expect(cores.autoLadderOrder, [0, 1, 2]);
    });

    test('beginAutoLadder starts at the persisted winning rung', () {
      final work = Directory.systemTemp.createTempSync('nexus-auto-begin');
      final cores = CoreManager(
        binaryManager: BinaryManager(appDir: work),
        workDir: work,
      );
      addTearDown(() {
        cores.dispose();
        work.deleteSync(recursive: true);
      });
      cores.tlsFragmentEnabled = true;
      cores.fragmentPreset = FragmentPreset.auto;
      cores.fragmentLadder = FragmentLadderCache(_FakeStore()
        ..sections['fragmentLadder'] = {'auto-node-1': 'aggressive'});
      cores.beginAutoLadder(_vlessXhttpTls());
      expect(cores.currentAutoFragment!.id, 'aggressive',
          reason:
              'a node that already climbed starts where it worked, not at 0');

      // v0.4.6 §user-2 wrap-around: the winner only SHIFTS the start — the
      // skipped lower rungs are still tried before giving up.
      expect(cores.advanceAutoLadder(), isTrue);
      expect(cores.currentAutoFragment!.id, 'conservative');
      expect(cores.advanceAutoLadder(), isTrue);
      expect(cores.currentAutoFragment!.id, 'default');
      expect(cores.advanceAutoLadder(), isFalse);
    });

    test('beginAutoLadder for a fixed preset leaves the ladder untouched',
        () {
      final work = Directory.systemTemp.createTempSync('nexus-auto-fxd2');
      final cores = CoreManager(
        binaryManager: BinaryManager(appDir: work),
        workDir: work,
      );
      addTearDown(() {
        cores.dispose();
        work.deleteSync(recursive: true);
      });
      cores.tlsFragmentEnabled = true;
      cores.fragmentPreset = FragmentPreset.aggressive;
      cores.beginAutoLadder(_vlessXhttpTls());
      expect(cores.fragmentFor(_vlessXhttpTls())!.id, 'aggressive');
    });
  });

  group('AUTO rung → real Xray config shape', () {
    test('escalating the rung changes the emitted fragment parameters', () {
      final work = Directory.systemTemp.createTempSync('nexus-auto-shape');
      final cores = CoreManager(
        binaryManager: BinaryManager(appDir: work),
        workDir: work,
      );
      addTearDown(() {
        cores.dispose();
        work.deleteSync(recursive: true);
      });
      cores.tlsFragmentEnabled = true;
      cores.fragmentPreset = FragmentPreset.auto;
      final p = _vlessXhttpTls()..core = CoreKind.xray;

      expect(_fragmentPackets(_configWith(cores, p)), 'tlshello',
          reason: 'rung 0 = conservative');
      cores.advanceAutoLadder();
      expect(_fragmentPackets(_configWith(cores, p)), 'tlshello',
          reason: 'rung 1 = default (still tlshello, different length)');
      cores.advanceAutoLadder();
      expect(_fragmentPackets(_configWith(cores, p)), '1-3',
          reason: 'rung 2 = aggressive');
    });

    test('pill off → fragmentFor returns null at any rung', () {
      final work = Directory.systemTemp.createTempSync('nexus-auto-off');
      final cores = CoreManager(
        binaryManager: BinaryManager(appDir: work),
        workDir: work,
      );
      addTearDown(() {
        cores.dispose();
        work.deleteSync(recursive: true);
      });
      cores.fragmentPreset = FragmentPreset.auto;
      expect(cores.fragmentFor(_vlessXhttpTls()), isNull,
          reason: 'opt-in only — the pill must be ON for any rung to emit');
    });

    test('ineligible node (sing-box core) → null even with AUTO on', () {
      final work = Directory.systemTemp.createTempSync('nexus-auto-inel');
      final cores = CoreManager(
        binaryManager: BinaryManager(appDir: work),
        workDir: work,
      );
      addTearDown(() {
        cores.dispose();
        work.deleteSync(recursive: true);
      });
      cores.tlsFragmentEnabled = true;
      cores.fragmentPreset = FragmentPreset.auto;
      final singboxNode = _vlessXhttpTls()..core = CoreKind.singbox;
      expect(cores.fragmentFor(singboxNode), isNull,
          reason: 'eligibility gate wins over the ladder');
    });
  });

  group('subscription suggestion chain (v0.4.6 §user-2)', () {
    test('sibling node STARTS at the subscription suggestion, wraps through '
        'the skipped rungs', () {
      final work = Directory.systemTemp.createTempSync('nexus-auto-sugg');
      final cores = CoreManager(
        binaryManager: BinaryManager(appDir: work),
        workDir: work,
      );
      addTearDown(() {
        cores.dispose();
        work.deleteSync(recursive: true);
      });
      cores.tlsFragmentEnabled = true;
      cores.fragmentPreset = FragmentPreset.auto;

      final sibling = _vlessXhttpTls()
        ..core = CoreKind.xray
        ..subscriptionId = 'sub-9';
      cores.fragmentLadder = FragmentLadderCache(_FakeStore()
        ..sections['fragmentLadderSuggestions'] = {'sub-9': 'aggressive'});

      cores.beginAutoLadder(sibling);
      expect(cores.autoLadderOrder, [2, 0, 1],
          reason:
              'start at the suggested aggressive rung, then wrap 0 → 1');
      expect(cores.currentAutoFragment!.id, 'aggressive');
      // Full wrap: ALL rungs are still tried before giving up.
      expect(cores.advanceAutoLadder(), isTrue);
      expect(cores.currentAutoFragment!.id, 'conservative');
      expect(cores.advanceAutoLadder(), isTrue);
      expect(cores.currentAutoFragment!.id, 'default');
      expect(cores.advanceAutoLadder(), isFalse);
    });

    test('per-node winner beats the subscription suggestion', () {
      final work = Directory.systemTemp.createTempSync('nexus-auto-prio');
      final cores = CoreManager(
        binaryManager: BinaryManager(appDir: work),
        workDir: work,
      );
      addTearDown(() {
        cores.dispose();
        work.deleteSync(recursive: true);
      });
      cores.tlsFragmentEnabled = true;
      cores.fragmentPreset = FragmentPreset.auto;
      final node = _vlessXhttpTls()
        ..core = CoreKind.xray
        ..subscriptionId = 'sub-9';
      cores.fragmentLadder = FragmentLadderCache(_FakeStore()
        ..sections['fragmentLadder'] = {'auto-node-1': 'default'}
        ..sections['fragmentLadderSuggestions'] = {'sub-9': 'aggressive'});

      cores.beginAutoLadder(node);
      expect(cores.autoLadderOrder, [1, 2, 0],
          reason: 'own winner (default) outranks the sibling suggestion');
      expect(cores.currentAutoFragment!.id, 'default');
    });

    test('suggestion from another subscription does not leak', () {
      final work = Directory.systemTemp.createTempSync('nexus-auto-leak');
      final cores = CoreManager(
        binaryManager: BinaryManager(appDir: work),
        workDir: work,
      );
      addTearDown(() {
        cores.dispose();
        work.deleteSync(recursive: true);
      });
      cores.tlsFragmentEnabled = true;
      cores.fragmentPreset = FragmentPreset.auto;
      final stranger = _vlessXhttpTls()
        ..core = CoreKind.xray
        ..subscriptionId = 'sub-other';
      cores.fragmentLadder = FragmentLadderCache(_FakeStore()
        ..sections['fragmentLadderSuggestions'] = {'sub-9': 'aggressive'});

      cores.beginAutoLadder(stranger);
      expect(cores.autoLadderOrder, [0, 1, 2],
          reason: 'conservative-first for subscriptions with no evidence');
    });

    test('manual nodes (subscriptionId null) are never suggested into', () {
      final work = Directory.systemTemp.createTempSync('nexus-auto-man');
      final cores = CoreManager(
        binaryManager: BinaryManager(appDir: work),
        workDir: work,
      );
      addTearDown(() {
        cores.dispose();
        work.deleteSync(recursive: true);
      });
      cores.tlsFragmentEnabled = true;
      cores.fragmentPreset = FragmentPreset.auto;
      final manual = _vlessXhttpTls()..core = CoreKind.xray;
      cores.fragmentLadder = FragmentLadderCache(_FakeStore()
        ..sections['fragmentLadderSuggestions'] = {'': 'aggressive'});

      cores.beginAutoLadder(manual);
      expect(cores.autoLadderOrder, [0, 1, 2],
          reason: 'null/empty subscriptionId → no suggestion lookup');
    });

    test('recordSuggestion round-trips through a JsonStore section',
        () async {
      final dir = await Directory.systemTemp.createTemp('nexus-auto-sug2');
      addTearDown(() => dir.deleteSync(recursive: true));
      final store = JsonStore(directory: dir);
      await store.load();
      final cache = FragmentLadderCache(store);
      expect(cache.suggestionFor('sub-9'), isNull);

      await cache.recordSuggestion('sub-9', FragmentPresets.aggressive);
      expect(cache.suggestionFor('sub-9')!.id, 'aggressive');
      // Sibling instance (restart) reads the same section.
      expect(FragmentLadderCache(store).suggestionFor('sub-9')!.id,
          'aggressive');
      // null/empty subscription and non-vocabulary ids are no-ops.
      await cache.recordSuggestion(null, FragmentPresets.defaultPreset);
      await cache.recordSuggestion('', FragmentPresets.defaultPreset);
      await cache.recordSuggestion(
          'sub-x',
          const FragmentProfile(
              id: 'turbo', name: 'x', packets: '1-3', length: '1-2',
              interval: '1-2'));
      expect(cache.suggestionFor('sub-x'), isNull);

      await store.flush(); // no pending debounce timer across the test
    });
  });

  group('FragmentLadderCache (per-node winner persistence)', () {
    test('round-trips the winner through a JsonStore section', () async {
      final dir = await Directory.systemTemp.createTemp('nexus-auto-store');
      addTearDown(() => dir.deleteSync(recursive: true));
      final store = JsonStore(directory: dir);
      await store.load();

      final cache = FragmentLadderCache(store);
      expect(cache.winnerFor('auto-node-1'), isNull);

      await cache.recordWinner('auto-node-1', FragmentPresets.aggressive);
      expect(cache.winnerFor('auto-node-1')!.id, 'aggressive');
      await store.flush(); // no pending debounce timer across the test

      // A NEW cache instance (app restart) reads the same section.
      final cache2 = FragmentLadderCache(store);
      expect(cache2.winnerFor('auto-node-1')!.id, 'aggressive');

      // clear() forgets.
      await cache2.clear();
      expect(cache2.winnerFor('auto-node-1'), isNull);

      // JsonStore debounces writes on a 400ms Timer — flush it away so
      // flutter_test does not see a pending timer at test end.
      await store.flush();
    });

    test('ignores ids outside the preset vocabulary', () async {
      final dir = await Directory.systemTemp.createTemp('nexus-auto-bad');
      addTearDown(() => dir.deleteSync(recursive: true));
      final store = JsonStore(directory: dir);
      await store.load();
      final cache = FragmentLadderCache(store);
      await cache.recordWinner(
          'auto-node-1',
          const FragmentProfile(
              id: 'turbo', name: 'x', packets: '1-3', length: '1-2',
              interval: '1-2'));
      expect(cache.winnerFor('auto-node-1'), isNull,
          reason: 'only real preset rungs are persisted');
    });
  });

  group('per-subscription rung win-rate stats (v0.4.6 §user-3)', () {
    test('attempts and wins accumulate per rung; failed rungs count too',
        () async {
      final dir = await Directory.systemTemp.createTemp('nexus-auto-stat');
      addTearDown(() => dir.deleteSync(recursive: true));
      final store = JsonStore(directory: dir);
      await store.load();
      final cache = FragmentLadderCache(store);
      expect(cache.statsFor('sub-9'), isEmpty);

      // A climb that failed conservative twice, won default once, and
      // never probed aggressive → honest 0/1 for aggressive.
      await cache.recordRungAttempt('sub-9', FragmentPresets.conservative,
          won: false);
      await cache.recordRungAttempt('sub-9', FragmentPresets.conservative,
          won: false);
      await cache.recordRungAttempt('sub-9', FragmentPresets.defaultPreset,
          won: true);

      final stats = cache.statsFor('sub-9');
      expect(stats['conservative'], [2, 0]);
      expect(stats['default'], [1, 1]);
      expect(stats.containsKey('aggressive'), isFalse);

      // Survives a fresh cache instance (restart).
      final again = FragmentLadderCache(store);
      expect(again.statsFor('sub-9')['default'], [1, 1]);
      await store.flush();
    });

    test('events outside the 30-day window age out of the aggregation',
        () async {
      final dir = await Directory.systemTemp.createTemp('nexus-auto-age');
      addTearDown(() => dir.deleteSync(recursive: true));
      final store = JsonStore(directory: dir);
      await store.load();
      final cache = FragmentLadderCache(store);

      await cache.recordRungAttempt('sub-9', FragmentPresets.conservative,
          won: true);
      await cache.recordRungAttempt('sub-9', FragmentPresets.defaultPreset,
          won: true);
      expect(cache.statsFor('sub-9')['conservative'], [1, 1]);

      // Rewrite the store with an OLD event for conservative (40 days ago)
      // plus a fresh one for default, then reload from a NEW cache instance
      // (as an app restart would).
      final fresh = DateTime.now().millisecondsSinceEpoch;
      final old = DateTime.now()
          .subtract(fragmentStatWindow + const Duration(days: 10))
          .millisecondsSinceEpoch;
      await store.putSection('fragmentLadderStats', {
        'sub-9': {
          'conservative': [[old, 1]],
          'default': [[fresh, 1]],
        },
      });
      await store.flush();
      final reloaded = FragmentLadderCache(store);
      final aged = reloaded.statsFor('sub-9');
      expect(aged.containsKey('conservative'), isFalse,
          reason: 'a probe older than the window is not evidence');
      expect(aged['default'], [1, 1]);
      expect(reloaded.bestRungFor('sub-9')!.id, 'default',
          reason: 'bestRung only aggregates in-window events');
    });

    test('event store is capped per rung (bounded growth)', () async {
      final dir = await Directory.systemTemp.createTemp('nexus-auto-cap');
      addTearDown(() => dir.deleteSync(recursive: true));
      final store = JsonStore(directory: dir);
      await store.load();
      final cache = FragmentLadderCache(store);
      for (var i = 0; i < fragmentStatMaxEvents + 40; i++) {
        await cache.recordRungAttempt(
            'sub-9', FragmentPresets.conservative,
            won: i % 2 == 0);
      }
      final stats = cache.statsFor('sub-9')['conservative']!;
      expect(stats[0], fragmentStatMaxEvents,
          reason: 'the cap bounds store growth');
      // The newest event wins/losses are what remain (last 40: indexes
      // 460..539 → 20 wins, 20 losses among the kept newest set is NOT
      // asserted exactly here; only the cap shape matters).
      expect(stats[1], lessThanOrEqualTo(stats[0]));
      await store.flush();
    });

    test('resetStatsFor forgets only the given subscription', () async {
      final dir = await Directory.systemTemp.createTemp('nexus-auto-rst');
      addTearDown(() => dir.deleteSync(recursive: true));
      final store = JsonStore(directory: dir);
      await store.load();
      final cache = FragmentLadderCache(store);
      await cache.recordRungAttempt('sub-9', FragmentPresets.conservative,
          won: true);
      await cache.recordRungAttempt('sub-other',
          FragmentPresets.conservative, won: true);

      await cache.resetStatsFor('sub-9');
      expect(cache.statsFor('sub-9'), isEmpty);
      expect(cache.statsFor('sub-other')['conservative'], [1, 1],
          reason: 'other subscriptions keep their evidence');
      // Winner + suggestion are identity mappings, NOT observations: a
      // stats reset must not erase them.
      await cache.recordWinner('auto-node-1', FragmentPresets.defaultPreset);
      await cache.recordSuggestion('sub-9', FragmentPresets.defaultPreset);
      await cache.resetStatsFor('sub-9');
      expect(cache.winnerFor('auto-node-1')!.id, 'default');
      expect(cache.suggestionFor('sub-9')!.id, 'default');
      // no-ops: null/empty/unknown ids never throw.
      await cache.resetStatsFor(null);
      await cache.resetStatsFor('');
      await cache.resetStatsFor('never-seen');

      await store.flush();
    });

    test('legacy [attempts, wins] stat entries are ignored safely',
        () async {
      final dir = await Directory.systemTemp.createTemp('nexus-auto-old');
      addTearDown(() => dir.deleteSync(recursive: true));
      final store = JsonStore(directory: dir);
      await store.load();
      // A pre-lifecycle store (counters, not event lists) must not crash.
      await store.putSection('fragmentLadderStats', {
        'sub-9': {
          'conservative': [5, 4],
        },
      });
      final cache = FragmentLadderCache(store);
      expect(cache.statsFor('sub-9'), isEmpty,
          reason: 'counter-shaped legacy data is skipped, not parsed');
      expect(cache.bestRungFor('sub-9'), isNull);
    });

    test('bestRungFor: highest win rate, ties resolve to the SAFER rung',
        () async {
      final dir = await Directory.systemTemp.createTemp('nexus-auto-best');
      addTearDown(() => dir.deleteSync(recursive: true));
      final store = JsonStore(directory: dir);
      await store.load();
      final cache = FragmentLadderCache(store);

      // No evidence → null.
      expect(cache.bestRungFor('sub-9'), isNull);

      // default 1/1 (100%) beats conservative 0/2.
      await cache.recordRungAttempt('sub-9', FragmentPresets.conservative,
          won: false);
      await cache.recordRungAttempt('sub-9', FragmentPresets.conservative,
          won: false);
      await cache.recordRungAttempt('sub-9', FragmentPresets.defaultPreset,
          won: true);
      expect(cache.bestRungFor('sub-9')!.id, 'default');

      // Tie between default (2/2) and aggressive (1/1) at 100% → the
      // SAFER (earlier in strength order) rung wins.
      await cache.recordRungAttempt('sub-9', FragmentPresets.defaultPreset,
          won: true);
      await cache.recordRungAttempt('sub-9', FragmentPresets.aggressive,
          won: true);
      expect(cache.bestRungFor('sub-9')!.id, 'default',
          reason: 'equal rates resolve to the safer rung');

      // A subscription with zero wins anywhere → null, never a guess.
      await cache.recordRungAttempt('sub-0', FragmentPresets.conservative,
          won: false);
      expect(cache.bestRungFor('sub-0'), isNull);

      // null/empty subscription ids → null.
      expect(cache.bestRungFor(null), isNull);
      expect(cache.bestRungFor(''), isNull);

      await store.flush();
    });

    test('recordRungAttempt ignores null/empty subs and foreign rungs',
        () async {
      final dir = await Directory.systemTemp.createTemp('nexus-auto-statg');
      addTearDown(() => dir.deleteSync(recursive: true));
      final store = JsonStore(directory: dir);
      await store.load();
      final cache = FragmentLadderCache(store);
      await cache.recordRungAttempt(
          null, FragmentPresets.conservative,
          won: true);
      await cache.recordRungAttempt('', FragmentPresets.conservative,
          won: true);
      await cache.recordRungAttempt(
          'sub-9',
          const FragmentProfile(
              id: 'turbo', name: 'x', packets: '1-3', length: '1-2',
              interval: '1-2'),
          won: true);
      expect(cache.statsFor('sub-9'), isEmpty);
      expect(cache.statsFor(null), isEmpty);
    });
  });

  test('AppSettings round-trips fragmentPreset == auto', () {
    final s = AppSettings()..fragmentPreset = FragmentPreset.auto;
    final r = AppSettings.fromJson(s.toJson());
    expect(r.fragmentPreset, FragmentPreset.auto);
    // Unknown stored value still falls back to conservative.
    final r2 = AppSettings.fromJson({'fragmentPreset': 'turbo'});
    expect(r2.fragmentPreset, FragmentPreset.conservative);
  });
}

/// Minimal JsonStore stand-in: FragmentLadderCache only needs
/// section()/putSection(), and the production JsonStore debounces writes —
/// a synchronous map keeps the state-machine tests deterministic.
class _FakeStore implements JsonStore {
  final sections = <String, Map<String, dynamic>>{};

  @override
  Map<String, dynamic> section(String key) =>
      sections[key] ?? <String, dynamic>{};

  @override
  Future<void> putSection(String key, Map<String, dynamic> value) async {
    sections[key] = Map<String, dynamic>.of(value);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
