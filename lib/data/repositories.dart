import 'dart:async';
import 'dart:convert';
import '../domain/entities/subscription.dart';
import '../domain/entities/proxy_profile.dart';
import '../routing/routing_models.dart';
import '../chain/chain_planner.dart';
import '../warp/warp_registrar.dart';
import 'app_storage.dart';
import 'secure_vault.dart';
import 'profile_codec.dart';

/// Warp account persistence: secrets into the vault, metadata into the store.
class WarpRepository {
  WarpRepository(this._store, this._vault);

  final JsonStore _store;
  final SecureVault _vault;

  WarpAccount? _account;
  WarpAccount? get account => _account;

  Future<void> load() async {
    final section = _store.section('warp');
    if (section.isEmpty) return;
    final priv = await _readSecret(section['privateKeyRef'] as String?);
    final token = await _readSecret(section['tokenRef'] as String?);
    _account = WarpAccount(
      deviceId: (section['deviceId'] ?? '') as String,
      token: token ?? '',
      privateKey: priv ?? '',
      peerPublicKey: (section['peerPublicKey'] ?? '') as String,
      endpointV4: (section['endpointV4'] ?? '') as String,
      endpointV6: section['endpointV6'] as String?,
      addressV4: section['addressV4'] as String?,
      addressV6: section['addressV6'] as String?,
      license: section['license'] as String?,
      clientId: section['clientId'] as String?,
      registeredAt: section['registeredAt'] == null
          ? null
          : DateTime.parse(section['registeredAt'] as String),
      awgJc: section['awgJc'] as int?,
      awgJmin: section['awgJmin'] as int?,
      awgJmax: section['awgJmax'] as int?,
      awgS1: section['awgS1'] as int?,
      awgS2: section['awgS2'] as int?,
      awgS3: section['awgS3'] as int?,
      awgS4: section['awgS4'] as int?,
      awgH1: section['awgH1'] as String?,
      awgH2: section['awgH2'] as String?,
      awgH3: section['awgH3'] as String?,
      awgH4: section['awgH4'] as String?,
      awgI1: section['awgI1'] as String?,
      awgI2: section['awgI2'] as String?,
      awgI3: section['awgI3'] as String?,
      awgI4: section['awgI4'] as String?,
      awgI5: section['awgI5'] as String?,
      awgHpk: section['awgHpk'] as String?,
      awgMasqId: section['awgMasqId'] as String?,
      awgMasqIp: section['awgMasqIp'] as String?,
      awgMasqIb: section['awgMasqIb'] as String?,
      awgRandomTrailers: section['awgRandomTrailers'] as bool?,
      awgDisableCookies: section['awgDisableCookies'] as bool?,
      endpointOverride: section['endpointOverride'] as String?,
    );
  }

  Future<String?> _readSecret(String? ref) async {
    if (ref == null) return null;
    if (isVaultRef(ref)) return _vault.read(vaultKeyOf(ref));
    return ref;
  }

  Future<void> save(WarpAccount a) async {
    _account = a;
    const privRef = 'warp.privateKey';
    const tokenRef = 'warp.token';
    await _vault.write(privRef, a.privateKey);
    await _vault.write(tokenRef, a.token);
    await _store.putSection('warp', {
      'deviceId': a.deviceId,
      'privateKeyRef': '$vaultPrefix$privRef',
      'tokenRef': '$vaultPrefix$tokenRef',
      'peerPublicKey': a.peerPublicKey,
      'endpointV4': a.endpointV4,
      'endpointV6': a.endpointV6,
      'addressV4': a.addressV4,
      'addressV6': a.addressV6,
      'license': a.license,
      'clientId': a.clientId,
      'registeredAt': a.registeredAt?.toIso8601String(),
      if (a.awgJc != null) 'awgJc': a.awgJc,
      if (a.awgJmin != null) 'awgJmin': a.awgJmin,
      if (a.awgJmax != null) 'awgJmax': a.awgJmax,
      if (a.awgS1 != null) 'awgS1': a.awgS1,
      if (a.awgS2 != null) 'awgS2': a.awgS2,
      if (a.awgS3 != null) 'awgS3': a.awgS3,
      if (a.awgS4 != null) 'awgS4': a.awgS4,
      if (a.awgH1 != null) 'awgH1': a.awgH1,
      if (a.awgH2 != null) 'awgH2': a.awgH2,
      if (a.awgH3 != null) 'awgH3': a.awgH3,
      if (a.awgH4 != null) 'awgH4': a.awgH4,
      if (a.awgI1 != null) 'awgI1': a.awgI1,
      if (a.awgI2 != null) 'awgI2': a.awgI2,
      if (a.awgI3 != null) 'awgI3': a.awgI3,
      if (a.awgI4 != null) 'awgI4': a.awgI4,
      if (a.awgI5 != null) 'awgI5': a.awgI5,
      if (a.awgHpk != null) 'awgHpk': a.awgHpk,
      if (a.awgMasqId != null) 'awgMasqId': a.awgMasqId,
      if (a.awgMasqIp != null) 'awgMasqIp': a.awgMasqIp,
      if (a.awgMasqIb != null) 'awgMasqIb': a.awgMasqIb,
      if (a.awgRandomTrailers != null) 'awgRandomTrailers': a.awgRandomTrailers,
      if (a.awgDisableCookies != null) 'awgDisableCookies': a.awgDisableCookies,
      if (a.endpointOverride != null) 'endpointOverride': a.endpointOverride,
    });
  }

