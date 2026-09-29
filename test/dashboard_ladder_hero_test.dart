import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/application/connection_controller.dart';
import 'package:nexus/application/dependencies.dart';
import 'package:nexus/core/core_detector.dart';
import 'package:nexus/core/health/latency_tester.dart';
import 'package:nexus/core/health/test_scheduler.dart';
import 'package:nexus/core/runtime/binary_manager.dart';
import 'package:nexus/core/runtime/core_manager.dart';
import 'package:nexus/data/repositories.dart';
import 'package:nexus/domain/entities/proxy_profile.dart';
import 'package:nexus/platform/android_vpn.dart';
import 'package:nexus/localization/generated/app_localizations.dart';
import 'package:nexus/presentation/screens/dashboard_screen.dart';
import 'package:nexus/settings/app_settings.dart';
import 'package:nexus/settings/smart_switch.dart';
import 'package:nexus/settings/vpn_session.dart';
import 'package:nexus/theme/theme.dart';

/// Pins the LIVE ladder readout on the dashboard hero (v0.5.2 §user):
/// while the smart switch's pre-connect ladder measures the pool, the
/// phase word counts per-node progress ("testing 1/2 · 100 ms") and the
/// finish sentinel hides it again. The GEO ROUTE chip line rides the same
/// stream — its rendering is covered by the shared [LadderProgress]
/// semantics asserted here.
void main() {
  late AppDependencies deps;

  setUpAll(() async {
    deps = await AppDependencies.bootstrapForTest();
    // bootstrapForTest wires only store/vault/geo/nodeUsage/profiles: the
    // health stack the SmartSwitch + dashboard chips read must be built
    // here, then the Android-shaped test session (no platform calls — the
    // controller is only driven by field writes).
    deps.tester = LatencyTester();
    deps.healthStore = HealthStore();
    deps.scheduler =
        TestScheduler(tester: deps.tester, store: deps.healthStore);
    // The dashboard's initState reads deps.connection (desktop phase
    // snapshot on non-Android) → build the controller stack it needs.
    deps.appSettings = AppSettings();
    deps.warpRepo = WarpRepository(deps.store, deps.vault);
    deps.cores = CoreManager(
        binaryManager: BinaryManager(),
        workDir: await Directory.systemTemp.createTemp('nexus_hero_test'));
    deps.detector = CoreDetector();
    deps.connection = ConnectionController(
      repository: deps.profiles,
      healthStore: deps.healthStore,
      tester: deps.tester,
      detector: deps.detector,
      cores: deps.cores,
      warpRepo: deps.warpRepo,
    );
    deps.vpnSession = _TestVpnSession(deps);
  });

  ProxyProfile node(String id) => ProxyProfile(
        id: id,
        name: 'Node $id',
        server: '203.0.113.10',
        port: 443,
        protocol: ProxyProtocol.shadowsocks,
        ssMethod: 'aes-128-gcm',
        password: 'ss-pass-1',
      );

  Future<void> pumpDashboard(WidgetTester t) async {
    await t.binding.setSurfaceSize(const Size(600, 1600));
    addTearDown(() => t.binding.setSurfaceSize(null));
    await t.pumpWidget(MaterialApp(
      locale: const Locale('en'),
      supportedLocales: const [Locale('en'), Locale('fa')],
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      theme: NexusTheme.theme(NexusThemeMode.dark),
      home: DashboardScreen(deps: deps),
    ));
    await t.pump(const Duration(milliseconds: 120));
  }

  SmartSwitch scriptedLadder() {
    final switcher = SmartSwitch(
      scheduler: TestScheduler(tester: LatencyTester(), store: deps.healthStore),
      health: deps.healthStore,
      interval: const Duration(seconds: 0),
      urlBatchProbe: (batch, {onNode}) async {
        final out = <String, ProbeResult>{};
        for (var i = 0; i < batch.length; i++) {
          final ms = 100 + i * 40;
          await Future<void>.delayed(const Duration(milliseconds: 30));
          onNode?.call(batch[i], ms);
          out[batch[i].id] = ProbeResult(ok: true, latencyMs: ms);
        }
        return out;
      },
    );
    return switcher;
  }

  testWidgets('phase word counts per landed node; finish hides it',
      (t) async {
    final session = deps.vpnSession as _TestVpnSession;
    session.controller.phase = AndroidVpnPhase.starting;
    final ladder = scriptedLadder();
    session.bridgeLadder(ladder.progress);

    await pumpDashboard(t);
    // The uiPhase of `starting` is `validating` — a ladder-gated phase;
    // the app maps connecting/validating to the same `l.connecting` word.
    expect(find.text('Connecting…'), findsOneWidget);
    ladder.start([node('a'), node('b')]);

    // Node 1 lands ~30 ms in: the hero word swaps to the live count and
    // the chip's line fades in (only the incoming text exists mid-fade).
    await t.pump(const Duration(milliseconds: 45));
    expect(find.text('testing 1/2 · 100 ms'), findsAtLeast(1),
        reason: 'the hero shows the live per-node count while connecting');

    // A REAL sequential batch lands node 2 and the finish in the SAME
    // event turn — the UI settles straight to the finished state: the
    // hero word returns and the chip fades its line out. (NO pumpAndSettle
    // here: the traffic graph's wave ticker runs forever in validating.)
    await t.pump(const Duration(milliseconds: 40));
    expect(find.text('Connecting…'), findsOneWidget,
        reason: 'run finished → the plain word is back');
    await t.pump(const Duration(milliseconds: 260));
    await t.pump(const Duration(milliseconds: 100));
    expect(find.textContaining('testing'), findsNothing,
        reason: 'the fade-out never leaks a stale count');

    // INLINE (tearDowns run AFTER the binding's timer invariant check):
    // cancel the switcher's periodic timers or the test fails on
    // "A Timer is still pending".
    ladder.stop();
  });

  testWidgets('ladder line disappears for a non-connecting phase',
      (t) async {
    final session = deps.vpnSession as _TestVpnSession;
    session.controller.phase = AndroidVpnPhase.idle;
    final ladder = scriptedLadder();
    session.bridgeLadder(ladder.progress);

    await pumpDashboard(t);
    ladder.start([node('a'), node('b')]);
    await t.pump(const Duration(milliseconds: 45));

    // DISCONNECTED phase → the hero gate keeps the plain word; the CHIP,
    // though, shows the count by design (the sweep IS running — only the
    // hero word is phase-sensitive).
    expect(find.text('Disconnected'), findsOneWidget);
    expect(find.textContaining('testing'), findsAtLeast(1));
    await t.pumpAndSettle(const Duration(milliseconds: 300));

    // After the run closes, the count is gone everywhere (and the idle
    // sentinel NEVER leaks a "0/0" ghost).
    expect(find.textContaining('testing'), findsNothing);

    await t.pumpAndSettle(const Duration(milliseconds: 50));
    ladder.stop();
  });
}

/// Test-only VpnSession: the real class boots an AndroidVpnController but
/// makes NO platform calls on its own — the test drives `controller.phase`
/// directly and bridges a REAL SmartSwitch's progress stream in.
class _TestVpnSession extends VpnSession {
  _TestVpnSession(this.d) : super(deps: d);

  final AppDependencies d;

  Stream<LadderProgress>? _source;

  /// Point the session's [smartLadderProgress] at a REAL switcher's stream.
  void bridgeLadder(Stream<LadderProgress> s) => _source = s;

  @override
  Stream<LadderProgress> get smartLadderProgress =>
      _source ?? super.smartLadderProgress;
}
