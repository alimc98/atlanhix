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
import 'package:nexus/domain/entities/proxy_profile.dart';
import 'package:nexus/platform/android_vpn.dart';
import 'package:nexus/settings/app_settings.dart';
import 'package:nexus/settings/runtime_config_bridge.dart';
import 'package:nexus/settings/vpn_session.dart';

/// v0.5.9 §retarget: "وقتی کانکت رو میزنیم و در حال اتصاله میخوایم یه
/// کانفیگ دیگه رو بزنیم که وصل بشه کار نمیکره" — a tap DURING an
/// in-flight connect previously only STORED the pick; the running flow
/// kept booting the old node and the tap did nothing. Now the tap
/// redirects the attempt: the old run is cancelled at the controller
/// generation gate (its tunnel probe aborts on attempt-identity), and the
/// new node redials through the same funnel.
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
/// pinned as its `default` (singbox_config_generator.dart). Parsing it is
/// the sharpest observable proof of WHICH node an engine start serves.
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

  test('cancelConnect makes the in-flight connect exit QUIETLY', () async {
    final c = AndroidVpnController()..permissionPollSeconds = 1;
    var gen = '';
    var stopCalls = 0;
    handler = (m, a) {
      switch (m) {
        case 'prepare':
          return {'granted': true};
        case 'start':
          gen = '${(jsonDecode(a! as String) as Map)['generation']}';
          return {'ok': true};
        case 'stop':
          stopCalls++;
          return {'ok': true};
        case 'state':
          // The engine NEVER reaches validating during this test — the
          // poll loop keeps spinning until the cancel lands.
          return {'state': 'STARTING', 'generation': gen};
      }
      return {};
    };

    var phaseSeen = <AndroidVpnPhase>[];
    final sub = c.states.listen(phaseSeen.add);

    final slow = c.connect(probeTunnel: () async => true);
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(c.connectRunActive, isTrue);
    expect(c.phase, AndroidVpnPhase.starting);

    c.cancelConnect();
    final ok = await slow;
    expect(ok, isFalse, reason: 'the superseded attempt reports no verdict');
    expect(stopCalls, 0,
        reason: 'a superseded run must NOT tear the tunnel down — the '
            'successor owns it');
    expect(c.phase, AndroidVpnPhase.starting,
        reason: 'no phase write after the cancel (the redial owns the UI)');
    await sub.cancel();
  });

  test('redial passes the gate after the cancelled run exits', () async {
    final c = AndroidVpnController()..permissionPollSeconds = 1;
    var gen = '';
    var started = 0;
    // The mock engine stays STARTING (never reaches validating) until the
    // test flips this — exactly the window a mid-flight retarget lands in.
    var nativeValidating = false;
    handler = (m, a) {
      switch (m) {
        case 'prepare':
          return {'granted': true};
        case 'start':
          gen = '${(jsonDecode(a! as String) as Map)['generation']}';
          started++;
          return {'ok': true};
        case 'state':
          return {'state': nativeValidating ? 'VALIDATING' : 'STARTING',
              'generation': gen};
      }
      return {};
    };

    // Attempt 1 goes in-flight, is cancelled mid-poll...
    final first = c.connect(probeTunnel: () async => true);
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(c.phase, AndroidVpnPhase.starting,
        reason: 'run 1 must still be in-flight for the retarget window');
    c.cancelConnect();
    nativeValidating = true; // the redial's fresh engine comes up
    final firstVerdict = await first;
    // The cancelled run exits at its NEXT poll tick — give it the beat.
    for (var i = 0; i < 40 && c.connectRunActive; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    expect(c.connectRunActive, isFalse,
        reason: 'the cancelled run has left the gate');
    expect(firstVerdict, isFalse);

    // ...and attempt 2 passes the gate and CONNECTS (the retarget redial).
    // The cancel left the phase on the old run's mid-flight state, so the
    // retarget lands a benign phase before dialing (same call _redialWith
    // makes).
    c.resetToIdle(reason: 'connect retargeted');
    final ok = await c.connect(probeTunnel: () async => true);
    expect(ok, isTrue, reason: 'the redial must pass the gate and connect');
    expect(started, 2);
    expect(c.phase, AndroidVpnPhase.connected);
  });

  test('session-level retarget: tap during connect redirects the dial',
      () async {
    final deps = await AppDependencies.bootstrapForTest();
    // Full session wiring: the funnel must reach the CONTROLLER (engine
    // resolution, config generation) for the retarget to be a real redial.
    deps.tester = LatencyTester();
    deps.healthStore = HealthStore();
    deps.scheduler = TestScheduler(tester: deps.tester, store: deps.healthStore);
    deps.appSettingsRepo = AppSettingsRepository(deps.store);
    deps.appSettings = deps.appSettingsRepo.current;
    deps.routingSettingsRepo = RoutingSettingsRepository(deps.store);
    await deps.routingSettingsRepo.load();
    deps.routingSettings = deps.routingSettingsRepo.current;
    deps.configBridge = RuntimeConfigBridge(
        settings: deps.appSettings, routing: deps.routingSettings);
    // v0.5.9 §retarget: _connectProfileInner resolves the engine HERE (the
    // object being dialed) — bootstrapForTest leaves `detector` unset, so
    // provide the real (pure-logic) detector.
    deps.detector = CoreDetector();
    final tmp = await Directory.systemTemp.createTemp('nexus_retarget_test');
    deps.binaryManager = BinaryManager(appDir: Directory('${tmp.path}/cores'));
    deps.cores = CoreManager(
      binaryManager: deps.binaryManager,
      workDir: Directory('${tmp.path}/runtime'),
      enableTun: false,
    );
    // All tapped nodes exist in the repository (like a real device): the
    // front config is built from the pool and routes via the selector's
    // `default` = the dialed node's tag.
    await deps.profiles.upsertMany([
      _node('n1', port: 1443),
      _node('n2', port: 2443),
    ]);
    final s = VpnSession(deps: deps);

    // The mock engine: run 1 never leaves STARTING → it stays in-flight
    // until the retarget's cancel lands at the generation gate. The echo of
    // the start generation is REQUIRED — the controller ignores state
    // payloads of a different generation (stale-session discipline). The
    // REDIAL's run fails natively a few polls in → fast terminal phase.
    var starts = 0;
    var gen = '';
    var pollsSinceStart = 0;
    final startConfigs = <String>[];
    handler = (m, a) {
      switch (m) {
        case 'prepare':
          return {'granted': true};
        case 'start':
          final handoff = jsonDecode(a! as String) as Map;
          gen = '${handoff['generation']}';
          starts++;
          pollsSinceStart = 0;
          startConfigs.add('${handoff['configJson']}');
          return {'ok': true};
        case 'state':
          pollsSinceStart++;
          if (starts >= 2 && pollsSinceStart > 2) {
            return {'state': 'FAILED', 'generation': gen,
                'detail': 'mock engine death'};
          }
          return {'state': 'STARTING', 'generation': gen};
      }
      return {};
    };

    s.selectNode(_node('n1', port: 1443));
    final flow = s.connect();
    for (var i = 0; i < 100 && !s.controller.connectRunActive; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(s.controller.connectRunActive, isTrue,
        reason: 'run 1 must be in-flight for the retarget window');
    expect(starts, 1);

    // THE USER TAP (bug #5): a different node mid-connect.
    s.selectNode(_node('n2', port: 2443));
    await flow; // run 1 exits quietly — cancelled, no verdict
    // The retarget must REDIAL: bounded wait for the fresh engine start.
    for (var i = 0; i < 200 && starts < 2; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(starts, 2,
        reason: 'the tap must REDIAL — the old build stored the pick and '
            'kept booting the stale node (start count stayed 1)');
    expect(selectorDefault(startConfigs.last), 'node:n2',
        reason: 'the redial dials THE TAPPED node, not the first pick');

    // The redial's own funnel also ends on a terminal phase (its canary
    // rounds fail against the mock engine — refused localhost, ~2.5s).
    for (var i = 0; i < 200 && s.controller.connectRunActive; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(s.controller.isBusy, isFalse,
        reason: 'the retargeted flow must end on a terminal phase');
    expect(s.selectedNode?.id, 'n2');
  });

  test('a newer tap mid-redial wins: every tap during connect retargets',
      () async {
    final deps = await AppDependencies.bootstrapForTest();
    deps.tester = LatencyTester();
    deps.healthStore = HealthStore();
    deps.scheduler = TestScheduler(tester: deps.tester, store: deps.healthStore);
    deps.appSettingsRepo = AppSettingsRepository(deps.store);
    deps.appSettings = deps.appSettingsRepo.current;
    deps.routingSettingsRepo = RoutingSettingsRepository(deps.store);
    await deps.routingSettingsRepo.load();
    deps.routingSettings = deps.routingSettingsRepo.current;
    deps.configBridge = RuntimeConfigBridge(
        settings: deps.appSettings, routing: deps.routingSettings);
    deps.detector = CoreDetector();
    final tmp = await Directory.systemTemp.createTemp('nexus_retarget_test2');
    deps.binaryManager = BinaryManager(appDir: Directory('${tmp.path}/cores'));
    deps.cores = CoreManager(
      binaryManager: deps.binaryManager,
      workDir: Directory('${tmp.path}/runtime'),
      enableTun: false,
    );
    await deps.profiles.upsertMany([
      _node('n1', port: 1443),
      _node('n2', port: 2443),
      _node('n3', port: 3443),
    ]);
    final s = VpnSession(deps: deps);
    var starts = 0;
    var gen = '';
    var pollsSinceStart = 0;
    final startConfigs = <String>[];
    handler = (m, a) {
      switch (m) {
        case 'prepare':
          return {'granted': true};
        case 'start':
          final handoff = jsonDecode(a! as String) as Map;
          gen = '${handoff['generation']}';
          starts++;
          pollsSinceStart = 0;
          startConfigs.add('${handoff['configJson']}');
          return {'ok': true};
        case 'state':
          pollsSinceStart++;
          if (starts >= 2 && pollsSinceStart > 2) {
            return {'state': 'FAILED', 'generation': gen,
                'detail': 'mock engine death'};
          }
          return {'state': 'STARTING', 'generation': gen};
      }
      return {};
    };

    s.selectNode(_node('n1', port: 1443));
    final flow = s.connect();
    for (var i = 0; i < 100 && !s.controller.connectRunActive; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    // Tap 1 → redial n2.
    s.selectNode(_node('n2', port: 2443));
    // Tap 2 lands while the n2 redial is coming up — it must retarget the
    // DIAL TARGET (the freshest tap wins) whatever run is in flight.
    s.selectNode(_node('n3', port: 3443));
    await flow;
    for (var i = 0; i < 200 && starts < 2; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    for (var i = 0; i < 200 && s.controller.connectRunActive; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(s.controller.isBusy, isFalse);
    expect(starts >= 2, isTrue, reason: 'the taps must have redial(ed)');
    expect(selectorDefault(startConfigs.last), 'node:n3',
        reason: 'the FRESHEST tap wins the dial (n3)');
    expect(s.selectedNode?.id, 'n3');
  });
}
