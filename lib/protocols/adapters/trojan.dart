import '../../domain/entities/proxy_profile.dart';
import '../../domain/errors/app_error.dart';
import '../common/uri_utils.dart';

/// trojan://password@host:port?security=tls&sni=&type=&path=&host=#name
class TrojanParser {
  ProxyProfile parse(String raw) {
    try {
      final uri = Uri.parse(raw);
      if (uri.scheme != 'trojan') throw const FormatException('not trojan');
      final hp = UriUtils.parseHostPort(uri.authority);
      if (hp == null) throw const FormatException('bad host:port');
      final q = UriUtils.queryOf(uri);
      final security = q['security'] == 'tls' || q['security'] == null
          ? Security.tls
          : (q['security'] == 'reality' ? Security.reality : Security.none);
      final type = q['type'] ?? 'tcp';
      return ProxyProfile(
        id: Ids.newId(),
        name: UriUtils.stripFragment(uri.fragment) ?? 'Trojan ${hp.$1}',
        server: hp.$1,
        port: hp.$2,
        protocol: ProxyProtocol.trojan,
        transport: switch (type) {
          'ws' => Transport.ws,
          'grpc' => Transport.grpc,
          'h2' => Transport.h2,
          'httpupgrade' => Transport.httpupgrade,
          _ => Transport.tcp,
        },
        security: security,
        password: Uri.decodeComponent(uri.userInfo),
        sni: (q['sni'] ?? q['peer'] ?? '').isEmpty ? null : q['sni'] ?? q['peer'],
        fingerprint: (q['fp'] ?? '').isEmpty ? null : q['fp'],
        allowInsecure:
            q['allowInsecure'] == '1' || q['insecure'] == '1',
        alpn: (q['alpn'] ?? '')
            .split(',')
            .where((e) => e.isNotEmpty)
            .map(Uri.decodeFull)
            .toList(),
        path: (q['path'] ?? '').isEmpty ? null : Uri.decodeFull(q['path']!),
        host: (q['host'] ?? '').isEmpty ? null : Uri.decodeFull(q['host']!),
        serviceName: (q['serviceName'] ?? '').isEmpty ? null : q['serviceName'],
        rawParams: q,
        rawConfig: raw,
        source: ProfileSource.uriImport,
      );
    } on FormatException catch (e) {
      throw ParseError('This Trojan link is malformed.',
          likelyCauses: ['Expected trojan://password@server:port'],
          raw: '$raw (${e.message})');
    }
  }

  String export(ProxyProfile p) {
    final q = <String, String>{
      'security': p.security == Security.reality
          ? 'reality'
          : (p.security == Security.tls ? 'tls' : 'none'),
      if (p.sni != null) 'sni': p.sni!,
      'type': switch (p.transport) {
        Transport.ws => 'ws',
        Transport.grpc => 'grpc',
        Transport.h2 => 'h2',
        Transport.httpupgrade => 'httpupgrade',
        _ => 'tcp',
      },
      if (p.path != null) 'path': p.path!,
      if (p.host != null) 'host': p.host!,
      if (p.serviceName != null) 'serviceName': p.serviceName!,
      if (p.allowInsecure) 'allowInsecure': '1',
    };
    final host = p.server.contains(':') ? '[${p.server}]' : p.server;
    return 'trojan://${Uri.encodeComponent(p.password ?? '')}@$host:${p.port}?'
        '${Uri(queryParameters: q).query}#${Uri.encodeComponent(p.name)}';
  }
}
