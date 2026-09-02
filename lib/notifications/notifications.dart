import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Global instance initialized once in `main()`.
final notificationsService = Notifications();

/// Thin wrapper over the Android notification/nav platform channels
/// (`zflow/notifications`, `zflow/nav`). Non-Android platforms no-op.
class Notifications {
  static const _channel = MethodChannel('zflow/notifications');
  static const _nav = MethodChannel('zflow/nav');

  Future<void> Function(Map<String, dynamic> payload)? _tapHandler;

  /// 冷启动/过早到达的点击载荷:此刻 tap 处理器(连接建立后由
  /// TaskNotifier 注册)尚不存在,暂存待注册时补派发,不再丢弃。
  Map<String, dynamic>? _pendingTap;
  bool _initialized = false;

  static bool get isSupported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// Registers the native→Dart tap callback and drains any cold-start payload
  /// (处理器未就绪时暂存补派发)。
  void init() {
    if (_initialized || !isSupported) return;
    _initialized = true;
    _nav.setMethodCallHandler((call) async {
      if (call.method == 'onNotificationTap' && call.arguments is String) {
        _dispatch(call.arguments as String);
      }
      return null;
    });
    _nav.invokeMethod<String>('getLaunchPayload').then((p) {
      if (p != null) _dispatch(p);
    }).catchError((_) {});
  }

  void _dispatch(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        final payload = decoded.cast<String, dynamic>();
        final handler = _tapHandler;
        if (handler == null) {
          _pendingTap = payload;
        } else {
          handler(payload);
        }
      }
    } catch (_) {}
  }

  Future<void> setTapHandler(Future<void> Function(Map<String, dynamic> payload)? h) {
    _tapHandler = h;
    final pending = _pendingTap;
    if (h != null && pending != null) {
      _pendingTap = null;
      Future(() => h(pending)).catchError((_) {});
    }
    return Future.value();
  }

  /// 运行中任务通知（TaskNotifier 驱动，实时预览）。
  Future<void> setRunning(String title, String text) => _channel
      .invokeMethod('setRunning', {'title': title, 'text': text});

  /// 释放「运行中」占用：若保活常驻开启，服务回落为保活空闲通知而非停止。
  Future<void> releaseRunning() => _channel.invokeMethod('releaseRunning');

  /// 保活常驻：空闲时也保持前台服务与连接。[wakeLock] = 息屏持锁。
  Future<void> setKeepAlive({required bool wakeLock}) =>
      _channel.invokeMethod('setKeepAlive', {'wakeLock': wakeLock});

  Future<void> clearKeepAlive() => _channel.invokeMethod('clearKeepAlive');

  /// [channel] 选择通知渠道：`approval`（审批，高重要性横幅）或
  /// `completion`（完成/失败，静音普通渠道）。
  Future<void> notifyEvent({
    required String channel,
    required String title,
    required String text,
    required Map<String, dynamic> payload,
  }) =>
      _channel.invokeMethod('notifyEvent', {
        'channel': channel,
        'title': title,
        'text': text,
        'payload': jsonEncode(payload),
      });

  Future<bool> isIgnoringBatteryOptimizations() async {
    if (!isSupported) return true;
    final ok = await _channel
        .invokeMethod<bool>('isIgnoringBatteryOptimizations');
    return ok ?? true;
  }

  /// 弹出系统「忽略电池优化」确认框（需 REQUEST_IGNORE_BATTERY_OPTIMIZATIONS）。
  Future<void> requestIgnoreBatteryOptimizations() {
    if (!isSupported) return Future.value();
    return _channel.invokeMethod('requestIgnoreBatteryOptimizations');
  }

  Future<bool> hasPermission() async {
    final ok = await _channel.invokeMethod<bool>('hasNotificationPermission');
    return ok ?? true;
  }

  Future<void> requestPermission() =>
      _channel.invokeMethod('requestNotificationPermission');
}
