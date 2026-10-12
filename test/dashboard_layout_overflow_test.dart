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
import 'package:nexus/localization/generated/app_localizations.dart';
import 'package:nexus/presentation/screens/dashboard_screen.dart';
import 'package:nexus/presentation/widgets/dashboard_globe.dart';
import 'package:nexus/settings/app_settings.dart';
import 'package:nexus/settings/vpn_session.dart';
import 'package:nexus/theme/theme.dart';

/// v0.6.12 §visual: the dashboard + globe were only ever eyeballed at one
/// window size, so layout breakage (RenderFlex overflow, bad constraints on
/// the globe, text that no longer fits) shipped silently — Flutter only
/// *prints* those in a normal run. Rendering the real screen at the window
/// sizes users actually have turns every one of them into a red test.
void main() {
  late AppDependencies deps;

  setUpAll(() async {
    deps = await AppDependencies.bootstrapForTest();
    deps.tester = LatencyTester();
    deps.healthStore = HealthStore();
    deps.scheduler =
        TestScheduler(tester: deps.tester, store: deps.healthStore);
    deps.appSettings = AppSettings();
    deps.warpRepo = WarpRepository(deps.store, deps.vault);
    deps.cores = CoreManager(
        binaryManager: BinaryManager(),
        workDir: await Directory.systemTemp.createTemp('nexus_layout_test'));
    deps.detector = CoreDetector();
    deps.connection = ConnectionController(
      repository: deps.profiles,
      healthStore: deps.healthStore,
      tester: deps.tester,
      detector: deps.detector,
      cores: deps.cores,
      warpRepo: deps.warpRepo,
      settings: deps.appSettings,
    );
    // initState reads vpnSession unconditionally (android branch of the
    // phase re-read) — the same Android-shaped stub the ladder test uses.
    deps.vpnSession = _TestVpnSession(deps);
  });

  Future<void> pumpDashboard(WidgetTester t, Size size) async {
    t.view.physicalSize = size;
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(
      locale: const Locale('en'),
      supportedLocales: const [Locale('en'), Locale('fa')],
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      theme: NexusTheme.theme(NexusThemeMode.dark),
      home: Scaffold(body: DashboardScreen(deps: deps)),
    ));
    // Two frames: the first lays out, the second settles fade-ins that
    // would otherwise report their overflow a frame later.
    await t.pump(const Duration(milliseconds: 120));
    await t.pump(const Duration(milliseconds: 400));
  }

  // Window sizes seen in the field (1366x768 laptops are still common) plus
  // the awkward ones a user can drag the window to.
  const sizes = <Size>[
    Size(1920, 1080),
    Size(1366, 768),
    Size(1280, 800),
    Size(1024, 640),
    Size(820, 620),
    Size(700, 900),
  ];

  for (final size in sizes) {
    testWidgets('dashboard lays out at ${size.width}x${size.height} cleanly',
        (t) async {
      await pumpDashboard(t, size);

      expect(find.byType(DashboardScreen), findsOneWidget);
      expect(t.takeException(), isNull,
          reason: 'dashboard threw at ${size.width}x${size.height} — '
              'usually a RenderFlex overflow or a bad intrinsic size');

      // Dispose the screen so its timers/controllers cannot leak into the
      // binding's pending-timer check.
      await t.pumpWidget(const SizedBox());
      await t.pump(const Duration(milliseconds: 20));
    }, timeout: const Timeout(Duration(minutes: 2)));
  }

  testWidgets('globe survives extreme aspect ratios inside the dashboard',
      (t) async {
    // A window dragged very wide or very short is the classic way a
    // CustomPaint with a fixed aspect assumption starts painting outside
    // its box (or lays out at zero size).
    for (final size in const [
      Size(1600, 400),
      Size(420, 1000),
      Size(640, 480),
    ]) {
      t.view.physicalSize = size;
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);
      await t.pumpWidget(MaterialApp(
        locale: const Locale('en'),
        supportedLocales: const [Locale('en'), Locale('fa')],
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        theme: NexusTheme.theme(NexusThemeMode.dark),
        home: Scaffold(
          body: SizedBox.expand(
            child: DashboardGlobe(
              anchors: const [
                GlobeAnchor(lat: 35.69, lon: 51.39, kind: GlobeAnchorKind.home),
                GlobeAnchor(
                    lat: 44.43, lon: 26.10, kind: GlobeAnchorKind.exit),
              ],
              initialYaw: 0.7,
            ),
          ),
        ),
      ));
      await t.pump(const Duration(milliseconds: 300));
      expect(t.takeException(), isNull,
          reason: 'globe threw at ${size.width}x${size.height}');
    }
    await t.pumpWidget(const SizedBox());
  }, timeout: const Timeout(Duration(minutes: 2)));
}

/// Test-only VpnSession: the real one boots an AndroidVpnController but
/// makes no platform calls on its own — the dashboard only reads
/// `controller.isAndroid` / `uiPhase` from it.
class _TestVpnSession extends VpnSession {
  _TestVpnSession(this.d) : super(deps: d);

  final AppDependencies d;
}
