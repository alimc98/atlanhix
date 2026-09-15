import '../data/app_storage.dart';
import '../routing/routing_models.dart';
import '../core/logger.dart';
import 'app_settings.dart';
import 'routing_settings.dart';

/// v0.4.1 §31 — the bridge between user settings and REAL runtime configs.
///
/// Everything the engines and the Android service actually consume is
/// derived here, in one auditable place:
///   * [routingProfile]     → RoutingCompiler → sing-box/Xray route rules
///   * [androidHandoff]     → VpnService TUN (routes, DNS, MTU, app lists)
///   * [singBoxOptions]     → mixed/TUN inbound flags of the generated config
///   * [routingDecision]    → §34 the routing test tool's match evaluator
///
/// No setting is honored unless it flows through this class.
class RuntimeConfigBridge {
  RuntimeConfigBridge({
    required this.settings,
    required this.routing,
  });

  final AppSettings settings;
  final RoutingSettings routing;

  /// The compiled rule profile for the engine config generators.
  /// v0.4.4 mockup pills: QUICK-SETTINGS shortcuts are merged as EXPLICIT
  /// user rules (tapping a pill IS opting in), even when the general
  /// routing mode stays off — but nothing is ever applied silently.
  RoutingProfile routingProfile() {
    final base = routing.toRoutingProfile();
    final pills = <RoutingRule>[];
    var k = 0;
    if (settings.iranAppsDirect) {
      pills.add(RoutingRule(
        id: 'pill-ir-${k++}',
        matchType: RuleMatchType.domainSuffix,
        patterns: const [
          '.ir', 'irancell.ir', 'mci.ir', 'shaparak.ir', 'digikala.com',
          'snapp.ir', 'tbank.ir', 'idpay.ir', 'hamrahcart.ir',
        ],
        action: RoutingAction.direct,
        comment: 'Iran Apps pill → direct',
      ));
    }
    if (settings.adsBlock) {
      pills.add(RoutingRule(
        id: 'pill-ads-${k++}',
        matchType: RuleMatchType.domainKeyword,
        patterns: const [
          'ads.', 'doubleclick', 'googlesyndication', 'google-analytics',
          'facebook.net', 'adservice', 'moatads', 'inmobile.co',
        ],
        action: RoutingAction.block,
        comment: 'Ads pill → block',
      ));
    }
    if (pills.isEmpty) return base;
    return RoutingProfile(
      id: base.id,
      name: base.name,
      isBuiltin: base.isBuiltin,
      rules: [...pills, ...base.rules],
    );
  }

  /// DNS settings consumed by RoutingCompiler.singBoxDns (§21/§22).
  /// UI modes map onto the engine-level DnsSettings:
  ///   auto    → automatic (clean domestic UDP by default, manual overrides
  ///             honored via remoteDns / domesticDns)
  ///   system  → system resolvers only
  ///   remote  → encrypted resolver through the tunnel (user pick, else DoH)
  ///   custom  → user-supplied plaintext servers (udp)
  DnsSettings dnsSettings() {
    final remote = settings.remoteDns.trim();
    final domestic = settings.domesticDns.trim();
    switch (settings.dnsMode) {
      case DnsModeUi.auto:
        return DnsSettings(
          mode: DnsMode.automatic,
          remoteOverride: remote.isEmpty ? null : remote,
          domesticOverride: domestic.isEmpty ? null : domestic,
        );
      case DnsModeUi.system:
        return DnsSettings(mode: DnsMode.system);
      case DnsModeUi.remote:
        // A manually entered remote DNS wins over the built-in DoH default.
        if (remote.isNotEmpty &&
            (remote.startsWith('https://') || remote.startsWith('tls://'))) {
          return remote.startsWith('https://')
              ? DnsSettings(mode: DnsMode.doh, dohUrl: remote)
              : DnsSettings(
                  mode: DnsMode.dot, dotHost: remote.substring(6).trim());
        }
        return DnsSettings(
            mode: DnsMode.doh,
            dohUrl: 'https://cloudflare-dns.com/dns-query');
      case DnsModeUi.custom:
        final primary = settings.dnsServers.isNotEmpty
            ? settings.dnsServers.first
            : (remote.isNotEmpty ? remote : '178.22.122.100');
        final secondary = settings.dnsServers.length > 1
            ? settings.dnsServers[1]
            : null;
        return DnsSettings(
            mode: DnsMode.custom, primary: primary, secondary: secondary);
    }
  }

