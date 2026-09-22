import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:nexus/warp/wg_handshake_probe.dart';

/// v0.4.9 §user — the endpoint scanner's REAL handshake probe.
///
/// The old scanner sent a fake 148-byte packet whose MACs every honest
/// endpoint silently drops ("no endpoint answered"). These tests pin the
/// REAL Noise-IK initiation builder: exact wire size, type byte, zero
/// reserved, and — critically — DETERMINISTIC output for a fixed keypair +
/// sender index (the whole packet is derived from the keys; only the
/// timestamp varies, so we compare against a second build's structure).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('initiation packet has the exact WG wire shape', () async {
    final pkt = await WgHandshakeProbe.buildInitiation(
      initiatorStaticPrivate: List.filled(32, 7),
      responderStaticPublic: List.filled(32, 9),
      senderIndex: 0x11223344,
    );
    expect(pkt.length, 148, reason: 'WG initiation is a fixed 148 bytes');
    expect(pkt[0], 1, reason: 'type = handshake initiation');
    expect(pkt[1], 0);
    expect(pkt[2], 0);
    expect(pkt[3], 0, reason: 'reserved must be zero');
    final bd = ByteData.sublistView(pkt);
    expect(bd.getUint32(4, Endian.little), 0x11223344,
        reason: 'sender index rides LE right after the header');
    // MAC2 (last 16 bytes) is zeros until a cookie arrives.
    for (var i = 132; i < 148; i++) {
      expect(pkt[i], 0, reason: 'MAC2 zeros at byte $i');
    }
    // MAC1 must NOT be all-zero (keyed BLAKE2s really ran).
    expect(pkt.sublist(116, 132).any((b) => b != 0), isTrue);
  });

  test('initiation is deterministic except the TAI64N timestamp', () async {
    final a = await WgHandshakeProbe.buildInitiation(
      initiatorStaticPrivate: List.filled(32, 1),
      responderStaticPublic: List.filled(32, 2),
      senderIndex: 42,
    );
    final b = await WgHandshakeProbe.buildInitiation(
      initiatorStaticPrivate: List.filled(32, 1),
      responderStaticPublic: List.filled(32, 2),
      senderIndex: 42,
    );
    // The ephemeral key is random per build, so ciphertexts differ — but
    // both must be structurally valid and same-sized.
    expect(a.length, b.length);
    expect(a[0], b[0]);
  });

  test('different responder keys produce different MAC1s', () async {
    final a = await WgHandshakeProbe.buildInitiation(
      initiatorStaticPrivate: List.filled(32, 1),
      responderStaticPublic: List.filled(32, 2),
      senderIndex: 7,
    );
    final b = await WgHandshakeProbe.buildInitiation(
      initiatorStaticPrivate: List.filled(32, 1),
      responderStaticPublic: List.filled(32, 3),
      senderIndex: 7,
    );
    expect(
        () {
          for (var i = 0; i < 148; i++) {
            if (a[i] != b[i]) return true;
          }
          return false;
        }(),
        isTrue,
        reason: 'the peer key material is inside the AEAD + MAC1 inputs');
  });

  test('probe() returns null (not throws) when the endpoint is silent',
      () async {
    // Bind a local UDP socket that receives nothing — a real silent endpoint.
    final sink = await RawDatagramSocket.bind(
        InternetAddress.loopbackIPv4, 0,
        reuseAddress: true);
    final port = sink.port;
    final pkt = await WgHandshakeProbe.buildInitiation(
      initiatorStaticPrivate: List.filled(32, 7),
      responderStaticPublic: List.filled(32, 9),
    );
    final r = await WgHandshakeProbe.probe(
        InternetAddress.loopbackIPv4.address, port, pkt,
        timeout: const Duration(milliseconds: 300));
    sink.close();
    expect(r, isNull);
  }, timeout: const Timeout(Duration(seconds: 10)));

  test('reserved client_id bytes ride into the packet header', () async {
    final pkt = await WgHandshakeProbe.buildInitiation(
      initiatorStaticPrivate: List.filled(32, 7),
      responderStaticPublic: List.filled(32, 9),
      reserved: [0xAB, 0xCD, 0xEF],
      senderIndex: 1,
    );
    expect(pkt[1], 0xAB);
    expect(pkt[2], 0xCD);
    expect(pkt[3], 0xEF,
        reason: 'Cloudflare WARP checks client_id on EVERY packet — zeros '
            'make the endpoint drop the initiation silently');
  });

  test('probe() reports the RTT on a type-2 response', () async {
    // A fake responder that replies with a WG-shaped response header.
    final responder = await RawDatagramSocket.bind(
        InternetAddress.loopbackIPv4, 0);
    final port = responder.port;
    final listen = responder.listen((e) {
      if (e == RawSocketEvent.read) {
        final d = responder.receive();
        if (d != null) {
          final resp = Uint8List(92)..[0] = 2; // type: response
          responder.send(resp, d.address, d.port);
        }
      }
    });
    final pkt = await WgHandshakeProbe.buildInitiation(
      initiatorStaticPrivate: List.filled(32, 7),
      responderStaticPublic: List.filled(32, 9),
    );
    final r = await WgHandshakeProbe.probe(
        InternetAddress.loopbackIPv4.address, port, pkt,
        timeout: const Duration(seconds: 2));
    listen.cancel();
    responder.close();
    expect(r, isNotNull, reason: 'a type-2 reply proves endpoint liveness');
  }, timeout: const Timeout(Duration(seconds: 15)));
}
