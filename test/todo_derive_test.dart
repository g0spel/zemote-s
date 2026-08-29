import 'package:flutter_test/flutter_test.dart';

import 'package:zflow/ui/chat_page.dart';

void main() {
  group('deriveTodoSteps (desktop-host logic mirror)', () {
    test('extracts todos from the latest TodoWrite input', () {
      final rows = [
        {
          'kind': 'toolCall',
          'toolName': 'TodoWrite',
          'input': {
            'todos': [
              {'content': '调研协议', 'status': 'completed'},
              {'content': '写解析器', 'status': 'in_progress'},
              {'content': '补测试', 'status': 'pending'},
            ],
          },
        },
      ];
      final steps = deriveTodoSteps(rows)!;
      expect(steps, hasLength(3));
      expect(steps[0].completed, isTrue);
      expect(steps[1].inProgress, isTrue);
      expect(steps[2].completed, isFalse);
      expect(steps[2].inProgress, isFalse);
    });

    test('latest matching row wins', () {
      final rows = [
        {
          'kind': 'toolCall',
          'toolName': 'todo_write',
          'input': {
            'todos': [
              {'content': '旧', 'status': 'completed'},
            ],
          },
        },
        {
          'kind': 'toolCall',
          'toolName': 'TodoWrite',
          'input': {
            'todos': [
              {'content': '新', 'status': 'in_progress'},
            ],
          },
        },
      ];
      final steps = deriveTodoSteps(rows)!;
      expect(steps, hasLength(1));
      expect(steps.first.title, '新');
    });

    test('accepts JSON-string payloads and output.text', () {
      final rows = [
        {
          'kind': 'toolCall',
          'toolName': 'update_plan',
          'output': {
            'text':
                '{"plan": ["step a", "step b", {"content": "step c", "status": "pending"}]}',
          },
        },
      ];
      final steps = deriveTodoSteps(rows)!;
      expect(steps, hasLength(3));
      // Bare strings: first is in_progress, the rest pending.
      expect(steps[0].inProgress, isTrue);
      expect(steps[1].completed, isFalse);
      expect(steps[2].title, 'step c');
    });

    test('normalizes status variants', () {
      final rows = [
        {
          'kind': 'toolCall',
          'toolName': 'TodoWrite',
          'input': {
            'todos': [
              {'content': 'a', 'status': 'in-progress'},
              {'content': 'b', 'status': 'COMPLETED'},
            ],
          },
        },
      ];
      final steps = deriveTodoSteps(rows)!;
      expect(steps[0].inProgress, isTrue);
      expect(steps[1].completed, isTrue);
    });

    test('all-or-nothing: a malformed item discards the row', () {
      final rows = [
        {
          'kind': 'toolCall',
          'toolName': 'TodoWrite',
          'input': {
            'todos': [
              {'content': 'a', 'status': 'pending'},
              {'content': 42, 'status': 'pending'}, // not a string title
            ],
          },
        },
      ];
      expect(deriveTodoSteps(rows), isNull);
    });

    test('non-matching tools are ignored', () {
      final rows = [
        {
          'kind': 'toolCall',
          'toolName': 'bash',
          'input': {
            'todos': [
              {'content': 'x', 'status': 'pending'},
            ],
          },
        },
      ];
      expect(deriveTodoSteps(rows), isNull);
    });
  });
}
