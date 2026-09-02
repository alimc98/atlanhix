import '../../domain/entities/proxy_profile.dart';
import '../../domain/errors/app_error.dart';
import '../common/uri_utils.dart';

/// ss:// SIP002 + legacy base64 format.
/// SIP002: ss://base64url(method:password)@host:port#name
/// legacy: ss://base64url(method:password@host:port)#name
/// Optional plugin=... query param parsed into rawParams.
class ShadowsocksParser {
  ProxyProfile parse(String raw) {
    try {
      final uri = Uri.parse(raw);
      if (uri.scheme != 'ss') throw const FormatException('not ss');
      final name = UriUtils.stripFragment(uri.fragment) ?? 'SS node';
      String userInfo = uri.userInfo;
      String hostPort;
      if (userInfo.isEmpty) {
        // legacy: everything base64 after ss://
        final body = raw.substring('ss://'.length);
        var qIdx = body.indexOf('?');
        final hIdx = body.indexOf('#');
        if (hIdx >= 0 && (qIdx < 0 || hIdx < qIdx)) qIdx = hIdx;
        final b64Body = qIdx >= 0 ? body.substring(0, qIdx) : body;
        final rest = qIdx >= 0 ? body.substring(qIdx) : '';
        final decoded = UriUtils.tryDecodeBase64(b64Body);
        if (decoded == null || !decoded.contains('@')) {
          throw const FormatException('legacy ss decode failed');
        }
        final at = decoded.lastIndexOf('@');
        userInfo = Uri.encodeComponent(decoded.substring(0, at));
        hostPort = decoded.substring(at + 1) + rest;
        final legacyUri = Uri.parse('ss://$userInfo@$hostPort');
        return _fromParts(legacyUri, name, raw);
      }
      final decodedUser =
          UriUtils.tryDecodeBase64(Uri.decodeComponent(userInfo)) ??
              Uri.decodeComponent(userInfo);
      final methodPass = decodedUser.split(':');
      if (methodPass.length < 2) {
        throw const FormatException('method:password missing');
      }
      final hp = UriUtils.parseHostPort(uri.authority);
      if (hp == null) throw const FormatException('bad host:port');
      final q = UriUtils.queryOf(uri);
      final method = methodPass[0];
      final password = methodPass.sublist(1).join(':');
      return ProxyProfile(
        id: Ids.newId(),
        name: name,
        server: hp.$1,
        port: hp.$2,
        protocol: ProxyProtocol.shadowsocks,
        ssMethod: method,
        password: password,
        rawParams: q,
        rawConfig: raw,
        source: ProfileSource.uriImport,
      );
    } on FormatException catch (e) {
      throw ParseError('This Shadowsocks link is malformed.',
          likelyCauses: [
            'Expected SIP002 ss://base64(method:password)@host:port or legacy base64 form'
          ],
          raw: '$raw (${e.message})');
    }
  }

  ProxyProfile _fromParts(Uri uri, String name, String raw) {
    final hp = UriUtils.parseHostPort(uri.authority);
    if (hp == null) throw const FormatException('bad host:port');
    final rawUser = Uri.decodeComponent(uri.userInfo);
    final decodedUser = UriUtils.tryDecodeBase64(rawUser) ?? rawUser;
    final idx = decodedUser.indexOf(':');
    if (idx < 0) throw const FormatException('method:password missing');
    final q = UriUtils.queryOf(uri);
    return ProxyProfile(
      id: Ids.newId(),
      name: name,
      server: hp.$1,
      port: hp.$2,
      protocol: ProxyProtocol.shadowsocks,
      ssMethod: decodedUser.substring(0, idx),
      password: decodedUser.substring(idx + 1),
      rawParams: q,
      rawConfig: raw,
      source: ProfileSource.uriImport,
    );
  }

  String export(ProxyProfile p) {
    final userInfo = UriUtils.encodeBase64Url('${p.ssMethod}:${p.password}');
    final host = p.server.contains(':') ? '[${p.server}]' : p.server;
    return 'ss://$userInfo@$host:${p.port}#${Uri.encodeComponent(p.name)}';
  }

  /// Decode a whole subscription body that is one big base64 blob of URIs.
  static List<String> decodeUriList(String body) {
    final trimmed = body.trim();
    if (trimmed.startsWith('ss://') ||
        trimmed.startsWith('vmess://') ||
        trimmed.startsWith('vless://') ||
        trimmed.startsWith('trojan://') ||
        trimmed.startsWith('hysteria2://') ||
        trimmed.startsWith('tuic://')) {
      return trimmed
          .split(RegExp(r'\r?\n'))
          .map((l) => l.trim())
          .where((l) => l.isNotEmpty)
          .toList();
    }
    final decoded = UriUtils.tryDecodeBase64(trimmed);
    if (decoded != null && decoded.contains('://')) {
      return decoded
          .split(RegExp(r'\r?\n'))
          .map((l) => l.trim())
          .where((l) => l.isNotEmpty)
          .toList();
    }
    throw const FormatException('not a URI list');
  }
}
