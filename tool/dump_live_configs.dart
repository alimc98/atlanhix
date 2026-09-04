// Dumps the generated Xray + sing-box configs for the first N live
// subscription profiles, with credentials redacted (validation tool).
import 'dart:convert';
import 'dart:io';

import 'package:nexus/core/core_detector.dart';
import 'package:nexus/core/configgen/singbox_config_generator.dart';
import 'package:nexus/core/configgen/xray_config_generator.dart';
import 'package:nexus/core/health/latency_tester.dart';
import 'package:nexus/domain/entities/proxy_profile.dart';
import 'package:nexus/protocols/importer.dart';
import 'package:nexus/routing/builtin_profiles.dart';
import 'package:nexus/routing/routing_models.dart';

String redact(String s) {
  var out = s;
  // uuid / long hex / base64ish secrets → redact
  out = out.replaceAll(RegExp(r'[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}', caseSensitive: false), '<uuid>');
  out = out.replaceAll(RegExp(r'"(password|privateKey|id|encryptionKey|publicKey|shortId)"\s*:\s*"[^"]+"', caseSensitive: false), r'"$1":"<redacted>"');
  return out;
}

Future<void> main() async {
  final raw = Platform.environment['ATLANHIX_SUBSCRIPTION_URL'];
  if (raw == null) {
    // ignore: avoid_print
    print('set ATLANHIX_SUBSCRIPTION_URL');
    return;
  }
  final client = HttpClient();
  final req = await client.getUrl(Uri.parse(raw));
  final resp = await req.close();
  final body = await utf8.decoder.bind(resp).join();
  client.close();
  var payload = body.trim();
  if (RegExp(r'^[A-Za-z0-9+/=]+$').hasMatch(payload) && payload.length % 4 == 0) {
    try {
      final d = utf8.decode(base64.decode(payload));
      if (d.contains('://')) payload = d;
    } on FormatException {}
  }
  final profiles = MultiFormatImporter().import(payload).profiles;
  final target = profiles
      .firstWhere((p) => p.transport == Transport.xhttp && p.security == Security.tls);
  final d = CoreDetector().resolve(target);
  final xrayJson = XrayConfigGenerator().generate(
    profile: target,
    routing: BuiltinRoutingProfiles.all().first,
    localSocksPort: 2081,
  );
  // ignore: avoid_print
  print('=== XRAY CONFIG (redacted) core=${d.core.name} ===');
  // ignore: avoid_print
  print(redact(const JsonEncoder.withIndent('  ').convert(xrayJson)));
  // Raw link params for comparison (redacted).
  // ignore: avoid_print
  print('=== PROFILE PARAMS (redacted) ===');
  // ignore: avoid_print
  print(redact(const JsonEncoder.withIndent('  ').convert({
    'server': target.server,
    'port': target.port,
    'transport': target.transport?.name,
    'security': target.security.name,
    'path': target.path,
    'host': target.host,
    'sni': target.sni,
    'alpn': target.alpn,
    'flow': target.flow,
    'rawParams-keys': target.rawParams.keys.toList(),
  })));
  final sb = SingBoxConfigGenerator().generate(
    runnableProfiles: [target],
    routing: BuiltinRoutingProfiles.all().first,
    dns: DnsSettings(mode: DnsMode.automatic),
    selectedTag: 'node:${target.id}',
    socksUpstreams: {
      target.id: (host: '127.0.0.1', port: 2081),
    },
  );
  // ignore: avoid_print
  print('=== SING-BOX FRONT (redacted, stub section) ===');
  // ignore: avoid_print
  print(redact(const JsonEncoder.withIndent('  ').convert(sb)));

  // --- Empirical: run the REAL xray with this config and probe it.
  final wd = await Directory.systemTemp.createTemp('xray-live-probe');
  final cfgFile = File('${wd.path}${Platform.pathSeparator}x.json');
  await cfgFile.writeAsString(jsonEncode(xrayJson));
  final xrayExe = File(Directory.current.path +
      Platform.pathSeparator +
      'cores' +
      Platform.pathSeparator +
      'windows-x64' +
      Platform.pathSeparator +
      'xray.exe');
  final p = await Process.start(xrayExe.path, ['run', '-c', cfgFile.path]);
  final errs = <String>[];
  p.stderr.transform(utf8.decoder).listen(errs.add);
  await Future<void>.delayed(const Duration(seconds: 2));
  final tester = LatencyTester();
  final rHttps = await tester.testHttpViaSocksProxy(
      '127.0.0.1', 2081, 'https://www.gstatic.com/generate_204',
      timeout: const Duration(seconds: 12));
  // ignore: avoid_print
  print('PROBE https via xray-socks: ok=${rHttps.ok} '
      'kind=${rHttps.errorKind} detail=${rHttps.detail} '
      '${rHttps.latencyMs}ms');
  final rHttp = await tester.testHttpViaSocksProxy(
      '127.0.0.1', 2081, 'http://www.gstatic.com/generate_204',
      timeout: const Duration(seconds: 12));
  // ignore: avoid_print
  print('PROBE http  via xray-socks: ok=${rHttp.ok} '
      'kind=${rHttp.errorKind} detail=${rHttp.detail} '
      '${rHttp.latencyMs}ms');
  p.kill();
  // ignore: avoid_print
  print('XRAY-STDERR (first 12 lines):');
  // ignore: avoid_print
  print(errs.take(12).join('\n'));
}
