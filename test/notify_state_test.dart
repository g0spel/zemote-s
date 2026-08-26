import 'package:flutter_test/flutter_test.dart';

import 'package:zemote/notifications/notify_state.dart';
import 'package:zemote/protocol/conversation.dart';

SessionEntry _entry(String id, String phase,
    {String title = 'Task', String? preview, Map<String, dynamic>? pending}) {
  return SessionEntry({
    'sessionId': id,
    'title': title,
    'phase': phase,
    'lastAssistantPreview': preview,
    'lastActivityAt': 0,
    'createdAt': 0,
    if (pending != null) 'pendingInteraction': pending,
  });
}

void main() {
  test('running tasks are collected', () {
    final update = computeNotifyUpdate(
      sessions: [
        _entry('a', 'running', preview: 'streaming text'),
        _entry('b', 'prewarming'),
        _entry('c', 'completed'),
      ],
      previousPhases: const {},
    );
    expect(update.running, hasLength(2));
    expect(update.completed, isEmpty);
    expect(update.running[0].preview, 'streaming text');
    expect(update.hasRunning, isTrue);
  });

  test('running -> completed fires exactly once', () {
    final sessions = [
      _entry('a', 'running'),
      _entry('b', 'completed', title: 'Done', preview: 'result'),
    ];
    final first = computeNotifyUpdate(
      sessions: sessions,
      previousPhases: const {'a': 'running', 'b': 'running'},
    );
    expect(first.completed, hasLength(1));
    expect(first.completed[0].taskId, 'b');
    expect(first.completed[0].title, 'Done');

    // Next tick with same terminal phases must NOT re-fire.
    final second = computeNotifyUpdate(
      sessions: sessions,
      previousPhases: const {'a': 'running', 'b': 'completed'},
    );
    expect(second.completed, isEmpty);
  });

  test('re-run completing again fires again', () {
    final run = computeNotifyUpdate(
      sessions: [_entry('a', 'running')],
      previousPhases: const {'a': 'completed'},
    );
    expect(run.completed, isEmpty);
    final done = computeNotifyUpdate(
      sessions: [_entry('a', 'completed')],
      previousPhases: const {'a': 'running'},
    );
    expect(done.completed, hasLength(1));
  });

  test('task missing from snapshot does not fire completion', () {
    final update = computeNotifyUpdate(
      sessions: const [],
      previousPhases: const {'a': 'running'},
    );
    expect(update.completed, isEmpty);
  });

  test('no running tasks -> hasRunning false', () {
    final update = computeNotifyUpdate(
      sessions: [_entry('a', 'completed')],
      previousPhases: const {},
    );
    expect(update.hasRunning, isFalse);
  });

  test('formatRunningText renders title + preview', () {
    final text = formatRunningText(const [
      RunningTask(taskId: 'a', title: '重构协议层', preview: '正在应用 diff'),
      RunningTask(taskId: 'b', title: '写测试', preview: ''),
    ]);
    expect(text, contains('重构协议层'));
    expect(text, contains('正在应用 diff'));
    expect(text, contains('• 写测试'));
  });

  test('completion events carry phase and activity marker', () {
    final update = computeNotifyUpdate(
      sessions: [
        _entry('a', 'failed', preview: 'boom'),
        _entry('b', 'completedSuccess', preview: 'ok'),
      ],
      previousPhases: const {'a': 'running', 'b': 'running'},
    );
    final phases = {for (final c in update.completed) c.taskId: c.phase};
    expect(phases['a'], 'failed');
    expect(phases['b'], 'completedSuccess');
  });

  test('completionTitleFor differentiates failures', () {
    expect(completionTitleFor('completedSuccess'), '任务完成');
    expect(completionTitleFor('completed'), '任务完成');
    expect(completionTitleFor('failed'), '任务失败');
    expect(completionTitleFor('error'), '任务失败');
    expect(completionTitleFor('completedInterrupted'), '任务中断');
    expect(completionTitleFor('cancelled'), '任务中断');
  });

  test('pending interactions surface as a snapshot with kind and tool',
      () {
    final update = computeNotifyUpdate(
      sessions: [
        _entry('a', 'waiting', pending: {
          'interactionId': 'i-1',
          'kind': 'permission',
          'toolName': 'bash',
        }),
        _entry('b', 'waiting', pending: {
          'interactionId': 'i-2',
          'kind': 'userInput',
        }),
        _entry('c', 'running'),
      ],
      previousPhases: const {},
    );
    expect(update.pendingInteractions, hasLength(2));
    final first = update.pendingInteractions[0];
    expect(first.taskId, 'a');
    expect(first.interactionId, 'i-1');
    expect(first.kind, 'permission');
    expect(first.toolName, 'bash');
    expect(update.pendingInteractions[1].taskId, 'b');
  });

  test('interactions without an id are ignored', () {
    final update = computeNotifyUpdate(
      sessions: [_entry('a', 'waiting', pending: {'kind': 'permission'})],
      previousPhases: const {},
    );
    expect(update.pendingInteractions, isEmpty);
  });

  test('attentionTitleFor names the blocker', () {
    expect(attentionTitleFor('permission', 'bash'), '权限请求 · bash');
    expect(attentionTitleFor('permission', ''), '权限请求等待批准');
    expect(attentionTitleFor('userInput', ''), '等待你的输入');
  });
}
