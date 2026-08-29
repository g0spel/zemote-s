import 'package:zflow/state/credential_storage.dart';

/// In-memory [CredentialStorage] for tests.
class FakeCredentialStorage implements CredentialStorage {
  String? value;

  @override
  Future<String?> read() async => value;

  @override
  Future<void> write(String v) async => value = v;
}
