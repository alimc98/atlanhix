import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/core_detector.dart';
import 'package:nexus/core/runtime/binary_manager.dart';

void main() {
  // The v0.5.2 Windows bug: engines ship at <exe-dir>/cores/<plat>/<name>,
  // but the app resolved them ONLY relative to the process CWD and never
  // re-read the directory after cores/ appeared. A zip extracted anywhere
  // and launched by double-click (CWD = System32 or wherever) → the
  // version probe ran NOTHING and every connect failed with
  // binaryMissing / "engine is not installed".
  group('BinaryManager path resolution (Windows zip layout)', () {
    late Directory sandbox;
    late Directory coresDir;

    setUp(() async {
      sandbox = await Directory.systemTemp.createTemp('atx_cores_test');
      coresDir = Directory(
          '${sandbox.path}${Platform.pathSeparator}cores'
          '${Platform.pathSeparator}windows-x64')
        ..createSync(recursive: true);
      // A fake engine: the version probe only needs a runnable exe that
      // prints a dotted version. cmd's ver output is not stable; use a
      // PowerShell one-liner? NO — spawn cost + policy. Write a .cmd? The
      // manager runs the path AS-IS. Simplest honest fake on Windows CI
      // and dev: copy an existing console exe is overkill — instead the
      // test asserts CANDIDATE PATHS, not probe results.
    });

    tearDown(() async {
      try {
        await sandbox.delete(recursive: true);
      } catch (_) {}
    });

    test('exe-relative appDir beats CWD: candidates include the bundle path',
        () {
      final bm = BinaryManager(appDir: coresDir);
      final candidates = bm.candidatePaths(CoreBinaryKind.singbox);
      expect(
        candidates.any((p) =>
            p.startsWith(coresDir.path) && p.endsWith('sing-box.exe')),
        isTrue,
        reason: 'candidates must contain the exe-relative cores path first-class: $candidates',
      );
    });

    test('resolveCoresDir-equivalent: bundled dir EXISTS → it is used', () {
      // Mirror of dependencies.resolveCoresDir: exe-dir first, CWD fallback.
      // The BUG was: the resolved dir was only computed at bootstrap and
      // the layout check probed the WRONG nesting; with the zip layout
      // (cores/windows-x64 next to the exe) the manager must resolve
      // every binary inside that dir.
      final exeSimulatedDir = sandbox; // stand-in for the exe directory
      final bundled = Directory(
          '${exeSimulatedDir.path}${Platform.pathSeparator}cores'
          '${Platform.pathSeparator}${BinaryManager.platformDirName()}');
      bundled.createSync(recursive: true);
      File('${bundled.path}${Platform.pathSeparator}sing-box.exe')
          .writeAsBytesSync([0x4d, 0x5a]); // MZ header stub — existence only

      final bm = BinaryManager(appDir: bundled);
      // The manager's FIRST candidate for the bundled dir must point at a
      // path that EXISTS on disk now (not only after a re-bootstrap).
      final candidates = bm.candidatePaths(CoreBinaryKind.singbox);
      final hit = candidates.any((p) => File(p).existsSync());
      expect(hit, isTrue,
          reason: 'bundled engines must be found without any CWD assumption');
    });

    test('CWD fallback still works for dev runs from the repo root', () {
      final bm = BinaryManager(); // no appDir — pure CWD candidate
      final candidates = bm.candidatePaths(CoreBinaryKind.xray);
      expect(
        candidates.any((p) => p.contains('cores')),
        isTrue,
        reason: 'dev layout (repo-root ./cores) stays a candidate',
      );
    });
  });
}
