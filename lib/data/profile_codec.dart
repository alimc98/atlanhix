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
///
/// v0.4.9 §boot: the resolve is TWO-PHASE — first every `@vault:` token in
/// the section is collected and read from the OS vault in PARALLEL
/// (Future.wait), then profiles decode from the prefetched map. The naive
/// loop awaited one EncryptedSharedPreferences IPC per secret per profile
/// (uuid+password+… × hundreds of subscription nodes) and dominated cold
/// boot; parallel prefetch collapses that to one round-trip batch.
///
/// v0.5.0 §boot MEASURED (device logcat): 2.8 s of the 3.2 s bootstrap sat
/// in `profiles.load` — flutter_secure_storage 9.x pays a one-time Keystore
/// master-key + EncryptedSharedPreferences setup of ~2.5 s on the FIRST
/// vault call of the process. [loadProfiles] now takes a DEFERRED resolver:
/// decode runs synchronously from the store and the vault batch read
/// happens OUTSIDE the boot path (the caller decides when — after the
/// first paint). Until [resolveSecrets] completes, [ProxyProfile.secrets
/// are the `@vault:` tokens themselves], which NOTHING renders and the
/// connect paths never touch before the deferred pass lands — see
/// [ProfileRepository.resolveSecrets].
Future<List<ProxyProfile>> loadProfiles(JsonStore store) async {
  final section = store.section(StoreKeys.profiles);
  final resolve = _identityResolver;
  final out = <ProxyProfile>[];
  for (final entry in section.entries) {
    try {
      final j = (entry.value as Map).cast<String, dynamic>();
      out.add(_profileFromStorable(j, resolve));
    } on FormatException catch (e) {
      Logger.instance.warn(
          'profiles', 'Skipping corrupt profile ${entry.key}: ${e.message}');
    }
  }
  return out;
}

/// Pass-through used by the fast path above; the deferred pass swaps in
/// real secret resolution.
String? _identityResolver(String? v) => v;

/// v0.5.0 §boot: SECOND phase of the split load — batch-resolve every
/// `@vault:` token on the already-decoded profiles. Runs after the first
/// paint so the one-time Keystore setup (~2.5 s on the device) never sits
/// between launch and the UI.
Future<void> resolveProfileSecrets(
    List<ProxyProfile> profiles, SecureVault vault) async {
  final keys = <String>{};
  void collect(String? v) {
    if (isVaultRef(v)) keys.add(vaultKeyOf(v!));
  }

  for (final p in profiles) {
    collect(p.uuid);
    collect(p.password);
    collect(p.hysteriaObfsPassword);
    collect(p.tuicUuid);
    collect(p.tuicToken);
    collect(p.rawConfig);
    final wg = p.wireguard;
    if (wg != null) {
      collect(wg.privateKey);
      collect(wg.preSharedKey);
    }
  }
  if (keys.isEmpty) return;
  final prefetched = await vault.readAll(keys);
  bool changed = false;
  String? swap(String? v) {
    if (!isVaultRef(v)) return v;
    final r = prefetched[vaultKeyOf(v!)];
    if (r != null) changed = true;
    return r;
  }

  for (final p in profiles) {
    if (p.uuid != null && isVaultRef(p.uuid!)) {
      p.uuid = swap(p.uuid);
      changed = true;
    }
    if (p.password != null && isVaultRef(p.password!)) {
      p.password = swap(p.password);
      changed = true;
    }
    if (p.hysteriaObfsPassword != null &&
        isVaultRef(p.hysteriaObfsPassword!)) {
      p.hysteriaObfsPassword = swap(p.hysteriaObfsPassword);
      changed = true;
    }
    if (p.tuicUuid != null && isVaultRef(p.tuicUuid!)) {
      p.tuicUuid = swap(p.tuicUuid);
      changed = true;
    }
    if (p.tuicToken != null && isVaultRef(p.tuicToken!)) {
      p.tuicToken = swap(p.tuicToken);
      changed = true;
    }
    if (p.rawConfig != null && isVaultRef(p.rawConfig!)) {
      p.rawConfig = swap(p.rawConfig);
      changed = true;
    }
    final wg = p.wireguard;
    if (wg != null) {
      if (wg.privateKey != null && isVaultRef(wg.privateKey!)) {
        // WireGuardConfig.privateKey is non-nullable: a missing vault entry
        // resolves to '' (same treatment as the original decode path).
        wg.privateKey = swap(wg.privateKey) ?? '';
        changed = true;
      }
      if (wg.preSharedKey != null && isVaultRef(wg.preSharedKey!)) {
        wg.preSharedKey = swap(wg.preSharedKey);
        changed = true;
      }
    }
  }
  if (changed) {
    Logger.instance.info('boot',
        'profile secrets resolved post-paint (${keys.length} vault keys)');
  }
}

