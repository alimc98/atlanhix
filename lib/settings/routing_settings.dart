import 'dart:convert';

import '../routing/routing_models.dart';
import 'app_settings.dart';

export 'runtime_config_bridge.dart' show RoutingSettingsRepository, RoutingDecision;

/// v0.4.1 §9 — the real routing configuration model.
///
/// Owns everything the runtime needs to build the actual traffic path:
/// mode (Global/Rule), per-app DIRECT/PROXY lists, domain and CIDR rule
/// lists, DNS, and the final outbound. Serializable; persisted in the
/// JsonStore section `routingSettings`; validated on write (§10: validate →
/// persist → regenerate runtime config).
///
/// This is NOT a UI-only structure: [RuntimeConfigBridge.toRoutingProfile]
/// compiles it into the RoutingProfile consumed by RoutingCompiler, and
/// [RuntimeConfigBridge.toHandoff] produces the Android TUN include/exclude
/// lists that make DIRECT apps bypass the VPN at the VpnService level.
///
/// OPT-IN (default OFF): [enabled] starts at `false`. A fresh install — or
/// any user who never opened the routing screens — connects with NO routing
/// rules at all: the generated engine config keeps only the engine minimum
/// (sniff, DNS hijack, private networks → DIRECT) and every other
/// destination follows `route.final` (the selected node). Routing rules are
/// emitted only after the user explicitly enables a mode in settings.
/// Legacy persisted sections (pre-opt-in) never carried an `enabled` key and
/// deliberately load as OFF — routing must be opted into, never inherited.
class RoutingSettings {
  RoutingSettings({
    this.enabled = false,
    this.mode = RoutingMode.rule,
    List<String>? directApps,
    List<String>? proxyApps,
    List<String>? directDomains,
    List<String>? proxyDomains,
    List<String>? directCidrs,
    List<String>? proxyCidrs,
    List<CustomRule>? customRules,
    this.finalOutbound = 'proxy',
  })  : directApps = directApps ?? [],
        proxyApps = proxyApps ?? [],
        directDomains = directDomains ?? [],
        proxyDomains = proxyDomains ?? [],
        directCidrs = directCidrs ?? [],
        proxyCidrs = proxyCidrs ?? [],
        customRules = customRules ?? [];

  /// Default OFF — routing is opt-in. `false` means the user never enabled
  /// a routing mode; the config pipeline then emits NO user rules.
  bool enabled;

  RoutingMode mode;

  /// §13 — Android packages that bypass the VPN (addDisallowedApplication).
  /// REAL Android-level DIRECT, not a Dart-side label.
  List<String> directApps;

  /// §12 — Android packages forced through the VPN. With
  /// proxyApps non-empty the VPN switches to include-list mode
  /// (addAllowedApplication): ONLY these apps ride the tunnel.
  List<String> proxyApps;

  /// §19 — domain rules (suffix or exact, `*.example.com` normalized to suffix).
  List<String> directDomains;
  List<String> proxyDomains;

  /// §20 — CIDR rules (IPv4/IPv6).
  List<String> directCidrs;
  List<String> proxyCidrs;

  /// Advanced custom rules (domain-keyword etc.), evaluated after the
  /// built-in private-network rule and before final.
  List<CustomRule> customRules;

  /// What unmatched traffic does in Rule mode: proxy | direct.
  String finalOutbound;

  // ---------------------------------------------------------- validation

  /// Validates all entries. Returns human-readable problems; empty = valid.
  /// Called by the editors before persist (§10) — nothing invalid is saved.
  List<String> validate() {
    final problems = <String>[];
    for (final d in directDomains) {
      final e = DomainRuleValidator.validate(d);
      if (e != null) problems.add('Direct domain "$d": $e');
    }
    for (final d in proxyDomains) {
      final e = DomainRuleValidator.validate(d);
      if (e != null) problems.add('Proxy domain "$d": $e');
    }
    for (final c in directCidrs) {
      final e = CidrValidator.validate(c);
      if (e != null) problems.add('Direct CIDR "$c": $e');
    }
    for (final c in proxyCidrs) {
      final e = CidrValidator.validate(c);
      if (e != null) problems.add('Proxy CIDR "$c": $e');
    }
    for (final r in customRules) {
      problems.addAll(r.validate());
    }
    // §16 guard: an app cannot be both DIRECT and PROXY — include-list wins
    // in Android semantics, which would silently drop the DIRECT intent.
    final clash = directApps.toSet().intersection(proxyApps.toSet());
    for (final pkg in clash) {
      problems.add('App "$pkg" is in both Direct and Proxy lists');
    }
    return problems;
  }

