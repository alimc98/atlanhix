// Ground-truth validation of the handshake probe's crypto against a REAL
// wireguard-go initiation (sing-box-lx = wireguard-go code).
//
//   dart run tool/wg_probe_validate.dart serve [port]   (default 24089)
//     — binds UDP; sing-box must point its peer public_key at
//       pub(accountPriv) and its endpoint at 127.0.0.1:<port>.
//       Parses the incoming initiation and tries to FULLY DECRYPT it with
//       this project's crypto (RFC-2104 HMAC-BLAKE2s-B64 chain + mixKey).
//       Prints mac1 MATCH/MISMATCH and per-step decrypt results.
//
//   dart run tool/wg_probe_validate.dart local
//     — spawns sing-box-lx (real wireguard-go) with its peer pointed at this
//       process, captures one initiation, validates it end-to-end, and shows
//       whether lx injects `reserved` into handshake packets.
//
//   dart run tool/wg_probe_validate.dart self
//     — builds an initiation with WgHandshakeProbe.buildInitiation and runs
//       it through the same validator logic (in-process). We hold BOTH
//       static keys (initiator = responder = account key), so a full
//       decrypt must succeed if builder and validator agree.
//
//   dart run tool/wg_probe_validate.dart hmac
//     — same, but with the tool-local independent HMAC builder (cross-check
//       that two separate implementations produce identical bytes).
//
// If `serve` validates wireguard-go's packet but `self`/`hmac` fail, the
// bug is in our builder; if `serve` fails to decrypt, our chain is wrong.
//
// NOTE: the responder role here uses pub(accountPriv) as rsPub — we cannot
// decrypt packets addressed to Cloudflare's static key (we don't hold it).
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'package:nexus/warp/wg_handshake_probe.dart';

const _protocolName = 'Noise_IKpsk2_25519_ChaChaPoly_BLAKE2s';
const _wgIdentifier = 'WireGuard v1 zx2c4 Jason@zx2c4.com';
const _labelMac1 = 'mac1----';

final _blake = Blake2s();
final _blake16 = Blake2s(hashLengthInBytes: 16);
final _x25519 = X25519();
final _aead = Chacha20.poly1305Aead();

Future<void> main(List<String> args) async {
  final mode = args.isNotEmpty ? args[0] : 'serve';
  final acct = await _loadAccount();
  final myPriv = base64.decode(acct['priv'] as String);
  final reserved = _b64(acct['clientId'] as String);
  // Responder static public = OUR pub (we hold the matching private key).
  final rsPub = await _pub(myPriv);
  stdout.writeln('account: endpoint=${acct['endpointV4']} '
      'reserved=$reserved local_rsPub=${_hex(rsPub.take(6))}…');

  if (mode == 'serve') {
    final port = args.length > 1 ? int.parse(args[1]) : 24089;
    await _serve(port, myPriv, rsPub, reserved);
  } else if (mode == 'local') {
    // End-to-end vs REAL wireguard-go (sing-box-lx) on this machine.
    await _local(myPriv, rsPub, reserved);
  } else if (mode == 'self' || mode == 'hmac') {
    final senderIdx = 0x51ab77c3;
    final pkt = mode == 'self'
        ? await WgHandshakeProbe.buildInitiation(
            initiatorStaticPrivate: myPriv,
            responderStaticPublic: rsPub,
            reserved: reserved,
            senderIndex: senderIdx,
          )
        : await buildHmacInitiation(
            initiatorStaticPrivate: myPriv,
            responderStaticPublic: rsPub,
            reserved: reserved,
            senderIndex: senderIdx,
          );
    stdout.writeln('built ${pkt.length}B initiation ($mode)');
    await _validate(pkt, myPriv, rsPub, reserved);
  }
}

