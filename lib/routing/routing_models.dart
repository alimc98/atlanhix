/// Routing actions a rule can take (§25).
enum RoutingAction { direct, proxy, warp, chain, block }

/// Matcher kinds for a rule. Multiple matchers inside one rule are OR'd for
/// domains and AND'd across categories (mirrors Xray/sing-box semantics).
enum RuleMatchType {
  domainFull,
  domainSuffix,
  domainKeyword,
  ipCidr,
  geoip,
  port,
  protocol,
  network,
  process, // desktop process name
  package, // Android app package
}

class RoutingRule {
  RoutingRule({
    required this.id,
    required this.matchType,
    required this.patterns,
    required this.action,
    this.chainId,
    this.enabled = true,
    this.comment,
  });

  final String id;
  final RuleMatchType matchType;
  final List<String> patterns;
  final RoutingAction action;
  final String? chainId;
  bool enabled;
  final String? comment;

  Map<String, dynamic> toJson() => {
        'id': id,
        'matchType': matchType.name,
        'patterns': patterns,
        'action': action.name,
        'chainId': chainId,
        'enabled': enabled,
        'comment': comment,
      };

  static RoutingRule fromJson(Map<String, dynamic> j) => RoutingRule(
        id: j['id'] as String,
        matchType:
            RuleMatchType.values.firstWhere((e) => e.name == j['matchType']),
        patterns: (j['patterns'] as List).cast<String>(),
        action:
            RoutingAction.values.firstWhere((e) => e.name == j['action']),
        chainId: j['chainId'] as String?,
        enabled: j['enabled'] as bool? ?? true,
        comment: j['comment'] as String?,
      );
}

class RoutingProfile {
  RoutingProfile({
    required this.id,
    required this.name,
    required this.rules,
    this.isBuiltin = false,
  });

  final String id;
  final String name;
  final List<RoutingRule> rules;
  final bool isBuiltin;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'isBuiltin': isBuiltin,
        'rules': rules.map((r) => r.toJson()).toList(),
      };

  static RoutingProfile fromJson(Map<String, dynamic> j) => RoutingProfile(
        id: j['id'] as String,
        name: j['name'] as String,
        isBuiltin: j['isBuiltin'] as bool? ?? false,
        rules: (j['rules'] as List)
            .map((r) => RoutingRule.fromJson((r as Map).cast<String, dynamic>()))
            .toList(),
      );
}

/// DNS behaviour (§24).
enum DnsMode { system, automatic, custom, doh, dot, fakeip }

class DnsSettings {
  DnsSettings({
    this.mode = DnsMode.automatic,
    this.primary,
    this.secondary,
    this.dohUrl,
    this.dotHost,
  });

  final DnsMode mode;
  final String? primary; // plain udp dns for custom
  final String? secondary;
  final String? dohUrl; // https://dns.google/dns-query
  final String? dotHost; // dns.google (DoT via tls://)

  Map<String, dynamic> toJson() => {
        'mode': mode.name,
        'primary': primary,
        'secondary': secondary,
        'dohUrl': dohUrl,
        'dotHost': dotHost,
      };

  static DnsSettings fromJson(Map<String, dynamic> j) => DnsSettings(
        mode: DnsMode.values.firstWhere((e) => e.name == j['mode'],
            orElse: () => DnsMode.automatic),
        primary: j['primary'] as String?,
        secondary: j['secondary'] as String?,
        dohUrl: j['dohUrl'] as String?,
        dotHost: j['dotHost'] as String?,
      );
}
