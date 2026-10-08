import 'dart:async';
import 'dart:convert';
import 'dart:io';

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

  Future<void> flush() async {
    _flushTimer?.cancel();
    await directory.create(recursive: true);
    final tmp = File('${_file.path}.tmp');
    await tmp.writeAsString(
      const JsonEncoder.withIndent('  ').convert({
        'schemaVersion': schemaVersion,
        'savedAt': DateTime.now().toIso8601String(),
        'data': _data,
      }),
      flush: true,
    );
    if (await _file.exists()) {
      await _file.delete();
    }
    await tmp.rename(_file.path);
  }
}
