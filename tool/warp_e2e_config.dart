// Writes a ready-to-run sing-box config for a REAL WARP account.
//   dart run tool/warp_e2e_config.dart <plain|awg|awgfull> <outfile>
// Registers once and caches the account next to the temp dir so every
// run talks to the same device identity.
import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';

Future<void> main(List<String> args) async {
  final mode = args.isNotEmpty ? args[0] : 'plain';
  final out = args.length > 1 ? args[1] : 'warp-e2e.json';
  final cache = File(
      '${Directory.systemTemp.path}${Platform.pathSeparator}warp_e2e_acct.json');

  Map<String, dynamic> acct;
  if (await cache.exists()) {
    acct = jsonDecode(await cache.readAsString()) as Map<String, dynamic>;
    stdout.writeln('using cached account ${acct['deviceId']}');
  } else {
    acct = await _register();
    await cache.writeAsString(jsonEncode(acct));
    stdout.writeln('registered new account ${acct['deviceId']}');
  }

  final endpointV4 = acct['endpointV4'] as String;
  final (host, port) = _splitHostPort(endpointV4, 2408);
  stdout.writeln('endpoint: $endpointV4 -> $host:$port');

  List<int>? reserved;
  final cid = acct['clientId'] as String;
  if (cid.isNotEmpty) {
    try {
      reserved = base64.decode(cid);
    } catch (_) {}
  }

  final endpoint = <String, dynamic>{
    'type': 'wireguard',
    'tag': 'warp',
    'address': [
      _pfx(acct['addressV4'] as String),
      if ((acct['addressV6'] as String?)?.isNotEmpty == true)
        _pfx(acct['addressV6'] as String),
    ],
    'private_key': acct['priv'],
    'mtu': 1280,
    'peers': [
      {
        'address': host,
        'port': port,
        'public_key': acct['serverPub'],
        'allowed_ips': ['0.0.0.0/0', '::/0'],
        'persistent_keepalive_interval': 25,
        if (reserved != null && reserved.length == 3) 'reserved': reserved,
      },
    ],
  };
  // AmneziaWG variants to test against Cloudflare's server:
  //  - awg     : the app's current preset (jc + s1/s2 + h1..h4)
  //  - awgjunk : junk packets ONLY (jc/jmin/jmax) — the real initiation keeps
  //              the standard WG layout, junk just gets dropped by the
  //              vanilla parser, so this is the subset that can interop
  //  - awgfull : app preset + random trailers + disable cookies
  //  - awgmasc : app preset + WireSock masquerade decoy (id/ip sugar)
  if (mode == 'awg' || mode == 'awgfull') {
    endpoint
      ..['jc'] = 4
      ..['jmin'] = 64
      ..['jmax'] = 96
      ..['s1'] = 15
      ..['s2'] = 15
      ..['h1'] = 1
      ..['h2'] = 2
      ..['h3'] = 3
      ..['h4'] = 4;
  }
  if (mode == 'awgjunk' ||
      mode == 'awgmasc' ||
      mode == 'awgmasc2' ||
      mode == 'awgjt') {
    endpoint
      ..['jc'] = 4
      ..['jmin'] = 64
      ..['jmax'] = 96;
  }
  if (mode == 'awgfull') {
    endpoint
      ..['random_trailers'] = true
      ..['disable_cookies'] = true;
  }
  if (mode == 'awgmasc' || mode == 'awgmasc2') {
    endpoint
      ..['id'] = 'www.google.com'
      ..['ip'] = 'quic';
  }
  if (mode == 'awgmasc2') {
    endpoint..['ib'] = 'chrome';
  }
  if (mode == 'awgjt') {
    endpoint
      ..['jc'] = 4
      ..['jmin'] = 64
      ..['jmax'] = 96
      ..['random_trailers'] = true;
  }
  if (mode == 'awgfinal') {
    endpoint
      ..['jc'] = 4
      ..['jmin'] = 64
      ..['jmax'] = 96
      ..['id'] = 'www.google.com'
      ..['ip'] = 'quic'
      ..['ib'] = 'chrome'
      ..['random_trailers'] = true;
  }
  if (mode == 'awgdc') {
    endpoint
      ..['jc'] = 4
      ..['jmin'] = 64
      ..['jmax'] = 96
      ..['disable_cookies'] = true;
  }

  final config = {
    'log': {'level': 'debug', 'timestamp': true},
    'dns': {
      'servers': [
        {'type': 'udp', 'tag': 'udp-dns', 'server': '1.1.1.1'},
      ],
    },
    'inbounds': [
      {
        'type': 'mixed',
        'tag': 'in',
        'listen': '127.0.0.1',
        'listen_port': 2080,
      },
    ],
    'endpoints': [endpoint],
    'outbounds': [
      {'type': 'direct', 'tag': 'direct', 'connect_timeout': '5s'},
    ],
    'route': {'final': 'warp'},
  };
  await File(out).writeAsString(jsonEncode(config));
  stdout.writeln('wrote $out (${mode} mode)');
}

String _pfx(String entry) {
  final t = entry.trim();
  if (t.isEmpty) return t;
  if (t.contains('/')) return t;
  return '$t/${t.contains(':') ? 128 : 32}';
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
  return (t, dflt);
}

Future<Map<String, dynamic>> _register() async {
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
    final req = await client
        .postUrl(Uri.parse('https://api.cloudflareclient.com/v0a2158/reg'));
    req.headers
      ..set('Content-Type', 'application/json')
      ..set('User-Agent', '1.1.1.1/6.28');
    req.write(body);
    final resp = await req.close().timeout(const Duration(seconds: 20));
    final text = await resp.transform(utf8.decoder).join();
    if (resp.statusCode != 200) {
      throw StateError('reg HTTP ${resp.statusCode}: $text');
    }
    final j = jsonDecode(text) as Map<String, dynamic>;
    final config = j['config'] as Map<String, dynamic>;
    final peer0 = ((config['peers'] as List).first as Map);
    final endpoint = (peer0['endpoint'] as Map?) ?? const {};
    final iface = (config['interface'] as Map?) ?? const {};
    final addrs = (iface['addresses'] as Map?) ?? const {};
    return {
      'deviceId': '${j['id']}',
      'endpointV4': '${endpoint['v4']}',
      'endpointV6': '${endpoint['v6'] ?? ''}',
      'serverPub': '${peer0['public_key']}',
      'clientId': '${config['client_id'] ?? ''}',
      'addressV4': '${addrs['v4'] ?? ''}',
      'addressV6': '${addrs['v6'] ?? ''}',
      'priv': base64.encode(priv),
    };
  } finally {
    client.close(force: true);
  }
}
