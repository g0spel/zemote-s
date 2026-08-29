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
    // 相对 now 构造,避免依赖固定日期(today/older 分界用 DateTime.now)。
    final now = DateTime.now();
    final todayMs = now.millisecondsSinceEpoch;
    final oldMs =
        now.subtract(const Duration(days: 2)).millisecondsSinceEpoch;

    test('置顶组最前且保持 sorted 顺序,其余按 今天/更早 两档', () {
      // sorted 输入按最近活动降序;pinned 命中项原序进入置顶组。
      final groups = groupSessions([
        _e('pin-today', 'idle', todayMs),
        _e('today', 'idle', todayMs - 1),
        _e('old', 'idle', oldMs),
        _e('pin-old', 'idle', oldMs - 1),
      ], {'pin-old', 'pin-today'});
      expect(groups.keys, ['pinned', 'today', 'older']);
      expect(groups['pinned']!.map((e) => e.sessionId),
          ['pin-today', 'pin-old']);
      expect(groups['today']!.map((e) => e.sessionId), ['today']);
      expect(groups['older']!.map((e) => e.sessionId), ['old']);
    });
    test('空置顶集退化为 今天/更早 两档,键序即展示序', () {
      final groups = groupSessions(
          [_e('today', 'idle', todayMs), _e('old', 'idle', oldMs)], {});
      expect(groups.keys, ['today', 'older']);
      expect(groups['today']!.map((e) => e.sessionId), ['today']);
      expect(groups['older']!.map((e) => e.sessionId), ['old']);
    });
    test('空列表返回空分组;lastActivityAt=0 落入更早', () {
      expect(groupSessions([], {}), isEmpty);
      expect(groupSessions([_e('zero', 'idle', 0)], {}).keys, ['older']);
    });
  });
}
