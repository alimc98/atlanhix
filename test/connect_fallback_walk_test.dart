import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/application/dependencies.dart';
import 'package:nexus/core/core_detector.dart';
import 'package:nexus/core/health/latency_tester.dart';
import 'package:nexus/core/health/test_scheduler.dart';
import 'package:nexus/core/runtime/binary_manager.dart';
import 'package:nexus/core/runtime/core_manager.dart';
import 'package:nexus/domain/entities/health.dart';
import 'package:nexus/domain/entities/proxy_profile.dart';
import 'package:nexus/platform/android_vpn.dart';
import 'package:nexus/settings/app_settings.dart';
import 'package:nexus/settings/runtime_config_bridge.dart';
import 'package:nexus/settings/vpn_session.dart';

/// v0.6.8 §smart-fix pins ("وقتی اسمارت سوییچ فعال هست و کانکت می‌کنیم وصل
/// نمی‌کنه، ولی دستی درست میشه"):
///
/// The AUTO path used to be a SINGLE dial — the pre-connect ladder's early
/// pick (or the health-store guess) — and reported failure the moment that
/// one engine start died, while a manual tap on a node the user can see is
/// alive worked. Auto is a REQUEST for a working node, not a single guess:
/// `VpnSession._fallbackWalk` walks the remaining ranked candidates (a REAL
/// dial each — engine resolution, config generation, native handoff, tunnel
/// probe; bounded at 3 extra dials; every burned dial recorded in the health
/// store) before the connect reports failure.
///
/// These tests drive that walk END-TO-END through the real funnel against a
/// scripted native service, so the single-dial regression cannot come back:
///  1. switch ON (the reported scenario): the ladder's pick dies → the walk
///     REDIALS the next ranked node and lands CONNECTED;
///  2. a dead FALLBACK node does not end the walk — the next candidate dials
///     (multi-hop, in ranking order);
///  3. the walk is BOUNDED (≤ 3 extra dials) and reports failure honestly,
///     with every burned dial landing a connect-fail record;
///  4. an EXPLICIT tap never walks — the tapped node IS the request and is
///     never silently swapped;
///  5. a user Stop during the walk ENDS it — no further dials.

ProxyProfile _node(String id, {int port = 443}) => ProxyProfile(
      id: id,
      name: 'Node $id',
      server: '203.0.113.10',
      port: port,
      protocol: ProxyProtocol.shadowsocks,
      ssMethod: 'aes-128-gcm',
      password: 'ss-pass-1',
    );

/// The front config routes via the `proxy` selector; the dialed node is
/// pinned as its `default` (singbox_config_generator.dart) — the sharpest
/// observable of WHICH node an engine start actually serves.
String? selectorDefault(String configJson) {
  final cfg = jsonDecode(configJson) as Map<dynamic, dynamic>;
  for (final ob in (cfg['outbounds'] as List)) {
    final m = ob as Map<dynamic, dynamic>;
    if (m['type'] == 'selector' && m['tag'] == 'proxy') {
      return m['default'] as String?;
    }
  }
  return null;
}

/// The tunnel canary passes instantly: in these tests only the NATIVE verdict
/// decides a dial's life/death, and a LIVE dial must reach CONNECTED without
/// burning the probe budget on top.
class _LiveTester extends LatencyTester {
  @override
  Future<ProbeResult> testHttpViaSocksProxy(
      String proxyHost, int proxyPort, String testUrl,
      {Duration? timeout}) async =>
      ProbeResult(ok: true, latencyMs: 42);
}

/// The native VPN service, scripted PER DIALED NODE (read from the engine
/// handoff's pinned selector default):
///  * [dead] → the start dies a few polls in (FAILED — mock engine death);
///  * [hang] → the start never leaves STARTING (the exact Stop window a user
///    lands in mid-walk);
///  * anything else → CONNECTED on the first poll (the session's own tunnel
///    probe then decides — the fake tester passes it).
class _Natives {
  _Natives({this.dead = const {}, this.hang = const {}});

  final Set<String> dead;
  final Set<String> hang;

  int starts = 0;
  final List<String> startConfigs = <String>[];
  String generation = '';
  bool stopped = false;
  int polls = 0;

  String? get currentTag =>
      startConfigs.isEmpty ? null : selectorDefault(startConfigs.last);

  List<String> get dialedTags =>
      startConfigs.map(selectorDefault).whereType<String>().toList();

