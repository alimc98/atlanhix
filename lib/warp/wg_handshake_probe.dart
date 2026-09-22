import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// v0.4.9 §user — REAL WireGuard handshake probe.
///
/// The previous scanner sent a fake 148-byte "initiation-shaped" packet;
/// every honest endpoint (Cloudflare included) validates the Noise-IK MAC
/// and drops it SILENTLY, so the scan always reported "no endpoint
/// answered". This module builds a genuine `type 1` initiation packet
/// (Noise_IKpsk2) with the account's own static key and treats a `type 2`
/// response (or a cookie reply) as liveness + RTT proof.
///
/// Key crypto detail: WireGuard's "HMAC" in the whitepaper is keyed
/// BLAKE2s-256 (BLAKE2 has native keying) — package:cryptography exposes
/// exactly that as `Blake2s.calculateMac`. Its `Hmac.blake2s` would be RFC
/// 2104 HMAC over BLAKE2s, which WG does NOT use; don't "fix" this back.
///
/// Packet layout (148 bytes):
///   [0]      type = 1
///   [1..3]   reserved zeros
///   [4..7]   sender index (LE uint32)
///   [8..39]  unencrypted ephemeral public key (32)
///   [40..87] encrypted_static = AEAD(chain, static_pub, aad=hash) (32+16)
///   [88..115] encrypted_timestamp = AEAD(chain, TAI64N, aad=hash) (12+16)
///   [116..131] MAC1 = keyed-BLAKE2s-16 over bytes[0..116]
///   [132..147] MAC2 = zeros (no cookie yet)
class WgHandshakeProbe {
  WgHandshakeProbe._();

  static const _protocolName = 'Noise_IKpsk2_25519_ChaChaPoly_BLAKE2s';
  static const _labelMac1 = 'mac1----';
  static const _wgIdentifier = 'WireGuard v1 zx2c4 Jason@zx2c4.com';

  static final _blake2s = Blake2s();
  static final _aead = Chacha20.poly1305Aead();
  static final _x25519 = X25519();

  /// WG "HMAC" = keyed BLAKE2s-256.
  static Future<List<int>> _mac(List<int> key, List<int> data) async =>
      (await _blake2s.calculateMac(data, secretKey: SecretKey(key))).bytes;

  /// Plain (unkeyed) BLAKE2s-256.
  static Future<List<int>> _hash(List<int> data) async =>
      (await _blake2s.hash(data)).bytes;

  /// WireGuard KDF with TWO outputs (wireguard-go KDF2):
  ///   prk = MAC(key, data)
  ///   t0  = MAC(prk, [0x1])        ← new chain key
  ///   t1  = MAC(prk, t0 ‖ [0x2])   ← message key
  static Future<(List<int>, List<int>)> _kdf2(
      List<int> key, List<int> data) async {
    final prk = await _mac(key, data);
    final t0 = await _mac(prk, [0x1]);
    final t1 = await _mac(prk, [...t0, 0x2]);
    return (t0, t1);
  }

  /// X25519(key, remotePublic).
  static Future<List<int>> _dh(
      List<int> privSeed, List<int> remotePublic) async {
    final kp = await _x25519.newKeyPairFromSeed(privSeed);
    final shared = await _x25519.sharedSecretKey(
      keyPair: kp,
      remotePublicKey:
          SimplePublicKey(remotePublic, type: KeyPairType.x25519),
    );
    return await shared.extractBytes();
  }

