import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:zflow/state/crash_report.dart';

void main() {
  test('record → read round-trip, clear removes', () async {
    final dir = await Directory.systemTemp.createTemp('zemote_crash');
    addTearDown(() => dir.delete(recursive: true));
    final store = CrashStore(File('${dir.path}/last_crash.json'));

    expect(await store.read(), isNull);

    await store.record(
        'uncaught', StateError('boom'), StackTrace.fromString('#0 main'));

    final info = await store.read();
    expect(info, isNotNull);
    expect(info!.kind, 'uncaught');
    expect(info.error, contains('boom'));
    expect(info.stack, contains('#0 main'));
    expect(info.appVersion, isNotEmpty);

    await store.clear();
    expect(await store.read(), isNull);
  });

  test('oversized error/stack are truncated, not dropped', () async {
    final dir = await Directory.systemTemp.createTemp('zemote_crash');
    addTearDown(() => dir.delete(recursive: true));
    final store = CrashStore(File('${dir.path}/last_crash.json'));

    final huge = 'x' * (64 * 1024);
    await store.record('framework', Exception(huge), StackTrace.fromString(huge));

    final info = await store.read();
    expect(info, isNotNull);
    expect(info!.error.length, lessThan(64 * 1024));
    expect(info.error.endsWith('…(截断)'), isTrue);
    expect(info.stack!.length, lessThan(64 * 1024));
  });

  test('read tolerates a corrupted file', () async {
    final dir = await Directory.systemTemp.createTemp('zemote_crash');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/last_crash.json');
    file.writeAsStringSync('not json{');
    final store = CrashStore(file);
    expect(await store.read(), isNull);
  });
}
