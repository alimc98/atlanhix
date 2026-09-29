import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/health/latency_tester.dart';
import 'package:nexus/core/health/test_scheduler.dart';
import 'package:nexus/domain/entities/health.dart';
import 'package:nexus/domain/entities/proxy_profile.dart';
import 'package:nexus/settings/app_settings.dart';
import 'package:nexus/settings/smart_switch.dart';

ProxyProfile _p(String id) => ProxyProfile(
      id: id,
      name: 'n-$id',
      server: '10.0.0.1',
      port: 443,
      protocol: ProxyProtocol.shadowsocks,
      ssMethod: 'aes-128-gcm',
      password: 'ss-pass-1',
    );

HealthStore _seedHealth(Map<String, (bool, int?)> seed) {
  final h = HealthStore();
  seed.forEach((id, v) {
    h.record(HealthRecord(
      profileId: id,
      at: DateTime.now(),
      ok: v.$1,
      latencyMs: v.$2,
      errorKind: v.$1 ? null : 'timeout',
    ));
  });
  return h;
}

SmartSwitch _switcher(HealthStore health, {int? marginPercent, int marginMs = 0}) {
  return SmartSwitch(
    scheduler: TestScheduler(tester: LatencyTester(), store: health),
    health: health,
    interval: const Duration(seconds: 0),
    marginMs: marginMs,
    marginPercent: marginPercent ?? 30,
  );
}

void main() {
  test('percent margin: 30% default — small gains do NOT migrate', () async {
    // Incumbent 200 ms; challenger 160 ms = 20% faster — INSIDE the 30%
    // margin → stay.
    final health = _seedHealth({'a': (true, 200), 'b': (true, 160)});
    final s = _switcher(health);
    final seen = <String>[];
    final sub = s.changes.listen((p) => seen.add(p.id));
    addTearDown(() async {
      await sub.cancel();
      s.dispose();
    });
    s.start([_p('a'), _p('b')], currentId: 'a');
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(s.best?.id, 'a', reason: '20% < 30% margin → no migration');
    expect(seen, isEmpty);
  });

  test('percent margin: a big enough gain migrates', () async {
    // Challenger 100 ms vs 200 ms = 50% faster — beyond the 30% margin.
    // (No probe provider → the sweep's TCP fallback evaluates after its
    // 400 ms settle delay; the poll waits that out.)
    final health = _seedHealth({'a': (true, 200), 'b': (true, 100)});
    final s = _switcher(health);
    final seen = <String>[];
    final sub = s.changes.listen((p) => seen.add(p.id));
    addTearDown(() async {
      await sub.cancel();
      s.dispose();
    });
    s.start([_p('a'), _p('b')], currentId: 'a');
    await Future<void>.delayed(const Duration(milliseconds: 700));
    expect(s.best?.id, 'b', reason: '50% > 30% margin → migrate');
    expect(seen, ['b']);
  });

  test('user-settable margin: 60% keeps a 50% gain out', () async {
    final health = _seedHealth({'a': (true, 200), 'b': (true, 100)});
    final s = _switcher(health, marginPercent: 60);
    s.start([_p('a'), _p('b')], currentId: 'a');
    await Future<void>.delayed(const Duration(milliseconds: 700));
    expect(s.best?.id, 'a', reason: '50% < 60% user margin → stay');
  });

  test('a dead incumbent always migrates regardless of the margin', () async {
    final health = _seedHealth({'a': (false, null), 'b': (true, 300)});
    final s = _switcher(health);
    s.start([_p('a'), _p('b')], currentId: 'a');
    await Future<void>.delayed(const Duration(milliseconds: 700));
    expect(s.best?.id, 'b', reason: 'dead incumbent is abandoned');
  });

  test('the initial pre-connect sweep fills best from REAL probes',
      () async {
    final health = HealthStore();
    final s = SmartSwitch(
      scheduler: TestScheduler(tester: LatencyTester(), store: health),
      health: health,
      interval: const Duration(seconds: 0),
      marginPercent: 30,
      urlBatchProbe: (batch, {onNode}) async => {
        'a': ProbeResult(ok: true, latencyMs: 420),
        'b': ProbeResult(ok: true, latencyMs: 180),
        'c': ProbeResult(ok: false, latencyMs: null,
            errorKind: 'timeout'),
      },
    );
    addTearDown(s.dispose);
    await s.initialSweep([_p('a'), _p('b'), _p('c')]);
    expect(s.best?.id, 'b', reason: 'the ladder picks the REAL fastest');
    // The results landed in the shared store — the UI latency column and
    // this ladder read the SAME truth.
    expect(health.statsOf('b')?.lastLatencyMs, 180);
    expect(health.statsOf('c')?.state, NodeHealth.timeout);
  });

  test('measured stream fires after a sweep (the Nodes tab repaint hook)',
      () async {
    final health = HealthStore();
    final s = SmartSwitch(
      scheduler: TestScheduler(tester: LatencyTester(), store: health),
      health: health,
      interval: const Duration(seconds: 0),
      marginPercent: 30,
      urlBatchProbe: (batch, {onNode}) async =>
          {for (final p in batch) p.id: ProbeResult(ok: true, latencyMs: 90)},
    );
    addTearDown(s.dispose);
    var fired = 0;
    final sub = s.measured.listen((_) => fired++);
    addTearDown(sub.cancel);
    await s.initialSweep([_p('a'), _p('b')]);
    await Future<void>.delayed(Duration.zero);
    expect(fired, greaterThanOrEqualTo(1),
        reason: 'the first sweep must announce its fresh pings');
  });

  test('AppSettings defaults carry the professional dials', () {
    final st = AppSettings();
    expect(st.smartSwitchMarginPercent, 30);
    expect(st.smartSwitchActiveRecheckSeconds, 30);
    expect(st.smartSwitchOthersRescanMinutes, 10);
  });

  test('AppSettings JSON round-trip preserves the dials', () {
    final st = AppSettings()
      ..smartSwitchMarginPercent = 45
      ..smartSwitchActiveRecheckSeconds = 60
      ..smartSwitchOthersRescanMinutes = 20;
    final restored = AppSettings.fromJson(st.toJson());
    expect(restored.smartSwitchMarginPercent, 45);
    expect(restored.smartSwitchActiveRecheckSeconds, 60);
    expect(restored.smartSwitchOthersRescanMinutes, 20);
  });
}
