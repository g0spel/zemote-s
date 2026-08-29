import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Persistence seam for the account store. Production uses
/// [SecureCredentialStorage] (Android Keystore / OS keychain); tests inject
/// an in-memory fake.
abstract class CredentialStorage {
  Future<String?> read();
  Future<void> write(String value);
}

/// Stores device credentials (connection URLs contain `sid`/`hash`, i.e.
/// full access to the paired desktop) encrypted at rest via
/// flutter_secure_storage. The app also sets `android:allowBackup="false"`
/// so this data never leaves the device through cloud backups.
class SecureCredentialStorage implements CredentialStorage {
  const SecureCredentialStorage();

  static const _storage = FlutterSecureStorage();
  static const _key = 'zflow_accounts_v1';

  @override
  Future<String?> read() => _storage.read(key: _key);

  @override
  Future<void> write(String value) => _storage.write(key: _key, value: value);
}
