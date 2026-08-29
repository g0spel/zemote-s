import 'package:flutter_test/flutter_test.dart';

import 'package:zflow/ui/chat_page.dart';

void main() {
  group('endedSubagentRows', () {
    test('keeps terminal rows (success/failed/cancelled) in order', () {
      final rows = [
        {'kind': 'turnHeader', 'rowId': 1},
        {
          'kind': 'subagent',
          'rowId': 2,
          'subagentType': 'Explore',
          'status': 'success',
          'summaryText': '定位到协议定义',
        },
        {'kind': 'assistantText', 'rowId': 3, 'text': '继续'},
        {
          'kind': 'subagent',
          'rowId': 4,
          'subagentType': 'general-purpose',
          'status': 'failed',
          'summaryText': '搜索超时',
        },
        {
          'kind': 'subagent',
          'rowId': 5,
          'subagentType': 'Explore',
          'status': 'cancelled',
          'summaryText': '被用户中断',
        },
      ];
      final ended = endedSubagentRows(rows);
      expect(ended.map((r) => r['rowId']), [2, 4, 5]);
      expect(ended.map((r) => r['status']), ['success', 'failed', 'cancelled']);
    });

    test('drops running subagent rows and non-subagent kinds', () {
      final rows = [
        {
          'kind': 'subagent',
          'rowId': 1,
          'subagentType': 'Explore',
          'status': 'running',
          'summaryText': 'still working',
        },
        {'kind': 'toolCall', 'rowId': 2, 'toolName': 'bash', 'status': 'success'},
        {'kind': 'subagent', 'rowId': 3, 'status': null},
      ];
      expect(endedSubagentRows(rows), isEmpty);
    });

    test('empty conversation is safe', () {
      expect(endedSubagentRows(const []), isEmpty);
    });
  });
}
