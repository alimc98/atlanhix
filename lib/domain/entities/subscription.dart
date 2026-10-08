import '../../settings/app_settings.dart' show CorePreference;

/// Traffic / account metadata advertised by providers via the standard
/// `subscription-userinfo` response header. Absent values mean the provider
/// does not expose them (never fabricated in UI).
class SubscriptionInfo {
  const SubscriptionInfo({
    this.uploadBytes,
    this.downloadBytes,
    this.totalBytes,
    this.expireAt,
    this.title,
  });

  final int? uploadBytes;
  final int? downloadBytes;
  final int? totalBytes;
  final DateTime? expireAt;
  final String? title;

  int? get usedBytes => (uploadBytes != null || downloadBytes != null)
      ? (uploadBytes ?? 0) + (downloadBytes ?? 0)
      : null;

  int? get remainingBytes => (totalBytes != null && usedBytes != null)
      ? (totalBytes! - usedBytes!).clamp(0, totalBytes!)
      : null;

  double? get usedFraction {
    if (totalBytes == null || totalBytes == 0 || usedBytes == null) return null;
    return (usedBytes! / totalBytes!).clamp(0.0, 1.0);
  }

  bool get hasAnyData =>
      uploadBytes != null || downloadBytes != null || totalBytes != null || expireAt != null;

  factory SubscriptionInfo.fromHeader(String value) {
    int? up, down, total, expire;
    for (final part in value.split(';')) {
      final kv = part.split('=');
      if (kv.length != 2) continue;
      final v = int.tryParse(kv[1].trim());
      if (v == null) continue;
      switch (kv[0].trim()) {
        case 'upload':
          up = v;
        case 'download':
          down = v;
        case 'total':
          total = v;
        case 'expire':
          expire = v;
      }
    }
    return SubscriptionInfo(
      uploadBytes: up,
      downloadBytes: down,
      totalBytes: total,
      expireAt: expire != null && expire > 0
          ? DateTime.fromMillisecondsSinceEpoch(expire * 1000)
          : null,
    );
  }
}

enum SubscriptionStatus { ok, updating, failed, neverUpdated }

class Subscription {
  Subscription({
    required this.id,
    required this.name,
    required this.url,
    this.info = const SubscriptionInfo(),
    this.status = SubscriptionStatus.neverUpdated,
    this.lastUpdated,
    this.nodeCount = 0,
    this.healthyCount = 0,
    this.screenXrayOnly = 0,
    this.screenRisky = 0,
    this.autoUpdate = true,
    this.updateIntervalMinutes = 360,
    this.lastError,
    this.etag,
    this.coreOverride,
  });

  final String id;
  String name;
  String url;
  SubscriptionInfo info;
  SubscriptionStatus status;
  DateTime? lastUpdated;
  int nodeCount;
  int healthyCount;

  /// v0.4.7 §user — last update's pre-import screening: how many nodes need
  /// the Xray core only (xhttp/mKCP) and how many carry stream-shape risks
  /// (headerType/mode/seed classes). 0 = no findings (or never screened).
  int screenXrayOnly;
  int screenRisky;

  bool autoUpdate;
  int updateIntervalMinutes;
  String? lastError;
  String? etag;

  /// v0.6.7 §sub-engine (user request): the ENGINE this subscription's
  /// content selected at import time.
  ///
  /// * `'mihomo'` — the payload was Clash.Meta (the format mihomo runs
  ///   natively); its nodes steer to the mihomo engine even on a device
  ///   whose mihomo probe has not settled yet (the child start owns a
  ///   per-node fallback).
  /// * `'auto'` — a plain URI/base64 subscription; the per-node capability
  ///   matrix decides (the exact fix for «ساب معمولی + mihomo وصل نمیشه»).
  /// * null — legacy row: falls back to the global Engine setting.
  String? coreOverride;

  CorePreference get effectiveCoreOverride => switch (coreOverride) {
        'mihomo' => CorePreference.mihomo,
        'auto' => CorePreference.auto,
        _ => CorePreference.auto,
      };

  DateTime? get nextUpdate {
    if (!autoUpdate || lastUpdated == null) return null;
    return lastUpdated!.add(Duration(minutes: updateIntervalMinutes));
  }

  static Subscription fromJson(Map<String, dynamic> j) {
    final infoRaw =
        (j['info'] ?? const <String, dynamic>{}) as Map<String, dynamic>;
    final expire = infoRaw['expire'] as int?;
    return Subscription(
      id: j['id'] as String,
      name: j['name'] as String,
      url: j['url'] as String,
      status: SubscriptionStatus.values.firstWhere(
        (s) => s.name == j['status'],
        orElse: () => SubscriptionStatus.neverUpdated,
      ),
      info: SubscriptionInfo(
        uploadBytes: infoRaw['upload'] as int?,
        downloadBytes: infoRaw['download'] as int?,
        totalBytes: infoRaw['total'] as int?,
        expireAt: expire == null ? null : DateTime.fromMillisecondsSinceEpoch(expire * 1000),
        title: infoRaw['title'] as String?,
      ),
      lastUpdated: j['lastUpdated'] == null
          ? null
          : DateTime.parse(j['lastUpdated'] as String),
      nodeCount: j['nodeCount'] as int? ?? 0,
      healthyCount: j['healthyCount'] as int? ?? 0,
      screenXrayOnly: j['screenXrayOnly'] as int? ?? 0,
      screenRisky: j['screenRisky'] as int? ?? 0,
      autoUpdate: j['autoUpdate'] as bool? ?? true,
      updateIntervalMinutes: j['updateIntervalMinutes'] as int? ?? 360,
      lastError: j['lastError'] as String?,
      etag: j['etag'] as String?,
      coreOverride: j['coreOverride'] as String?,
    );
  }
}