  Map<String, Object> handle(String method, Object? arg) {
    switch (method) {
      case 'prepare':
        return {'granted': true};
      case 'start':
        final handoff = jsonDecode(arg! as String) as Map;
        generation = '${handoff['generation']}';
        startConfigs.add('${handoff['configJson']}');
        starts++;
        polls = 0;
        stopped = false;
        return {'ok': true};
      case 'stop':
        stopped = true;
        return {'ok': true};
      case 'state':
        // A stopped service answers STOPPED at once — the FAILED teardown
        // polls for it and would otherwise burn its full 20×150 ms budget.
        if (stopped) return {'state': 'STOPPED', 'generation': generation};
        polls++;
        final tag = currentTag ?? '';
        if (dead.contains(tag)) {
          // Two honest STARTING beats, then the engine dies — the shape a
          // device shows when libbox cannot come up on a node.
          if (polls > 2) {
            return {
              'state': 'FAILED',
              'generation': generation,
              'detail': 'mock engine death',
            };
          }
          return {'state': 'STARTING', 'generation': generation};
        }
        if (hang.contains(tag)) {
          return {'state': 'STARTING', 'generation': generation};
        }
        return {'state': 'CONNECTED', 'generation': generation};
    }
    return {'error': 'unexpected $method'};
  }
}

/// Full session wiring — mirrors the proven harness in connect_cancel_test
/// (bootstrapForTest leaves the funnel's dependencies unset).
Future<VpnSession> _session(
  String tag,
  List<ProxyProfile> profiles, {
  required HealthStore health,
  bool smartSwitch = false,
}) async {
  final deps = await AppDependencies.bootstrapForTest();
  deps.tester = _LiveTester();
  deps.healthStore = health;
  deps.scheduler = TestScheduler(tester: deps.tester, store: deps.healthStore);
  deps.appSettingsRepo = AppSettingsRepository(deps.store);
  deps.appSettings = deps.appSettingsRepo.current;
  deps.routingSettingsRepo = RoutingSettingsRepository(deps.store);
  await deps.routingSettingsRepo.load();
  deps.routingSettings = deps.routingSettingsRepo.current;
  deps.configBridge = RuntimeConfigBridge(
      settings: deps.appSettings, routing: deps.routingSettings);
  // _connectProfileInner resolves the engine HERE (pure logic on host).
  deps.detector = CoreDetector();
  final tmp = await Directory.systemTemp.createTemp('nexus_walk_$tag');
  deps.binaryManager = BinaryManager(appDir: Directory('${tmp.path}/cores'));
  deps.cores = CoreManager(
    binaryManager: deps.binaryManager,
    workDir: Directory('${tmp.path}/runtime'),
    enableTun: false,
  );
  await deps.profiles.upsertMany(profiles);
  final s = VpnSession(deps: deps);
  s.smartSwitch = smartSwitch;
  s.smartSwitchPreferred = smartSwitch;
  return s;
}

/// A landed, healthy URL measurement — seeds both the ladder's cached
/// healthy hand-over and the walk's healthy-first ranking.
void _seed(HealthStore health, String id, int latencyMs) => health.record(
      HealthRecord(
        profileId: id,
        at: DateTime.now(),
        ok: true,
        latencyMs: latencyMs,
      ),
    );

