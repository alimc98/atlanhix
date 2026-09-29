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

void main() {
  test('batch probe: every result lands in the shared HealthStore', () async {
    final health = HealthStore();
    final switcher = SmartSwitch(
      scheduler: TestScheduler(tester: LatencyTester(), store: health),
      health: health,
      interval: const Duration(seconds: 0), // connect-time sweep only
      urlBatchProbe: (batch, {onNode}) async => {
        for (final p in batch)
          p.id: ProbeResult(ok: true, latencyMs: p.id == 'fast' ? 100 : 800),
      },
    );
    switcher.start([_p('slow'), _p('fast')], currentId: 'slow');
    await Future<void>.delayed(const Duration(milliseconds: 450));
    // Both nodes were measured (UI latency column sees the same truth):
    expect(health.statsOf('slow')?.lastLatencyMs, 800);
    expect(health.statsOf('fast')?.lastLatencyMs, 100);
    // 700 ms margin → migrate from the slow incumbent to the fast one.
    expect(switcher.best?.id, 'fast');
  });

  test('batch probe: a timed-out node is NOT silently forgotten', () async {
    final health = HealthStore();
    final switcher = SmartSwitch(
      scheduler: TestScheduler(tester: LatencyTester(), store: health),
      health: health,
      interval: const Duration(seconds: 0),
      urlBatchProbe: (batch, {onNode}) async => {
        // The incumbent answers; the challenger times out.
        'inc': ProbeResult(ok: true, latencyMs: 200),
      }, // 'chal' missing from the map
    );
    switcher.start([_p('inc'), _p('chal')], currentId: 'inc');
    await Future<void>.delayed(const Duration(milliseconds: 450));
    expect(switcher.best?.id, 'inc',
        reason: 'an unmeasured challenger must not win the ladder');
  });

  test('batch provider wins over the legacy per-node urlProbe', () async {
    final health = HealthStore();
    var perNodeCalls = 0;
    final switcher = SmartSwitch(
      scheduler: TestScheduler(tester: LatencyTester(), store: health),
      health: health,
      interval: const Duration(seconds: 0),
      urlProbe: (p) async {
        perNodeCalls++;
        return ProbeResult(ok: true, latencyMs: 900);
      },
      urlBatchProbe: (batch, {onNode}) async =>
          {for (final p in batch) p.id: ProbeResult(ok: true, latencyMs: 120)},
    );
    switcher.start([_p('a'), _p('b')], currentId: 'a');
    await Future<void>.delayed(const Duration(milliseconds: 450));
    expect(perNodeCalls, 0, reason: 'the batch path replaces per-node probing');
    expect(switcher.best?.id, 'a',
        reason: 'no real measurement difference → incumbent stays');
  });
}
