import 'package:flutter_test/flutter_test.dart';

import 'package:zflow/state/log_store.dart';

void main() {
  test('long lines are truncated with a marker', () {
    final store = LogStore();
    addTearDown(store.dispose);
    store.add('x' * 5000);
    final line = store.entries.single.message;
    expect(line.length, lessThan(2000));
    expect(line, contains('字符已截断'));
  });

  test('rapid adds coalesce into one notification per flush window',
      () async {
    final store = LogStore();
    addTearDown(store.dispose);
    var notified = 0;
    store.addListener(() => notified++);

    for (var i = 0; i < 200; i++) {
      store.add('line $i');
    }
    // Entries are stored immediately; listeners fire on the flush timer.
    expect(store.entries, hasLength(200));
    expect(notified, 0);

    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(notified, 1);
  });

  test('clear notifies immediately', () async {
    final store = LogStore();
    addTearDown(store.dispose);
    var notified = 0;
    store.addListener(() => notified++);
    store.add('a');
    store.clear();
    expect(notified, 1);
    expect(store.entries, isEmpty);
  });
}
