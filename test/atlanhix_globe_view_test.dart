import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/domain/entities/proxy_profile.dart';
import 'package:nexus/presentation/globe/atlanhix_globe_view.dart';
import 'package:nexus/presentation/globe/globe_geo.dart';
import 'package:nexus/presentation/widgets/dashboard_globe.dart'
    show GlobeAnchor, GlobeAnchorKind;
import 'package:nexus/presentation/widgets/globe_backdrop.dart';
import 'package:nexus/theme/theme.dart';

Widget _wrap(Widget child) => MaterialApp(
      theme: NexusTheme.theme(NexusThemeMode.dark),
      home: Scaffold(
        body: SizedBox.expand(child: child),
      ),
    );

const _tehran = GlobeLocation(lat: 35.69, lon: 51.42, label: 'Tehran');
const _london = GlobeLocation(lat: 51.51, lon: -0.13, label: 'London');

ProxyProfile _node(String id, String name) => ProxyProfile(
      id: id,
      name: name,
      server: '10.0.0.1',
      port: 443,
      protocol: ProxyProtocol.shadowsocks,
      ssMethod: 'aes-128-gcm',
      password: 'pw',
    );

void main() {
  testWidgets('globe view renders in the CPU-fallback env without errors',
      (tester) async {
    await tester.pumpWidget(_wrap(
      const SizedBox(
        width: 360,
        height: 320,
        child: AtlanhixGlobeView(source: _tehran, destination: _london),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 200));
    expect(tester.takeException(), isNull);
    expect(find.byType(AtlanhixGlobeView), findsOneWidget);
  });

  testWidgets('all five visual states paint without exceptions',
      (tester) async {
    for (final st in GlobeVisualState.values) {
      await tester.pumpWidget(_wrap(
        SizedBox(
          width: 360,
          height: 320,
          child: AtlanhixGlobeView(
            source: _tehran,
            destination: _london,
            state: st,
            error: st == GlobeVisualState.error,
          ),
        ),
      ));
      await tester.pump(const Duration(milliseconds: 60));
      expect(tester.takeException(), isNull, reason: st.name);
    }
  });

  testWidgets('destination morph: switching nodes never throws', (tester) async {
    GlobeLocation dest = _london;
    late StateSetter setter;
    await tester.pumpWidget(_wrap(
      StatefulBuilder(builder: (context, s) {
        setter = s;
        return SizedBox(
          width: 360,
          height: 320,
          child: AtlanhixGlobeView(
            source: _tehran,
            destination: dest,
            state: GlobeVisualState.connected,
            initialYaw: 0.7,
          ),
        );
      }),
    ));
    await tester.pump(const Duration(milliseconds: 100));
    // Iran → Hong Kong
    setter(() {
      dest = const GlobeLocation(lat: 22.32, lon: 114.17, label: 'Hong Kong');
    });
    // Morph runs ~0.9 s; pump through it with frames.
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.takeException(), isNull);
    }
    // Iran → Singapore
    setter(() {
      dest = const GlobeLocation(lat: 1.35, lon: 103.82, label: 'Singapore');
    });
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('route states drive the visible route on/off', (tester) async {
    // Connected with both anchors: route painter path executes (no throw).
    await tester.pumpWidget(_wrap(
      const SizedBox(
        width: 360,
        height: 320,
        child: AtlanhixGlobeView(
          source: _tehran,
          destination: _london,
          state: GlobeVisualState.connecting,
          initialYaw: 0.7,
        ),
      ),
    ));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.takeException(), isNull);
    }
    // Back to idle: route target drops to 0 and fades out gracefully.
    await tester.pumpWidget(_wrap(
      const SizedBox(
        width: 360,
        height: 320,
        child: AtlanhixGlobeView(
          source: _tehran,
          destination: _london,
          state: GlobeVisualState.idle,
          initialYaw: 0.7,
        ),
      ),
    ));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('disconnecting retracts the route (fade-out on teardown)',
      (tester) async {
    // Regression guard for v0.5.6 §globe-fix: `disconnecting` used to count
    // as "route visible", so the arc stayed at full strength while the
    // tunnel was already going down. The spec wants it to fade.
    final view = find.byType(AtlanhixGlobeView);
    Widget build(GlobeVisualState st) => _wrap(
          SizedBox(
            width: 360,
            height: 320,
            child: AtlanhixGlobeView(
              source: _tehran,
              destination: _london,
              state: st,
              initialYaw: 0.7,
            ),
          ),
        );

    // The route eases in at ~2.1/s now that dt is wall-clock based, so
    // ~1.5 s of pumped frames saturates it (exp decay approaches 1
    // asymptotically; 1.5 s ≈ 0.96, then it snaps via the epsilon check).
    await tester.pumpWidget(build(GlobeVisualState.connected));
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    final state = tester.state<AtlanhixGlobeViewState>(view);
    expect(state.routeProgress, greaterThan(0.9),
        reason: 'connected should draw the route');

    // Teardown begins → the route must start retracting.
    await tester.pumpWidget(build(GlobeVisualState.disconnecting));
    await tester.pump(const Duration(milliseconds: 100));
    final during = tester.state<AtlanhixGlobeViewState>(view).routeProgress;
    expect(during, lessThan(1.0),
        reason: 'disconnecting must retract, not hold, the route');

    // And it keeps going down to nothing. The fade rate is ~0.72/s, so give it
    // a generous ~15 s of pumped frames — well past the point where the
    // epsilon snap parks _routeT exactly on its 0 target.
    for (var i = 0; i < 150; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(tester.state<AtlanhixGlobeViewState>(view).routeProgress,
        lessThan(0.05), reason: 'route should fade out completely');
  });

  testWidgets('error keeps the route visible (shows the attempted hop)',
      (tester) async {
    await tester.pumpWidget(_wrap(
      const SizedBox(
        width: 360,
        height: 320,
        child: AtlanhixGlobeView(
          source: _tehran,
          destination: _london,
          state: GlobeVisualState.error,
          error: true,
          initialYaw: 0.7,
        ),
      ),
    ));
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(
        tester
            .state<AtlanhixGlobeViewState>(find.byType(AtlanhixGlobeView))
            .routeProgress,
        greaterThan(0.9),
        reason: 'a failed connect should still show where it was headed');
  });

  testWidgets('animation rate is frame-rate independent (30 Hz vs 120 Hz)',
      (tester) async {
    // Regression guard for v0.5.6 §globe-fix. The tick used to hardcode
    // `dt = 1/60`, so every rate below was per-FRAME: on a 120 Hz phone the
    // route drew at double speed and on a throttled 30 Hz one at half. This
    // pumps the SAME wall-clock window at two refresh rates and asserts
    // they land in the same place.
    Widget build(GlobeVisualState st) => _wrap(
          SizedBox(
            width: 360,
            height: 320,
            child: AtlanhixGlobeView(
              source: _tehran,
              destination: _london,
              state: st,
              initialYaw: 0.7,
            ),
          ),
        );

    Future<double> progressAfter(int fps) async {
      await tester.pumpWidget(build(GlobeVisualState.connected));
      final st =
          tester.state<AtlanhixGlobeViewState>(find.byType(AtlanhixGlobeView));
      const window = Duration(milliseconds: 3000);
      final frames = fps * 40;
      final step =
          Duration(microseconds: (window.inMicroseconds / frames).round());
      for (var i = 0; i < frames; i++) {
        await tester.pump(step);
      }
      return st.routeProgress;
    }

    final at30 = await progressAfter(30);
    final at120 = await progressAfter(120);
    expect((at30 - at120).abs(), lessThan(0.08),
        reason: 'route progress must not depend on refresh rate '
            '(30 Hz gave $at30, 120 Hz gave $at120)');
  });

  testWidgets('route progress never overshoots its 0..1 range',
      (tester) async {
    // Regression guard: the exponential-approach rewrite initially pushed
    // routeT to 1.044 and left it oscillating around 1 forever.
    await tester.pumpWidget(_wrap(
      const SizedBox(
        width: 360,
        height: 320,
        child: AtlanhixGlobeView(
          source: _tehran,
          destination: _london,
          state: GlobeVisualState.connected,
          initialYaw: 0.7,
        ),
      ),
    ));
    final st =
        tester.state<AtlanhixGlobeViewState>(find.byType(AtlanhixGlobeView));
    var sawOvershoot = false;
    var previous = st.routeProgress;
    for (var i = 0; i < 60; i++) {
      await tester.pump(const Duration(milliseconds: 32));
      final now = st.routeProgress;
      expect(now, inInclusiveRange(0.0, 1.0),
          reason: 'routeProgress must stay within 0..1');
      if (now < previous - 1e-9 && previous >= 1.0) sawOvershoot = true;
      previous = now;
    }
    expect(sawOvershoot, isFalse,
        reason: 'progress must approach 1 monotonically, never fall back');
    expect(previous, greaterThan(0.99), reason: 'and it should have arrived');
  });

  testWidgets('shader clock is monotonic and never reads the wall clock',
      (tester) async {
    await tester.pumpWidget(_wrap(
      const SizedBox(
        width: 360,
        height: 320,
        child: AtlanhixGlobeView(
          source: _tehran,
          destination: _london,
          state: GlobeVisualState.connected,
          initialYaw: 0.7,
        ),
      ),
    ));
    final st =
        tester.state<AtlanhixGlobeViewState>(find.byType(AtlanhixGlobeView));
    var previous = st.shaderTime;
    expect(previous, greaterThanOrEqualTo(0));
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 32));
      final now = st.shaderTime;
      // Monotonically non-decreasing, bounded, and nowhere near a
      // wall-clock value (which would be ~1.7e9 seconds since epoch).
      expect(now, greaterThanOrEqualTo(previous));
      expect(now, lessThan(st.shaderTimeWrap));
      expect(now, lessThan(1e6));
      previous = now;
    }
    expect(previous, greaterThan(0),
        reason: 'the shader clock must actually advance');
  });

  testWidgets('config toggles disable route/orbit without errors',
      (tester) async {
    await tester.pumpWidget(_wrap(
      const SizedBox(
        width: 360,
        height: 320,
        child: AtlanhixGlobeView(
          source: _tehran,
          destination: _london,
          state: GlobeVisualState.connected,
          config: AtlanhixGlobeConfig(
            showRoute: false,
            showOrbit: false,
            showPacketFlow: false,
            autoRotate: false,
          ),
        ),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 120));
    expect(tester.takeException(), isNull);
  });

  group('destinationForNode', () {
    test('uses country hints when geo has no host fix', () {
      final loc = destinationForNode(
          _node('n1', 'UK · London'), null);
      expect(loc, isNotNull);
      expect(loc!.lat, closeTo(51.51, 0.2));
    });
    test('flag emoji resolves', () {
      expect(destinationForNode(_node('n2', '🇸🇬 SG-1'), null),
          isNotNull);
    });
    test('unresolvable node → null (no invented pin)', () {
      expect(destinationForNode(_node('n3', 'fast-node-9'), null), isNull);
      expect(destinationForNode(null, null), isNull);
    });
  });

  group('GlobeBackdrop visual-state mapping', () {
    Future<GlobeVisualState> stateOf(WidgetTester tester,
        {required bool connected,
        required bool connecting,
        bool disconnecting = false,
        bool error = false}) async {
      AtlanhixGlobeView? view;
      await tester.pumpWidget(_wrap(
        SizedBox(
          width: 400,
          height: 400,
          child: GlobeBackdrop(
            connected: connected,
            connecting: connecting,
            disconnecting: disconnecting,
            error: error,
            anchors: const [
              GlobeAnchor(lat: 35.69, lon: 51.42, kind: GlobeAnchorKind.home),
              GlobeAnchor(
                  lat: 51.51, lon: -0.13,
                  kind: GlobeAnchorKind.exit, active: true),
            ],
          ),
        ),
      ));
      await tester.pump(const Duration(milliseconds: 60));
      tester.element(find.byWidgetPredicate((w) => w is AtlanhixGlobeView));
      view = tester.widget<AtlanhixGlobeView>(
          find.byType(AtlanhixGlobeView));
      expect(tester.takeException(), isNull);
      return view.state;
    }

    testWidgets('connected → connected', (tester) async {
      expect(await stateOf(tester, connected: true, connecting: false),
          GlobeVisualState.connected);
    });
    testWidgets('connecting → connecting', (tester) async {
      expect(await stateOf(tester, connected: false, connecting: true),
          GlobeVisualState.connecting);
    });
    testWidgets('error → error', (tester) async {
      expect(await stateOf(tester, connected: false, connecting: false,
          error: true), GlobeVisualState.error);
    });
    testWidgets('disconnecting → disconnecting', (tester) async {
      expect(await stateOf(tester, connected: false, connecting: false,
          disconnecting: true), GlobeVisualState.disconnecting);
    });
    testWidgets('nothing → idle', (tester) async {
      expect(await stateOf(tester, connected: false, connecting: false),
          GlobeVisualState.idle);
    });
  });
}
