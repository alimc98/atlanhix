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
  static ProxyProfile profileFor(WarpAccount a, {String name = 'Cloudflare WARP'}) {
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
      source: ProfileSource.warp,
      tags: const ['warp'],
    );
  }
}
