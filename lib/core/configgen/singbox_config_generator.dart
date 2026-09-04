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
  });

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
  static Map<String, String> defaultResolver(DnsSettings dns) => {
        'server': switch (dns.mode) {
          DnsMode.system || DnsMode.automatic || DnsMode.fakeip => 'local',
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
    final outbounds = <Map<String, dynamic>>[];
    final endpoints = <Map<String, dynamic>>[];
    final tags = <String>[];

    // Materialize the WARP endpoint first if chaining is enabled.
    var warpTag = '';
    if (warpProfile != null) {
      warpTag = 'warp';
      final wEp = builders.singBoxWireguardEndpoint(warpProfile, tag: warpTag);
      if (wEp != null) endpoints.add(wEp);
    }

    for (final p in runnableProfiles) {
      final tag = 'node:${p.id}';
      final o = builders.singBoxOutbound(p, tag: tag,
          // Chained: the node's outbound dials through WARP (WARP outside).
          detourTag: warpProfile != null && chainWarpOutside ? warpTag : null);
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
          if (warpProfile != null && chainWarpOutside) 'detour': warpTag,
        });
        tags.add(tag);
      }
    }

    outbounds.add({
      'type': 'selector',
      'tag': 'proxy',
      'outbounds': tags.isEmpty ? ['direct'] : tags,
      'default':
          tags.contains(selectedTag) ? selectedTag : (tags.firstOrNull ?? 'direct'),
      'interrupt_exist_connections': true,
    });
    // NOTE: sing-box ≥1.13 removed the deprecated `block`/`dns` outbounds —
    // blocking/DNS-hijack are handled by route rule actions instead.
    outbounds.add({'type': 'direct', 'tag': 'direct'});

    final dnsObj = _compiler.singBoxDns(dns);
    // Ensure the server referenced by default_domain_resolver exists.
    final servers = dnsObj['servers'] as List;
    final resolverTag = SingBoxConfigGenerator.defaultResolver(dns)['server']!;
    if (!servers.any((s) => s['tag'] == resolverTag)) {
      servers.add({'tag': resolverTag, 'type': 'udp', 'server': '1.1.1.1'});
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
            'strict_route': true,
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
          // v0.3.2 (live validation finding): loopback/private destinations
          // must never be routed through a proxy node — the loopback E2E
          // probes (127.0.0.1 mock destinations) exposed this regression.
          {
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
