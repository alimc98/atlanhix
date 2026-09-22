import '../../domain/entities/proxy_profile.dart';
import '../../domain/errors/app_error.dart';

/// Parser for wg-quick style `.conf` files and AmneziaWG `.conf` extensions.
///
/// [Interface]PrivateKey/Address/DNS/MTU + [Peer]PublicKey/PresharedKey/
/// AllowedIPs/Endpoint/PersistentKeepalive; AWG adds Jc/Jmin/Jmax/S1/S2/H1-H4.
/// Unknown keys are preserved (future-proof per spec §19).
class WireGuardConfParser {
  ProxyProfile parse(String text, {String? fileName}) {
    final lines = text.split(RegExp(r'\r?\n')).map((l) => l.trim()).toList();
    String? section;
    final interface = <String, String>{};
    final peers = <Map<String, String>>[];
    final unknownInterface = <String, String>{};
    for (final line in lines) {
      if (line.isEmpty || line.startsWith('#')) continue;
      final secMatch = RegExp(r'^\[(interface|peer)\]$', caseSensitive: false)
          .firstMatch(line);
      if (secMatch != null) {
        section = secMatch.group(1)!.toLowerCase();
        if (section == 'peer') peers.add({});
        continue;
      }
      final kv = line.split(RegExp(r'\s*=\s*'));
      if (kv.length < 2 || section == null) continue;
      final key = kv[0];
      final value = kv.sublist(1).join('=').trim();
      if (section == 'interface') {
        const known = {
          'privatekey', 'address', 'dns', 'mtu', 'listenport', 'fwmark',
          // v0.4.9: wg-quick allows REPEATED Address lines (the amnezia-client
          // WARP conf carries one v4 + one v6 line) — collect instead of
          // keeping only the last one.
          // AmneziaWG 2.0/3.x client set (amneziawg-go v3.1):
          'jc', 'jmin', 'jmax',
          's1', 's2', 's3', 's4',
          'h1', 'h2', 'h3', 'h4',
          'i1', 'i2', 'i3', 'i4', 'i5',
          'hpk', 'contentpaddingaddition',
          // AWG 3.x dialect flags (amnezia-client WARP confs).
          'randomtrailers', 'disablecookies',
        };
        final lk = key.toLowerCase();
        if (lk == 'address') {
          final prev = interface['Address'];
          interface['Address'] =
              (prev == null || prev.isEmpty) ? value : '$prev, $value';
        } else if (known.contains(lk)) {
          interface[key] = value;
        } else {
          unknownInterface[key] = value;
        }
      } else {
        peers.last[key] = value;
      }
    }
    _validate(interface, peers, fileName);
    final profile = _build(interface, peers.first, unknownInterface, fileName);
    return profile..rawConfig = text;
  }

  void _validate(Map<String, String> interface,
      List<Map<String, String>> peers, String? fileName) {
    if (_getAny(interface, ['PrivateKey', 'privatekey']) == null) {
      throw ParseError('Not a WireGuard configuration.', likelyCauses: [
        'Missing [Interface] PrivateKey',
        'Expected a wg-quick .conf file'
      ], raw: fileName ?? 'conf');
    }
    if (peers.isEmpty) {
      throw ParseError('WireGuard configuration has no peer.',
          likelyCauses: ['Missing [Peer] section'], raw: fileName ?? 'conf');
    }
    final endpoint = _getAny(peers.first, ['Endpoint', 'endpoint']) ?? '';
    if (_parseEndpoint(endpoint) == null) {
      throw ParseError('WireGuard configuration has no valid endpoint.',
          likelyCauses: ['[Peer] Endpoint must be host:port'],
          raw: fileName ?? 'conf');
    }
  }

