import 'dart:async';
import 'dart:convert' show jsonDecode;
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import '../core/logger.dart';

/// v0.6.0 §in-app-update — Dart side of the in-app updater.
///
/// The user asked for NO browser, NO manual GitHub step: pressing Download
/// must download INSIDE the app and then install. This service drives the
/// native `dev.atlanhix/updater` channel (Android): DownloadManager streams
/// the APK into the app sandbox while [onProgress] reports 0..100, and
/// [install] fires the one-tap system installer on the finished file.
/// Desktop keeps the old behavior (the caller falls back to opening the
/// release URL — Android is the platform the request targets).
class InAppUpdater {
  InAppUpdater();

  static const _channel = MethodChannel('dev.atlanhix/updater');

  int? downloadId;
  String? _version;
  Timer? _poll;

  /// 0..100 while a download is in flight, 100 on completion.
  void Function(int percent)? onProgress;
  void Function(String stage)? onStage; // 'downloading' | 'installing' | 'failed'

  /// Starts the in-app download. Returns true when the native side accepted.
  Future<bool> download({required String url, required String version}) async {
    _version = version;
    try {
      final r = await _channel.invokeMethod<String>(
          'download', {'url': url, 'version': version});
      final j = r == null ? <String, dynamic>{} : _decode(r);
      if (j['ok'] != true) {
        Logger.instance
            .warn('update', 'download refused: ${j['error'] ?? 'unknown'}');
        return false;
      }
      downloadId = (j['downloadId'] as num?)?.toInt();
      onStage?.call('downloading');
      _startPolling();
      return true;
    } on MissingPluginException {
      return false; // desktop — caller falls back to the old open-URL flow
    } catch (e) {
      Logger.instance.warn('update', 'download failed: $e');
      return false;
    }
  }

  void _startPolling() {
    _poll?.cancel();
    _poll = Timer.periodic(const Duration(milliseconds: 500), (_) async {
      final s = await status();
      if (s == null) return;
      final p = s['progress'];
      if (p is num) onProgress?.call(p.toInt().clamp(0, 100));
      switch (s['status']) {
        case 'done':
          _poll?.cancel();
          onProgress?.call(100);
          final outcome = await install(version: _version ?? '');
          onStage?.call(switch (outcome) {
            InstallOutcome.launched => 'installing',
            InstallOutcome.needsPermission => 'needsPermission',
            InstallOutcome.failed => 'failed',
          });
        case 'failed' || 'gone':
          _poll?.cancel();
          onStage?.call('failed');
      }
    });
  }

  /// v0.6.3 §update-fix: aborts a running DownloadManager download (the
  /// dialog's Cancel). A cancelled download must never be installed later.
  Future<void> cancel() async {
    _poll?.cancel();
    final id = downloadId;
    downloadId = null;
    if (id == null) return;
    try {
      await _channel.invokeMethod<String>('cancel', {'downloadId': id});
    } catch (_) {}
  }

  /// Native download status (null when the channel is unavailable).
  Future<Map<String, dynamic>?> status() async {
    if (downloadId == null) return null;
    try {
      final r = await _channel
          .invokeMethod<String>('status', {'downloadId': downloadId});
      return _decode(r!);
    } catch (_) {
      return null;
    }
  }

  /// Launches the system installer over the downloaded APK. Android shows
  /// its standard one-tap consent — there is no silent-install path for
  /// sideloaded APKs, and pretending otherwise would be dishonest.
  ///
  /// v0.6.3 §update-fix: the outcome is RICH now. Since Android 8 the
  /// package installer refuses an app that has not been granted "install
  /// unknown apps"; the old boolean collapsed that wall into a bare
  /// failure, so the update looked broken with no way forward. The native
  /// side opens the exact settings page and answers
  /// [InstallOutcome.needsPermission] — the dialog tells the user what to do
  /// and offers the Install button again.
  Future<InstallOutcome> install({required String version}) async {
    try {
      final r =
          await _channel.invokeMethod<String>('install', {'version': version});
      final j = _decode(r!);
      if (j['ok'] == true) return InstallOutcome.launched;
      final err = '${j['error'] ?? ''}';
      Logger.instance.warn('update', 'install refused: $err');
      if (err.startsWith('unknown_sources')) {
        return InstallOutcome.needsPermission;
      }
      return InstallOutcome.failed;
    } on MissingPluginException {
      return InstallOutcome.failed;
    } catch (e) {
      Logger.instance.warn('update', 'install failed: $e');
      return InstallOutcome.failed;
    }
  }

  Map<String, dynamic> _decode(String raw) =>
      Map<String, dynamic>.from(jsonDecode(raw) as Map);

