import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/application/in_app_updater.dart';
import 'package:nexus/application/update_checker.dart';

/// v0.6.3 §release-parity / §update-fix — the release-asset contract for
/// every platform, the archive downloader's extension handling, and the
/// Android installer's permission wall.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('release asset per platform (v0.6.3)', () {
    test('android picks the ABI split first, universal second, any apk last',
        () {
      final arm64 = UpdateChecker.assetForPlatform('android',
          archHint: 'linux_6.1 android arm64 armv8l');
      expect(arm64.candidates.first.suffix, '-arm64-v8a.apk');
      expect(arm64.candidates.first.prefix, 'atlanhix-');
      expect(arm64.candidates[1].suffix, '-universal.apk');
      expect(arm64.candidates.last.suffix, '.apk');
      expect(arm64.candidates.first.kind, UpdateAssetKind.apk);

      final v7a = UpdateChecker.assetForPlatform('android',
          archHint: 'android armv7l');
      expect(v7a.candidates.first.suffix, '-armeabi-v7a.apk');

      // Unknown ABI → the universal APK, never a random split.
      final unknown = UpdateChecker.assetForPlatform('android');
      expect(unknown.candidates.first.suffix, '-universal.apk');
      expect(unknown.candidates.length, 2,
          reason: 'universal first, then the any-apk fallback');
    });

    test('windows and linux get their bundle archives', () {
      final win = UpdateChecker.assetForPlatform('windows');
      expect(win.candidates.single.suffix, '-windows-x64.zip');
      expect(win.candidates.single.kind, UpdateAssetKind.windowsZip);

      final lin = UpdateChecker.assetForPlatform('linux');
      expect(lin.candidates.single.suffix, '-linux-x64.tar.gz');
      expect(lin.candidates.single.kind, UpdateAssetKind.linuxTarGz);
    });

    test('platforms without a published asset fall back to the release page',
        () {
      expect(UpdateChecker.assetForPlatform('macos').candidates, isEmpty);
      expect(UpdateChecker.assetForPlatform('web').candidates, isEmpty);
    });
  });

  group('desktop archive downloader (v0.6.3)', () {
    test('the saved name carries the RELEASE extension (not a hardcoded zip)',
        () {
      expect(
        DesktopUpdateDownloader.archiveFileName('9.9.9+1', '.tar.gz'),
        'atlanhix-update-9.9.9_1.tar.gz',
        reason: 'Linux bundles are tar.gz — a zip-named tarball would fail '
            'the user\'s unpack step',
      );
      expect(
        DesktopUpdateDownloader.archiveFileName('v1.0.0', '.zip'),
        'atlanhix-update-v1.0.0.zip',
      );
    });

    test('a refused URL returns null and never throws', () async {
      final dl = DesktopUpdateDownloader();
      final path = await dl.downloadArchive(
        url: 'http://127.0.0.1:1/nope.zip',
        version: '1.0.0',
      );
      expect(path, isNull);
    });

    test('the target folder is a real writable directory on every OS', () {
      // Contract the private _downloadsDir() must satisfy: Downloads when it
      // exists (Windows %USERPROFILE%, Linux/macOS $HOME), temp otherwise.
      final env = Platform.environment;
      final home =
          Platform.isWindows ? env['USERPROFILE'] : env['HOME'];
      final downloads = home == null
          ? null
          : Directory('$home${Platform.pathSeparator}Downloads');
      final d = (downloads != null && downloads.existsSync())
          ? downloads
          : Directory.systemTemp;
      expect(d.existsSync(), isTrue);
      final probe = File('${d.path}${Platform.pathSeparator}'
          'atx_probe_${DateTime.now().millisecondsSinceEpoch}');
      probe.writeAsStringSync('x');
      probe.deleteSync();
    });
  });

  group('Android in-app install outcomes (v0.6.3)', () {
    void setMock(List<Object?> calls, Map<String, Object> Function(String m) reply) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('dev.atlanhix/updater'), (call) async {
        calls.add(call.method);
        return jsonEncode(reply(call.method));
      });
    }

    test('the "install unknown apps" wall maps to needsPermission', () async {
      final calls = <Object?>[];
      setMock(calls, (m) => m == 'install'
          ? {'ok': false, 'error': 'unknown_sources', 'openedSettings': true}
          : {'ok': false});
      final u = InAppUpdater();
      expect(await u.install(version: '0.6.3+19'),
          InstallOutcome.needsPermission,
          reason: 'granting this is the user\'s one-time tap — the dialog '
              'must offer Install again instead of a dead error');
    });

    test('a launched installer maps to launched; anything else to failed',
        () async {
      final calls = <Object?>[];
      setMock(calls, (m) => {'ok': true});
      expect(await InAppUpdater().install(version: '1.0.0'),
          InstallOutcome.launched);

      setMock(calls, (m) => {'ok': false, 'error': 'provider: nope'});
      expect(await InAppUpdater().install(version: '1.0.0'),
          InstallOutcome.failed);
    });

    test('download accepts the job and cancel reports its id', () async {
      final calls = <Object?>[];
      setMock(calls, (m) => m == 'download'
          ? {'ok': true, 'downloadId': 77}
          : {'ok': true});
      final u = InAppUpdater();
      expect(await u.download(url: 'https://example.com/a.apk', version: '1.0.0'),
          isTrue);
      expect(u.downloadId, 77);
      await u.cancel();
      expect(calls, containsAllInOrder(['download', 'cancel']));
    });
  });
}
