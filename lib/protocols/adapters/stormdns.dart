import 'dart:convert';

import '../../domain/entities/proxy_profile.dart';
import '../../domain/errors/app_error.dart';

/// StormDNS (DNS-tunnel transport, Go engine at GitHub
/// `nullroute1970 / StormDNS`) adapter — the sibling of MasterDnsVPN with
/// the same client_config.toml schema and the same local SOCKS5 listener.
///
/// Import formats:
///  * `stormdns://<base64url(JSON)>#name` — WhiteDNS-compatible profile
///    link (`schema: whitedns.profile`), so links swap between apps;
///  * `storm://…` — alias of the same payload;
///  * `masterdns://<base64url(JSON)>#name` — WhiteDNS link carrying the
///    same server shape for the MasterDNS server family; routed to the
///    MasterDnsVPN core here (scheme semantics — see [parseUri]);
///  * raw `client_config.toml` text pasted/imported.
class StormDnsParser {
  static const _whiteDnsSchema = 'whitedns.profile';

  /// TOML keys that only the StormDNS sample carries — used to tell the two
  /// otherwise near-identical client configs apart on paste.
  static final _stormTomlKeys = RegExp(
      r'^(STARTUP_MODE|DNS_QUERY_TYPE|UPLOAD_PACKET_DUPLICATION_COUNT|'
      r'DOWNLOAD_PACKET_DUPLICATION_COUNT|LOCAL_DNS_CACHE_TTL_SECONDS)\s*=',
      multiLine: true);

  static bool looksLikeStormToml(String text) => _stormTomlKeys.hasMatch(text);

  /// Generic `KEY = value` TOML shape (shared with the mdvpn sniffer).
  static bool looksLikeToml(String text) {
    final t = text.trimLeft();
    return t.startsWith('#') ||
        RegExp(r'^[A-Z_]+\s*=', multiLine: true).hasMatch(text);
  }

  /// Parses a raw upstream `client_config.toml`.
  ProxyProfile parseToml(String text, {String? name}) {
    final kv = <String, String>{};
    for (final line in text.split(RegExp(r'\r?\n'))) {
      final l = line.trim();
      if (l.isEmpty || l.startsWith('#') || l.startsWith('[')) continue;
      final idx = l.indexOf('=');
      if (idx <= 0) continue;
      var key = l.substring(0, idx).trim();
      var value = l.substring(idx + 1).trim();
      // TOML array form: DOMAINS = ["a.com", "b.com"]
      if (value.startsWith('[') && value.endsWith(']')) {
        value = value
            .substring(1, value.length - 1)
            .split(',')
            .map((e) => e.trim().replaceAll('"', ''))
            .where((e) => e.isNotEmpty)
            .join(',');
      } else if (value.startsWith('"') &&
          value.endsWith('"') &&
          value.length >= 2) {
        value = value.substring(1, value.length - 1);
      }
      kv[key.toUpperCase()] = value;
    }
    final domains = (kv['DOMAINS'] ?? '')
        .split(',')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    final server = domains.isNotEmpty ? domains.first : (kv['SERVER'] ?? '');
    if (server.isEmpty) {
      throw ParseError(
          'StormDNS configuration needs DOMAINS (tunnel domain list).',
          likelyCauses: ['Paste a complete client_config.toml from your provider'],
          raw: text);
    }
    final name0 = kv['NAME'] ?? 'StormDNS $server';
    // §2/§22: the shared key is a SECRET — move it into `password` (the
    // persistence layer vaultifies it) and redact it from the stored TOML.
    final secretKey = kv.remove('ENCRYPTION_KEY');
    var storedRaw = text;
    if (secretKey != null && secretKey.isNotEmpty) {
      storedRaw = text
          .split(RegExp(r'\r?\n'))
          .map((line) {
            final t = line.trim();
            if (t.toUpperCase().startsWith('ENCRYPTION_KEY')) {
              return 'ENCRYPTION_KEY = "<redacted>"';
            }
            return line;
          })
          .join('\n');
    }
    return ProxyProfile(
      id: Ids.newId(),
      name: name0,
      server: server,
      port: int.tryParse(kv['SERVER_PORT'] ?? '') ?? 53,
      protocol: ProxyProtocol.stormDns,
      core: CoreKind.stormDns,
      password: (secretKey == null || secretKey.isEmpty) ? null : secretKey,
      rawParams: kv,
      rawConfig: storedRaw,
      source: ProfileSource.fileImport,
    );
  }

  /// True for a WhiteDNS-style profile link (`stormdns://`, `storm://`, or
  /// the `masterdns://` JSON variant — NOT our legacy `mdvpn://` TOML link).
  static bool isProfileLink(String raw) {
    final s = raw.trimLeft().toLowerCase();
    return s.startsWith('stormdns://') ||
        s.startsWith('storm://') ||
        s.startsWith('masterdns://');
  }

