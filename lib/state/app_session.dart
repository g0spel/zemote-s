import 'package:flutter/foundation.dart';

import '../protocol/connection_params.dart';
import '../protocol/zemote_client.dart';
import '../state/log_store.dart';
import 'account_store.dart';

/// Creates the [ZemoteClient] for one device. Production builds the real
/// relay client; tests inject fakes through [AppSession.clientFactory].
typedef ZemoteClientFactory = ZemoteClient Function(
    ZemoteConnectionParams params, void Function(String line)? onLog);

/// Translates low-level connect failures into an actionable Chinese
/// explanation shown in the device list. Unknown reasons pass through.
String describeConnectFailure(Object e) {
  final s = '$e';
  if (s.contains('session-not-found') || s.contains('session-expired')) {
    return '凭据已失效：请在桌面 ZCode 重新生成远程控制链接，删除本设备后重新添加';
  }
  if (s.contains('session-conflict')) {
    return '连接冲突：同一凭据已有其他远程客户端在线，请先关闭其他客户端或重新生成链接';
  }
  if (s.contains('desktop-disconnected')) {
    return '桌面端未连接：请打开桌面 ZCode 并确认远程控制已开启';
  }
  if (s.contains('invalid-mobile-connection')) {
    return '桌面未在超时内确认本次连接：请确认桌面在线后重试，或重新生成链接';
  }
  if (s.contains('relay-unavailable')) {
    return '无法连接中继服务器：请检查网络，或服务暂时不可用';
  }
  if (s.contains('kicked')) {
    return '已被桌面端断开（kicked）';
  }
  if (s.contains('auth-malformed')) {
    return '配对协议异常（挑战帧格式变化）：上游协议可能已变更，请导出协议日志反馈';
  }
  if (s.contains('pairing timeout')) {
    return '配对超时：桌面未响应，凭据可能已失效，或上游协议已变更（请导出协议日志排查）';
  }
  if (s.contains('TimeoutException') || s.contains('SocketException')) {
    return '网络错误：无法到达服务器（$s）';
  }
  return s;
}

/// Manages connections to multiple devices simultaneously. Each account can
/// have an independent live connection; exactly one is "active" and drives
/// the RootShell view. Switching to an already-connected device does not
/// reconnect, and the last connect/switch request always wins activation —
/// a slow in-flight connect never yanks the active device back.
class AppSession extends ChangeNotifier {
  final Map<String, ZemoteClient> _connections = {};
  final Set<String> _connecting = {};

  /// 在途 connect 的 future(按账号):同账号重复 connect 复用同一个,
  /// 防止二次建连覆盖 `_connections[id]` 后旧 socket 泄漏。
  final Map<String, Future<ZemoteClient>> _inFlight = {};

  /// 连接意图(按账号):connect 发起时登记,disconnect/disconnectAll
  /// 撤销。connect 完成时意图已不在 → 该账号在连接期间被断开/移除,
  /// 连接作废(不入池、不激活)。
  final Set<String> _connectIntents = {};
  final Map<String, String> _errors = {};
  String? _activeId;
  Account? _activeAccount;

  /// Monotonic activation-intent counter: every request that wants a device
  /// active (connect/switchTo/_activate) bumps it. A slow in-flight connect
  /// whose epoch is no longer current must not steal activation back after
  /// the user switched to another device — the last request wins.
  int _activationEpoch = 0;

  final ZemoteClientFactory? clientFactory;

  AppSession({@visibleForTesting this.clientFactory});

  /// Currently active device client (drives the shell).
  ZemoteClient? get client => _connections[_activeId];

  /// Currently active device account.
  Account? get current => _activeAccount;

  /// Whether [accountId] currently has a live connection.
  bool isConnected(String accountId) => _connections.containsKey(accountId);

  /// Whether [accountId] is currently establishing a connection.
  bool connecting(String accountId) => _connecting.contains(accountId);

  /// Last error for [accountId], if any.
  String? errorOf(String accountId) => _errors[accountId];

  /// Client for a specific (possibly non-active) device.
  ZemoteClient? clientOf(String accountId) => _connections[accountId];

  /// True while any device is connecting (disables global add actions).
  bool get connectingAny => _connecting.isNotEmpty;

