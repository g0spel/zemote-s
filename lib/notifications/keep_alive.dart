import 'package:flutter/widgets.dart';

import '../state/account_store.dart';
import '../state/background_prefs.dart';
import 'notifications.dart';

/// 保活服务装配：开关 × 已配对设备 → 前台服务运行/停止；偏好或设备列表
/// 变化、App 回前台（系统可能回收过服务）时重新对齐。
class KeepAliveController {
  final AccountStore store;
  final BackgroundPrefs prefs;
  final Notifications notifications;
  AppLifecycleListener? _lifecycle;
  bool _syncing = false;

  KeepAliveController({
    required this.store,
    required this.prefs,
    required this.notifications,
  });

  void start() {
    prefs.addListener(_scheduleSync);
    store.addListener(_scheduleSync);
    _lifecycle = AppLifecycleListener(onStateChange: (state) {
      if (state == AppLifecycleState.resumed) _scheduleSync();
    });
    _scheduleSync();
  }

  void dispose() {
    prefs.removeListener(_scheduleSync);
    store.removeListener(_scheduleSync);
    _lifecycle?.dispose();
  }

  void _scheduleSync() {
    // 监听回调里同步 invoke 会与 prefs 通知互相重入；合并到微任务稳态。
    if (_syncing) return;
    _syncing = true;
    Future<void>.microtask(() async {
      try {
        await sync();
      } finally {
        _syncing = false;
      }
    });
  }

  Future<void> sync() async {
    if (!Notifications.isSupported) return;
    if (!prefs.loaded) await prefs.load();
    final decision = keepAliveDecision(
      enabled: prefs.keepAliveEnabled,
      hasDevices: store.accounts.isNotEmpty,
    );
    if (decision == KeepAliveDecision.run) {
      await notifications.setKeepAlive(wakeLock: prefs.wakeLock);
    } else {
      await notifications.clearKeepAlive();
    }
  }
}
