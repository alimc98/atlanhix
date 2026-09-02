import 'dart:convert';
import '../../domain/entities/proxy_profile.dart';
import '../../domain/errors/app_error.dart';
import '../common/uri_utils.dart';

/// vmess:// base64(JSON) — the v2rayN legacy format (still the most common),
/// plus `vmess1://` JSON passthrough.
class VmessParser {
  ProxyProfile parse(String raw) {
    if (raw.startsWith('vmess1://')) {
      return _fromJsonText(Uri.parse(raw).fragment, raw);
    }
    final body = raw.substring('vmess://'.length);
    final decoded = UriUtils.tryDecodeBase64(body);
    if (decoded != null && decoded.trim().startsWith('{')) {
      return _fromJsonText(decoded, raw);
    }
    // Some providers use qs-style: vmess://uuid@host:port?params (rare).
    try {
      final uri = Uri.parse(raw.replaceFirst('vmess://', 'vmess://'));
      final hp = UriUtils.parseHostPort(uri.authority);
      if (hp == null || uri.userInfo.isEmpty) {
        throw const FormatException('vmess authority/userinfo missing');
      }
      final q = UriUtils.queryOf(uri);
      return ProxyProfile(
        id: Ids.newId(),
        name: UriUtils.stripFragment(uri.fragment) ?? 'VMess ${hp.$1}',
        server: hp.$1,
        port: hp.$2,
        protocol: ProxyProtocol.vmess,
        transport: _transportOf(q['type'] ?? 'tcp'),
        security: (q['tls'] == 'true' || q['tls'] == '1')
            ? Security.tls
            : Security.none,
        uuid: uri.userInfo,
        alterId: int.tryParse(q['alterId'] ?? '0') ?? 0,
        encryption: q['encryption'] ?? 'auto',
        host: q['host'],
        path: q['path'],
        sni: q['sni'],
        rawConfig: raw,
        source: ProfileSource.uriImport,
      );
    } on FormatException {
      throw ParseError('This VMess link is malformed.',
          likelyCauses: ['Not a vmess:// base64 JSON or URI format'], raw: raw);
    }
  }

  ProxyProfile _fromJsonText(String text, String raw) {
    Map<String, dynamic> j;
    try {
      j = _decodeJson(text.startsWith('{') ? text : (UriUtils.tryDecodeBase64(text) ?? text));
    } on FormatException {
      throw ParseError('This VMess link is malformed.',
          likelyCauses: ['Base64 payload is not valid VMess JSON'], raw: raw);
    }
    String server = (j['add'] ?? j['address'] ?? '').toString();
    final port = int.tryParse((j['port'] ?? '').toString());
    final uuid = (j['id'] ?? '').toString();
    if (server.isEmpty || port == null || uuid.isEmpty) {
      throw ParseError('This VMess link is missing required fields.',
          likelyCauses: ['add/port/id must be present in the VMess JSON'],
          raw: raw);
    }
    final net = (j['net'] ?? 'tcp').toString();
    final tlsRaw = (j['tls'] ?? '').toString();
    final security = tlsRaw == 'tls' || tlsRaw == 'reality'
        ? Security.reality
        : (tlsRaw == 'tls' || tlsRaw == 'true'
            ? Security.tls
            : Security.none);
    final realityPk = (j['pbk'] ?? '').toString();
    final effSecurity = realityPk.isNotEmpty
        ? Security.reality
        : (tlsRaw == 'tls' || tlsRaw == 'true' ? Security.tls : security);
    return ProxyProfile(
      id: Ids.newId(),
      name: ((j['ps'] ?? '').toString()).isEmpty
          ? 'VMess $server'
          : (j['ps']).toString(),
      server: server,
      port: port,
      protocol: ProxyProtocol.vmess,
      transport: _transportOf(net),
      security: effSecurity,
      uuid: uuid,
      alterId: int.tryParse((j['aid'] ?? '0').toString()) ?? 0,
      encryption: (j['scy'] ?? 'auto').toString(),
      sni: (j['sni'] ?? j['host'] ?? '').toString().isNotEmpty
          ? (j['sni'] ?? j['host']).toString()
          : null,
      host: (j['host'] ?? '').toString().isNotEmpty ? j['host'].toString() : null,
      path: (j['path'] ?? '').toString().isNotEmpty ? j['path'].toString() : null,
      serviceName: (j['path'] ?? '').toString().startsWith('/')
          ? null
          : (j['path'] ?? '').toString(),
      fingerprint: (j['fp'] ?? '').toString().isNotEmpty ? j['fp'].toString() : null,
      allowInsecure: (j['allowInsecure'] ?? '').toString() == '1',
      alpn: ((j['alpn'] ?? '') as String).split(',').where((e) => e.isNotEmpty).toList(),
      realityPublicKey: realityPk.isEmpty ? null : realityPk,
      realityShortId: (j['sid'] ?? '').toString().isEmpty ? null : j['sid'].toString(),
      rawConfig: raw,
      source: ProfileSource.uriImport,
    );
  }

  static Map<String, dynamic> _decodeJson(String text) {
    final j = jsonDecode(text);
    if (j is! Map) throw const FormatException('not an object');
    return j.cast<String, dynamic>();
  }

  static Transport _transportOf(String net) => switch (net) {
        'ws' => Transport.ws,
        'grpc' || 'grpc-standard' => Transport.grpc,
        'h2' => Transport.h2,
        'httpupgrade' => Transport.httpupgrade,
        'xhttp' => Transport.xhttp,
        'kcp' => Transport.quic,
        'quic' => Transport.quic,
        _ => Transport.tcp,
      };
}