ProxyProfile _profileFromStorable(
    Map<String, dynamic> j, String? Function(String?) resolve) {
  final secret = resolve;

  final wgRaw = j['wireguard'] as Map<String, dynamic>?;
  final wg = wgRaw == null
      ? null
      : WireGuardConfig(
          privateKey: secret(wgRaw['privateKey'] as String?) ?? '',
          peerPublicKey: (wgRaw['peerPublicKey'] ?? '') as String,
          endpointHost: (wgRaw['endpointHost'] ?? '') as String,
          endpointPort: (wgRaw['endpointPort'] ?? 0) as int,
          preSharedKey: secret(wgRaw['preSharedKey'] as String?),
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
    uuid: secret(j['uuid'] as String?),
    password: secret(j['password'] as String?),
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
    hysteriaObfsPassword: secret(j['hysteriaObfsPassword'] as String?),
    hysteriaUpMbps: j['hysteriaUpMbps'] as int?,
    hysteriaDownMbps: j['hysteriaDownMbps'] as int?,
    tuicUuid: secret(j['tuicUuid'] as String?),
    tuicToken: secret(j['tuicToken'] as String?),
    wireguard: wg,
    amnezia: j['amnezia'] == null
        ? null
        : AmneziaParams(
            jc: j['amnezia']['jc'] as int?,
            jmin: j['amnezia']['jmin'] as int?,
            jmax: j['amnezia']['jmax'] as int?,
            s1: j['amnezia']['s1'] as int?,
            s2: j['amnezia']['s2'] as int?,
            s3: j['amnezia']['s3'] as int?,
            s4: j['amnezia']['s4'] as int?,
            h1: (j['amnezia']['h1'] as String?)?.trim().isEmpty == true
                ? null
                : j['amnezia']['h1'] as String?,
            h2: (j['amnezia']['h2'] as String?)?.trim().isEmpty == true
                ? null
                : j['amnezia']['h2'] as String?,
            h3: (j['amnezia']['h3'] as String?)?.trim().isEmpty == true
                ? null
                : j['amnezia']['h3'] as String?,
            h4: (j['amnezia']['h4'] as String?)?.trim().isEmpty == true
                ? null
                : j['amnezia']['h4'] as String?,
            i1: j['amnezia']['i1'] as String?,
            i2: j['amnezia']['i2'] as String?,
            i3: j['amnezia']['i3'] as String?,
            i4: j['amnezia']['i4'] as String?,
            i5: j['amnezia']['i5'] as String?,
            masqId: j['amnezia']['masqId'] as String?,
            masqIp: j['amnezia']['masqIp'] as String?,
            masqIb: j['amnezia']['masqIb'] as String?,
            headerProtectionKey: j['amnezia']['hpk'] as String?,
            contentPaddingAddition:
                j['amnezia']['padding'] as String?,
            randomTrailers: j['amnezia']['randomTrailers'] as bool?,
            disableCookies: j['amnezia']['disableCookies'] as bool?,
          ),
    rawParams: ((j['rawParams'] ?? const {}) as Map).cast<String, String>(),
    rawConfig: secret((j['raw']?['secret']) as String?) ??
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
