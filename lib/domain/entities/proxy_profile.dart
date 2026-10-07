import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart' as c;

/// Which engine executes a profile.
enum CoreKind {
  singbox,
  xray,
  mihomo, // v0.5.3: standalone mihomo (Clash.Meta) engine — full xhttp/XMUX
  wireguardSingbox, // WireGuard endpoint inside sing-box
  amneziaWg, // external amneziawg-go daemon
  masterDnsVpn, // external mdvpn-client daemon
  stormDns, // external StormDNS client daemon (DNS tunnel → local SOCKS5)
  unknown,
}

/// Universal proxy protocol enumeration (normalized, provider-agnostic).
enum ProxyProtocol {
  vmess,
  vless,
  trojan,
  shadowsocks,
  hysteria,
  hysteria2,
  tuic,
  wireguard,
  socks,
  http,
  anytls,
  shadowtls,
  naive,
  ssh,
  masterDnsVpn,
  stormDns, // v0.6.4 §stormdns: DNS-tunnel transport (nullroute1970/StormDNS)
  custom,
}

/// Network transport carried over the protocol.
enum Transport {
  tcp,
  ws,
  grpc,
  h2,
  httpupgrade,
  xhttp,
  quic,
  none, // for protocols without transport concept (e.g. WireGuard)
}

/// Security layer wrapped around the transport.
enum Security {
  none,
  tls,
  reality,
}

/// Where a profile came from.
enum ProfileSource { manual, uriImport, subscription, chain, warp, fileImport }

/// Universal internal representation of a proxy node.
///
/// The UI and all engines operate on this model only; raw provider formats
/// (share links, Clash YAML, sing-box/Xray JSON) are normalized into it by
/// protocol adapters and never leak past the protocols layer.
class ProxyProfile {
  ProxyProfile({
    required this.id,
    required this.name,
    required this.server,
    required this.port,
    required this.protocol,
    this.transport = Transport.none,
    this.security = Security.none,
    this.core = CoreKind.unknown,
    this.uuid,
    this.password,
    this.alterId,
    this.encryption,
    this.flow,
    this.path,
    this.host,
    this.serviceName,
    this.sni,
    this.fingerprint,
    this.allowInsecure = false,
    this.alpn = const [],
    this.realityPublicKey,
    this.realityShortId,
    this.realitySpiderX,
    this.ssMethod,
    this.hysteriaObfsPassword,
    this.hysteriaUpMbps,
    this.hysteriaDownMbps,
    this.tuicUuid,
    this.tuicToken,
    this.wireguard,
    this.amnezia,
    this.rawParams = const {},
    this.rawConfig,
    this.source = ProfileSource.manual,
    this.subscriptionId,
    this.tags = const [],
    this.metadata = const {},
    this.userPinnedCore,
    this.enabled = true,
    this.createdAt,
  });

  final String id;
  String name;
  final String server;
  final int port;
  ProxyProtocol protocol;
  Transport transport;
  Security security;
  CoreKind core;

  // Credentials (persisted via secure vault reference in the data layer).
  String? uuid;
  String? password;
  int? alterId;
  String? encryption;
  String? flow;
  String? path;
  String? host;
  String? serviceName;
  String? sni;
  String? fingerprint;
  bool allowInsecure;
  List<String> alpn;

  // Reality (Xray/sing-box).
  String? realityPublicKey;
  String? realityShortId;
  String? realitySpiderX;

  // Shadowsocks.
  String? ssMethod;

  // Hysteria / Hysteria2.
  String? hysteriaObfsPassword;
  int? hysteriaUpMbps;
  int? hysteriaDownMbps;

  // TUIC.
  String? tuicUuid;
  String? tuicToken;

  // WireGuard / AmneziaWG.
  WireGuardConfig? wireguard;
  AmneziaParams? amnezia;

  // Preserved unknown parameters & raw payload for power users.
  Map<String, String> rawParams;
  String? rawConfig;

