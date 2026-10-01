import 'dart:async';
import 'dart:collection';
import '../../domain/entities/health.dart';
import '../../domain/entities/proxy_profile.dart';
import 'latency_tester.dart';

/// Job kinds with different priorities (§63: no single global timer).
enum TestJobKind { activeNodeMonitor, userRequested, backgroundSweep, recoveryCheck }

class TestJob implements Comparable<TestJob> {
  TestJob({required this.kind, required this.profileId, required this.runAt});

  final TestJobKind kind;
  final String profileId;
  final DateTime runAt;

  @override
  int compareTo(TestJob other) {
    final p = kind.priority.compareTo(other.kind.priority);
    if (p != 0) return p;
    return runAt.compareTo(other.runAt);
  }
}

extension _Prio on TestJobKind {
  int get priority => switch (this) {
        TestJobKind.activeNodeMonitor => 0,
        TestJobKind.userRequested => 1,
        TestJobKind.recoveryCheck => 2,
        TestJobKind.backgroundSweep => 3,
      };
}

/// Simple binary heap used by the scheduler.
class HeapPriorityQueue<E extends Comparable<E>> {
  final List<E> _a = [];

  bool get isNotEmpty => _a.isNotEmpty;
  bool get isEmpty => _a.isEmpty;

  void add(E e) {
    _a.add(e);
    var i = _a.length - 1;
    while (i > 0) {
      final parent = (i - 1) ~/ 2;
      if (_a[parent].compareTo(_a[i]) <= 0) break;
      final t = _a[parent];
      _a[parent] = _a[i];
      _a[i] = t;
      i = parent;
    }
  }

  E removeFirst() {
    final first = _a.first;
    final last = _a.removeLast();
    if (_a.isNotEmpty) {
      _a[0] = last;
      var i = 0;
      for (;;) {
        final l = 2 * i + 1, r = 2 * i + 2;
        var m = i;
        if (l < _a.length && _a[l].compareTo(_a[m]) < 0) m = l;
        if (r < _a.length && _a[r].compareTo(_a[m]) < 0) m = r;
        if (m == i) break;
        final t = _a[m];
        _a[m] = _a[i];
        _a[i] = t;
        i = m;
      }
    }
    return first;
  }
}

/// Aggregated health store with derived state, in-memory cache of the DB.
class HealthStore {
  final Map<String, NodeHealthStats> _stats = {};
  final Map<String, Queue<HealthRecord>> _recent = {};
  static const _window = 20;

  NodeHealthStats? statsOf(String profileId) => _stats[profileId];

  Map<String, NodeHealthStats> get all => Map.unmodifiable(_stats);

  void record(HealthRecord r) {
    final q = _recent.putIfAbsent(r.profileId, () => Queue());
    q.addLast(r);
    if (q.length > _window) q.removeFirst();
    final s = _stats.putIfAbsent(r.profileId, NodeHealthStats.new);
    s.lastChecked = r.at;
    s.sampleCount = s.sampleCount + 1;
    if (r.ok) {
      s
        ..consecutiveFailures = 0
        ..lastSuccess = r.at
        // v0.6.0 §tcping: lastLatencyMs is the REAL end-to-end (URL) stream
        // ONLY. The old `?? r.handshakeMs` fold leaked raw TCP-probe numbers
        // into the URL stream Smart Switch ranks on — a 50 ms Iran-internal
        // SYN-ACK could outrank a node whose tunnel actually moves traffic.
        ..lastLatencyMs = r.latencyMs;
      // v0.6.0 §tcping: a TCP-only record (latencyMs null, handshakeMs
      // set) feeds the DISPLAY column, not the URL latency stream.
      if (r.latencyMs == null && r.handshakeMs != null) {
        s.lastTcpMs = r.handshakeMs;
      }
      if (r.latencyMs != null) {
        s.avgLatencyMs = s.avgLatencyMs == null
            ? r.latencyMs
            : ((s.avgLatencyMs! * 0.7 + r.latencyMs! * 0.3).round());
      }
      s.state =
          (r.latencyMs ?? 0) > 900 ? NodeHealth.degraded : NodeHealth.healthy;
    } else {
      s.consecutiveFailures++;
      s.state = switch (r.errorKind) {
        'config' => NodeHealth.configError,
        'core' => NodeHealth.coreError,
        'blocked' => NodeHealth.blocked,
        _ => s.consecutiveFailures >= 3
            ? NodeHealth.offline
            : NodeHealth.timeout,
      };
    }
    final ok = q.where((x) => x.ok).length;
    s.successRate = q.isEmpty ? 0 : ok / q.length;
    final lats = q
        .where((x) => x.ok && x.latencyMs != null)
        .map((x) => x.latencyMs!)
        .toList();
    if (lats.length >= 2) {
      final recent = lats.length > 5 ? lats.sublist(lats.length - 5) : lats;
      final mean = recent.reduce((a, b) => a + b) / recent.length;
      final v =
          recent.map((x) => (x - mean) * (x - mean)).reduce((a, b) => a + b) /
              recent.length;
      s.jitterMs = v.round();
    }
  }

