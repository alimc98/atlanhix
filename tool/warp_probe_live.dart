// Live validation of the WARP handshake probe against REAL Cloudflare
// endpoints. Settles two open questions empirically:
//   1) KDF: RFC-2104 HMAC-BLAKE2s (block 64) vs native keyed BLAKE2s.
//   2) The response's receiver-index offset (4 vs 8) — our sender index
//      must appear in a genuine type-2 reply.
//
// Run: dart run tool/warp_probe_live.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'package:nexus/warp/wg_handshake_probe.dart';

Future<void> main() async {
  stdout.writeln('== 1) register a WARP device ==');
  final reg = await _register();
  if (reg == null) {
    stdout.writeln('REGISTRATION FAILED');
    return;
  }
  final endpointV4 = reg['endpointV4'] as String;
  final endpointV6 = reg['endpointV6'] as String?;
  final serverPub = reg['serverPub'] as String;
  final clientId = reg['clientId'] as String;
  stdout.writeln('endpoint.v4  = "$endpointV4"');
  stdout.writeln('endpoint.v6  = "$endpointV6"');
  stdout.writeln('client_id    = "$clientId"');
  stdout.writeln('server pub   = ${serverPub.substring(0, Math.min(12, serverPub.length))}…');

  final priv = base64.decode(reg['priv'] as String);
  final responder = base64.decode(serverPub);
  List<int>? reserved;
  try {
    reserved = clientId.isEmpty ? null : base64.decode(clientId);
  } catch (_) {}
  stdout.writeln('reserved     = $reserved');

  final (host, port) = _splitHostPort(endpointV4, 2408);
  stdout.writeln('default dial = $host:$port');

  stdout.writeln('\n== 2) KDF A/B against the default endpoint ==');
  final senderIdx = 0x51ab77c3;
  final variants = <String, Future<Uint8List> Function()>{
    'lib-crypto + reserved': () => WgHandshakeProbe.buildInitiation(
        initiatorStaticPrivate: priv,
        responderStaticPublic: responder,
        reserved: reserved,
        senderIndex: senderIdx),
    'lib-crypto, no reserved': () => WgHandshakeProbe.buildInitiation(
        initiatorStaticPrivate: priv,
        responderStaticPublic: responder,
        senderIndex: senderIdx),
    'tool-hmac cross-check + reserved': () => _buildHmac(
        initiatorStaticPrivate: priv,
        responderStaticPublic: responder,
        reserved: reserved,
        senderIndex: senderIdx),
    'tool-hmac cross-check, no reserved': () => _buildHmac(
        initiatorStaticPrivate: priv,
        responderStaticPublic: responder,
        senderIndex: senderIdx),
    // Does CF validate the reserved CONTENT (client_id binding), or only
    // the MAC? garbage reserved + correct zeroed-body mac1.
    'lib-crypto, garbage reserved [1,2,3]': () =>
        WgHandshakeProbe.buildInitiation(
            initiatorStaticPrivate: priv,
            responderStaticPublic: responder,
            reserved: const [1, 2, 3],
            senderIndex: senderIdx),
  };
  String? winner;
  for (final e in variants.entries) {
    final pkt = await e.value();
    final r = await _probeRaw(host, port, pkt,
        timeout: const Duration(milliseconds: 2500));
    stdout.writeln('-- ${e.key}: ${r == null ? 'SILENT' : 'REPLY'}');
    if (r != null) {
      _describe(r, senderIdx);
      winner ??= e.key;
    }
  }

  stdout.writeln('\n== 3) scan-candidate sweep with the working variant ==');
  const candidates = [
    '162.159.192.1',
    '162.159.193.10',
    '162.159.195.1',
    '188.114.96.1',
    '188.114.97.1',
  ];
  for (final c in candidates) {
    final pkt = winner != null && winner!.startsWith('tool-hmac')
        ? await _buildHmac(
            initiatorStaticPrivate: priv,
            responderStaticPublic: responder,
            reserved: reserved,
            senderIndex: senderIdx)
        : await WgHandshakeProbe.buildInitiation(
            initiatorStaticPrivate: priv,
            responderStaticPublic: responder,
            reserved: reserved,
            senderIndex: senderIdx);
    final r = await _probeRaw(c, 2408, pkt,
        timeout: const Duration(milliseconds: 2500));
    stdout.writeln('-- $c:2408 ${r == null ? 'SILENT' : 'REPLY'}');
    if (r != null) _describe(r, senderIdx);
  }
  stdout.writeln('\nWINNER: ${winner ?? 'none — neither KDF answered'}');
}

class Math {
  static int min(int a, int b) => a < b ? a : b;
}

