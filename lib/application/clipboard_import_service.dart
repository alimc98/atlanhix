import 'dart:async';

import 'package:flutter/services.dart';

import '../core/logger.dart';
import '../domain/entities/proxy_profile.dart';
import '../protocols/importer.dart';

/// v0.4.7 §user — clipboard import prompt (Happ/V2Box-style UX).
///
/// When the app opens and the clipboard holds share-link payload(s)
/// (`vless://`, `vmess://`, `ss://`, `trojan://`, a base64 URI list, or an
/// http(s) subscription URL), the user is asked ONCE whether to import:
///   * an http(s) URL  → subscription (SubscriptionService.add)
///   * anything else   → nodes (importer.import + profiles.upsertMany)
///
/// Reading the clipboard is opt-in per offer (Android 12+ shows a system
/// paste toast when it happens): checked right after warm-up AND on every
/// resume (main.dart re-checks — the payload is usually copied in ANOTHER
/// app), deduplicated by content so one payload is offered exactly once.
class ClipboardImportService {
  ClipboardImportService({
    required this.importer,
    required this.onAddNodes,
    required this.onAddSubscription,
    this.knownPayload,
  });

  final MultiFormatImporter importer;

  /// Persists node profiles (repository upsert). Injected so this service
  /// stays UI-free and testable.
  final Future<void> Function(List<ProxyProfile> profiles) onAddNodes;

  /// Persists + fetches a subscription. Injected for the same reason.
  final Future<void> Function(String url) onAddSubscription;

  /// v0.4.9 §user-fix ("هر بار میگه لینک رو ادد کنم در حالی که ادد شده"):
  /// returns TRUE when the clipboard payload is ALREADY inside the app —
  /// an identical subscription URL, or share links whose nodes all match
  /// existing profiles (identity hash, not the display name). A known
  /// payload never re-offers, across app runs too (the check is against
  /// the live repositories, not session memory).
  final bool Function(String payload)? knownPayload;

  static final _subUri = RegExp(
    r'^(vless|vmess|ss|ssr|trojan|hysteria2?|tuic|juicity|socks5?|wireguard|wg|mdvpn)://',
    caseSensitive: false,
  );

  /// Classification of the last clipboard payload.
  ClipboardPayloadKind classify(String text) {
    final t = text.trim();
    if (t.isEmpty) return ClipboardPayloadKind.none;
    if (t.startsWith('http://') || t.startsWith('https://')) {
      // v0.5.6 §clipboard-fix (user report: "هر چیزی توی کلیپ‌بورد باشه رو
      // می‌خواد add subscribe کنه در صورتی که اصلاً سابی نیست" — ANYTHING in
      // the clipboard gets offered as a subscription).
      //
      // The old test was "is this a single http(s) link with a host?" — which
      // is true of every URL ever copied: a news article, a Telegram invite,
      // a GitHub link, a YouTube video. The clipboard is read on EVERY app
      // resume, so the user was nagged about whatever they last copied.
      //
      // A subscription URL is now required to LOOK like one: a bare URL with
      // no path noise, no fragment, and the token patterns every real
      // provider uses (`/sub`, `/subscribe`, `/api/v1/client/subscribe`,
      // `token=`, `uuid=`…). A link that fails this test is simply not a
      // subscription, and is no longer offered at all.
      if (_looksLikeSubscriptionUrl(t)) {
        return ClipboardPayloadKind.subscriptionUrl;
      }
      return ClipboardPayloadKind.none;
    }
    if (_subUri.hasMatch(t)) return ClipboardPayloadKind.shareLinks;
    // Multi-line uri lists / base64 blobs are worth importing as nodes too —
    // but only when the sniffer actually recognizes the format.
    if (t.contains('://') || t.contains('\n')) {
      try {
        if (SourceFormatSniffer().detect(t) != SourceFormat.unknown) {
          return ClipboardPayloadKind.shareLinks;
        }
      } catch (_) {}
    }
    return ClipboardPayloadKind.none;
  }

  /// Path fragments every real subscription provider uses.
  static final _subPathHints = RegExp(
    r'(^|/)(sub|subscribe|subscription|api/v\d+/client/subscribe|'
    r'client/subscribe|panel/api/v\d+/(sub|client/subscribe))\b',
    caseSensitive: false,
  );

