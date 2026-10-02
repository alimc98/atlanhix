import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/application/connection_controller.dart';
import 'package:nexus/application/dependencies.dart';
import 'package:nexus/core/core_detector.dart';
import 'package:nexus/core/engine_availability.dart';
import 'package:nexus/core/health/latency_tester.dart';
import 'package:nexus/core/health/test_scheduler.dart';
import 'package:nexus/core/runtime/binary_manager.dart';
import 'package:nexus/core/runtime/core_manager.dart';
import 'package:nexus/data/app_storage.dart';
import 'package:nexus/data/profile_repository.dart';
import 'package:nexus/domain/entities/proxy_profile.dart';
import 'package:nexus/platform/android_vpn.dart';
import 'package:nexus/settings/app_settings.dart';
import 'package:nexus/settings/runtime_config_bridge.dart';
import 'package:nexus/settings/vpn_session.dart';

/// v0.6.2 §stop-fix — the two device reports this pins:
///
/// 1. \"موقعی که توی کانکتینگ هست نمیشه متوقف کرد\" — the dashboard pill was
///    DISABLED while connecting (`onTap: busy ? null : …`), and even a stop
///    that did reach the controller left the in-flight connect alive: its
///    probe outlived the teardown and repainted `failed`/`connected` over the
///    user's stop.
/// 2. \"یه کانفیگ دیگه رو کانکت کرد\" — a node tap mid-connect redialed through
///    a gate the CANCELLED run itself had armed (`validating` ∈ wedgeArmed),
///    so `resetToIdle`/`markStarting`/`connect()` all no-oped and the app sat
///    on \"Connecting…\" forever — from then on EVERY config failed silently
///    (the user's \"کلا هیچ کانفیگی وصل نمیشه\").
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
/// pinned as its `default` (singbox_config_generator.dart).
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

/// A tester whose "real" probe HANGS for a fixed beat: it holds the connect
/// flow on the `validating` phase, which is exactly the window a user taps
/// Stop / another node in.
class _SlowTester extends LatencyTester {
  _SlowTester(this.hold);

  final Duration hold;
  int calls = 0;

  @override
  Future<ProbeResult> testHttpViaSocksProxy(
      String proxyHost, int proxyPort, String testUrl,
      {Duration? timeout}) async {
    calls++;
    await Future<void>.delayed(hold);
    return ProbeResult(ok: true, latencyMs: 42);
  }
}

/// Desktop cores stub: `stop()` takes a real beat (the cancellation window)
/// while everything else stays honest-but-inert.
class _SlowStopCores extends CoreManager {
  _SlowStopCores(this.stopDelay)
      : super(
          binaryManager: StubBinaryManager(),
          workDir: Directory.systemTemp,
        );

  final Duration stopDelay;

  @override
  Future<void> stop() async {
    await Future<void>.delayed(stopDelay);
  }
}

class StubBinaryManager extends BinaryManager {
  StubBinaryManager();

  @override
  Future<CoreBinaryInfo> inspect(CoreBinaryKind kind) async =>
      const CoreBinaryInfo(kind: CoreBinaryKind.singbox, status: 'not-found');
}

class _EmptyProfileRepository implements ProfileRepository {
  @override
  List<ProxyProfile> get all => const <ProxyProfile>[];

  @override
  dynamic noSuchMethod(Invocation invocation) => throw StateError('unused');
}

