import 'dart:io';

/// Multi-signal CDN detection (§13). Signals are advisory: they bias
/// fragmentation attempts and UI badges, never hard-block connections.
class CdnSignals {
  const CdnSignals({
    required this.isCdn,
    required this.provider,
    required this.confidence,
    required this.indicators,
  });

  final bool isCdn;
  final String? provider; // cloudflare | fastly | cloudfront | gcore | other
  final double confidence;
  final List<String> indicators;
}

class CdnDetector {
  // Well-known Cloudflare ranges (kept intentionally small & curated).
  static const _cloudflareV4 = [
    '173.245.48.0/20',
    '103.21.244.0/22',
    '103.22.200.0/22',
    '103.31.4.0/22',
    '141.101.64.0/18',
    '108.162.192.0/18',
    '190.93.240.0/20',
    '188.114.96.0/20',
    '197.234.240.0/22',
    '198.41.128.0/17',
    '162.158.0.0/15',
    '104.16.0.0/13',
    '172.64.0.0/13',
    '131.0.72.0/22',
  ];

  static const _cdnHostHints = [
    'cloudflare',
    'cdn',
    'fastly',
    'cloudfront',
    'gcore',
    'akamai',
    'edgekey',
    'workers.dev',
    'pages.dev',
  ];

  CdnSignals analyze({
    required String serverHost,
    String? sni,
    String? wsHost,
    String? transport,
    String? security,
  }) {
    final indicators = <String>[];
    var score = 0.0;
    String? provider;

    if (_isCloudflareIp(serverHost)) {
      score += 0.5;
      provider = 'cloudflare';
      indicators.add('server IP is in a Cloudflare range');
    }
    for (final h in [sni, wsHost, serverHost]) {
      if (h == null) continue;
      final lower = h.toLowerCase();
      for (final hint in _cdnHostHints) {
        if (lower.contains(hint)) {
          score += 0.25;
          provider ??= hint == 'cloudflare' || hint == 'workers.dev' || hint == 'pages.dev'
              ? 'cloudflare'
              : 'other';
          indicators.add('hostname contains "$hint"');
          break;
        }
      }
    }
    if (transport == 'ws' || transport == 'xhttp' || transport == 'httpupgrade') {
      score += 0.15;
      indicators.add('$transport transport is CDN-friendly');
    }
    if (security == 'tls' || security == 'reality') {
      score += 0.10;
      indicators.add('TLS on 443-style fronting');
    }
    return CdnSignals(
      isCdn: score >= 0.5,
      provider: provider,
      confidence: score.clamp(0.0, 1.0),
      indicators: indicators,
    );
  }

  static bool _isCloudflareIp(String host) {
    final ip = InternetAddress.tryParse(host);
    if (ip == null || ip.type != InternetAddressType.IPv4) return false;
    final bytes = ip.address;
    for (final cidr in _cloudflareV4) {
      if (_inCidr(bytes, cidr)) return true;
    }
    return false;
  }

  static bool _inCidr(String ip, String cidr) {
    final parts = cidr.split('/');
    final net = InternetAddress(parts[0]);
    final prefix = int.parse(parts[1]);
    final ipBytes = InternetAddress(ip).rawAddress;
    final netBytes = net.rawAddress;
    var fullBytes = prefix ~/ 8;
    var remBits = prefix % 8;
    for (var i = 0; i < fullBytes; i++) {
      if (ipBytes[i] != netBytes[i]) return false;
    }
    if (remBits > 0) {
      final mask = (0xFF << (8 - remBits)) & 0xFF;
      if ((ipBytes[fullBytes] & mask) != (netBytes[fullBytes] & mask)) {
        return false;
      }
    }
    return true;
  }
}
