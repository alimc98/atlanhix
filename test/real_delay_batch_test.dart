import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/application/real_delay_tester.dart';
import 'package:nexus/core/health/latency_tester.dart';
import 'package:nexus/domain/entities/proxy_profile.dart';

/// v0.4.9 §user — the batch API behind "test all nodes works with no
/// connection": live-engine results win when the engine is up; otherwise
/// the transient batch provider measures; otherwise honest engine-off.
ProxyProfile _p(String id) => ProxyProfile(
      id: id,
      name: 'n-$id',
      server: '203.0.113.1',
      port: 443,
      protocol: ProxyProtocol.vless,
    );

void main() {
  test('live engine up → per-node real measurements', () async {
    final t = RealDelayTester(tester: LatencyTester())
      ..engineDelayTest = (p) async =>
          ProbeResult(ok: true, latencyMs: 111);
    final out = await t.testBatch([_p('a'), _p('b')]);
    expect(out['a']!.ok, isTrue);
    expect(out['a']!.latencyMs, 111);
    expect(out['b']!.latencyMs, 111);
  });

  test('live engine OFF → transient batch provider measures', () async {
    // NOTE: block bodies — `=> null` followed by a cascade line parses the
    // cascade INTO the closure body (Dart grammar), which broke the build.
    final t = RealDelayTester(tester: LatencyTester())
      ..engineDelayTest = (p) async {
        return null; // engine off
      }
      ..transientBatchTest = (batch) async => {
            for (final n in batch) n.id: ProbeResult(ok: true, latencyMs: 222)
          };
    final out = await t.testBatch([_p('a'), _p('b')]);
    expect(out['a']!.ok, isTrue);
    expect(out['a']!.latencyMs, 222);
    expect(out['b']!.latencyMs, 222);
  });

  test('no mechanism → honest engine-off for every node', () async {
    final t = RealDelayTester(tester: LatencyTester());
    final out = await t.testBatch([_p('a')]);
    expect(out['a']!.ok, isFalse);
    expect(out['a']!.errorKind, 'engine-off');
  });

  test('single test falls back to engine-off when nothing measures', () async {
    final t = RealDelayTester(tester: LatencyTester());
    final r = await t.test(_p('solo'));
    expect(r.errorKind, 'engine-off');
    expect(r.ok, isFalse);
  });

  test('empty batch → empty map', () async {
    final t = RealDelayTester(tester: LatencyTester());
    expect(await t.testBatch(const []), isEmpty);
  });
}
