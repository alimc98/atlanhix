import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/data/app_storage.dart';

/// v0.6.9 §hang-fix pins for the store's flush path.
///
/// The old flush pretty-printed AND fsync-rewrote the WHOLE store (every
/// profile — megabytes) on the UI isolate per write burst, and two flushes
/// could overlap, racing on the same `.tmp` file. The rewrite moved the
/// encode + write + rename into a worker isolate ([Isolate.run]) and made
/// concurrent flush() calls coalesce into one non-overlapping worker loop.
void main() {
  File storeFile(Directory dir) =>
      File('${dir.path}${Platform.pathSeparator}nexus_store.json');

  test('concurrent flush() calls coalesce and every caller\'s data lands',
      () async {
    final dir = await Directory.systemTemp.createTemp('nexus_store_flush');
    addTearDown(() => dir.delete(recursive: true));
    final store = JsonStore(directory: dir, schemaVersion: 1);
    await store.load();

    // The write-burst shape the app produces constantly (usage fold, health
    // records, settings toggles) — with flush() racing from several callers.
    await Future.wait([
      for (var i = 0; i < 20; i++) store.putSection('s$i', {'v': i}),
      store.flush(),
      store.flush(),
      store.flush(),
    ]);
    await store.flush();

    final doc =
        jsonDecode(await storeFile(dir).readAsString()) as Map<String, dynamic>;
    expect(doc['schemaVersion'], 1);
    final data = doc['data'] as Map<String, dynamic>;
    for (var i = 0; i < 20; i++) {
      expect((data['s$i'] as Map)['v'], i,
          reason: 'every section written before/while flushing must be '
              'durable once flush() resolves');
    }
    expect(File('${storeFile(dir).path}.tmp').existsSync(), isFalse,
        reason: 'the atomic write must leave no .tmp behind');
  });

  test('a putSection storm keeps the file valid and complete', () async {
    final dir = await Directory.systemTemp.createTemp('nexus_store_storm');
    addTearDown(() => dir.delete(recursive: true));
    final store = JsonStore(directory: dir);
    await store.load();

    // 50 rapid writes without awaiting between them — the debounce must
    // coalesce them and the final flush must carry the LAST value.
    for (var i = 0; i < 50; i++) {
      // ignore: unawaited_futures
      store.putSection('hot', {'n': i});
    }
    await store.flush();

    final doc =
        jsonDecode(await storeFile(dir).readAsString()) as Map<String, dynamic>;
    final hot = (doc['data'] as Map)['hot'] as Map;
    expect(hot['n'], 49, reason: 'the coalesced write carries the latest '
        'state, not an early snapshot');
  });

  test('load() after a flush round-trips every section', () async {
    final dir = await Directory.systemTemp.createTemp('nexus_store_reload');
    addTearDown(() => dir.delete(recursive: true));
    final store = JsonStore(directory: dir);
    await store.load();
    await store.putSection('profiles', {
      'p1': {'id': 'p1', 'name': 'Node'}
    });
    await store.flush();

    final fresh = JsonStore(directory: dir);
    await fresh.load();
    final p = (fresh.section('profiles')['p1'] as Map);
    expect(p['name'], 'Node');
  });
}
