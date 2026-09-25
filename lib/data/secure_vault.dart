import 'dart:async';

/// Storage for secret material (passwords, private keys, tokens).
/// Production implementations use OS secure storage; tests use memory.
abstract class SecureVault {
  Future<void> write(String key, String value);
  Future<String?> read(String key);
  Future<void> delete(String key);
  Future<bool> containsKey(String key);

  /// v0.4.9 §boot: batch read for the profile-load prefetch. Default is the
  /// parallel fan-out over [read] (correct for every backend, though each
  /// entry is still one IPC on the platform vault); the Flutter
  /// implementation overrides it with flutter_secure_storage's native
  /// readAll — ONE channel call instead of N.
  Future<Map<String, String?>> readAll(Iterable<String> keys) async {
    final reads = await Future.wait(keys.map((k) => read(k)));
    final out = <String, String?>{};
    var i = 0;
    for (final k in keys) {
      out[k] = reads[i++];
    }
    return out;
  }
}

/// OS-backed vault via flutter_secure_storage (Keystore / DPAPI / libsecret).
class PlatformSecureVault implements SecureVault {
  PlatformSecureVault(this._storage);

  /// flutter_secure_storage instance is injected to keep this class
  /// constructible in non-plugin environments (falls back to memory).
  final SecureVault _storage;

  @override
  Future<bool> containsKey(String key) => _storage.containsKey(key);

  @override
  Future<void> delete(String key) => _storage.delete(key);

  @override
  Future<String?> read(String key) => _storage.read(key);

  @override
  Future<void> write(String key, String value) => _storage.write(key, value);

  @override
  Future<Map<String, String?>> readAll(Iterable<String> keys) =>
      _storage.readAll(keys);
}

/// In-memory vault for tests / graceful fallback (surfaced in Settings).
class InMemoryVault implements SecureVault {
  final Map<String, String> _m = {};

  @override
  Future<bool> containsKey(String key) async => _m.containsKey(key);

  @override
  Future<void> delete(String key) async {
    _m.remove(key);
  }

  @override
  Future<String?> read(String key) async => _m[key];

  @override
  Future<void> write(String key, String value) async {
    _m[key] = value;
  }

  @override
  Future<Map<String, String?>> readAll(Iterable<String> keys) async =>
      {for (final k in keys) k: _m[k]};
}