  /// Query keys carrying the subscription token.
  ///
  /// v0.5.6: matched against [Uri.query], which does NOT include the leading
  /// `?` — the first version anchored on `[?&]` and therefore never matched
  /// any real `?token=` URL.
  static final _subQueryHints =
      RegExp(r'(^|[?&])(token|uuid|sub|key|api_?key|secret)=', caseSensitive: false);

  /// Hosts that are unambiguously NOT a proxy subscription.
  ///
  /// v0.5.6 §clipboard-fix: matched against the FULL host, not just a
  /// `www.`-prefixed form — the first version missed bare `t.me` and
  /// `youtu.be`, which are exactly the two links people copy most often.
  static final _notSubscriptionHosts = RegExp(
    r'^(www\.)?'
    r'(github\.com|githubusercontent\.com|gitlab\.com|'
    r'telegram\.me|t\.me|whatsapp\.com|twitter\.com|x\.com|facebook\.com|'
    r'instagram\.com|reddit\.com|youtube\.com|youtu\.be|'
    r'google\.[a-z.]+|mail\.google\.com|drive\.google\.com|docs\.google\.com|'
    r'wikipedia\.org|linkedin\.com|medium\.com|stackoverflow\.com)$',
    caseSensitive: false,
  );

  /// True only when the URL is shaped like a provider subscription link.
  ///
  /// v0.5.6 §clipboard-fix: deliberately conservative — a false negative
  /// costs the user one manual paste, while a false positive nags them on
  /// every resume for a link that was never a subscription.
  static bool _looksLikeSubscriptionUrl(String raw) {
    final uri = Uri.tryParse(raw);
    if (uri == null || (uri.host.isEmpty)) return false;
    if (_notSubscriptionHosts.hasMatch(uri.host)) return false;
    // A fragment is never used by subscription endpoints and is a strong
    // signal this is an ordinary web link (youtube/telegram share links).
    if (uri.fragment.isNotEmpty) return false;
    // A subscription URL is a BARE link — it must not be embedded in a
    // sentence. Reject whitespace / multi-line before the hint checks, so
    // a `?token=` inside prose is not mistaken for a real endpoint.
    if (raw.contains(RegExp(r'\s'))) return false;
    if (_subPathHints.hasMatch(uri.path)) return true;
    if (_subQueryHints.hasMatch(uri.query)) return true;
    // No path and no query at all: a bare origin is not a subscription.
    if (uri.path.isEmpty || uri.path == '/') return false;
    // A deep, single-segment path with no extension and no obvious page
    // marker is the other common provider shape (/xxxxxxxxxxxxxxxx).
    final segs = uri.pathSegments.where((s) => s.isNotEmpty).toList();
    if (segs.length == 1) {
      final only = segs.first;
      final looksLikePage = only.contains('.') && only.length < 12;
      if (!looksLikePage && only.length >= 8) return true;
    }
    return false;
  }

  /// Reads the clipboard once and returns the import action, or null when
  /// there is nothing importable. Never throws.
  Future<ClipboardOffer?> peekOffer() async {
    String text;
    try {
      text = (await Clipboard.getData(Clipboard.kTextPlain))?.text ?? '';
    } catch (e) {
      Logger.instance.info('clipboard-import', 'read failed: $e');
      return null;
    }
    switch (classify(text)) {
      case ClipboardPayloadKind.subscriptionUrl:
      case ClipboardPayloadKind.shareLinks:
        final t = text.trim();
        // v0.4.9 §user-fix: already-added content is never offered again —
        // the user switches apps and back and the SAME link kept asking.
        if (knownPayload?.call(t) ?? false) return null;
        return ClipboardOffer(
            kind:
                classify(t) == ClipboardPayloadKind.subscriptionUrl
                    ? ClipboardPayloadKind.subscriptionUrl
                    : ClipboardPayloadKind.shareLinks,
            text: t);
      case ClipboardPayloadKind.none:
        return null;
    }
  }
}

enum ClipboardPayloadKind { none, shareLinks, subscriptionUrl }

class ClipboardOffer {
  ClipboardOffer({required this.kind, required this.text});

  final ClipboardPayloadKind kind;
  final String text;

  int get lineCount => text.split(RegExp(r'\r?\n')).where((l) => l.trim().isNotEmpty).length;
}
