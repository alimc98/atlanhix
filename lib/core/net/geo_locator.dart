import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;

/// v0.5.2 §globe — IP geolocation for the dashboard globe.
///
/// The dashboard's globe needs TWO anchored points:
///  * HOME — where the device really is (the DIRECT IP, measured with the
///    tunnel's effect bypassed as well as we can on the platform).
///  * EXIT — where the tunnel lands (the node/WARP exit IP).
///
/// When the tunnel is connected, `app → node` draws the great-circle ARC the
/// user asked for ("وقتی وصل می‌شیم از ایران به رومانی خط بکشه").
///
/// Providers (free, key-less, in fallback order):
///  1. ip-api.com — JSON: fields lat/lon/city/country/countryCode/query.
///  2. ipwho.is  — JSON: latitude/longitude/city/country_code/ip.
///  3. Cloudflare trace — text/plain `loc=IR` (country only, no city).
///  4. ipinfo.io/text — text/plain `country=NL\nloc=52.1,4.2` (city-free).
///
/// Engineering honesty rules (same spirit as the rest of the app):
///  * A DEAD IP never moves the pin — a lookup that answers with a reserved
///    IP (0.0.0.0, ::, 127.x, 10.x, 192.168.x …) is discarded, so a captive
///    portal / engine glitch cannot teleport the exit to the ISP's null host.
///  * Results are cached per ROLE and only refetched when the underlying IP
///    CHANGES (or `force`) — the globe's 1 Hz repaint never costs network I/O.
///  * Every failure is swallowed into `null` — the globe shows a calm
///    un-anchored state instead of error chrome.

/// One geolocated fix: coarse (country) + fine (city) coordinates.
class GeoFix {
  const GeoFix({
    required this.lat,
    required this.lon,
    required this.countryCode,
    this.countryName = '',
    this.city = '',
    this.ip = '',
  });

  final double lat;
  final double lon;
  final String countryCode; // ISO-3166 alpha-2 ('IR', 'RO', 'NL' …)
  final String countryName; // display name (may be empty on text providers)
  final String city; // '' when the provider cannot resolve a city
  final String ip;

  bool get hasCity => city.trim().isNotEmpty;

  factory GeoFix.fromIpApiJson(Map<String, dynamic> j) => GeoFix(
        lat: (j['lat'] as num?)?.toDouble() ?? 0,
        lon: (j['lon'] as num?)?.toDouble() ?? 0,
        countryCode: (j['countryCode'] as String?) ?? '',
        countryName: (j['country'] as String?) ?? '',
        city: (j['city'] as String?) ?? '',
        ip: (j['query'] as String?) ?? '',
      );

  factory GeoFix.fromIpWhoJson(Map<String, dynamic> j) => GeoFix(
        lat: (j['latitude'] as num?)?.toDouble() ?? 0,
        lon: (j['longitude'] as num?)?.toDouble() ?? 0,
        countryCode: (j['country_code'] as String?) ?? '',
        countryName: (j['country'] as String?) ?? '',
        city: (j['city'] as String?) ?? '',
        ip: (j['ip'] as String?) ?? '',
      );

  /// Cloudflare `/cdn-cgi/trace` (text/plain k=v lines) — country only.
  factory GeoFix.fromTraceText(String body) {
    String? field(String key) {
      for (final line in body.split('\n')) {
        final i = line.indexOf('=');
        if (i > 0 && line.substring(0, i).trim() == key) {
          return line.substring(i + 1).trim();
        }
      }
      return null;
    }

    final loc = field('loc') ?? '';
    // Some edges ship `loc=US` plus a `colo=` airport code only — no lat/lon.
    // City coordinates come from the JSON providers; this is the fallback.
    return GeoFix(
      lat: 0,
      lon: 0,
      countryCode: loc,
      ip: field('ip') ?? '',
    );
  }

