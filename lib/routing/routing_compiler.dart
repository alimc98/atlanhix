import '../routing/routing_models.dart';

/// Compiles a routing profile + DNS settings into engine-specific rule sets.
class RoutingCompiler {
  /// sing-box `route.rules` entries (as maps ready for json encoding).
  /// Blocking uses the `reject` *action* (block outbound was removed in
  /// sing-box 1.13).
  List<Map<String, dynamic>> singBoxRules(RoutingProfile profile) {
    final rules = <Map<String, dynamic>>[];
    for (final r in profile.rules.where((r) => r.enabled)) {
      final rule = <String, dynamic>{};
      switch (r.action) {
        case RoutingAction.block:
          rule['action'] = 'reject';
        case RoutingAction.direct:
          rule['outbound'] = 'direct';
        case RoutingAction.proxy:
          rule['outbound'] = 'proxy';
        case RoutingAction.warp:
          rule['outbound'] = 'warp';
        case RoutingAction.chain:
          rule['outbound'] = r.chainId ?? 'proxy';
      }
      switch (r.matchType) {
        case RuleMatchType.domainFull:
          rule['domain'] = r.patterns;
        case RuleMatchType.domainSuffix:
          rule['domain_suffix'] = r.patterns
              .map((p) => p.startsWith('.') ? p.substring(1) : p)
              .toList();
        case RuleMatchType.domainKeyword:
          rule['domain_keyword'] = r.patterns;
        case RuleMatchType.ipCidr:
          rule['ip_cidr'] = r.patterns;
        case RuleMatchType.geoip:
          rule['geoip'] = r.patterns;
        case RuleMatchType.port:
          rule['port'] = r.patterns;
        case RuleMatchType.protocol:
          rule['port'] = r.patterns; // approximated via port after sniff
        case RuleMatchType.network:
          rule['network'] = r.patterns;
        case RuleMatchType.process:
          rule['process_name'] = r.patterns;
        case RuleMatchType.package:
          break; // enforced by VpnService allow/deny lists on Android
      }
      if (rule.length > 1) rules.add(rule);
    }
    return rules;
  }

  /// Xray `routing.rules` entries.
  List<Map<String, dynamic>> xrayRules(RoutingProfile profile,
      {required String proxyTag, required String warpTag}) {
    final rules = <Map<String, dynamic>>[];
    for (final r in profile.rules.where((r) => r.enabled)) {
      final tag = switch (r.action) {
        RoutingAction.direct => 'direct',
        RoutingAction.block => 'block',
        RoutingAction.proxy => proxyTag,
        RoutingAction.warp => warpTag,
        RoutingAction.chain => r.chainId ?? proxyTag,
      };
      final rule = <String, dynamic>{'outboundTag': tag};
      switch (r.matchType) {
        case RuleMatchType.domainFull:
          rule['domain'] = r.patterns.map((p) => 'full:$p').toList();
        case RuleMatchType.domainSuffix:
          rule['domain'] = r.patterns
              .map((p) =>
                  p.startsWith('.') ? 'domain:${p.substring(1)}' : 'domain:$p')
              .toList();
        case RuleMatchType.domainKeyword:
          rule['domain'] = r.patterns;
        case RuleMatchType.ipCidr:
          rule['ip'] = r.patterns;
        case RuleMatchType.geoip:
          rule['ip'] =
              r.patterns.map((p) => p.startsWith('geoip:') ? p : 'geoip:$p').toList();
        case RuleMatchType.port:
          rule['port'] = r.patterns.join(',');
        case RuleMatchType.protocol:
        case RuleMatchType.network:
        case RuleMatchType.process:
        case RuleMatchType.package:
          continue; // not directly expressible in Xray route rules
      }
      if (rule.length > 1) rules.add(rule);
    }
    return rules;
  }

  /// sing-box `dns` object for the selected DNS mode (§24).
  /// Legacy-compatible format chosen deliberately for broad engine-version
  /// support; documented in docs/ARCHITECTURE.md.
  Map<String, dynamic> singBoxDns(DnsSettings dns) {
    final servers = <Map<String, dynamic>>[];
    final rules = <Map<String, dynamic>>[];
    switch (dns.mode) {
      case DnsMode.system:
        servers.add({'tag': 'local', 'type': 'local'});
      case DnsMode.custom:
        servers.add({
          'tag': 'custom',
          'type': 'udp',
          'server': dns.primary ?? '1.1.1.1',
        });
      case DnsMode.doh:
        servers.add({
          'tag': 'doh',
          'type': 'https',
          'server': _hostOf(dns.dohUrl ?? 'https://dns.google/dns-query'),
          'path': _pathOf(dns.dohUrl ?? 'https://dns.google/dns-query'),
        });
      case DnsMode.dot:
        servers.add({
          'tag': 'dot',
          'type': 'tls',
          'server': dns.dotHost ?? 'dns.google',
        });
      case DnsMode.fakeip:
        servers.add({'tag': 'remote', 'type': 'https', 'server': '1.1.1.1'});
        servers.add({'tag': 'fakeip', 'type': 'fakeip'});
        rules.add({
          'query_type': ['A', 'AAAA'],
          'server': 'fakeip',
        });
      case DnsMode.automatic:
        servers.add({'tag': 'local', 'type': 'local'});
        servers.add({'tag': 'remote', 'type': 'https', 'server': '1.1.1.1'});
        // DEVICE EVIDENCE (Mi 9T / MCI): with both servers racing and no rule,
        // the carrier `local` resolver answered blocked domains first with a
        // private sinkhole IP (graph.facebook.com -> 10.10.34.36, TTL 600) —
        // poisoned responses won the race for every app query through the
        // tunnel. Automatic means "works on hostile networks": pin all traffic
        // DNS to the clean resolver. Users who want carrier-local resolution
        // pick DnsMode.system explicitly.
        rules.add({'server': 'remote'});
    }
    final dnsObj = <String, dynamic>{'servers': servers};
    if (dns.mode == DnsMode.fakeip) {
      dnsObj['fakeip'] = {
        'enabled': true,
        'inet4_range': '198.18.0.0/15',
        'inet6_range': 'fc00::/18',
      };
    }
    if (rules.isNotEmpty) dnsObj['rules'] = rules;
    return dnsObj;
  }

  static String _hostOf(String url) {
    final u = Uri.parse(url);
    return u.host.isEmpty ? url : u.host;
  }

  static String _pathOf(String url) {
    final u = Uri.parse(url);
    return u.path.isEmpty ? '/' : u.path;
  }
}

/// Validates that a compiled rule set does not swallow all traffic into a
/// loopback (a classic misconfiguration that kills connectivity).
class RouteSanityChecker {
  static const _loopbackHints = ['127.', '::1', 'localhost'];

  static bool profileWouldLoop(RoutingProfile p) {
    for (final r in p.rules) {
      if (r.action == RoutingAction.proxy &&
          r.matchType == RuleMatchType.domainSuffix) {
        for (final pat in r.patterns) {
          if (_loopbackHints.any(pat.contains)) return true;
        }
      }
    }
    return false;
  }
}
