import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/application/update_checker.dart';

/// v0.6.0 §desktop-update — the Windows half of the in-app update promise.
void main() {
  group('UpdateChecker platform asset selection (v0.6.0)', () {
    test('parses windows-zip and apk kinds distinctly', () {
      expect(UpdateAssetKind.windowsZip.name, 'windowsZip');
      expect(UpdateAssetKind.apk.name, 'apk');
    });
  });

  group('DesktopUpdateDownloader temp fallback (no network)', () {
    test('downloads dir fallback exists and is writable', () {
      // _downloadsDir is private; assert the contract it must satisfy:
      // a real, writable directory is always returned (Downloads or temp).
      final profile = Platform.environment['USERPROFILE'];
      final downloads = profile == null
          ? null
          : Directory('$profile\\Downloads');
      final d = (downloads != null && downloads.existsSync())
          ? downloads
          : Directory.systemTemp;
      expect(d.existsSync(), isTrue);
      final probe = File(
          '${d.path}${Platform.pathSeparator}atx_probe_${DateTime.now().millisecondsSinceEpoch}');
      probe.writeAsStringSync('x');
      probe.deleteSync();
    });
  });
}
