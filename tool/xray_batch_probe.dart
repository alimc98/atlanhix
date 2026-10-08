// Xray-side batch probe: import the live subscription, take ONLY the
// xhttp/mKCP nodes, generate each node's real Xray config via
// XrayConfigGenerator (the same code path the phone uses), run the real
// xray.exe, and dial gstatic out through its SOCKS inbound. Credentials
// are never printed.
import 'dart:convert';
import 'dart:io';

import 'package:nexus/core/configgen/xray_config_generator.dart';
import 'package:nexus/core/health/latency_tester.dart';
import 'package:nexus/domain/entities/proxy_profile.dart';
import 'package:nexus/protocols/importer.dart';
import 'package:nexus/routing/builtin_profiles.dart';

const xrayExe = r'C:\Users\Hosna\dev-tools\xray-win\xray.exe';

Future<void> main() async {
  final raw =
      File(Platform.environment['SUB_FILE']!).readAsStringSync().trim();
  var payload = raw;
  if (!raw.contains('://')) {
    try {
      payload = utf8.decode(base64.decode(raw));
    } catch (_) {}
  }
  final profiles = MultiFormatImporter().import(payload).profiles;
  final xrayNodes = profiles
      .where((p) =>
          p.transport == Transport.xhttp ||
          p.rawParams['type'] == 'mkcp' ||
          p.rawParams['type'] == 'kcp')
      .toList();
  stdout.writeln('total ${profiles.length}, xray-only ${xrayNodes.length}');

  var port = 21910;
  for (final p in xrayNodes) {
    final label = p.name.replaceAll('\n', ' ');
    port++;
    try {
      final cfg = XrayConfigGenerator().generate(
        profile: p,
        routing: BuiltinRoutingProfiles.all().first,
        localSocksPort: port,
        dnsServer: '8.8.8.8',
      );
      final dir = await Directory.systemTemp.createTemp('xprobe');
      final f = File('${dir.path}${Platform.pathSeparator}c.json');
      await f.writeAsString(jsonEncode(cfg));
      Process? proc;
      try {
        proc = await Process.start(xrayExe, ['run', '-c', f.path]);
        final slog = StringBuffer();
        proc.stdout.transform(utf8.decoder).listen(slog.write);
        proc.stderr.transform(utf8.decoder).listen(slog.write);
        await Future<void>.delayed(const Duration(seconds: 3));
        final r = await LatencyTester().testHttpViaSocksProxy(
            '127.0.0.1', port, 'http://www.gstatic.com/generate_204',
            timeout: const Duration(seconds: 15));
        stdout.writeln('${r.ok ? "PASS" : "FAIL"}  $label  '
            '(${p.transport.name}  / ${p.security.name}) '
            'kind=${r.errorKind} ${r.latencyMs ?? '-'}ms');
        if (!r.ok) {
          final tail = slog
              .toString()
              .split('\n')
              .where((l) =>
                  l.contains('error') ||
                  l.contains('Error') ||
                  l.contains('failed'))
              .take(2)
              .join(' | ');
          stdout.writeln('      log: ${tail.isEmpty ? "-" : tail}');
        }
      } finally {
        proc?.kill();
        await dir.delete(recursive: true);
        await Future<void>.delayed(const Duration(milliseconds: 400));
      }
    } catch (e) {
      stdout.writeln('GENFAIL $label  $e');
    }
  }
  exit(0);
}
