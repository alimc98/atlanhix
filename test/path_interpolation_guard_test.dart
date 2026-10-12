import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// v0.6.11 §path-fix regression guard.
///
/// The Windows connect failure (`PathNotFoundException: Exists failed,
/// path = 'Directory: 'C:\Users\…\AppData\Roaming'/.nexus/runtime\singbox'
/// (errno 123)`) came from ONE line: `Directory('$baseDir/.nexus/runtime')`
/// interpolated a `Directory` OBJECT, whose `toString()` is
/// `Directory: '<path>'` — so every engine work dir on desktop resolved to a
/// syntactically invalid path and the tunnel died before it started.
///
/// Nothing type-checks this: Dart happily stringifies any object. So the
/// guard is textual — any `$identifier` inside `lib/**.dart` whose
/// identifier is declared as a `Directory`/`File` (or built from one) in the
/// same file MUST be followed by `.path`.
void main() {
  test('Directory/File variables are never interpolated without .path',
      () {
    final violations = <String>[];
    final libDir = Directory('lib');
    expect(libDir.existsSync(), isTrue,
        reason: 'test must run from the package root');

    final files = libDir
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));

    // Identifiers this file binds to a Directory/File value:
    //   final Directory workDir;      Directory? fallback;
    //   final d = Directory(...);     ({required Directory workDir})
    // The typed form must end at `)` + `;`/`,` so an initializer like
    // `final exeDir = File(p).parent.path;` (a STRING, not a File) is not
    // mis-declared.
    final declared = RegExp(
        r'(?:final\s+|late\s+|var\s+|const\s+|required\s+)*'
        r'(?:Directory|File)\s*\??\s+(\w+)'
        r'|'
        r'(?:final|late|var|const)\s+(\w+)\s*=\s*'
        r'(?:Directory|File)\s*\([^;]*\)\s*[;,]');

    // $name NOT followed by `.path` (and not by another identifier char, so
    // `$dirSuffix` does not trip on a declared `dir`).
    String? violationIn(String src, String name) {
      final m = RegExp(r'\$' + name + r'(?![\w.])').firstMatch(src);
      if (m == null) return null;
      final line =
          src.substring(0, m.start).split('\n').length.toString();
      return '\$$name at line $line';
    }

    for (final f in files) {
      // Full-line comments are stripped: docs legitimately *mention* the
      // anti-pattern (`// '$dir' stringifies to …`) without being code.
      final src = f
          .readAsStringSync()
          .replaceAll(RegExp(r'^\s*//.*$', multiLine: true), '');
      final names = <String>{};
      for (final m in declared.allMatches(src)) {
        final n = m.group(1) ?? m.group(2);
        if (n != null && n.isNotEmpty) names.add(n);
      }
      for (final n in names) {
        final hit = violationIn(src, n);
        if (hit != null) violations.add('${f.path}: $hit');
      }
    }

    expect(
      violations,
      isEmpty,
      reason: 'A Directory/File variable was interpolated into a path '
          'without .path. `Directory(\'\$x\')` stringifies to '
          '\'Directory: <path>\' and produces an unopenable path '
          '(Windows errno 123 / PathNotFoundException). '
          'Use \'\${x.path}\' instead. '
          'Violations:\n${violations.join('\n')}',
    );
  }, timeout: const Timeout(Duration(minutes: 2)));
}
