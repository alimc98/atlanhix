import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/application/clipboard_import_service.dart';
import 'package:nexus/application/update_checker.dart';
import 'package:nexus/protocols/importer.dart';

/// v0.5.6 regression guards for the three reported bugs.
///
/// Bug 2 was a silent version-constant drift: `kAppVersion` sat at `0.5.1+8`
/// while pubspec had moved on through five releases, so the update checker
/// compared every tag against a version that no binary ever had and reported
/// an update on EVERY launch. Nothing failed — the app just nagged forever.
/// The only durable fix is to make the drift break the build.
void main() {
  group('app version stays in sync with pubspec', () {
    test('kAppVersion matches pubspec version', () {
      final pubspec = File('pubspec.yaml').readAsStringSync();
      final m = RegExp(r'^version:\s*(\S+)', multiLine: true).firstMatch(pubspec);
      expect(m, isNotNull, reason: 'pubspec.yaml has no version: line');
      final pubspecVersion = m!.group(1)!;
      expect(
        kAppVersion,
        pubspecVersion,
        reason: 'kAppVersion (lib/application/update_checker.dart) has drifted '
            'from pubspec version:. The update checker compares the running '
            'binary against this value, so a stale constant makes it offer '
            'an update on every launch. Bump both together.',
      );
    });

    test('the constant parses as a comparable version', () {
      expect(kAppVersion, matches(RegExp(r'^\d+\.\d+\.\d+\+\d+$')));
    });
  });

  group('clipboard only offers real subscription URLs', () {
    // Bug 3: "هر چیزی توی کلیپ‌بورد باشه رو می‌خواد add subscribe کنه" —
    // anything in the clipboard was offered as a subscription, because the
    // old test was merely "is this an http(s) link with a host?".
    final svc = ClipboardImportService(
      importer: _StubImporter(),
      onAddNodes: (_) async {},
      onAddSubscription: (_) async {},
    );

    bool offered(String t) =>
        svc.classify(t) != ClipboardPayloadKind.none;

    test('ordinary web links are NOT offered', () {
      const notSubscriptions = <String>[
        'https://github.com/alimc98/atlanhix',
        'https://github.com/',
        'https://t.me/some_channel',
        'https://telegram.me/joinchat/AAAA',
        'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
        'https://youtu.be/dQw4w9WgXcQ',
        'https://news.example.com/2026/10/some-article-about-vpn',
        'https://example.com/',
        'https://example.com',
        'https://twitter.com/someone/status/1234567890',
        'https://en.wikipedia.org/wiki/Virtual_private_network',
      ];
      for (final url in notSubscriptions) {
        expect(offered(url), isFalse,
            reason: '"$url" is not a subscription and must not be offered');
      }
    });

    test('real subscription shapes ARE still offered', () {
      const subscriptions = <String>[
        // path-shaped providers
        'https://panel.example.com/sub/abcdef123456',
        'https://panel.example.com/subscribe/xyz789',
        'https://example.com/api/v1/client/subscribe?token=abc123',
        // token-in-query providers
        'https://example.com/?token=abc123def456',
        'https://example.com/path?uuid=0123456789abcdef',
        // opaque single-segment token paths
        'https://example.com/AbCdEf1234567890XyZ',
      ];
      for (final url in subscriptions) {
        expect(offered(url), isTrue,
            reason: '"$url" looks like a subscription and must be offered');
      }
    });

    test('share links and junk behave exactly as before', () {
      expect(svc.classify('vless://uuid@example.com:443?security=tls#node'),
          ClipboardPayloadKind.shareLinks);
      expect(svc.classify('ss://YWVzLTI1Ni1nY206cGFzcw=='),
          ClipboardPayloadKind.shareLinks);
      expect(svc.classify(''), ClipboardPayloadKind.none);
      expect(svc.classify('just some random text'),
          ClipboardPayloadKind.none);
      expect(svc.classify('hello world https://example.com/sub/abc123456'),
          ClipboardPayloadKind.none,
          reason: 'a URL embedded in prose is not a bare subscription link');
    });
  });
}

/// Minimal stand-in — `classify` never touches the importer.
class _StubImporter extends MultiFormatImporter {}