  /// TUN resolver list handed to VpnService (§22 — resolved INSIDE the
  /// tunnel; Android uses these over the physical NIC's servers).
  List<String> tunDnsServers() {
    final custom = settings.dnsServers
        .where((s) => CidrValidator.validate(s) == null && _isIp(s))
        .toList();
    switch (settings.dnsMode) {
      case DnsModeUi.auto:
        // Domestic clean UDP resolvers measured reachable from IR mobile
        // data (2026-09-13, Mi 9T/MCI); 1.1.1.1/8.8.8.8 are blocked there,
        // and a TUN whose DNS servers are unreachable starves every system
        // lookup (including our Kotlin DnsResolver path) into timeouts.
        return const ['178.22.122.100', '185.55.226.26'];
      case DnsModeUi.system:
        return const ['1.1.1.1', '8.8.8.8'];
      case DnsModeUi.remote:
        return const ['1.1.1.1'];
      case DnsModeUi.custom:
        return custom.isNotEmpty ? custom : const ['178.22.122.100'];
    }
  }

  static bool _isIp(String s) =>
      CidrValidator.validate(s.contains('/') ? s.split('/')[0] : s) == null;

  /// Routes for the TUN builder (§23 IPv6 semantics):
  ///   off  → 0.0.0.0/0 only (no IPv6 route = no IPv6 leak path)
  ///   on   → v4 + v6
  ///   auto → v6 route only when the generated config carries an IPv6
  ///          TUN address (same condition as [wantsInet6]).
  List<String> tunRoutes() => switch (settings.ipv6) {
        IpV6Mode.on => const ['0.0.0.0/0', '::/0'],
        IpV6Mode.off => const ['0.0.0.0/0'],
        IpV6Mode.auto => const ['0.0.0.0/0', '::/0'],
      };

  /// Whether the TUN gets an IPv6 address (§23). `off` never does — this is
  /// the honest implementation of the toggle: no address, no route, no leak.
  bool wantsInet6() => settings.ipv6 != IpV6Mode.off;

  /// Effective TUN MTU (§24; AUTO = 8500).
  int tunMtu() => settings.effectiveMtu;

  /// Android per-app lists (§13/§16).
  ({List<String> include, List<String> exclude}) androidAppLists() =>
      routing.toAndroidAppLists();

  /// The complete VpnService start handoff.
  Map<String, dynamic> androidHandoff({required String singBoxConfigJson}) {
    final apps = androidAppLists();
    return {
      'mtu': tunMtu(),
      'inet4Address': '172.19.0.1',
      'inet4Prefix': 30,
      if (wantsInet6()) 'inet6Address': 'fdfe:dcba:9876::1',
      if (wantsInet6()) 'inet6Prefix': 126,
      'dns': tunDnsServers(),
      'routes': tunRoutes(),
      'includeApps': apps.include,
      'excludeApps': apps.exclude,
      'keepAlive': settings.keepVpnAlive,
      'configJson': singBoxConfigJson,
    };
  }

  /// Options block for SingBoxConfigGenerator.
  SingBoxOptionsAdapter singBoxOptions({required int mixedPort, required int apiPort}) =>
      SingBoxOptionsAdapter(
        mixedPort: mixedPort,
        apiPort: apiPort,
        enableTun: false, // Android TUN is established by VpnService, not sing-box
        tunMtu: tunMtu(),
        logLevel: settings.debugLogging ? 'debug' : 'info',
      );

  // -------------------------------------------------- §34 routing tester

