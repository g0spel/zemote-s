import 'package:flutter_test/flutter_test.dart';
import 'package:zemote/protocol/conversation.dart';
import 'package:zemote/ui/conversation_list_page.dart';
import 'package:zemote/ui/theme.dart';

SessionEntry _e(String id, String phase, int at) => SessionEntry({
      'sessionId': id, 'title': 'T-$id', 'phase': phase,
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
}