/// End-to-end check against REAL wireguard-go (sing-box-lx): spawns lx with
/// its peer pointed at this process, captures ONE initiation packet and runs
/// it through [_validate]. Also reveals whether lx injects the configured
/// `reserved` bytes into the HANDSHAKE (bytes 1..3) — CF drops packets that
/// put client_id there (live-tested), so if lx sends zeros while `reserved`
/// is configured, reserved must be a transport-packet-only concept.
Future<void> _local(
    List<int> myPriv, List<int> rsPub, List<int>? reserved) async {
  const base =
      'C:\\Users\\Hosna\\AppData\\Local\\Temp\\opencode\\sbx\\lx\\'
      'sing-box-1.14.2-lx.1-windows-amd64';
  final exe = '$base\\sing-box.exe';
  if (!File(exe).existsSync()) {
    stdout.writeln('missing sing-box-lx at $exe');
    return;
  }
  final cfg = {
    'log': {'level': 'debug', 'timestamp': true},
    'dns': {
      'servers': [
        {'type': 'udp', 'server': '1.1.1.1'},
      ],
    },
    'inbounds': [
      {'type': 'mixed', 'listen': '127.0.0.1', 'listen_port': 2081},
    ],
    'endpoints': [
      {
        'type': 'wireguard',
        'tag': 'warp',
        'address': ['172.16.0.2/32'],
        // Fresh initiator identity — NOT our own key: sing-box refuses to
        // build a peer whose public key equals the endpoint's own (it ends
        // up all-zero/never-started). The validator only needs the
        // RESPONDER key (pub(myPriv) below), so this is safe.
        'private_key':
            base64.encode(await X25519().newKeyPair().then((k) => k.extractPrivateKeyBytes())),
        'mtu': 1280,
        'peers': [
          {
            'address': '127.0.0.1',
            'port': 24089,
            'public_key': base64.encode(rsPub),
            'allowed_ips': ['0.0.0.0/0', '::/0'],
            'persistent_keepalive_interval': 25,
            if (reserved != null && reserved.length == 3)
              'reserved': reserved,
          },
        ],
      },
    ],
    'outbounds': [
      {'type': 'direct', 'tag': 'direct'},
    ],
    'route': {'final': 'warp'},
  };
  final cfgFile = File(
      '${Directory.systemTemp.path}${Platform.pathSeparator}wg_local_test.json');
  await cfgFile.writeAsString(jsonEncode(cfg));

  final sock = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 24089);
  final got = Completer<Uint8List>();
  sock.listen((e) {
    stdout.writeln('    [udp event] $e');
    if (e == RawSocketEvent.read) {
      final d = sock.receive();
      if (d != null && d.data.isNotEmpty) {
        stdout.writeln('<< ${d.data.length}B from '
            '${d.address.address}:${d.port} (real wireguard-go)');
        if (!got.isCompleted) got.complete(Uint8List.fromList(d.data));
      }
    }
  }, onError: (Object e) => stdout.writeln('    [udp error] $e'));

  final proc = await Process.start(exe, ['run', '-c', cfgFile.path],
      workingDirectory: base);
  proc.stdout.transform(utf8.decoder).listen((s) {
    for (final l in s.split('\n')) {
      if (l.trim().isNotEmpty) stdout.writeln('[lx] ${l.trim()}');
    }
  });
  proc.stderr.transform(utf8.decoder).listen((s) {
    for (final l in s.split('\n')) {
      if (l.trim().isNotEmpty) stdout.writeln('[lx!] ${l.trim()}');
    }
  });

  // Generate traffic through lx so it initiates the handshake.
  await Future<void>.delayed(const Duration(seconds: 1));
  unawaited(Process.run('curl.exe', [
    '-s',
    '--max-time', '4',
    '--socks5-hostname', '127.0.0.1:2081',
    'http://www.cloudflare.com/cdn-cgi/trace',
  ]).then((r) {
    final out = (r.stdout as String).trim();
    if (out.isNotEmpty) stdout.writeln('[curl] ${out.split('\n').first}');
  }));

  Uint8List? pkt;
  try {
    pkt = await got.future.timeout(const Duration(seconds: 10));
  } on TimeoutException {
    stdout.writeln('NO initiation arrived from sing-box (10s)');
  }
  proc.kill();
  sock.close();
  if (pkt != null) {
    final f = File(
        '${Directory.systemTemp.path}${Platform.pathSeparator}lx_initiation.bin');
    f.writeAsBytesSync(pkt);
    stdout.writeln('saved packet -> ${f.path}');
    await _validate(pkt, myPriv, rsPub, reserved);
  }
}

