import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/configgen/outbound_builders.dart';
import 'package:nexus/domain/entities/proxy_profile.dart';

/// v0.4.4: Xray xhttp nodes failed on-device because the builder dropped
/// link params (PQ `encryption` string, xhttp `extra` object, xPadding).
/// These tests pin the full-parameter emission.
void main() {
  const pq = 'mlkem768x25519plus.native.0rtt.6jty63RGNSxYYZbIGYzemZe8eM5Cd';
  final xhttpReality = ProxyProfile(
    id: 'x1',
    name: 'RO Reality',
    server: '1.2.3.4',
    port: 443,
    protocol: ProxyProtocol.vless,
    transport: Transport.xhttp,
    security: Security.reality,
    uuid: 'b1a2798c-6d0a-44dd-9d7f-f8a59e6d7f83',
    encryption: pq,
    sni: 'almodarresi.com',
    fingerprint: 'chrome',
    realityPublicKey: 'YHMi34atgyrjGIQzqiACOwznzSXdgP-WLaiIqzbPNjo',
    realityShortId: '07e480',
    realitySpiderX: '/ef1f1a38423451e',
    path: '/apiw',
    rawParams: {
      'type': 'xhttp',
      'mode': 'auto',
      'path': '/apiw',
      'security': 'reality',
      'encryption': pq,
      'extra': '{"mode":"auto","xPaddingBytes":"150-1000","xPaddingHeader":"example"}',
      'x_padding_bytes': '150-1000',
      'fp': 'chrome',
    },
  );

  test('vless user keeps the post-quantum encryption string verbatim', () {
    final out = OutboundBuilders().xrayOutbound(xhttpReality, tag: 'proxy-out')!;
    final user = (((out['settings'] as Map)['vnext'] as List).first
        as Map)['users'][0] as Map;
    expect(user['encryption'], pq);
    expect(user['id'], xhttpReality.uuid);
  });

  test('xhttpSettings carries mode+path+padding from extra JSON', () {
    final out = OutboundBuilders().xrayOutbound(xhttpReality, tag: 'proxy-out')!;
    final stream = out['streamSettings'] as Map;
    expect(stream['network'], 'xhttp');
    final xs = stream['xhttpSettings'] as Map;
    expect(xs['mode'], 'auto');
    expect(xs['path'], '/apiw');
    expect(xs['xPaddingBytes'], '150-1000');
    expect(xs['xPaddingHeader'], 'example');
    expect(xs['host'], 'almodarresi.com'); // sni fallback (no host param)
  });

  test('realitySettings keeps pbk/sid/spx/fingerprint', () {
    final out = OutboundBuilders().xrayOutbound(xhttpReality, tag: 'proxy-out')!;
    final rs = ((out['streamSettings'] as Map)['realitySettings']) as Map;
    expect(rs['publicKey'], xhttpReality.realityPublicKey);
    expect(rs['shortId'], '07e480');
    expect(rs['spiderX'], '/ef1f1a38423451e');
    expect(rs['fingerprint'], 'chrome');
    expect(rs['serverName'], 'almodarresi.com');
  });

  test('encryption=none links still emit none (Ghodrat-style plain vless)',
      () {
    final plain = ProxyProfile(
      id: 'g1',
      name: 'Ghodrat',
      server: '5.6.7.8',
      port: 443,
      protocol: ProxyProtocol.vless,
      transport: Transport.xhttp,
      security: Security.tls,
      uuid: 'b1a2798c-6d0a-44dd-9d7f-f8a59e6d7f83',
      encryption: 'none',
      sni: 'n2.example.ir',
      host: 'n2.example.ir',
      fingerprint: 'chrome',
      path: '/api',
      rawParams: {
        'type': 'xhttp',
        'mode': 'auto',
        'path': '/api',
        'encryption': 'none',
        'extra': '{"mode":"auto","xPaddingBytes":"100-1000"}',
        'x_padding_bytes': '100-1000',
        'fp': 'chrome',
        'host': 'n2.example.ir',
        'security': 'tls',
        'sni': 'n2.example.ir',
      },
    );
    final out = OutboundBuilders().xrayOutbound(plain, tag: 'p')!;
    final user = (((out['settings'] as Map)['vnext'] as List).first
        as Map)['users'][0] as Map;
    expect(user['encryption'], 'none');
    final xs = ((out['streamSettings'] as Map)['xhttpSettings']) as Map;
    expect(xs['xPaddingBytes'], '100-1000');
    expect(jsonEncode(xs).contains('"host":"n2.example.ir"'), isTrue);
  });
}