  void dispose() => _poll?.cancel();
}

/// v0.6.3 §update-fix: what happened when the installer was fired.
enum InstallOutcome {
  /// The system package installer is on screen.
  launched,
  /// Android blocked the install: the "install unknown apps" page for this
  /// app was opened — the user grants it and taps Install again.
  needsPermission,
  failed,
}

/// v0.6.0 §desktop-update — Windows download flow, the desktop half of the
/// same "download inside the app" promise.
///  /// The release archive carries the app binaries AND its cores/ dir, so the
  /// upgrade path is: download into the user's Downloads folder (real HTTP
  /// stream with progress) → the file manager opens on the file → the user
  /// unpacks it over the previous install (or runs it from anywhere). A true
  /// silent self-replace needs a separate updater process with elevation;
  /// this is the honest one-tap version of it. Windows takes the .zip, Linux
  /// the .tar.gz — same code path, different extension (v0.6.3 §release-
  /// parity).
class DesktopUpdateDownloader {
  DesktopUpdateDownloader({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;
  bool _cancelled = false;

  void cancel() => _cancelled = true;

  /// Streams [url] into `<Downloads>/atlanhix-update-<version><extension>`.
  /// Returns the absolute file path, or null on failure/cancel.
  ///
  /// v0.6.3 §release-parity: [extension] is the release artifact's own
  /// extension — `.zip` for Windows bundles, `.tar.gz` for Linux ones — so
  /// the saved file is a real archive instead of a zip-named tarball.
  Future<String?> downloadArchive({
    required String url,
    required String version,
    String extension = '.zip',
    void Function(int percent)? onProgress,
  }) async {
    _cancelled = false;
    final dir = _downloadsDir();
    try {
      if (dir == null) return null;
      final file = File(
          '${dir.path}${Platform.pathSeparator}${archiveFileName(version, extension)}');
      final resp = await _client
          .send(http.Request('GET', Uri.parse(url)))
          .timeout(const Duration(seconds: 20));
      if (resp.statusCode != 200) {
        Logger.instance
            .info('update', 'desktop download: HTTP ${resp.statusCode}');
        return null;
      }
      final total = resp.contentLength ?? 0;
      var received = 0;
      final sink = file.openWrite();
      try {
        await for (final chunk in resp.stream) {
          if (_cancelled) return null;
          received += chunk.length;
          sink.add(chunk);
          if (total > 0) onProgress?.call((received * 100 ~/ total).clamp(0, 100));
        }
      } finally {
        await sink.close();
      }
      if (total > 0 && received < total) {
        Logger.instance
            .info('update', 'desktop download incomplete: $received/$total');
        return null;
      }
      return file.absolute.path;
    } catch (e) {
      Logger.instance.warn('update', 'desktop download failed: $e');
      return null;
    }
  }

  /// v0.6.3 §release-parity: the saved file name — pure so the extension
  /// contract is unit-testable without a network round-trip.
  static String archiveFileName(String version, String extension) {
    final safe = version.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    return 'atlanhix-update-$safe$extension';
  }

  /// Opens the platform file manager on the downloaded file (one tap away
  /// from an unzip/tar over the old install). Never throws.
  ///
  /// v0.6.3 §release-parity: Windows selects the file in Explorer; Linux has
  /// no select verb, so xdg-open gets the containing folder (honest and
  /// works on every DE); macOS keeps `open -R` for completeness.
  Future<void> revealInExplorer(String path) async {
    try {
      final file = File(path);
      if (Platform.isWindows) {
        await Process.run('explorer', ['/select,', path]);
      } else if (Platform.isLinux) {
        final dir = file.parent;
        await Process.run('xdg-open', [dir.path]);
      } else if (Platform.isMacOS) {
        await Process.run('open', ['-R', path]);
      }
    } catch (e) {
      Logger.instance.info('update', 'reveal failed: $e');
    }
  }

  /// The real Downloads folder for the running OS, with sane fallbacks:
  /// %USERPROFILE%\Downloads (Windows), $HOME/Downloads (Linux/macOS),
  /// then the temp dir. Never null on a sane system.
  Directory? _downloadsDir() {
    final env = Platform.environment;
    final home = Platform.isWindows
        ? env['USERPROFILE']
        : (env['HOME'] ?? env['XDG_CONFIG_HOME']?.replaceAll('/.config', ''));
    if (home != null && home.isNotEmpty) {
      final d = Directory('$home${Platform.pathSeparator}Downloads');
      if (d.existsSync()) return d;
    }
    return Directory.systemTemp;
  }
}
