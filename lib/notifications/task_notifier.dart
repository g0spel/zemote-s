import 'dart:async';

import 'package:flutter/widgets.dart';

import '../protocol/conversation.dart';
import '../protocol/zflow_client.dart';
import 'notifications.dart';
import 'notify_state.dart';

/// Monitors the active workspace's sessions-index while a bridge is open.
/// While tasks are running it drives the Android foreground-service
/// notification with real-time preview updates, and fires silent completion
/// notifications plus one silent alert per pending interaction (permission /
/// input request blocking a task). Tapping a notification routes to the
/// task's chat via [onOpenTask].
class TaskNotifier {
  final BridgeSession bridge;
  final Map<String, dynamic> scope;
  final Notifications notifications;
  final Future<void> Function(String taskId, String title) onOpenTask;

  SessionsIndexSubscription? _sub;
  Map<String, String> _prevPhases = {};

  /// Only the newest notifier may own the process-wide notification tap
  /// handler. Teardown is asynchronous because subscription unsubscribe waits
  /// for the bridge, so an old notifier can finish after a replacement was
  /// installed.
  static final Expando<TaskNotifier> _tapOwners = Expando<TaskNotifier>();

  /// Coalesces repeated dispose calls while preserving the async unsubscribe
  /// completion for callers that need to await it.
  Future<void>? _disposeFuture;
  Future<void>? _startFuture;

  /// taskId → lastActivityAt already announced. Stale repeats (identical
  /// preview, e.g. after reconnect snapshots) are suppressed.
  final Map<String, int> _lastNotifiedActivity = {};

  /// interactionIds already seen in a pending snapshot. Ids are learned
  /// even while the app is foregrounded (the user is looking at the popup)
  /// so a later background replay of the same pending interaction does
  /// not re-alert; resolved interactions drop out and free their ids.
  final Set<String> _seenInteractionIds = {};

  /// Completion alerts are pointless while the user is looking at the app:
  /// they also re-fire on every resume via reconnect snapshots.
  bool _appResumed = true;
  AppLifecycleListener? _lifecycle;
  bool _active = false;
  bool _disposed = false;
  bool _permissionChecked = false;
  DateTime _lastForegroundUpdate = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _trailingTimer;

  TaskNotifier({
    required this.bridge,
    required this.scope,
    required this.notifications,
    required this.onOpenTask,
  }) {
    _tapOwners[notifications] = this;
    notifications.setTapHandler(_handleTap);
    _lifecycle = AppLifecycleListener(onStateChange: (state) {
      _appResumed = state == AppLifecycleState.resumed;
    });
    final now = WidgetsBinding.instance.lifecycleState;
    _appResumed = now == null || now == AppLifecycleState.resumed;
  }

  bool get isActive => _active;

  Future<void> start() => _startFuture ??= _start();

  Future<void> _start() async {
    if (_active || _disposed) return;
    _active = true;
    _prevPhases = {};
    try {
      final transport = bridge.conversation(scope);
      final sub = await transport.subscribeSessionsIndex();
      if (_disposed || !_active) {
        // The subscription may finish after dispose. Do not make dispose wait
        // for an uncancellable start; release it only while the bridge is
        // still usable. A disposed bridge has already released its registry.
        unawaited(_disposeSubscription(sub));
        return;
      }
      _sub = sub;
      sub.state.addListener(_onState);
      _onState();
    } catch (_) {
      _active = false;
      _startFuture = null;
    }
  }

  Future<void> _disposeSubscription(SessionsIndexSubscription sub) async {
    if (bridge.isDisposed) return;
    try {
      // dispose() sends unsubscribe before its first await. Checking the
      // bridge immediately before calling it avoids sending unsubscribe on a
      // bridge that teardown has already released.
      await sub.dispose();
    } catch (_) {}
  }