  /// ipinfo.io/plain (or `ipinfo.io/json`-less text) — `country=NL\nloc=…`.
  factory GeoFix.fromIpInfoText(String body) {
    String? country;
    (double, double)? coords;
    for (final line in body.split('\n')) {
      final i = line.indexOf('=');
      if (i <= 0) continue;
      final k = line.substring(0, i).trim();
      final v = line.substring(i + 1).trim();
      if (k == 'country') country = v;
      if (k == 'loc') {
        final parts = v.split(',');
        if (parts.length == 2) {
          final lat = double.tryParse(parts[0].trim());
          final lon = double.tryParse(parts[1].trim());
          if (lat != null && lon != null) coords = (lat, lon);
        }
      }
    }
    if (country == null && coords == null) {
      // Maybe the JSON shape slipped through as text.
      try {
        final j = jsonDecode(body);
        if (j is Map) {
          return GeoFix(
            lat: (j['latitude'] as num?)?.toDouble() ?? 0,
            lon: (j['longitude'] as num?)?.toDouble() ?? 0,
            countryCode: (j['country'] as String?) ?? '',
            city: (j['city'] as String?) ?? '',
            ip: (j['ip'] as String?) ?? '',
          );
        }
      } on FormatException catch (_) {}
      return GeoFix(lat: 0, lon: 0, countryCode: '');
    }
    return GeoFix(
      lat: coords?.$1 ?? 0,
      lon: coords?.$2 ?? 0,
      countryCode: country ?? '',
      city: '',
      ip: '',
    );
  }

  bool get plausible =>
      lat.abs() <= 90 && lon.abs() <= 180 && countryCode.length == 2;
}

/// Test hook over [_isDeadIp] (the locator's own honesty invariant).
// ignore: avoid_public_member_tests
bool isDeadIpForTest(String ip) => _isDeadIp(ip);

/// Non-routable / local addresses — never an honest exit.
bool _isDeadIp(String ip) {
  final v = ip.trim();
  if (v.isEmpty || v == '0.0.0.0' || v == '::' || v == '::1') return true;
  if (v.startsWith('127.')) return true;
  if (v.startsWith('10.')) return true;
  if (v.startsWith('192.168.')) return true;
  if (v.startsWith('169.254.')) return true;
  // 172.16.0.0 – 172.31.255.255
  final octets = v.split('.');
  if (octets.length == 4) {
    final second = int.tryParse(octets[1]);
    if (octets[0] == '172' && second != null && second >= 16 && second <= 31) {
      return true;
    }
    // CGNAT 100.64/10 (carrier-grade NAT behind some mobile tunnels).
    if (octets[0] == '100' && second != null && second >= 64 && second <= 127) {
      return true;
    }
  }
  if (v.startsWith('fc') || v.startsWith('fd') || v.startsWith('fe80')) {
    return true; // IPv6 ULA / link-local
  }
  return false;
}

class GeoLocator {
  GeoLocator({http.Client? client, this.timeout = const Duration(seconds: 6)})
      : _client = client ?? http.Client();

  final http.Client _client;
  final Duration timeout;

  // ── Cached fixes ────────────────────────────────────────────────────────
  GeoFix? _home;
  DateTime? _homeAt; // last successful home lookup (freshness gate)
  GeoFix? _exit;
  DateTime? _exitAt;
  bool _homeInFlight = false;
  bool _exitInFlight = false;

  /// A cached fix younger than this is reused without network I/O. The
  /// callers fire on connect events, not ticks — this gate only stops a
  /// chatty state stream from hammering the providers.
  static const _freshFor = Duration(seconds: 60);

  /// Last known DIRECT-IP fix (null until the first successful lookup).
  GeoFix? get lastHome => _home;

  /// Last known TUNNEL-EXIT fix (null until the first successful lookup).
  GeoFix? get lastExit => _exit;

  static const List<String> _jsonProviders = <String>[
    'http://ip-api.com/json/?fields=status,lat,lon,city,country,countryCode,query',
    'https://ipwho.is/',
  ];

