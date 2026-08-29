import 'package:flutter_test/flutter_test.dart';
import 'package:zemote/protocol/conversation.dart';
import 'package:zemote/ui/session_drawer.dart';
import 'package:zemote/ui/theme.dart';

SessionEntry _e(String id, String phase, int at, {String? title}) =>
    SessionEntry({
      'sessionId': id, 'title': title ?? 'T-$id', 'phase': phase,
      'lastActivityAt': at, 'createdAt': 0,
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
    test('按 今天/更早 两档分组,键序即展示序', () {
      // now = 2026-08-28 12:00;今天 08:00 / 昨天 23:00 → 更早。
      final now = DateTime(2026, 8, 28, 12);
      final groups = groupSessions([
        _e('old', 'idle', DateTime(2026, 8, 27, 23).millisecondsSinceEpoch),
        _e('today', 'idle', DateTime(2026, 8, 28, 8).millisecondsSinceEpoch),
      ], now: now);
      expect(groups.keys, ['今天', '更早']);
      expect(groups['今天']!.map((e) => e.sessionId), ['today']);
      expect(groups['更早']!.map((e) => e.sessionId), ['old']);
    });
    test('空列表返回空分组;lastActivityAt=0 落入更早', () {
      final now = DateTime(2026, 8, 28, 12);
      expect(groupSessions([], now: now), isEmpty);
      final groups = groupSessions([_e('zero', 'idle', 0)], now: now);
      expect(groups.keys, ['更早']);
    });
  });
}
