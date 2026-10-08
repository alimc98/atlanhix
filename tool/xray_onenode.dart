import 'dart:convert';
import 'dart:io';
import 'package:nexus/core/configgen/xray_config_generator.dart';
import 'package:nexus/core/health/latency_tester.dart';
import 'package:nexus/protocols/importer.dart';
import 'package:nexus/routing/builtin_profiles.dart';
const xrayExe = r'C:\Users\Hosna\dev-tools\xray-win\xray.exe';
Future<void> main(List<String> args) async {
  final raw = File(Platform.environment['SUB_FILE']!).readAsStringSync().trim();
  var payload = raw;
  if (!raw.contains('://')) { try { payload = utf8.decode(base64.decode(raw)); } catch (_) {} }
  final p = MultiFormatImporter().import(payload).profiles.firstWhere((e) => e.name.contains(args[0]));
  final cfg = XrayConfigGenerator().generate(profile: p, routing: BuiltinRoutingProfiles.all().first, localSocksPort: 40995, dnsServer: '8.8.8.8');
  final dir = await Directory.systemTemp.createTemp('xo');
  final f = File('${dir.path}/c.json')..writeAsStringSync(jsonEncode(cfg));
  final proc = await Process.start(xrayExe, ['run','-c',f.path]);
  final slog = StringBuffer();
  proc.stdout.transform(utf8.decoder).listen(slog.write);
  proc.stderr.transform(utf8.decoder).listen(slog.write);
  await Future<void>.delayed(const Duration(seconds: 2));
  final r = await LatencyTester().testHttpViaSocksProxy('127.0.0.1', 40995, 'http://www.gstatic.com/generate_204', timeout: const Duration(seconds: 15));
  stdout.writeln('${r.ok ? "PASS" : "FAIL"} kind=${r.errorKind} ${r.latencyMs ?? '-'}ms');
  final lines = slog.toString().split('\n').where((l) => l.trim().isNotEmpty && !l.contains('starting') && !l.contains('Reading config')).toList();
  for (final l in lines.take(8)) {
    stdout.writeln('  ${l.replaceAll(RegExp(r'[0-9a-f]{8}-[0-9a-f-]{27}'), '<u>').replaceAll(RegExp(r'password=\S+'), 'password=<r>')}');
  }
  proc.kill();
  await dir.delete(recursive: true);
  exit(0);
}
