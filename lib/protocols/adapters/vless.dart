import '../../domain/entities/proxy_profile.dart';
import '../../domain/errors/app_error.dart';
import '../common/uri_utils.dart';

/// vless://uuid@host:port?encryption=none&security=reality|tls&sni=&fp=&pbk=&
/// sid=&type=ws|grpc|tcp|xhttp|httpupgrade&flow=xtls-rprx-vision&path=&host=&
/// serviceName=&headerType=#name
class VlessParser {
  ProxyProfile parse(String raw) {
    try {
      final uri = Uri.parse(raw);
      if (uri.scheme != 'vless') throw const FormatException('not vless');
      if (uri.userInfo.isEmpty) throw const FormatException('missing uuid');
      final hp = UriUtils.parseHostPort(uri.authority);
      if (hp == null) throw const FormatException('bad host:port');
      final q = UriUtils.queryOf(uri);
      final security = switch (q['security']) {
        'reality' => Security.reality,
        'tls' => Security.tls,
        _ => Security.none,
      };
      final type = q['type'] ?? 'tcp';
      final transport = switch (type) {
        'ws' => Transport.ws,
        'grpc' => Transport.grpc,
        'h2' => Transport.h2,
        'httpupgrade' => Transport.httpupgrade,
        'xhttp' => Transport.xhttp,
        _ => Transport.tcp,
      };
      final sni = q['sni'] ?? q['host'];
      return ProxyProfile(
        id: Ids.newId(),
        name: UriUtils.stripFragment(uri.fragment) ?? 'VLESS ${hp.$1}',
        server: hp.$1,
        port: hp.$2,
        protocol: ProxyProtocol.vless,
        transport: transport,
        security: security,
        uuid: Uri.decodeComponent(uri.userInfo),
        encryption: q['encryption'] ?? 'none',
        flow: (q['flow'] ?? '').isEmpty ? null : q['flow'],
        path: (q['path'] ?? '').isEmpty ? null : Uri.decodeFull(q['path']!),
        host: (q['host'] ?? '').isEmpty ? null : Uri.decodeFull(q['host']!),
        serviceName: (q['serviceName'] ?? '').isEmpty ? null : q['serviceName'],
        sni: (sni ?? '').isEmpty ? null : Uri.decodeFull(sni!),
        fingerprint: (q['fp'] ?? '').isEmpty ? null : q['fp'],
        allowInsecure: q['allowInsecure'] == '1' || q['insecure'] == '1',
        alpn: (q['alpn'] ?? '')
            .split(',')
            .where((e) => e.isNotEmpty)
            .map(Uri.decodeFull)
            .toList(),
        realityPublicKey: (q['pbk'] ?? '').isEmpty ? null : q['pbk'],
        realityShortId: (q['sid'] ?? '').isEmpty ? null : q['sid'],
        realitySpiderX: (q['spx'] ?? '').isEmpty ? null : Uri.decodeFull(q['spx']!),
        rawParams: q,
        rawConfig: raw,
        source: ProfileSource.uriImport,
      );
    } on FormatException catch (e) {
      throw ParseError('This VLESS link is malformed.',
          likelyCauses: [
            'Expected vless://uuid@server:port with transport/security params'
          ],
          raw: '$raw (${e.message})');
    }
  }

  /// Export back to vless:// share URI (used by node export & QR).
  String export(ProxyProfile p) {
    final q = <String, String>{
      'encryption': p.encryption ?? 'none',
      if (p.security != Security.none)
        'security': p.security == Security.reality ? 'reality' : 'tls',
      if (p.sni != null) 'sni': p.sni!,
      if (p.fingerprint != null) 'fp': p.fingerprint!,
      if (p.realityPublicKey != null) 'pbk': p.realityPublicKey!,
      if (p.realityShortId != null) 'sid': p.realityShortId!,
      if (p.realitySpiderX != null) 'spx': p.realitySpiderX!,
      'type': switch (p.transport) {
        Transport.ws => 'ws',
        Transport.grpc => 'grpc',
        Transport.h2 => 'h2',
        Transport.httpupgrade => 'httpupgrade',
        Transport.xhttp => 'xhttp',
        _ => 'tcp',
      },
      if (p.flow != null) 'flow': p.flow!,
      if (p.path != null) 'path': p.path!,
      if (p.host != null) 'host': p.host!,
      if (p.serviceName != null) 'serviceName': p.serviceName!,
      if (p.allowInsecure) 'allowInsecure': '1',
    };
    final userInfo = Uri.encodeComponent(p.uuid ?? '');
    final host = p.server.contains(':') ? '[${p.server}]' : p.server;
    return 'vless://$userInfo@$host:${p.port}?'
        '${Uri(queryParameters: q).query.replaceFirst('%3A', ':')}'
        '#${Uri.encodeComponent(p.name)}';
  }
}
