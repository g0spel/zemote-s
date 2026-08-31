import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 后台保活与通知偏好（设置 → 后台与通知）。
///
/// 默认值即产品默认行为：保活开（连接稳定优先），三类通知全开（协议
/// 通知精准、非扒页面无噪音）。单例经 [load] 恢复，变更即落盘并通知。
class BackgroundPrefs extends ChangeNotifier {
  BackgroundPrefs._();

  static final BackgroundPrefs instance = BackgroundPrefs._();

  static const _kKeepAlive = 'keepAlive.enabled';
  static const _kWakeLock = 'keepAlive.wakeLock';
  static const _kNotifyApprovals = 'notify.approvals';
  static const _kNotifyCompletions = 'notify.completions';
  static const _kNotifyFailures = 'notify.failures';

  bool _loaded = false;

  /// 前台服务常驻：后台/息屏下保持 relay 连接（有已配对设备时生效）。
  bool _keepAliveEnabled = true;

  /// 息屏时持有 WakeLock（部分机型 Doze 会冻结 socket；代价是耗电）。
  bool _wakeLock = true;

  bool _notifyApprovals = true;
  bool _notifyCompletions = true;
  bool _notifyFailures = true;

  bool get keepAliveEnabled => _keepAliveEnabled;
  bool get wakeLock => _wakeLock;
  bool get notifyApprovals => _notifyApprovals;
  bool get notifyCompletions => _notifyCompletions;
  bool get notifyFailures => _notifyFailures;
  bool get loaded => _loaded;

  Future<void> load() async {
    if (_loaded) return;
    final prefs = await SharedPreferences.getInstance();
    _keepAliveEnabled = prefs.getBool(_kKeepAlive) ?? true;
    _wakeLock = prefs.getBool(_kWakeLock) ?? true;
    _notifyApprovals = prefs.getBool(_kNotifyApprovals) ?? true;
    _notifyCompletions = prefs.getBool(_kNotifyCompletions) ?? true;
    _notifyFailures = prefs.getBool(_kNotifyFailures) ?? true;
    _loaded = true;
    notifyListeners();
  }

  Future<void> setKeepAliveEnabled(bool value) async {
    _keepAliveEnabled = value;
    await _persist(_kKeepAlive, value);
  }

  Future<void> setWakeLock(bool value) async {
    _wakeLock = value;
    await _persist(_kWakeLock, value);
  }

  Future<void> setNotifyApprovals(bool value) async {
    _notifyApprovals = value;
    await _persist(_kNotifyApprovals, value);
  }

  Future<void> setNotifyCompletions(bool value) async {
    _notifyCompletions = value;
    await _persist(_kNotifyCompletions, value);
  }

  Future<void> setNotifyFailures(bool value) async {
    _notifyFailures = value;
    await _persist(_kNotifyFailures, value);
  }

  Future<void> _persist(String key, bool value) async {
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(key, value);
    } catch (_) {
      notifyListeners();
    }
  }

  /// 测试与关灯场景：恢复「从未持久化过」的初始态。
  @visibleForTesting
  void resetForTest() {
    _keepAliveEnabled = true;
    _wakeLock = true;
    _notifyApprovals = true;
    _notifyCompletions = true;
    _notifyFailures = true;
    _loaded = true;
  }
}

/// 保活服务是否应该运行：开关开 且 存在已配对设备。
KeepAliveDecision keepAliveDecision({
  required bool enabled,
  required bool hasDevices,
}) =>
    enabled && hasDevices
        ? KeepAliveDecision.run
        : KeepAliveDecision.stop;

enum KeepAliveDecision { run, stop }
