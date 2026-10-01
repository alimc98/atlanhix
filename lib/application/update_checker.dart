import 'dart:convert';
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
const String kAppVersion = '0.5.8+14';

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
      // Prefer the .apk asset; fall back to the release page.
      String url = (j['html_url'] as String?) ?? repoApi;
      final assets = (j['assets'] as List?) ?? const [];
      for (final a in assets) {
        final name = ((a as Map)['name'] as String?)?.toLowerCase() ?? '';
        final link = a['browser_download_url'] as String?;
        if (link != null && name.endsWith('.apk')) {
          url = link;
          break;
        }
      }
      return UpdateInfo(
        version: tag,
        url: url,
        notes: (j['body'] as String?) ?? '',
      );
    } catch (e) {
      Logger.instance.info('update', 'check failed: $e');
      return null;
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

class UpdateInfo {
  UpdateInfo({required this.version, required this.url, required this.notes});

  final String version;
  final String url;
  final String notes;
}
