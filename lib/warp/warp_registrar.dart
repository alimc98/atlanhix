import 'dart:convert';
import 'package:cryptography/cryptography.dart';
import '../domain/entities/proxy_profile.dart';

/// A registered Cloudflare WARP device (fields per the documented
/// device-registration API used by official clients; see THIRD_PARTY_LICENSES
/// for provenance). Secrets are held only until persisted into the vault.
class WarpAccount {
  WarpAccount({
    required this.deviceId,
    required this.token,
    required this.privateKey,
    required this.peerPublicKey,
    required this.endpointV4,
    this.endpointV6,
    this.addressV4,
    this.addressV6,
    this.license,
    this.clientId,
    this.registeredAt,
    // v0.4.8 §user: AmneziaWG obfuscation params — WARP's plain WireGuard
    // handshake is routinely throttled on Iranian carriers; an AWG-3.1
    // masked peer (warp-generator.vercel.app style) survives where the
    // vanilla one is killed. Null/empty params = plain WARP.
    this.awgJc,
    this.awgJmin,
    this.awgJmax,
    this.awgS1,
    this.awgS2,
    this.awgS3,
    this.awgS4,
    this.awgH1,
    this.awgH2,
    this.awgH3,
    this.awgH4,
    // AWG 3.x: decoy/signature packets (tag DSL) + header protection key.
    this.awgI1,
    this.awgI2,
    this.awgI3,
    this.awgI4,
    this.awgI5,
    this.awgHpk,
    this.awgMasqId,
    this.awgMasqIp,
    this.awgMasqIb,
    this.awgRandomTrailers,
    this.awgDisableCookies,
    // v0.4.9 §user: the WARP API hands out ONE default endpoint (host:port);
    // carriers block the popular ones, so the account can carry a SCANNED
    // best endpoint (WarpServer-style IP:port sweep). Null/empty = default.
    this.endpointOverride,
  });

  final String deviceId;
  final String token;
  final String privateKey; // base64 x25519
  final String peerPublicKey;
  final String endpointV4;
  final String? endpointV6;
  final String? addressV4;
  final String? addressV6;
  final String? license;
  final String? clientId;
  final DateTime? registeredAt;

  // ---- AmneziaWG 3.x — the FULL 3.1 surface (see AmneziaParams): junk,
  // paddings s1..s4, header remap h1..h4 (single or range), decoy packets
  // i1..i5 (tag DSL) and the header-protection key. Kept on the ACCOUNT so
  // a re-save from the manual-params sheet round-trips losslessly.
  final int? awgJc;
  final int? awgJmin;
  final int? awgJmax;
  final int? awgS1;
  final int? awgS2;
  final int? awgS3;
  final int? awgS4;
  final String? awgH1;
  final String? awgH2;
  final String? awgH3;
  final String? awgH4;
  final String? awgI1;
  final String? awgI2;
  final String? awgI3;
  final String? awgI4;
  final String? awgI5;
  final String? awgHpk;

  /// Masquerade sugar (sing-box-lx wire names `id`/`ip`/`ib`): decoy
  /// domain + protocol + browser profile. Builds the I1 masquerade decoy
  /// without hand-writing the tag DSL. Live-proven vs Cloudflare (warp=on).
  final String? awgMasqId;
  final String? awgMasqIp;
  final String? awgMasqIb;

  /// AWG 3.x dialect flags (amnezia-client confs: RandomTrailers /
  /// DisableCookies). Null = server default.
  final bool? awgRandomTrailers;
  final bool? awgDisableCookies;

  /// Scanned best `host:port` for the WARP peer (overrides the API default).
  final String? endpointOverride;

  /// Raw x25519 bytes of our static private key (for the real handshake
  /// probe used by the endpoint scanner).
  List<int> get privateKeyBytes {
    try {
      return base64.decode(privateKey);
    } on FormatException {
      return List.filled(32, 0);
    }
  }

  /// Raw x25519 bytes of the server's public key.
  List<int> get serverKeyBytes {
    try {
      return base64.decode(peerPublicKey);
    } on FormatException {
      return List.filled(32, 0);
    }
  }

  /// The endpoint string actually dialed: the scanned override when it has
  /// any content, else the API default. Both may be `host`, `host:port`,
  /// `[v6]` or `[v6]:port`.
  String get _endpointSource {
    final o = endpointOverride?.trim();
    if (o != null && o.isNotEmpty) return o;
    return endpointV4.trim();
  }

  /// Host part of the dial endpoint.
  ///
  /// v0.4.9: previously returned `endpointV4` RAW — the WARP API hands out
  /// `162.159.192.6:0`, so the engine received a "host" containing the port
  /// (and a zero port) and failed to start the tunnel.
  String get dialHost => _splitEndpoint(_endpointSource).$1;

  /// Port of the dial endpoint — never 0 (API's `:0` means "WireGuard
  /// default"), clamped to a valid range, default 2408.
  int get dialPort => _splitEndpoint(_endpointSource).$2;

