import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import '../core/logger.dart';
import '../core/net/clean_dns_client.dart';
import '../settings/routing_settings.dart';
import 'subscription_routing.dart';
import '../domain/entities/proxy_profile.dart';
import '../domain/entities/subscription.dart';
import '../domain/errors/app_error.dart';
import '../protocols/common/uri_utils.dart';
import '../protocols/importer.dart';
import '../data/profile_repository.dart';
import '../data/repositories.dart';

/// Downloads, decodes, normalizes and persists subscription content (§9).
class SubscriptionService {
  SubscriptionService({
    required this.subscriptions,
    required this.profiles,
    required this.importer,
    this.onCarriedRouting,
    this.currentRouting,
    http.Client? client,
  }) : _client = client ?? CleanDnsClient();

  /// Source of the CURRENT user routing settings (read side of the apply).
  final RoutingSettings Function()? currentRouting;

  /// v0.4.7 §user: called when the fetched subscription URL carries a
  /// routing payload (`?routing=<b64json>`, Happ-style). The callback owns
  /// persistence (RoutingSettingsRepository.save) — the service stays
  /// storage-agnostic. Null = feature not wired (tests).
  final Future<void> Function(RoutingSettings next)? onCarriedRouting;

  final SubscriptionRepository subscriptions;
  final ProfileRepository profiles;
  final MultiFormatImporter importer;
  final http.Client _client;

  final _progress = StreamController<SubscriptionUpdateEvent>.broadcast();
  Stream<SubscriptionUpdateEvent> get progress => _progress.stream;