Future<void> _serve(int port, List<int> myPriv, List<int> rsPub,
    List<int>? reserved) async {
  final sock = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, port);
  stdout.writeln('validator listening on 127.0.0.1:$port — '
      'point sing-box peer there, Ctrl+C to exit');
  sock.listen((e) {
    if (e != RawSocketEvent.read) return;
    final d = sock.receive();
    if (d == null || d.data.isEmpty) return;
    stdout.writeln('\n<< ${d.data.length}B from ${d.address.address}:'
        '${d.port} head=${_hex(d.data.take(8))}');
    _validate(d.data, myPriv, rsPub, reserved);
  });
  await Completer<void>().future;
}

Future<void> _validate(Uint8List pkt, List<int> myPriv, List<int> rsPub,
    List<int>? reserved) async {
  if (pkt.length != 148 && pkt.length < 116) {
    stdout.writeln('  BAD length ${pkt.length}');
    return;
  }
  final type = pkt[0];
  stdout.writeln('  type=$type '
      'reserved=[${pkt[1]},${pkt[2]},${pkt[3]}] '
      'expected_reserved=$reserved');
  final senderIdx = ByteData.sublistView(pkt, 4, 8).getUint32(0, Endian.little);
  stdout.writeln('  senderIndex=0x${senderIdx.toRadixString(16)}');

  // mac1 check — protocol rule: MAC over the body with bytes[1..3]
  // (reserved) ZEROED, keyed BLAKE2s with a 16-byte output.
  final body = pkt.sublist(0, 116);
  final mac1Key = await _hash([..._labelMac1.codeUnits, ...rsPub]);
  final zeroed = Uint8List.fromList(body);
  zeroed[1] = 0;
  zeroed[2] = 0;
  zeroed[3] = 0;
  final mac1 =
      (await _blake16.calculateMac(zeroed, secretKey: SecretKey(mac1Key)))
          .bytes;
  final mac1Ok = _eq(mac1, pkt.sublist(116, 132));
  stdout.writeln('  mac1 (keyed blake2s-16 over reserved-zeroed body): '
      '${mac1Ok ? "MATCH" : "MISMATCH"}');
  if (!mac1Ok) {
    final mac1Raw =
        (await _blake16.calculateMac(body, secretKey: SecretKey(mac1Key)))
            .bytes;
    stdout.writeln('    zeroed=${_hex(mac1)}');
    stdout.writeln('    raw   =${_hex(mac1Raw)}');
    stdout.writeln('    pkt   =${_hex(pkt.sublist(116, 132))}'
        '${_eq(mac1Raw, pkt.sublist(116, 132)) ? "  (matches RAW body!)" : ""}');
  }

  // Chain bootstrap.
  var c = await _hash(_protocolName.codeUnits);
  var h = await _hash([...c, ..._wgIdentifier.codeUnits]);
  h = await _hash([...h, ...rsPub]);
  final ephPub = pkt.sublist(8, 40);
  h = await _hash([...h, ...ephPub]);
  // WireGuard mixes the ephemeral into the CHAIN KEY too:
  // c = KDF1(c, ephPub) = HMAC(HMAC(c, ephPub), 0x01).
  c = await _kdf2First(c, ephPub);

  // es: DH(ephemeral_pub, our static priv)
  final k1 = await _kdf2Second(c, await _dhPub(myPriv, ephPub));
  c = await _kdf2First(c, await _dhPub(myPriv, ephPub));
  try {
    final st = await _aead.decrypt(
      SecretBox(pkt.sublist(40, 72),
          nonce: Uint8List(12), mac: Mac(pkt.sublist(72, 88))),
      secretKey: SecretKey(k1),
      aad: h,
    );
    stdout.writeln('  encrypted_static DECRYPTED -> '
        '${_hex(st.take(8))}... (static pub OK)');
    h = await _hash([...h, ...pkt.sublist(40, 88)]);
    final k2 = await _kdf2Second(c, await _dhPub(myPriv, st));
    final ts = await _aead.decrypt(
      SecretBox(pkt.sublist(88, 100),
          nonce: Uint8List(12), mac: Mac(pkt.sublist(100, 116))),
      secretKey: SecretKey(k2),
      aad: h,
    );
    final tai = ByteData.view((Uint8List.fromList(ts)).buffer)
        .getUint64(0, Endian.big);
    final unix = tai - 0x4000000000000000;
    stdout.writeln('  encrypted_timestamp DECRYPTED -> '
        'tai64=$tai unix_delta=${unix - DateTime.now().millisecondsSinceEpoch ~/ 1000}s');
    stdout.writeln('  => CHAIN (HMAC-BLAKE2s-B64) VALID');
  } catch (e) {
    stdout.writeln('  DECRYPT FAILED: $e');
    stdout.writeln('  => CHAIN MISMATCH');
  }
}

