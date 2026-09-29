import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/application/node_usage.dart';
import 'package:nexus/presentation/widgets/globe_backdrop.dart';
import 'package:nexus/theme/theme.dart';

void main() {
  testWidgets('placeholder sanity', (tester) async {});

  group('NodeUsage delta accounting', () {
    test('folds counter deltas into the active node bucket', () {
      final u = NodeUsage(() async => null, (_) async {});
      addTearDown(u.dispose);
      u.fold('node-a', 0, 0); // baseline
      u.fold('node-a', 100, 900);
      u.fold('node-a', 250, 1500);
      expect(u.of('node-a').up, 250);
      expect(u.of('node-a').down, 1500);
      expect(u.of('node-b'), (up: 0, down: 0));
    });

    test('migration re-baselines — bytes split by node', () {
      final u = NodeUsage(() async => null, (_) async {});
      addTearDown(u.dispose);
      u.fold('a', 0, 0);
      u.fold('a', 100, 100);
      u.fold('b', 150, 200); // switch → new baseline
      u.fold('b', 350, 700);
      expect(u.of('a'), (up: 100, down: 100));
      expect(u.of('b'), (up: 200, down: 500));
    });

    test('a counter RESTART never produces negative spikes', () {
      final u = NodeUsage(() async => null, (_) async {});
      addTearDown(u.dispose);
      u.fold('a', 5000, 5000);
      u.fold('a', 10, 20); // engine reboot reset the counters
      expect(u.of('a').up, 0, reason: 'a shrinking counter re-baselines');
      expect(u.of('a').down, 0);
    });
  });

  group('GlobeBackdrop', () {
    Widget wrap(Widget child) => MaterialApp(
          theme: NexusTheme.theme(NexusThemeMode.dark),
          home: const Scaffold(body: SizedBox.expand()),
        ).letScaffold(child: child);

    testWidgets('mounts behind the app without gestures', (tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: NexusTheme.theme(NexusThemeMode.dark),
        home: const Scaffold(
          backgroundColor: Colors.transparent,
          body: Stack(
            fit: StackFit.expand,
            children: [
              GlobeBackdrop(connected: false, connecting: false),
              Center(child: Text('OVER')),
            ],
          ),
        ),
      ));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('OVER'), findsOneWidget);
      expect(find.byType(GlobeBackdrop), findsOneWidget);
      // The backdrop fills the body (full-screen background).
      expect(
        tester.getSize(find.byType(GlobeBackdrop)),
        tester.getSize(find.byType(Scaffold).first),
      );
    });

    testWidgets('connection state change does not throw', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: GlobeBackdrop(connected: false, connecting: false),
        ),
      ));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: GlobeBackdrop(connected: true, connecting: false),
        ),
      ));
      await tester.pump(const Duration(milliseconds: 50));
      expect(tester.takeException(), isNull);
    });
  });
}

extension _Let on Widget {
  Widget letScaffold({required Widget child}) => child;
}
