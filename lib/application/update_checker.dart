import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../core/logger.dart';
import '../core/net/clean_dns_client.dart';

/// The version this binary was built from (mirrors pubspec `version:`).
///
/// v0.5.6 §update-fix: this was a HAND-MAINTAINED constant that had drifted
/// to `0.5.1+8` while pubspec was already at 0.5.5 — so the checker compared
/// every release against a stale version and ALWAYS reported an update,
/// forever ("همش پیام آپدیت میده" — it keeps telling me there is an update).
///
/// `pubspec.yaml` remains the single source of truth; this literal must be
/// bumped with it. That invariant is now ENFORCED by
/// `test/app_version_consistency_test.dart`, which fails the build when the
/// two disagree — which is how the drift stayed invisible for five releases.
const String kAppVersion = '0.6.3+19';

/// v0.4.7 §user — the release update checker.
///
/// On app open (throttled to once per 24h) it asks GitHub Releases for the
/// newest published tag and compares it with the RUNNING version. When a
/// newer release exists it reports [UpdateInfo] — the UI shows a
/// Download / Later dialog (the download is the release page / APK asset
/// URL opened in the browser; no silent installs, no in-app APK sideloading
/// — Android requires user consent for that and this keeps the app honest).
class UpdateChecker {
  UpdateChecker({http.Client? client}) : _client = client ?? CleanDnsClient();

  final http.Client _client;

  /// The repo that hosts releases.
  static const repoApi =
      'https://api.github.com/repos/alimc98/atlanhix/releases/latest';

  /// Throttle key — checked once per 24 hours per storage section.
  static const throttleHours = 24;

  DateTime? lastChecked; // set by the caller's persistence layer

  /// Latest release info, or null when up-to-date / offline / rate-limited.
  /// Never throws.
  Future<UpdateInfo?> check({required String currentVersion}) async {
    try {
      final resp = await _client.get(Uri.parse(repoApi), headers: {
        'Accept': 'application/vnd.github+json',
        'User-Agent': 'atlanhix-updater',
      }).timeout(const Duration(seconds: 12));
      if (resp.statusCode != 200) {
        Logger.instance.info('update',
            'check skipped: HTTP ${resp.statusCode} (offline/rate-limited)');
        return null;
      }
      final j = jsonDecode(resp.body) as Map<String, dynamic>;
      final tag = (j['tag_name'] as String?)?.trim() ?? '';
      if (tag.isEmpty) return null;
      final latest = _parseVersion(tag);
      final current = _parseVersion(currentVersion);
      if (latest == null || current == null) return null;
      if (!_isNewer(latest, current)) return null;
      // Prefer the platform's own installer asset; fall back to the release
      // page. v0.6.0 §desktop-update: Windows picks the release ZIP
      // (Atlanhix-v*-windows-x64.zip — engines ride inside, so an unzip
      // over the old install upgrades in place), Android keeps the .apk.
      // v0.6.3 §release-parity: Linux gets the same treatment
      // (Atlanhix-v*-linux-x64.tar.gz), and the Android pick is ABI-aware —
      // the release carries arm64/v7a/universal splits and "first .apk"
      // could hand an arm64 phone the 32-bit build.
      final assets = (j['assets'] as List?) ?? const [];
      String url = (j['html_url'] as String?) ?? repoApi;
      var kind = UpdateAssetKind.apk;
      final pick = assetForPlatform(
        platformName,
        archHint: Platform.version,
      );
      for (final cand in pick.candidates) {
        var hit = false;
        for (final a in assets) {
          final m = a as Map;
          final name = (m['name'] as String?)?.toLowerCase() ?? '';
          final link = m['browser_download_url'] as String?;
          if (link != null &&
              name.startsWith(cand.prefix) &&
              name.endsWith(cand.suffix)) {
            url = link;
            kind = cand.kind;
            hit = true;
            break;
          }
        }
        if (hit) break;
      }
      return UpdateInfo(
        version: tag,
        url: url,
        notes: (j['body'] as String?) ?? '',
        assetKind: kind,
      );
    } catch (e) {
      Logger.instance.info('update', 'check failed: $e');
      return null;
    }
  }