  ProfileSource source;
  String? subscriptionId;
  List<String> tags;
  Map<String, String> metadata;
  CoreKind? userPinnedCore;
  bool enabled;
  DateTime? createdAt;

  /// Stable identity used for subscription dedup — hash of everything that
  /// determines the connection, excluding cosmetics (name, tags, source).
  String get identityHash {
    final b = StringBuffer()
      ..write(protocol.name)
      ..write('|$server|$port|')
      ..write(transport.name)
      ..write('|')
      ..write(security.name)
      ..write('|${uuid ?? ''}|${password ?? ''}|${sni ?? ''}|')
      ..write('${realityPublicKey ?? ''}|${realityShortId ?? ''}|')
      ..write('${ssMethod ?? ''}|${path ?? ''}|${host ?? ''}|')
      ..write('${flow ?? ''}|${wireguard?.identityPart ?? ''}');
    return c.sha256.convert(utf8.encode(b.toString())).toString();
  }

  /// Effective core after user override.
  CoreKind get effectiveCore =>
      userPinnedCore == CoreKind.unknown ? core : (userPinnedCore ?? core);

  bool get isWireGuardFamily =>
      protocol == ProxyProtocol.wireguard || wireguard != null;

  ProxyProfile copyWith({
    String? name,
    String? server,
    CoreKind? core,
    CoreKind? userPinnedCore,
    String? subscriptionId,
    bool? enabled,
    Map<String, String>? metadata,
    List<String>? tags,
    String? sni,
    String? password,
    String? uuid,
    String? path,
    String? host,
    int? port,
  }) {
    final p = this;
    return ProxyProfile(
      id: p.id,
      name: name ?? p.name,
      server: server ?? p.server,
      port: port ?? p.port,
      protocol: p.protocol,
      transport: p.transport,
      security: p.security,
      core: core ?? p.core,
      uuid: uuid ?? p.uuid,
      password: password ?? p.password,
      alterId: p.alterId,
      encryption: p.encryption,
      flow: p.flow,
      path: path ?? p.path,
      host: host ?? p.host,
      serviceName: p.serviceName,
      sni: sni ?? p.sni,
      fingerprint: p.fingerprint,
      allowInsecure: p.allowInsecure,
      alpn: p.alpn,
      realityPublicKey: p.realityPublicKey,
      realityShortId: p.realityShortId,
      realitySpiderX: p.realitySpiderX,
      ssMethod: p.ssMethod,
      hysteriaObfsPassword: p.hysteriaObfsPassword,
      hysteriaUpMbps: p.hysteriaUpMbps,
      hysteriaDownMbps: p.hysteriaDownMbps,
      tuicUuid: p.tuicUuid,
      tuicToken: p.tuicToken,
      wireguard: p.wireguard,
      amnezia: p.amnezia,
      rawParams: p.rawParams,
      rawConfig: p.rawConfig,
      source: p.source,
      subscriptionId: subscriptionId ?? p.subscriptionId,
      tags: tags ?? p.tags,
      metadata: metadata ?? p.metadata,
      userPinnedCore: userPinnedCore ?? p.userPinnedCore,
      enabled: p.enabled,
      createdAt: p.createdAt,
    );
  }

  Map<String, dynamic> toPublicJson() => {
        'id': id,
        'name': name,
        'server': server,
        'port': port,
        'protocol': protocol.name,
        'transport': transport.name,
        'security': security.name,
        'core': effectiveCore.name,
        'source': source.name,
        'subscriptionId': subscriptionId,
        'tags': tags,
      };
}

class WireGuardConfig {
  WireGuardConfig({
    required this.privateKey,
    required this.peerPublicKey,
    required this.endpointHost,
    required this.endpointPort,
    this.preSharedKey,
    this.allowedIps = const ['0.0.0.0/0', '::/0'],
    this.dns = const [],
    this.addresses = const [],
    this.mtu,
    this.persistentKeepalive,
    this.reserved,
  });

