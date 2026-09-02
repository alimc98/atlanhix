import '../../domain/entities/proxy_profile.dart';
import '../../domain/errors/app_error.dart';

/// One element of a proxy chain (§16).
enum ChainElementType { profile, warp, internet }

class ChainElement {
  ChainElement({
    required this.id,
    required this.type,
    this.profileId,
    this.label,
    this.enabled = true,
  });

  final String id;
  final ChainElementType type;
  final String? profileId;
  String? label;
  bool enabled;
}

class ProxyChain {
  ProxyChain({
    required this.id,
    required this.name,
    required this.elements,
  });

  final String id;
  String name;
  List<ChainElement> elements;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'elements': elements
            .map((e) => {
                  'id': e.id,
                  'type': e.type.name,
                  'profileId': e.profileId,
                  'label': e.label,
                  'enabled': e.enabled,
                })
            .toList(),
      };

  static ProxyChain fromJson(Map<String, dynamic> j) => ProxyChain(
        id: j['id'] as String,
        name: j['name'] as String,
        elements: (j['elements'] as List)
            .map((e) => ChainElement(
                  id: e['id'] as String,
                  type: ChainElementType.values
                      .firstWhere((t) => t.name == e['type']),
                  profileId: e['profileId'] as String?,
                  label: e['label'] as String?,
                  enabled: e['enabled'] as bool? ?? true,
                ))
            .toList(),
      );
}

/// Validation result for a chain before it can be started (§16: the engine
/// must validate technical compatibility first).
class ChainValidation {
  ChainValidation(this.ok, this.reasons);
  final bool ok;
  final List<String> reasons;
}

/// Plans and validates chains. Technical rules:
///  * at most one WARP element; it must be a WireGuard-family profile;
///  * a WireGuard-family profile cannot tunnel through another WireGuard hop
///    (UDP-in-UDP has no reliability layer and fails in practice);
///  * engines connect via local SOCKS ingestion, so mixed-engine chains are
///    allowed but each external engine adds a process hop;
///  * an Xray node using `dialerProxy` chaining must run inside one Xray
///    process (both elements Xray) — otherwise a local-port bridge is used.
class ChainPlanner {
  ChainValidation validate(ProxyChain chain, List<ProxyProfile> profiles) {
    final reasons = <String>[];
    final active = chain.elements.where((e) => e.enabled).toList();
    if (active.isEmpty) {
      reasons.add('Chain is empty');
    }
    if (active.length > 4) {
      reasons.add('Chains are limited to 4 active hops for reliability');
    }
    var warpCount = 0;
    var wgHops = 0;
    for (final e in active) {
      if (e.type == ChainElementType.internet) continue;
      final p = _profileOf(e, profiles);
      if (p == null) {
        reasons.add('Element "${e.label ?? e.id}" points to a missing profile');
        continue;
      }
      if (p.isWireGuardFamily) {
        wgHops++;
        if (e.type == ChainElementType.warp) warpCount++;
      }
    }
    if (warpCount > 1) reasons.add('Only one WARP element is allowed');
    if (wgHops > 1) {
      reasons.add(
          'WireGuard/AWG/WARP cannot be chained through each other (UDP-in-UDP)');
    }
    return ChainValidation(reasons.isEmpty, reasons);
  }

  /// Materializes generation order: outermost hop first (it dials the
  /// internet directly and carries no detour); each inner hop's outbound
  /// references the next outer hop via `detour`/`sockopt.dialerProxy`.
  /// UI order `elements[0..n-1]` means traffic flows 0 → n-1 → internet.
  ChainPlan plan(ProxyChain chain, List<ProxyProfile> profiles) {
    final v = validate(chain, profiles);
    if (!v.ok) throw ChainError('This chain cannot be started.', reasons: v.reasons);
    final active =
        chain.elements.where((e) => e.enabled).toList().reversed.toList();
    final hops = <ChainHop>[];
    for (var i = 0; i < active.length; i++) {
      final e = active[i];
      if (e.type == ChainElementType.internet) continue;
      final p = _profileOf(e, profiles);
      if (p == null) continue;
      hops.add(ChainHop(
        profile: p,
        isLast: i == 0, // first in reversed order = outermost
      ));
    }
    return ChainPlan(hops: hops);
  }

  ProxyProfile? _profileOf(ChainElement e, List<ProxyProfile> profiles) =>
      profiles.where((p) => p.id == e.profileId).firstOrNull;
}

class ChainHop {
  ChainHop({required this.profile, required this.isLast});
  final ProxyProfile profile;

  /// true when this hop is the outermost (dials the internet directly).
  final bool isLast;
}

/// Materialized, engine-ready description of a chain.
class ChainPlan {
  ChainPlan({required this.hops});
  final List<ChainHop> hops;

  bool get isSingle => hops.length <= 1;
}