  /// Splits `host`, `host:port`, `[v6]` or `[v6]:port`. A missing, zero or
  /// invalid port resolves to [defaultPort] (2408 = WireGuard/WARP default).
  static (String, int) _splitEndpoint(String raw, {int defaultPort = 2408}) {
    final s = raw.trim();
    if (s.isEmpty) return ('', defaultPort);
    if (s.startsWith('[')) {
      final i = s.indexOf(']');
      if (i > 0) {
        final host = s.substring(1, i);
        final rest = s.substring(i + 1);
        final p =
            rest.startsWith(':') ? int.tryParse(rest.substring(1).trim()) : null;
        return (host, (p != null && p > 0 && p <= 65535) ? p : defaultPort);
      }
      return (s, defaultPort);
    }
    final i = s.lastIndexOf(':');
    if (i > 0) {
      final head = s.substring(0, i);
      if (!head.contains(':')) {
        // Exactly one colon → host:port.
        final host = head.trim();
        final p = int.tryParse(s.substring(i + 1).trim());
        if (host.isNotEmpty) {
          return (host, (p != null && p > 0 && p <= 65535) ? p : defaultPort);
        }
      }
      // Several colons, no brackets → naked IPv6 without a port.
      return (s, defaultPort);
    }
    // Plain hostname / IPv4 with no port.
    return (s, defaultPort);
  }

  bool get hasAmneziaParams =>
      awgJc != null ||
      awgH1 != null ||
      awgS1 != null ||
      awgI1 != null ||
      (awgMasqId != null && awgMasqId!.isNotEmpty) ||
      (awgHpk != null && awgHpk!.isNotEmpty);

  /// AmneziaWG params built from the stored fields (null when plain WARP).
  AmneziaParams? get amneziaParams => hasAmneziaParams
      ? AmneziaParams(
          jc: awgJc,
          jmin: awgJmin,
          jmax: awgJmax,
          s1: awgS1,
          s2: awgS2,
          s3: awgS3,
          s4: awgS4,
          h1: awgH1,
          h2: awgH2,
          h3: awgH3,
          h4: awgH4,
          i1: awgI1,
          i2: awgI2,
          i3: awgI3,
          i4: awgI4,
          i5: awgI5,
          masqId: awgMasqId,
          masqIp: awgMasqIp,
          masqIb: awgMasqIb,
          headerProtectionKey: awgHpk,
          randomTrailers: awgRandomTrailers,
          disableCookies: awgDisableCookies,
        )
      : null;

  /// WARP uses the client_id as the WireGuard `reserved` field.
  List<int>? get reservedBytes {
    final b64 = clientId;
    if (b64 == null || b64.isEmpty) return null;
    try {
      return base64.decode(b64);
    } on FormatException {
      return null;
    }
  }

  Map<String, dynamic> toPublicJson() => {
        'deviceId': deviceId,
        'endpoint': endpointV4,
        'addressV4': addressV4,
        'addressV6': addressV6,
        'license': license,
        'registeredAt': registeredAt?.toIso8601String(),
        if (endpointOverride != null) 'endpointOverride': endpointOverride,
        if (hasAmneziaParams) 'amneziaWG': true,
      };
}

class WarpKeyPair {
  WarpKeyPair(this.privateKeyB64, this.publicKeyB64);
  final String privateKeyB64;
  final String publicKeyB64;
}

/// Generates device registration payloads against Cloudflare WARP.
/// The HTTP layer is injected so tests never touch the network.
abstract class WarpHttp {
  Future<Map<String, dynamic>> post(
    Uri url, {
    Map<String, String> headers = const {},
    Object? body,
  });
  Future<Map<String, dynamic>> get(Uri url, {Map<String, String> headers = const {}});
  Future<Map<String, dynamic>> patch(
    Uri url, {
    Map<String, String> headers = const {},
    Object? body,
  });
}

class WarpRegistrar {
  WarpRegistrar({required this.http, this.apiBase = 'https://api.cloudflareclient.com'});

  final WarpHttp http;
  final String apiBase;

  static const _apiVersion = 'v0a2158';
  static const _headers = {
    'User-Agent': '1.1.1.1/6.28',
    'Content-Type': 'application/json',
  };