Future<ConnectionController> _desktopController(CoreManager cores) async {
  final dir = await Directory.systemTemp.createTemp('nexus_cancel_repo');
  final store = JsonStore(directory: dir, schemaVersion: 1);
  await store.load();
  return ConnectionController(
    repository: _EmptyProfileRepository(),
    healthStore: HealthStore(),
    tester: LatencyTester(),
    detector: CoreDetector(),
    cores: cores,
  );
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

  // ── Controller level ────────────────────────────────────────────────────

  test('stop() during the tunnel probe cancels the run and the stop STICKS',
      () async {
    final c = AndroidVpnController()..permissionPollSeconds = 1;
    var gen = '';
    var nativelyStopped = false;
    handler = (m, a) {
      switch (m) {
        case 'prepare':
          return {'granted': true};
        case 'start':
          gen = '${(jsonDecode(a! as String) as Map)['generation']}';
          return {'ok': true};
        case 'stop':
          nativelyStopped = true;
          return {'ok': true};
        case 'state':
          return {
            'state': nativelyStopped ? 'STOPPED' : 'VALIDATING',
            'generation': gen,
          };
      }
      return {};
    };

    var probeEntered = false;
    final phases = <AndroidVpnPhase>[];
    final sub = c.states.listen(phases.add);
    final flow = c.connect(probeTunnel: () async {
      probeEntered = true;
      // A real probe: the canaries are REAL HTTP requests, so the stop can
      // land while this await is pending.
      await Future<void>.delayed(const Duration(milliseconds: 250));
      return true;
    });
    for (var i = 0; i < 300 && !probeEntered; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(probeEntered, isTrue, reason: 'the probe gate must be reached');
    expect(c.phase, AndroidVpnPhase.validating);

    await c.stop();
    expect(c.phase, AndroidVpnPhase.stopped,
        reason: 'the user-visible result of Stop must be `stopped`');

    final ok = await flow;
    expect(ok, isFalse, reason: 'a cancelled attempt reports no success');

    // The probe resolves 250 ms later — the cancelled run must stay silent.
    await Future<void>.delayed(const Duration(milliseconds: 350));
    expect(c.phase, AndroidVpnPhase.stopped,
        reason: 'a cancelled run must NOT repaint connected/failed — that '
            'was the "نمیشه متوقف کرد" bug (the stop looked ignored)');
    expect(phases, isNot(contains(AndroidVpnPhase.connected)));
    expect(c.lastErrorCode, isNot(VpnErrorCode.healthCheckFailed));
    await sub.cancel();
  });

  test('a cancelled validating phase is STALE — the successor may re-enter '
      '(the wedge that killed every later connect)', () async {
    final c = AndroidVpnController()..permissionPollSeconds = 1;
    var gen = '';
    var starts = 0;
    handler = (m, a) {
      switch (m) {
        case 'prepare':
          return {'granted': true};
        case 'start':
          gen = '${(jsonDecode(a! as String) as Map)['generation']}';
          starts++;
          return {'ok': true};
        case 'state':
          return {'state': 'VALIDATING', 'generation': gen};
      }
      return {};
    };

    var firstProbeEntered = false;
    final first = c.connect(probeTunnel: () async {
      firstProbeEntered = true;
      await Future<void>.delayed(const Duration(milliseconds: 200));
      return true;
    });
    for (var i = 0; i < 300 && !firstProbeEntered; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(firstProbeEntered, isTrue);
    expect(c.phase, AndroidVpnPhase.validating);

    // The retarget/disconnect gate: cancel the in-flight run. Its phase is
    // `validating` and it will never write another one.
    c.cancelConnect();
    expect(c.phaseIsStale, isTrue,
        reason: 'the abandoned run left a STALE validating phase');
    expect(c.wedgeArmed, isFalse,
        reason: 'a stale phase must not gate the successor (this was the '
            'permanent wedge: every later connect answered a silent false)');

    // The successor (the node-tap redial / the fresh tap) lands a benign
    // phase and CONNECTS.
    c.resetToIdle(reason: 'retarget');
    c.markStarting(detail: 'redial');
    final ok = await c.connect(probeTunnel: () async => true);
    expect(ok, isTrue, reason: 'the successor must pass the gate');
    expect(starts, 2);
    expect(c.phase, AndroidVpnPhase.connected);
    expect(await first, isFalse,
        reason: 'the superseded run yields its verdict to the successor');
  });

  test('stillOwned=false refuses the attempt BEFORE any native call', () async {
    final c = AndroidVpnController()..permissionPollSeconds = 1;
    var prepared = false;
    var started = false;
    handler = (m, a) {
      switch (m) {
        case 'prepare':
          prepared = true;
          return {'granted': true};
        case 'start':
          started = true;
          return {'ok': true};
      }
      return {};
    };
    final ok = await c.connect(
      probeTunnel: () async => true,
      stillOwned: () => false,
    );
    expect(ok, isFalse);
    expect(prepared, isFalse, reason: 'no consent dialog for a dead attempt');
    expect(started, isFalse, reason: 'no engine start for a dead attempt');
    expect(c.phase, AndroidVpnPhase.idle);
  });

  // ── Session level (the real device shape: the engine REACHES validating) ─

  Future<VpnSession> sessionHarness(String tag, LatencyTester tester) async {
    final deps = await AppDependencies.bootstrapForTest();
    deps.tester = tester;
    deps.healthStore = HealthStore();
    deps.scheduler =
        TestScheduler(tester: deps.tester, store: deps.healthStore);
    deps.appSettingsRepo = AppSettingsRepository(deps.store);
    deps.appSettings = deps.appSettingsRepo.current;
    deps.routingSettingsRepo = RoutingSettingsRepository(deps.store);
    await deps.routingSettingsRepo.load();
    deps.routingSettings = deps.routingSettingsRepo.current;
    deps.configBridge = RuntimeConfigBridge(
        settings: deps.appSettings, routing: deps.routingSettings);
    deps.detector = CoreDetector();
    final tmp = await Directory.systemTemp.createTemp('nexus_cancel_$tag');
    deps.binaryManager = BinaryManager(appDir: Directory('${tmp.path}/cores'));
    deps.cores = CoreManager(
      binaryManager: deps.binaryManager,
      workDir: Directory('${tmp.path}/runtime'),
      enableTun: false,
    );
    await deps.profiles.upsertMany([
      _node('n1', port: 1443),
      _node('n2', port: 2443),
    ]);
    return VpnSession(deps: deps);
  }

  test('tap during VALIDATING redials the tapped node (no wedge)', () async {
    final slow = _SlowTester(const Duration(milliseconds: 900));
    final s = await sessionHarness('retarget', slow);

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
          // Run 2 (the redial) dies natively so the test ends on a terminal
          // phase; run 1 stays VALIDATING (the real window) until cancelled.
          if (starts >= 2 && pollsSinceStart > 2) {
            return {
              'state': 'FAILED',
              'generation': gen,
              'detail': 'mock engine death'
            };
          }
          return {'state': 'VALIDATING', 'generation': gen};
      }
      return {};
    };

    s.selectNode(_node('n1', port: 1443));
    final flow = s.connect();
    // The engine is UP and the probe is HANGING — the exact state the user
    // taps another node in.
    for (var i = 0;
        i < 300 && s.controller.phase != AndroidVpnPhase.validating;
        i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(s.controller.phase, AndroidVpnPhase.validating);
    expect(starts, 1);

    s.selectNode(_node('n2', port: 2443));
    await flow;
    for (var i = 0; i < 400 && starts < 2; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(starts, 2,
        reason: 'the tap must REDIAL the tapped node — before the fix the '
            'redial was refused by the cancelled run\'s own validating phase '
            'and NO config could ever connect again');
    expect(selectorDefault(startConfigs.last), 'node:n2');
    for (var i = 0;
        i < 400 && s.controller.connectRunActive;
        i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(s.controller.isBusy, isFalse,
        reason: 'the retargeted flow must end on a terminal phase, never '
            'spin on "Connecting…" forever');
    expect(s.selectedNode?.id, 'n2');
  });

  test('disconnect during VALIDATING stops and never resurrects', () async {
    final slow = _SlowTester(const Duration(milliseconds: 900));
    final s = await sessionHarness('stop', slow);

    var starts = 0;
    var gen = '';
    var nativelyStopped = false;
    handler = (m, a) {
      switch (m) {
        case 'prepare':
          return {'granted': true};
        case 'start':
          gen = '${(jsonDecode(a! as String) as Map)['generation']}';
          starts++;
          return {'ok': true};
        case 'stop':
          nativelyStopped = true;
          return {'ok': true};
        case 'state':
          return {
            'state': nativelyStopped ? 'STOPPED' : 'VALIDATING',
            'generation': gen,
          };
      }
      return {};
    };

    s.selectNode(_node('n1', port: 1443));
    final flow = s.connect();
    for (var i = 0;
        i < 300 && s.controller.phase != AndroidVpnPhase.validating;
        i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(s.controller.phase, AndroidVpnPhase.validating);

    // THE USER PRESSES CANCEL (the pill, now tappable while connecting).
    await s.disconnect();
    expect(s.controller.phase, AndroidVpnPhase.stopped);
    expect(s.controller.isConnected, isFalse);

    final ok = await flow;
    expect(ok, isFalse);
    // The probe resolves ~900 ms in — nothing may resurrect the session.
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    expect(starts, 1, reason: 'a stopped attempt starts no second engine');
    expect(s.controller.phase, AndroidVpnPhase.stopped,
        reason: 'the cancelled funnel must not publish a late verdict');
    expect(s.controller.isConnected, isFalse);
  });

  test('an UNAVAILABLE engine preference falls back instead of failing every '
      'config', () async {
    final slow = _SlowTester(const Duration(milliseconds: 50));
    final s = await sessionHarness('pref', slow);
    // The device-shape trap: Engine=mihomo chosen in Settings (that is how
    // the user reached the xhttp-on-mihomo path) while this build/ABI does
    // not report the mihomo runtime. Before the fallback, EVERY node died on
    // the single-core gate with CORE_NOT_RUNNABLE_ON_ANDROID.
    s.deps.appSettings.corePreference = CorePreference.mihomo;
    MihomoCoreState.instance.setRuntimeLoaded(false);

    var starts = 0;
    var gen = '';
    var polls = 0;
    handler = (m, a) {
      switch (m) {
        case 'prepare':
          return {'granted': true};
        case 'start':
          gen = '${(jsonDecode(a! as String) as Map)['generation']}';
          starts++;
          polls = 0;
          return {'ok': true};
        case 'state':
          polls++;
          if (polls > 2) {
            return {'state': 'FAILED', 'generation': gen, 'detail': 'mock'};
          }
          return {'state': 'STARTING', 'generation': gen};
      }
      return {};
    };

    s.selectNode(_node('n1', port: 1443));
    await s.connect();
    expect(starts, 1,
        reason: 'the fallback engine must actually START — with the '
            'preference unguarded, the core gate refused every config');
    expect(s.lastError, isNot('CORE_NOT_RUNNABLE_ON_ANDROID'));
  });

  test('an engine gate that arms DURING the tap is not a rejection', () async {
    final slow = _SlowTester(const Duration(milliseconds: 50));
    final s = await sessionHarness('bootrace', slow);
    s.deps.appSettings.corePreference = CorePreference.mihomo;
    // The boot probe is still in flight (it runs unawaited behind the first
    // frame): the mihomo runtime reads OFF at the tap and arms ~300 ms later.
    MihomoCoreState.instance.setRuntimeLoaded(false);
    Timer(const Duration(milliseconds: 300),
        () => MihomoCoreState.instance.setRuntimeLoaded(true));

    var gen = '';
    var polls = 0;
    handler = (m, a) {
      switch (m) {
        case 'prepare':
          return {'granted': true};
        case 'start':
          gen = '${(jsonDecode(a! as String) as Map)['generation']}';
          polls = 0;
          return {'ok': true};
        case 'state':
          polls++;
          if (polls > 2) {
            return {'state': 'FAILED', 'generation': gen, 'detail': 'mock'};
          }
          return {'state': 'STARTING', 'generation': gen};
      }
      return {};
    };

    // The node already carries the mihomo core (a re-tap after a first
    // resolution) — the state a real device is in after one connect attempt.
    s.selectNode(_node('n1', port: 1443).copyWith(core: CoreKind.mihomo));
    await s.connect();
    expect(s.lastError, isNot('NODE_NOT_RUNNABLE_ON_ANDROID'),
        reason: 'a gate that arms a beat later must not reject the tap — '
            'that is the first-tap failure that made EVERY config look dead');
    MihomoCoreState.instance.setRuntimeLoaded(false);
  });

  // ── Desktop (Windows) parity ────────────────────────────────────────────

  test('desktop: a node switch during a connect is honored, not dropped',
      () async {
    final cores = _SlowStopCores(const Duration(milliseconds: 200));
    final c = await _desktopController(cores);

    final first = c.connect(_node('a'));
    expect(c.state.activeProfile?.id, 'a');
    // The OLD gate (`if (_state.isBusy) return false;`) silently dropped
    // this request — the desktop half of "یه کانفیگ دیگه رو کانکت کرد".
    final second = c.connect(_node('b'));
    expect(c.state.activeProfile?.id, 'b',
        reason: 'the freshest request must own the connect funnel');
    expect(await first, isFalse,
        reason: 'the superseded run yields to the newer request');
    await c.disconnect();
    await second;
    expect(c.state.phase, isNot(ConnectionPhase.connected));
  });

  test('desktop: disconnect during a connect keeps the app DISCONNECTED',
      () async {
    final cores = _SlowStopCores(const Duration(milliseconds: 250));
    final c = await _desktopController(cores);

    final flow = c.connect(_node('a'));
    expect(c.state.isBusy, isTrue);
    await c.disconnect();
    expect(c.state.phase, ConnectionPhase.disconnected);

    final ok = await flow;
    expect(ok, isFalse);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(c.state.phase, ConnectionPhase.disconnected,
        reason: 'the cancelled run must not repaint error/connected after '
            'the user stopped it');
  });
}
