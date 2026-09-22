// One-shot app-socket DNS matrix on the DEVICE: for every resolver, test
// TCP:53 reachability and UDP:53 answer, with byte-level logs. Built for the
// 'why does the app not get what nc gets' question. Run: dart run tool/dns_matrix.dart
import 'dart:async';
import 'dart:io';


import 'package:nexus/core/dns_scanner.dart';

Future<void> main() async {
  const resolvers = [
    '178.22.122.100', '185.55.226.26', '94.103.125.150', '8.8.8.8', '1.1.1.1',
  ];
  for (final r in resolvers) {
    // 1) raw TCP reachability (no DNS semantics)
    String tcp;
    try {
      final s = await Socket.connect(InternetAddress(r), 53,
          timeout: const Duration(seconds: 4));
      s.destroy();
      tcp = 'OPEN';
    } catch (e) {
      tcp = e.runtimeType.toString();
    }
    // 2) raw UDP send + manual receive (bypass DnsScanner entirely)
    String udpRaw;
    try {
      final sock = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      final q = _query('n2.meta-design.ir');
      final n = sock.send(q, InternetAddress(r), 53);
      final completer = Completer();
      Timer(const Duration(seconds: 4), () {
        if (!completer.isCompleted) completer.complete('TIMEOUT');
      });
      sock.listen((e) {
        if (e == RawSocketEvent.read) {
          final dg = sock.receive();
          if (dg != null && !completer.isCompleted) {
            completer.complete('REPLY ${dg.data.length}B');
          }
        }
      });
      udpRaw = 'sent=$n ${await completer.future}';
      sock.close();
    } catch (e) {
      udpRaw = 'EXC $e';
    }
    // 3) DnsScanner.resolve (app's actual code path)
    final viaScanner =
        await DnsScanner().resolve('n2.meta-design.ir', server: r);
    final viaScannerTcp =
        await DnsScanner().resolve('n2.meta-design.ir', server: r, tcp: true);
    stdout.writeln('$r | tcp53=$tcp | udp=$udpRaw | A(udp)=${viaScanner.join(",")}|A(tcp)=${viaScannerTcp.join(",")}');
  }
  exit(0);
}

List<int> _query(String name) {
  final out = <int>[0xAB, 0xCD, 0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 0];
  for (final part in name.split('.')) {
    out.add(part.length);
    out.addAll(part.codeUnits);
  }
  out.addAll([0, 0, 1, 0, 1]);
  return out;
}
