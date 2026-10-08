import 'dart:convert';
import 'dart:io';

import 'package:nexus/core/configgen/mihomo_config_generator.dart';
import 'package:nexus/protocols/importer.dart';
import 'package:nexus/routing/builtin_profiles.dart';
import 'package:nexus/routing/routing_models.dart';


/// Validates MihomoConfigGenerator output against the REAL mihomo binary
/// (`mihomo -t -f config.json`) for representative user profiles.
/// Usage: dart run tool/mihomo_validate_configs.dart [path-to-mihomo]
Future<void> main(List<String> args) async {
  final mihomoBin = args.isNotEmpty
      ? args.first
      : 'cores${Platform.pathSeparator}windows-x64${Platform.pathSeparator}mihomo.exe';
  final routing = BuiltinRoutingProfiles.all().first;
  final dns = DnsSettings(mode: DnsMode.automatic);

  // Representative profiles: URI spellings users actually import. Servers are
  // dummies — `-t` validates schema/fields, it does not dial.
  final uris = <String, String>{
    'vless-reality-vision':
        'vless://8f2c41a8-1a2b-4c3d-9e10-fcafe0b12d34@203.0.113.10:443?security=reality&sni=www.cloudflare.com&fp=chrome&pbk=jNXHt1yRo0vDuchQlIP6Z0ZvjT3KtzVI-T4E7RoLJS0&sid=6ba85179&type=tcp&flow=xtls-rprx-vision#RealityNode',
    'vless-ws-tls':
        'vless://8f2c41a8-1a2b-4c3d-9e10-fcafe0b12d34@203.0.113.11:443?security=tls&sni=cdn.example.com&type=ws&host=cdn.example.com&path=%2Fws#WsNode',
    'vless-xhttp-reality':
        'vless://8f2c41a8-1a2b-4c3d-9e10-fcafe0b12d34@203.0.113.12:443?security=reality&sni=www.cloudflare.com&fp=chrome&pbk=jNXHt1yRo0vDuchQlIP6Z0ZvjT3KtzVI-T4E7RoLJS0&sid=6ba85179&type=xhttp&path=%2Fxhttp&host=cdn.example.com&mode=auto#XhttpNode',
    'vmess-ws-tls':
        'vmess://eyJhZGQiOiIyMDMuMC4xMTMuMTMiLCJhaWQiOiIwIiwiaWQiOiI4ZjJjNDFhOC0xYTJiLTRjM2QtOWUxMC1mY2FmZTBiMTJkMzQiLCJuYW1lIjoiVm1lc3NOb2RlIiwicG9ydCI6IjQ0MyIsInRscyI6InRscyIsImhvc3QiOiJjZG4uZXhhbXBsZS5jb20iLCJwYXRoIjoiL3ZtZXNzIiwibmV0Ijoid3MiLCJ2IjoiMiJ9',
    'trojan-tls':
        'trojan://secretpass@203.0.113.14:443?security=tls&sni=tls.example.com#TrojanNode',
    'ss-2022':
        'ss://YWVzLTI1Ni1nY206cGFzcw%3D%3D@203.0.113.15:8388#SSNode',
    'hysteria2':
        'hysteria2://secretpass@203.0.113.16:443?sni=hy2.example.com&insecure=0#Hy2Node',
    'tuic-v5':
        'tuic://8f2c41a8-1a2b-4c3d-9e10-fcafe0b12d34:secretpass@203.0.113.17:443?sni=tuic.example.com&congestion_control=bbr&udp_relay_mode=native#TuicNode',
  };

  final gen = MihomoConfigGenerator.ports(mixedPort: 2081, apiPort: 9099);
  var failures = 0;
  for (final entry in uris.entries) {
    final profile = MultiFormatImporter().import(entry.value).profiles.first;
    final cfg = gen.build(
      profiles: [profile],
      selectedId: profile.id,
      routing: routing,
      dns: dns,
    );
    final proxy = (cfg['proxies'] as List)
        .cast<Map<dynamic, dynamic>>()
        .singleOrNull;
    if (proxy == null) {
      failures++;
      // ignore: avoid_print
      print('FAIL ${entry.key}: proxy TRANSLATION DROPPED (proxyOf → null)');
      continue;
    }
    final dir = await Directory.systemTemp.createTemp('mihomo-val');
    final f = File('${dir.path}/config.json')
      ..writeAsStringSync(jsonEncode(cfg));
    final r = await Process.run(mihomoBin, ['-t', '-f', f.path]);
    final ok = r.exitCode == 0;
    if (!ok) failures++;
    // ignore: avoid_print
    print('${ok ? "PASS" : "FAIL"} ${entry.key}'
        ' → type=${proxy['type']}'
        '${ok ? "" : "\n    ${"${r.stdout}".trim()}${"${r.stderr}".trim()}"}');
    await dir.delete(recursive: true);
  }
  // ignore: avoid_print
  print(failures == 0 ? 'ALL PASS' : '$failures FAILURES');
  exit(failures == 0 ? 0 : 1);
}

extension on List<dynamic> {
  dynamic get singleOrNull => length == 1 ? first : null;
}
