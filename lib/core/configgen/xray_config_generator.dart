import '../../domain/entities/proxy_profile.dart';
import '../../routing/routing_compiler.dart';
import '../../routing/routing_models.dart';
import '../fragmentation/fragment_profiles.dart';
import 'outbound_builders.dart';
/// Generates a complete Xray-core client config for a single profile.
/// Xray runs as a local upstream of sing-box: one profile per process,
/// listening on [localSocksPort]; fragmentation is injected when eligible.
class XrayConfigGenerator {
  XrayConfigGenerator({this.builders = const OutboundBuilders()});

  final OutboundBuilders builders;
  final _compiler = RoutingCompiler();

  Map<String, dynamic> generate({
    required ProxyProfile profile,
    required int localSocksPort,
    required RoutingProfile routing,
    FragmentProfile? fragment,
    String dnsServer = '1.1.1.1',
    String? accessLogPath,
  }) {
    final proxyTag = 'proxy-out';
    final proxyOut =
        builders.xrayOutbound(profile, tag: proxyTag);
    if (proxyOut == null) {
      throw ArgumentError('Profile ${profile.id} is not Xray-runnable');
    }

      final useFragment = fragment != null &&
        profile.security != Security.none &&
        (profile.transport == Transport.tcp ||
            profile.transport == Transport.ws ||
            profile.transport == Transport.grpc ||
            profile.transport == Transport.xhttp ||
            profile.transport == Transport.h2);

    if (useFragment) {
      // Fragment the TLS client hello of the proxy connection itself:
      // proxy → fragment(freedom) → internet.
      (proxyOut['streamSettings'] as Map<String, dynamic>)['sockopt'] = {
        'dialerProxy': 'fragment-out',
      };
    }

    final routingRules = [
      {
        'type': 'field',
        'outboundTag': 'block',
        'protocol': ['bittorrent'],
      },
      ..._compiler.xrayRules(routing, proxyTag: proxyTag, warpTag: proxyTag),
    ];

    return {
      'log': {
        'loglevel': 'warning',
        if (accessLogPath != null) 'access': accessLogPath,
      },
      'dns': {
        'servers': [dnsServer, 'localhost'],
        'queryStrategy': 'UseIP',
      },
      'inbounds': [
        {
          'tag': 'socks-in',
          'listen': '127.0.0.1',
          'port': localSocksPort,
          'protocol': 'socks',
          'settings': {'auth': 'noauth', 'udp': true},
          'sniffing': {
            'enabled': true,
            'destOverride': ['http', 'tls', 'quic'],
          },
        },
      ],
      'outbounds': [
        if (useFragment) ...[
          {
            'protocol': 'freedom',
            'tag': 'fragment-out',
            'settings': {
              'domainStrategy': 'AsIs',
              'fragment': {
                'packets': fragment.packets,
                'length': fragment.length,
                'interval': fragment.interval,
              },
            },
          },
        ],
        proxyOut,
        {'protocol': 'freedom', 'tag': 'direct'},
        {'protocol': 'blackhole', 'tag': 'block'},
      ],
      'routing': {
        'domainStrategy': 'IPIfNonMatch',
        'rules': [
          ...routingRules,
          // UPSTREAM SEMANTICS: the front sing-box has already split
          // LAN/IRAN/domestic to direct — whatever arrives at this local
          // SOCKS is tunnel-bound traffic. Final rule must therefore be the
          // NODE, never direct (direct-on-MCI dies in TLS handshake;
          // measured on device 2026-09-15: 'socks-in -> direct' fails while
          // the same config passes on open networks).
          {'type': 'field', 'outboundTag': proxyTag, 'network': 'tcp,udp'},
        ],
      },
    };
  }
}
