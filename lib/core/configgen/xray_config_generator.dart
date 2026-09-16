import 'dart:io' show Platform;

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

  /// Clean resolvers per platform (v0.4.6 desktop-Xray DNS fix).
  ///
  /// DEVICE EVIDENCE (carried over from routing_compiler.dart, Mi 9T/MCI):
  /// 1.1.1.1 (DoH, DoT and plain UDP/53) times out on IR mobile data, and
  /// the carrier `localhost` resolver poison-answers blocked domains with a
  /// private sinkhole (10.10.34.x). The same evidence applies to the Xray
  /// process: with `servers: [1.1.1.1, localhost]` Xray's DEFAULT serial
  /// query starts ROUND-ROBIN (verified vs Xray-core app/dns/dns.go
  /// serialQuery + sortClients — the first answer of the rotating order
  /// wins), so the poisoned carrier answer wins every second lookup and
  /// domain-addressed nodes (all xhttp CDN fronts) dial a dead IP.
  ///
  /// Desktop keeps the two global resolvers (the Iranian pair is
  /// carrier-internal and unreachable from abroad); Android uses the
  /// domestic pair measured reachable on-device. `localhost` is NEVER in
  /// the list — it can only re-introduce the poison race.
  static const _cleanDnsAndroid = ['178.22.122.100', '185.55.226.26'];
  static const _cleanDnsDesktop = ['8.8.8.8', '1.1.1.1'];

  static List<String> get defaultCleanServers =>
      Platform.isAndroid ? _cleanDnsAndroid : _cleanDnsDesktop;

  Map<String, dynamic> generate({
    required ProxyProfile profile,
    required int localSocksPort,
    required RoutingProfile routing,
    FragmentProfile? fragment,

    /// Explicit DNS override. When null (the DEFAULT and the only shape
    /// every caller should use) the platform-clean server pair above is
    /// emitted. Only tests/tools pass a value here.
    String? dnsServer,
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
      //
      // v0.4.6 FIX (engine-verified shape): Xray evaluates the dialer
      // (`sockopt.dialerProxy`) INSIDE the active security layer —
      // `tlsSettings.sockopt` for TLS and `realitySettings.sockopt` for
      // Reality. A sockopt placed at bare `streamSettings.sockopt` is
      // IGNORED once a security layer is active, so the old placement
      // silently ran unfragmented (the config still passed -test: an
      // unknown-toplevel sockopt is not a schema error, just a no-op).
      final stream = proxyOut['streamSettings'] as Map<String, dynamic>;
      final securityKey = switch (stream['security']) {
        'reality' => 'realitySettings',
        'tls' => 'tlsSettings',
        _ => null, // no security layer → nothing to fragment anyway
      };
      if (securityKey != null) {
        (stream[securityKey] as Map<String, dynamic>)['sockopt'] = {
          'dialerProxy': 'fragment-out',
        };
      }
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
        'loglevel': 'info',
        if (accessLogPath != null) 'access': accessLogPath,
      },
      'dns': {
        // v0.4.6 DESKTOP-XRAY DNS FIX: clean, platform-appropriate
        // resolvers; never `localhost` (carrier poison race — see the
        // class comment). Xray serial-query is round-robin by default, so
        // ONE poisoned server in the list is enough to kill the node
        // every other lookup.
        'servers': dnsServer != null
            ? [dnsServer, ...defaultCleanServers.where((s) => s != dnsServer)]
            : defaultCleanServers,
        // v0.4.4 audit fix: UseIP asks for A+AAAA — on IR mobile the AAAA
        // answers for domain-addressed nodes embed the 10.10.34.x sinkhole
        // over 6to4, so Xray itself dials a dead address and the TLS
        // handshake dies (Ghodrat root-cause #1). IPv4-only dialing; the
        // front sing-box already prefers IPv4 too.
        'queryStrategy': 'UseIPv4',
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