  /// v0.6.3 §release-parity: the platform name the asset picker understands.
  static String get platformName {
    if (kIsWeb) return 'web';
    return switch (defaultTargetPlatform) {
      TargetPlatform.android => 'android',
      TargetPlatform.windows => 'windows',
      TargetPlatform.linux => 'linux',
      TargetPlatform.macOS => 'macos',
      _ => 'other',
    };
  }

  /// v0.6.3 §release-parity: the release asset that serves [platform] —
  /// PURE so every platform/ABI combination is unit-testable without a
  /// device. [archHint] is the raw `Platform.version` string (Android ABI
  /// detection: the release ships arm64-v8a / armeabi-v7a / universal
  /// splits). Candidates are tried IN ORDER; a miss on the ABI-specific
  /// suffix falls back to universal, then to any file of the right kind.
  static ReleaseAssetPick assetForPlatform(String platform,
      {String archHint = ''}) {
    switch (platform) {
      case 'android':
        final a = archHint.toLowerCase();
        final abi = (a.contains('arm64') || a.contains('aarch64'))
            ? '-arm64-v8a'
            : (a.contains('armeabi') || a.contains('armv7'))
                ? '-armeabi-v7a'
                : '-universal';
        return ReleaseAssetPick([
          (prefix: 'atlanhix-', suffix: '$abi.apk', kind: UpdateAssetKind.apk),
          if (abi != '-universal')
            (prefix: 'atlanhix-', suffix: '-universal.apk', kind: UpdateAssetKind.apk),
          (prefix: '', suffix: '.apk', kind: UpdateAssetKind.apk),
        ]);
      case 'windows':
        return ReleaseAssetPick([
          (prefix: 'atlanhix-', suffix: '-windows-x64.zip', kind: UpdateAssetKind.windowsZip),
        ]);
      case 'linux':
        return ReleaseAssetPick([
          (prefix: 'atlanhix-', suffix: '-linux-x64.tar.gz', kind: UpdateAssetKind.linuxTarGz),
        ]);
      default:
        // macOS has no published asset yet — the caller keeps the release
        // page URL, which is honest (and the dialog says so).
        return const ReleaseAssetPick([]);
    }
  }

  /// `v0.4.6` / `0.4.6+7` → (0,4,6) with the build number as a 4th part.
  static List<int>? _parseVersion(String raw) {
    final m = RegExp(r'(\d+)\.(\d+)\.(\d+)').firstMatch(raw);
    if (m == null) return null;
    final build = RegExp(r'\+(\d+)').firstMatch(raw)?.group(1) ?? '0';
    return [
      int.parse(m.group(1)!),
      int.parse(m.group(2)!),
      int.parse(m.group(3)!),
      int.parse(build),
    ];
  }

  static bool _isNewer(List<int> a, List<int> b) {
    for (var i = 0; i < 4; i++) {
      final x = i < a.length ? a[i] : 0;
      final y = i < b.length ? b[i] : 0;
      if (x != y) return x > y;
    }
    return false;
  }
}

/// The kind of release asset the checker picked for this platform.
enum UpdateAssetKind { apk, windowsZip, linuxTarGz }

/// One asset-name matcher: a release file is mine when its lowercased name
/// starts with [prefix] and ends with [suffix].
typedef ReleaseAssetMatcher = ({String prefix, String suffix, UpdateAssetKind kind});

/// Ordered fallbacks for a platform (ABI-specific first, universal last).
class ReleaseAssetPick {
  const ReleaseAssetPick(this.candidates);

  final List<ReleaseAssetMatcher> candidates;
}

class UpdateInfo {
  UpdateInfo({
    required this.version,
    required this.url,
    required this.notes,
    this.assetKind = UpdateAssetKind.apk,
  });

  final String version;
  final String url;
  final String notes;

  /// v0.6.0 §desktop-update: what the UI should do with [url] — an Android
  /// APK goes through the in-app DownloadManager + installer; a Windows zip
  /// is downloaded into the user's Downloads folder and offered as an
  /// unzip-in-place upgrade (the bundle carries its own cores dir, so the
  /// release zip IS the installer).
  final UpdateAssetKind assetKind;
}
