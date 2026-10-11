import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

/// JSON-file storage engine with schema versioning and forward-only
/// migrations (§58, §65).
///
/// Engineering note: this keeps the first release free of native SQLite
/// dependencies on all three platforms while providing durability (atomic
/// writes), versioning and migrations. The repository interfaces in this
/// package are storage-agnostic, so a Drift/SQLite backend can replace
/// JsonStore without touching the application layer (documented in
/// docs/ARCHITECTURE.md §9).
class JsonStore {
  JsonStore({required this.directory, this.schemaVersion = 1});

  final Directory directory;
  final int schemaVersion;

  Map<String, dynamic> _data = {};
  final _controller = StreamController<String>.broadcast();
  bool _loaded = false;
  Timer? _flushTimer;
  bool _pendingFlush = false;
  Future<void>? _flushWorker;

  static const _fileName = 'nexus_store.json';

  File get _file => File('${directory.path}${Platform.pathSeparator}$_fileName');

  Stream<String> get changes => _controller.stream;

  Future<void> load() async {
    if (_loaded) return;
    await directory.create(recursive: true);
    if (await _file.exists()) {
      try {
        final text = await _file.readAsString();
        final doc = jsonDecode(text) as Map<String, dynamic>;
        final version = (doc['schemaVersion'] ?? 1) as int;
        var payload =
            (doc['data'] ?? const <String, dynamic>{}) as Map<String, dynamic>;
        if (version < schemaVersion) {
          payload = _migrate(payload, version, schemaVersion);
        }
        _data = payload;
      } on FormatException catch (_) {
        // Corrupt store: keep a backup next to it and start clean — never
        // crash the app on malformed local data (§66).
        final backup = File('${_file.path}.corrupt');
        if (await backup.exists()) await backup.delete();
        await _file.copy(backup.path);
        _data = {};
      }
    } else {
      _data = {};
    }
    _loaded = true;
  }

  /// Forward-only migrations. v1 is the initial schema.
  Map<String, dynamic> _migrate(
      Map<String, dynamic> data, int from, int to) {
    var d = data;
    for (var v = from; v < to; v++) {
      switch (v) {
        // case 1: d = _migrateV1ToV2(d);
        default:
          break;
      }
    }
    return d;
  }

  Map<String, dynamic> section(String key) =>
      (_data[key] as Map<String, dynamic>?) ?? <String, dynamic>{};

  Future<void> putSection(String key, Map<String, dynamic> value) async {
    _data[key] = value;
    _scheduleFlush();
    _controller.add(key);
  }

  void _scheduleFlush() {
    // Debounced atomic write: coalesce bursts (e.g. health updates).
    _flushTimer?.cancel();
    _flushTimer = Timer(const Duration(milliseconds: 400), () {
      unawaited(flush());
    });
  }

  /// Durable once this completes: at least one full write that started after
  /// the call has landed. Concurrent callers coalesce into the SAME worker
  /// loop — the loop re-runs while anything is still pending, so every
  /// caller's data is covered by a write that began after its request.
  Future<void> flush() {
    _flushTimer?.cancel();
    _pendingFlush = true;
    return _flushWorker ??= _flushLoop();
  }

  Future<void> _flushLoop() async {
    try {
      while (_pendingFlush) {
        _pendingFlush = false;
        await _writeSnapshot();
      }
    } finally {
      _flushWorker = null;
    }
  }

  Future<void> _writeSnapshot() async {
    await directory.create(recursive: true);
    // v0.6.9 §hang-fix ("بعضی وقتا هنگ می‌کنه و not responding میاد"): the
    // whole store — every profile of every subscription, easily megabytes —
    // was pretty-printed AND fsync'd HERE, on the UI isolate, on every write
    // burst. While connected the usage fold writes every 2 s, so the window
    // froze for hundreds of ms on a cadence (the desktop "Not responding"
    // dialog). The snapshot below is copied to a worker isolate by
    // [Isolate.run] (fast native object copy, no JSON cost on this thread);
    // the encode + write + fsync + rename all happen OFF the UI isolate.
    final doc = <String, dynamic>{
      'schemaVersion': schemaVersion,
      'savedAt': DateTime.now().toIso8601String(),
      'data': _data,
    };
    final path = _file.path;
    await Isolate.run(() {
      final tmp = File('$path.tmp');
      tmp.writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert(doc),
        flush: true,
      );
      final file = File(path);
      if (file.existsSync()) file.deleteSync();
      tmp.renameSync(path);
    });
  }
}
