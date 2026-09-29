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
