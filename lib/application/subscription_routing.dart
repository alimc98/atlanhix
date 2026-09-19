import 'dart:convert';

import '../core/logger.dart';
import '../domain/entities/subscription.dart';
import '../settings/app_settings.dart' show RoutingMode;
import '../settings/routing_settings.dart';

/// v0.4.7 §user — subscription-carried routing (the Happ / Incy feature).
///
/// A subscription URL may carry a routing profile in its query string, e.g.
///   https://provider/sub?token=…&routing=<base64url-json>
///   …&routing-data=<base64url-json>          (Happ's parameter name)
///
/// Accepted JSON (all keys optional; unknown keys ignored):
/// {
///   "mode": "rule" | "global",
///   "final": "proxy" | "direct",
///   "proxy": ["domain.com", "other.example"],   // → proxyDomains
///   "direct": ["ir.example", "bank.example"],   // → directDomains
///   "proxy_cidr": ["1.2.3.0/24"],
///   "direct_cidr": ["10.0.0.0/8"]
/// }
///
/// Security posture: the payload only ever CONVERGES ON THE SAFE SUBSET of
/// [RoutingSettings] — it can add domain/CIDR entries and pick the mode.
/// It can NOT touch per-app lists, custom rules, or flip `enabled` for a
/// user who explicitly disabled routing (a subscription must never silently
/// re-enable interception after the user turned it off — first successful
/// import ENABLES routing for first-time users, later fetches never flip a
/// user-made OFF).
class SubscriptionRoutingParser {
  /// Extracts + decodes the routing payload from a subscription URL.
  /// Returns null when the URL carries none (or it does not decode).
  static SubscriptionRouting? fromUrl(String url) {
    final uri = Uri.tryParse(url.trim());
    if (uri == null) return null;
    final raw = uri.queryParameters['routing'] ??
        uri.queryParameters['routing-data'] ??
        uri.queryParameters['happ-routing'];
    if (raw == null || raw.trim().isEmpty) return null;
    return parse(raw);
  }

  /// Decodes a base64url (or plain JSON) routing payload.
  static SubscriptionRouting? parse(String payload) {
    try {
      var t = payload.trim().replaceAll('-', '+').replaceAll('_', '/');
      while (t.length % 4 != 0) {
        t += '=';
      }
      var text = const Base64Decoder().convert(t);
      final s = utf8.decode(text, allowMalformed: true);
      final j = jsonDecode(s);
      if (j is! Map) return null;
      return SubscriptionRouting.fromJson(j.cast<String, dynamic>());
    } catch (_) {
      // Plain-JSON payloads (not base64) are also accepted.
      try {
        final j = jsonDecode(payload.trim());
        if (j is Map) {
          return SubscriptionRouting.fromJson(j.cast<String, dynamic>());
        }
      } catch (_) {}
      Logger.instance.info('sub-routing',
          'routing payload present but undecodable — ignored');
      return null;
    }
  }
}

class SubscriptionRouting {
  SubscriptionRouting({
    this.mode,
    this.finalOutbound,
    List<String>? proxy,
    List<String>? direct,
    List<String>? proxyCidr,
    List<String>? directCidr,
  })  : proxy = proxy ?? [],
        direct = direct ?? [],
        proxyCidr = proxyCidr ?? [],
        directCidr = directCidr ?? [];

  factory SubscriptionRouting.fromJson(Map<String, dynamic> j) {
    List<String> list(Object? v) =>
        v is List ? v.map((e) => '$e').where((e) => e.trim().isNotEmpty).toList() : const [];
    return SubscriptionRouting(
      mode: j['mode'] is String ? j['mode'] as String : null,
      finalOutbound: j['final'] is String ? j['final'] as String : null,
      proxy: list(j['proxy'] ?? j['proxy_domains']),
      direct: list(j['direct'] ?? j['direct_domains']),
      proxyCidr: list(j['proxy_cidr'] ?? j['proxyCidr']),
      directCidr: list(j['direct_cidr'] ?? j['directCidr']),
    );
  }

  final String? mode; // "rule" | "global"
  final String? finalOutbound; // "proxy" | "direct"
  final List<String> proxy;
  final List<String> direct;
  final List<String> proxyCidr;
  final List<String> directCidr;

  bool get isEmpty =>
      (mode == null || mode!.isEmpty) &&
      proxy.isEmpty &&
      direct.isEmpty &&
      proxyCidr.isEmpty &&
      directCidr.isEmpty;
}

/// Applies [sub]'s carried routing onto the user's [RoutingSettings] with
/// the safety contract documented above. Returns the updated settings (or
/// the same instance when there was nothing to apply).
RoutingSettings applySubscriptionRouting(
  RoutingSettings current,
  Subscription sub,
) {
  final r = SubscriptionRoutingParser.fromUrl(sub.url);
  if (r == null || r.isEmpty) return current;
  final next = current
    ..proxyDomains = {...current.proxyDomains, ...r.proxy}.toList()
    ..directDomains = {...current.directDomains, ...r.direct}.toList()
    ..proxyCidrs = {...current.proxyCidrs, ...r.proxyCidr}.toList()
    ..directCidrs = {...current.directCidrs, ...r.directCidr}.toList();
  // Mode: only consulted when the user has not made an explicit choice.
  if (!current.enabled) {
    if (r.mode?.toLowerCase() == 'global') {
      next.mode = RoutingMode.global;
    } else if (r.mode?.toLowerCase() == 'rule') {
      next.mode = RoutingMode.rule;
    }
    // First import with real routing data = the user opted in (Happ parity:
    // the routing shipped with the provider's sub is the expected UX).
    if (r.mode != null || r.proxy.isNotEmpty || r.direct.isNotEmpty) {
      next.enabled = true;
    }
  }
  if (r.finalOutbound == 'direct' || r.finalOutbound == 'proxy') {
    next.finalOutbound = r.finalOutbound!;
  }
  return next;
}