// ---------------------------------------------------------------- crypto

Future<List<int>> _hash(List<int> d) async => (await _blake.hash(d)).bytes;

/// Our x25519 public key for a private-seed.
Future<List<int>> _pub(List<int> privSeed) async {
  final kp = await _x25519.newKeyPairFromSeed(privSeed);
  return (await kp.extractPublicKey()).bytes;
}

/// RFC-2104 HMAC with BLAKE2s-256, block size 64.
Future<List<int>> hmacB64(List<int> key, List<int> data) async {
  const block = 64;
  var k = key;
  if (k.length > block) k = await _hash(k);
  if (k.length < block) k = [...k, ...List.filled(block - k.length, 0)];
  final ipad = [for (final b in k) b ^ 0x36];
  final opad = [for (final b in k) b ^ 0x5c];
  final inner = await _hash([...ipad, ...data]);
  return _hash([...opad, ...inner]);
}

Future<List<int>> _kdf2First(List<int> key, List<int> data) async =>
    hmacB64(await hmacB64(key, data), [0x1]);
Future<List<int>> _kdf2Second(List<int> key, List<int> data) async {
  final prk = await hmacB64(key, data);
  final t0 = await hmacB64(prk, [0x1]);
  return hmacB64(prk, [...t0, 0x2]);
}

Future<List<int>> _dhPub(List<int> privSeed, List<int> remotePub) async {
  final kp = await _x25519.newKeyPairFromSeed(privSeed);
  final shared = await _x25519.sharedSecretKey(
    keyPair: kp,
    remotePublicKey: SimplePublicKey(remotePub, type: KeyPairType.x25519),
  );
  return shared.extractBytes();
}

// ------------------------------------------------------ builders (tool-local)

