import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/health/test_scheduler.dart';
import 'package:nexus/domain/entities/health.dart';
import 'package:nexus/domain/entities/proxy_profile.dart';
import 'package:nexus/localization/generated/app_localizations.dart';
import 'package:nexus/presentation/screens/nodes_screen.dart';
import 'package:nexus/theme/theme.dart';

ProxyProfile _p(String id) => ProxyProfile(
      id: id,
      name: 'n-$id',
      server: '10.0.0.1',
      port: 443,
      protocol: ProxyProtocol.shadowsocks,
      ssMethod: 'aes-128-gcm',
      password: 'ss-pass-1',
    );

Widget _wrap(Widget child) => MaterialApp(
      theme: NexusTheme.theme(NexusThemeMode.dark),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: Center(child: child)),
    );


void main() {
  test('nodeMetricSubline: stdDev is derived from the stored variance', () {
    // variance 1600 ms² → stdDev 40 ms.
    expect(nodeMetricSubline(jitterMs: 1600, successRate: 1.0),
        '±40 ms · 100% up');
    // Small variance keeps one decimal (±2.4 ms reads precisely).
    expect(
        nodeMetricSubline(jitterMs: 6, successRate: 0.933), '±2.4 ms · 93% up');
  });

  test('nodeMetricSubline: no jitter history → jitter omitted, rate kept', () {
    expect(nodeMetricSubline(jitterMs: null, successRate: 0.5), '50% up');
    expect(nodeMetricSubline(jitterMs: null, successRate: null), '');
  });

  test('nodeMetricSubline: rate clamps to the sane range', () {
    // Variance 0 still prints with one decimal below the 10 ms threshold —
    // the honest shape (±0.0) rather than a fake-precise integer.
    expect(nodeMetricSubline(jitterMs: 0, successRate: 1.5), '±0.0 ms · 100% up');
  });

  testWidgets('node tile renders the stability subline under the latency',
      (tester) async {
    final h = HealthStore();
    // successRate 0.5: 1 ok / 1 fail in the window.
    h.record(HealthRecord(
        profileId: 'a', at: DateTime.now(), ok: true, latencyMs: 120));
    h.record(HealthRecord(
        profileId: 'a',
        at: DateTime.now(),
        ok: false,
        latencyMs: null,
        errorKind: 'timeout'));
    final s = h.statsOf('a')!;
    final expected = nodeMetricSubline(
        jitterMs: s.jitterMs, successRate: s.successRate);
    expect(expected, contains('% up'));

    await tester.pumpWidget(_wrap(NodeTile(
      profile: _p('a'),
      stats: s,
      onConnect: () {},
      onCoreTap: () {},
    )));
    expect(find.text('120 ms'), findsOneWidget);
    expect(find.text(expected), findsOneWidget);
  });

  testWidgets('never-tested node renders the empty subline (no fake ±0)',
      (tester) async {
    await tester.pumpWidget(_wrap(NodeTile(
      profile: _p('b'),
      stats: null,
      onConnect: () {},
      onCoreTap: () {},
    )));
    expect(find.text('—'), findsOneWidget);
    expect(find.text(''), findsOneWidget);
  });

  testWidgets('measured-steady node shows a real ± value and 100% up',
      (tester) async {
    final h = HealthStore();
    // Two samples 20 ms apart → variance ≈ 100 ms² → σ ≈ 10 ms.
    h.record(HealthRecord(
        profileId: 'c', at: DateTime.now(), ok: true, latencyMs: 130));
    h.record(HealthRecord(
        profileId: 'c', at: DateTime.now(), ok: true, latencyMs: 150));
    final s = h.statsOf('c')!;
    final expected = nodeMetricSubline(
        jitterMs: s.jitterMs, successRate: s.successRate);
    expect(expected, '±10 ms · 100% up');

    await tester.pumpWidget(_wrap(NodeTile(
      profile: _p('c'),
      stats: s,
      onConnect: () {},
      onCoreTap: () {},
    )));
    expect(find.text('±10 ms · 100% up'), findsOneWidget);
    // Keep the analyzer import used even if assertions above change shape.
    expect(math.sqrt(s.jitterMs!), closeTo(10, 0.5));
  });
}
