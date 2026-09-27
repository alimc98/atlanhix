import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/health/latency_tester.dart';
import 'package:nexus/core/health/test_scheduler.dart';
import 'package:nexus/domain/entities/health.dart';
import 'package:nexus/domain/entities/proxy_profile.dart';
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

/// Seeds [samples] (ok, latencyMs) per id through the real HealthStore so
/// jitter/successRate derive exactly as they do on device.
HealthStore _seed(Map<String, List<(bool, int?)>> samples) {
  final h = HealthStore();
  samples.forEach((id, list) {
    for (final (ok, lat) in list) {
      h.record(HealthRecord(
        profileId: id,
        at: DateTime.now(),
        ok: ok,
        latencyMs: lat,
        errorKind: ok ? null : 'timeout',
      ));
    }
  });
  return h;
}

void main() {
  test('a spiky fast node does NOT outrank a steady slightly-slower one',
      () async {
    // spiky: 100 ms but ±80 jitter → jit ≈ 80 → 120 pts
    // steady: 140 ms, ±10 → jit ≈ 10 → 190 pts
    // Latency gap: 40 ms ≈ 40 pts < jitter gap 70 pts → steady wins.
    final health = _seed({
      'spiky': [for (var i = 0; i < 6; i++) (true, i.isEven ? 20 : 180)],
      'steady': [for (var i = 0; i < 6; i++) (true, 130 + (i % 3) * 10)],
    });
    expect(health.statsOf('spiky')!.jitterMs, greaterThan(3000),
        reason: 'jitterMs stores the VARIANCE (ms²) — spiky ≈ 6400');
    expect(health.statsOf('steady')!.jitterMs, lessThan(300),
        reason: 'steady variance stays tiny (stdDev < ~17 ms)');
    expect(health.statsOf('spiky')!.avgLatencyMs!,
        lessThan(health.statsOf('steady')!.avgLatencyMs!),
        reason: 'on AVERAGE the spiky node is faster — only steadiness '
            'turns the ladder');

    final switcher = SmartSwitch(
      scheduler: TestScheduler(tester: LatencyTester(), store: health),
      health: health,
      interval: const Duration(seconds: 0),
    );
    switcher.start([_p('spiky'), _p('steady')], currentId: 'spiky');
    await Future<void>.delayed(const Duration(milliseconds: 450));
    expect(switcher.best?.id, 'steady',
        reason: 'jitter must matter: the steadier node takes the ladder');
  });

  test('a flaky node (low success rate) never outranks a reliable one',
      () async {
    // flaky: ~57% ok in the 7-sample window, fast when it answers.
    // reliable: 100% ok, a bit slower.
    final health = _seed({
      'flaky': [
        (true, 80), (false, null), (true, 90), (false, null),
        (true, 85), (false, null), (true, 88),
      ],
      'reliable': [for (var i = 0; i < 7; i++) (true, 160)],
    });
    expect(health.statsOf('flaky')!.successRate, lessThan(0.65));
    expect(health.statsOf('reliable')!.successRate, 1.0);

    final switcher = SmartSwitch(
      scheduler: TestScheduler(tester: LatencyTester(), store: health),
      health: health,
      interval: const Duration(seconds: 0),
    );
    switcher.start([_p('flaky'), _p('reliable')], currentId: 'reliable');
    await Future<void>.delayed(const Duration(milliseconds: 450));
    expect(switcher.best?.id, 'reliable',
        reason: 'success rate must matter: 80 ms at 57% up is worse than '
            '160 ms at 100% up');
  });

  test('composite margin: a steadier challenger wins with a smaller latency '
      'lead', () async {
    // incumbent: 150 ms but SPIKY (variance ≈ 4900 ms²) — jitter pts ≈ 0.
    // challenger: 120 ms, steady (variance ≈ 0) — only 30 ms better, but
    // under the 60 ms latency-shaped margin the RAW latency comparison
    // would reject it; the composite lets the jitter gap decide:
    // lat 880 vs 910 (+30), jit 200 vs ~51 (+149) → margin cleared.
    final health = _seed({
      'inc': [for (var i = 0; i < 6; i++) (true, i.isEven ? 60 : 240)],
      'chal': [for (var i = 0; i < 6; i++) (true, 115 + (i % 3) * 5)],
    });
    expect(health.statsOf('chal')!.lastLatencyMs!, 125);
    final switcher = SmartSwitch(
      scheduler: TestScheduler(tester: LatencyTester(), store: health),
      health: health,
      interval: const Duration(seconds: 0),
      marginMs: 60,
    );
    final seen = <String>[];
    final sub = switcher.changes.listen((p) => seen.add(p.id));
    addTearDown(() async {
      await sub.cancel();
      switcher.dispose();
    });
    switcher.start([_p('inc'), _p('chal')], currentId: 'inc');
    await Future<void>.delayed(const Duration(milliseconds: 450));
    expect(switcher.best?.id, 'chal',
        reason: 'composite margin: a steadier challenger needs a smaller '
            'latency lead → migrate');
    expect(seen, ['chal']);
  });

  test('composite margin: an equally-steady challenger inside the margin '
      'stays put', () async {
    final health = _seed({
      'inc': [for (var i = 0; i < 6; i++) (true, 150)],
      'chal': [for (var i = 0; i < 6; i++) (true, 110)],
    });
    final switcher = SmartSwitch(
      scheduler: TestScheduler(tester: LatencyTester(), store: health),
      health: health,
      interval: const Duration(seconds: 0),
      marginMs: 60, // 40 ms better — inside the tolerance
    );
    switcher.start([_p('inc'), _p('chal')], currentId: 'inc');
    await Future<void>.delayed(const Duration(milliseconds: 450));
    expect(switcher.best?.id, 'inc',
        reason: 'no composite advantage → the incumbent keeps the tunnel');
  });

  test('legacy invariants hold: unknown never beats measured fast, dead '
      'incumbent always abandoned', () async {
    final health = _seed({
      'fast': [(true, 100)],
      'dead': [(false, null), (false, null), (false, null)],
    });
    final switcher = SmartSwitch(
      scheduler: TestScheduler(tester: LatencyTester(), store: health),
      health: health,
      interval: const Duration(seconds: 0),
      marginMs: 5000,
    );
    final seen = <String>[];
    final sub = switcher.changes.listen((p) => seen.add(p.id));
    addTearDown(() async {
      await sub.cancel();
      switcher.dispose();
    });
    switcher.start([_p('dead'), _p('fast')], currentId: 'dead');
    await Future<void>.delayed(const Duration(milliseconds: 450));
    expect(switcher.best?.id, 'fast',
        reason: 'unusable incumbent is abandoned regardless of the margin');
    expect(seen, ['fast']);
  });
}