Future<void> _until(bool Function() cond, {int ms = 15000}) async {
  final deadline = DateTime.now().add(Duration(milliseconds: ms));
  while (!cond() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Map<String, Object> Function(String method, Object? arg) handler;
  setUp(() {
    handler = (m, a) => {'error': 'unexpected $m'};
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('dev.atlanhix/vpn'), (call) async {
      final out = handler(call.method, call.arguments);
      return jsonEncode(out);
    });
  });

  test('smart-switch ON: the ladder pick dies → the walk REDIALS the next '
      'ranked node and CONNECTS (the reported single-dial failure)', () async {
    final health = HealthStore();
    _seed(health, 'a', 50); // fastest healthy → the ladder's early pick
    _seed(health, 'b', 200);
    final s = await _session(
      'switch_on',
      [_node('a', port: 1001), _node('b', port: 1002), _node('c', port: 1003)],
      health: health,
      smartSwitch: true,
    );
    final natives = _Natives(dead: {'node:a'});
    handler = natives.handle;

    final ok = await s.connect();

    expect(ok, isTrue,
        reason: 'auto is a REQUEST for a working node — the walk must dial '
            'the next ranked candidate instead of reporting the first '
            'dial\'s death (the device report: auto fails, manual works)');
    expect(natives.startConfigs.map(selectorDefault).toList(),
        ['node:a', 'node:b'],
        reason: 'the ladder pick (a, 50 ms) dials first; the walk then '
            'tries the NEXT ranked node (b, 200 ms) — never a random one');
    expect(s.selectedNode?.id, 'b',
        reason: 'the session must hand over to the node that actually '
            'connected (the ladder\'s incumbent was the corpse)');
    expect(s.controller.phase, AndroidVpnPhase.connected);
    final a = health.statsOf('a');
    expect(a, isNotNull);
    expect(a!.consecutiveFailures, greaterThanOrEqualTo(1),
        reason: 'every dial the walk burns is a real measurement — the '
            'failed pick must land in the health store so the next auto '
            'pick cannot re-choose the corpse');
    expect(a.state, isNot(NodeHealth.healthy));
  });

  test('a dead FALLBACK node does not end the walk — the next candidate is '
      'dialed (multi-hop, ranking order)', () async {
    final health = HealthStore();
    _seed(health, 'a', 50);
    _seed(health, 'b', 200);
    _seed(health, 'c', 300);
    final s = await _session(
      'multihop',
      [_node('a', port: 2001), _node('b', port: 2002), _node('c', port: 2003)],
      health: health,
    );
    final natives = _Natives(dead: {'node:a', 'node:b'});
    handler = natives.handle;

    final ok = await s.connect();

    expect(ok, isTrue,
        reason: 'a dead fallback must not end the walk — the third ranked '
            'node is a working answer to the same request');
    expect(natives.startConfigs.map(selectorDefault).toList(),
        ['node:a', 'node:b', 'node:c'],
        reason: 'the walk follows the SAME healthy-first/latency ranking '
            '_bestNode always used — b (200 ms) before c (300 ms)');
    expect(s.selectedNode?.id, 'c');
    expect(s.controller.phase, AndroidVpnPhase.connected);
    for (final id in ['a', 'b']) {
      expect(health.statsOf(id)?.consecutiveFailures,
          greaterThanOrEqualTo(1),
          reason: 'each dead dial is recorded so the ranking learns');
    }
  });

  test('the walk is BOUNDED (≤ 3 extra dials) and every burned dial lands a '
      'connect-fail record', () async {
    final health = HealthStore();
    // Distinct latencies pin the ranking: e1 fastest … e5 slowest.
    for (var i = 0; i < 5; i++) {
      _seed(health, 'e${i + 1}', 10 * (i + 1));
    }
    final s = await _session(
      'bound',
      [for (var i = 0; i < 5; i++) _node('e${i + 1}', port: 4001 + i)],
      health: health,
    );
    final natives = _Natives(
        dead: {'node:e1', 'node:e2', 'node:e3', 'node:e4', 'node:e5'});
    handler = natives.handle;

    final ok = await s.connect();

    expect(ok, isFalse,
        reason: 'with every candidate dead the connect must report failure '
            'honestly — after WALKING the pool, never after one dial');
    expect(natives.starts, 4,
        reason: 'bounded: 1 initial dial + at most 3 extra (same depth as '
            'the desktop smartConnect walk) — never the whole pool');
    expect(natives.startConfigs.map(selectorDefault).toList(),
        ['node:e1', 'node:e2', 'node:e3', 'node:e4']);
    expect(health.statsOf('e5')?.consecutiveFailures, 0,
        reason: 'the never-dialed candidate carries no connect-fail record '
            '— the walk records only dials it actually burned');
    for (final id in ['e1', 'e2', 'e3', 'e4']) {
      final st = health.statsOf(id);
      expect(st, isNotNull,
          reason: 'every burned dial lands an honest connect-fail record '
              'the ladder hysteresis and the next auto pick learn from');
      expect(st!.consecutiveFailures, greaterThanOrEqualTo(1));
    }
    expect(s.controller.phase, isNot(AndroidVpnPhase.connected));
    expect(s.controller.isBusy, isFalse,
        reason: 'an exhausted walk ends on a terminal phase — never spins');
  });

  test('an EXPLICIT tap never walks — the tapped node IS the request and is '
      'never silently swapped', () async {
    final health = HealthStore();
    _seed(health, 'a', 50);
    _seed(health, 'b', 200);
    final s = await _session(
      'explicit',
      [_node('a', port: 5001), _node('b', port: 5002)],
      health: health,
    );
    final natives = _Natives(dead: {'node:a', 'node:b'});
    handler = natives.handle;

    s.selectNode(_node('a', port: 5001));
    final ok = await s.connect();

    expect(ok, isFalse);
    expect(natives.starts, 1,
        reason: 'a dead tap fails HONESTLY — the old silent swap made every '
            'tap "repeat" whatever auto preferred (v0.4.1 device contract)');
    expect(s.selectedNode?.id, 'a',
        reason: 'the dashboard keeps showing the node the USER chose');
  });

  test('a user Stop during the walk ENDS it — no further dials', () async {
    final health = HealthStore();
    _seed(health, 'a', 50);
    _seed(health, 'b', 200);
    _seed(health, 'c', 300);
    final s = await _session(
      'stop',
      [_node('a', port: 6001), _node('b', port: 6002), _node('c', port: 6003)],
      health: health,
    );
    // a dies natively; b's start HANGS — the walk's in-flight dial, the
    // exact window a user presses Stop. c must never be dialed.
    final natives = _Natives(dead: {'node:a'}, hang: {'node:b'});
    handler = natives.handle;

    final flow = s.connect();
    await _until(() => natives.starts >= 2);
    expect(natives.starts, 2,
        reason: 'the walk must have moved on from the dead pick to b');
    expect(s.controller.connectRunActive, isTrue,
        reason: 'b\'s dial is the live Stop window this test needs');

    await s.disconnect();
    expect(await flow, isFalse);
    expect(natives.starts, 2,
        reason: 'Stop mid-walk must END it — the walk may not dial c over '
            'the stop the user just made (v0.6.2 §stop-fix discipline)');
    expect(s.controller.isConnected, isFalse);
    expect(s.controller.phase, AndroidVpnPhase.stopped);
  });
}
