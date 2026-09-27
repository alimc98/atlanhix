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

void main() {
  test('recommends a better node while the tunnel is DOWN and the switch '
      'was armed from the card (stale-currentId regression)', () async {
    // The v0.5.0 device bug: best stays null on the first sweep, so the
    // fresh winner was compared against the STALE currentId and the dead
    // incumbent was re-elected as "no change" — no migration ever fired.
    final health = HealthStore();
    final switcher = SmartSwitch(
      scheduler: TestScheduler(tester: LatencyTester(), store: health),
      health: health,
      interval: const Duration(seconds: 1),
      urlProbe: (p) async =>
          p.id == 'bad' ? null : ProbeResult(ok: true, latencyMs: 300),
    );
    final bad = _p('bad');
    final good = _p('good');
    final seen = <String>[];
    final sub = switcher.changes.listen((p) => seen.add(p.id));
    addTearDown(() async {
      await sub.cancel();
      switcher.dispose();
    });
    switcher.start([bad, good], currentId: 'bad');
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    expect(seen, ['good'],
        reason: 'the dead incumbent must be abandoned on the first sweep');
    expect(switcher.best?.id, 'good');
  });

  test('tolerance margin: challenger must beat the incumbent by marginMs',
      () async {
    // No engine (urlProbe null) → results come straight from the store.
    final health = _seedHealth({
      'mid': (true, 250),
      'good': (true, 200),
    });
    final switcher = SmartSwitch(
      scheduler: TestScheduler(tester: LatencyTester(), store: health),
      health: health,
      interval: const Duration(seconds: 0), // no timer; manual evaluation
      marginMs: 100,
    );
    final cands = [_p('mid'), _p('good'), _p('bad')];
    final seen = <String>[];
    final sub = switcher.changes.listen((p) => seen.add(p.id));
    addTearDown(() async {
      await sub.cancel();
      switcher.dispose();
    });
    switcher.start(cands, currentId: 'mid');
    await Future<void>.delayed(Duration.zero);
    // 200 vs 250 = 50 ms better — inside the 100 ms tolerance → stay.
    expect(switcher.best?.id, 'mid');
    expect(seen, isEmpty);

    // Now the challenger is 150 ms better → migrate.
    health.record(HealthRecord(
        profileId: 'good', at: DateTime.now(), ok: true, latencyMs: 100));
    await Future<void>.delayed(const Duration(milliseconds: 450));
    expect(seen, ['good'], reason: '150ms > 100ms margin → switch');
  });

  test('a dead incumbent is always abandoned regardless of the margin',
      () async {
    final health = _seedHealth({
      'dead': (false, null),
      'good': (true, 400),
    });
    final switcher = SmartSwitch(
      scheduler: TestScheduler(tester: LatencyTester(), store: health),
      health: health,
      interval: const Duration(seconds: 0),
      marginMs: 5000, // absurd tolerance must not pin a dead node
    );
    final cands = [_p('dead'), _p('good')];
    final seen = <String>[];
    final sub = switcher.changes.listen((p) => seen.add(p.id));
    addTearDown(() async {
      await sub.cancel();
      switcher.dispose();
    });
    switcher.start(cands, currentId: 'dead');
    await Future<void>.delayed(const Duration(milliseconds: 450));
    expect(seen, ['good']);
  });

  test('re-seeding on reconfigure keeps the current pick (no rollback)',
      () async {
    final health = _seedHealth({'good': (true, 150)});
    final switcher = SmartSwitch(
      scheduler: TestScheduler(tester: LatencyTester(), store: health),
      health: health,
      interval: const Duration(seconds: 0),
      marginMs: 0,
    );
    final cands = [_p('mid'), _p('good')];
    final seen = <String>[];
    final sub = switcher.changes.listen((p) => seen.add(p.id));
    addTearDown(() async {
      await sub.cancel();
      switcher.dispose();
    });
    // mid is unusable (timeout) → the first start must migrate to good.
    switcher.start(cands, currentId: 'mid');
    await Future<void>.delayed(const Duration(milliseconds: 450));
    expect(switcher.best?.id, 'good');
    final changesAfterStart = seen.length;
    expect(changesAfterStart, 1, reason: 'exactly one recommendation so far');
    // good degrades to 300 ms but stays healthy; reconfigure (settings
    // edit) must NOT roll the pick back to the timeout 'mid' (which would
    // re-fire the change and bounce the tunnel).
    health.record(HealthRecord(
        profileId: 'good', at: DateTime.now(), ok: true, latencyMs: 300));
    switcher.reconfigure(cands, newInterval: const Duration(seconds: 5));
    await Future<void>.delayed(const Duration(milliseconds: 450));
    expect(switcher.best?.id, 'good', reason: 're-seed must keep the pick');
    expect(seen.length, changesAfterStart,
        reason: 're-seed is not a recommendation change — no re-fire');
  });
}