  /// Evaluates what the compiled rules do with a destination — the REAL
  /// decision the engine would make (same data, same order). Domain rules
  /// match by suffix/exact; CIDR by prefix containment. App rules map to
  /// the VpnService lists (reported separately as android DIRECT/PROXY).
  RoutingDecision evaluate({String? domain, String? ip, String? appPackage}) {
    // OPT-IN: with routing disabled the engine applies NO user rules —
    // everything (minus Android's own TUN handling) follows `route.final`.
    // Report that honestly instead of evaluating rules that are not emitted.
    if (!routing.enabled) {
      return RoutingDecision(
          verdict: 'PROXY',
          matchedRule: 'Routing disabled (opt-in) — final outbound',
          outbound: 'proxy');
    }
    final profile = routingProfile();

    // Android-level app routing first — it overrides engine rules.
    if (appPackage != null) {
      if (routing.directApps.contains(appPackage)) {
        return RoutingDecision(
            verdict: 'DIRECT',
            matchedRule: 'Direct Apps (VpnService disallow-list)',
            outbound: 'android-bypass');
      }
      if (routing.proxyApps.isNotEmpty) {
        if (routing.proxyApps.contains(appPackage)) {
          return RoutingDecision(
              verdict: 'PROXY',
              matchedRule: 'Proxy Apps (VpnService allow-list)',
              outbound: 'proxy');
        }
        return RoutingDecision(
            verdict: 'DIRECT',
            matchedRule: 'Not in Proxy Apps allow-list (VpnService)',
            outbound: 'android-bypass');
      }
    }

    if (ip != null) {
      // loopback/private first (mirrors compiled rule 1)
      if (_inCidr(ip, _privateCidrs)) {
        return RoutingDecision(
            verdict: 'DIRECT',
            matchedRule: 'Private networks rule',
            outbound: 'direct');
      }
      for (final list in <(List<String>, String, String)>[
        (routing.directCidrs, 'User direct networks', 'direct'),
        (routing.proxyCidrs, 'User proxy networks', 'proxy'),
      ]) {
        for (final cidr in list.$1) {
          if (_inCidr(ip, [cidr])) {
            return RoutingDecision(
                verdict: list.$2.startsWith('User direct') ? 'DIRECT' : 'PROXY',
                matchedRule: '${list.$2}: $cidr',
                outbound: list.$3);
          }
        }
      }
    }

    if (domain != null) {
      final lower = domain.toLowerCase();
      final d = lower.endsWith('.')
          ? lower.substring(0, lower.length - 1)
          : lower;
      final order = <(List<String>, RoutingAction, String)>[
        (routing.directDomains, RoutingAction.direct, 'User direct domains'),
        (routing.proxyDomains, RoutingAction.proxy, 'User proxy domains'),
      ];
      for (final (list, action, label) in order) {
        for (var raw in list) {
          var pattern = raw.toLowerCase();
          var kind = 'exact';
          if (pattern.startsWith('*.')) {
            pattern = pattern.substring(1);
            kind = 'suffix';
          } else if (pattern.startsWith('.')) {
            pattern = pattern.substring(1);
            kind = 'suffix';
          }
          final hit =
              kind == 'suffix' ? d.endsWith('.$pattern') || d == pattern : d == pattern;
          if (hit) {
            return RoutingDecision(
                verdict: action == RoutingAction.direct ? 'DIRECT' : 'PROXY',
                matchedRule: '$label: $raw ($kind)',
                outbound: action == RoutingAction.direct ? 'direct' : 'proxy');
          }
        }
      }
      // custom rules (domain keyword)
      for (final r in routing.customRules) {
        if (r.matchType == RuleMatchType.domainKeyword &&
            r.patterns.any((p) => d.contains(p.toLowerCase()))) {
          return RoutingDecision(
              verdict: switch (r.action) {
                CustomRuleAction.direct => 'DIRECT',
                CustomRuleAction.proxy => 'PROXY',
                CustomRuleAction.block => 'BLOCKED',
              },
              matchedRule: 'Custom keyword rule: ${r.patterns.join(",")}',
              outbound: r.action.name);
        }
      }
      // compiled profile rules not covered above (e.g. block rules)
      for (final rule in profile.rules) {
        if (rule.action == RoutingAction.block) {
          final hit = switch (rule.matchType) {
            RuleMatchType.domainSuffix => rule.patterns
                .any((p) => d == p.replaceFirst('.', '') || d.endsWith(p)),
            RuleMatchType.domainFull => rule.patterns.contains(d),
            RuleMatchType.domainKeyword =>
              rule.patterns.any((p) => d.contains(p)),
            _ => false,
          };
          if (hit) {
            return RoutingDecision(
                verdict: 'BLOCKED',
                matchedRule: 'Custom block rule: ${rule.patterns.join(",")}',
                outbound: 'reject');
          }
        }
      }
    }

    if (isGlobalMode()) {
      return RoutingDecision(
          verdict: 'PROXY', matchedRule: 'Global mode (final)', outbound: 'proxy');
    }
    return RoutingDecision(
        verdict:
            routing.finalOutbound == 'direct' ? 'DIRECT' : 'PROXY',
        matchedRule: 'Final outbound (no rule matched)',
        outbound: routing.finalOutbound);
  }

