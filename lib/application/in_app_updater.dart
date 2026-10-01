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
          final ok = await install(version: _version ?? '');
          onStage?.call(ok ? 'installing' : 'failed');
        case 'failed' || 'gone':
          _poll?.cancel();
          onStage?.call('failed');
      }
    });
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
  Future<bool> install({required String version}) async {
    try {
      final r =
          await _channel.invokeMethod<String>('install', {'version': version});
      final j = _decode(r!);
      if (j['ok'] != true) {
        Logger.instance
            .warn('update', 'install refused: ${j['error'] ?? 'unknown'}');
        return false;
      }
      return true;
    } on MissingPluginException {
      return false;
    } catch (e) {
      Logger.instance.warn('update', 'install failed: $e');
      return false;
    }
  }

  Map<String, dynamic> _decode(String raw) =>
      Map<String, dynamic>.from(jsonDecode(raw) as Map);

  void dispose() => _poll?.cancel();
}

/// v0.6.0 §desktop-update — Windows download flow, the desktop half of the
/// same "download inside the app" promise.
///
/// The release ZIP carries the app binaries AND its cores/ dir, so the
/// upgrade path is: download into the user's Downloads folder (real HTTP
/// stream with progress through the same CleanDnsClient the checker uses,
/// so a DNS-poisoned network still resolves GitHub) → explorer window opens
/// on the file → the user unzips over the previous install (or runs it from
/// anywhere). A true silent self-replace needs a separate updater process
/// with elevation; this is the honest one-tap version of it.
class DesktopUpdateDownloader {
  DesktopUpdateDownloader({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;
  bool _cancelled = false;

  void cancel() => _cancelled = true;

  /// Streams [url] into `<Downloads>/atlanhix-update-<version>.zip`.
  /// Returns the absolute file path, or null on failure/cancel.
  Future<String?> downloadZip({
    required String url,
    required String version,
    void Function(int percent)? onProgress,
  }) async {
    _cancelled = false;
    final dir = _downloadsDir();
    try {
      if (dir == null) return null;
      final safe = version.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
      final file = File('${dir.path}${Platform.pathSeparator}'
          'atlanhix-update-$safe.zip');
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

  /// Opens an explorer window on the downloaded file (one tap away from
  /// unzip-over-old-install). Never throws.
  Future<void> revealInExplorer(String path) async {
    try {
      await Process.run('explorer', ['/select,', path]);
    } catch (e) {
      Logger.instance.info('update', 'explorer reveal failed: $e');
    }
  }

  /// The real Downloads folder on Windows (COM shell lookup), with sane
  /// fallbacks: UserProfile\Downloads, then the temp dir.
  Directory? _downloadsDir() {
    final profile = Platform.environment['USERPROFILE'];
    if (profile != null && profile.isNotEmpty) {
      final d = Directory('$profile\\Downloads');
      if (d.existsSync()) return d;
    }
    return Directory.systemTemp;
  }
}