  // --------------------------------------------------------- compilation

  /// Compiles into the [RoutingProfile] the engine config generators
  /// consume. OPT-IN gate: when [enabled] is `false` (the default) this
  /// returns a profile with ZERO rules — the generator then emits only the
  /// engine-minimum route block (sniff / DNS hijack / private → DIRECT)
  /// with `final` pointing at the selected node. Rules appear ONLY after
  /// the user enabled a mode in settings.
  ///
  /// Rule order when enabled (deterministic, §18):
  ///   1. private networks → DIRECT (RFC1918 + loopback, injected by
  ///      SingBoxConfigGenerator already for sing-box; emitted here for Xray)
  ///   2. user CIDR rules
  ///   3. user domain rules (direct then proxy)
  ///   4. custom rules
  /// Final outbound is applied via `route.final` in the generator.
  RoutingProfile toRoutingProfile() {
    // Default-off: nothing the user configured is applied until they
    // explicitly enable routing (mode Global/Rule in the settings screen).
    if (!enabled) {
      return RoutingProfile(
          id: 'routing-disabled', name: 'Routing off', rules: const []);
    }
    final rules = <RoutingRule>[];
    var n = 0;
    String nextId(String kind) => 'rs-${kind}-${n++}';

    if (mode == RoutingMode.rule) {
      // Private networks → DIRECT (sing-box generator adds ip_is_private for
      // the front engine; this rule additionally covers Xray upstreams).
      rules.add(RoutingRule(
        id: nextId('priv'),
        matchType: RuleMatchType.ipCidr,
        patterns: const [
          '10.0.0.0/8',
          '172.16.0.0/12',
          '192.168.0.0/16',
          '127.0.0.0/8',
          '169.254.0.0/16',
          '::1/128',
          'fc00::/7',
          'fe80::/10',
        ],
        action: RoutingAction.direct,
        comment: 'Private networks → DIRECT',
      ));

      if (directCidrs.isNotEmpty) {
        rules.add(RoutingRule(
          id: nextId('cidr'),
          matchType: RuleMatchType.ipCidr,
          patterns: List.of(directCidrs),
          action: RoutingAction.direct,
          comment: 'User direct networks',
        ));
      }
      if (proxyCidrs.isNotEmpty) {
        rules.add(RoutingRule(
          id: nextId('cidr'),
          matchType: RuleMatchType.ipCidr,
          patterns: List.of(proxyCidrs),
          action: RoutingAction.proxy,
          comment: 'User proxy networks',
        ));
      }

      if (directDomains.isNotEmpty) {
        rules.addAll(_domainRules(directDomains, RoutingAction.direct));
      }
      if (proxyDomains.isNotEmpty) {
        rules.addAll(_domainRules(proxyDomains, RoutingAction.proxy));
      }

      for (final r in customRules) {
        final action = switch (r.action) {
          CustomRuleAction.direct => RoutingAction.direct,
          CustomRuleAction.proxy => RoutingAction.proxy,
          CustomRuleAction.block => RoutingAction.block,
        };
        rules.add(RoutingRule(
          id: nextId('custom'),
          matchType: r.matchType,
          patterns: List.of(r.patterns),
          action: action,
          comment: r.comment,
        ));
      }
    } else {
      // §17 GLOBAL mode: everything rides the tunnel except explicit
      // DIRECT apps (enforced at the VpnService layer via exclude list —
      // see toHandoff) and private networks (loopback must never proxy).
      rules.add(RoutingRule(
        id: nextId('priv'),
        matchType: RuleMatchType.ipCidr,
        patterns: const [
          '10.0.0.0/8',
          '172.16.0.0/12',
          '192.168.0.0/16',
          '127.0.0.0/8',
          '169.254.0.0/16',
          '::1/128',
          'fc00::/7',
          'fe80::/10',
        ],
        action: RoutingAction.direct,
        comment: 'Private networks → DIRECT (global mode safety)',
      ));
      if (directDomains.isNotEmpty) {
        rules.addAll(_domainRules(directDomains, RoutingAction.direct));
      }
    }
    return RoutingProfile(id: 'routing-settings', name: 'User routing', rules: rules);
  }

