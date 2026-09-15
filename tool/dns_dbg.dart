// DNS-path diagnostics, exact same code as app. Run: dart run tool/dns_dbg.dart
import 'dart:io';

import 'package:nexus/core/dns_scanner.dart';

Future<void> main() async {
  for (final server in ['178.22.122.100', '185.55.226.26', '8.8.8.8']) {
    for (final tcp in [false, true]) {
      final sw = Stopwatch()..start();
      try {
        final ips = await DnsScanner()
            .resolve('n2.meta-design.ir', server: server, tcp: tcp)
            .timeout(const Duration(seconds: 8));
        stdout.writeln('$server tcp=$tcp -> $ips (${sw.elapsedMilliseconds}ms)');
      } catch (e) {
        stdout.writeln('$server tcp=$tcp EXC $e (${sw.elapsedMilliseconds}ms)');
      }
    }
  }
  exit(0);
}
