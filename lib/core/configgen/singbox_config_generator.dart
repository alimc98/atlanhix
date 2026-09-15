import '../../domain/entities/proxy_profile.dart';
import '../../routing/routing_compiler.dart';
import '../../routing/routing_models.dart';
import 'outbound_builders.dart';

/// Runtime options that shape the generated sing-box client config.
class SingBoxOptions {
  const SingBoxOptions({
    this.mixedPort = 2080,
    this.clashApiPort = 9097,
    this.clashApiSecret = 'nexus-local',
    this.enableTun = false,
    this.tunMtu = 9000,
    this.logLevel = 'info',
    this.tlsFragment = false,
  });

  /// v0.4.4 mockup pill: TLS client-hello fragmentation (sing-box >=1.11
  /// `tls.fragment`) applied to TCP-TLS outbounds when the user opts in.
  final bool tlsFragment;

  final int mixedPort;
  final int clashApiPort;
  final String clashApiSecret;
  final bool enableTun;
  final int tunMtu;
  final String logLevel;
}

/// Generates a complete sing-box client configuration.
///
/// Architecture: sing-box **always** owns the inbounds (mixed/TUN), DNS and
/// routing. A `selector` outbound tagged `proxy` contains every runnable
/// upstream so switching is a Clash-API call without touching the process.
/// Non-sing-box engines (Xray, mdvpn) appear as SOCKS upstreams on their
/// assigned local ports.
class SingBoxConfigGenerator {
  SingBoxConfigGenerator({this.builders = const OutboundBuilders()});

  final OutboundBuilders builders;
  final _compiler = RoutingCompiler();

  /// The resolver referenced by `route.default_domain_resolver`
  /// (required since sing-box 1.12).
  ///
  /// DEVICE EVIDENCE (Mi 9T, MCI, 2026-09-13): the carrier `local` resolver
  /// poison-answerS blocked node domains — `us.hixyz.ir` and even
  /// graph.facebook.com resolved to a sinkhole (10.10.34.36) while the real
  /// address is 192.227.211.124. Outbound bootstrap through `local` then
  /// dials the sinkhole and dies with `tls: Connection terminated during
  /// handshake`. So automatic/fakeip bootstrap through the clean `remote`
  /// resolver (1.1.1.1), which the config always carries or auto-adds.
  /// Explicit user DNS choices (custom/doh/dot) and a deliberate
  /// DnsMode.system are honored as selected.
  static Map<String, String> defaultResolver(DnsSettings dns) => {
        'server': switch (dns.mode) {
          DnsMode.automatic || DnsMode.fakeip => 'remote',
          DnsMode.system => 'local',
          DnsMode.custom => 'custom',
          DnsMode.doh => 'doh',
          DnsMode.dot => 'dot',
        },
      };

