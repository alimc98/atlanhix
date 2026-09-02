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
    this.autoUpdate = true,
    this.updateIntervalMinutes = 360,
    this.lastError,
    this.etag,
  });

  final String id;
  String name;
  String url;
  SubscriptionInfo info;
  SubscriptionStatus status;
  DateTime? lastUpdated;
  int nodeCount;
  int healthyCount;
  bool autoUpdate;
  int updateIntervalMinutes;
  String? lastError;
  String? etag;

  DateTime? get nextUpdate {
    if (!autoUpdate || lastUpdated == null) return null;
    return lastUpdated!.add(Duration(minutes: updateIntervalMinutes));
  }

  Map<String, dynamic> toStorable() => {
        'id': id,
        'name': name,
        'url': url,
        'info': {
          'upload': info.uploadBytes,
          'download': info.downloadBytes,
          'total': info.totalBytes,
          'expire': info.expireAt?.millisecondsSinceEpoch,
          'title': info.title,
        },
        'lastUpdated': lastUpdated?.toIso8601String(),
        'nodeCount': nodeCount,
        'healthyCount': healthyCount,
        'autoUpdate': autoUpdate,
        'updateIntervalMinutes': updateIntervalMinutes,
        'lastError': lastError,
        'etag': etag,
      };

  static Subscription fromJson(Map<String, dynamic> j) {
    final infoRaw = (j['info'] ?? {}) as Map<String, dynamic>;
    final expire = infoRaw['expire'] as int?;
    return Subscription(
      id: j['id'] as String,
      name: j['name'] as String,
      url: j['url'] as String,
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
      autoUpdate: j['autoUpdate'] as bool? ?? true,
      updateIntervalMinutes: j['updateIntervalMinutes'] as int? ?? 360,
      lastError: j['lastError'] as String?,
      etag: j['etag'] as String?,
    );
  }
}
