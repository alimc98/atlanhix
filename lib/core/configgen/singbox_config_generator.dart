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

    /// v0.4.7 §loop-fix: server/resolver IPs the :xray CHILD process dials
    /// directly. Emitted as `ip_cidr → direct` route rules so the child's
    /// sockets (which cannot call VpnService.protect) escape the TUN through
    /// the front engine's protected dialer instead of looping into its own
    /// SOCKS listener (`software caused connection abort`, Mi 9T 2026-09-17).
    /// Empty on desktop and for native sing-box nodes — no behavior change.
    List<String> bypassCidrs = const [],
  }) {
    // v0.4.4: the TLS-fragment pill flows in via options — rebuild the
    // builders with it (stateless, deterministic).
    final builders = options.tlsFragment
        ? const OutboundBuilders(tlsFragment: true)
        : this.builders;
    final outbounds = <Map<String, dynamic>>[];
    final endpoints = <Map<String, dynamic>>[];
    final tags = <String>[];

    // Materialize the WARP endpoint first when a WARP profile is present.
    //
    // Three topologies (v0.4.8 §user — the two explicit chain directions
    // the user described + the selector-member default):
    //
    //  * `warpFirst` (warpOutside) — the NODE dials through WARP
    //    (`detour: warp` on the node outbound): traffic flows
    //    app → node → WARP → internet. For nodes whose SERVER IP/SPN is
    //    blocked so the node handshake itself needs an exit outside the
    //    censor... more precisely per the user: WARP FIRST, then the
    //    (filtered) config — app → WARP → node → internet. Implemented as
    //    the WARP endpoint detouring through the node? NO — detour is a
    //    DIAL path: node `detour: warp` = node's socket is dialed FROM
    //    inside the WARP tunnel = app → WARP → node → internet. WARP is
    //    the first hop the user asked for.
    //
    //  * `selectedWarpTag != null` (warpLast) — the node connects DIRECT
    //    and the WARP endpoint itself detours through it: app → node →
    //    WARP → internet. The sanctions-evasion shape: the observed exit
    //    IP is Cloudflare's.
    //
    //  * neither flag — WARP is a plain selector MEMBER (manual switch).
    var warpTag = '';
    final warpAsLastHop = selectedWarpTag != null;
    final warpFirst = warpProfile != null && !warpAsLastHop && chainWarpOutside;
    if (warpProfile != null) {
      warpTag = 'warp';
      final firstNodeTag = runnableProfiles.isEmpty
          ? null
          : 'node:${runnableProfiles.first.id}';
      // v0.4.9 §user-fix (warp-last was dead on device): the warp endpoint's
      // detour binds the warp HANDSHAKE to a dial path. Binding it to
      // `firstNodeTag` meant the chain ignored the user's selected node —
      // with a multi-node pool the session exited through the FIRST pool
      // member regardless of the pick (and a selection change rebuilt the
      // binding only because the whole config was rebuilt). Bind to the
      // SELECTED node; fall back to the first member only when the selection
      // is not in the pool (stale id after a subscription refresh).
      final selectedInPool =
          runnableProfiles.any((p) => 'node:${p.id}' == selectedTag);
      final exitNodeTag = warpAsLastHop
          ? (selectedInPool ? selectedTag : firstNodeTag)
          : null;
      final wEp = builders.singBoxWireguardEndpoint(warpProfile,
          tag: warpTag,
          detourTag: exitNodeTag);
      if (wEp != null) endpoints.add(wEp);
    }

    for (final p in runnableProfiles) {
      final tag = 'node:${p.id}';
      // v0.4.9 §user-fix ("test all still red on device"): a batch probe
      // runs with NO :xray child process. A socks stub for a detected-Xray
      // node pointed at a dead 127.0.0.1:port and the delay test measured
      // a guaranteed failure — polluting HealthStore with fake deads AND
      // dominating the selector. The node is simply not buildable HERE:
      // skip it so the caller reports 'engine-off' (honest) instead of
      // 'timeout' (a lie). v0.4.9 §connect-fix: ONLY when no live upstream
      // port is provided — a map entry with a REAL local port (the front
      // session's :xray child) must still emit the stub, or every
      // Xray-owned connect died on a native sing-box outbound instead
      // (regression caught on device: first tap on a PQ/vless node died).
      final up0 = socksUpstreams[p.id];
      if (up0 == null &&
          (p.effectiveCore == CoreKind.xray ||
              p.transport == Transport.xhttp)) {
        continue;
      }
      final o = builders.singBoxOutbound(p, tag: tag,
          // warpFirst: the node's own socket is dialed through the WARP
          // tunnel — app → WARP → node → internet (WARP masks the node
          // handshake from the censor; see topology comment above).
          detourTag: warpFirst ? warpTag : null);
      if (o != null) {
        outbounds.add(o);
        tags.add(tag);
        continue;
      }
      final ep = builders.singBoxWireguardEndpoint(p, tag: tag,
          // v0.4.9 §user-fix (warp-first was a NO-OP for WG nodes): only
          // TCP/UDP outbounds received the detour — a WireGuard NODE
          // dialed straight out, so the chain silently degraded to plain.
          // A WG endpoint dials through another endpoint just like an
          // outbound does (`detour` on the endpoint = its dial path).
          detourTag: warpFirst ? warpTag : null);
      if (ep != null) {
        endpoints.add(ep);
        tags.add(tag);
        continue;
      }
      final up = socksUpstreams[p.id];
      if (up != null) {
        // v0.4.9 §user-fix (warp-first crashed Xray nodes): this stub
        // points at the LOCAL :xray child (127.0.0.1). `detour: warp`
        // wrapped those LOOPBACK dials in the WARP tunnel — Cloudflare
        // cannot route 127.0.0.1, so the child never answered and every
        // warp-first connect with an Xray-core node died. The child dials
        // the node itself on its own protected/direct path (the v0.4.7
        // loop-fix), so the stub stays direct; the detour is only kept
        // for a hypothetical non-local upstream.
        final local = up.host == '127.0.0.1' ||
            up.host == 'localhost' ||
            up.host == '::1';
        outbounds.add({
          'type': 'socks',
          'tag': tag,
          'server': up.host,
          'server_port': up.port,
          'version': '5',
          if (warpFirst && !local) 'detour': warpTag,
        });
        tags.add(tag);
      }
    }

    // Selector: node tags + the WARP tag when a WARP profile exists. In the
    // warpLast (sanctions-evasion) shape the warp endpoint is the DEFAULT —
    // every session flows node → WARP → internet (Cloudflare exit IP). In
    // the warpFirst shape the selected NODE is the default (its detour is
    // what creates the WARP-first hop; selecting "warp" bare would bypass
    // the node entirely and give a plain WARP session).
    final members = [...tags, if (warpProfile != null) warpTag];
    final defaultTag = warpAsLastHop && members.contains(warpTag)
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
    // v0.4.9 §user-fix (warp-last rescue member): in the warp-last shape the
    // `warp` endpoint's dial path rides the SELECTED node — if that node's
    // outbound is unavailable at runtime, a selector fallback into `warp`
    // would dead-end (no member left to dial). `warp:direct` is a warp
    // endpoint dialing straight out (plain WARP session) so the selector
    // always retains a working last-member. It must be added AFTER the warp
    // endpoint exists, and it is deliberately NOT the default member.
    if (warpAsLastHop && endpoints.any((e) => e['tag'] == warpTag)) {
      final directWarp = builders.singBoxWireguardEndpoint(warpProfile!,
          tag: 'warp:direct');
      if (directWarp != null) {
        endpoints.add(directWarp);
        members.add('warp:direct');
      }
    }

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
          // v0.4.7 §loop-fix — BEFORE the proxy final: the child :xray
          // process has no protect hook; its server/resolver dials ride
          // this direct rule to the front's protected socket. Order matters:
          // these must never be shadowed by a user rule or the final.
          for (final cidr in bypassCidrs)
            {
              'action': 'route',
              'ip_cidr': [cidr],
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
