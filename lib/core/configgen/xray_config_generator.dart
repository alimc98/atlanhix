import 'dart:io' show InternetAddress, InternetAddressType, Platform;

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

  /// v0.4.7 §loop-fix — every destination the :xray CHILD PROCESS dials
  /// directly (server IP + configured resolvers), expressed as ip_cidr
  /// prefixes for a front sing-box direct-outbound route rule.
  ///
  /// WHY (device evidence 2026-09-17, Mi 9T / Android 11): the child runs
  /// in the `:xray` process WITHOUT a VpnService.protect hook (gomobile
  /// libv2ray is banned next to libbox's go.Seq). Its sockets are therefore
  /// uid-routed into the TUN like any other app traffic; without an escape
  /// route they loop back into the child's own SOCKS listener — the tunnel
  /// log shows the child's outbound source `fdfe:dcba:9876::1` (the TUN's
  /// own address) failing with `software caused connection abort`.
  ///
  /// HOW: the front engine owns the TUN and dials with VpnService.protect
  /// (LibboxEngine.kt). A route rule `ip_cidr → direct` sends the child's
  /// server traffic to that protected dialer, out of the loop, without
  /// touching any other flow. The child's SOCKS stub (127.0.0.1) never
  /// matches a public ip_cidr, so no flow is ever double-wrapped. Desktop
  /// callers never hit this — no TUN, no loop.
  ///
  /// [profile] must be the BOOTSTRAP-PINNED variant when its host is a
  /// hostname: the loop can only be broken against the RESOLVED server IP.
  /// Hostname-based nodes still keep their server field as the pinned IP
  /// here (callers pin before generating the front config).
  static List<String> childDialBypassCidrs(
    ProxyProfile profile, {
    DnsSettings? dns,
  }) {
    final cidrs = <String>{};
    void addEntry(String raw) {
      var s = raw.trim();
      if (s.isEmpty || s.contains('://')) return; // URLs (DoH/DoT) skipped
      s = s.split('/').first; // drop any path residue
      if (s.startsWith('[')) {
        // [v6]:port → bare v6
        final close = s.indexOf(']');
        if (close == -1) return;
        s = s.substring(1, close);
      } else {
        // v4:port → v4 (a bare v6 keeps its colons; its tail is never all digits)
        final colon = s.indexOf(':');
        if (colon != -1 && RegExp(r'^\d+$').hasMatch(s.substring(colon + 1))) {
          s = s.substring(0, colon);
        }
      }
      final addr = InternetAddress.tryParse(s);
      if (addr == null) return; // hostname → cannot be a route prefix
      if (addr.isLoopback || addr.isLinkLocal || addr.isMulticast) return;
      if (addr.type == InternetAddressType.IPv4 &&
          _isPrivateV4(addr.address)) {
        return; // already direct via the front's ip_is_private rule
      }
      cidrs.add(addr.type == InternetAddressType.IPv6
          ? '${addr.address}/128'
          : '${addr.address}/32');
    }

    // The child's REAL dial targets: the (bootstrap-pinned) node server and
    // the resolvers the generator itself hands the child config.
    addEntry(profile.server);
    for (final s in defaultCleanServers) {
      addEntry(s);
    }
    // Defensive: a caller MAY pass explicit DNS entries (tests/tools); their
    // literal IPs are bypassed too so the child never dials into the loop.
    if (dns?.primary != null) addEntry(dns!.primary!);
    if (dns?.secondary != null) addEntry(dns!.secondary!);
    if (dns?.remoteOverride != null) addEntry(dns!.remoteOverride!);
    if (dns?.domesticOverride != null) addEntry(dns!.domesticOverride!);
    return cidrs.toList()..sort();
  }

  static bool _isPrivateV4(String ip) {
    final o = ip.split('.').map(int.tryParse).toList();
    if (o.length != 4 || o.any((e) => e == null)) return false;
    final a = o[0]!, b = o[1]!;
    return a == 10 ||
        (a == 172 && b >= 16 && b <= 31) ||
        (a == 192 && b == 168) ||
        (a == 100 && b >= 64 && b <= 127); // CGNAT (carrier data)
  }

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
      // v0.4.6 §xray-fix (verified against the Xray-core tree, 2026-09):
      // `sockopt.dialerProxy` is read from the OUTBOUND'S streamSettings —
      // app/proxyman/outbound/handler.go passes h.streamSettings into
      // internet.Dial → DialSystem, which redirects the connection to the
      // named outbound (transport/internet/dialer.go). tlsSettings /
      // realitySettings are TLS Config protos and have NO sockopt field, so
      // a sockopt nested there is silently dropped (config still passes
      // -test — an unknown field inside the security layer is not a schema
      // error, just a no-op) and the node ran UNFRAGMENTED. Canonical
      // placement is streamSettings.sockopt — exactly what every mainstream
      // client emits for this chain.
      final stream = proxyOut['streamSettings'] as Map<String, dynamic>;
      final secured = stream['security'] == 'tls' ||
          stream['security'] == 'reality';
      if (secured) {
        stream['sockopt'] = {'dialerProxy': 'fragment-out'};
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
              // v0.4.6 §xray-fix: UseIPv4, never AsIs. With dialerProxy the
              // freedom outbound performs the REAL dial of the node's IP —
              // and `AsIs` hands that resolution to the OS resolver
              // (DialSystem only consults Xray's DNS module when a
              // domainStrategy is set), i.e. the poisoned carrier resolver
              // this whole class of fixes exists to bypass. UseIPv4 routes
              // the lookup through the `dns` object above (clean pair +
              // UseIPv4) — matching the non-fragment dial path.
              'domainStrategy': 'UseIPv4',
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