  static const List<(String, GeoFix Function(String))> _textProviders =
      <(String, GeoFix Function(String))>[
    (
      'https://www.cloudflare.com/cdn-cgi/trace',
      GeoFix.fromTraceText,
    ),
    (
      'https://ipinfo.io/widget',
      GeoFix.fromIpInfoText,
    ),
  ];

  /// Locate the device's DIRECT IP (home anchor). Fresh cache → reuse.
  Future<GeoFix?> locateHome({bool force = false}) async {
    if (_homeInFlight) return _home;
    _homeInFlight = true;
    try {
      final fresh = _home != null &&
          _homeAt != null &&
          DateTime.now().difference(_homeAt!) < _freshFor;
      if (!force && fresh) return _home;
      final r = await _locate();
      if (r != null) {
        _home = r;
        _homeAt = DateTime.now();
      }
      return r;
    } finally {
      _homeInFlight = false;
    }
  }

  /// Locate the TUNNEL-EXIT IP. An [exitIpHint] (when the engine exposes
  /// the egress IP) short-circuits a matching cache without a round-trip.
  Future<GeoFix?> locateExit({bool force = false, String? exitIpHint}) async {
    if (_exitInFlight) return _exit;
    _exitInFlight = true;
    try {
      final hint = (exitIpHint ?? '').trim();
      if (!force &&
          _exit != null &&
          hint.isNotEmpty &&
          hint == _exit!.ip) {
        return _exit;
      }
      final fresh = _exit != null &&
          _exitAt != null &&
          DateTime.now().difference(_exitAt!) < _freshFor;
      if (!force && fresh) return _exit;
      final r = await _locate();
      if (r != null) {
        _exit = r;
        _exitAt = DateTime.now();
      }
      return r;
    } finally {
      _exitInFlight = false;
    }
  }

  /// Forget cached fixes (connect/disconnect transitions invalidate the
  /// roles: the "home" probe may land on the tunnel while connected).
  void invalidate() {
    _home = null;
    _homeAt = null;
    _exit = null;
    _exitAt = null;
  }

  // Per-host cache for [locateHost] — a node's server hostname resolves
  // once per app run (subscription refreshes re-import the same hosts).
  final Map<String, GeoFix?> _hostCache = {};

  /// The LAST resolved host fix (any host, memoized) — the globe reads
  /// this for the provisional destination pin before the tunnel is up.
  /// v0.5.4 §globe3d: an honest read of the same cache.
  GeoFix? get lastHost {
    for (final fix in _hostCache.values) {
      if (fix != null) return fix;
    }
    return null;
  }

  /// Locate a NODE'S SERVER by hostname/IP (the provisional pin shown
  /// BEFORE the tunnel comes up). ip-api resolves domains server-side, so
  /// a plain hostname works; CDN-fronted hosts resolve to the CDN edge —
  /// the live exit fix always replaces this once the tunnel is up.
  Future<GeoFix?> locateHost(String host, {bool force = false}) async {
    final key = host.trim().toLowerCase();
    if (key.isEmpty) return null;
    if (!force && _hostCache.containsKey(key)) return _hostCache[key];
    try {
      final url =
          'http://ip-api.com/json/${Uri.encodeComponent(key)}'
          '?fields=status,lat,lon,city,country,countryCode,query';
      final resp = await _client.get(Uri.parse(url)).timeout(timeout);
      GeoFix? fix;
      if (resp.statusCode == 200) {
        final body = jsonDecode(resp.body);
        if (body is Map) {
          final j = body.cast<String, dynamic>();
          final okFlag = j['success'];
          if (!(okFlag is bool && !okFlag)) {
            final parsed = GeoFix.fromIpApiJson(j);
            if (parsed.plausible && !_isDeadIp(parsed.ip)) fix = parsed;
          }
        }
      }
      _hostCache[key] = fix;
      return fix;
    } on Exception catch (_) {
      return null; // decorative — never throw into the UI
    }
  }

