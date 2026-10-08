// Standalone validation: feed our generated config to the REAL binary.
import 'dart:convert';
import 'dart:io';
import 'package:nexus/core/runtime/external_runtimes.dart';
import 'package:nexus/core/runtime/binary_manager.dart';
import 'package:nexus/domain/entities/proxy_profile.dart';

Future<void> main() async {
  final wd = Directory(Platform.environment['MDVPN_WD']!);
  final rt = MasterDnsVpnRuntime(
    binaryManager: BinaryManager(userCoresDir: wd.path),
    workDir: wd,
    socksPort: 18777,
  );
  rt.profile = ProxyProfile(
    id: 'validate',
    name: 'validation',
    server: 'validate.invalid',
    port: 53,
    protocol: ProxyProtocol.masterDnsVpn,
    password: 'validation-key-not-a-real-secret',
    rawParams: {'DOMAINS': 'validate.invalid', 'DATA_ENCRYPTION_METHOD': '1'},
  );
  final cfg = await rt.writeConfig();
  // ignore: avoid_print
  print('CONFIG-FILE: ${cfg.path}');
  // Prove the secret is not in the file:
  final text = await cfg.readAsString();
  // ignore: avoid_print
  print('KEY-IN-CONFIG: ${text.contains('validation-key-not-a-real-secret')}');
  // Real start() path: sidecars (resolvers file) + launch args.
  await rt.prepareSidecars();
  final args = rt.launchArgs(cfg);
  // Args contain the secret; mask it in the echo:
  // ignore: avoid_print
  print('ARGV-SHAPE: ${args.map((a) => a == 'validation-key-not-a-real-secret' ? '<redacted>' : a).join(' ')}');
  final p = await Process.start(wd.path + r'\masterdnsvpn-client.exe', args);
  final out = <String>[];
  final sub1 = p.stdout.transform(utf8.decoder).listen(out.add);
  final sub2 = p.stderr.transform(utf8.decoder).listen(out.add);
  await Future<void>.delayed(const Duration(seconds: 12));
  p.kill();
  await sub1.cancel();
  await sub2.cancel();
  final joined = out.join('\n');
  // Redact anything that could echo the key back.
  // ignore: avoid_print
  print('CLIENT-OUTPUT-BEGIN');
  // ignore: avoid_print
  print(joined.replaceAll('validation-key-not-a-real-secret', '<redacted>').split('\n').take(30).join('\n'));
  // ignore: avoid_print
  print('CLIENT-OUTPUT-END');
  // ignore: avoid_print
  print('CONFIG-PARSED-OK: ${!joined.contains('startup failed')}');
}

