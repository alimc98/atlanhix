import 'dart:async';

import 'fragment_profiles.dart';
import '../../data/app_storage.dart';

/// The freshness window of the per-subscription rung stats: probes older
/// than this age out of the win-rate aggregation (network conditions, CDN
/// fronting and DPI behavior drift over time — a 6-month-old 100% rate is
/// marketing, not evidence).
const Duration fragmentStatWindow = Duration(days: 30);

/// Hard cap on stored probe events per rung (bounded store growth; the
/// aggregation keeps the newest events first).
const int fragmentStatMaxEvents = 500;

/// v0.4.6 §user — persists the WINNING rung of the fragment AUTO ladder per
/// node id, so the next connect to the same node starts from the level that
/// already worked (no re-climbing from conservative on every connect).
///
/// v0.4.6 §user-2 — also persists a SUBSCRIPTION-LEVEL suggestion: the
/// latest proven rung of any node in a subscription seeds the starting rung
/// for the subscription's OTHER nodes (nodes of one subscription usually
/// share the same CDN/DPI shape). A per-node winner always wins over the
/// subscription suggestion; both are just FIRST attempts — the ladder still
/// wraps through every remaining rung on failure.
///
/// v0.4.6 §user-3 — also aggregates per-subscription ATTEMPT/WIN counts per
/// rung, so the UI can show WHICH fragment mode actually works best for a
/// subscription. Every real probe of a rung is an attempt; only probes that
/// pass are wins — failed rungs inside the climb are counted too, otherwise
/// every rung would show a dishonest 100% rate.
///
/// Storage: dedicated [JsonStore] sections
///   `fragmentLadder`            → profileId → winning FragmentPresets id
///   `fragmentLadderSuggestions` → subscriptionId → suggested preset id
///   `fragmentLadderStats`       → subscriptionId → rungId → [attempts, wins]
/// (`conservative` / `default` / `aggressive`). Structure, never identity:
/// keys are internal ids, values are enum ids / counters — no host or
/// credential is ever stored.
class FragmentLadderCache {
  FragmentLadderCache(this._store);

  final JsonStore _store;
  Map<String, String>? _cache;
  Map<String, String>? _suggestions;
  Map<String, Map<String, List<List<int>>>>? _stats;

  static const _section = 'fragmentLadder';
  static const _suggestionsSection = 'fragmentLadderSuggestions';
  static const _statsSection = 'fragmentLadderStats';

  /// Rung ids this cache accepts, in strength order (ties in [bestRungFor]
  /// resolve to the SAFER rung).
  static const _rungIds = ['conservative', 'default', 'aggressive'];

  Map<String, String> get _map {
    final c = _cache;
    if (c != null) return c;
    _cache = _store
        .section(_section)
        .map((k, v) => MapEntry(k, v.toString()));
    return _cache!;
  }

  Map<String, String> get _sugMap {
    final c = _suggestions;
    if (c != null) return c;
    _suggestions = _store
        .section(_suggestionsSection)
        .map((k, v) => MapEntry(k, v.toString()));
    return _suggestions!;
  }

  /// subId → rungId → probe events `[epochMillis, won(0|1)]`, newest kept
  /// last; defensive parse — corrupt or partial entries are skipped, never
  /// thrown.
  Map<String, Map<String, List<List<int>>>> get _statMap {
    final c = _stats;
    if (c != null) return c;
    final out = <String, Map<String, List<List<int>>>>{};
    _store.section(_statsSection).forEach((subId, rungs) {
      if (rungs is! Map) return;
      final bucket = <String, List<List<int>>>{};
      rungs.forEach((rungId, events) {
        if (events is! List) return;
        final parsed = <List<int>>[];
        for (final e in events) {
          if (e is List &&
              e.length == 2 &&
              e[0] is int &&
              e[1] is int) {
            parsed.add([e[0] as int, e[1] as int]);
          }
        }
        if (parsed.isNotEmpty) bucket[rungId.toString()] = parsed;
      });
      if (bucket.isNotEmpty) out[subId] = bucket;
    });
    _stats = out;
    return _stats!;
  }

  /// The persisted winning rung for [profileId], or null when the node has
  /// never climbed (or a later app upgrade changed the id vocabulary).
  FragmentProfile? winnerFor(String profileId) {
    final id = _map[profileId];
    return FragmentPresets.byId(id);
  }

  /// The suggested STARTING rung for nodes of [subscriptionId] — the latest
  /// proven rung of any sibling node. Null when the subscription has never
  /// produced a winner (or the id is null / outside the vocabulary).
  FragmentProfile? suggestionFor(String? subscriptionId) {
    if (subscriptionId == null || subscriptionId.isEmpty) return null;
    final id = _sugMap[subscriptionId];
    return FragmentPresets.byId(id);
  }