  ProxyProfile _build(Map<String, String> interface, Map<String, String> peer,
      Map<String, String> unknownInterface, String? fileName) {
    final endpoint = _getAny(peer, ['Endpoint', 'endpoint'])!;
    final hp = _parseEndpoint(endpoint)!;
    final privKey = _getAny(interface, ['PrivateKey', 'privatekey'])!;
    // H1..H4 may be a single value OR a "N-M" range (AWG 3.x) — keep as a
    // normalized string; the endpoint builder emits int-or-String from it.
    String? header(String k) {
      final v = _getAny(interface, [k.toUpperCase(), k])?.trim();
      return (v == null || v.isEmpty) ? null : v;
    }

    String? padded(String k) {
      final v = _getAny(interface, [k.toUpperCase(), k])?.trim();
      return (v == null || v.isEmpty) ? null : v;
    }

    final awg = AmneziaParams(
      jc: int.tryParse(_getAny(interface, ['Jc', 'jc']) ?? ''),
      jmin: int.tryParse(_getAny(interface, ['Jmin', 'jmin']) ?? ''),
      jmax: int.tryParse(_getAny(interface, ['Jmax', 'jmax']) ?? ''),
      s1: int.tryParse(_getAny(interface, ['S1', 's1']) ?? ''),
      s2: int.tryParse(_getAny(interface, ['S2', 's2']) ?? ''),
      s3: int.tryParse(_getAny(interface, ['S3', 's3']) ?? ''),
      s4: int.tryParse(_getAny(interface, ['S4', 's4']) ?? ''),
      h1: header('h1'),
      h2: header('h2'),
      h3: header('h3'),
      h4: header('h4'),
      i1: padded('i1'),
      i2: padded('i2'),
      i3: padded('i3'),
      i4: padded('i4'),
      i5: padded('i5'),
      headerProtectionKey: padded('hpk'),
      contentPaddingAddition: padded('contentpaddingaddition'),
      randomTrailers: _flag(_getAny(
          interface, ['RandomTrailers', 'randomtrailers'])),
      disableCookies: _flag(_getAny(
          interface, ['DisableCookies', 'disablecookies'])),
      extra: Map.fromEntries(unknownInterface.entries.where(
          (e) => !RegExp(
                  r'^(jc|jmin|jmax|s[1-4]|h[1-4]|i[1-5]|hpk|contentpaddingaddition|randomtrailers|disablecookies)$',
                  caseSensitive: false)
              .hasMatch(e.key))),
    );
    final dns = (_getAny(interface, ['DNS', 'dns']) ?? '')
        .split(',')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    final addresses = ((_getAny(interface, ['Address', 'address']) ?? '')
            .split(',')
            .map((e) => e.trim())
            .where((e) => e.isNotEmpty)
            .toList())
        .map(_prefix) // bare IPs → netip.Prefix-compatible (see _prefix)
        .toList();
    final isAwg = awg.isNotEmpty;
    return ProxyProfile(
      id: Ids.newId(),
      name: fileName ?? 'WireGuard ${hp.$1}',
      server: hp.$1,
      port: hp.$2,
      protocol: ProxyProtocol.wireguard,
      transport: Transport.none,
      security: Security.none,
      core: isAwg ? CoreKind.amneziaWg : CoreKind.wireguardSingbox,
      wireguard: WireGuardConfig(
        privateKey: privKey,
        peerPublicKey: _getAny(peer, ['PublicKey', 'publickey']) ?? '',
        endpointHost: hp.$1,
        endpointPort: hp.$2,
        preSharedKey: _getAny(peer, ['PresharedKey', 'presharedkey']),
        allowedIps: (_getAny(peer, ['AllowedIPs', 'allowedips']) ??
                '0.0.0.0/0, ::/0')
            .split(',')
            .map((e) => e.trim())
            .where((e) => e.isNotEmpty)
            .toList(),
        dns: dns,
        addresses: addresses,
        mtu: int.tryParse(_getAny(interface, ['MTU', 'mtu']) ?? ''),
        persistentKeepalive: int.tryParse(
            _getAny(peer, ['PersistentKeepalive', 'persistentkeepalive']) ??
                ''),
      ),
      amnezia: isAwg ? awg : null,
      rawConfig: null,
      source: ProfileSource.fileImport,
    );
  }

  String exportConf(ProxyProfile p) {
    final wg = p.wireguard!;
    final awg = p.amnezia?.toConfLines() ?? const <String, String>{};
    final b = StringBuffer('[Interface]\n')
      ..writeln('PrivateKey = ${wg.privateKey}');
    if (wg.addresses.isNotEmpty) {
      b.writeln('Address = ${wg.addresses.join(', ')}');
    }
    if (wg.dns.isNotEmpty) b.writeln('DNS = ${wg.dns.join(', ')}');
    if (wg.mtu != null) b.writeln('MTU = ${wg.mtu}');
    awg.forEach((k, v) => b.writeln('$k = $v'));
    b..writeln()..writeln('[Peer]')..writeln('PublicKey = ${wg.peerPublicKey}');
    if (wg.preSharedKey != null) b.writeln('PresharedKey = ${wg.preSharedKey}');
    b..writeln('AllowedIPs = ${wg.allowedIps.join(', ')}')
        ..writeln('Endpoint = ${wg.endpointHost}:${wg.endpointPort}');
    if (wg.persistentKeepalive != null) {
      b.writeln('PersistentKeepalive = ${wg.persistentKeepalive}');
    }
    return b.toString();
  }

  /// sing-box ≥1.12 wants `address` entries as netip.Prefix; bare IPs
  /// ("172.16.0.2") fail the engine decode with `no '/'`. v4 → /32,
  /// v6 → /128 when the conf omitted the prefix length.
  static String _prefix(String entry) {
    final t = entry.trim();
    if (t.contains('/')) return t;
    return '$t/${t.contains(':') ? 128 : 32}';
  }

  /// wg-quick dialect tri-state: absent → null (server default);
  /// "on"/"true"/"yes"/"1" → true; anything else → false.
  static bool? _flag(String? v) {
    if (v == null) return null;
    final t = v.trim().toLowerCase();
    return t == 'on' || t == 'true' || t == 'yes' || t == '1';
  }

  static String? _getAny(Map<String, String> m, List<String> keys) {
    for (final k in keys) {
      final v = m[k] ?? m[k.toLowerCase()] ?? m[k.toUpperCase()];
      if (v != null) return v;
    }
    // Mixed-case keys ("Hpk", "ContentPaddingAddition") — the AWG conf
    // headers are neither all-upper nor all-lower, so fall back to a
    // case-insensitive scan (cheap: interface maps hold ~20 keys).
    final lower = <String, String>{
      for (final e in m.entries) e.key.toLowerCase(): e.value
    };
    for (final k in keys) {
      final v = lower[k.toLowerCase()];
      if (v != null) return v;
    }
    return null;
  }

  static (String, int)? _parseEndpoint(String e) {
    final m = RegExp(r'^(?:\[([^\]]+)\]|([^:\[\]]+)):(\d+)$').firstMatch(e);
    if (m == null) return null;
    final host = m.group(1) ?? m.group(2);
    final port = int.tryParse(m.group(3)!);
    if (host == null || port == null) return null;
    return (host, port);
  }
}
