// Regression for the ECH dropout (root cause #6, Mi 9T 2026-09-13):
// subscription hysteria2 links carry `ech=<base64 DER ECHConfigList>`;
// the importer kept it in rawParams but the config generator never emitted
// it — ECH-only servers then killed every handshake
// ("Connection terminated during handshake"). sing-box 1.14 consumes ECH
// as a PEM block typed "ECH CONFIGS" (verified against v1.14.0
// common/tls/ech.go + `sing-box check`).
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/configgen/singbox_config_generator.dart';
import 'package:nexus/domain/entities/proxy_profile.dart';
import 'package:nexus/protocols/adapters/hysteria2.dart';
import 'package:nexus/routing/routing_models.dart';

void main() {
  // The real ECHConfigList (base64) from an imported subscription node —
  // contains no credentials.
  const echB64 =
      'AF7+DQBaAAAgACA/Hm1VTKlmnzWIQJ4s1yLPefMK3/Z2SnngqpTj3NS3XwAkAAEAAQ'
      'ABAAIAAQADAAIAAQACAAIAAgADAAMAAQADAAIAAwADAAt1ay5oaXh5ei5pcgAA';
  // Subscriptions percent-encode the base64 (real link uses %2B).
  final echParam = Uri.encodeComponent(echB64);

  test('hysteria2 link keeps the ech param for configgen', () {
    final p = Hysteria2Parser().parse(
        'hysteria2://SECRET@uk.example.test:443?sni=uk.example.test'
        '&obfs=salamander&obfs-password=O&ech=$echParam#n');
    expect(p.rawParams['ech'], echB64);
  });

  test('generated sing-box config embeds tls.ech as an ECH CONFIGS PEM', () {
    final p = Hysteria2Parser().parse(
        'hysteria2://SECRET@uk.example.test:443?sni=uk.example.test'
        '&obfs=salamander&obfs-password=O&ech=$echParam#n');
    final cfg = SingBoxConfigGenerator().generate(
      runnableProfiles: [p],
      routing: RoutingProfile(id: 'r', name: 'r', rules: const []),
      dns: DnsSettings(mode: DnsMode.automatic),
      options: const SingBoxOptions(enableTun: false),
      selectedTag: 'proxy',
    );
    final ob = (cfg['outbounds'] as List)
        .cast<Map<String, dynamic>>()
        .firstWhere((o) => o['type'] == 'hysteria2');
    final ech = (ob['tls'] as Map)['ech'] as Map;
    expect(ech['enabled'], isTrue);
    final pem = (ech['config'] as List).single as String;
    expect(pem, startsWith('-----BEGIN ECH CONFIGS-----'));
    expect(pem, endsWith('-----END ECH CONFIGS-----'));
    // DER must round-trip exactly — sing-box feeds block.Bytes into
    // SetECHConfigList, so a mangled copy would hard-fail the handshake.
    final body = pem
        .split('\n')
        .where((l) => !l.startsWith('-----'))
        .join();
    expect(base64.decode(body), base64.decode(echB64));
    // QUIC outbound must NOT carry utls (sing-box: "unsupported usage").
    expect((ob['tls'] as Map)['utls'], isNull);
  });

  test('no ech param → no tls.ech key at all (never a broken empty block)',
      () {
    final p = Hysteria2Parser().parse(
        'hysteria2://SECRET@plain.example.test:443?sni=plain.example.test#n');
    final cfg = SingBoxConfigGenerator().generate(
      runnableProfiles: [p],
      routing: RoutingProfile(id: 'r', name: 'r', rules: const []),
      dns: DnsSettings(mode: DnsMode.automatic),
      options: const SingBoxOptions(enableTun: false),
      selectedTag: 'proxy',
    );
    final ob = (cfg['outbounds'] as List)
        .cast<Map<String, dynamic>>()
        .firstWhere((o) => o['type'] == 'hysteria2');
    expect((ob['tls'] as Map)['ech'], isNull);
  });

  test('corrupt ech param is dropped, not emitted', () {
    final p = Hysteria2Parser().parse(
        'hysteria2://SECRET@x.example.test:443?sni=x.example.test&ech=%%%notb64#n');
    final cfg = SingBoxConfigGenerator().generate(
      runnableProfiles: [p],
      routing: RoutingProfile(id: 'r', name: 'r', rules: const []),
      dns: DnsSettings(mode: DnsMode.automatic),
      options: const SingBoxOptions(enableTun: false),
      selectedTag: 'proxy',
    );
    final ob = (cfg['outbounds'] as List)
        .cast<Map<String, dynamic>>()
        .firstWhere((o) => o['type'] == 'hysteria2');
    expect((ob['tls'] as Map)['ech'], isNull);
  });
}
