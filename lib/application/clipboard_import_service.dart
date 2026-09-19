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
/// Reading the clipboard is opt-in per offer (Android 12+ shows the system
/// paste toast on the FIRST read of each process lifetime — this service
/// reads once, right after warm-up, so the toast rides the prompt itself).
class ClipboardImportService {
  ClipboardImportService({
    required this.importer,
    required this.onAddNodes,
    required this.onAddSubscription,
  });

  final MultiFormatImporter importer;

  /// Persists node profiles (repository upsert). Injected so this service
  /// stays UI-free and testable.
  final Future<void> Function(List<ProxyProfile> profiles) onAddNodes;

  /// Persists + fetches a subscription. Injected for the same reason.
  final Future<void> Function(String url) onAddSubscription;

  static final _subUri = RegExp(
    r'^(vless|vmess|ss|ssr|trojan|hysteria2?|tuic|juicity|socks5?|wireguard|wg|mdvpn)://',
    caseSensitive: false,
  );

  /// Classification of the last clipboard payload.
  ClipboardPayloadKind classify(String text) {
    final t = text.trim();
    if (t.isEmpty) return ClipboardPayloadKind.none;
    if (t.startsWith('http://') || t.startsWith('https://')) {
      // A subscription URL is a bare single http(s) link.
      if (Uri.tryParse(t)?.host.isNotEmpty ?? false) {
        return ClipboardPayloadKind.subscriptionUrl;
      }
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
        return ClipboardOffer(kind: ClipboardPayloadKind.subscriptionUrl, text: text.trim());
      case ClipboardPayloadKind.shareLinks:
        return ClipboardOffer(kind: ClipboardPayloadKind.shareLinks, text: text.trim());
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