  static List<RoutingRule> _domainRules(
      List<String> domains, RoutingAction action) {
    final full = <String>[];
    final suffix = <String>[];
    for (var d in domains) {
      if (d.startsWith('*.')) {
        suffix.add(d.substring(2));
      } else if (d.startsWith('.')) {
        suffix.add(d.substring(1));
      } else {
        full.add(d);
      }
    }
    // One rule per matcher kind keeps the compiled output canonical.
    final out = <RoutingRule>[];
    if (full.isNotEmpty) {
      out.add(RoutingRule(
          id: 'rs-dom-f-${full.length}-${action.name}',
          matchType: RuleMatchType.domainFull,
          patterns: full,
          action: action,
          comment: 'User exact domains → ${action.name}'));
    }
    if (suffix.isNotEmpty) {
      out.add(RoutingRule(
          id: 'rs-dom-s-${suffix.length}-${action.name}',
          matchType: RuleMatchType.domainSuffix,
          patterns: suffix,
          action: action,
          comment: 'User domain suffixes → ${action.name}'));
    }
    return out;
  }

  // ------------------------------------------------------------- Android

  /// §13/§16 — the Android VpnService per-app lists.
  ///
  /// proxyApps non-empty  → include-list mode (addAllowedApplication):
  ///   ONLY the listed apps use the VPN — every other app is effectively
  ///   DIRECT by Android itself. This is the only way Android can express
  ///   "just these apps through the VPN".
  /// otherwise            → exclude-list mode (addDisallowedApplication):
  ///   all apps use the VPN except the DIRECT list, which Android itself
  ///   routes around the tunnel (real DIRECT, kernel-enforced).
  ({List<String> include, List<String> exclude}) toAndroidAppLists() {
    // OPT-IN: per-app lists apply ONLY when routing is enabled — a user who
    // never opted in gets a whole-device tunnel (no include/exclude lists),
    // even if drafts of app lists were entered but routing was never on.
    if (!enabled) {
      return (include: const <String>[], exclude: const <String>[]);
    }
    if (proxyApps.isNotEmpty) {
      return (include: List.of(proxyApps), exclude: const <String>[]);
    }
    return (include: const <String>[], exclude: List.of(directApps));
  }

  // -------------------------------------------------------- serialization

  Map<String, dynamic> toJson() => {
        'enabled': enabled,
        'mode': mode.name,
        'directApps': directApps,
        'proxyApps': proxyApps,
        'directDomains': directDomains,
        'proxyDomains': proxyDomains,
        'directCidrs': directCidrs,
        'proxyCidrs': proxyCidrs,
        'customRules': customRules.map((r) => r.toJson()).toList(),
        'finalOutbound': finalOutbound,
      };

  static RoutingSettings fromJson(Map<String, dynamic> j) => RoutingSettings(
        // OPT-IN: sections persisted before the enabled flag existed have no
        // key and load as `false` — routing must be opted into explicitly.
        enabled: j['enabled'] as bool? ?? false,
        mode: RoutingMode.values
            .firstWhere((e) => e.name == j['mode'], orElse: () => RoutingMode.rule),
        directApps: (j['directApps'] as List?)?.cast<String>() ?? [],
        proxyApps: (j['proxyApps'] as List?)?.cast<String>() ?? [],
        directDomains: (j['directDomains'] as List?)?.cast<String>() ?? [],
        proxyDomains: (j['proxyDomains'] as List?)?.cast<String>() ?? [],
        directCidrs: (j['directCidrs'] as List?)?.cast<String>() ?? [],
        proxyCidrs: (j['proxyCidrs'] as List?)?.cast<String>() ?? [],
        customRules: ((j['customRules'] as List?) ?? [])
            .map((r) => CustomRule.fromJson((r as Map).cast<String, dynamic>()))
            .toList(),
        finalOutbound: j['finalOutbound'] as String? ?? 'proxy',
      );

  RoutingSettings copy() =>
      RoutingSettings.fromJson(jsonDecode(jsonEncode(toJson())) as Map<String, dynamic>);
}

/// §10 Advanced — user-defined custom rule.
class CustomRule {
  CustomRule({
    required this.id,
    required this.matchType,
    required this.patterns,
    required this.action,
    this.comment,
  });

  final String id;
  RuleMatchType matchType; // domainFull / domainSuffix / domainKeyword / ipCidr
  List<String> patterns;
  CustomRuleAction action;
  String? comment;

  List<String> validate() {
    final problems = <String>[];
    if (patterns.isEmpty) problems.add('Custom rule "$id" has no patterns');
    for (final p in patterns) {
      final e = matchType == RuleMatchType.ipCidr
          ? CidrValidator.validate(p)
          : DomainRuleValidator.validate(p);
      if (e != null) problems.add('Custom rule "$id" pattern "$p": $e');
    }
    return problems;
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'matchType': matchType.name,
        'patterns': patterns,
        'action': action.name,
        'comment': comment,
      };

