// v0.5.4 §globe3d — PURE SPHERICAL MATH for the Atlanhix globe.
//
// Everything here is unit-testable WITHOUT Flutter: no rendering, no I/O.
// The widget layer (atlanhix_globe_view.dart) converts these geodesic
// primitives into screen coordinates.
//
// Coordinate conventions (kept identical to dashboard_globe.dart so both
// painters can share data):
//   * lat/lon in DEGREES everywhere in this file's public API;
//   * unit-sphere vectors: x = cos(lat)·sin(lon), y = sin(lat),
//     z = cos(lat)·cos(lon) — so lon=0 faces +z, and the painter's yaw
//     rotation brings (−lon, lat) to face the viewer.

import 'dart:math' as math;

/// A geographic point the globe can anchor to. Country-level fixes are
/// first-class: the visualization only needs a representative point, never
/// a street address.
class GlobeLocation {
  const GlobeLocation({
    required this.lat,
    required this.lon,
    this.label = '',
    this.city = '',
    this.countryCode = '',
    this.exact = false,
  });

  final double lat;
  final double lon;

  /// Display name — already-localized text or a plain city/country label.
  final String label;
  final String city;
  final String countryCode;

  /// True when the fix came from a real geolocation of the host/IP;
  /// false for country-level fallbacks (the UI may style them lighter).
  final bool exact;

  GlobeLocation copyWith({double? lat, double? lon, String? label}) =>
      GlobeLocation(
        lat: lat ?? this.lat,
        lon: lon ?? this.lon,
        label: label ?? this.label,
        city: city,
        countryCode: countryCode,
        exact: exact,
      );

  @override
  bool operator ==(Object other) =>
      other is GlobeLocation &&
      other.lat == lat &&
      other.lon == lon &&
      other.label == label;

  @override
  int get hashCode => Object.hash(lat, lon, label);

  @override
  String toString() => 'GlobeLocation($lat, $lon, $label)';
}

/// Country-level representative coordinates (ISO-3166 alpha-2 → centroid).
/// The globe NEVER pretends city precision it does not have: when the node
/// model has no geo metadata and the server host cannot be geolocated, the
/// destination falls back to this table keyed by country hints in the node
/// name / host TLD. Kept deliberately small — the top node-origin countries
/// VPN users actually see.
const Map<String, GlobeLocation> kCountryCentroids = <String, GlobeLocation>{
  'IR': GlobeLocation(lat: 35.69, lon: 51.42, label: 'Iran'),
  'UK': GlobeLocation(lat: 51.51, lon: -0.13, label: 'United Kingdom'),
  'GB': GlobeLocation(lat: 51.51, lon: -0.13, label: 'United Kingdom'),
  'DE': GlobeLocation(lat: 50.11, lon: 8.68, label: 'Germany'),
  'FR': GlobeLocation(lat: 48.86, lon: 2.35, label: 'France'),
  'NL': GlobeLocation(lat: 52.37, lon: 4.90, label: 'Netherlands'),
  'RO': GlobeLocation(lat: 44.43, lon: 26.10, label: 'Romania'),
  'TR': GlobeLocation(lat: 41.01, lon: 28.98, label: 'Türkiye'),
  'AE': GlobeLocation(lat: 25.20, lon: 55.27, label: 'UAE'),
  'FI': GlobeLocation(lat: 60.17, lon: 24.94, label: 'Finland'),
  'SE': GlobeLocation(lat: 59.33, lon: 18.06, label: 'Sweden'),
  'PL': GlobeLocation(lat: 52.23, lon: 21.01, label: 'Poland'),
  'US': GlobeLocation(lat: 40.71, lon: -74.01, label: 'United States'),
  'CA': GlobeLocation(lat: 43.65, lon: -79.38, label: 'Canada'),
  'SG': GlobeLocation(lat: 1.35, lon: 103.82, label: 'Singapore'),
  'HK': GlobeLocation(lat: 22.32, lon: 114.17, label: 'Hong Kong'),
  'JP': GlobeLocation(lat: 35.68, lon: 139.69, label: 'Japan'),
  'KR': GlobeLocation(lat: 37.57, lon: 126.98, label: 'South Korea'),
  'AU': GlobeLocation(lat: -33.87, lon: 151.21, label: 'Australia'),
  'IN': GlobeLocation(lat: 19.08, lon: 72.88, label: 'India'),
  'MY': GlobeLocation(lat: 3.14, lon: 101.69, label: 'Malaysia'),
  'RU': GlobeLocation(lat: 55.76, lon: 37.62, label: 'Russia'),
  'UA': GlobeLocation(lat: 50.45, lon: 30.52, label: 'Ukraine'),
  'MD': GlobeLocation(lat: 47.01, lon: 28.86, label: 'Moldova'),
  'CH': GlobeLocation(lat: 47.38, lon: 8.54, label: 'Switzerland'),
  'AT': GlobeLocation(lat: 48.21, lon: 16.37, label: 'Austria'),
  'ES': GlobeLocation(lat: 40.42, lon: -3.70, label: 'Spain'),
  'IT': GlobeLocation(lat: 41.90, lon: 12.50, label: 'Italy'),
  'BR': GlobeLocation(lat: -23.55, lon: -46.63, label: 'Brazil'),
  'ZA': GlobeLocation(lat: -26.20, lon: 28.05, label: 'South Africa'),
};

