import 'package:flutter_test/flutter_test.dart';
import 'package:zflow/protocol/conversation.dart';
import 'package:zflow/ui/session_drawer.dart';
import 'package:zflow/ui/theme.dart';

SessionEntry _e(String id, String phase, int at,
        {String? title, bool archived = false}) =>
    SessionEntry({
      'sessionId': id, 'title': title ?? 'T-$id', 'phase': phase,
      'lastActivityAt': at, 'createdAt': 0,
      if (archived) 'archived': 1,
    });

void main() {
  group('sortSessions', () {
    test('descending by lastActivityAt', () {
      final r = sortSessions([_e('a', 'idle', 1), _e('b', 'running', 9), _e('c', 'idle', 5)]);
      expect(r.map((e) => e.sessionId).toList(), ['b', 'c', 'a']);
    });
  });
  group('statusDotColor', () {
    test('running→run blue, waiting→warn, else null', () {
      expect(statusDotColor('running'), EmberColors.dark().run);
      expect(statusDotColor('prewarming'), EmberColors.dark().run);
      expect(statusDotColor('waiting'), EmberColors.dark().warn);
      expect(statusDotColor('completedSuccess'), isNull);
    });
  });
  group('filterSessions', () {
    test('空串返回原列表', () {
      final list = [_e('a', 'idle', 1), _e('b', 'idle', 2)];
      expect(filterSessions(list, ''), same(list));
      expect(filterSessions(list, '   '), same(list));
    });
    test('标题 contains 匹配(大小写不敏感)', () {
      final list = [
        _e('a', 'idle', 1, title: '修复登录'),
        _e('b', 'idle', 2, title: 'Refactor API'),
        _e('c', 'idle', 3, title: '无关会话'),
      ];
      expect(filterSessions(list, '登录').map((e) => e.sessionId), ['a']);
      expect(filterSessions(list, 'refactor').map((e) => e.sessionId), ['b']);
      expect(filterSessions(list, 'AP').map((e) => e.sessionId), ['b']);
      expect(filterSessions(list, '不存在'), isEmpty);
    });
  });
  group('groupSessions', () {
    test('两档:置顶在活跃组内最前,归档单独成组', () {
      final groups = groupSessions([
        _e('pin', 'idle', 300),
        _e('a', 'idle', 200),
        _e('arch', 'idle', 100, archived: true),
        _e('b', 'idle', 50),
      ], {'pin'});
      expect(groups.keys, ['active', 'archived']);
      expect(groups['active']!.map((e) => e.sessionId), ['pin', 'a', 'b']);
      expect(groups['archived']!.map((e) => e.sessionId), ['arch']);
    });
    test('空列表返回空分组', () {
      expect(groupSessions([], {}), isEmpty);
    });
  });
}