  static CustomRule fromJson(Map<String, dynamic> j) => CustomRule(
        id: j['id'] as String,
        matchType: RuleMatchType.values
            .firstWhere((e) => e.name == j['matchType']),
        patterns: (j['patterns'] as List).cast<String>(),
        action: CustomRuleAction.values
            .firstWhere((e) => e.name == j['action']),
        comment: j['comment'] as String?,
      );
}

enum CustomRuleAction { direct, proxy, block }

/// §19 — domain syntax validation. Accepts `example.com` (exact),
/// `.example.com` or `*.example.com` (suffix). Rejects everything else.
class DomainRuleValidator {
  static final _domainRe =
      RegExp(r'^(\*\.)?([a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$');
  static final _dotFormRe =
      RegExp(r'^\.([a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$');

  /// null = valid, otherwise the reason.
  static String? validate(String raw) {
    final d = raw.trim();
    if (d.isEmpty) return 'empty';
    if (d.contains('/') || d.contains(' ') || d.contains(':')) {
      return 'not a plain domain (no scheme, spaces or ports)';
    }
    if (_domainRe.hasMatch(d) || _dotFormRe.hasMatch(d)) return null;
    return 'invalid domain syntax (use example.com or *.example.com)';
  }

  /// Normalizes `*.x` → `.x` for storage.
  static String normalize(String raw) {
    final d = raw.trim();
    if (d.startsWith('*.')) return '.${d.substring(2)}';
    return d;
  }
}

/// §20 — CIDR validation (IPv4 + IPv6).
class CidrValidator {
  static String? validate(String raw) {
    final c = raw.trim();
    if (c.isEmpty) return 'empty';
    final parts = c.split('/');
    if (parts.length > 2) return 'too many slashes';
    final addr = parts[0];
    final prefix = parts.length == 2 ? int.tryParse(parts[1]) : null;
    if (parts.length == 2 && prefix == null) return 'invalid prefix length';
    final isV6 = addr.contains(':');
    if (isV6) {
      if (!RegExp(r'^[0-9a-fA-F:]+$').hasMatch(addr)) return 'invalid IPv6 address';
      final groups = addr.split(':').where((g) => g.isNotEmpty).length;
      final compressed = addr.contains('::');
      if (!compressed && groups != 8) return 'IPv6 address must have 8 groups';
      if (compressed && groups > 7) return 'IPv6 address has too many groups';
      if (prefix != null && (prefix < 0 || prefix > 128)) {
        return 'IPv6 prefix must be 0-128';
      }
    } else {
      final octets = addr.split('.');
      if (octets.length != 4) return 'IPv4 address must have 4 octets';
      for (final o in octets) {
        final v = int.tryParse(o);
        if (v == null || v < 0 || v > 255) return 'invalid IPv4 octet "$o"';
      }
      if (prefix != null && (prefix < 0 || prefix > 32)) {
        return 'IPv4 prefix must be 0-32';
      }
    }
    return null;
  }
}

/// §14 — the Iranian Apps preset: an EDITABLE package list the user can
/// review and toggle per app. It is data, not a hardcode: shipping as a
/// JSON asset/updatable blob, and per-app enable/disable lives in
/// RoutingSettings.directApps (the preset only seeds suggestions).
class IranianAppsPreset {
  /// Actual package IDs (the routing identifiers). Apps may be absent on a
  /// given device; the picker greys them out. Update this list over time.
  static const List<String> packageIds = [
    'com.digikala',
    'snapp.app',
    'ir.cafebazaar.codeto.market', // Bazaar
    'com.farsitel.bazaar',
    'com.sheypoor.mobile',
    'com.mci.androididt', // MCI MyMci
    'ir.tashilat.iran.cell', // Irancell
    'com.shatel.mobile',
    'ir.asiatech.asiatechapp',
    'com.podland.pod',
    'ir.pna.apps.pnaclient',
    'com.pasargad.pasargadmobile',
    'com.mellat.mellatmobilebankingapp',
    'ir.mobilesep.sep.ion',
    'com.samanpr.saman24',
    'ir.tejaratbank.mobilebanking',
    'com.refahbank.android.refahyab',
    'ir.ate.saderatbank',
    'com.keshavarzi.mobile',
    'com.samandehi.samandehi',
  ];

  static const String sourceNote =
      'Preset list — review and toggle each app individually. '
      'An app is DIRECT only when YOU add it to Direct Apps.';
}
