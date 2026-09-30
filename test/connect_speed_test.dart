import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/application/dependencies.dart';
import 'package:nexus/core/health/latency_tester.dart';
import 'package:nexus/core/health/test_scheduler.dart';
import 'package:nexus/domain/entities/health.dart';
import 'package:nexus/domain/entities/proxy_profile.dart';
import 'package:nexus/platform/android_vpn.dart';
import 'package:nexus/settings/app_settings.dart';
import 'package:nexus/settings/smart_switch.dart';
import 'package:nexus/settings/vpn_session.dart';

/// Pins the v0.5.5 §user connect-speed fix:
///  1. the pre-connect ladder HANDS OVER on the first healthy measurement
///     instead of blocking the tunnel until the whole pool settles;
///  2. `connect()` flips the controller to STARTING on the tap itself —
///     the UI never sits on "Disconnected" while the ladder runs;
///  3. the ladder wait is hard-capped by [SmartSwitch.initialSweep]'s
///     maxWait (a dead/slow provider cannot stall a connect).
ProxyProfile _node(String id) => ProxyProfile(
      id: id,
      name: 'Node $id',
      server: '203.0.113.10',
      port: 443,
      protocol: ProxyProtocol.shadowsocks,
      ssMethod: 'aes-128-gcm',
      password: 'ss-pass-1',
    );

/// A batch provider that lands node `a` FIRST (a healthy 90 ms), then the
/// truly-fastest `b` (30 ms) much later — the early pick must take `a`
/// and start the handshake without waiting for `b`.
SmartSwitch _ladderSwitcher(HealthStore health) => SmartSwitch(
      scheduler: TestScheduler(tester: LatencyTester(), store: health),
      health: health,
      interval: const Duration(seconds: 0),
      urlBatchProbe: (batch, {onNode}) async {
        final out = <String, ProbeResult>{};
        Future<void> land(String id, int ms, int delay) async {
          await Future<void>.delayed(Duration(milliseconds: delay));
          onNode?.call(_node(id), ms);
          out[id] = ProbeResult(ok: true, latencyMs: ms);
        }

        await Future.wait([
          land('a', 90, 40),
          land('b', 30, 150),
          land('c', 10, 250),
        ]);
        return out;
      },
    );

void main() {
  late AppDependencies deps;

  setUpAll(() async {
    deps = await AppDependencies.bootstrapForTest();
    deps.tester = LatencyTester();
    deps.healthStore = HealthStore();
    deps.scheduler =
        TestScheduler(tester: deps.tester, store: deps.healthStore);
    await deps.store.load();
    deps.appSettingsRepo = AppSettingsRepository(deps.store);
    deps.appSettings = deps.appSettingsRepo.current;
  });

  test('earlyPick fires on the first healthy node, not the whole pool',
      () async {
    final health = HealthStore();
    final sw = _ladderSwitcher(health);
    addTearDown(sw.dispose);

    final picked = <ProxyProfile>[];
    final t0 = DateTime.now();
    await sw.initialSweep(
      [_node('a'), _node('b'), _node('c')],
      maxWait: const Duration(seconds: 5),
      earlyPick: picked.add,
    );
    final elapsed = DateTime.now().difference(t0);

    expect(picked, isNotEmpty, reason: 'a healthy node must hand over early');
    expect(picked.first.id, 'a',
        reason: 'the FIRST healthy measurement wins the early handover');
    expect(elapsed.inMilliseconds, lessThan(1000),
        reason: 'the handshake must not wait for the slowest measurement');
    // The full sweep keeps running in the BACKGROUND and crowns the truly-
    // fastest node — the armed switch migrates to it after connect. Poll
    // (bounded) for the migration: the sweep finishes after the early
    // handover by design.
    var migrated = false;
    for (var i = 0; i < 60 && !migrated; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      migrated = sw.best?.id == 'c';
    }
    expect(sw.best?.id, 'c',
        reason: 'the full sweep still picks the REAL fastest (10 ms)');
  });

  test('connect() flips the controller to starting on the tap itself',
      () async {
    final s = VpnSession(deps: deps);
    expect(s.controller.phase, AndroidVpnPhase.idle);
    // No explicit node + no runnable pool in the test harness: the connect
    // ends with NO_RUNNABLE_NODE — but the PHASE flip happens BEFORE any
    // await, which is exactly what this test pins.
    unawaited(s.connect());
    expect(s.controller.phase, AndroidVpnPhase.starting,
        reason: 'the UI must see "connecting" the instant the user taps');
  });

  test('initialSweep never waits past maxWait', () async {
    final health = HealthStore();
    final sw = SmartSwitch(
      scheduler: TestScheduler(tester: LatencyTester(), store: health),
      health: health,
      interval: const Duration(seconds: 0),
      urlBatchProbe: (batch, {onNode}) async {
        await Future<void>.delayed(const Duration(seconds: 2));
        return const {};
      },
    );
    addTearDown(sw.dispose);

    final t0 = DateTime.now();
    await sw.initialSweep([_node('x')],
        maxWait: const Duration(milliseconds: 250));
    expect(DateTime.now().difference(t0).inMilliseconds, lessThan(1500),
        reason: 'a slow provider must not stall the connect');
    expect(sw.best, isNull, reason: 'honest: nothing healthy was measured');
  });
}
