import '../../domain/entities/proxy_profile.dart';
import '../core_detector.dart';

/// Fragmentation presets (§14). Values map 1:1 to Xray freedom `fragment`
/// settings. Eligibility is enforced by [FragmentationEngine].
class FragmentProfile {
  const FragmentProfile({
    required this.id,
    required this.name,
    required this.packets,
    required this.length,
    required this.interval,
  });
  final String id;
  final String name;

  /// `tlshello` or `1-3` (packets after ClientHello).
  final String packets;

  /// Fragment size range, e.g. `100-200`.
  final String length;

  /// Delay between fragments in ms, e.g. `10-20`.
  final String interval;

  Map<String, dynamic> toJson() => {
        'id': id,
        'packets': packets,
        'length': length,
        'interval': interval,
      };

  static FragmentProfile fromJson(Map<String, dynamic> j) => FragmentProfile(
        id: j['id'] as String,
        name: (j['name'] ?? j['id']) as String,
        packets: j['packets'] as String,
        length: j['length'] as String,
        interval: j['interval'] as String,
      );
}

class FragmentPresets {
  static const conservative = FragmentProfile(
    id: 'conservative',
    name: 'Conservative',
    packets: 'tlshello',
    length: '10-40',
    interval: '5-10',
  );

  static const standard = FragmentProfile(
    id: 'default',
    name: 'Default',
    packets: 'tlshello',
    length: '100-200',
    interval: '10-20',
  );

  static const aggressive = FragmentProfile(
    id: 'aggressive',
    name: 'Aggressive',
    packets: '1-3',
    length: '10-20',
    interval: '5-10',
  );

  static const all = [conservative, standard, aggressive];

  static FragmentProfile? byId(String? id) {
    if (id == null) return null;
    for (final p in all) {
      if (p.id == id) return p;
    }
    return null;
  }
}

/// Decides whether fragmentation is technically compatible (§14: never blindly
/// fragment). Currently an Xray capability on TLS-family transports.
class FragmentationEngine {
  final CoreDetector _detector = CoreDetector();

  bool isEligible(ProxyProfile p) {
    // Resolve the effective core, running detection when the profile has no
    // pinned/detected engine yet.
    final core = p.effectiveCore == CoreKind.unknown
        ? _detector.detect(p).core
        : p.effectiveCore;
    if (core != CoreKind.xray) return false;
    if (p.security == Security.none) return false;
    return switch (p.transport) {
      Transport.tcp ||
      Transport.ws ||
      Transport.grpc ||
      Transport.h2 ||
      Transport.httpupgrade ||
      Transport.xhttp =>
        true,
      Transport.quic ||
      Transport.none =>
        false, // QUIC/UDP and transport-less (WG) cannot TCP-fragment
    };
  }

  /// Try profiles in a safe order; the caller tests connectivity and persists
  /// the winning profile via the cache.
  List<FragmentProfile> orderedAttempts() => const [
        FragmentPresets.conservative,
        FragmentPresets.standard,
        FragmentPresets.aggressive,
      ];
}
