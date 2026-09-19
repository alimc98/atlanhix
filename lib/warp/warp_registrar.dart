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

  bool get hasAmneziaParams =>
      awgJc != null ||
      awgH1 != null ||
      awgS1 != null ||
      awgI1 != null ||
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
          headerProtectionKey: awgHpk,
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
      server: a.endpointV4,
      port: 2408,
      protocol: ProxyProtocol.wireguard,
      core: CoreKind.wireguardSingbox,
      wireguard: WireGuardConfig(
        privateKey: a.privateKey,
        peerPublicKey: a.peerPublicKey,
        endpointHost: a.endpointV4,
        endpointPort: 2408,
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
