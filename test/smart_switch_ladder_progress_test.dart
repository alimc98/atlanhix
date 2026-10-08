
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/health/latency_tester.dart';
import 'package:nexus/core/health/test_scheduler.dart';
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

/// A switcher whose batch provider reports each landed measurement through
/// the SAME [SmartSwitch]s onNode channel the real engine path uses —
/// parallel completion order is the report order.
SmartSwitch _switcher({required Map<String, int> delays}) {
  final health = HealthStore();
  return SmartSwitch(
    scheduler: TestScheduler(tester: LatencyTester(), store: health),
    health: health,
    interval: const Duration(seconds: 0), // one announced sweep only
    urlBatchProbe: (batch, {onNode}) async {
      await Future.wait(batch.map((p) async {
        final ms = delays[p.id];
        await Future<void>.delayed(
            Duration(milliseconds: (ms ?? 5).clamp(1, 200)));
        onNode?.call(p, ms);
      }));
      return {
        for (final p in batch)
          p.id: ProbeResult(ok: delays[p.id] != null, latencyMs: delays[p.id]),
      };
    },
  );
}

void main() {
  test('ladder progress counts per landed node, finish closes the run',
      () async {
    final switcher = _switcher(delays: {
      'fast': 20,
      'mid': 60,
      'slow': 120,
    });
    final events = <LadderProgress>[];
    final sub = switcher.progress.listen(events.add);

    switcher.start([_p('slow'), _p('mid'), _p('fast')],
        currentId: 'slow'); // void — fire and forget
    await Future<void>.delayed(const Duration(milliseconds: 500));
    await sub.cancel();

    // start + 3 landed + finish
    expect(events.length, 5, reason: 'events: $events');
    expect(events.first.total, 3);
    expect(events.first.done, 0);
    expect(events.first.lastMs, isNull, reason: 'start has no last ms');
    expect(events.first.isFinish, isFalse);

    // Per-node events count up monotonically, 1-based, with the ms landed.
    final counted = events
        .where((e) => e.lastMs != null && !e.isFinish)
        .toList()
      ..sort((a, b) => a.done.compareTo(b.done));
    expect([for (final e in counted) e.done], [1, 2, 3]);
    expect([for (final e in counted) e.lastMs], [20, 60, 120]);
    expect(events.last.isFinish, isTrue);
    // The finish KEEPS the count (never resets to 0/n).
    expect(events.last.done, 3);
    expect(events.last.total, 3);
  });

  test('finish fires even when the batch provider throws (timeout path)',
      () async {
    final health = HealthStore();
    final switcher = SmartSwitch(
      scheduler: TestScheduler(tester: LatencyTester(), store: health),
      health: health,
      interval: const Duration(seconds: 0),
      urlBatchProbe: (batch, {onNode}) async =>
          throw StateError('engine exploded'),
    );
    final events = <LadderProgress>[];
    final sub = switcher.progress.listen(events.add);

    await switcher.initialSweep([_p('a'), _p('b')],
        maxWait: const Duration(milliseconds: 300));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await sub.cancel();

    expect(events.where((e) => e.isFinish).length, 1,
        reason:
            'a dead sweep must still close its progress: ${events.length} events');
    // The throw happened BEFORE any health.record — the ladder degrades to
    // the health-store pick (first candidate on a tie of unmeasured nodes),
    // never hangs on the 9 s cap.
    expect(switcher.best?.id, 'a');
  });

  test('initialSweep announces and closes exactly one run', () async {
    final switcher = _switcher(delays: {'a': 10, 'b': 20});
    final events = <LadderProgress>[];
    final sub = switcher.progress.listen(events.add);

    await switcher.initialSweep([_p('a'), _p('b')],
        maxWait: const Duration(milliseconds: 400));
    await Future<void>.delayed(const Duration(milliseconds: 60));
    await sub.cancel();

    expect(events.length, 4, reason: 'events: $events'); // start+2+finish
    expect(events.first.done, 0);
    expect(events.last.isFinish, isTrue);
    expect(switcher.best?.id, 'a', reason: 'the faster node wins the ladder');
  });

  test('ladderProgress snapshot resumes a remounted UI mid-run', () async {
    final switcher = _switcher(delays: {'a': 30, 'b': 90});
    switcher.start([_p('a'), _p('b')]);
    // Mid-run read: at least the start event is already published.
    await Future<void>.delayed(const Duration(milliseconds: 50));
    final snap = switcher.ladderProgress;
    expect(snap.total, 2);
    expect(snap.isFinish, isFalse);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(switcher.ladderProgress.isFinish, isTrue);
    expect(switcher.ladderProgress.done, 2);
  });

  test('stop() closes an open run (user disabled the switch mid-ladder)',
      () async {
    final switcher = _switcher(delays: {'a': 10, 'b': 10});
    final events = <LadderProgress>[];
    final sub = switcher.progress.listen(events.add);
    switcher.start([_p('a'), _p('b')]);
    switcher.stop(); // immediately — the sweep's own finish is a no-op after
    await Future<void>.delayed(const Duration(milliseconds: 150));
    await sub.cancel();
    expect(events.where((e) => e.isFinish).length, 1,
        reason: 'exactly one close for the run: ${events.length} events');
  });
}