  void reset(String profileId) {
    _stats.remove(profileId);
    _recent.remove(profileId);
  }

  /// Drop every stat whose profileId is not in [keepIds].
  ///
  /// v0.5.6 §leak-fix: [reset] had NO caller anywhere in the app, so a node
  /// dropped by a subscription refresh kept its [NodeHealthStats] and its
  /// 20-entry [_recent] queue resident forever — both maps grew
  /// monotonically across refreshes. Subscriptions re-import different
  /// node id sets, so the stale entries accumulated in a long session.
  void retainOnly(Set<String> keepIds) {
    if (_stats.isEmpty && _recent.isEmpty) return;
    _stats.removeWhere((id, _) => !keepIds.contains(id));
    _recent.removeWhere((id, _) => !keepIds.contains(id));
  }
}

/// Prioritized test scheduler. Active node is always tested first; background
/// sweeps run with bounded concurrency and yield to higher-priority work.
class TestScheduler {
  TestScheduler({required this.tester, required this.store, this.concurrency = 6});

  final LatencyTester tester;
  final HealthStore store;
  final int concurrency;

  final _queue = HeapPriorityQueue<TestJob>();
  final _inFlight = <String>{};
  final _controller = StreamController<HealthRecord>.broadcast();
  Timer? _activeMonitorTimer;
  bool _running = false;

  Stream<HealthRecord> get results => _controller.stream;

  String testUrl = 'https://www.gstatic.com/generate_204';
  Duration timeout = const Duration(seconds: 5);
  Duration activeInterval = const Duration(seconds: 30);
  int failureThreshold = 2;
  int recoveryThreshold = 1;

  String? _activeProfileId;
  final _profiles = <String, ProxyProfile>{};

  void updateProfiles(Iterable<ProxyProfile> profiles) {
    _profiles
      ..clear()
      ..addEntries(profiles.map((p) => MapEntry(p.id, p)));
  }

  void setActive(String? profileId) {
    _activeProfileId = profileId;
    _restartActiveMonitor();
  }

  void enqueue(TestJobKind kind, String profileId,
      {Duration delay = Duration.zero}) {
    _queue.add(TestJob(
        kind: kind, profileId: profileId, runAt: DateTime.now().add(delay)));
    _pump();
  }

  void enqueueSweep({TestJobKind kind = TestJobKind.backgroundSweep}) {
    for (final id in _profiles.keys) {
      enqueue(kind, id);
    }
  }

  void start() {
    _running = true;
    _restartActiveMonitor();
    _pump();
  }

  void stop() {
    _running = false;
    _activeMonitorTimer?.cancel();
  }

  void dispose() {
    stop();
    _controller.close();
  }

  void _restartActiveMonitor() {
    _activeMonitorTimer?.cancel();
    if (_activeProfileId == null) return;
    _activeMonitorTimer = Timer.periodic(activeInterval, (_) {
      if (_activeProfileId != null) {
        enqueue(TestJobKind.activeNodeMonitor, _activeProfileId!);
      }
    });
  }

  void _pump() {
    if (!_running) return;
    while (_inFlight.length < concurrency && _queue.isNotEmpty) {
      final job = _queue.removeFirst();
      if (_inFlight.contains(job.profileId)) continue;
      _inFlight.add(job.profileId);
      _run(job).whenComplete(() {
        _inFlight.remove(job.profileId);
        _pump();
      });
    }
  }

  Future<void> _run(TestJob job) async {
    final p = _profiles[job.profileId];
    if (p == null) return;
    final r = await _probe(p);
    final rec = HealthRecord(
      profileId: p.id,
      at: DateTime.now(),
      ok: r.ok,
      // v0.6.0 §tcping: stop folding handshakeMs into latencyMs — the raw
      // TCP probe is a DISPLAY number (lastTcpMs), never a URL latency.
      latencyMs: r.latencyMs,
      errorKind: r.errorKind,
      handshakeMs: r.handshakeMs,
    );
    store.record(rec);
    _controller.add(rec);
  }

  Future<ProbeResult> _probe(ProxyProfile p) =>
      tester.testTcp(p.server, p.port, timeout: timeout);

  /// End-to-end probe through the running proxy (used by failover).
  Future<ProbeResult> probeViaProxy({
    required String proxyHost,
    required int proxyPort,
    String? url,
  }) =>
      tester.testHttpViaSocksProxy(proxyHost, proxyPort, url ?? testUrl,
          timeout: timeout);
}
