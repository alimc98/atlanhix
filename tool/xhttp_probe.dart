// Does the BUNDLED sing-box 1.14 accept any xhttp/splithttp form? Try several
// transport spellings against `sing-box check` to see which (if any) parse.
import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  final base = {
    'log': {'level': 'error'},
    'inbounds': [
      {'type': 'mixed', 'tag': 'm', 'listen': '127.0.0.1', 'listen_port': 2080}
    ],
    'outbounds': [
      {'type': 'direct', 'tag': 'direct'},
    ],
    'route': {'final': 'direct'},
  };
  final variants = <String, Map<String, dynamic>>{
    'xhttp-type': {
      'type': 'vless',
      'tag': 'p',
      'server': '1.2.3.4',
      'server_port': 443,
      'uuid': '00000000-0000-0000-0000-000000000000',
      'transport': {'type': 'xhttp', 'mode': 'auto', 'path': '/api', 'host': 'x.com'},
      'tls': {'enabled': true, 'server_name': 'x.com'},
    },
    'splithttp-type': {
      'type': 'vless',
      'tag': 'p',
      'server': '1.2.3.4',
      'server_port': 443,
      'uuid': '00000000-0000-0000-0000-000000000000',
      'transport': {'type': 'splithttp', 'mode': 'auto', 'path': '/api'},
      'tls': {'enabled': true, 'server_name': 'x.com'},
    },
    'http-type': {
      'type': 'vless',
      'tag': 'p',
      'server': '1.2.3.4',
      'server_port': 443,
      'uuid': '00000000-0000-0000-0000-000000000000',
      'transport': {'type': 'http', 'path': '/api', 'host': ['x.com']},
      'tls': {'enabled': true, 'server_name': 'x.com'},
    },
    'httpupgrade-type': {
      'type': 'vless',
      'tag': 'p',
      'server': '1.2.3.4',
      'server_port': 443,
      'uuid': '00000000-0000-0000-0000-000000000000',
      'transport': {'type': 'httpupgrade', 'path': '/api', 'host': 'x.com'},
      'tls': {'enabled': true, 'server_name': 'x.com'},
    },
  };
  for (final e in variants.entries) {
    final cfg = jsonDecode(jsonEncode(base)) as Map<String, dynamic>;
    (cfg['outbounds'] as List).add(e.value);
    final f = File('C:/Users/Hosna/AppData/Local/Temp/sbx_${e.key}.json');
    await f.writeAsString(jsonEncode(cfg));
    final r = await Process.run(
        'cores/windows-x64/sing-box.exe', ['check', '-c', f.path]);
    final out = '${r.stdout}${r.stderr}'.trim().replaceAll('\n', ' | ');
    stdout.writeln('${e.key.padRight(18)} rc=${r.exitCode}  ${out.isEmpty ? "OK" : out}');
  }
}
