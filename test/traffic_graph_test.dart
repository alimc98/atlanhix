import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/presentation/widgets/traffic_graph.dart';
import 'package:nexus/theme/theme.dart';

void main() {
  // Deterministic sample traffic (bytes/s): rolling hills + a live tail
  // so the NOW burst and the pill both have something to say.
  List<double> series(int seed) => List.generate(60, (i) {
        final t = i / 59;
        final wave = math.sin(t * math.pi * 2.6 + seed * 1.3) * 0.5 + 0.5;
        final spike = (i % 17 == 0) ? 0.85 * (1 - t * 0.3) : 0.0;
        final tail = i >= 55 ? 0.55 + 0.1 * (i - 55) : 0.0; // live tail
        return math.max(math.max(wave * 0.55, spike), tail) *
            (900_000 - seed * 200_000);
      });

  Widget harness(Widget child, Size size) => MaterialApp(
        theme: NexusTheme.theme(NexusThemeMode.dark),
        home: Scaffold(
          backgroundColor: const Color(0xFF060907),
          body: Center(
            child: SizedBox.fromSize(
              size: size,
              child: child,
            ),
          ),
        ),
      );

  testWidgets('traffic graph renders waves + burst + pill (golden)',
      (t) async {
    await t.binding.setSurfaceSize(const Size(640, 320));
    addTearDown(() => t.binding.setSurfaceSize(null));

    await t.pumpWidget(harness(
      TrafficGraph(
        downSamples: series(0),
        upSamples: series(1),
        height: 240,
        // Freeze the pill at the mockup position for the golden.
        pillPosition: 0.635,
      ),
      const Size(560, 260),
    ));
    // One controlled frame of the 9 s phase loop (never pumpAndSettle —
    // the animator repeats forever by design).
    await t.pump(const Duration(milliseconds: 400));
    await expectLater(find.byType(TrafficGraph),
        matchesGoldenFile('goldens/traffic_graph.png'));
  });

  testWidgets('zero-traffic state still paints (no crash, pill hidden)',
      (t) async {
    await t.binding.setSurfaceSize(const Size(320, 200));
    addTearDown(() => t.binding.setSurfaceSize(null));
    await t.pumpWidget(harness(
      TrafficGraph(
        downSamples: List.filled(60, 0),
        upSamples: List.filled(60, 0),
        height: 160,
        showPeakPill: false,
      ),
      const Size(300, 180),
    ));
    await t.pump(const Duration(milliseconds: 200));
    expect(t.takeException(), isNull);
  });

  testWidgets('empty sample lists do not crash the painter', (t) async {
    await t.binding.setSurfaceSize(const Size(320, 200));
    addTearDown(() => t.binding.setSurfaceSize(null));
    await t.pumpWidget(harness(
      const TrafficGraph(
        downSamples: [],
        upSamples: [],
        height: 160,
      ),
      const Size(300, 180),
    ));
    await t.pump(const Duration(milliseconds: 200));
    expect(t.takeException(), isNull);
  });
}
