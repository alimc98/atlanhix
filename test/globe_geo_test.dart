import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/presentation/globe/globe_geo.dart';

void main() {
  group('globeVec / slerpLatLon', () {
    test('endpoints are the inputs themselves', () {
      final (la, lo) = slerpLatLon(35.69, 51.42, 51.51, -0.13, 0.0);
      expect(la, closeTo(35.69, 0.01));
      expect(lo, closeTo(51.42, 0.01));
      final (la2, lo2) = slerpLatLon(35.69, 51.42, 51.51, -0.13, 1.0);
      expect(la2, closeTo(51.51, 0.01));
      expect(lo2, closeTo(-0.13, 0.01));
    });

    test('midpoint of Tehran→London is roughly midway in space', () {
      final (mla, mlo) = slerpLatLon(35.69, 51.42, 51.51, -0.13, 0.5);
      // Great-circle midpoints bow toward the pole relative to the naive
      // average — assert the loose band, not an exact value.
      expect(mla, inInclusiveRange(42, 50));
      expect(mlo, inInclusiveRange(20, 32));
    });

    test('antipodal points do not produce NaN', () {
      final (la, lo) = slerpLatLon(0, 0, 0, 180, 0.5);
      expect(la.isNaN, isFalse);
      expect(lo.isNaN, isFalse);
    });

    test('identical points short-circuit', () {
      final (la, lo) = slerpLatLon(10, 20, 10, 20, 0.7);
      expect(la, closeTo(10, 1e-6));
      expect(lo, closeTo(20, 1e-6));
    });

    test('every sample stays on the unit sphere (re-derived lat/lon)', () {
      for (var i = 0; i <= 20; i++) {
        final t = i / 20;
        final (la, lo) = slerpLatLon(-33.87, 151.21, 1.35, 103.82, t);
        final (x, y, z) = globeVec(la, lo);
        final len = math.sqrt(x * x + y * y + z * z);
        expect(len, closeTo(1.0, 1e-9));
      }
    });
  });

  group('greatCircleKm', () {
    test('Tehran→London ≈ 4390 km (±60)', () {
      final km = greatCircleKm(35.69, 51.42, 51.51, -0.13);
      expect(km, inInclusiveRange(4330, 4450));
    });

    test('zero distance for identical points', () {
      expect(greatCircleKm(10, 20, 10, 20), closeTo(0, 1e-6));
    });
  });

  group('arcLift', () {
    test('both ends touch the surface, midpoint is raised', () {
      final a = arcLift(35.69, 51.42, 51.51, -0.13, 0.0);
      final b = arcLift(35.69, 51.42, 51.51, -0.13, 1.0);
      final mid = arcLift(35.69, 51.42, 51.51, -0.13, 0.5);
      expect(a, closeTo(1.0, 1e-9));
      expect(b, closeTo(1.0, 1e-9));
      expect(mid, greaterThan(1.1));
    });

    test('longer routes fly higher', () {
      final shortHop =
          arcLift(35.69, 51.42, 38.0, 46.0, 0.5); // Tehran→Baku-ish
      final longHop =
          arcLift(35.69, 51.42, 40.71, -74.01, 0.5); // Tehran→NYC
      expect(longHop, greaterThan(shortHop));
    });
  });

  group('guessCountryCode', () {
    test('reads separators in node names', () {
      expect(guessCountryCode('DE-01 Frankfurt', 'x.com'), 'DE');
      expect(guessCountryCode('[UK] London 1', 'x.com'), 'GB');
      expect(guessCountryCode('US | New York', 'x.com'), 'US');
      expect(guessCountryCode('nl · Amsterdam', 'x.com'), 'NL');
      expect(guessCountryCode('Singapore – 02', 'x.com'), 'SG');
    });

    test('reads flag emoji', () {
      expect(guessCountryCode('🇩🇪 Frankfurt', 'x.com'), 'DE');
      expect(guessCountryCode('🇭🇰 Sai Wan', 'x.com'), 'HK');
    });

    test('falls back to the host TLD', () {
      expect(guessCountryCode('relay-4', 'vpn.de'), 'DE');
      // .uk canonicalizes to GB (the centroid table's key).
      expect(guessCountryCode('relay-4', 'node.co.uk'), 'GB');
      // Generic TLDs are not countries.
      expect(guessCountryCode('relay-4', 'node.com'), '');
    });

    test('gives up honestly', () {
      expect(guessCountryCode('fast-node-9', '1.2.3.4'), '');
    });
  });

  group('kCountryCentroids', () {
    test('the spec’s example cities resolve', () {
      expect(kCountryCentroids['GB']!.lat, closeTo(51.51, 0.2));
      expect(kCountryCentroids['DE']!.city, isEmpty);
      expect(kCountryCentroids['SG']!.lat, closeTo(1.35, 0.2));
      expect(kCountryCentroids['HK']!.lon, closeTo(114.17, 0.2));
      expect(kCountryCentroids['JP']!.lat, closeTo(35.68, 0.2));
      expect(kCountryCentroids['US']!.lon, closeTo(-74.01, 0.2));
    });
  });

  group('arcSegmentsFor', () {
    test('short hops stay near the floor, long arcs scale', () {
      expect(arcSegmentsFor(10, 20, 11, 21), lessThan(30));
      expect(
        arcSegmentsFor(0, 0, 60, 120),
        greaterThan(arcSegmentsFor(0, 0, 5, 10)),
      );
      expect(arcSegmentsFor(0, 0, 0, 179), lessThanOrEqualTo(96));
    });
  });
}
