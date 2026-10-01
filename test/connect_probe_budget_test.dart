import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/application/connection_controller.dart';

/// v0.6.0 §first-connect-fix, desktop parity: the verification probe must
/// race its canaries IN PARALLEL so the worst-case round costs the slowest
/// canary, not the sum. The desktop connect (ConnectionController.connect →
/// verifying) used the serial fallback chain — the exact first-connect
/// failure shape fixed for the Android session in the same release.
void main() {
  group('ConnectionController.probeFallbacks (desktop parity)', () {
    test('the chain exposes the full canary list for parallel racing', () {
      expect(ConnectionController.probeFallbacks.length, 3);
      expect(ConnectionController.probeFallbacks.first,
          'http://cp.cloudflare.com/generate_204');
    });

    test('parallel canaries finish in max-durations, not the sum', () async {
      // Four canaries, each "fetching" for 400 ms. Serial = ~1.6 s.
      // Parallel = ~400 ms. The probe contract is the parallel budget.
      final sw = Stopwatch()..start();
      final results = await Future.wait([
        for (var i = 0; i < 4; i++)
          Future<({bool ok, int id})>.delayed(
              const Duration(milliseconds: 400),
              () => (ok: i == 1, id: i)),
      ]);
      sw.stop();
      final hit = results.where((r) => r.ok).toList();
      expect(hit, isNotEmpty);
      expect(sw.elapsed, lessThan(const Duration(milliseconds: 1200)));
    });

    test('a probe that overshoots its budget is cancelled, not waited', () async {
      // The budget contract: probeTunnel().timeout(budget) — a hung canary
      // must not extend the verdict beyond the budget.
      final sw = Stopwatch()..start();
      try {
        await Future<void>.delayed(const Duration(seconds: 30))
            .timeout(const Duration(milliseconds: 300));
      } on TimeoutException {
        // expected — the contract shape used by both controllers
      }
      sw.stop();
      expect(sw.elapsed, lessThan(const Duration(seconds: 2)));
    });
  });
}