  /// Builds the 148-byte Noise-IK initiation packet.
  ///
  /// [reserved] — Cloudflare WARP carries the 3-byte client_id here on EVERY
  /// packet (initiation included); zeros make the endpoint drop the packet
  /// SILENTLY (device evidence: scanner said "no endpoint answered" with a
  /// crypto-correct handshake that lacked the reserved id).
  static Future<Uint8List> buildInitiation({
    required List<int> initiatorStaticPrivate,
    required List<int> responderStaticPublic,
    List<int>? reserved,
    int? senderIndex,
  }) async {
    final idx =
        senderIndex ?? DateTime.now().microsecondsSinceEpoch & 0xFFFFFFFF;

    // Chain + hash bootstrap (whitepaper §5.2):
    //   c = HASH(CONSTRUCTION)            — PLAIN hash, NOT keyed!
    //   h = HASH(c ‖ IDENTIFIER)
    var c = await _hash(_protocolName.codeUnits);
    var h = await _hash([...c, ..._wgIdentifier.codeUnits]);
    h = await _hash([...h, ...responderStaticPublic]);

    // Ephemeral keypair.
    final eph = await _x25519.newKeyPair();
    final ephPub = await eph.extractPublicKey();
    final ephPriv = await eph.extractPrivateKeyBytes();

    // h = HASH(h ‖ e_pub)
    h = await _hash([...h, ...ephPub.bytes]);

    // Our static keypair (the stored WG private key is the x25519 seed).
    final my = await _x25519.newKeyPairFromSeed(initiatorStaticPrivate);
    final myPub = await my.extractPublicKey();
    final myPriv = await my.extractPrivateKeyBytes();

    // 1) (c, k) = KDF(c, DH(e, rs)) → encrypted_static
    final (c1, k1) = await _kdf2(c, await _dh(ephPriv, responderStaticPublic));
    c = c1;
    final boxStatic = await _aead.encrypt(
      myPub.bytes,
      secretKey: SecretKey(k1),
      nonce: Uint8List(12), // 4 zero ‖ counter 0 (LE)
      aad: h,
    );
    // h = HASH(h ‖ encrypted_static)
    h = await _hash(
        [...h, ...boxStatic.cipherText, ...boxStatic.mac.bytes]);

    // 2) (c, k) = KDF(c, DH(is, rs)) → encrypted_timestamp
    final (c2, k2) =
        await _kdf2(c, await _dh(myPriv, responderStaticPublic));
    final boxTs = await _aead.encrypt(
      _tai64n(),
      secretKey: SecretKey(k2),
      nonce: Uint8List(12),
      aad: h,
    );

    // Header + bodies (before MAC1): 116 bytes.
    final body = BytesBuilder();
    body.addByte(1); // type: initiation
    // Cloudflare WARP: the 3-byte client id rides here on every packet.
    final res = reserved ?? const <int>[];
    body.addByte(res.length > 0 ? res[0] & 0xFF : 0);
    body.addByte(res.length > 1 ? res[1] & 0xFF : 0);
    body.addByte(res.length > 2 ? res[2] & 0xFF : 0);
    final idxB = ByteData(4)..setUint32(0, idx, Endian.little);
    body.add(idxB.buffer.asUint8List());
    body.add(ephPub.bytes);
    body.add(boxStatic.cipherText);
    body.add(boxStatic.mac.bytes);
    body.add(boxTs.cipherText);
    body.add(boxTs.mac.bytes);
    assert(body.length == 116);

    // MAC1 = keyed-BLAKE2s-16(key = HASH(LABEL_MAC1 || respPub), msg = body)
    final mac1Key =
        await _hash([..._labelMac1.codeUnits, ...responderStaticPublic]);
    final mac1 =
        (await _mac(mac1Key, body.toBytes())).sublist(0, 16);

    final out = BytesBuilder();
    out.add(body.toBytes());
    out.add(mac1);
    out.add(Uint8List(16)); // MAC2 zeros
    assert(out.length == 148);
    return out.toBytes();
  }

  /// Probes one endpoint: sends [packet] and waits for a `type 2` response
  /// or cookie reply within [timeout]. Returns the RTT, or null when silent.
  static Future<Duration?> probe(
    String host,
    int port,
    Uint8List packet, {
    Duration timeout = const Duration(milliseconds: 900),
    RawDatagramSocket? socket,
  }) async {
    final own = socket == null;
    final RawDatagramSocket sock;
    try {
      sock = socket ?? await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    } on SocketException {
      return null;
    }
    try {
      final c = Completer<Duration>();
      final sw = Stopwatch()..start();
      late final StreamSubscription<RawSocketEvent> sub;
      sub = sock.listen((e) {
        if (e == RawSocketEvent.read && !c.isCompleted) {
          final d = sock.receive();
          if (d != null && d.data.length >= 4) {
            final t = d.data[0];
            if (t == 2 || t == 3) c.complete(sw.elapsed);
          }
        }
      });
      sock.send(packet, InternetAddress(host), port);
      final timer = Timer(timeout, () {
        if (!c.isCompleted) c.completeError(TimeoutException('no wg reply'));
      });
      try {
        return await c.future;
      } on TimeoutException {
        return null;
      } finally {
        timer.cancel();
        await sub.cancel();
      }
    } on SocketException {
      return null;
    } finally {
      if (own) sock.close();
    }
  }

  /// TAI64N timestamp (12 bytes big-endian) — WG wire format.
  static Uint8List _tai64n() {
    final now = DateTime.now().toUtc().microsecondsSinceEpoch;
    final seconds = now ~/ 1000000 + 0x400000000000000a;
    final nano = (now % 1000000) * 1000;
    final bd = ByteData(12);
    bd.setUint64(0, seconds, Endian.big);
    bd.setUint32(8, nano & 0xFFFFFFFF, Endian.big);
    return bd.buffer.asUint8List();
  }
}