(String, int) _splitHostPort(String ep, int dflt) {
  final t = ep.trim();
  if (t.startsWith('[')) {
    final i = t.indexOf(']');
    if (i > 0) {
      final h = t.substring(1, i);
      final rest = t.substring(i + 1);
      final p = rest.startsWith(':') ? int.tryParse(rest.substring(1)) : null;
      return (h, (p != null && p > 0) ? p : dflt);
    }
    return (t, dflt);
  }
  final i = t.lastIndexOf(':');
  if (i > 0 && !t.substring(0, i).contains(':')) {
    final h = t.substring(0, i);
    final p = int.tryParse(t.substring(i + 1));
    return (h, (p != null && p > 0) ? p : dflt);
  }
  return (t, dflt); // bare IP / naked v6 / domain
}

void _describe(Uint8List resp, int senderIdx) {
  final len = resp.length;
  final type = len > 0 ? resp[0] : -1;
  final head = resp
      .take(16)
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join(' ');
  stdout.writeln('    len=$len type=$type head: $head');
  if (len >= 12) {
    final bd = ByteData.sublistView(resp);
    final o4 = bd.getUint32(4, Endian.little);
    final o8 = bd.getUint32(8, Endian.little);
    stdout.writeln(
        '    u32@4=0x${o4.toRadixString(16)} u32@8=0x${o8.toRadixString(16)} '
        '(ours=0x${senderIdx.toRadixString(16)})');
  }
}

// ---------------------------------------------------------------- register

Future<Map<String, String>?> _register() async {
  final alg = X25519();
  final kp = await alg.newKeyPair();
  final pub = (await kp.extractPublicKey()).bytes;
  final priv = await kp.extractPrivateKeyBytes();
  final body = jsonEncode({
    'install_id': '',
    'tos': DateTime.now().toUtc().toIso8601String(),
    'model': 'PC',
    'serial_number': DateTime.now().microsecondsSinceEpoch.toString(),
    'language': 'en',
    'key': base64.encode(pub),
    'type': 'Windows',
    'locale': 'en_US',
    'warp_enabled': true,
  });
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
  try {
    final req = await client.postUrl(
        Uri.parse('https://api.cloudflareclient.com/v0a2158/reg'));
    req.headers
      ..set('Content-Type', 'application/json')
      ..set('User-Agent', '1.1.1.1/6.28');
    req.write(body);
    final resp = await req.close().timeout(const Duration(seconds: 20));
    final text = await resp.transform(utf8.decoder).join();
    if (resp.statusCode != 200) {
      stdout.writeln('reg HTTP ${resp.statusCode}: ${text.substring(0, Math.min(300, text.length))}');
      return null;
    }
    final j = jsonDecode(text) as Map<String, dynamic>;
    final config = j['config'] as Map<String, dynamic>;
    final peers = (config['peers'] as List).cast<Map>();
    final peer0 = peers.first;
    final endpoint = (peer0['endpoint'] as Map?) ?? const {};
    final iface = (config['interface'] as Map?) ?? const {};
    final addrs = (iface['addresses'] as Map?) ?? const {};
    return {
      'endpointV4': '${endpoint['v4']}',
      'endpointV6': '${endpoint['v6'] ?? ''}',
      'serverPub': '${peer0['public_key']}',
      'clientId': '${config['client_id'] ?? ''}',
      'addressV4': '${addrs['v4'] ?? ''}',
      'addressV6': '${addrs['v6'] ?? ''}',
      'priv': base64.encode(priv),
    };
  } catch (e) {
    stdout.writeln('reg error: $e');
    return null;
  } finally {
    client.close(force: true);
  }
}

// ------------------------------------------------------------ raw probe

Future<Uint8List?> _probeRaw(String host, int port, Uint8List pkt,
    {required Duration timeout}) async {
  final sock = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
  try {
    final c = Completer<Uint8List>();
    final sw = Stopwatch()..start();
    late final StreamSubscription<RawSocketEvent> sub;
    sub = sock.listen((e) {
      if (e == RawSocketEvent.read && !c.isCompleted) {
        final d = sock.receive();
        if (d != null && d.data.isNotEmpty) {
          stdout.writeln('    (reply after ${sw.elapsedMilliseconds}ms '
              'from ${d.address.address}:${d.port})');
          c.complete(Uint8List.fromList(d.data));
        }
      }
    });
    final addr = InternetAddress.tryParse(host);
    if (addr != null) {
      sock.send(pkt, addr, port);
    } else {
      final look = await InternetAddress.lookup(host);
      sock.send(pkt, look.first, port);
    }
    final timer = Timer(timeout, () {
      if (!c.isCompleted) c.completeError(TimeoutException('silent'));
    });
    try {
      return await c.future;
    } on TimeoutException {
      return null;
    } finally {
      timer.cancel();
      await sub.cancel();
    }
  } finally {
    sock.close();
  }
}

