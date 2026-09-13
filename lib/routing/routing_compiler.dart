import 'dart:io' show Platform;

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
        // Same reasoning as automatic: foreign DNS is unreachable on IR
        // mobile data (measured 2026-09-13) → clean domestic UDP; desktop
        // keeps the global defaults (see automatic).
        servers.add(Platform.isAndroid
            ? {'tag': 'remote', 'type': 'udp', 'server': '178.22.122.100'}
            : {'tag': 'remote', 'type': 'udp', 'server': '1.1.1.1'});
        servers.add({'tag': 'fakeip', 'type': 'fakeip'});
        rules.add({
          'query_type': ['A', 'AAAA'],
          'server': 'fakeip',
        });
      case DnsMode.automatic:
        // DEVICE EVIDENCE (Mi 9T / MCI mobile data, 2026-09-13):
        //   * foreign DNS is unreachable: 1.1.1.1:443 (DoH), 8.8.8.8:853
        //     (DoT) and even 53/udp to 1.1.1.1/8.8.8.8 all time out.
        //   * the carrier `local` resolver poison-answers blocked domains
        //     with sinkholes: private 10.10.34.36 for A and a 6to4 address
        //     embedding it ([2001:4188:2:600:10:10:34.36]) for AAAA.
        //   * probed FROM THE PHONE over UDP/53: Shecan 178.22.122.100/101
        //     and Begzar 185.55.226.26 answered with the REAL records
        //     (us.hixyz.ir → 192.227.211.124). 45.90.28.x / RadarUDP gave
        //     nothing from this network.
        // Legacy-format servers RACE in parallel and the first answer wins,
        // so `local` must NOT be in the list at all (the user picks it
        // explicitly via DnsMode.system). prefer_ipv4 sidesteps the
        // 6to4-embedded AAAA sinkhole class. (A `detour` on these servers is
        // NOT usable: sing-box 1.14 rejects "detour to an empty direct
        // outbound" in configs without a direct outbound — caught by the
        // desktop E2E.)
        // Defaults are platform-aware: Android ships for IR mobile data
        // (Shecan/Begzar, measured reachable+clean from MCI); desktop dev
        // machines are typically NOT on an Iranian network where those IPs
        // route, so they keep the universal global resolvers.
        if (Platform.isAndroid) {
          servers.add({'tag': 'remote', 'type': 'udp', 'server': '178.22.122.100'});
          servers.add({'tag': 'remote2', 'type': 'udp', 'server': '185.55.226.26'});
        } else {
          servers.add({'tag': 'remote', 'type': 'udp', 'server': '1.1.1.1'});
          servers.add({'tag': 'remote2', 'type': 'udp', 'server': '8.8.8.8'});
        }
        // Manual overrides (Settings → DNS): a user-entered resolver REPLACES
        // the default for its role; scheme-aware (udp ip / https URL /
        // tls://host). The scanner in Settings helps pick a working one.
        final ro = dns.remoteOverride?.trim() ?? '';
        if (ro.isNotEmpty) {
          final s = _serverFromSpec(ro, tag: 'remote');
          if (s != null) {
            // Replace ONLY the clean-remote pair; 'local' must stay (rules
            // detour to it). An invalid entry never silently falls back.
            servers.removeWhere((e) => e['tag'] == 'remote' || e['tag'] == 'remote2');
            servers.insert(0, s);
          }
        }
        final dom = dns.domesticOverride?.trim() ?? '';
        if (dom.isNotEmpty) {
          final s = _serverFromSpec(dom, tag: 'domestic');
          if (s != null) {
            servers.add(s);
            // User opted in: Iranian names resolve through THEIR domestic
            // pick (not the poisoned carrier resolver).
            rules.add({
              'domain_suffix': ['.ir'],
              'server': 'domestic',
            });
          }
        }
    }
    final dnsObj = <String, dynamic>{'servers': servers};
    if (dns.mode == DnsMode.automatic || dns.mode == DnsMode.fakeip) {
      // Carrier AAAA answers embed the private sinkhole via 6to4
      // ([2001:4188:2:600:10:10:34.36]); IPv4 from the clean UDP resolver is
      // the trustworthy path on IR mobile.
      dnsObj['strategy'] = 'prefer_ipv4';
    }
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

  /// Parse a user DNS entry into a sing-box legacy server object.
  /// Accepted forms: `1.2.3.4`, `1.2.3.4:5300`, `https://host/path`,
  /// `tls://host`. Returns null when unparseable (never a silent default).
  static Map<String, dynamic>? _serverFromSpec(String spec,
      {required String tag}) {
    final s = spec.trim();
    if (s.isEmpty) return null;
    if (s.startsWith('https://')) {
      final u = Uri.tryParse(s);
      if (u == null || u.host.isEmpty) return null;
      return {
        'tag': tag,
        'type': 'https',
        'server': u.host,
        'path': u.path.isEmpty ? '/dns-query' : u.path,
      };
    }
    if (s.startsWith('tls://')) {
      final host = s.substring(6).trim();
      if (host.isEmpty) return null;
      return {'tag': tag, 'type': 'tls', 'server': host};
    }
    // IPv4 (with optional :port) or IPv6 [addr]:port / bare addr.
    final m4 = RegExp(r'^(\d{1,3}(?:\.\d{1,3}){3})(?::(\d{1,5}))?$')
        .firstMatch(s);
    if (m4 != null) {
      final octets = m4.group(1)!.split('.').map(int.parse).toList();
      if (octets.any((o) => o > 255)) return null;
      final port = int.tryParse(m4.group(2) ?? '');
      if (port != null && (port < 1 || port > 65535)) return null;
      return {
        'tag': tag,
        'type': 'udp',
        'server': m4.group(1)!,
        if (port != null) 'server_port': port,
      };
    }
    final m6 = RegExp(r'^\[([0-9a-fA-F:]+)\](?::(\d{1,5}))?$').firstMatch(s);
    if (m6 != null) {
      final port = int.tryParse(m6.group(2) ?? '');
      return {
        'tag': tag,
        'type': 'udp',
        'server': m6.group(1)!,
        if (port != null) 'server_port': port,
      };
    }
    return null;
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
