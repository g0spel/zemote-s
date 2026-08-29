import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:zflow/state/account_store.dart';

import 'fake_credential_storage.dart';

void main() {
  test('exportJson round-trips through importJson', () async {
    final store = AccountStore(storage: FakeCredentialStorage());
    final url =
        'https://zcode.z.ai/remote/v4?sid=abc&hash=def&t=123&name=桌面1';
    await store.addUrl(url);
    final exported = store.exportJson();
    final parsed = jsonDecode(exported) as Map<String, dynamic>;
    expect(parsed['accounts'], isA<List>());
    expect((parsed['accounts'] as List), hasLength(1));

    final store2 = AccountStore(storage: FakeCredentialStorage());
    final count = await store2.importJson(exported);
    expect(count, 1);
    expect(store2.accounts, hasLength(1));
    expect(store2.accounts.first.url, url);
  });

  test('importJson skips invalid URLs and duplicates', () async {
    final store = AccountStore(storage: FakeCredentialStorage());
    await store.addUrl(
        'https://zcode.z.ai/remote/v4?sid=abc&hash=def&t=123&name=桌面1');
    final count = await store.importJson(jsonEncode({
      'app': 'zflow',
      'accounts': [
        {'id': 'x1', 'label': 'dup', 'url': 'https://zcode.z.ai/remote/v4?sid=abc&hash=def&t=123&name=桌面1'},
        {'id': 'x2', 'label': 'bad', 'url': 'not a url'},
        {'id': 'x3', 'label': 'new', 'url': 'https://zcode.z.ai/remote/v4?sid=zzz&hash=hhh&t=999&name=桌面2'},
      ],
    }));
    expect(count, 1);
    expect(store.accounts, hasLength(2));
  });

  test('importJson rejects non-device files', () async {
    final store = AccountStore(storage: FakeCredentialStorage());
    await expectLater(
      store.importJson('{"foo": 1}'),
      throwsFormatException,
    );
  });

  test('accounts persist through storage', () async {
    final storage = FakeCredentialStorage();
    final store = AccountStore(storage: storage);
    await store.addUrl('https://zcode.z.ai/remote/v4?sid=a&hash=b&t=1');
    expect(storage.value, isNotNull);

    final reloaded = AccountStore(storage: storage);
    await reloaded.load();
    expect(reloaded.accounts, hasLength(1));
    expect(reloaded.loaded, isTrue);
  });
}