/// Guesses the country code of a NODE from the textual hints the existing
/// subscription model already carries (the node NAME mostly, plus the
/// server host's TLD). Pure string heuristics — no network, no parsing of
/// subscription formats. Returns '' when nothing matches.
String guessCountryCode(String nodeName, String serverHost) {
  final name = nodeName.toLowerCase();
  // Full country names first (unambiguous): "Singapore – 02",
  // "Germany Frankfurt".
  const names = <String, String>{
    'singapore': 'SG', 'germany': 'DE', 'united kingdom': 'GB',
    'england': 'GB', 'netherlands': 'NL', 'hong kong': 'HK',
    'japan': 'JP', 'united states': 'US', 'usa': 'US', 'america': 'US',
    'france': 'FR', 'romania': 'RO', 'turkey': 'TR', 'türkiye': 'TR',
    'sweden': 'SE', 'finland': 'FI', 'poland': 'PL', 'switzerland': 'CH',
    'austria': 'AT', 'spain': 'ES', 'italy': 'IT', 'ukraine': 'UA',
    'moldova': 'MD', 'australia': 'AU', 'canada': 'CA', 'brazil': 'BR',
    'india': 'IN', 'malaysia': 'MY', 'russia': 'RU', 'emirates': 'AE',
    'iran': 'IR', 'tehran': 'IR',
  };
  for (final entry in names.entries) {
    if (name.contains(entry.key)) return entry.value;
  }
  // Two-letter ISO codes wrapped in common separators: "DE-01", "[UK]",
  // "US | New York".
  final m = RegExp(
    r'(?:^|[\s\[\(#|\-—–·/])'
    r'(ir|uk|gb|de|fr|nl|ro|tr|ae|fi|se|pl|us|ca|sg|hk|jp|kr|au|in|my|ru|'
    r'ua|md|ch|at|es|it|br|za)'
    r'(?=$|[\s\]\)#|\-—–·/])',
  ).firstMatch(name);
  if (m != null) {
    final code = m.group(1)!.toUpperCase();
    if (code == 'UK') return 'GB';
    return code;
  }
  // Flag emoji (regional indicators) — each pair encodes its code
  // directly (🇩🇪 → 'DE').
  final runes = nodeName.runes.toList();
  for (var i = 0; i + 1 < runes.length; i++) {
    final a = runes[i];
    final b = runes[i + 1];
    if (a >= 0x1F1E6 && a <= 0x1F1FF && b >= 0x1F1E6 && b <= 0x1F1FF) {
      final cc = String.fromCharCode(a - 0x1F1E6 + 0x41) +
          String.fromCharCode(b - 0x1F1E6 + 0x41);
      if (kCountryCentroids.containsKey(cc)) return cc;
    }
  }
  // Host TLD as the last resort (vpn.de → DE). Two-char TLDs only; the
  // generic TLDs (.com/.net/…) are not countries and are skipped.
  final host = serverHost.toLowerCase().trim();
  final tld = RegExp(r'\.([a-z]{2})$').firstMatch(host);
  if (tld != null) {
    var cc = tld.group(1)!.toUpperCase();
    if (cc == 'UK') cc = 'GB'; // co.uk / .uk → canonical GB
    if (kCountryCentroids.containsKey(cc)) return cc;
  }
  return '';
}

