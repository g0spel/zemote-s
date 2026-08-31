import 'dart:async';

import 'package:flutter/widgets.dart';

import '../protocol/conversation.dart';
import '../protocol/zflow_client.dart';
import '../state/background_prefs.dart';
import 'notifications.dart';
import 'notify_state.dart';
import 'unread.dart';

/// Monitors the active workspace's sessions-index while a bridge is open.
/// While tasks are running it drives the Android foreground-service
/// notification with real-time preview updates, and fires notifications
/// gated by user prefs and visibility (三重门控：后台、或前台但看的不是
/// 该会话才推). Types: approval (pending interaction, high-importance
/// channel), completion, failure. Tapping routes to the task's chat via
/// [onOpenTask].
class TaskNotifier {
  final BridgeSession bridge;
  final Map<String, dynamic> scope;
  final Notifications notifications;
  final Future<void> Function(String taskId, String title) onOpenTask;

  /// 当前前台正在查看的会话 id（null = 非会话页/草稿）。门控用。
  final String? Function() visibleSessionId;

  final BackgroundPrefs prefs;
  final UnreadEvents unread;

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
    this.visibleSessionId = _noVisibleSession,
    BackgroundPrefs? prefs,
    UnreadEvents? unread,
  })  : prefs = prefs ?? BackgroundPrefs.instance,
        unread = unread ?? UnreadEvents.instance {
    _tapOwners[notifications] = this;
    notifications.setTapHandler(_handleTap);
    _lifecycle = AppLifecycleListener(onStateChange: (state) {
      _appResumed = state == AppLifecycleState.resumed;
    });
    final now = WidgetsBinding.instance.lifecycleState;
    _appResumed = now == null || now == AppLifecycleState.resumed;
  }

  static String? _noVisibleSession() => null;

  /// 三重门控（zremote 同款语义）：后台必推；前台但正在看的是「别的
  /// 会话」也推；前台且正看该会话不推（用户盯着聊天，弹回无意义）。
  bool _shouldNotify(String taskId) =>
      !_appResumed || visibleSessionId() != taskId;

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
      // 类型路由与偏好：失败/中断走失败开关，其余走完成开关；偏好关闭
      // 或三重门控命中（前台正看该会话）则跳过。重复活动标记（重连
      // 快照重放旧 preview）不重复提醒。
      final isFailure = completionTitleFor(c.phase) != '任务完成';
      if (isFailure ? !prefs.notifyFailures : !prefs.notifyCompletions) {
        continue;
      }
      if (!_shouldNotify(c.taskId)) continue;
      final marker = c.lastActivityAt;
      final last = _lastNotifiedActivity[c.taskId];
      if (marker > 0 && last != null && marker <= last) continue;
      if (marker > 0) _lastNotifiedActivity[c.taskId] = marker;
      unread.add(c.taskId);
      _safe(notifications.notifyEvent(
        channel: 'completion',
        title: completionTitleFor(c.phase),
        text: c.preview.trim().isEmpty ? c.title : '${c.title}\n${c.preview}',
        payload: {'taskId': c.taskId, 'title': c.title},
      ));
    }

    // Pending interactions (permission / input): one alert per
    // interactionId, learned even in the foreground so replays stay
    // quiet. Tapping routes to the chat where the popup lives.
    final liveInteractionIds = <String>{};
    for (final p in update.pendingInteractions) {
      liveInteractionIds.add(p.interactionId);
      if (!_seenInteractionIds.add(p.interactionId)) continue;
      if (!prefs.notifyApprovals) continue;
      if (!_shouldNotify(p.taskId)) continue;
      unread.add(p.taskId);
      _safe(notifications.notifyEvent(
        channel: 'approval',
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
      // 保活常驻开启时服务回落为空闲通知而非停止（Kotlin 侧裁决）。
      _safe(notifications.releaseRunning());
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
    _safe(notifications.setRunning(title, text));
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
      _safe(notifications.releaseRunning());
      notifications.setTapHandler(null);
    }
  }

  void _safe(Future<void> future) {
    future.catchError((_) {});
  }
}
