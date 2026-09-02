import '../../domain/entities/proxy_profile.dart';
import '../../domain/errors/app_error.dart';
import '../common/uri_utils.dart';

/// hysteria2:// (and hy2://) password@host:port?sni=&insecure=&obfs=salamander&
/// obfs-password=&mport=30000-40000#name
/// Also parses hysteria:// v1 links (auth in userinfo, params) — best effort.
class Hysteria2Parser {
  ProxyProfile parse(String raw) {
    try {
      final uri = Uri.parse(raw);
      final isV2 = uri.scheme == 'hysteria2' || uri.scheme == 'hy2';
      if (!isV2 && uri.scheme != 'hysteria') {
        throw const FormatException('not hysteria');
      }
      final hp = UriUtils.parseHostPort(uri.authority);
      if (hp == null) throw const FormatException('bad host:port');
      final q = UriUtils.queryOf(uri);
      final name = UriUtils.stripFragment(uri.fragment) ??
          '${isV2 ? 'Hysteria2' : 'Hysteria'} ${hp.$1}';
      final password = Uri.decodeComponent(uri.userInfo);
      final mport = (q['mport'] ?? '').isEmpty ? null : q['mport'];
      return ProxyProfile(
        id: Ids.newId(),
        name: name,
        server: hp.$1,
        port: hp.$2,
        protocol: isV2 ? ProxyProtocol.hysteria2 : ProxyProtocol.hysteria,
        security: Security.tls, // QUIC TLS mandatory in hysteria2
        password: password,
        sni: (q['sni'] ?? q['peer'] ?? '').isEmpty ? null : q['sni'] ?? q['peer'],
        allowInsecure:
            q['insecure'] == '1' || q['allowInsecure'] == '1',
        hysteriaObfsPassword: (q['obfs-password'] ?? '').isEmpty
            ? null
            : q['obfs-password'],
        hysteriaUpMbps: int.tryParse(q['upmbps'] ?? q['up'] ?? ''),
        hysteriaDownMbps: int.tryParse(q['downmbps'] ?? q['down'] ?? ''),
        fingerprint: (q['fp'] ?? '').isEmpty ? null : q['fp'],
        rawParams: {
          ...q,
          if (mport != null) 'mport': mport,
        },
        rawConfig: raw,
        source: ProfileSource.uriImport,
      );
    } on FormatException catch (e) {
      throw ParseError('This Hysteria link is malformed.',
          likelyCauses: ['Expected hysteria2://password@server:port?params'],
          raw: '$raw (${e.message})');
    }
  }

  String export(ProxyProfile p) {
    final q = <String, String>{
      if (p.sni != null) 'sni': p.sni!,
      if (p.allowInsecure) 'insecure': '1',
      if (p.hysteriaObfsPassword != null) ...{
        'obfs': 'salamander',
        'obfs-password': p.hysteriaObfsPassword!,
      },
      if (p.rawParams['mport'] != null) 'mport': p.rawParams['mport']!,
    };
    final host = p.server.contains(':') ? '[${p.server}]' : p.server;
    return 'hysteria2://${Uri.encodeComponent(p.password ?? '')}@$host:'
        '${p.port}${q.isEmpty ? '' : '?${Uri(queryParameters: q).query}'}'
        '#${Uri.encodeComponent(p.name)}';
  }
}
