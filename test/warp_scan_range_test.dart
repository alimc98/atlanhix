import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/warp/wg_handshake_probe.dart';

void main() {
  // v0.5.0 §user — the endpoint scanner now sweeps the FULL /24 WARP
  // class-C networks. The old code sent a fake initiation (MAC-invalid →
  // silently dropped) and scored "silent" endpoints; these tests exercise
  // the REAL handshake probe over a real socket against loopback UDP
  // endpoints we fully control.
  group('WARP endpoint scanner plumbing (real probe, loopback)', () {
    test('an answering endpoint wins the sweep (onSend cancels the budget)',
        () async {
      // The responder is a SEPARATE socket — probe() needs exclusive listen
      // rights on the client socket it is handed (the real scanner's sweep
      // socket is never shared with a responder either).
      final responder =
          await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
      final client =
          await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() {
        responder.close();
        client.close();
      });
      responder.listen((RawSocketEvent e) {
        if (e != RawSocketEvent.read) return;
        final d = responder.receive();
        if (d == null) return;
        // A 148-byte type-2-shaped reply: probe() treats any datagram whose
        // first byte is 2 as a handshake response.
        responder.send(List<int>.filled(148, 0)..[0] = 2, d.address, d.port);
      });

      // A packet whose MAC the "server" above never checks — enough for
      // the plumbing test; cryptographic validity is covered by the live
      // e2e (tool/warp_e2e_*) against Cloudflare itself.
      final pkt = List<int>.filled(148, 0)..[0] = 1;

      var onSendFired = false;
      final sw = Stopwatch()..start();
      final rtt = await WgHandshakeProbe.probe(
        '127.0.0.1',
        responder.port,
        Uint8List.fromList(pkt),
        timeout: const Duration(milliseconds: 300),
        socket: client,
        onSend: () => onSendFired = true,
      );
      sw.stop();
      expect(onSendFired, isTrue,
          reason: 'the scanner cancels its budget on this hook');
      expect(rtt, isNotNull, reason: 'a type-2 replier must win the sweep');
      expect(rtt!.inMilliseconds, lessThan(300),
          reason: 'the answer must come back well inside the budget');
      expect(sw.elapsed, lessThan(const Duration(milliseconds: 250)));
    });

    test('a silent endpoint times out and returns null (sweep skip path)',
        () async {
      final client =
          await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(client.close);
      final pkt = Uint8List(148)..[0] = 1;
      final rtt = await WgHandshakeProbe.probe(
        '127.0.0.1',
        9, // discard port on loopback — nobody answers
        pkt,
        timeout: const Duration(milliseconds: 150),
        socket: client,
      );
      expect(rtt, isNull);
    });

    test('RTT ordering: the fastest answering endpoint sorts first',
        () async {
      // Two responders; the second delays 40 ms — the scanner's winner is
      // the minimum RTT, so results must sort accordingly. Each probe gets
      // its OWN client socket (exclusive listen), the responders live on
      // separate server sockets.
      final fast =
          await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
      final slow =
          await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() {
        fast.close();
        slow.close();
      });
      Future<void> reply(RawDatagramSocket s, Duration delay) async {
        s.listen((RawSocketEvent e) {
          if (e != RawSocketEvent.read) return;
          final d = s.receive();
          if (d == null) return;
          Future<void>.delayed(delay).then((_) =>
              s.send(List<int>.filled(148, 0)..[0] = 2, d.address, d.port));
        });
      }

      await reply(fast, Duration.zero);
      await reply(slow, const Duration(milliseconds: 40));
      final pkt = Uint8List(148)..[0] = 1;
      final cFast =
          await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
      final cSlow =
          await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() {
        cFast.close();
        cSlow.close();
      });
      final rFast = await WgHandshakeProbe.probe('127.0.0.1', fast.port, pkt,
          timeout: const Duration(seconds: 2), socket: cFast);
      final rSlow = await WgHandshakeProbe.probe('127.0.0.1', slow.port, pkt,
          timeout: const Duration(seconds: 2), socket: cSlow);
      expect(rFast, isNotNull);
      expect(rSlow, isNotNull);
      expect(rFast!.compareTo(rSlow!), lessThan(0),
          reason: 'the sweep sorts by RTT; the faster endpoint is the winner');
    });
  });
}