  /// [socksUpstreams] maps profileId → local host:port of an external engine
  /// (Xray local SOCKS, MasterDNSVPN SOCKS). Profiles listed here are exposed
  /// inside the sing-box selector as SOCKS stubs so the front engine can
  /// hot-switch to them (Phase 5 fast switching).
  ///
  /// [chainWarpOutside] — WARP **traffic chaining** (v0.3.0 §8). When set and
  /// [warpProfile] is provided, the WARP WireGuard endpoint is materialized
  /// and the selected node's outbound dials *through* it (`detour: warp`),
  /// i.e. traffic flows node → WARP → internet. When false, WARP is the
  /// first hop: traffic flows warp-endpoint → node → internet. The selector
  /// always contains both plain and chained tags so switching is a Clash-API
  /// call. Never a separate "WARP running" indicator — the chain is real
  /// only when traffic traverses both outbounds (E2E-verified via the outer
  /// engine's counters/log).
  Map<String, dynamic> generate({
    required List<ProxyProfile> runnableProfiles,
    required RoutingProfile routing,
    required DnsSettings dns,
    SingBoxOptions options = const SingBoxOptions(),
    required String selectedTag,
    Map<String, ({String host, int port})> socksUpstreams = const {},
    ProxyProfile? warpProfile,
    bool chainWarpOutside = true,
    String? selectedWarpTag,
  }) {
    // v0.4.4: the TLS-fragment pill flows in via options — rebuild the
    // builders with it (stateless, deterministic).
    final builders = options.tlsFragment
        ? const OutboundBuilders(tlsFragment: true)
        : this.builders;
    final outbounds = <Map<String, dynamic>>[];
    final endpoints = <Map<String, dynamic>>[];
    final tags = <String>[];

    // Materialize the WARP endpoint first if chaining is enabled.
    //
    // Two directions:
    //  * chainWarpOutside=true  — the NODE dials through WARP (`detour: warp`
    //    on the node outbound): WARP is the outer tunnel.
    //  * selectedWarpTag != null — the v0.4.3 user-requested chain
    //    "config → WARP → Cloudflare IP": the node connects DIRECT and the
    //    WARP endpoint itself detours through it, so WARP is the LAST hop and
    //    the observed exit IP is Cloudflare's. The selector then defaults to
    //    the warp endpoint tag (route final = proxy = warp = node = internet).
    var warpTag = '';
    final warpAsLastHop = selectedWarpTag != null;
    if (warpProfile != null) {
      warpTag = 'warp';
      final firstNodeTag = runnableProfiles.isEmpty
          ? null
          : 'node:${runnableProfiles.first.id}';
      final wEp = builders.singBoxWireguardEndpoint(warpProfile,
          tag: warpTag,
          detourTag: warpAsLastHop ? firstNodeTag : null);
      if (wEp != null) endpoints.add(wEp);
    }

    for (final p in runnableProfiles) {
      final tag = 'node:${p.id}';
      final o = builders.singBoxOutbound(p, tag: tag,
          // Chained: the node's outbound dials through WARP (WARP outside).
          // Not when WARP is the LAST hop — then the plain node is the detour.
          detourTag: warpProfile != null &&
                  chainWarpOutside &&
                  !warpAsLastHop
              ? warpTag
              : null);
      if (o != null) {
        outbounds.add(o);
        tags.add(tag);
        continue;
      }
      final ep = builders.singBoxWireguardEndpoint(p, tag: tag);
      if (ep != null) {
        endpoints.add(ep);
        tags.add(tag);
        continue;
      }
      final up = socksUpstreams[p.id];
      if (up != null) {
        outbounds.add({
          'type': 'socks',
          'tag': tag,
          'server': up.host,
          'server_port': up.port,
          'version': '5',
          if (warpProfile != null &&
                  chainWarpOutside &&
                  !warpAsLastHop)
            'detour': warpTag,
        });
        tags.add(tag);
      }
    }

    // Last-hop chain: the warp endpoint joins the selector and wins by
    // default, so every session flows node → WARP → internet (Cloudflare IP).
    final members = [...tags, if (warpAsLastHop && warpTag.isNotEmpty) warpTag];
    final defaultTag = warpAsLastHop && warpTag.isNotEmpty && members.contains(warpTag)
        ? warpTag
        : (tags.contains(selectedTag) ? selectedTag : (tags.firstOrNull ?? 'direct'));
    outbounds.add({
      'type': 'selector',
      'tag': 'proxy',
      'outbounds': members.isEmpty ? ['direct'] : members,
      'default': defaultTag,
      'interrupt_exist_connections': true,
    });
    // NOTE: sing-box ≥1.13 removed the deprecated `block`/`dns` outbounds —
    // blocking/DNS-hijack are handled by route rule actions instead.
    // `connect_timeout` is NOT cosmetic: sing-box marks a direct outbound
    // EMPTY (IsEmpty, v1.14 protocol/direct/outbound.go) when its dialer
    // options are all defaults, and then REFUSES any DNS server that
    // detours through it — "detour to an empty direct outbound makes no
    // sense" killed every engine start on the Mi 9T (2026-09-15). A real
    // dialer option makes the outbound usable as the bootstrap detour.
    outbounds.add({
      'type': 'direct',
      'tag': 'direct',
      'connect_timeout': '5s',
    });

    final dnsObj = _compiler.singBoxDns(dns);
    // Ensure the server referenced by default_domain_resolver exists.
    final servers = dnsObj['servers'] as List;
    final resolverTag = SingBoxConfigGenerator.defaultResolver(dns)['server']!;
    if (!servers.any((s) => s['tag'] == resolverTag)) {
      // Domestic clean UDP resolver: 1.1.1.1 is unreachable from IR mobile
      // data (measured on Mi 9T / MCI 2026-09-13).
      servers.add({
        'tag': resolverTag,
        'type': 'udp',
        'server': '178.22.122.100',
      });
    }

    return {
      'log': {
        'level': options.logLevel,
        'timestamp': true,
      },
      'dns': dnsObj,
      'inbounds': [
        {
          'type': 'mixed',
          'tag': 'mixed-in',
          'listen': '127.0.0.1',
          'listen_port': options.mixedPort,
        },
        if (options.enableTun)
          {
            'type': 'tun',
            'tag': 'tun-in',
            'address': ['172.19.0.1/30', 'fdfe:dcba:9876::1/126'],
            'mtu': options.tunMtu,
            'auto_route': true,
            // strict_route false (device 2026-09-15): its netfilter rules
          // apply to the app uid INCLUDING the protected sockets that
          // dial the node itself → SYN routed back into tun0 → dial
          // i/o timeouts while a shell `nc` connects instantly. The
          // engine's own protect() keeps loop bypass safe without it.
          'strict_route': false,
            'stack': 'mixed',
          },
      ],
      'outbounds': outbounds,
      if (endpoints.isNotEmpty) 'endpoints': endpoints,
      'route': {
        'rules': [
          {'action': 'sniff'},
          {
            'protocol': 'dns',
            'action': 'hijack-dns',
          },
          // ALWAYS-ON (v0.4.4 device fix, 2026-09-15): private/LAN
          // destinations must never be routed through a proxy node — and
          // the clean DNS servers now carry `detour: direct`, which
          // sing-box 1.14 refuses when NOTHING references the direct
          // outbound ("start dns/udp[remote]: detour to an empty direct
          // outbound makes no sense"). This rule both fixes the engine
          // startup failure and keeps LAN/loopback honest (the old
          // opt-in gating by routing.rules.isNotEmpty left configs
          // without user rules with an EMPTY direct set — the exact
          // shape that crashed on the phone).
          {
            'action': 'route',
            'ip_is_private': true,
            'outbound': 'direct',
          },
          ..._compiler.singBoxRules(routing),
        ],
        'final': 'proxy',
        'auto_detect_interface': true,
        // Required since sing-box 1.12 (removed-as-deprecated in 1.14):
        // outbounds without an explicit `domain_resolver` use this server.
        'default_domain_resolver':
            SingBoxConfigGenerator.defaultResolver(dns),
      },
      'experimental': {
        'clash_api': {
          'external_controller': '127.0.0.1:${options.clashApiPort}',
          'secret': options.clashApiSecret,
          'default_mode': 'Rule',
        },
        // Disabled: cache-file acquire can time out on test/machine
        // filesystems; selector state persistence is not required since
        // NEXUS sets the selector explicitly on every start.
        'cache_file': {'enabled': false},
      },
    };
  }
}
