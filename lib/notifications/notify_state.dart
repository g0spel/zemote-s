import '../protocol/conversation.dart';

/// Pure derivation of notification state from a sessions-index snapshot.
/// Kept dependency-free so it can be unit tested.
///
/// [previousPhases] is the sessionId→phase map from the last tick; it doubles
/// as the de-dupe for completion events (a running→terminal transition fires
/// exactly once, and re-running a task fires again on its next completion).
class NotifyUpdate {
  final List<RunningTask> running;
  final List<CompletionEvent> completed;

  /// ALL interactions currently pending across sessions — a SNAPSHOT, not
  /// edge-triggered: the notifier diffs it against what it already
  /// announced (one alert per interactionId, resolved interactions drop
  /// out and free their ids).
  final List<AttentionEvent> pendingInteractions;

  const NotifyUpdate({
    required this.running,
    required this.completed,
    this.pendingInteractions = const [],
  });

  bool get hasRunning => running.isNotEmpty;
}

class RunningTask {
  final String taskId;
  final String title;
  final String preview;

  const RunningTask({
    required this.taskId,
    required this.title,
    required this.preview,
  });
}

/// A task blocked on a pending interaction (permission request / user
/// input) — surfaced by the sessions-index summary.
class AttentionEvent {
  final String taskId;
  final String title;
  final String interactionId;

  /// `permission` | `userInput` (host enum).
  final String kind;

  final String toolName;

  const AttentionEvent({
    required this.taskId,
    required this.title,
    required this.interactionId,
    required this.kind,
    required this.toolName,
  });
}

class CompletionEvent {
  final String taskId;
  final String title;
  final String preview;
  final String phase;
  /// Monotonic activity marker from the sessions-index; used to suppress
  /// stale repeats (0 when the server omits it).
  final int lastActivityAt;

  const CompletionEvent({
    required this.taskId,
    required this.title,
    required this.preview,
    required this.phase,
    required this.lastActivityAt,
  });
}

const _runningPhases = {'running', 'prewarming'};
const _terminalPhases = {
  'completed',
  'completedSuccess',
  'completedInterrupted',
  'cancelled',
  'failed',
  'error',
};

NotifyUpdate computeNotifyUpdate({
  required List<SessionEntry> sessions,
  required Map<String, String> previousPhases,
}) {
  final running = <RunningTask>[];
  final completed = <CompletionEvent>[];
  final pending = <AttentionEvent>[];
  final nowPhases = <String, String>{};
  final nowEntries = <String, SessionEntry>{};

  for (final e in sessions) {
    nowPhases[e.sessionId] = e.phase;
    nowEntries[e.sessionId] = e;
    if (_runningPhases.contains(e.phase)) {
      running.add(RunningTask(
        taskId: e.sessionId,
        title: e.title.isEmpty ? e.sessionId : e.title,
        preview: e.lastAssistantPreview ?? '',
      ));
    }
    final interaction = e.pendingInteraction;
    final interactionId = '${interaction?['interactionId'] ?? ''}';
    if (interaction != null && interactionId.isNotEmpty) {
      pending.add(AttentionEvent(
        taskId: e.sessionId,
        title: e.title.isEmpty ? e.sessionId : e.title,
        interactionId: interactionId,
        kind: '${interaction['kind'] ?? ''}',
        toolName: '${interaction['toolName'] ?? ''}',
      ));
    }
  }

  previousPhases.forEach((sessionId, wasPhase) {
    if (!_runningPhases.contains(wasPhase)) return;
    final now = nowPhases[sessionId];
    if (now == null || !_terminalPhases.contains(now)) return;
    final entry = nowEntries[sessionId];
    completed.add(CompletionEvent(
      taskId: sessionId,
      title: entry?.title.isNotEmpty == true ? entry!.title : sessionId,
      preview: entry?.lastAssistantPreview ?? '',
      phase: now,
      lastActivityAt: entry?.lastActivityAt ?? 0,
    ));
  });

  return NotifyUpdate(
      running: running, completed: completed, pendingInteractions: pending);
}

/// Notification title for a terminal phase — failures must not announce
/// themselves as completions.
String completionTitleFor(String phase) => switch (phase) {
      'failed' || 'error' => '任务失败',
      'completedInterrupted' || 'cancelled' => '任务中断',
      _ => '任务完成',
    };

/// Notification title for a pending interaction — the task is blocked
/// until the user answers.
String attentionTitleFor(String kind, String toolName) => kind == 'permission'
    ? (toolName.isEmpty ? '权限请求等待批准' : '权限请求 · $toolName')
    : '等待你的输入';

/// Formats the running-tasks list into the persistent notification text.
String formatRunningText(List<RunningTask> running) {
  if (running.isEmpty) return '';
  final lines = <String>[];
  for (final t in running) {
    final preview = t.preview.trim();
    lines.add(preview.isEmpty ? '• ${t.title}' : '• ${t.title}\n  $preview');
  }
  return lines.join('\n\n');
}
