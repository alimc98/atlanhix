// Micro-control: does raw UDP egress + reply work at all on this network?
// 1) DNS query to 1.1.1.1:53 (well-known UDP echo-ish control)
// 2) garbage 4-byte datagram to a WARP endpoint (expect ICMP unreachable or
//    silence — either way we learn whether the socket reports anything)
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

Future<void> main() async {
  // --- 1) DNS control -----------------------------------------------
  final dns = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
  final q = Uint8List.fromList([
    0x12, 0x34, 0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    7, 101, 120, 97, 109, 112, 108, 101, // "example"
    3, 99, 111, 109, // "com"
    0x00, 0x00, 0x01, 0x00, 0x01,
  ]);
  final done = Completer<String>();
  dns.listen((e) {
    if (e == RawSocketEvent.read && !done.isCompleted) {
      final d = dns.receive();
      if (d != null) {
        done.complete('DNS REPLY ${d.data.length} bytes from ${d.address}');
      }
    }
  }, onError: (Object e) {
    if (!done.isCompleted) done.complete('DNS SOCKET ERROR: $e');
  });
  try {
    final n = dns.send(q, InternetAddress('1.1.1.1'), 53);
    print('DNS sent $n bytes');
  } catch (e) {
    print('DNS send threw: $e');
  }
  final r1 = await Future.any([
    done.future,
    Future.delayed(const Duration(seconds: 4), () => 'DNS TIMEOUT'),
  ]);
  print(r1);
  dns.close();

  // --- 2) WARP endpoint, tiny garbage datagram ----------------------
  final s2 = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
  final done2 = Completer<String>();
  s2.listen((e) {
    if (e == RawSocketEvent.read && !done2.isCompleted) {
      final d = s2.receive();
      if (d != null) {
        done2.complete('WG REPLY ${d.data.length}B type=${d.data.isNotEmpty ? d.data[0] : -1} '
            'from ${d.address}');
      }
    }
  }, onError: (Object e) {
    if (!done2.isCompleted) done2.complete('WG SOCKET ERROR: $e');
  });
  try {
    final n = s2.send(Uint8List.fromList([1, 0, 0, 0]),
        InternetAddress('162.159.192.1'), 2408);
    print('WG garbage sent $n bytes');
  } catch (e) {
    print('WG send threw: $e');
  }
  final r2 = await Future.any([
    done2.future,
    Future.delayed(const Duration(seconds: 4), () => 'WG TIMEOUT (silent)'),
  ]);
  print(r2);
  s2.close();

  // --- 3) is any local VPN/proxy interface up? ----------------------
  print('--- interfaces ---');
  for (final i in await NetworkInterface.list()) {
    for (final a in i.addresses) {
      print('${i.name}: ${a.address}');
    }
  }
}