  /// v0.4.8 §user: patches the AmneziaWG 3.x obfuscation params on the
  /// stored account (manual entry from the WARP card sheet) — secrets are
  /// never round-tripped through the UI, so the vault values are preserved.
  /// [hpk] (header-protection key) is a key-like string, so it goes through
  /// the secure vault like every other secret.
  ///
  /// v0.4.9: [replaceAwgParams] controls the AWG field semantics. The
  /// params SHEET passes `true` (its full form is the new truth — clearing
  /// a field clears it). Endpoint-only callers (scanner/manual endpoint)
  /// leave it `false`, which KEEPS the stored params — previously those
  /// calls nulled every AWG field, silently downgrading an AmneziaWG 3.1
  /// WARP account to plain WireGuard after a scan.
  Future<void> saveWithAwgParams({
    bool replaceAwgParams = false,
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
    String? hpk,
    String? masqId,
    String? masqIp,
    String? masqIb,
    bool? randomTrailers,
    bool? disableCookies,
    String? endpointOverride,
    bool clearEndpointOverride = false,
  }) async {
    final a = _account;
    if (a == null) return;
    _account = WarpAccount(
      deviceId: a.deviceId,
      token: a.token,
      privateKey: a.privateKey,
      peerPublicKey: a.peerPublicKey,
      endpointV4: a.endpointV4,
      endpointV6: a.endpointV6,
      addressV4: a.addressV4,
      addressV6: a.addressV6,
      license: a.license,
      clientId: a.clientId,
      registeredAt: a.registeredAt,
      awgJc: replaceAwgParams ? jc : a.awgJc,
      awgJmin: replaceAwgParams ? jmin : a.awgJmin,
      awgJmax: replaceAwgParams ? jmax : a.awgJmax,
      awgS1: replaceAwgParams ? s1 : a.awgS1,
      awgS2: replaceAwgParams ? s2 : a.awgS2,
      awgS3: replaceAwgParams ? s3 : a.awgS3,
      awgS4: replaceAwgParams ? s4 : a.awgS4,
      awgH1: replaceAwgParams ? h1 : a.awgH1,
      awgH2: replaceAwgParams ? h2 : a.awgH2,
      awgH3: replaceAwgParams ? h3 : a.awgH3,
      awgH4: replaceAwgParams ? h4 : a.awgH4,
      awgI1: replaceAwgParams ? i1 : a.awgI1,
      awgI2: replaceAwgParams ? i2 : a.awgI2,
      awgI3: replaceAwgParams ? i3 : a.awgI3,
      awgI4: replaceAwgParams ? i4 : a.awgI4,
      awgI5: replaceAwgParams ? i5 : a.awgI5,
      awgHpk: replaceAwgParams ? hpk : a.awgHpk,
      awgMasqId: replaceAwgParams ? masqId : a.awgMasqId,
      awgMasqIp: replaceAwgParams ? masqIp : a.awgMasqIp,
      awgMasqIb: replaceAwgParams ? masqIb : a.awgMasqIb,
      awgRandomTrailers:
          replaceAwgParams ? randomTrailers : a.awgRandomTrailers,
      awgDisableCookies:
          replaceAwgParams ? disableCookies : a.awgDisableCookies,
      endpointOverride:
          clearEndpointOverride ? null : (endpointOverride ?? a.endpointOverride),
    );
    await save(_account!);
  }

  Future<void> clear() async {
    _account = null;
    await _store.putSection('warp', {});
  }
}

