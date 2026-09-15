import '../core/logger.dart';
import '../domain/entities/proxy_profile.dart';
import 'app_storage.dart';
import 'secure_vault.dart';

/// Persistence keys used inside the JSON store.
class StoreKeys {
  static const profiles = 'profiles';
  static const subscriptions = 'subscriptions';
  static const settings = 'settings';
  static const chains = 'chains';
  static const routing = 'routing';
  static const warp = 'warp';
}

/// Vault reference encoding: secret values live in the vault, the store only
/// holds `@vault:<key>` tokens (§41).
const vaultPrefix = '@vault:';

bool isVaultRef(String? v) => v != null && v.startsWith(vaultPrefix);
String vaultKeyOf(String v) => v.substring(vaultPrefix.length);

/// Loads profiles from the store, resolving vault-backed secrets.
Future<List<ProxyProfile>> loadProfiles(
    JsonStore store, SecureVault vault) async {
  final section = store.section(StoreKeys.profiles);
  final out = <ProxyProfile>[];
  for (final entry in section.entries) {
    try {
      final j = (entry.value as Map).cast<String, dynamic>();
      out.add(await _profileFromStorable(j, vault));
    } on FormatException catch (e) {
      Logger.instance.warn(
          'profiles', 'Skipping corrupt profile ${entry.key}: ${e.message}');
    }
  }
  return out;
}

Future<ProxyProfile> _profileFromStorable(
    Map<String, dynamic> j, SecureVault vault) async {
  Future<String?> secret(String? v) async {
    if (isVaultRef(v)) return vault.read(vaultKeyOf(v!));
    return v;
  }

  final wgRaw = j['wireguard'] as Map<String, dynamic>?;
  final wg = wgRaw == null
      ? null
      : WireGuardConfig(
          privateKey: await secret(wgRaw['privateKey'] as String?) ?? '',
          peerPublicKey: (wgRaw['peerPublicKey'] ?? '') as String,
          endpointHost: (wgRaw['endpointHost'] ?? '') as String,
          endpointPort: (wgRaw['endpointPort'] ?? 0) as int,
          preSharedKey: await secret(wgRaw['preSharedKey'] as String?),
          allowedIps: ((wgRaw['allowedIps'] ?? const []) as List).cast<String>(),
          dns: ((wgRaw['dns'] ?? const []) as List).cast<String>(),
          addresses: ((wgRaw['addresses'] ?? const []) as List).cast<String>(),
          mtu: wgRaw['mtu'] as int?,
          persistentKeepalive: wgRaw['persistentKeepalive'] as int?,
          reserved: (wgRaw['reserved'] as List?)
              ?.map((e) => int.tryParse('$e') ?? 0)
              .toList(),
        );
  return ProxyProfile(
    id: j['id'] as String,
    name: j['name'] as String,
    server: j['server'] as String,
    port: j['port'] as int,
    protocol: ProxyProtocol.values.firstWhere((e) => e.name == j['protocol']),
    transport: Transport.values.firstWhere((e) => e.name == j['transport'],
        orElse: () => Transport.none),
    security: Security.values.firstWhere((e) => e.name == j['security'],
        orElse: () => Security.none),
    core: CoreKind.values.firstWhere((e) => e.name == j['core'],
        orElse: () => CoreKind.unknown),
    uuid: await secret(j['uuid'] as String?),
    password: await secret(j['password'] as String?),
    alterId: j['alterId'] as int?,
    encryption: j['encryption'] as String?,
    flow: j['flow'] as String?,
    path: j['path'] as String?,
    host: j['host'] as String?,
    serviceName: j['serviceName'] as String?,
    sni: j['sni'] as String?,
    fingerprint: j['fingerprint'] as String?,
    allowInsecure: j['allowInsecure'] as bool? ?? false,
    alpn: ((j['alpn'] ?? const []) as List).cast<String>(),
    realityPublicKey: j['realityPublicKey'] as String?,
    realityShortId: j['realityShortId'] as String?,
    realitySpiderX: j['realitySpiderX'] as String?,
    ssMethod: j['ssMethod'] as String?,
    hysteriaObfsPassword: await secret(j['hysteriaObfsPassword'] as String?),
    hysteriaUpMbps: j['hysteriaUpMbps'] as int?,
    hysteriaDownMbps: j['hysteriaDownMbps'] as int?,
    tuicUuid: await secret(j['tuicUuid'] as String?),
    tuicToken: await secret(j['tuicToken'] as String?),
    wireguard: wg,
    amnezia: j['amnezia'] == null
        ? null
        : AmneziaParams(
            jc: j['amnezia']['jc'] as int?,
            jmin: j['amnezia']['jmin'] as int?,
            jmax: j['amnezia']['jmax'] as int?,
            s1: j['amnezia']['s1'] as int?,
            s2: j['amnezia']['s2'] as int?,
            h1: j['amnezia']['h1'] as int?,
            h2: j['amnezia']['h2'] as int?,
            h3: j['amnezia']['h3'] as int?,
            h4: j['amnezia']['h4'] as int?,
          ),
    rawParams: ((j['rawParams'] ?? const {}) as Map).cast<String, String>(),
    rawConfig: await secret((j['raw']?['secret']) as String?) ??
        (j['raw']?['text']) as String?,
    source: ProfileSource.values.firstWhere((e) => e.name == j['source'],
        orElse: () => ProfileSource.manual),
    subscriptionId: j['subscriptionId'] as String?,
    tags: ((j['tags'] ?? const []) as List).cast<String>(),
    metadata: ((j['metadata'] ?? const {}) as Map).cast<String, String>(),
    userPinnedCore: j['userPinnedCore'] == null
        ? null
        : CoreKind.values.firstWhere((e) => e.name == j['userPinnedCore']),
    enabled: j['enabled'] as bool? ?? true,
    createdAt: j['createdAt'] == null
        ? null
        : DateTime.parse(j['createdAt'] as String),
  );
}
