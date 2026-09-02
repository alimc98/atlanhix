import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../data/secure_vault.dart';

/// Creates the best available OS-backed vault; falls back to memory when the
/// platform plugin is unavailable (surfaced in Settings as a warning).
SecureVault createPlatformVault() {
  return FlutterSecureVault(const FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  ));
}

class FlutterSecureVault implements SecureVault {
  FlutterSecureVault(this._s);

  final FlutterSecureStorage _s;

  @override
  Future<bool> containsKey(String key) => _s.containsKey(key: key);

  @override
  Future<void> delete(String key) => _s.delete(key: key);

  @override
  Future<String?> read(String key) => _s.read(key: key);

  @override
  Future<void> write(String key, String value) => _s.write(key: key, value: value);
}
