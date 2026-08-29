import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:zemote/state/session_list_cache.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('workspace cache keys are isolated and do not expose paths', () {
    const cache = SessionListCache();
    final a = cache.keyFor(const {'workspacePath': '/secret/a'});
    final b = cache.keyFor(const {'workspacePath': '/secret/b'});

    expect(a, isNot(b));
    expect(a, isNot(contains('secret')));
    expect(a, startsWith('zemote_session_list_v1_'));
  });

  test('cache roundtrip keeps session list fields', () async {
    const cache = SessionListCache();
    const workspace = {
      'workspacePath': '/work',
      'workspaceIdentity': 'work-id',
    };
    await cache.write(workspace, const [
      {
        'sessionId': 's1',
        'title': 'Cached session',
        'phase': 'idle',
        'lastAssistantPreview': 'preview',
        'lastActivityAt': 20,
        'createdAt': 1,
      },
    ]);

    final restored = await cache.read(workspace);
    expect(restored, hasLength(1));
    expect(restored.single['sessionId'], 's1');
    expect(restored.single['title'], 'Cached session');
    expect(restored.single['lastActivityAt'], 20);
  });

  test('empty list never overwrites the cached list', () async {
    const cache = SessionListCache();
    const workspace = {'workspacePath': '/work'};
    await cache.write(workspace, const [
      {'sessionId': 's1', 'title': 'Cached session'},
    ]);
    await cache.write(workspace, const []);

    final restored = await cache.read(workspace);
    expect(restored, hasLength(1));
  });
}