/// Typed JSON settings section.
class SettingsRepository {
  SettingsRepository(this._store);

  final JsonStore _store;

  Map<String, dynamic> get _data => _store.section('settings');

  T get<T>(String key, T fallback) {
    final v = _data[key];
    if (v is T) return v;
    return fallback;
  }

  Future<void> set(String key, Object? value) async {
    final section = {..._data};
    section[key] = value;
    await _store.putSection('settings', section);
  }

  String exportJson() => const JsonEncoder.withIndent('  ').convert(_data);
}

/// Generic JSON-section list repository helper.
class _ListSection<T> {
  _ListSection(this.store, this.key, this.decode, this.encode, this.idOf);

  final JsonStore store;
  final String key;
  final T Function(Map<String, dynamic>) decode;
  final Map<String, dynamic> Function(T) encode;
  final String Function(T) idOf;

  final _items = <T>[];
  final _controller = StreamController<List<T>>.broadcast();

  List<T> get items => List.unmodifiable(_items);
  Stream<List<T>> get changes => _controller.stream;

  Future<void> load() async {
    final raw = store.section(key);
    _items
      ..clear()
      ..addAll(raw.values
          .map((v) => decode((v as Map).cast<String, dynamic>())));
    _controller.add(items);
  }

  // v0.4 BUGFIX (Android device run, fresh install): upsert/remove used to
  // mutate the UNMODIFIABLE view returned by `items` â€” every list-repo
  // mutation threw `Cannot add to an unmodifiable list`. Mutate the backing
  // `_items` and expose typed operations to the repositories instead.
  Future<void> upsert(T item) async {
    final id = idOf(item);
    final idx = _items.indexWhere((x) => idOf(x) == id);
    if (idx >= 0) {
      _items[idx] = item;
    } else {
      _items.add(item);
    }
    await save();
  }

  Future<void> removeById(String id) async {
    _items.removeWhere((x) => idOf(x) == id);
    await save();
  }

  Future<void> save() async {
    final section = <String, dynamic>{
      for (final i in _items) idOf(i): encode(i),
    };
    await store.putSection(key, section);
    _controller.add(items);
  }
}

class SubscriptionRepository {
  SubscriptionRepository(JsonStore store)
      : _section = _ListSection(
          store,
          'subscriptions',
          Subscription.fromJson,
          _subToJson,
          (s) => s.id,
        );

  final _ListSection<Subscription> _section;

  List<Subscription> get all => _section.items;
  Stream<List<Subscription>> get changes => _section.changes;

  Future<void> load() => _section.load();

  Future<void> upsert(Subscription s) => _section.upsert(s);

  Future<void> remove(String id) => _section.removeById(id);

  static Map<String, dynamic> _subToJson(Subscription s) => {
        'id': s.id,
        'name': s.name,
        'url': s.url,
        'info': {
          'upload': s.info.uploadBytes,
          'download': s.info.downloadBytes,
          'total': s.info.totalBytes,
          'expire': s.info.expireAt?.millisecondsSinceEpoch,
          'title': s.info.title,
        },
        'lastUpdated': s.lastUpdated?.toIso8601String(),
        'nodeCount': s.nodeCount,
        'healthyCount': s.healthyCount,
        'autoUpdate': s.autoUpdate,
        'updateIntervalMinutes': s.updateIntervalMinutes,
        'lastError': s.lastError,
        'etag': s.etag,
      };
}

class ChainRepository {
  ChainRepository(JsonStore store)
      : _section = _ListSection(
          store,
          'chains',
          ProxyChain.fromJson,
          (c) => c.toJson(),
          (c) => c.id,
        );

  final _ListSection<ProxyChain> _section;

  List<ProxyChain> get all => _section.items;
  Stream<List<ProxyChain>> get changes => _section.changes;

  Future<void> load() => _section.load();

  Future<void> upsert(ProxyChain c) => _section.upsert(c);

  Future<void> remove(String id) => _section.removeById(id);
}

class RoutingRepository {
  RoutingRepository(JsonStore store)
      : _section = _ListSection(
          store,
          'routing',
          RoutingProfile.fromJson,
          (p) => p.toJson(),
          (p) => p.id,
        );

  final _ListSection<RoutingProfile> _section;

  List<RoutingProfile> get all => _section.items;
  Stream<List<RoutingProfile>> get changes => _section.changes;

  Future<void> load() => _section.load();

  Future<void> upsert(RoutingProfile p) => _section.upsert(p);

  Future<void> remove(String id) => _section.removeById(id);
}


