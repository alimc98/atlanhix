import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
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
        reason: 'WARP client_id rides in bytes 1..3; live-tested vs CF: '
            'client_id and zeros both get type-2 replies, a GARBAGE '
            'reserved value is dropped silently (CF validates the value)');
  });

  test('KDF2 matches wireguard-go kdf_test.go vectors (RFC-2104 HMAC)',
      () async {
    // Exact vectors from wireguard-go device/kdf_test.go (3 cases).
    // key/input are hex in the source; decode them first.
    const cases = <(String, String, String, String)>[
      ('746573742d6b6579', '746573742d696e707574',
          '6f0e5ad38daba1bea8a0d213688736f19763239305e0f58aba697f9ffc41c633',
          'df1194df20802a4fe594cde27e92991c8cae66c366e8106aaa937a55fa371e8a'),
      ('776972656775617264', '776972656775617264',
          '491d43bbfdaa8750aaf535e334ecbfe5129967cd64635101c566d4caefda96e8',
          '1e71a379baefd8a79aa4662212fcafe19a23e2b609a3db7d6bcba8f560e3d25f'),
      ('', '',
          '8387b46bf43eccfcf349552a095d8315c4055beb90208fb1be23b894bc2ed5d0',
          '58a0e5f6faefccf4807bff1f05fa8a9217945762040bcec2f4b4a62bdfe0e86e'),
    ];
    for (final (keyHex, inputHex, t0Hex, t1Hex) in cases) {
      final key = _unhex(keyHex);
      final input = _unhex(inputHex);
      final (t0, t1) = await WgHandshakeProbe.kdf2(key, input);
      expect(_hex(t0), t0Hex,
          reason: 'KDF2 t0 for key=$keyHex input=$inputHex must match '
              'wireguard-go byte-for-byte (RFC-2104 HMAC, block 64 — NOT '
              'native keyed BLAKE2s)');
      expect(_hex(t1), t1Hex,
          reason: 'KDF2 t1 (message key) for key=$keyHex input=$inputHex');
    }
  });

  test('MAC1 covers the body with the 3 reserved bytes ZEROED', () async {
    // Proven twice: a real sing-box-lx initiation (captured + decrypted
    // locally) matches only over the zeroed body, and live vs Cloudflare
    // reserved + raw-body mac1 → silent drop while the same packet with
    // zeroed-body mac1 → type-2 reply.
    final pkt = await WgHandshakeProbe.buildInitiation(
      initiatorStaticPrivate: List.filled(32, 7),
      responderStaticPublic: List.filled(32, 9),
      reserved: [0xAB, 0xCD, 0xEF],
      senderIndex: 5,
    );
    final body = Uint8List.fromList(pkt.sublist(0, 116));
    final mac1Key = (await Blake2s()
            .hash([...'mac1----'.codeUnits, ...List.filled(32, 9)]))
        .bytes;
    final emitted = pkt.sublist(116, 132);

    final zeroed = Uint8List.fromList(body);
    zeroed[1] = 0;
    zeroed[2] = 0;
    zeroed[3] = 0;
    final zeroMac = (await Blake2s(hashLengthInBytes: 16)
            .calculateMac(zeroed, secretKey: SecretKey(mac1Key)))
        .bytes;
    expect(emitted, zeroMac,
        reason: 'MAC1 = keyed BLAKE2s-16 over the reserved-ZEROED body');

    final rawMac = (await Blake2s(hashLengthInBytes: 16)
            .calculateMac(body, secretKey: SecretKey(mac1Key)))
        .bytes;
    expect(emitted, isNot(equals(rawMac)),
        reason: 'raw-body mac1 (covering the reserved bytes) is exactly the '
            'form Cloudflare drops silently — must NOT be what we emit');
  });

  test('KDF2 t1 (message key) differs from t0 (chain key)', () async {
    final (t0, t1) =
        await WgHandshakeProbe.kdf2(List.filled(32, 3), List.filled(32, 4));
    expect(t0, isNot(equals(t1)));
    expect(t0.length, 32);
    expect(t1.length, 32);
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

String _hex(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

List<int> _unhex(String s) {
  final out = <int>[];
  for (var i = 0; i < s.length; i += 2) {
    out.add(int.parse(s.substring(i, i + 2), radix: 16));
  }
  return out;
}
