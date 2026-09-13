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
    });
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