  bool isGlobalMode() => routing.mode == RoutingMode.global;

  static const _privateCidrs = [
    '10.0.0.0/8',
    '172.16.0.0/12',
    '192.168.0.0/16',
    '127.0.0.0/8',
    '169.254.0.0/16',
    '::1/128',
    'fc00::/7',
    'fe80::/10',
  ];

  static bool _inCidr(String ip, List<String> cidrs) {
    final v4 = _parseV4(ip);
    for (final c in cidrs) {
      if (c.contains(':') != ip.contains(':')) continue;
      if (c.contains(':')) {
        // v6: textual prefix compare on expanded forms is approximate but
        // honest for diagnostics (full compare needs bigint on web — Dart int is 64-bit).
        final parts = c.split('/');
        final prefix = int.tryParse(parts.length > 1 ? parts[1] : '128') ?? 128;
        final a = _expandV6(ip), b = _expandV6(parts[0]);
        if (a == null || b == null) continue;
        final n = (prefix / 4).ceil();
        return a.substring(0, n) == b.substring(0, n);
      }
      if (v4 == null) continue;
      final parts = c.split('/');
      final base = _parseV4(parts[0]);
      if (base == null) continue;
      final prefix = int.tryParse(parts.length > 1 ? parts[1] : '32') ?? 32;
      if (prefix == 0) return true;
      final mask = prefix >= 32 ? 0xFFFFFFFF : (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF;
      if ((v4 & mask) == (base & mask)) return true;
    }
    return false;
  }

  static int? _parseV4(String s) {
    final o = s.split('.');
    if (o.length != 4) return null;
    var v = 0;
    for (final p in o) {
      final x = int.tryParse(p);
      if (x == null || x < 0 || x > 255) return null;
      v = (v << 8) | x;
    }
    return v;
  }

  static String? _expandV6(String s) {
    try {
      final halves = s.split('::');
      List<String> head = halves[0].isEmpty ? [] : halves[0].split(':');
      List<String> tail =
          halves.length > 1 ? (halves[1].isEmpty ? [] : halves[1].split(':')) : [];
      final missing = 8 - head.length - tail.length;
      if (halves.length == 1 && missing != 0) return null;
      final groups = [
        ...head,
        ...List.filled(missing < 0 ? 0 : missing, '0'),
        ...tail
      ];
      if (groups.length != 8) return null;
      return groups.map((g) => g.padLeft(4, '0')).join();
    } catch (_) {
      return null;
    }
  }
}

/// §34 — verdict of the routing test tool.
class RoutingDecision {
  RoutingDecision({
    required this.verdict,
    required this.matchedRule,
    required this.outbound,
  });
  final String verdict; // DIRECT | PROXY | BLOCKED | UNKNOWN
  final String matchedRule;
  final String outbound;

  @override
  String toString() => '$verdict ← $matchedRule → $outbound';
}

/// Options passed to the sing-box generator (kept adapter-thin so the
/// generator keeps its own class in core/configgen).
class SingBoxOptionsAdapter {
  SingBoxOptionsAdapter({
    required this.mixedPort,
    required this.apiPort,
    required this.enableTun,
    required this.tunMtu,
    required this.logLevel,
  });
  final int mixedPort;
  final int apiPort;
  final bool enableTun;
  final int tunMtu;
  final String logLevel;
}

/// Persistence for [RoutingSettings] (JsonStore section `routingSettings`).
class RoutingSettingsRepository {
  RoutingSettingsRepository(this._store);

  final JsonStore _store;
  RoutingSettings _current = RoutingSettings();

  RoutingSettings get current => _current;

  Future<void> load() async {
    final section = _store.section('routingSettings');
    if (section.isEmpty) return;
    _current = RoutingSettings.fromJson(section);
  }

  /// Validates BEFORE persisting (§10) — invalid input never reaches disk.
  /// Returns the validation problems (empty on success).
  Future<List<String>> save(RoutingSettings s) async {
    final problems = s.validate();
    if (problems.isNotEmpty) {
      Logger.instance.warn('routing', 'rejected invalid routing config: $problems');
      return problems;
    }
    _current = s;
    await _store.putSection('routingSettings', s.toJson());
    return const [];
  }
}
