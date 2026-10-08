import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/application/connection_controller.dart';
import 'package:nexus/localization/generated/app_localizations.dart';
import 'package:nexus/presentation/widgets/common_widgets.dart';
import 'package:nexus/presentation/widgets/speed_graph.dart';
import 'package:nexus/theme/theme.dart';

Widget _wrap(Widget child) => MaterialApp(
      theme: NexusTheme.theme(NexusThemeMode.dark),
      home: Scaffold(body: Center(child: child)),
    );

void main() {
  group('MetricTile', () {
    testWidgets('renders label and value', (tester) async {
      await tester.pumpWidget(_wrap(
        const MetricTile(label: 'Latency', value: '32 ms'),
      ));
      expect(find.text('LATENCY'), findsOneWidget);
      expect(find.text('32 ms'), findsOneWidget);
    });
  });

  group('ConnectButton', () {
    testWidgets('tapping triggers toggle', (tester) async {
      var toggled = false;
      await tester.pumpWidget(_wrap(
        ConnectButton(
          phase: ConnectionPhase.disconnected,
          onToggle: () => toggled = true,
        ),
      ));
      await tester.tap(find.byType(GestureDetector).first);
      expect(toggled, isTrue);
    });
  });

  group('StatusDot', () {
    testWidgets('shows label when provided', (tester) async {
      await tester.pumpWidget(_wrap(
        const StatusDot(color: Colors.green, label: 'Healthy'),
      ));
      expect(find.text('Healthy'), findsOneWidget);
    });
  });

  group('SpeedGraph', () {
    testWidgets('renders without data (waiting state)', (tester) async {
      await tester.pumpWidget(_wrap(
        const SizedBox(
          width: 300,
          child: SpeedGraph(downSamples: [], upSamples: []),
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.byType(CustomPaint), findsWidgets);
    });

    testWidgets('renders with data', (tester) async {
      await tester.pumpWidget(_wrap(
        SizedBox(
          width: 300,
          child: SpeedGraph(
            downSamples: List.generate(30, (i) => i.toDouble()),
            upSamples: List.generate(30, (i) => i / 2),
          ),
        ),
      ));
      await tester.pumpAndSettle();
    });
  });

  group('RTL / Persian smoke', () {
    testWidgets('Persian locale renders localized strings', (tester) async {
      late AppLocalizations l;
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('fa'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(
            builder: (context) {
              l = AppLocalizations.of(context)!;
              return const Scaffold(body: SizedBox());
            },
          ),
        ),
      );
      expect(l.connected, 'متصل');
      expect(l.healthHealthy, 'سالم');
    });
  });
}