  /// Ensure [account] is connected and make it active. Reuses an existing
  /// live connection, then an in-flight connect for the same account;
  /// otherwise establishes a new one. If the user switched to another
  /// device while this connect was in flight, the device is added to the
  /// pool silently (stays connected) without stealing activation. If the
  /// account was disconnected (or removed) mid-flight, the connection is
  /// discarded — a device the user just cut off never comes back through
  /// a stale connect.
  Future<ZemoteClient> connect(Account account) async {
    final existing = _connections[account.id];
    if (existing != null) {
      _activate(account);
      return existing;
    }
    final inFlight = _inFlight[account.id];
    if (inFlight != null) return inFlight;
    final future = _connect(account);
    _inFlight[account.id] = future;
    try {
      return await future;
    } finally {
      if (identical(_inFlight[account.id], future)) {
        _inFlight.remove(account.id);
      }
    }
  }

  Future<ZemoteClient> _connect(Account account) async {
    _connectIntents.add(account.id);
    _connecting.add(account.id);
    _errors.remove(account.id);
    notifyListeners();
    final epoch = ++_activationEpoch;
    final params = account.params;
    if (params == null) {
      _connectIntents.remove(account.id);
      _connecting.remove(account.id);
      _errors[account.id] = '无法解析连接 URL（需为 https 且包含 sid/hash/t 参数）';
      notifyListeners();
      throw StateError(_errors[account.id]!);
    }
    final factory = clientFactory;
    final c = factory != null
        ? factory(params, log)
        : ZemoteClient(params, onLog: log);
    try {
      await c.connect();
      await c.waitPaired(timeout: const Duration(seconds: 90));
    } catch (e, st) {
      _connectIntents.remove(account.id);
      _connecting.remove(account.id);
      _errors[account.id] = describeConnectFailure(e);
      notifyListeners();
      log('[诊断] 连接失败: ${describeConnectFailure(e)}（原始错误: $e）');
      await c.dispose();
      Error.throwWithStackTrace(StateError(describeConnectFailure(e)), st);
    }
    if (!_connectIntents.contains(account.id)) {
      // 连接期间被 disconnect/disconnectAll:意图已撤销,作废在途连接。
      _connecting.remove(account.id);
      notifyListeners();
      await c.dispose();
      throw StateError('连接已取消：设备在连接完成前已断开或移除');
    }
    _connectIntents.remove(account.id);
    _connections[account.id] = c;
    if (epoch == _activationEpoch) {
      _activate(account);
    } else {
      // A newer connect/switchTo superseded this one; still connected in
      // the background, just not active.
      _connecting.remove(account.id);
      notifyListeners();
    }
    return c;
  }

  /// Switch the active device without reconnecting. Connects first if needed.
  Future<void> switchTo(Account account) async {
    if (_connections.containsKey(account.id)) {
      _activate(account);
      return;
    }
    await connect(account);
  }

  void _activate(Account account) {
    _activationEpoch++;
    _activeId = account.id;
    _activeAccount = account;
    _connecting.remove(account.id);
    _errors.remove(account.id);
    notifyListeners();
  }

  /// Disconnect a single device. Bumps the activation epoch so an in-flight
  /// connect for this device cannot re-activate it after the disconnect,
  /// and revokes the connect intent so the in-flight connect is discarded
  /// at completion instead of entering the pool.
  Future<void> disconnect(String accountId) async {
    _activationEpoch++;
    _connectIntents.remove(accountId);
    final conn = _connections.remove(accountId);
    _connecting.remove(accountId);
    _errors.remove(accountId);
    if (_activeId == accountId) {
      _activeId = null;
      _activeAccount = null;
    }
    notifyListeners();
    await conn?.dispose();
  }

  /// Disconnect everything.
  Future<void> disconnectAll() async {
    _activationEpoch++;
    _connectIntents.clear();
    final all = _connections.values.toList();
    _connections.clear();
    _connecting.clear();
    _errors.clear();
    _activeId = null;
    _activeAccount = null;
    notifyListeners();
    for (final c in all) {
      await c.dispose();
    }
  }

  @override
  Future<void> dispose() async {
    await disconnectAll();
    super.dispose();
  }
}
