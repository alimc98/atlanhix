import 'dart:async';
import 'dart:math' as math;

import '../core/logger.dart';

/// v0.5.2 §user — PER-NODE USAGE (upload + download under each node).
///
/// The engine exposes only GLOBAL counters (the native `state` poll mirrors
/// libbox writeStatus; desktop reads the Clash API /connections totals).
/// A per-node attribution is derived honestly by DELTA ACCOUNTING:
///
///   * when the tunnel CONNECTS on node X, the service opens a session
///     bucket (up0/down0 = the global counters at that instant);
///   * every poll folds (global − up0) into node X's lifetime totals;
///   * a hot MIGRATION closes the current bucket and opens a new one —
///     so every byte is attributed to exactly one node per second in use.
///
/// Not wire-exact (a switch boundary blends ≤1 s of traffic), but honest:
/// the number shown under a node is what really flowed while IT was the
/// active node, not a guess.
class NodeUsage {
  NodeUsage(this._load, this._save);

  /// Persists the totals map (store section `nodeUsage`).
  final Future<Map<String, ({int up, int down})>?> Function() _load;
  final Future<void> Function(Map<String, ({int up, int down})>) _save;

  final Map<String, ({int up, int down})> _totals = {};
  String? _activeNodeId;
  int _up0 = 0;
  int _down0 = 0;
  bool _armed = false;
  Timer? _flush;

  /// Fold one engine counter poll. Call at the watcher's cadence (1–2 s);
  /// counters may RESTART on engine reboot — a shrinking counter closes
  /// the bucket and re-baselines without negative spikes.
  void fold(String? nodeId, int globalUp, int globalDown) {
    if (nodeId == null) return;
    if (!_armed || _activeNodeId != nodeId) {
      // New session bucket (first fold after connect/migration/restart).
      _activeNodeId = nodeId;
      _up0 = globalUp;
      _down0 = globalDown;
      _armed = true;
      return;
    }
    final dUp = math.max(0, globalUp - _up0);
    final dDown = math.max(0, globalDown - _down0);
    _up0 = globalUp;
    _down0 = globalDown;
    if (dUp == 0 && dDown == 0) return;
    final t = _totals[nodeId] ?? (up: 0, down: 0);
    _totals[nodeId] = (up: t.up + dUp, down: t.down + dDown);
    _scheduleFlush();
  }

  /// Live totals for a node (never null — missing = zeros).
  ({int up, int down}) of(String nodeId) =>
      _totals[nodeId] ?? (up: 0, down: 0);

  /// Boot restore — called once from bootstrap.
  Future<void> restore() async {
    try {
      final saved = await _load();
      if (saved != null) _totals.addAll(saved);
    } catch (_) {
      // A corrupt section is not worth a broken boot.
    }
  }

  void _scheduleFlush() {
    _flush ??= Timer(const Duration(seconds: 5), () async {
      _flush = null;
      try {
        await _save(Map.of(_totals));
      } catch (_) {
        Logger.instance.warn('node-usage', 'persist failed');
      }
    });
  }

  void dispose() {
    _flush?.cancel();
  }
}

/// Formats bytes the way the usage tile does (KB/MB/GB).
String fmtBytes(int b) {
  if (b >= 1 << 30) return '${(b / (1 << 30)).toStringAsFixed(2)} GB';
  if (b >= 1 << 20) return '${(b / (1 << 20)).toStringAsFixed(1)} MB';
  if (b >= 1 << 10) return '${(b / (1 << 10)).toStringAsFixed(0)} KB';
  return '$b B';
}