  /// Record [profile] as the winning rung for [profileId] (fire-and-forget:
  /// JsonStore coalesces and flushes atomically). Only real preset ids are
  /// stored — a profile whose id is not in the vocabulary is ignored.
  Future<void> recordWinner(String profileId, FragmentProfile profile) async {
    if (FragmentPresets.byId(profile.id) == null) return;
    _map[profileId] = profile.id;
    await _store.putSection(
        _section, Map<String, dynamic>.of(_map.cast<String, dynamic>()));
  }

  /// Promote [profile] to the suggested starting rung for every node of
  /// [subscriptionId]. Callers pass the CONNECTED profile's subscriptionId —
  /// null (manual/imported nodes) is a no-op so manual nodes never leak a
  /// suggestion into subscription groups. The latest proven rung replaces
  /// any previous one: freshest evidence wins.
  Future<void> recordSuggestion(
      String? subscriptionId, FragmentProfile profile) async {
    if (subscriptionId == null || subscriptionId.isEmpty) return;
    if (FragmentPresets.byId(profile.id) == null) return;
    _sugMap[subscriptionId] = profile.id;
    await _store.putSection(_suggestionsSection,
        Map<String, dynamic>.of(_sugMap.cast<String, dynamic>()));
  }

  /// v0.4.6 §user-3: record one REAL probe of [rung] for [subscriptionId] —
  /// [won] true only when the tunnel probe through that rung passed. Failed
  /// rungs inside the climb are attempts too (honest win rates). Events are
  /// timestamped (JSON store section `fragmentLadderStats`); the aggregation
  /// in [statsFor]/[bestRungFor] only counts events inside the 30-day
  /// [fragmentStatWindow], so stale evidence ages out automatically. Null
  /// or empty subscription ids and non-vocabulary rungs are no-ops.
  Future<void> recordRungAttempt(
      String? subscriptionId, FragmentProfile rung,
      {required bool won}) async {
    if (subscriptionId == null || subscriptionId.isEmpty) return;
    if (FragmentPresets.byId(rung.id) == null) return;
    final sub = _statMap.putIfAbsent(subscriptionId, () => {});
    final events = sub.putIfAbsent(rung.id, () => []);
    events.add([
      DateTime.now().millisecondsSinceEpoch,
      won ? 1 : 0,
    ]);
    if (events.length > fragmentStatMaxEvents) {
      events.removeRange(0, events.length - fragmentStatMaxEvents);
    }
    await _persistStats();
  }

  Future<void> _persistStats() async {
    unawaited(_store.putSection(_statsSection, {
      for (final e in _statMap.entries)
        e.key: {
          for (final r in e.value.entries) r.key: [for (final ev in r.value) List<int>.of(ev)],
        },
    }));
  }

  /// Per-rung [attempts, wins] for [subscriptionId], aggregated over probe
  /// events INSIDE the freshness window ([fragmentStatWindow]); older events
  /// age out automatically. Empty when nothing recent (or the id is
  /// null/empty).
  Map<String, List<int>> statsFor(String? subscriptionId) {
    if (subscriptionId == null || subscriptionId.isEmpty) return const {};
    final sub = _statMap[subscriptionId];
    if (sub == null) return const {};
    final cutoff =
        DateTime.now().millisecondsSinceEpoch - fragmentStatWindow.inMilliseconds;
    final out = <String, List<int>>{};
    sub.forEach((rungId, events) {
      var attempts = 0;
      var wins = 0;
      for (final e in events) {
        if (e[0] >= cutoff) {
          attempts++;
          if (e[1] == 1) wins++;
        }
      }
      if (attempts > 0) out[rungId] = [attempts, wins];
    });
    return Map.unmodifiable(out);
  }

  /// The rung with the best win rate for [subscriptionId] (inside the
  /// freshness window) — requires at least one win; ties resolve to the
  /// SAFER rung. Null when no rung has won recently.
  FragmentProfile? bestRungFor(String? subscriptionId) {
    final stats = statsFor(subscriptionId);
    if (stats.isEmpty) return null;
    FragmentProfile? best;
    var bestRate = 0.0;
    for (final id in _rungIds) {
      final pair = stats[id];
      if (pair == null || pair[1] == 0) continue;
      final rate = pair[1] / pair[0];
      if (best == null || rate > bestRate) {
        best = FragmentPresets.byId(id);
        bestRate = rate;
      }
    }
    return best;
  }

  /// v0.4.6 §user-3: manual reset from the subscriptions screen — forgets
  /// the rung stats of THIS subscription only (winners/suggestions are
  /// identity mappings, not observations; they stay). Null/empty id is a
  /// no-op.
  Future<void> resetStatsFor(String? subscriptionId) async {
    if (subscriptionId == null || subscriptionId.isEmpty) return;
    if (!_statMap.containsKey(subscriptionId)) return;
    _statMap.remove(subscriptionId);
    await _persistStats();
  }

  /// Test/debug hook: forget everything.
  Future<void> clear() async {
    _map.clear();
    _sugMap.clear();
    _statMap.clear();
    await _store.putSection(_section, const {});
    await _store.putSection(_suggestionsSection, const {});
    await _store.putSection(_statsSection, const {});
  }
}
