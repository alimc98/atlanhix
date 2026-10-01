import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/application/dependencies.dart';
import 'package:nexus/platform/android_vpn.dart';
import 'package:nexus/settings/vpn_session.dart';

/// v0.3.0 §5/§6/§7 — Android VPN state machine tests.
///
/// The platform channel is mocked at the binary-messenger level so the
/// REAL Dart controller logic runs (permission flow, handoff building,
/// state polling, probe gating, clean stop). Native service behavior is
/// covered on-device — no Android SDK/toolchain in this environment, so
/// these prove the Dart half only and are labelled as such.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Map<String, Object> Function(String method, Object? arg) handler;

  // v0.5.8: session-level pins run against the shared bootstrap harness
  // (same pattern as connect_speed_test.dart — the empty pool yields
  // NO_RUNNABLE_NODE, which is exactly the pre-tunnel gate being pinned).
  late AppDependencies deps;
  setUpAll(() async {
    deps = await AppDependencies.bootstrapForTest();
  });

  setUp(() {
    handler = (m, a) => {'error': 'unexpected $m'};
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('dev.atlanhix/vpn'), (call) async {
      final out = handler(call.method, call.arguments);
      return jsonEncode(out);
    });
  });

  test('handoff payload carries dns/routes/per-app (§6/§7 contract)', () {
    final c = AndroidVpnController()
      ..includeApps = ['com.example.allowed']
      ..excludeApps = ['com.example.blocked']
      ..dnsServers = ['1.1.1.1']
      ..routes = const ['0.0.0.0/0'];
    final h = c.buildHandoff();
    expect(h['includeApps'], ['com.example.allowed']);
    expect(h['excludeApps'], ['com.example.blocked']);
    expect(h['dns'], ['1.1.1.1']);
    expect(h['routes'], ['0.0.0.0/0']);
    expect(h['inet4Address'], '172.19.0.1');
    expect(h['configJson'], '');
  });

  test('connect: granted → starting → validating → real probe → connected',
      () async {
    final c = AndroidVpnController()..permissionPollSeconds = 1;
    // v0.4.x race fix: `state` must echo the generation delivered with
    // `start` — the controller skips payloads from a PREVIOUS session.
    var gen = '';
    handler = (m, a) {
      switch (m) {
        case 'prepare':
          return {'granted': true, 'needsUserConsent': false};
        case 'start':
          gen = '${(jsonDecode(a! as String) as Map)['generation']}';
          return {'ok': true};
        case 'state':
          return {'state': 'VALIDATING', 'detail': '', 'generation': gen};
      }
      return {};
    };
    var probes = 0;
    final ok = await c.connect(probeTunnel: () async {
      probes++;
      return true;
    });
    expect(ok, isTrue);
    expect(probes, 1, reason: 'connected requires exactly one real probe');
    expect(c.phase, AndroidVpnPhase.connected);
  });

  test('connect: engine fails natively → failed, never connected (§5)',
      () async {
    final c = AndroidVpnController()..permissionPollSeconds = 1;
    var gen = '';
    handler = (m, a) {
      switch (m) {
        case 'prepare':
          return {'granted': true};
        case 'start':
          gen = '${(jsonDecode(a! as String) as Map)['generation']}';
          return {'ok': true};
        case 'state':
          return {
            'state': 'FAILED',
            'detail': 'engineUnavailable: no libbox',
            'generation': gen
          };
      }
      return {};
    };
    var probed = false;
    final ok = await c.connect(probeTunnel: () async {
      probed = true;
      return true;
    });
    expect(ok, isFalse);
    expect(probed, isFalse,
        reason: 'no probe may run when the engine reports failure');
    expect(c.phase, AndroidVpnPhase.failed);
    expect(c.lastDetail, contains('engineUnavailable'));
  });

  test('connect: engine up but probe fails → failed (no fake success)',
      () async {
    final c = AndroidVpnController()..permissionPollSeconds = 1;
    var gen = '';
    handler = (m, a) {
      switch (m) {
        case 'prepare':
          return {'granted': true};
        case 'start':
          gen = '${(jsonDecode(a! as String) as Map)['generation']}';
          return {'ok': true};
        case 'state':
          return {'state': 'VALIDATING', 'generation': gen};
      }
      return {};
    };
    final ok = await c.connect(
        probeTunnel: () async => false,
        startupTimeout: const Duration(seconds: 2));
    expect(ok, isFalse);
    expect(c.phase, AndroidVpnPhase.failed);
  });

  test('permission denied → permissionDenied phase, no start attempted',
      () async {
    final c = AndroidVpnController()..permissionPollSeconds = 1;
    var started = false;
    handler = (m, a) {
      switch (m) {
        case 'prepare':
          return {'granted': false, 'needsUserConsent': true};
        case 'start':
          started = true;
          return {'ok': true};
      }
      return {};
    };
    final ok = await c.connect(probeTunnel: () async => true);
    expect(ok, isFalse);
    expect(started, isFalse,
        reason: 'start must not be attempted without VPN permission');
    expect(c.phase, AndroidVpnPhase.permissionDenied);
    expect(c.lastErrorCode, VpnErrorCode.permissionDenied);
  });

  test('explicit denial → immediate permissionDenied, exactly one prepare',
      () async {
    final c = AndroidVpnController();
    var prepareCalls = 0;
    handler = (m, a) {
      switch (m) {
        case 'prepare':
          prepareCalls++;
          return {'granted': false};
      }
      return {};
    };
    final ok = await c.connect(probeTunnel: () async => true);
    expect(ok, isFalse);
    expect(c.phase, AndroidVpnPhase.permissionDenied,
        reason: 'denial is its own state, not generic failed (v0.4.1 §3)');
    expect(c.lastErrorCode, VpnErrorCode.permissionDenied);
    expect(prepareCalls, 1,
        reason: 'NO re-launch loop — one prepare per user action');
  });

  test('native REVOKED while connected → revoked phase + service stopped',
      () async {
    final c = AndroidVpnController()..watcherInterval = const Duration(milliseconds: 50);
    var stopped = false;
    var revokedSeen = false;
    var gen = '';
    handler = (m, a) {
      switch (m) {
        case 'prepare':
          return {'granted': true};
        case 'start':
          gen = '${(jsonDecode(a! as String) as Map)['generation']}';
          return {'ok': true};
        case 'state':
          // VALIDATING once (probe gate) → CONNECTED → then REVOKED.
          if (!revokedSeen && c.phase == AndroidVpnPhase.connected) {
            revokedSeen = true;
            return {
              'state': 'REVOKED',
              'detail': 'revoked by system',
              'errorCode': 'VPN_REVOKED',
              'generation': gen
            };
          }
          if (revokedSeen) return {'state': 'STOPPED', 'generation': gen};
          return {'state': 'VALIDATING', 'detail': '', 'generation': gen};
        case 'stop':
          stopped = true;
          return {'ok': true};
      }
      return {};
    };
    final ok = await c.connect(probeTunnel: () async => true);
    expect(ok, isTrue);
    // Watcher ticks every 50ms — wait for it to mirror the revoke.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(c.phase, AndroidVpnPhase.revoked);
    expect(c.lastErrorCode, VpnErrorCode.revoked);
    expect(stopped, isTrue,
        reason: 'revoke must tear the tunnel down, not leave it stale');
  });

  test('§6 native failure carries structured errorCode into diagnostics',
      () async {
    final c = AndroidVpnController();
    var gen = '';
    handler = (m, a) {
      switch (m) {
        case 'prepare':
          return {'granted': true};
        case 'start':
          gen = '${(jsonDecode(a! as String) as Map)['generation']}';
          return {'ok': true};
        case 'state':
          return {
            'state': 'FAILED',
            'detail': 'engineUnavailable: no libbox',
            'errorCode': 'ENGINE_START_FAILED',
            'generation': gen
          };
      }
      return {};
    };
    await c.connect(probeTunnel: () async => true);
    expect(c.lastErrorCode, 'ENGINE_START_FAILED');
    final d = await c.diagnostics();
    expect(d['errorCode'], 'ENGINE_START_FAILED');
    expect(d['nativeState'], 'FAILED');
  });

  test('stop: confirms native STOPPED before declaring stopped', () async {
    final c = AndroidVpnController();
    var stateCalls = 0;
    handler = (m, a) {
      switch (m) {
        case 'stop':
          return {'ok': true};
        case 'state':
          stateCalls++;
          return {'state': stateCalls >= 2 ? 'STOPPED' : 'STOPPING'};
      }
      return {};
    };
    c.phase = AndroidVpnPhase.connected;
    await c.stop();
    expect(c.phase, AndroidVpnPhase.stopped);
    expect(stateCalls, greaterThanOrEqualTo(2),
        reason: 'stop must poll until the native side confirms');
  });

  test(
      'v0.5.8: markStarting\'s starting phase must NOT wedge connect (probe runs)',
      () async {
    // REGRESSION PIN for the "فقط میچرخه و وصل نمیشه" bug. v0.5.5 added
    // markStarting (tap → starting) but the connect gate `if (isBusy)
    // return false` counted `starting` as busy — every tap was silently
    // refused, the service never started, no probe ever ran and the UI
    // spun forever on every config.
    final c = AndroidVpnController()..permissionPollSeconds = 1;
    var gen = '';
    var started = false;
    var probed = false;
    handler = (m, a) {
      switch (m) {
        case 'prepare':
          return {'granted': true};
        case 'start':
          gen = '${(jsonDecode(a! as String) as Map)['generation']}';
          started = true;
          return {'ok': true};
        case 'state':
          return {'state': 'VALIDATING', 'detail': '', 'generation': gen};
      }
      return {};
    };
    c.markStarting(); // the v0.5.5 tap feedback
    expect(c.wedgeArmed, isFalse,
        reason: '`starting` from a tap must not ARM the connect gate');
    final ok = await c.connect(probeTunnel: () async {
      probed = true;
      return true;
    });
    expect(ok, isTrue, reason: 'the flow must proceed past its own gate');
    expect(started, isTrue, reason: 'the service start must be invoked');
    expect(probed, isTrue, reason: 'the tunnel probe must actually run');
    expect(c.phase, AndroidVpnPhase.connected);
  });

  test('v0.5.8: a pre-tunnel gate failure lands a terminal phase (no spin)',
      () async {
    final s = VpnSession(deps: deps);
    expect(s.controller.phase, AndroidVpnPhase.idle);
    // Empty pool in this harness → NO_RUNNABLE_NODE via the session gate.
    final ok = await s.connect();
    expect(ok, isFalse);
    expect(s.lastError, 'NO_RUNNABLE_NODE');
    expect(s.controller.phase, isNot(AndroidVpnPhase.starting),
        reason: 'the spinner must END when the flow ends — v0.5.5 left it '
            'on `starting` forever after a gate rejection');
    // And the controller must be immediately tap-able again.
    expect(s.controller.isBusy, isFalse);
  });

  test('v0.5.8: resetToIdle never tramples a live session', () async {
    final c = AndroidVpnController()..phase = AndroidVpnPhase.connected;
    c.resetToIdle();
    expect(c.phase, AndroidVpnPhase.connected);
    c.phase = AndroidVpnPhase.validating;
    c.resetToIdle();
    expect(c.phase, AndroidVpnPhase.validating,
        reason: 'reset must refuse busy phases');
    c.phase = AndroidVpnPhase.starting;
    c.resetToIdle(reason: 'flow ended');
    expect(c.phase, AndroidVpnPhase.stopped);
  });
}
