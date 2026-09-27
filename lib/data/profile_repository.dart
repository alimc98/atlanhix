import 'dart:async';
import '../domain/entities/proxy_profile.dart';
import 'profile_codec.dart';
import 'profile_codec_write.dart';
import 'app_storage.dart';
import 'secure_vault.dart';

/// CRUD facade over the JSON store for profiles.
class ProfileRepository {
  ProfileRepository(this._store, this._vault);

  final JsonStore _store;
  final SecureVault _vault;

  final _profiles = <ProxyProfile>[];
  final _controller = StreamController<List<ProxyProfile>>.broadcast();
  bool _loaded = false;

  List<ProxyProfile> get all => List.unmodifiable(_profiles);
  Stream<List<ProxyProfile>> get changes => _controller.stream;

  ProxyProfile? byId(String id) {
    for (final p in _profiles) {
      if (p.id == id) return p;
    }
    return null;
  }

  /// v0.5.0 §boot: the fast phase — decode from the JSON store only, no
  /// vault touch (Keystore's one-time ~2.5 s init stays off the boot path).
  /// [resolveSecrets] is the deferred second phase; before it runs the
  /// profiles carry `@vault:` tokens in place of secrets, which nothing on
  /// screen renders.
  Future<void> load() async {
    if (_loaded) return;
    _profiles
      ..clear()
      ..addAll(await loadProfiles(_store));
    _loaded = true;
    _controller.add(all);
  }

  /// v0.5.0 §boot: resolve every `@vault:` token on the loaded profiles
  /// (batch vault read). Call AFTER the first paint. Idempotent — resolved
  /// plaintext values are not vault refs and stay untouched.
  Future<void> resolveSecrets() async {
    await resolveProfileSecrets(_profiles, _vault);
  }

  Future<void> upsertMany(Iterable<ProxyProfile> profiles) async {
    for (final p in profiles) {
      final idx = _profiles.indexWhere((x) => x.id == p.id);
      if (idx >= 0) {
        _profiles[idx] = p;
      } else {
        _profiles.add(p);
      }
    }
    await _persist();
  }

  Future<void> update(ProxyProfile p) => upsertMany([p]);

  Future<void> remove(String id) async {
    _profiles.removeWhere((p) => p.id == id);
    await _persist();
  }

  /// Subscription refresh: replaces only this subscription's nodes, preserving
  /// manual profiles (§9 update semantics).
  Future<void> replaceSubscriptionProfiles(
      String subscriptionId, List<ProxyProfile> fresh) async {
    _profiles.removeWhere((p) => p.subscriptionId == subscriptionId);
    _profiles.addAll(fresh);
    await _persist();
  }

  Future<void> _persist() async {
    final salt = Ids.randomHex(4);
    final section = <String, dynamic>{};
    for (final p in _profiles) {
      section[p.id] = profileToStorable(p, _vault, salt);
    }
    await _store.putSection(StoreKeys.profiles, section);
    _controller.add(all);
  }
}