  /// Decodes a WhiteDNS-compatible profile link.
  ///
  /// Engine routing: `stormdns://`/`storm://` → StormDNS core;
  /// `masterdns://` → MasterDnsVPN core (the scheme names the MasterDNS
  /// server family; WhiteDNS maps both schemes onto its own engine, we
  /// keep the honest per-scheme engine so a link never silently switches
  /// protocol implementations).
  ProxyProfile parseUri(String raw) {
    final link = raw.trim();
    final schemeEnd = link.indexOf('://');
    final scheme =
        schemeEnd > 0 ? link.substring(0, schemeEnd).toLowerCase() : '';
    const allowed = {'stormdns', 'storm', 'masterdns'};
    if (!allowed.contains(scheme)) {
      throw ParseError('Not a StormDNS profile link.', raw: raw);
    }
    // Fragment (name) and query are metadata — strip before decoding.
    var payload = link.substring(schemeEnd + 3);
    final cut = payload.indexOf('#');
    if (cut >= 0) payload = payload.substring(0, cut);
    final cutQ = payload.indexOf('?');
    if (cutQ >= 0) payload = payload.substring(0, cutQ);
    payload = payload.trim();
    if (payload.isEmpty) {
      throw ParseError('Profile link payload is empty.', raw: raw);
    }
    String json;
    try {
      json = _decodeBase64Payload(payload);
    } catch (_) {
      throw ParseError('Profile link payload is not valid base64.',
          raw: raw);
    }
    Object? root;
    try {
      root = jsonDecode(json);
    } catch (_) {
      throw ParseError('Profile link payload is not valid JSON.', raw: raw);
    }
    if (root is! Map) {
      throw ParseError('Profile link payload is not a profile object.',
          raw: raw);
    }
    final m = root.cast<String, dynamic>();
    final schema = m['schema'];
    if (schema != null && schema != _whiteDnsSchema) {
      throw ParseError('Unsupported profile schema: $schema', raw: raw);
    }
    final profile = m['profile'];
    if (profile is! Map) {
      throw ParseError('Profile link is missing its profile object.',
          raw: raw);
    }
    final server = (profile['server'] ?? const <String, dynamic>{}) as Map;
    final domain = '${server['domain'] ?? ''}'
        .trim()
        .replaceFirst(RegExp(r'\.+$'), '');
    final key = '${server['encryption_key'] ?? ''}'.trim();
    if (domain.isEmpty) {
      throw ParseError('Profile link is missing the tunnel domain.',
          raw: raw);
    }
    if (key.isEmpty) {
      throw ParseError('Profile link is missing the encryption key.',
          raw: raw);
    }
    final methodRaw = server['encryption_method'];
    final method = methodRaw is num
        ? methodRaw.toInt()
        : int.tryParse('$methodRaw') ?? 1;
    final name = '${profile['name'] ?? ''}'.trim();
    final forStorm = scheme != 'masterdns';
    return ProxyProfile(
      id: Ids.newId(),
      name: name.isEmpty ? '${forStorm ? 'StormDNS' : 'MasterDNSVPN'} $domain' : name,
      server: domain,
      port: 53,
      protocol: forStorm ? ProxyProtocol.stormDns : ProxyProtocol.masterDnsVpn,
      core: forStorm ? CoreKind.stormDns : CoreKind.masterDnsVpn,
      password: key,
      rawParams: {
        'DOMAINS': domain,
        'DATA_ENCRYPTION_METHOD': '$method',
      },
      source: ProfileSource.uriImport,
    );
  }

  /// WhiteDNS-compatible export: `stormdns://<base64url(JSON)>#name`.
  String exportUri(ProxyProfile p) {
    final domain = (p.rawParams['DOMAINS'] ?? p.server)
        .split(',')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .firstOrNull ?? p.server;
    final method =
        int.tryParse(p.rawParams['DATA_ENCRYPTION_METHOD'] ?? '') ?? 1;
    final payload = jsonEncode({
      'schema': _whiteDnsSchema,
      'version': 1,
      'profile': {
        'name': p.name,
        'server': {
          'domain': domain,
          'encryption_key': p.password ?? '',
          'encryption_method': method,
        },
      },
    });
    final b64 = base64Url.encode(utf8.encode(payload)).replaceAll('=', '');
    return 'stormdns://$b64#${Uri.encodeComponent(p.name)}';
  }

  /// base64url (no padding, WhiteDNS `withoutPadding`) with a std-base64
  /// fallback, mirroring WhiteDNS's decodeProfilePayload.
  static String _decodeBase64Payload(String payload) {
    final padded =
        payload.padRight(payload.length + ((4 - payload.length % 4) % 4), '=');
    List<int> bytes;
    try {
      bytes = base64Url.decode(padded);
    } on FormatException {
      try {
        bytes = base64.decode(padded);
      } on FormatException {
        throw FormatException('invalid base64');
      }
    }
    return utf8.decode(bytes, allowMalformed: false);
  }
}
