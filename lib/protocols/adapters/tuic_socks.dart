import '../../domain/entities/proxy_profile.dart';
import '../../domain/errors/app_error.dart';
import '../common/uri_utils.dart';

/// tuic://uuid:password@host:port?congestion_control=bbr&alpn=h3&sni=&
/// udp_relay_mode=native&allow_insecure=1#name
class TuicParser {
  ProxyProfile parse(String raw) {
    try {
      final uri = Uri.parse(raw);
      if (uri.scheme != 'tuic') throw const FormatException('not tuic');
      final hp = UriUtils.parseHostPort(uri.authority);
      if (hp == null) throw const FormatException('bad host:port');
      final q = UriUtils.queryOf(uri);
      final userPass = Uri.decodeComponent(uri.userInfo).split(':');
      return ProxyProfile(
        id: Ids.newId(),
        name: UriUtils.stripFragment(uri.fragment) ?? 'TUIC ${hp.$1}',
        server: hp.$1,
        port: hp.$2,
        protocol: ProxyProtocol.tuic,
        security: Security.tls,
        tuicUuid: userPass.isNotEmpty ? userPass[0] : null,
        tuicToken: userPass.length > 1 ? userPass[1] : null,
        sni: (q['sni'] ?? '').isEmpty ? null : q['sni'],
        allowInsecure: q['allow_insecure'] == '1' || q['insecure'] == '1',
        alpn: (q['alpn'] ?? 'h3')
            .split(',')
            .where((e) => e.isNotEmpty)
            .toList(),
        rawParams: q,
        rawConfig: raw,
        source: ProfileSource.uriImport,
      );
    } on FormatException catch (e) {
      throw ParseError('This TUIC link is malformed.',
          likelyCauses: ['Expected tuic://uuid:password@server:port'],
          raw: '$raw (${e.message})');
    }
  }
}

/// socks:// and http:// proxy links (user:pass@host:port#name).
class SocksHttpParser {
  ProxyProfile parse(String raw) {
    final uri = Uri.tryParse(raw);
    if (uri == null) {
      throw ParseError('This proxy link is malformed.', raw: raw);
    }
    final isSocks = uri.scheme == 'socks' || uri.scheme == 'socks5';
    if (!isSocks && uri.scheme != 'http' && uri.scheme != 'https') {
      throw ParseError('Unsupported proxy scheme: ${uri.scheme}', raw: raw);
    }
    final hp = UriUtils.parseHostPort(uri.authority);
    if (hp == null) {
      throw ParseError('This proxy link is missing host/port.', raw: raw);
    }
    final userPass = Uri.decodeComponent(uri.userInfo).split(':');
    return ProxyProfile(
      id: Ids.newId(),
      name: UriUtils.stripFragment(uri.fragment) ?? '${uri.scheme} ${hp.$1}',
      server: hp.$1,
      port: hp.$2,
      protocol: isSocks ? ProxyProtocol.socks : ProxyProtocol.http,
      password: userPass.length > 1 ? userPass[1] : null,
      uuid: userPass.isNotEmpty && userPass[0].isNotEmpty ? userPass[0] : null,
      rawConfig: raw,
      source: ProfileSource.uriImport,
    );
  }
}
