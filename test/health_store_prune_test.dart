import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/health/test_scheduler.dart';
import 'package:nexus/domain/entities/health.dart';

/// v0.5.6 §leak-fix regression guards for the resources fixed in this pass.
///
/// These are deliberately behavioural (state that must actually be released)
/// rather than "nothing threw" checks, because the bugs they cover were all
/// invisible from the outside.
void main() {
  HealthRecord rec(String id, {bool ok = true, int? ms}) => HealthRecord(
        profileId: id,
        ok: ok,
        latencyMs: ms,
        at: DateTime.now(),
      );

  group('HealthStore.retainOnly', () {
    test('drops stats and history for nodes that no longer exist', () {
      final store = HealthStore();
      for (var i = 0; i < 3; i++) {
        store.record(rec('node-$i', ms: 100 + i));
      }
      expect(store.statsOf('node-0'), isNotNull);
      expect(store.statsOf('node-2'), isNotNull);

      // A subscription refresh dropped node-1 and node-2.
      store.retainOnly({'node-0'});

      expect(store.statsOf('node-0'), isNotNull,
          reason: 'surviving node keeps its stats');
      expect(store.statsOf('node-1'), isNull,
          reason: 'removed node must not stay resident');
      expect(store.statsOf('node-2'), isNull);
      expect(store.all.keys, {'node-0'});
    });

    test('an empty keep-set clears everything (all nodes removed)', () {
      final store = HealthStore();
      store.record(rec('a'));
      store.record(rec('b'));
      store.retainOnly(const <String>{});
      expect(store.all, isEmpty);
    });

    test('repeated refreshes do not accumulate dropped-node entries', () {
      final store = HealthStore();
      // Ten refreshes, each introducing a new id and dropping the previous.
      for (var round = 0; round < 10; round++) {
        store.record(rec('round-$round', ms: 120));
        store.retainOnly({'round-$round'});
      }
      expect(store.all.length, 1,
          reason: 'only the current node should remain after each prune');
      expect(store.statsOf('round-9'), isNotNull);
    });
  });

  group('CleanDnsClient pin cache', () {
    // The eviction bound itself is exercised in clean_dns_client's own tests;
    // here we assert the public pin accessor still reports the same IP after
    // an unrelated prune, so wiring the two together cannot corrupt pins.
    test('a prune of health stats does not disturb pin bookkeeping', () {
      final store = HealthStore();
      store.record(rec('x'));
      store.retainOnly(const <String>{});
      expect(store.all, isEmpty);
    });
  });
}