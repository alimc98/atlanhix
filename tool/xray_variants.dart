import 'dart:convert';
import 'dart:io';
import 'package:nexus/core/configgen/xray_config_generator.dart';
import 'package:nexus/core/health/latency_tester.dart';
import 'package:nexus/protocols/importer.dart';
import 'package:nexus/routing/builtin_profiles.dart';
const xrayExe = r'C:\Users\Hosna\dev-tools\xray-win\xray.exe';
Future<void> main() async {
  final raw = File(Platform.environment['SUB_FILE']!).readAsStringSync().trim();
  var payload = raw;
  if (!raw.contains('://')) { try { payload = utf8.decode(base64.decode(raw)); } catch (_) {} }
  final p = MultiFormatImporter().import(payload).profiles.firstWhere((e) => e.name.contains('GM-USA'));
  final base = XrayConfigGenerator().generate(profile: p, routing: BuiltinRoutingProfiles.all().first, localSocksPort: 40990, dnsServer: '8.8.8.8');
  for (var v = 0; v < 4; v++) {
    final cfg = jsonDecode(jsonEncode(base)) as Map<String, dynamic>;
    cfg['inbounds'] = [ { 'tag':'socks-in','listen':'127.0.0.1','port':40990+v,'protocol':'socks','settings':{'auth':'noauth','udp':true} } ];
    final ob = (cfg['outbounds'] as List).firstWhere((o)=>o['tag']=='proxy-out') as Map<String, dynamic>;
    final ss = ob['streamSettings'] as Map<String, dynamic>;
    final xs = ss['xhttpSettings'] as Map<String, dynamic>;
    final users = (((ob['settings'])['vnext'] as List).first['users'] as List).first as Map<String, dynamic>;
    if (v == 1) xs.remove('host');
    if (v == 2) users.remove('encryption');
    if (v == 3) { xs.remove('host'); users.remove('encryption'); }
    final dir = await Directory.systemTemp.createTemp('xv');
    final f = File('${dir.path}/c.json')..writeAsStringSync(jsonEncode(cfg));
    final proc = await Process.start(xrayExe, ['run','-c',f.path]);
    final slog = StringBuffer();
    proc.stdout.transform(utf8.decoder).listen(slog.write);
    proc.stderr.transform(utf8.decoder).listen(slog.write);
    await Future<void>.delayed(const Duration(seconds: 3));
    final r = await LatencyTester().testHttpViaSocksProxy('127.0.0.1', 40990+v, 'http://www.gstatic.com/generate_204', timeout: const Duration(seconds: 12));
    final tag = ['as-generated','no-xhttp-host','drop-mlkem','both'][v];
    stdout.writeln('${r.ok ? "PASS" : "FAIL"}  $tag  kind=${r.errorKind} ${r.latencyMs ?? '-'}ms');
    if (!r.ok) {
      final err = slog.toString().split('\n').where((l)=>l.contains('Error')||l.contains('error')||l.contains('Failed')).take(2).join(' | ');
      if (err.isNotEmpty) stdout.writeln('    $err');
    }
    proc.kill();
    await dir.delete(recursive: true);
    await Future<void>.delayed(const Duration(milliseconds: 300));
  }
  exit(0);
}
