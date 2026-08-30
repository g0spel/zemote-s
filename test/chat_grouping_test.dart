import 'package:flutter_test/flutter_test.dart';

import 'package:zflow/protocol/conversation.dart';
import 'package:zflow/ui/chat_page.dart';

void main() {
  group('assistantTurnParts', () {
    test('preserves original order: reasoning → text → tool → text', () {
      final parts = assistantTurnParts([
        {'kind': 'reasoning', 'text': '思考…'},
        {
          'kind': 'assistantText',
          'text': 'Let me check.',
          'rowId': 1,
          'entityId': 'e1',
          'feedback': 'like',
        },
        {'kind': 'toolCall', 'toolName': 'bash'},
        {'kind': 'assistantText', 'text': 'Done.', 'rowId': 2},
        {'kind': 'assistantText', 'text': ' Final words.', 'rowId': 3},
        {'kind': 'subagent', 'text': '…'},
        {'kind': 'turnHeader', 'status': 'completed'},
      ]);
      // Ordered parts: reasoning(tile) → text → tool(tile) → merged text → subagent(tile)
      expect(parts.parts.map((p) => p.kind),
          ['row', 'text', 'row', 'text', 'row']);
      expect(parts.parts[0].row?['kind'], 'reasoning');
      expect(parts.parts[1].text, 'Let me check.');
      expect(parts.parts[2].row?['kind'], 'toolCall');
      expect(parts.parts[3].text, 'Done.\n\n Final words.');
      expect(parts.parts[4].row?['kind'], 'subagent');
      expect(parts.header?['status'], 'completed');
      expect(parts.streaming, isFalse);
    });

    test('streaming flag propagates', () {
      final parts = assistantTurnParts([
        {'kind': 'assistantText', 'text': '正在输出…', 'state': 'streaming'},
      ]);
      expect(parts.parts, hasLength(1));
      expect(parts.parts[0].kind, 'text');
      expect(parts.parts[0].text, '正在输出…');
      expect(parts.parts[0].streaming, isTrue);
      expect(parts.streaming, isTrue);
    });

    test('empty text rows are dropped', () {
      final parts = assistantTurnParts([
        {'kind': 'assistantText', 'text': '   '},
        {'kind': 'assistantText', 'text': 'real answer'},
      ]);
      expect(parts.parts, hasLength(1));
      expect(parts.parts[0].text, 'real answer');
    });

    test('no assistant text keeps tiles only', () {
      final parts = assistantTurnParts([
        {'kind': 'toolCall', 'toolName': 'bash'},
      ]);
      expect(parts.parts, hasLength(1));
      expect(parts.parts[0].kind, 'row');
    });
  });

  group('cached groupRows', () {
    tearDown(clearGroupRowsCache);

    test('reuses same state/version and ignores control-only updates', () {
      final state = ConversationState()
        ..rows = [
          {'rowId': 1, 'kind': 'userInput', 'text': 'hello'},
          {'rowId': 2, 'kind': 'assistantText', 'text': 'answer'},
        ];
      final first = cachedGroupRows(state);
      state.snapshot = {'control': {'phase': 'running'}};
      final second = cachedGroupRows(state);
      expect(identical(first, second), isTrue);
      expect(first, hasLength(2));
    });

    test('rows mutation invalidates cache and preserves timeline boundaries', () {
      final state = ConversationState()
        ..rows = [
          {'rowId': 1, 'kind': 'userInput'},
          {'rowId': 2, 'kind': 'assistantText', 'text': 'a'},
        ];
      final first = cachedGroupRows(state);
      state.applyFrame({
        'payload': {
          'kind': 'deltas',
          'deltas': [
            {'op': 'row.appended', 'row': {'rowId': 3, 'kind': 'timelineMarker'}},
            {'op': 'row.appended', 'row': {'rowId': 4, 'kind': 'assistantText', 'text': 'b'}},
          ],
        },
        'fromSeq': state.seq,
        'toSeq': state.seq + 1,
      }, onGap: () => fail('should not gap'));
      final second = cachedGroupRows(state);
      expect(identical(first, second), isFalse);
      expect(second.map((group) => group.map((row) => row['rowId'])), [
        [1],
        [2],
        [3],
        [4],
      ]);
    });

    test('different state objects do not share groups', () {
      final firstState = ConversationState()
        ..rows = [{'rowId': 1, 'kind': 'assistantText', 'text': 'one'}];
      final secondState = ConversationState()
        ..rows = [{'rowId': 1, 'kind': 'assistantText', 'text': 'two'}];
      final first = cachedGroupRows(firstState);
      final second = cachedGroupRows(secondState);
      expect(identical(first, second), isFalse);
      expect(second.single.single['text'], 'two');
    });
  });

  group('formatTokenCount', () {
    test('小值原样,≥1 万换算成 x.x 万', () {
      expect(formatTokenCount(0), '0');
      expect(formatTokenCount(999), '999');
      expect(formatTokenCount(10000), '1.0 万');
      expect(formatTokenCount(553000), '55.3 万');
      expect(formatTokenCount(6800000), '680.0 万');
    });
  });
}
