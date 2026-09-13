import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/platform/android_vpn.dart';

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
    handler = (m, a) {
      switch (m) {
        case 'prepare':
          return {'granted': true, 'needsUserConsent': false};
        case 'start':
          return {'ok': true};
        case 'state':
          return {'state': 'VALIDATING', 'detail': ''};
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
    handler = (m, a) {
      switch (m) {
        case 'prepare':
          return {'granted': true};
        case 'start':
          return {'ok': true};
        case 'state':
          return {'state': 'FAILED', 'detail': 'engineUnavailable: no libbox'};
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
    handler = (m, a) {
      switch (m) {
        case 'prepare':
          return {'granted': true};
        case 'start':
          return {'ok': true};
        case 'state':
          return {'state': 'VALIDATING'};
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
    handler = (m, a) {
      switch (m) {
        case 'prepare':
          return {'granted': true};
        case 'start':
          return {'ok': true};
        case 'state':
          // VALIDATING once (probe gate) → CONNECTED → then REVOKED.
          if (!revokedSeen && c.phase == AndroidVpnPhase.connected) {
            revokedSeen = true;
            return {
              'state': 'REVOKED',
              'detail': 'revoked by system',
              'errorCode': 'VPN_REVOKED'
            };
          }
          if (revokedSeen) return {'state': 'STOPPED'};
          return {'state': 'VALIDATING', 'detail': ''};
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
    handler = (m, a) {
      switch (m) {
        case 'prepare':
          return {'granted': true};
        case 'start':
          return {'ok': true};
        case 'state':
          return {
            'state': 'FAILED',
            'detail': 'engineUnavailable: no libbox',
            'errorCode': 'ENGINE_START_FAILED'
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
}