  Future<GeoFix?> _locate() async {
    // 1) JSON providers — the responder's `query`/`ip` field IS the egress
    //    IP of whatever socket path this request took (direct when the
    //    tunnel is down, the exit when it is up) — exactly the honesty the
    //    two roles need, with zero engine plumbing.
    for (final url in _jsonProviders) {
      try {
        final resp = await _client.get(Uri.parse(url)).timeout(timeout);
        if (resp.statusCode != 200) continue;
        final body = jsonDecode(resp.body);
        if (body is! Map) continue;
        final j = body.cast<String, dynamic>();
        final okFlag = j['success'];
        if (okFlag is bool && !okFlag) continue;
        final fix = url.contains('ipwho.is')
            ? GeoFix.fromIpWhoJson(j)
            : GeoFix.fromIpApiJson(j);
        if (!fix.plausible || _isDeadIp(fix.ip)) continue;
        return fix;
      } on Exception catch (_) {
        continue; // next provider — never throw into the UI
      }
    }

    // 2) Text fallbacks (country-only: the pin snaps to a capital later).
    for (final (url, parse) in _textProviders) {
      try {
        final resp = await _client.get(Uri.parse(url)).timeout(timeout);
        if (resp.statusCode != 200) continue;
        final fix = parse(resp.body);
        if (!fix.plausible) continue;
        return fix;
      } on Exception catch (_) {
        continue;
      }
    }
    return null;
  }
}

/// ── Geometry helpers shared with the globe painter ────────────────────────
///
/// Kept beside the locator so the widget layer never duplicates the math.

/// Great-circle distance between two lat/lon fixes, in kilometres.
double greatCircleKm(GeoFix a, GeoFix b) {
  const r = 6371.0;
  final la1 = a.lat * math.pi / 180, la2 = b.lat * math.pi / 180;
  final dla = (b.lat - a.lat) * math.pi / 180;
  final dlo = (b.lon - a.lon) * math.pi / 180;
  final sinDla = math.sin(dla / 2);
  final sinDlo = math.sin(dlo / 2);
  final h = sinDla * sinDla + math.cos(la1) * math.cos(la2) * sinDlo * sinDlo;
  return 2 * r * math.asin(math.sqrt(h));
}