  void _onState() {
    if (!_active || _disposed) return;
    final sub = _sub;
    if (sub == null) return;
    final update = computeNotifyUpdate(
      sessions: sub.state.list,
      previousPhases: _prevPhases,
    );
    _prevPhases = {for (final e in sub.state.list) e.sessionId: e.phase};

    for (final c in update.completed) {
      // Suppress while the user is in the app (they see the chat), and
      // suppress repeats of an already-announced activity marker (stale
      // previews re-arriving with reconnect snapshots).
      if (_appResumed) break;
      final marker = c.lastActivityAt;
      final last = _lastNotifiedActivity[c.taskId];
      if (marker > 0 && last != null && marker <= last) continue;
      if (marker > 0) _lastNotifiedActivity[c.taskId] = marker;
      _safe(notifications.notifyTaskCompleted(
        title: completionTitleFor(c.phase),
        text: c.preview.trim().isEmpty ? c.title : '${c.title}\n${c.preview}',
        payload: {'taskId': c.taskId, 'title': c.title},
      ));
    }

    // Pending interactions (permission / input): one silent alert per
    // interactionId, learned even in the foreground so replays stay
    // quiet. Tapping routes to the chat where the popup lives.
    final liveInteractionIds = <String>{};
    for (final p in update.pendingInteractions) {
      liveInteractionIds.add(p.interactionId);
      if (!_seenInteractionIds.add(p.interactionId)) continue;
      if (_appResumed) continue;
      _safe(notifications.notifyTaskCompleted(
        title: attentionTitleFor(p.kind, p.toolName),
        text: p.title,
        payload: {'taskId': p.taskId, 'title': p.title},
      ));
    }
    _seenInteractionIds.removeWhere((id) => !liveInteractionIds.contains(id));

    if (update.hasRunning) {
      _ensurePermission();
      _scheduleForeground(update.running);
    } else {
      _trailingTimer?.cancel();
      _safe(notifications.stopForeground());
    }
  }

  void _ensurePermission() {
    if (_permissionChecked) return;
    _permissionChecked = true;
    _safe(() async {
      final ok = await notifications.hasPermission();
      if (!ok) await notifications.requestPermission();
    }());
  }

  void _scheduleForeground(List<RunningTask> running) {
    const throttle = Duration(milliseconds: 900);
    final now = DateTime.now();
    if (now.difference(_lastForegroundUpdate) >= throttle) {
      _publish(running);
      return;
    }
    _trailingTimer?.cancel();
    _trailingTimer = Timer(throttle, () {
      if (_active && !_disposed) _publish(running);
    });
  }

  void _publish(List<RunningTask> running) {
    _lastForegroundUpdate = DateTime.now();
    final title = '${running.length} 个任务运行中';
    var text = formatRunningText(running);
    if (text.length > 600) text = '${text.substring(0, 597)}…';
    _safe(notifications.updateForeground(title, text));
  }

  Future<void> _handleTap(Map<String, dynamic> payload) async {
    if (!identical(_tapOwners[notifications], this)) return;
    final taskId = payload['taskId'] as String?;
    if (taskId == null || _disposed) return;
    await onOpenTask(taskId, (payload['title'] as String?) ?? taskId);
  }

  Future<void> dispose() => _disposeFuture ??= _dispose();

  Future<void> _dispose() async {
    _disposed = true;
    _active = false;
    _trailingTimer?.cancel();
    _lifecycle?.dispose();
    // subscribeSessionsIndex cannot be cancelled once started. Do not await
    // _startFuture here: a bridge teardown may release the transport first;
    // _start() handles a late subscription and releases it when possible.
    final sub = _sub;
    _sub = null;
    if (sub != null && !bridge.isDisposed) {
      sub.state.removeListener(_onState);
      await sub.dispose();
    }
    if (identical(_tapOwners[notifications], this)) {
      _tapOwners[notifications] = null;
      _safe(notifications.stopForeground());
      notifications.setTapHandler(null);
    }
  }

  void _safe(Future<void> future) {
    future.catchError((_) {});
  }
}