/// lat/lon (degrees) → unit-sphere vector (x, y, z) in the convention
/// documented at the top of this file.
(double, double, double) globeVec(double latDeg, double lonDeg) {
  final la = latDeg * math.pi / 180;
  final lo = lonDeg * math.pi / 180;
  final cl = math.cos(la);
  return (cl * math.sin(lo), math.sin(la), cl * math.cos(lo));
}

/// Great-circle SLERP between two geographic points: returns the lat/lon
/// at fraction [t] of the arc (t=0 → a, t=1 → b). Antipodal-safe: when the
/// two points are (near-)opposite a fallback plane is used.
(double, double) slerpLatLon(
  double lat1, double lon1,
  double lat2, double lon2,
  double t,
) {
  final va = globeVec(lat1, lon1);
  final vb = globeVec(lat2, lon2);
  final dot = (va.$1 * vb.$1 + va.$2 * vb.$2 + va.$3 * vb.$3)
      .clamp(-1.0, 1.0);
  final omega = math.acos(dot);
  if (omega < 1e-9) return (lat2, lon2); // identical
  final so = math.sin(omega);
  var w1 = math.sin((1 - t) * omega) / so;
  var w2 = math.sin(t * omega) / so;
  if (omega > math.pi - 1e-4) {
    // Near-antipodal: slerp is ill-conditioned — take the midpoint of the
    // normalized sum for the mid-part and lerp endpoints otherwise.
    if (t >= 0.45 && t <= 0.55) {
      final mx = va.$1 + vb.$1, my = va.$2 + vb.$2, mz = va.$3 + vb.$3;
      final ml = math.sqrt(mx * mx + my * my + mz * mz);
      if (ml > 1e-9) {
        return _vecToLatLon((mx / ml, my / ml, mz / ml));
      }
    }
    w1 = 1 - t;
    w2 = t;
  }
  final x = w1 * va.$1 + w2 * vb.$1;
  final y = w1 * va.$2 + w2 * vb.$2;
  final z = w1 * va.$3 + w2 * vb.$3;
  final len = math.sqrt(x * x + y * y + z * z);
  if (len < 1e-12) return (lat2, lon2);
  return _vecToLatLon((x / len, y / len, z / len));
}

(double, double) _vecToLatLon((double, double, double) v) {
  final lat = math.asin(v.$2.clamp(-1.0, 1.0)) * 180 / math.pi;
  final lon = math.atan2(v.$1, v.$3) * 180 / math.pi;
  return (lat, lon);
}

/// Great-circle distance in kilometers (mean Earth radius).
double greatCircleKm(double lat1, double lon1, double lat2, double lon2) {
  const r = 6371.0;
  final va = globeVec(lat1, lon1);
  final vb = globeVec(lat2, lon2);
  final dot = (va.$1 * vb.$1 + va.$2 * vb.$2 + va.$3 * vb.$3)
      .clamp(-1.0, 1.0);
  return r * math.acos(dot);
}

/// The arc LIFT for fraction [t] of the route: a raised midpoint scaled by
/// the route's angular length — a Tehran→London arc flies much higher than
/// a Tehran→Baku hop, exactly like the reference art.
double arcLift(double lat1, double lon1, double lat2, double lon2, double t) {
  final va = globeVec(lat1, lon1);
  final vb = globeVec(lat2, lon2);
  final dot = (va.$1 * vb.$1 + va.$2 * vb.$2 + va.$3 * vb.$3)
      .clamp(-1.0, 1.0);
  final omega = math.acos(dot);
  // 0.35 ≈ the classic flight-arc bulge; shorter hops stay closer to the
  // surface because sin(t·π) already tapers both ends to zero.
  final height = math.min(0.35, omega * 0.22);
  return 1 + height * math.sin(t * math.pi);
}

/// Total arc length parameter sample count for a smooth route path at any
/// globe radius. Longer routes get proportionally more segments, capped.
int arcSegmentsFor(double lat1, double lon1, double lat2, double lon2) {
  final va = globeVec(lat1, lon1);
  final vb = globeVec(lat2, lon2);
  final dot = (va.$1 * vb.$1 + va.$2 * vb.$2 + va.$3 * vb.$3)
      .clamp(-1.0, 1.0);
  final omega = math.acos(dot);
  return (24 + omega * 30).round().clamp(24, 96);
}