/// ISO-3166 alpha-2 → capital city coordinates (lat, lon).
///
/// v0.5.2 §globe: the dashboard globe samples this point cloud directly —
/// no asset parsing at runtime. Text-only providers (Cloudflare trace) give
/// a country code with NO coordinates; the pin then snaps to the capital
/// instead of vanishing. ~190 entries is ~6 KB of Dart — cheaper than a
/// lookup table asset and its async plumbing.
const Map<String, (double, double)> kCapitalCoords = <String, (double, double)>{
  'AD': (42.51, 1.52), 'AE': (24.47, 54.37), 'AF': (34.53, 69.17),
  'AG': (17.12, -61.85), 'AI': (18.22, -63.05), 'AL': (41.33, 19.82),
  'AM': (40.18, 44.51), 'AO': (-8.84, 13.23), 'AR': (-34.60, -58.38),
  'AS': (-14.28, -170.70), 'AT': (48.21, 16.37), 'AU': (-35.28, 149.13),
  'AW': (12.52, -70.03), 'AZ': (40.41, 49.87), 'BA': (43.86, 18.41),
  'BB': (13.10, -59.61), 'BD': (23.81, 90.41), 'BE': (50.85, 4.35),
  'BF': (12.37, -1.53), 'BG': (42.70, 23.32), 'BH': (26.22, 50.58),
  'BI': (-3.38, 29.36), 'BJ': (6.49, 2.61), 'BM': (32.29, -64.78),
  'BN': (4.89, 114.94), 'BO': (-16.50, -68.15), 'BR': (-15.79, -47.88),
  'BS': (25.05, -77.35), 'BT': (27.47, 89.64), 'BW': (-24.63, 25.92),
  'BY': (53.90, 27.57), 'BZ': (17.25, -88.77), 'CA': (45.42, -75.70),
  'CD': (-4.44, 15.27), 'CF': (4.36, 18.56), 'CG': (-4.27, 15.28),
  'CH': (46.95, 7.45), 'CI': (5.35, -4.02), 'CL': (-33.45, -70.67),
  'CM': (3.87, 11.52), 'CN': (39.90, 116.41), 'CO': (4.71, -74.07),
  'CR': (9.93, -84.08), 'CU': (23.11, -82.37), 'CV': (14.93, -23.51),
  'CW': (12.11, -68.93), 'CY': (35.17, 33.36), 'CZ': (50.09, 14.42),
  'DE': (52.52, 13.40), 'DJ': (11.59, 43.15), 'DK': (55.68, 12.57),
  'DM': (15.30, -61.39), 'DO': (18.47, -69.90), 'DZ': (36.75, 3.06),
  'EC': (-0.18, -78.47), 'EE': (59.44, 24.75), 'EG': (30.04, 31.24),
  'ER': (15.34, 38.93), 'ES': (40.42, -3.70), 'ET': (9.02, 38.75),
  'FI': (60.17, 24.94), 'FJ': (-18.14, 178.44), 'FM': (6.92, 158.16),
  'FO': (62.01, -6.77), 'FR': (48.86, 2.35), 'GA': (0.42, 9.47),
  'GB': (51.51, -0.13), 'GD': (12.06, -61.75), 'GE': (41.72, 44.79),
  'GF': (4.94, -52.33), 'GH': (5.60, -0.19), 'GI': (36.14, -5.35),
  'GL': (64.18, -51.72), 'GM': (13.45, -16.58), 'GN': (9.64, -13.58),
  'GP': (16.24, -61.53), 'GQ': (3.75, 8.78), 'GR': (37.98, 23.73),
  'GT': (14.63, -90.51), 'GU': (13.48, 144.75), 'GW': (11.86, -15.60),
  'GY': (6.80, -58.16), 'HK': (22.32, 114.17), 'HN': (14.07, -87.19),
  'HR': (45.81, 15.98), 'HT': (18.54, -72.34), 'HU': (47.50, 19.04),
  'ID': (-6.21, 106.85), 'IE': (53.35, -6.26), 'IL': (31.77, 35.21),
  'IN': (28.61, 77.21), 'IQ': (33.31, 44.36), 'IR': (35.69, 51.39),
  'IS': (64.15, -21.94), 'IT': (41.90, 12.50), 'JM': (17.97, -76.79),
  'JO': (31.95, 35.93), 'JP': (35.68, 139.69), 'KE': (-1.29, 36.82),
  'KG': (42.87, 74.59), 'KH': (11.56, 104.92), 'KM': (-11.70, 43.26),
  'KP': (39.02, 125.75), 'KR': (37.57, 126.98), 'KW': (29.38, 47.99),
  'KY': (19.29, -81.37), 'KZ': (51.17, 71.45), 'LA': (17.98, 102.63),
  'LB': (33.89, 35.50), 'LC': (14.01, -60.99), 'LI': (47.14, 9.52),
  'LK': (6.93, 79.86), 'LR': (6.30, -10.80), 'LS': (-29.31, 27.48),
  'LT': (54.69, 25.28), 'LU': (49.61, 6.13), 'LV': (56.95, 24.11),
  'LY': (32.89, 13.19), 'MA': (34.02, -6.84), 'MD': (47.01, 28.86),
  'ME': (42.44, 19.26), 'MG': (-18.88, 47.51), 'MK': (41.99, 21.43),
  'ML': (12.65, -8.00), 'MM': (19.75, 96.10), 'MN': (47.89, 106.91),
  'MO': (22.20, 113.55), 'MQ': (14.61, -61.07), 'MR': (18.08, -15.98),
  'MT': (35.90, 14.51), 'MU': (-20.16, 57.50), 'MV': (4.17, 73.51),
  'MW': (-13.97, 33.79), 'MX': (19.43, -99.13), 'MY': (3.14, 101.69),
  'MZ': (-25.97, 32.58), 'NA': (-22.56, 17.08), 'NC': (-22.28, 166.46),
  'NE': (13.51, 2.11), 'NG': (9.06, 7.50), 'NI': (12.11, -86.24),
  'NL': (52.37, 4.90), 'NO': (59.91, 10.75), 'NP': (27.72, 85.32),
  'NZ': (-41.29, 174.78), 'OM': (23.59, 58.41), 'PA': (8.98, -79.52),
  'PE': (-12.05, -77.04), 'PF': (-17.53, -149.57), 'PG': (-9.44, 147.18),
  'PH': (14.60, 120.98), 'PK': (33.69, 73.05), 'PL': (52.23, 21.01),
  'PR': (18.47, -66.11), 'PS': (31.90, 35.20), 'PT': (38.72, -9.14),
  'PY': (-25.26, -57.58), 'QA': (25.29, 51.53), 'RE': (-20.88, 55.45),
  'RO': (44.43, 26.10), 'RS': (44.79, 20.45), 'RU': (55.76, 37.62),
  'RW': (-1.95, 30.06), 'SA': (24.71, 46.68), 'SB': (-9.43, 159.96),
  'SC': (-4.62, 55.45), 'SD': (15.50, 32.56), 'SE': (59.33, 18.06),
  'SG': (1.35, 103.82), 'SI': (46.05, 14.51), 'SK': (48.15, 17.11),
  'SL': (8.47, -13.23), 'SM': (43.94, 12.45), 'SN': (14.72, -17.47),
  'SO': (2.07, 45.37), 'SR': (5.87, -55.17), 'SS': (4.85, 31.58),
  'SV': (13.69, -89.22), 'SY': (33.51, 36.28), 'SZ': (-26.32, 31.14),
  'TD': (12.11, 15.04), 'TG': (6.13, 1.22), 'TH': (13.76, 100.50),
  'TJ': (38.56, 68.79), 'TL': (-8.56, 125.56), 'TM': (37.95, 58.38),
  'TN': (36.81, 10.18), 'TO': (-21.14, -175.20), 'TR': (39.93, 32.86),
  'TT': (10.65, -61.51), 'TW': (25.03, 121.57), 'TZ': (-6.16, 35.75),
  'UA': (50.45, 30.52), 'UG': (0.35, 32.58), 'US': (38.90, -77.04),
  'UY': (-34.90, -56.16), 'UZ': (41.30, 69.24), 'VA': (41.90, 12.45),
  'VC': (13.16, -61.22), 'VE': (10.49, -66.88), 'VG': (18.42, -64.62),
  'VI': (18.34, -64.93), 'VN': (21.03, 105.85), 'VU': (-17.73, 168.32),
  'WS': (-13.83, -171.77), 'XK': (42.67, 21.17), 'YE': (15.37, 44.19),
  'ZA': (-25.75, 28.19), 'ZM': (-15.41, 28.28), 'ZW': (-17.83, 31.05),
};

/// Snap a fix with unknown coordinates onto its capital (country-code only
/// fixes from the text providers). Returns null when the code is unknown.
GeoFix? snapToCapital(GeoFix fix) {
  // Real coordinates (any non-zero lat/lon) are already an honest fix — a
  // device parked exactly on (0,0) in the Gulf of Guinea is not a real case.
  if (fix.lat != 0 || fix.lon != 0) return fix;
  final cap = kCapitalCoords[fix.countryCode.toUpperCase()];
  if (cap == null) return null;
  return GeoFix(
    lat: cap.$1,
    lon: cap.$2,
    countryCode: fix.countryCode,
    countryName: fix.countryName,
    city: fix.hasCity ? fix.city : 'capital',
    ip: fix.ip,
  );
}