  static const _userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) nexus/0.1';

  /// Fetch supporting BOTH schemes (user request 2026-09-15): tries the URL
  /// as saved first; on any transport failure (TLS reset, timeout — MCI
  /// kills some https endpoints) retries the SAME host:port under the other
  /// scheme, and finally the other scheme on its default port. A server that
  /// switched http↔https without changing the link keeps updating.
  Future<http.Response> _getDualScheme(Uri uri) async {
    final alt = uri.scheme == 'https'
        ? uri.replace(scheme: 'http')
        : uri.replace(scheme: 'https');
    final candidates = <Uri>[
      uri,
      alt,
      if (!uri.hasPort) alt.replace(port: null),
    ];
    final seen = <String>{};
    Object? lastError;
    for (final u in candidates) {
      final key = '${u.scheme}://${u.authority}';
      if (!seen.add(key)) continue;
      try {
        final resp = await _client
            .get(u, headers: {'User-Agent': _userAgent})
            .timeout(const Duration(seconds: 20));
        if (resp.statusCode == 200) return resp;
        lastError = SubscriptionFetchError(
          'The server responded with HTTP ${resp.statusCode}.',
          statusCode: resp.statusCode,
        );
      } catch (e) {
        lastError = e;
      }
    }
    if (lastError is http.Response) return lastError;
    if (lastError is SubscriptionFetchError) throw lastError;
    throw SubscriptionFetchError('Subscription fetch failed: $lastError',
        statusCode: null);
  }

  /// Fetches and applies one subscription. Never throws — failures are
  /// recorded on the subscription and surfaced via [progress].
  Future<SubscriptionUpdateEvent> update(Subscription sub) async {
    final event = SubscriptionUpdateEvent(subscriptionId: sub.id);
    _progress.add(event..status = UpdateStatus.downloading);
    try {
      final uri = Uri.parse(sub.url.trim());
      if (uri.scheme != 'http' && uri.scheme != 'https') {
        throw SubscriptionFetchError('Subscription URL must be http(s).',
            statusCode: null);
      }
      final resp = await _getDualScheme(uri);
      if (resp.statusCode != 200) {
        throw SubscriptionFetchError(
          'The server responded with HTTP ${resp.statusCode}.',
          statusCode: resp.statusCode,
        );
      }
      final body = utf8.decode(resp.bodyBytes, allowMalformed: true);
      event.byteCount = resp.bodyBytes.length;

      // Standard account headers (§9) — absent on many providers.
      final userinfo = resp.headers['subscription-userinfo'] ??
          resp.headers['Subscription-Userinfo'];
      final info = userinfo != null
          ? SubscriptionInfo.fromHeader(userinfo)
          : const SubscriptionInfo();
      final headerTitle = resp.headers['profile-title'] ??
          resp.headers['Profile-Title'];

      // Decode & normalize (off this frame; parsing is pure CPU).
      final result = importer.import(body);
      final fresh = <ProxyProfile>[];
      final seen = <String>{};
      for (final p in result.profiles) {
        final identity = p.identityHash;
        if (!seen.add(identity)) continue; // dedup within payload
        fresh.add(p
          ..subscriptionId = sub.id
          ..source = ProfileSource.subscription);
      }
      event.parsed = fresh.length;
      event.warnings = result.warnings;
      // v0.4.7 §user: pre-import screening — count Xray-only transports
      // (xhttp/mKCP) and stream-shape risks BEFORE anything is persisted, so
      // the UI can report what this subscription contains at a glance.
      final screen = result.screen;
      event.xrayOnly = screen.xrayOnly;
      event.risky = screen.risky;
      event.screenCauses = Map.of(screen.causeCounts);
      if (screen.hasFindings) {
        Logger.instance.info('subs',
            '${sub.name}: screen total=${screen.total} xrayOnly=${screen.xrayOnly} '
            'risky=${screen.risky} '
            'causes=${screen.causeCounts.entries.take(4).map((e) => '${e.value}x ${e.key}').join('; ')}');
      }

      final before = profiles.all.where((p) => p.subscriptionId == sub.id).length;
      await profiles.replaceSubscriptionProfiles(sub.id, fresh);

      final updated = sub
        ..info = info.hasAnyData ? info : sub.info
        ..lastUpdated = DateTime.now()
        ..status = SubscriptionStatus.ok
        ..nodeCount = fresh.length
        // v0.4.7 §user: persist the screening counts so the subscription
        // card shows them between updates.
        ..screenXrayOnly = screen.xrayOnly
        ..screenRisky = screen.risky
        ..lastError = null
        ..etag = resp.headers['etag'];
      if (headerTitle != null && sub.name.isEmpty) {
        updated.name = headerTitle;
      }
      await subscriptions.upsert(updated);

      // v0.4.7 §user: the sub URL may CARRY a routing profile (Happ/Incy
      // parity) — apply it after the nodes are in. Failures are logged and
      // never fail the update itself.
      if (onCarriedRouting != null && currentRouting != null) {
        try {
          final next = applySubscriptionRouting(currentRouting!(), sub);
          await onCarriedRouting!(next);
        } catch (e) {
          Logger.instance
              .warn('subs', 'carried routing not applied: $e');
        }
      }

      event
        ..status = UpdateStatus.done
        ..before = before
        ..after = fresh.length;
      Logger.instance.info('subs',
          '${sub.name}: $before -> ${fresh.length} nodes');
    } on AppError catch (e) {
      event
        ..status = UpdateStatus.failed
        ..error = e.userMessage;
      // A failed fetch keeps the previous payload — its screening result
      // stays valid, so the screening counts are NOT reset here.
      await subscriptions.upsert(sub
        ..status = SubscriptionStatus.failed
        ..lastError = e.userMessage);
      Logger.instance.warn('subs', '${sub.name}: ${e.userMessage}');
    } catch (e) {
      event
        ..status = UpdateStatus.failed
        ..error = 'Network error: $e';
      await subscriptions.upsert(sub
        ..status = SubscriptionStatus.failed
        ..lastError = 'Network error');
      Logger.instance.warn('subs', '${sub.name}: $e');
    }
    _progress.add(event);
    return event;
  }

  /// Adds a new subscription and performs the first update.
  Future<Subscription> add(String url, {String? name}) async {
    final sub = Subscription(
      id: Ids.newId(),
      name: name ?? '',
      url: url.trim(),
    );
    await subscriptions.upsert(sub);
    unawaited(update(sub));
    return sub;
  }

  /// Due subscriptions for background refresh (§60).
  List<Subscription> dueNow() {
    final now = DateTime.now();
    return subscriptions.all
        .where((s) => s.autoUpdate && (s.nextUpdate == null || now.isAfter(s.nextUpdate!)))
        .toList();
  }
}

enum UpdateStatus { downloading, parsing, done, failed }

class SubscriptionUpdateEvent {
  SubscriptionUpdateEvent({required this.subscriptionId});

  final String subscriptionId;
  UpdateStatus status = UpdateStatus.downloading;
  int? byteCount;
  int? parsed;
  int? before;
  int? after;
  List<String> warnings = const [];
  String? error;

  /// v0.4.7 §user — pre-import screening results (null = not screened, e.g.
  /// the fetch failed before parsing).
  int? xrayOnly;
  int? risky;
  Map<String, int> screenCauses = const {};

  double? get progressFraction =>
      byteCount == null ? null : (byteCount! / 1_000_000).clamp(0.0, 1.0);
}
