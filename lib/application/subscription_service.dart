import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import '../core/logger.dart';
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
    http.Client? client,
  }) : _client = client ?? http.Client();

  final SubscriptionRepository subscriptions;
  final ProfileRepository profiles;
  final MultiFormatImporter importer;
  final http.Client _client;

  final _progress = StreamController<SubscriptionUpdateEvent>.broadcast();
  Stream<SubscriptionUpdateEvent> get progress => _progress.stream;

  static const _userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) nexus/0.1';

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
      final resp = await _client
          .get(uri, headers: {'User-Agent': _userAgent})
          .timeout(const Duration(seconds: 20));
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

      final before = profiles.all.where((p) => p.subscriptionId == sub.id).length;
      await profiles.replaceSubscriptionProfiles(sub.id, fresh);

      final updated = sub
        ..info = info.hasAnyData ? info : sub.info
        ..lastUpdated = DateTime.now()
        ..status = SubscriptionStatus.ok
        ..nodeCount = fresh.length
        ..lastError = null
        ..etag = resp.headers['etag'];
      if (headerTitle != null && sub.name.isEmpty) {
        updated.name = headerTitle;
      }
      await subscriptions.upsert(updated);

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

  double? get progressFraction =>
      byteCount == null ? null : (byteCount! / 1_000_000).clamp(0.0, 1.0);
}