/// Copy of the probe's builder but with the RFC-2104 HMAC chain.
Future<Uint8List> buildHmacInitiation({
  required List<int> initiatorStaticPrivate,
  required List<int> responderStaticPublic,
  List<int>? reserved,
  int? senderIndex,
}) async {
  final idx = senderIndex ?? DateTime.now().microsecondsSinceEpoch & 0xFFFFFFFF;
  var c = await _hash(_protocolName.codeUnits);
  var h = await _hash([...c, ..._wgIdentifier.codeUnits]);
  h = await _hash([...h, ...responderStaticPublic]);

  final eph = await _x25519.newKeyPair();
  final ephPub = await eph.extractPublicKey();
  final ephPriv = await eph.extractPrivateKeyBytes();
  h = await _hash([...h, ...ephPub.bytes]);
  // WireGuard's extra step: c = KDF1(c, ephPub) — vanilla Noise doesn't,
  // wireguard-go and boringtun both do.
  c = (await _kdf2(c, ephPub.bytes)).$1;

  final my = await _x25519.newKeyPairFromSeed(initiatorStaticPrivate);
  final myPub = await my.extractPublicKey();
  final myPriv = await my.extractPrivateKeyBytes();

  final (c1, k1) = await _kdf2(c, await _dhPub(ephPriv, responderStaticPublic));
  c = c1;
  final boxStatic = await _aead.encrypt(myPub.bytes,
      secretKey: SecretKey(k1), nonce: Uint8List(12), aad: h);
  h = await _hash([...h, ...boxStatic.cipherText, ...boxStatic.mac.bytes]);

  final (c2, k2) = await _kdf2(c, await _dhPub(myPriv, responderStaticPublic));
  final boxTs = await _aead.encrypt(_tai64n(),
      secretKey: SecretKey(k2), nonce: Uint8List(12), aad: h);
  c = c2;

  final body = BytesBuilder();
  body.addByte(1);
  final res = reserved ?? const <int>[];
  body.addByte(res.isNotEmpty ? res[0] & 0xFF : 0);
  body.addByte(res.length > 1 ? res[1] & 0xFF : 0);
  body.addByte(res.length > 2 ? res[2] & 0xFF : 0);
  body.add((ByteData(4)..setUint32(0, idx, Endian.little)).buffer.asUint8List());
  body.add(ephPub.bytes);
  body.add(boxStatic.cipherText);
  body.add(boxStatic.mac.bytes);
  body.add(boxTs.cipherText);
  body.add(boxTs.mac.bytes);
  if (body.length != 116) {
    throw StateError('body=${body.length}');
  }
  final mac1Key = await _hash([..._labelMac1.codeUnits, ...responderStaticPublic]);
  final mac1Body = Uint8List.fromList(body.toBytes());
  mac1Body[1] = 0;
  mac1Body[2] = 0;
  mac1Body[3] = 0;
  final mac1 = (await _blake16
          .calculateMac(mac1Body, secretKey: SecretKey(mac1Key)))
      .bytes;
  final out = BytesBuilder()
    ..add(body.toBytes())
    ..add(mac1)
    ..add(Uint8List(16));
  return out.toBytes();
}

Future<(List<int>, List<int>)> _kdf2(List<int> key, List<int> data) async {
  final prk = await hmacB64(key, data);
  final t0 = await hmacB64(prk, [0x1]);
  final t1 = await hmacB64(prk, [...t0, 0x2]);
  return (t0, t1);
}

Uint8List _tai64n() {
  final now = DateTime.now().toUtc().microsecondsSinceEpoch;
  final secs = now ~/ 1000000 + 0x400000000000000a;
  final nanos = (now % 1000000) * 1000;
  final bd = ByteData(12);
  bd.setUint64(0, secs, Endian.big);
  bd.setUint32(8, nanos & 0xFFFFFFFF, Endian.big);
  return bd.buffer.asUint8List();
}

// ---------------------------------------------------------------- helpers

Future<Map<String, dynamic>> _loadAccount() async {
  final cache = File(
      '${Directory.systemTemp.path}${Platform.pathSeparator}warp_e2e_acct.json');
  if (!await cache.exists()) {
    throw StateError('run tool/warp_e2e_config.dart first (no account)');
  }
  return jsonDecode(await cache.readAsString()) as Map<String, dynamic>;
}

List<int>? _b64(String s) {
  if (s.isEmpty) return null;
  try {
    return base64.decode(s);
  } catch (_) {
    return null;
  }
}

bool _eq(List<int> a, List<int> b) =>
    a.length == b.length && [for (var i = 0; i < a.length; i++) a[i] ^ b[i]]
        .every((x) => x == 0);

String _hex(Iterable<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');
