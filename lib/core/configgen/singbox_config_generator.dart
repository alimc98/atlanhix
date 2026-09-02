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

  /// [upstreams] maps profileId → the outbound the engine should dial.
  /// Returns the config map; encode with jsonEncode.
  Map<String, dynamic> generate({
    required List<ProxyProfile> runnableProfiles,
    required RoutingProfile routing,
    required DnsSettings dns,
    SingBoxOptions options = const SingBoxOptions(),
    required String selectedTag,
  }) {
    final outbounds = <Map<String, dynamic>>[];
    final endpoints = <Map<String, dynamic>>[];
    final tags = <String>[];

    for (final p in runnableProfiles) {
      final tag = 'node:${p.id}';
      final o = builders.singBoxOutbound(p, tag: tag);
      if (o != null) {
        outbounds.add(o);
        tags.add(tag);
        continue;
      }
      final ep = builders.singBoxWireguardEndpoint(p, tag: tag);
      if (ep != null) {
        endpoints.add(ep);
        tags.add(tag);
      }
    }

    outbounds.add({
      'type': 'selector',
      'tag': 'proxy',
      'outbounds': tags.isEmpty ? ['direct'] : tags,
      'default': tags.contains(selectedTag) ? selectedTag : (tags.firstOrNull ?? 'direct'),
      'interrupt_exist_connections': true,
    });
    outbounds.addAll([
      {'type': 'direct', 'tag': 'direct'},
      {'type': 'block', 'tag': 'block'},
      {'type': 'dns', 'tag': 'dns-out'},
    ]);

    final dnsObj = _compiler.singBoxDns(dns);

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
          ..._compiler.singBoxRules(routing),
        ],
        'final': 'proxy',
        'auto_detect_interface': true,
      },
      'experimental': {
        'clash_api': {
          'external_controller': '127.0.0.1:${options.clashApiPort}',
          'secret': options.clashApiSecret,
          'default_mode': 'Rule',
        },
        'cache_file': {'enabled': true},
      },
    };
  }
}