  String privateKey;
  String peerPublicKey;
  String endpointHost;
  int endpointPort;
  String? preSharedKey;
  List<String> allowedIps;
  List<String> dns;
  List<String> addresses;
  int? mtu;
  int? persistentKeepalive;
  List<int>? reserved; // warp/standard 3-byte reserved field

  String get identityPart =>
      '$privateKey|$peerPublicKey|$endpointHost:$endpointPort';
}

/// AmneziaWG obfuscation parameters — the FULL 3.x surface (amneziawg-go
/// v3.1 semantics, verified 2026-09):
///
///  * `Jc/Jmin/Jmax` — junk packets before each handshake (client-side).
///  * `S1..S4`      — message paddings: init / response / cookie / transport.
///                    AWG 3.x header protection REQUIRES S1..S4 ≥ 12.
///  * `H1..H4`      — message-type header remap; a single value ("1234") or
///                    a range ("1000-2000") — hence String, not int.
///  * `I1..I5`      — custom signature (decoy) packets sent before every
///                    handshake in order, tag DSL: `<b 0x..>`, `<r 12>`,
///                    `<rd 8>`, `<rc 8>`, `<t>` (client-side, no server match
///                    needed). Mutually exclusive with masquerade sugar.
///  * `headerProtectionKey` — AWG 3.x `Hpk` (server-side; `awg genkey`).
///  * `contentPaddingAddition` — AWG 3.x content-padding range.
///
/// Unknown/forward params are kept in [extra] so a future AWG version still
/// round-trips (spec §19: no hardcoded single version).
class AmneziaParams {
  AmneziaParams({
    this.jc,
    this.jmin,
    this.jmax,
    this.s1,
    this.s2,
    this.s3,
    this.s4,
    this.h1,
    this.h2,
    this.h3,
    this.h4,
    this.i1,
    this.i2,
    this.i3,
    this.i4,
    this.i5,
    this.masqId,
    this.masqIp,
    this.masqIb,
    this.headerProtectionKey,
    this.contentPaddingAddition,
    this.randomTrailers,
    this.disableCookies,
    this.extra = const {},
  });

  final int? jc, jmin, jmax, s1, s2;
  final int? s3, s4;

  /// Single value ("1234") or range ("1000-2000").
  final String? h1, h2, h3, h4;
  final String? i1, i2, i3, i4, i5;

  /// Masquerade sugar (sing-box-lx wire names `id`/`ip`/`ib`, verified in
  /// v1.14.1-lx.8's option struct): builds the I1 decoy for you —
  /// `masqId` = decoy domain, `masqIp` = protocol (`quic`/`ipip`/…),
  /// `masqIb` = browser profile (`chrome`/…). Mutually exclusive with a
  /// hand-written i1. Live-proven against Cloudflare WARP (warp=on).
  final String? masqId, masqIp, masqIb;
  final String? headerProtectionKey;
  final String? contentPaddingAddition;

  /// AWG 3.x dialect flags (amnezia-client WARP confs): junk TRAILERS after
  /// each packet and cookie replies disabled. Absent = server default.
  final bool? randomTrailers;
  final bool? disableCookies;
  final Map<String, String> extra;

  bool get isNotEmpty =>
      jc != null ||
      jmin != null ||
      jmax != null ||
      s1 != null ||
      s2 != null ||
      s3 != null ||
      s4 != null ||
      h1 != null ||
      h2 != null ||
      h3 != null ||
      h4 != null ||
      i1 != null ||
      i2 != null ||
      i3 != null ||
      i4 != null ||
      i5 != null ||
      (masqId != null && masqId!.isNotEmpty) ||
      (masqIp != null && masqIp!.isNotEmpty) ||
      (masqIb != null && masqIb!.isNotEmpty) ||
      (headerProtectionKey != null && headerProtectionKey!.isNotEmpty) ||
      (contentPaddingAddition != null &&
          contentPaddingAddition!.isNotEmpty) ||
      randomTrailers == true ||
      disableCookies == true ||
      extra.isNotEmpty;

