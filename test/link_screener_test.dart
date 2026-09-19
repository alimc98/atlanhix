// v0.4.7 §user — the pre-import link screener.
//
// Contract: a payload's Xray-ONLY transports (xhttp / mKCP — the sing-box
// front cannot express them) and their stream-shape requirements are
// classified BEFORE import, so the subscription card can report counts
// ("Xray-only nodes / with warnings") instead of the user discovering a
// broken node at connect time. The screener is a PURE classifier: profiles
// in, counts out — no repository, no I/O.
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/domain/entities/proxy_profile.dart';
import 'package:nexus/protocols/importer.dart';
import 'package:nexus/protocols/link_screener.dart';

ProxyProfile _xhttp({Map<String, String> params = const {}}) =>
    ProxyProfile(
      id: 'x1',
      name: 'xhttp node',
      server: 'cdn.example.com',
      port: 443,
      protocol: ProxyProtocol.vless,
      transport: Transport.xhttp,
      security: Security.tls,
      uuid: 'u',
      path: '/api',
      sni: 'cdn.example.com',
      rawParams: {'type': 'xhttp', ...params},
    );

ProxyProfile _kcp({Map<String, String> params = const {}}) => ProxyProfile(
      id: 'k1',
      name: 'kcp node',
      server: 'k.example.com',
      port: 443,
      protocol: ProxyProtocol.vmess,
      transport: Transport.quic, // the vmess parser's mKCP mapping
      security: Security.none,
      uuid: 'u',
      rawParams: {'type': 'kcp', ...params},
    );

ProxyProfile _plain() => ProxyProfile(
      id: 's1',
      name: 'shared node',
      server: 's.example.com',
      port: 443,
      protocol: ProxyProtocol.vless,
      transport: Transport.ws,
      security: Security.tls,
      uuid: 'u',
      path: '/ws',
    );

void main() {
  group('LinkScreener — Xray-only classification', () {
    test('xhttp node → xrayOnly bucket with the transport cause', () {
      final e = const LinkScreener().screen(_xhttp());
      expect(e.engine, LinkScreenEngine.xrayOnly);
      expect(e.transport, LinkScreenTransport.xhttp);
      expect(e.causes.any((c) => c.contains('Xray core only')), isTrue);
    });

    test('mKCP node (raw param, quic enum) → xrayOnly bucket', () {
      final e = const LinkScreener().screen(_kcp());
      expect(e.engine, LinkScreenEngine.xrayOnly);
      expect(e.transport, LinkScreenTransport.mkcp);
      expect(e.causes.any((c) => c.contains('Xray core only')), isTrue);
    });

    test('shared node → shared bucket, no causes', () {
      final e = const LinkScreener().screen(_plain());
      expect(e.engine, LinkScreenEngine.shared);
      expect(e.transport, LinkScreenTransport.other);
      expect(e.causes, isEmpty);
    });
  });

  group('LinkScreener — stream-shape risks', () {
    test('xhttp with explicit modern mode is flagged only for the transport',
        () {
      final e = const LinkScreener()
          .screen(_xhttp(params: {'mode': 'stream-one'}));
      expect(e.risks, isEmpty,
          reason: 'a well-shaped xhttp node carries no shape risks');
      expect(e.isRisky, isFalse);
    });

    test('xhttp legacy mode spelling is flagged with the 26.x mapping', () {
      final e = const LinkScreener().screen(_xhttp(params: {'mode': 'packet'}));
      expect(
          e.risks.any((c) =>
              c.contains('packet') && c.contains('packet-up')), isTrue);
      expect(e.isRisky, isTrue);
    });

    test('xhttp mode inside the extra JSON object is honored', () {
      final e = const LinkScreener().screen(_xhttp(params: {
        'extra': '{"mode":"stream-one","xPaddingBytes":"100"}',
      }));
      expect(e.risks.where((c) => c.contains('mode')), isEmpty);
    });

    test('mKCP without headerType and seed is flagged twice', () {
      final e = const LinkScreener().screen(_kcp());
      expect(e.risks.any((c) => c.contains('headerType')), isTrue);
      expect(e.risks.any((c) => c.contains('seed')), isTrue);
      expect(e.risks.length, 2);
      expect(e.causes.length, 1, reason: 'transport notice stays separate');
    });

    test('mKCP with headerType=http + seed is clean apart from transport',
        () {
      final e = const LinkScreener()
          .screen(_kcp(params: {'headerType': 'http', 'seed': 's3ed'}));
      expect(e.risks, isEmpty);
      expect(e.causes.length, 1);
    });

    test('clash-style header JSON is understood', () {
      final e = const LinkScreener()
          .screen(_kcp(params: {'header': '{"type":"http"}'}));
      expect(e.risks.any((c) => c.contains('headerType')), isFalse);
    });
  });

  group('LinkScreener — aggregates', () {
    test('screenAll counts buckets, risks and causes', () {
      final s = const LinkScreener().screenAll([
        _xhttp(params: {'mode': 'stream-one'}),
        _kcp(), // no header/seed → risky
        _plain(),
        _plain(),
      ]);
      expect(s.total, 4);
      expect(s.xrayOnly, 2);
      expect(s.risky, 1);
      expect(s.perTransport[LinkScreenTransport.xhttp], 1);
      expect(s.perTransport[LinkScreenTransport.mkcp], 1);
      expect(s.perTransport[LinkScreenTransport.other], 2);
      expect(s.hasFindings, isTrue);
    });

    test('an all-shared payload has no findings (UI row stays hidden)', () {
      final s = const LinkScreener().screenAll([_plain(), _plain()]);
      expect(s.xrayOnly, 0);
      expect(s.risky, 0);
      expect(s.hasFindings, isFalse);
    });
  });

  group('MultiFormatImporter — screening is attached to results', () {
    test('a mixed uriList import carries real counts', () {
      const payload = 'vless://u@cdn.example.com:443?security=tls&'
          'type=xhttp&path=%2Fapi&sni=cdn.example.com#xhttp-node\n'
          'vless://u@ws.example.com:443?security=tls&type=ws&path=%2Fws#ws-node';
      final r = MultiFormatImporter().import(payload);
      expect(r.profiles.length, 2);
      expect(r.screen.total, 2);
      expect(r.screen.xrayOnly, 1);
      expect(r.screen.hasFindings, isTrue);
    });

    test('the default ImportResult screen is a valid empty summary', () {
      final r = ImportResult(
          profiles: const [], warnings: const [], format: SourceFormat.unknown);
      expect(r.screen.total, 0);
      expect(r.screen.hasFindings, isFalse);
    });
  });
}
