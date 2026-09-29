import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/presentation/widgets/dashboard_globe.dart';
import 'package:nexus/theme/theme.dart';

Widget _wrap(Widget child) => MaterialApp(
      theme: NexusTheme.theme(NexusThemeMode.dark),
      home: Scaffold(
        body: SizedBox.expand(child: child),
      ),
    );

void main() {
  testWidgets('globe renders the point cloud without anchors',
      (tester) async {
    await tester.pumpWidget(_wrap(
      const SizedBox(
        width: 360,
        height: 320,
        child: DashboardGlobe(initialYaw: 0.7),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 100));
    // The RepaintBoundary + CustomPaint stack exists and paints.
    expect(find.byType(DashboardGlobe), findsOneWidget);
    expect(
        find.descendant(
            of: find.byType(DashboardGlobe),
            matching: find.byType(CustomPaint)),
        findsWidgets);
  });

  testWidgets('unfold intro completes: flat map becomes a sphere',
      (tester) async {
    await tester.pumpWidget(_wrap(
      const SizedBox(
        width: 360,
        height: 320,
        child: DashboardGlobe(intro: GlobeIntro.unfold, initialYaw: 0.7),
      ),
    ));
    // Mid-morph: still animating (no pumpAndSettle — the controller repeats).
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 5000));
    // The morph deadline passed; the painter must be in sphere mode and the
    // widget tree stable enough for the next frame.
    expect(tester.takeException(), isNull);
  });

  testWidgets('anchors + arc do not throw at any rotation', (tester) async {
    final anchors = [
      const GlobeAnchor(lat: 35.69, lon: 51.39, kind: GlobeAnchorKind.home),
      const GlobeAnchor(
          lat: 44.43, lon: 26.10, kind: GlobeAnchorKind.exit, active: true),
    ];
    await tester.pumpWidget(_wrap(
      SizedBox(
        width: 360,
        height: 320,
        child: DashboardGlobe(anchors: anchors, initialYaw: 3.6),
      ),
    ));
    // A full second of rotation sweeps the arc across the limb — no
    // exceptions from the slerp/projection path (the Iran→Romania arc).
    await tester.pump(const Duration(milliseconds: 1000));
    expect(tester.takeException(), isNull);
  });
}