  /// Generates a keypair locally and registers a new WARP device.
  Future<WarpAccount> register({String locale = 'en_US'}) async {
    final alg = X25519();
    final keyPair = await alg.newKeyPair();
    final pub = await keyPair.extractPublicKey();

    String b64(List<int> bytes) => base64.encode(bytes);
    final privB64 = b64((await keyPair.extractPrivateKeyBytes()));
    final pubB64 = b64(pub.bytes);

    final body = {
      'install_id': '',
      'tos': DateTime.now().toUtc().toIso8601String().replaceAll('Z', 'Z'),
      'model': 'PC',
      'serial_number': DateTime.now().microsecondsSinceEpoch.toString(),
      'language': 'en',
      'key': pubB64,
      'type': 'Windows',
      'locale': locale,
      'warp_enabled': true,
    };

    final resp = await http.post(
      Uri.parse('$apiBase/$_apiVersion/reg'),
      headers: _headers,
      body: body,
    );

    final config = resp['config'] as Map?;
    if (config == null) {
      throw StateError('WARP registration response missing config');
    }
    final peers = (config['peers'] as List?) ?? const [];
    final peer0 = peers.isNotEmpty ? (peers.first as Map) : null;
    final interface = (config['interface'] as Map?) ?? const {};

    return WarpAccount(
      deviceId: '${resp['id']}',
      token: '${resp['token'] ?? ''}',
      privateKey: privB64,
      peerPublicKey: '${peer0?['public_key'] ?? ''}',
      endpointV4: '${(peer0?['endpoint'] as Map?)?['v4'] ?? ''}',
      endpointV6: (peer0?['endpoint'] as Map?)?['v6'] as String?,
      addressV4: ((interface['addresses'] as Map?)?['v4'] ?? '') as String?,
      addressV6: ((interface['addresses'] as Map?)?['v6'] ?? '') as String?,
      license: '${resp['license'] ?? ''}',
      clientId: '${config['client_id'] ?? ''}',
      registeredAt: DateTime.now(),
      // v0.4.9 §user — WARP runs as AmneziaWG 3.1 by default. This exact
      // set was validated LIVE against Cloudflare (the tool/warp_e2e_
      // config.dart matrix: plain/awg/awgjunk/awgmasc/awgjt/awgfinal/
      // awgdc runs through sing-box-lx → cdn-cgi/trace warp=on): junk
      // packets (jc/jmin/jmax), the masquerade decoy (id/ip/ib) and
      // random trailers. s1/s2/h1..h4 are deliberately ABSENT — they
      // reshape the handshake and Cloudflare's vanilla parser drops it
      // ("handshake did not complete after 5 seconds"). Clearing the
      // fields in the WARP sheet reverts to plain WireGuard.
      awgJc: 4,
      awgJmin: 64,
      awgJmax: 96,
      awgMasqId: 'www.google.com',
      awgMasqIp: 'quic',
      awgMasqIb: 'chrome',
      awgRandomTrailers: true,
    );
  }

  /// Binds the device to a Warp+ license (max 5 devices per license).
  Future<void> updateLicense(WarpAccount account, String licenseKey) async {
    await http.patch(
      Uri.parse('$apiBase/$_apiVersion/reg/${account.deviceId}/account'),
      headers: {..._headers, 'Authorization': 'Bearer ${account.token}'},
      body: {'license': licenseKey},
    );
  }

  /// Traces the current egress: `warp=on|plus|off`.
  Future<String> trace() async {
    final resp = await http.get(
      Uri.parse('https://www.cloudflare.com/cdn-cgi/trace'),
      headers: const {},
    );
    final raw = resp.toString();
    final m = RegExp(r'warp=(\w+)').firstMatch(raw);
    return m?.group(1) ?? 'unknown';
  }

  /// Converts the account into a runnable WireGuard-family profile.
  ProxyProfile toProfile(WarpAccount a, {String name = 'Cloudflare WARP'}) =>
      WarpRegistrar.profileFor(a, name: name);

  /// Pure conversion (no network, no instance state) so any layer can
  /// materialize a registered WARP device as a WireGuard endpoint — used by
  /// the v0.3.0 WARP traffic chain (§8).
  ///
  /// v0.4.8 §user: when the account carries AmneziaWG params the profile is
  /// tagged AWG — the WARP handshake leaves as junk-padded packets that
  /// carrier DPI cannot fingerprint as plain WireGuard.
  static ProxyProfile profileFor(WarpAccount a, {String name = 'Cloudflare WARP'}) {
    final awg = a.amneziaParams;
    return ProxyProfile(
      id: Ids.newId(),
      name: name,
      server: a.dialHost,
      port: a.dialPort,
      protocol: ProxyProtocol.wireguard,
      core: CoreKind.wireguardSingbox,
      wireguard: WireGuardConfig(
        privateKey: a.privateKey,
        peerPublicKey: a.peerPublicKey,
        endpointHost: a.dialHost,
        endpointPort: a.dialPort,
        allowedIps: const ['0.0.0.0/0', '::/0'],
        addresses: [
          if (a.addressV4 != null && a.addressV4!.isNotEmpty) a.addressV4!,
          if (a.addressV6 != null && a.addressV6!.isNotEmpty) a.addressV6!,
        ],
        dns: const ['1.1.1.1'],
        mtu: 1280,
        persistentKeepalive: 25,
        reserved: a.reservedBytes,
      ),
      amnezia: awg,
      source: ProfileSource.warp,
      tags: [if (awg != null) ...['warp', 'awg-3.1'] else 'warp'],
    );
  }
}