// ------------------------------------------------- HMAC-BLAKE2s variant

final _blake = Blake2s();
final _blake16 = Blake2s(hashLengthInBytes: 16);

Future<List<int>> _hmac(List<int> key, List<int> data) async {
  const block = 64;
  var k = key.length > block ? await (_blake.hash(key)).then((d) => d.bytes) : key;
  if (k.length < block) k = [...k, ...List.filled(block - k.length, 0)];
  final ipad = [for (final b in k) b ^ 0x36];
  final opad = [for (final b in k) b ^ 0x5c];
  final inner = await _blake.hash([...ipad, ...data]);
  return (await _blake.hash([...opad, ...inner.bytes])).bytes;
}

Future<(List<int>, List<int>)> _kdf2h(List<int> key, List<int> data) async {
  final prk = await _hmac(key, data);
  final t0 = await _hmac(prk, [0x1]);
  final t1 = await _hmac(prk, [...t0, 0x2]);
  return (t0, t1);
}

/// Copy of WgHandshakeProbe.buildInitiation with the KDF swapped to
/// RFC-2104 HMAC-BLAKE2s (block 64) — the WireGuard whitepaper/Noise HMAC.
Future<Uint8List> _buildHmac({
  required List<int> initiatorStaticPrivate,
  required List<int> responderStaticPublic,
  List<int>? reserved,
  int? senderIndex,
}) async {
  const protocolName = 'Noise_IKpsk2_25519_ChaChaPoly_BLAKE2s';
  const labelMac1 = 'mac1----';
  const wgIdentifier = 'WireGuard v1 zx2c4 Jason@zx2c4.com';
  final aead = Chacha20.poly1305Aead();
  final x25519 = X25519();
  Future<List<int>> hash(List<int> d) async => (await _blake.hash(d)).bytes;

  final idx = senderIndex ?? 0x22222222;
  var c = await hash(protocolName.codeUnits);
  var h = await hash([...c, ...wgIdentifier.codeUnits]);
  h = await hash([...h, ...responderStaticPublic]);

  final eph = await x25519.newKeyPair();
  final ephPub = await eph.extractPublicKey();
  final ephPriv = await eph.extractPrivateKeyBytes();
  h = await hash([...h, ...ephPub.bytes]);
  // wireguard-go/boringtun also mix the ephemeral into the chain key:
  c = (await _kdf2h(c, ephPub.bytes)).$1;

  final my = await x25519.newKeyPairFromSeed(initiatorStaticPrivate);
  final myPub = await my.extractPublicKey();
  final myPriv = await my.extractPrivateKeyBytes();

  Future<List<int>> dh(List<int> priv, List<int> pub) async {
    final kp = await x25519.newKeyPairFromSeed(priv);
    final sk = await x25519.sharedSecretKey(
        keyPair: kp,
        remotePublicKey: SimplePublicKey(pub, type: KeyPairType.x25519));
    return sk.extractBytes();
  }

  final (c1, k1) = await _kdf2h(c, await dh(ephPriv, responderStaticPublic));
  c = c1;
  final boxStatic = await aead.encrypt(myPub.bytes,
      secretKey: SecretKey(k1), nonce: Uint8List(12), aad: h);
  h = await hash([...h, ...boxStatic.cipherText, ...boxStatic.mac.bytes]);

  final (c2, k2) = await _kdf2h(c, await dh(myPriv, responderStaticPublic));
  final now = DateTime.now().toUtc().microsecondsSinceEpoch;
  final secs = now ~/ 1000000 + 0x400000000000000a;
  final nanos = (now % 1000000) * 1000;
  final bd = ByteData(12);
  bd.setUint64(0, secs, Endian.big);
  bd.setUint32(8, nanos & 0xFFFFFFFF, Endian.big);
  final boxTs = await aead.encrypt(bd.buffer.asUint8List(),
      secretKey: SecretKey(k2), nonce: Uint8List(12), aad: h);

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

  final mac1Key = await hash([...labelMac1.codeUnits, ...responderStaticPublic]);
  // keyed BLAKE2s with a 16-byte OUTPUT (blake2s.New128), not 32-truncated;
  // MAC covers the body with the 3 reserved bytes ZEROED (proven live + vs
  // captured wireguard-go packet).
  final mac1Body = Uint8List.fromList(body.toBytes());
  mac1Body[1] = 0;
  mac1Body[2] = 0;
  mac1Body[3] = 0;
  final mac1 = (await _blake16.calculateMac(mac1Body,
          secretKey: SecretKey(mac1Key)))
      .bytes;

  final out = BytesBuilder();
  out.add(body.toBytes());
  out.add(mac1);
  out.add(Uint8List(16));
  return out.toBytes();
}
