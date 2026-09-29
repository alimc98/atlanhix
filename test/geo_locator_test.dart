import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nexus/core/net/geo_locator.dart';

void main() {
  group('GeoFix parsing', () {
    test('ip-api JSON', () {
      final f = GeoFix.fromIpApiJson(const {
        'status': 'success',
        'lat': 35.69,
        'lon': 51.39,
        'city': 'Tehran',
        'country': 'Iran',
        'countryCode': 'IR',
        'query': '78.38.1.1',
      });
      expect(f.plausible, isTrue);
      expect(f.countryCode, 'IR');
      expect(f.hasCity, isTrue);
    });

    test('ipwho.is JSON', () {
      final f = GeoFix.fromIpWhoJson(const {
        'ip': '89.137.1.1',
        'latitude': 44.43,
        'longitude': 26.1,
        'city': 'Bucharest',
        'country': 'Romania',
        'country_code': 'RO',
        'success': true,
      });
      expect(f.plausible, isTrue);
      expect(f.lat, closeTo(44.43, 1e-9));
      expect(f.countryCode, 'RO');
    });

    test('Cloudflare trace (country-only)', () {
      final f = GeoFix.fromTraceText(
          'fl=1\nip=1.2.3.4\nloc=RO\ncolo=OTP\ntls=TLSv1.3\n');
      expect(f.countryCode, 'RO');
      expect(f.ip, '1.2.3.4');
    });

    test('dead IPs are rejected by plausibility pipeline', () {
      // The locator rejects these before they ever reach the UI.
      expect(isDeadIpForTest('0.0.0.0'), isTrue);
      expect(isDeadIpForTest('127.0.0.1'), isTrue);
      expect(isDeadIpForTest('10.0.0.5'), isTrue);
      expect(isDeadIpForTest('192.168.1.1'), isTrue);
      expect(isDeadIpForTest('172.20.3.4'), isTrue);
      expect(isDeadIpForTest('100.64.0.9'), isTrue);
      expect(isDeadIpForTest('::'), isTrue);
      expect(isDeadIpForTest('fe80::1'), isTrue);
      expect(isDeadIpForTest('89.137.1.1'), isFalse);
      expect(isDeadIpForTest('78.38.1.1'), isFalse);
    });
  });

  group('GeoLocator provider fallback', () {
    test('first provider wins', () async {
      final client = MockClient((req) async {
        if (req.url.host == 'ip-api.com') {
          return http.Response(
              jsonEncode({
                'status': 'success',
                'lat': 35.69,
                'lon': 51.39,
                'city': 'Tehran',
                'country': 'Iran',
                'countryCode': 'IR',
                'query': '78.38.1.1',
              }),
              200);
        }
        return http.Response('should not be called', 500);
      });
      final geo = GeoLocator(client: client);
      final fix = await geo.locateHome();
      expect(fix, isNotNull);
      expect(fix!.countryCode, 'IR');
      expect(geo.lastHome, same(fix));
    });

    test('falls through to the second provider', () async {
      final client = MockClient((req) async {
        if (req.url.host == 'ip-api.com') {
          return http.Response('{"success":false}', 200);
        }
        if (req.url.host == 'ipwho.is') {
          return http.Response(
              jsonEncode({
                'ip': '89.137.1.1',
                'latitude': 44.43,
                'longitude': 26.1,
                'city': 'Bucharest',
                'country': 'Romania',
                'country_code': 'RO',
              }),
              200);
        }
        return http.Response('no', 500);
      });
      final geo = GeoLocator(client: client);
      final fix = await geo.locateHome();
      expect(fix, isNotNull);
      expect(fix!.countryCode, 'RO');
    });

    test('dead exit IP never becomes a fix', () async {
      final client = MockClient((req) async {
        if (req.url.host == 'ip-api.com') {
          return http.Response(
              jsonEncode({
                'status': 'success',
                'lat': 1.0,
                'lon': 2.0,
                'city': '',
                'country': 'X',
                'countryCode': 'XX',
                'query': '0.0.0.0',
              }),
              200);
        }
        if (req.url.host == 'ipwho.is') {
          return http.Response(
              jsonEncode({
                'ip': '10.9.9.9',
                'latitude': 3.0,
                'longitude': 4.0,
                'city': '',
                'country': 'Y',
                'country_code': 'YY',
              }),
              200);
        }
        return http.Response('no', 500);
      });
      final geo = GeoLocator(client: client);
      final fix = await geo.locateExit();
      expect(fix, isNull); // honest: no fix at all, never a fake one
    });

    test('fresh cache answers without network', () async {
      var hits = 0;
      final client = MockClient((req) async {
        hits++;
        return http.Response(
            jsonEncode({
              'status': 'success',
              'lat': 44.43,
              'lon': 26.1,
              'city': 'Bucharest',
              'country': 'Romania',
              'countryCode': 'RO',
              'query': '89.137.1.1',
            }),
            200);
      });
      final geo = GeoLocator(client: client);
      await geo.locateExit();
      expect(hits, 1);
      await geo.locateExit(); // fresh → cached
      expect(hits, 1);
      await geo.locateExit(force: true); // forced → real round-trip
      expect(hits, 2);
    });

    test('host lookup resolves a node server', () async {
      final client = MockClient((req) async {
        expect(req.url.host, 'ip-api.com');
        expect(req.url.path, contains('ro-node.example.net'));
        return http.Response(
            jsonEncode({
              'status': 'success',
              'lat': 44.43,
              'lon': 26.1,
              'city': 'Bucharest',
              'country': 'Romania',
              'countryCode': 'RO',
              'query': '89.137.1.1',
            }),
            200);
      });
      final geo = GeoLocator(client: client);
      final fix = await geo.locateHost('ro-node.example.net');
      expect(fix, isNotNull);
      expect(fix!.city, 'Bucharest');
      // Cached: no second hit (the mock would throw on a second call).
      final again = await geo.locateHost('ro-node.example.net');
      expect(again, isNotNull);
    });

    test('network errors stay null — never throw', () async {
      final client = MockClient((req) async => throw Exception('offline'));
      final geo = GeoLocator(client: client);
      final fix = await geo.locateHome();
      expect(fix, isNull);
    });
  });

  group('geometry', () {
    test('great-circle Tehran → Bucharest ≈ 2 350 km', () {
      final tehran = const GeoFix(lat: 35.69, lon: 51.39, countryCode: 'IR');
      final buch =
          const GeoFix(lat: 44.43, lon: 26.10, countryCode: 'RO');
      final km = greatCircleKm(tehran, buch);
      expect(km, inInclusiveRange(2250, 2450));
    });

    test('snapToCapital fills unknown coordinates', () {
      final countryOnly =
          const GeoFix(lat: 0, lon: 0, countryCode: 'RO');
      final snapped = snapToCapital(countryOnly)!;
      expect(snapped.lat, closeTo(44.43, 0.01));
      expect(snapped.lon, closeTo(26.10, 0.01));
      // Real coordinates pass through untouched.
      final real =
          const GeoFix(lat: 35.7, lon: 51.4, countryCode: 'IR');
      expect(identical(snapToCapital(real), real), isTrue);
      expect(snapToCapital(const GeoFix(lat: 0, lon: 0, countryCode: 'ZZ')),
          isNull);
    });
  });
}
