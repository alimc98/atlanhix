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
/// Key crypto details (verified against BOTH wireguard-go
/// `CreateMessageInitiation` and Cloudflare's boringtun
/// `receive_handshake_initialization` — the code that runs WARP's servers):
///
/// 1. The KDF is RFC-2104 HMAC over BLAKE2s-256 with block size 64.
///    boringtun says it outright: "RFC 2401 HMAC+Blake2s, NOT to be
///    confused with *keyed* Blake2s". Native keyed-BLAKE2s
///    (`Blake2s.calculateMac`) is a different function and silently
///    derives different keys — don't switch to it.
/// 2. After mixing the ephemeral public key into the hash, WireGuard
///    ALSO mixes it into the chain key (`c = KDF1(c, eph_pub)` — see
///    wireguard-go `handshake.mixKey(msg.Ephemeral)` and boringtun's
///    `chaining_key = HMAC(HMAC(c, eph_pub), 0x1)`). Vanilla Noise's
///    `e` token does not do this; WireGuard does. Missing this step
///    yields a wrong AEAD key and a SILENT drop at the server.
/// 3. MAC1 is keyed BLAKE2s with a **16-byte output** (`blake2s.New128`
///    / `Blake2sMac<16>`), not BLAKE2s-32 truncated to 16: the digest
///    length lives in BLAKE2's parameter block, so the two differ.
///
/// Packet layout (148 bytes):
///   [0]      type = 1
///   [1..3]   reserved zeros
///   [4..7]   sender index (LE uint32)
///   [8..39]  unencrypted ephemeral public key (32)
///   [40..87] encrypted_static = AEAD(chain, static_pub, aad=hash) (32+16)
///   [88..115] encrypted_timestamp = AEAD(chain, TAI64N, aad=hash) (12+16)
///   [116..131] MAC1 = keyed-BLAKE2s-16 over bytes[0..116] (reserved
///              bytes zeroed for the MAC — see buildInitiation)
///   [132..147] MAC2 = zeros (no cookie yet)
class WgHandshakeProbe {
  WgHandshakeProbe._();

  static const _protocolName = 'Noise_IKpsk2_25519_ChaChaPoly_BLAKE2s';
  static const _labelMac1 = 'mac1----';
  static const _wgIdentifier = 'WireGuard v1 zx2c4 Jason@zx2c4.com';

  static final _blake2s = Blake2s();
  static final _blake2s16 = Blake2s(hashLengthInBytes: 16);
  static final _aead = Chacha20.poly1305Aead();
  static final _x25519 = X25519();

  /// Plain (unkeyed) BLAKE2s-256.
  static Future<List<int>> _hash(List<int> data) async =>
      (await _blake2s.hash(data)).bytes;

  /// RFC-2104 HMAC over BLAKE2s-256 with block size **64** (BLAKE2s block).
  ///
  /// wireguard-go: `hmac.New(blake2s.New256, key)` — Go pads to the hash's
  /// BlockSize, which is 64 for BLAKE2s. boringtun: `SimpleHmac<Blake2s256>`,
  /// also B=64.
  ///
  /// package:cryptography's `Hmac(Blake2s())` must NOT be used: its
  /// `Blake2s.blockLengthInBytes` reports 32 (algorithms.dart:774 — a
  /// package bug), so it would pad the key to 32 bytes and produce a
  /// different MAC. Hand-rolled here with the correct 64.
  static Future<List<int>> _hmac(List<int> key, List<int> data) async {
    const b = 64;
    var k = key;
    if (k.length > b) k = await _hash(k); // RFC 2104: long keys get hashed
    if (k.length < b) k = [...k, ...List.filled(b - k.length, 0)];
    final ipad = [for (final x in k) x ^ 0x36];
    final opad = [for (final x in k) x ^ 0x5c];
    final inner = await _hash([...ipad, ...data]);
    return _hash([...opad, ...inner]);
  }

  /// WireGuard KDF1(key, data) = HMAC(HMAC(key, data), 0x01).
  static Future<List<int>> _kdf1(List<int> key, List<int> data) async =>
      _hmac(await _hmac(key, data), const [0x01]);

  /// WireGuard KDF with TWO outputs (wireguard-go `KDF2` / boringtun):
  ///   prk = HMAC(key, data)
  ///   t0  = HMAC(prk, [0x1])         ← new chain key
  ///   t1  = HMAC(prk, t0 ‖ [0x2])    ← message key
  static Future<(List<int>, List<int>)> _kdf2(
      List<int> key, List<int> data) async {
    final prk = await _hmac(key, data);
    final t0 = await _hmac(prk, const [0x01]);
    final t1 = await _hmac(prk, [...t0, 0x02]);
    return (t0, t1);
  }

