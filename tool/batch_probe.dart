// Batch probe: import the live subscription, generate a real sing-box runtime
// config per non-xhttp node, run the bundled sing-box.exe and dial out through
// its socks port to gstatic. One verdict line per node. Credentials redacted.
import 'dart:convert';
import 'dart:io';

import 'package:nexus/core/configgen/singbox_config_generator.dart';
import 'package:nexus/core/health/latency_tester.dart';
import 'package:nexus/domain/entities/proxy_profile.dart';
import 'package:nexus/protocols/importer.dart';
import 'package:nexus/routing/builtin_profiles.dart';
import 'package:nexus/routing/routing_models.dart';

Future<void> main() async {
  final raw = File(Platform.environment['SUB_FILE']!).readAsStringSync().trim();
  var payload = raw;
  if (!raw.contains('://')) {
    try {
      payload = utf8.decode(base64.decode(raw));
    } catch (_) {}
  }
  final profiles = MultiFormatImporter().import(payload).profiles;
  stdout.writeln('imported ${profiles.length} profiles');

  var port = 20910;
  for (final p in profiles) {
    final label = p.name.replaceAll('\n', ' ');
    if (p.transport == Transport.xhttp) {
      stdout.writeln('SKIP-XHTTP  $label');
      continue;
    }
    if (p.server.contains(':')) {
      stdout.writeln('SKIP-V6     $label');
      continue;
    }
    port++;
    final sb = SingBoxConfigGenerator().generate(
      runnableProfiles: [p],
      routing: BuiltinRoutingProfiles.all().first,
      dns: DnsSettings(mode: DnsMode.automatic),
      selectedTag: 'node:${p.id}',
      socksUpstreams: {p.id: (host: '127.0.0.1', port: port)},
    );
    final m = jsonDecode(jsonEncode(sb)) as Map<String, dynamic>;
    (m['inbounds'] as List).add({
      'type': 'socks',
      'tag': 'probe-in',
      'listen': '127.0.0.1',
      'listen_port': port,
    });
    final dir = await Directory.systemTemp.createTemp('sbprobe');
    final f = File('${dir.path}${Platform.pathSeparator}c.json');
    await f.writeAsString(jsonEncode(m));
    Process? proc;
    try {
      proc = await Process.start(
          'cores${Platform.pathSeparator}windows-x64${Platform.pathSeparator}sing-box.exe',
          ['run', '-c', f.path, '--disable-color']);
      final slog = StringBuffer();
      proc.stdout.transform(utf8.decoder).listen(slog.write);
      proc.stderr.transform(utf8.decoder).listen(slog.write);
      await Future<void>.delayed(const Duration(seconds: 3));
      final r = await LatencyTester().testHttpViaSocksProxy(
          '127.0.0.1', port, 'http://www.gstatic.com/generate_204',
          timeout: const Duration(seconds: 15));
      stdout.writeln('${r.ok ? "PASS" : "FAIL"}  $label  '
          '(${p.protocol.name}/${p.transport.name} '
          '/${p.security.name}) kind=${r.errorKind} '
          '${r.latencyMs ?? '-'}ms');
      if (!r.ok) {
        final detail = (r.detail ?? '')
            .replaceAll(RegExp(r'[0-9a-f]{8}-[0-9a-f-]{27}'), '<u>');
        final tail = slog
            .toString()
            .split('\n')
            .where((l) => l.contains('rror') || l.contains('atal'))
            .take(3)
            .join(' | ');
        stdout.writeln('      probe: ${detail.isEmpty ? "-" : detail}');
        if (tail.isNotEmpty) stdout.writeln('      log: $tail');
      }
    } finally {
      proc?.kill();
      await dir.delete(recursive: true);
      await Future<void>.delayed(const Duration(milliseconds: 400));
    }
  }
  exit(0);
}