  /// v0.5.0 §user-fix (node editor wiped AWG params): non-null arguments
  /// REPLACE the stored value; null arguments KEEP it. The editor passes
  /// every form field — a field the user left empty still carries the
  /// parsed-null of the SEEDED controller, so merge semantics must be
  /// "null = keep" to round-trip untouched obfuscation params.
  AmneziaParams copyWith({
    int? jc,
    int? jmin,
    int? jmax,
    int? s1,
    int? s2,
    int? s3,
    int? s4,
    String? h1,
    String? h2,
    String? h3,
    String? h4,
    String? i1,
    String? i2,
    String? i3,
    String? i4,
    String? i5,
    String? masqId,
    String? masqIp,
    String? masqIb,
    String? headerProtectionKey,
    String? contentPaddingAddition,
    bool? randomTrailers,
    bool? disableCookies,
    Map<String, String>? extra,
  }) =>
      AmneziaParams(
        jc: jc ?? this.jc,
        jmin: jmin ?? this.jmin,
        jmax: jmax ?? this.jmax,
        s1: s1 ?? this.s1,
        s2: s2 ?? this.s2,
        s3: s3 ?? this.s3,
        s4: s4 ?? this.s4,
        h1: h1 ?? this.h1,
        h2: h2 ?? this.h2,
        h3: h3 ?? this.h3,
        h4: h4 ?? this.h4,
        i1: i1 ?? this.i1,
        i2: i2 ?? this.i2,
        i3: i3 ?? this.i3,
        i4: i4 ?? this.i4,
        i5: i5 ?? this.i5,
        masqId: masqId ?? this.masqId,
        masqIp: masqIp ?? this.masqIp,
        masqIb: masqIb ?? this.masqIb,
        headerProtectionKey: headerProtectionKey ?? this.headerProtectionKey,
        contentPaddingAddition:
            contentPaddingAddition ?? this.contentPaddingAddition,
        randomTrailers: randomTrailers ?? this.randomTrailers,
        disableCookies: disableCookies ?? this.disableCookies,
        extra: extra ?? this.extra,
      );

  Map<String, String> toConfLines() => {
        if (jc != null) 'Jc': '$jc',
        if (jmin != null) 'Jmin': '$jmin',
        if (jmax != null) 'Jmax': '$jmax',
        if (s1 != null) 'S1': '$s1',
        if (s2 != null) 'S2': '$s2',
        if (s3 != null) 'S3': '$s3',
        if (s4 != null) 'S4': '$s4',
        if (h1 != null) 'H1': '$h1',
        if (h2 != null) 'H2': '$h2',
        if (h3 != null) 'H3': '$h3',
        if (h4 != null) 'H4': '$h4',
        if (i1 != null) 'I1': '$i1',
        if (i2 != null) 'I2': '$i2',
        if (i3 != null) 'I3': '$i3',
        if (i4 != null) 'I4': '$i4',
        if (i5 != null) 'I5': '$i5',
        if (headerProtectionKey != null &&
            headerProtectionKey!.isNotEmpty)
          'Hpk': headerProtectionKey!,
        if (contentPaddingAddition != null &&
            contentPaddingAddition!.isNotEmpty)
          'ContentPaddingAddition': contentPaddingAddition!,
        if (randomTrailers == true) 'RandomTrailers': 'on',
        if (disableCookies == true) 'DisableCookies': 'on',
        ...extra,
      };
}

/// Short random hex ids used across profiles, chains and rules.
class Ids {
  static final Random _r = Random.secure();

  static String newId() {
    final b = List<int>.generate(16, (_) => _r.nextInt(256));
    return b.map((e) => e.toRadixString(16).padLeft(2, '0')).join();
  }

  static String randomHex(int bytes) {
    final b = List<int>.generate(bytes, (_) => _r.nextInt(256));
    return b.map((e) => e.toRadixString(16).padLeft(2, '0')).join();
  }
}