  /// Test hook: KDF2 exposed so `test/wg_handshake_probe_test.dart` can pin
  /// it with wireguard-go's own `kdf_test.go` vectors.
  static Future<(List<int>, List<int>)> kdf2(List<int> key, List<int> data) =>
      _kdf2(key, data);

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
  /// [reserved] — the 3-byte WARP `client_id`, carried in bytes[1..3] of
  /// every packet (initiation included). This matches what real WARP
  /// clients do: a captured sing-box-lx initiation carries
  /// reserved=[197,77,221] (= client_id) while its MAC1 is computed over
  /// the zeroed body.
  ///
  /// Both forms are accepted by Cloudflare, but ONLY with mac1 computed
  /// over the zeroed body (that is handled inside this builder):
  ///   * reserved = zeros       → type-2 reply (live-tested)
  ///   * reserved = client_id   → type-2 reply (lx does exactly this)
  ///   * reserved = client_id + mac1 over the raw body → SILENT drop
  ///     (this was the original scanner failure mode: the handshake was
  ///     "crypto-correct" but the MAC covered the reserved bytes).
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

    // c = KDF1(c, e_pub) — WireGuard mixes the ephemeral public key into the
    // CHAIN KEY as well (wireguard-go: `handshake.mixKey(msg.Ephemeral[:])`
    // right before mixHash; boringtun: `chaining_key = HMAC(HMAC(c, e_pub),
    // 0x01)`). Vanilla Noise's `e` token only mixHash-es; WireGuard does
    // BOTH. Skipping this derives a wrong AEAD key → server drops silently.
    c = await _kdf1(c, ephPub.bytes);

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
    body.addByte(res.isNotEmpty ? res[0] & 0xFF : 0);
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

    // MAC1 = keyed-BLAKE2s with a **16-byte OUTPUT**
    // (wireguard-go `blake2s.New128(key)` / boringtun `Blake2sMac<16>`),
    // key = HASH(LABEL_MAC1 ‖ respPub), msg = body[0..116] **with the three
    // reserved bytes ZEROED**.
    //
    // The reserved-zeroing was proven empirically, twice:
    //  * local: a real sing-box-lx initiation carrying reserved=[197,77,221]
    //    mismatches over the raw body but MATCHES over the zeroed body
    //    (senders MAC the zeroed layout; `reserved` is injected into the
    //    transmitted bytes separately).
    //  * live vs CF: reserved + mac1-over-raw-body → silent drop;
    //    the same packet with mac1-over-zeroed-body → type-2 reply.
    //
    // NOT BLAKE2s-32-truncated-to-16: the digest length lives in BLAKE2's
    // parameter block, so keyed-BLAKE2s-16(key, m) != keyed-BLAKE2s-32(key,
    // m)[0..16]. The server verifies with the 16-byte form.
    final mac1Key =
        await _hash([..._labelMac1.codeUnits, ...responderStaticPublic]);
    final mac1Body = Uint8List.fromList(body.toBytes());
    mac1Body[1] = 0;
    mac1Body[2] = 0;
    mac1Body[3] = 0;
    final mac1 =
        (await _blake2s16.calculateMac(mac1Body,
                secretKey: SecretKey(mac1Key)))
            .bytes;

    final out = BytesBuilder();
    out.add(body.toBytes());
    out.add(mac1);
    out.add(Uint8List(16)); // MAC2 zeros
    assert(out.length == 148);
    return out.toBytes();
  }

  /// Probes one endpoint: sends [packet] and waits for a `type 2` response
  /// or cookie reply within [timeout]. Returns the RTT, or null when silent.
  ///
  /// v0.5.0 §user (WarpServer-range scanner): [onSend] fires the instant the
  /// initiation leaves the socket — the scanner cancels its budget timer on
  /// the FIRST answer instead of waiting out the full per-candidate timeout
  /// sequentially. Pass your own [socket] when sweeping many endpoints; the
  /// caller owns (and must close) it. [socket] is required when [onSend] is
  /// given (a fresh per-call socket would never receive the caller's reply).
  static Future<Duration?> probe(
    String host,
    int port,
    Uint8List packet, {
    Duration timeout = const Duration(milliseconds: 900),
    RawDatagramSocket? socket,
    void Function()? onSend,
  }) async {
    assert(
        socket != null || onSend == null,
        'probe(onSend) needs an explicit socket — '
        'a per-call socket never receives the caller\'s reply');
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
      onSend?.call();
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
