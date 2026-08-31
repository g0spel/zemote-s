import 'dart:async';

import 'package:flutter/material.dart';

import '../notifications/notifications.dart';
import '../notifications/task_notifier.dart';
import '../notifications/unread.dart';
import '../protocol/conversation.dart'
    show SessionEntry, SessionsIndexSubscription;
import '../protocol/relay_client.dart';
import '../protocol/zflow_client.dart';
import '../state/account_store.dart';
import '../state/log_store.dart';
import '../state/app_session.dart';
import 'automation_page.dart';
import 'chat_page.dart';
import 'session_drawer.dart';
import 'delayed_banner.dart';
import 'device_management_page.dart';
import 'settings_page.dart';
import 'theme.dart';

/// 库级未读计数单例（通知发出 +1，打开会话清零）。
final unreadEvents = UnreadEvents.instance;

/// Mirrors `HC()` in the web client:
/// key = workspaceIdentity?.trim() || workspacePath.
String? workspaceKeyOf(Map<String, dynamic> w) {
  final identity = w['workspaceIdentity'];
  if (identity is String && identity.trim().isNotEmpty) {
    return identity.trim();
  }
  final path = w['workspacePath'];
  if (path is String && path.isNotEmpty) return path;
  for (final key in const ['workspaceKey', 'key', 'id']) {
    final v = w[key];
    if (v is String && v.isNotEmpty) return v;
  }
  return null;
}

/// 宿主 bootstrap 工作区条目({path, label?, workspaceIdentity?})→
/// 内部约定字段({workspacePath, workspaceKey,...})。
Map<String, dynamic> _normalizeWorkspace(Map<dynamic, dynamic> w) => {
      ...w.cast<String, dynamic>(),
      'workspacePath': w['workspacePath'] ?? w['path'],
      'workspaceKey': (w['workspaceIdentity'] as String?)?.trim().isNotEmpty ==
              true
          ? (w['workspaceIdentity'] as String).trim()
          : w['path'],
    };

String workspaceTitle(Map<String, dynamic> w) {
  final label = w['label'] as String?;
  if (label != null && label.isNotEmpty) return label;
  final path = w['workspacePath'] as String?;
  if (path != null && path.isNotEmpty) {
    final parts = path.split(RegExp(r'[\\/]'));
    return parts.lastWhere((p) => p.isNotEmpty, orElse: () => path);
  }
  final identity = w['workspaceIdentity'] as String?;
  if (identity != null && identity.isNotEmpty) return identity;
  return workspaceKeyOf(w) ?? '未知工作区';
}

/// Ember 三 Tab 壳:对话 / 自动化 / 设置。自 [AppSession] 驱动,启动时自动
/// 连接第一台设备并打开工作区;顶栏胶囊可在多设备间切换(不重连)。
class RootShell extends StatefulWidget {
  final AccountStore store;
  final AppSession session;

  /// 测试隔离用:生产路径恒为 true(挂载即自动连接第一台设备)。
  final bool autoConnect;

  const RootShell({
    super.key,
    required this.store,
    required this.session,
    this.autoConnect = true,
  });

  @override
  State<RootShell> createState() => _RootShellState();
}

enum _ConnectPhase { idle, connecting, failed, done }

class _RootShellState extends State<RootShell> {
  int _tab = 0;
  _ConnectPhase _phase = _ConnectPhase.idle;
  String? _connectError;
  List<dynamic> _workspaces = const [];
  Map<String, dynamic>? _activeWorkspace;
  BridgeSession? _bridge;
  StreamSubscription? _updatedSub;
  TaskNotifier? _taskNotifier;
  Future<void>? _recentSessionCleanup;
  AppLifecycleListener? _lifecycle;

  /// 会话抽屉开关(仅对话 Tab;随会话态复位/切 Tab 一起关闭)。
  bool _drawerOpen = false;

  /// 对话 Tab 的会话选择:null = draft 新会话(内嵌 ChatPage
  /// sessionId:null,首条消息 createSession,列表收进抽屉);
  /// 其余值 = 内嵌会话 id(经 ValueKey 重建)。draft 发出首条消息后由
  /// ChatPage 的 onSessionInfo 回写 id(实例内部已切到该会话,不触发
  /// 重建;下次重建/切 Tab 按已选会话恢复,不再开新 draft)。
  final ValueNotifier<String?> _activeSessionId = ValueNotifier(null);

  /// 内嵌 ChatPage 的重建代数:仅用户驱动的切换(抽屉选择/设备或工作区
  /// 复位)递增并强制全新实例;会话 id 的静默变化(draft 采纳回写)不动
  /// 它,保证当前实例跨壳重建存活(composer 草稿、在途 echo 不丢)。
  int _sessionEpoch = 0;

  /// 头部会话名:null 显示"新会话";由内嵌 ChatPage 的 onSessionInfo
  /// 回写(桌面端生成或重命名标题时)。
  final ValueNotifier<String?> _activeSessionTitle = ValueNotifier(null);

  /// 推入栈顶的任务会话页(通知点击进入)——可见会话判定的最高优先级。
  String? _visibleTaskChatId;

  /// 通知三重门控用:当前前台正在查看的会话 id(推入的任务页优先,
  /// 否则为内嵌会话)。
  String? _visibleSessionId() => _visibleTaskChatId ?? _activeSessionId.value;

  /// 当前壳已加载/正在加载的设备 id(防止 session 通知重复触发引导链)。
  String? _loadedAccountId;

  /// 上一次见到的激活设备 id:session 通知不带增量,靠它识别"激活设备换人了"
  /// (开链)与"设备消失"(断开重置)。connect 进行中的同步通知 current 尚未
  /// 变化,不会被误判成新切换。
  String? _lastSeenCurrentId;

  /// Monotonic chain generation: every bootstrap chain captures its own
  /// generation and may only commit shell state while it is still the
  /// newest one. A switch (or an external disconnect) bumps the counter,
  /// which invalidates all in-flight chains instead of dropping their
  /// requests — the last requested device always ends up on screen.
  int _chainGeneration = 0;

  /// autoConnect 因设备尚未加载完而挂起时置位,加载完成后补连一次。
  bool _pendingAutoConnect = false;

  bool _isCurrentChain(int gen) => mounted && gen == _chainGeneration;

  @override
  void initState() {
    super.initState();
    widget.session.addListener(_onSessionChanged);
    widget.store.addListener(_onChanged);
    // Coming back from background: timers were frozen — probe the relay now
    // instead of waiting for the next heartbeat tick to notice a dead
    // socket (shortens the user-visible disconnect window).
    _lifecycle = AppLifecycleListener(
      onResume: () => widget.session.client?.pokeRelay(),
    );
    if (widget.autoConnect && widget.store.accounts.isNotEmpty) {
      _openAccount(widget.store.accounts.first);
    } else if (widget.autoConnect) {
      // 配对设备是异步加载的:挂载时还没到就把标记挂起,加载完成
      // (_onChanged)后补连,保证冷启动 autoConnect 与加载时序无关。
      _pendingAutoConnect = true;
    }
  }

  @override
  void dispose() {
    widget.session.removeListener(_onSessionChanged);
    widget.store.removeListener(_onChanged);
    _lifecycle?.dispose();
    // State.dispose is synchronous; invalidate shell callbacks and session
    // adoption before releasing notifiers.
    _chainGeneration++;
    _sessionEpoch++;
    _teardownDeviceState();
    _activeSessionId.dispose();
    _activeSessionTitle.dispose();
    super.dispose();
  }

  void _onChanged() {
    if (!mounted) return;
    if (_pendingAutoConnect &&
        widget.store.accounts.isNotEmpty &&
        widget.session.current == null) {
      _pendingAutoConnect = false;
      _openAccount(widget.store.accounts.first);
    }
    setState(() {});
  }

  /// Session notifications: a new active device starts its bootstrap chain
  /// (never dropped — generation invalidation supersedes in-flight chains);
  /// a vanished active device (kicked / disconnected externally) resets the
  /// shell to the disconnected state instead of showing stale content.
  void _onSessionChanged() {
    if (!mounted) return;
    final account = widget.session.current;
    final prevId = _lastSeenCurrentId;
    _lastSeenCurrentId = account?.id;
    if (account == null) {
      if (prevId != null) {
        // Had an active device, now none: kicked or disconnected externally.
        _chainGeneration++;
        _loadedAccountId = null;
        _teardownDeviceState();
        setState(() {
          _tab = 0;
          _phase = _ConnectPhase.idle;
          _connectError = null;
          _workspaces = const [];
          _resetSessionState();
        });
        return;
      }
      setState(() {});
      return;
    }
    final changed = prevId != account.id;
    if (changed && account.id != _loadedAccountId) {
      _openAccount(account);
      return;
    }
    setState(() {});
  }

  /// Connect (or reuse) [account]'s device, then bootstrap workspaces and
  /// auto-open the first one. Chains may overlap; only the newest
  /// generation commits state, so a mid-flight switch always lands on the
  /// device the user asked for last.
  Future<void> _openAccount(Account account) async {
    unawaited(widget.store.touch(account.id));
    final gen = ++_chainGeneration;
    _loadedAccountId = account.id;
    _teardownDeviceState();
    setState(() {
      _tab = 0;
      _phase = _ConnectPhase.connecting;
      _connectError = null;
      _workspaces = const [];
      _activeWorkspace = null;
      _bridge = null;
      _resetSessionState();
    });
    try {
      final client = await widget.session.connect(account);
      if (!_isCurrentChain(gen)) return;
      _resubscribe(client, gen);
      final bootstrap = await client.bootstrap();
      if (!_isCurrentChain(gen)) return;
      final list = bootstrap['workspaces'];
      setState(() => _workspaces = list is List
          // 宿主条目字段是 {path, label?, workspaceIdentity?}:归一化为
          // 内部约定的 workspacePath/workspaceKey(workspaceKey 算法与
          // 宿主 Xmn 一致:identity 优先,否则 path)。缺失会导致
          // V4 订阅无 directory(全局索引、跨工作区混入)以及
          // listSessions 被必填校验拒绝。
          ? [for (final w in list)
              if (w is Map) _normalizeWorkspace(w)]
          : const []);
      // 连接完成不直接开新会话:进入工作区/会话选择(抽屉),
      // 由用户决定进入哪个工作区、哪个会话。
      if (!_isCurrentChain(gen)) return;
      setState(() => _phase = _ConnectPhase.done);
    } catch (e) {
      // A superseded chain failing must not clobber the newer chain's UI.
      if (!_isCurrentChain(gen)) return;
      _loadedAccountId = null;
      setState(() {
        _phase = _ConnectPhase.failed;
        _connectError = '$e';
      });
    }
  }

  void _teardownDeviceState() {
    final updatedSub = _updatedSub;
    _updatedSub = null;
    updatedSub?.cancel();

    final taskNotifier = _taskNotifier;
    _taskNotifier = null;
    final recentCleanup = _recentSessionCleanup;
    _recentSessionCleanup = null;
    final bridge = _bridge;
    _bridge = null;
    _activeWorkspace = null;
    unawaited(() async {
      // Release the bridge first. The notifier/recent-session cleanup paths
      // check this state and skip unsubscribe once the transport is gone;
      // teardown must not wait behind an uncancellable subscribe/start.
      bridge?.dispose();
      try {
        if (taskNotifier != null) await taskNotifier.dispose();
      } catch (_) {}
      try {
        if (recentCleanup != null) await recentCleanup;
      } catch (_) {}
    }());
  }

  void _resubscribe(ZflowClient client, int gen) {
    _updatedSub?.cancel();
    _updatedSub = client.workspaceListUpdated.listen((result) {
      if (!_isCurrentClient(client, gen) || result is! Map) return;
      final list = result['workspaces'];
      if (list is List) setState(() => _workspaces = list);
    });
  }

  bool _isCurrentClient(ZflowClient client, int gen) =>
      _isCurrentChain(gen) && identical(widget.session.client, client);

  bool _isCurrentBridge(BridgeSession bridge, int gen) =>
      _isCurrentChain(gen) && identical(_bridge, bridge) && !bridge.isDisposed;

  Future<void> _openWorkspace(Map<String, dynamic> workspace, int gen) async {
    final key = workspaceKeyOf(workspace);
    final client = widget.session.client;
    if (key == null || client == null || !_isCurrentChain(gen)) return;
    _resubscribe(client, gen);
    try {
      final session = await client.openBridge(key);
      if (!_isCurrentChain(gen)) {
        session.dispose();
        return;
      }
      setState(() {
        _bridge = session;
        _activeWorkspace = workspace;
      });
      _startTaskNotifier(session, workspace, gen);
      final recentCleanup = _probeRecentSession(session, workspace, gen);
      _recentSessionCleanup = recentCleanup;
      try {
        await recentCleanup;
      } catch (e) {
        log('[诊断] 最近会话打开失败: $e');
      } finally {
        if (identical(_recentSessionCleanup, recentCleanup)) {
          _recentSessionCleanup = null;
        }
      }
    } catch (e) {
      if (!mounted || !_isCurrentChain(gen)) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('打开工作区失败: $e')));
    }
  }

  Future<void> _probeRecentSession(
      BridgeSession session, Map<String, dynamic> workspace, int gen) async {
    final transport = session.conversation(_scopeOf(workspace));
    SessionsIndexSubscription? sub;
    try {
      await transport.handshake();
      if (!_isCurrentBridge(session, gen)) return;
      sub = await transport.subscribeSessionsIndex();
      if (!_isCurrentBridge(session, gen)) return;
      SessionEntry? recent;
      for (var i = 0; i < 80; i++) {
        if (!_isCurrentBridge(session, gen)) return;
        if (sub.state.ready) {
          for (final e in sub.state.list) {
            if (!e.isArchived) {
              recent = e;
              break;
            }
          }
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      if (!_isCurrentBridge(session, gen)) return;
      final picked = recent;
      log('[v4] 最近会话:ready=${sub.state.ready} '
          '列表=${sub.state.list.length} 选中=${picked?.sessionId ?? '无'}');
      if (diagLogEnabled.value) {
        debugPrint('[zflow] recent-session: ready=${sub.state.ready} '
            'list=${sub.state.list.length} '
            'picked=${picked?.sessionId ?? 'none'}');
      }
      if (picked != null && _isCurrentBridge(session, gen)) {
        _sessionEpoch++;
        setState(() => _activeSessionId.value = picked.sessionId);
      }
    } finally {
      if (sub != null && !session.isDisposed) {
        await sub.dispose();
      }
    }
  }

  /// Background task notifications: while tasks are running, a silent
  /// foreground-service notification shows live progress and completion
  /// alerts route back into the task's chat (Android only).
  void _startTaskNotifier(
      BridgeSession bridge, Map<String, dynamic> workspace, int gen) {
    if (!Notifications.isSupported) return;
    final previous = _taskNotifier;
    if (previous != null) {
      _taskNotifier = null;
      unawaited(previous.dispose());
    }
    final scope = _scopeOf(workspace);
    final workspaceKey = workspaceKeyOf(workspace) ?? '';
    _taskNotifier = TaskNotifier(
      bridge: bridge,
      scope: scope,
      notifications: notificationsService,
      visibleSessionId: _visibleSessionId,
      onOpenTask: (taskId, title) async {
        if (!_isCurrentBridge(bridge, gen)) return;
        unreadEvents.clearTask(taskId);
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => ChatPage(
              session: bridge,
              scope: scope,
              workspaceKey: workspaceKey,
              sessionId: taskId,
              title: title,
            ),
          ),
        ).then((_) {
          if (_visibleTaskChatId == taskId) _visibleTaskChatId = null;
        });
        _visibleTaskChatId = taskId;
      },
    )..start();
  }

  /// Opens a task chat pushed on top of the shell (automation run history).
  void _openTaskChat(
      BridgeSession bridge, int gen, String taskId, String title) {
    if (!_isCurrentBridge(bridge, gen)) return;
    final workspace = _activeWorkspace;
    if (workspace == null) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ChatPage(
          session: bridge,
          scope: _scopeOf(workspace),
          workspaceKey: workspaceKeyOf(workspace) ?? '',
          sessionId: taskId,
          title: title,
        ),
      ),
    );
  }

  /// `{workspacePath, workspaceIdentity?}` — the chat/automation scope.
  Map<String, dynamic> _scopeOf(Map<String, dynamic> workspace) => {
        'workspacePath': workspace['workspacePath'],
        if (workspace['workspaceIdentity'] != null)
          'workspaceIdentity': workspace['workspaceIdentity'],
      };

  /// 设备切换/断开后会话选择失效:回到 draft 态,抽屉一并关闭;
  /// 重建代数递增,内嵌 ChatPage 换设备后必须全新实例。
  void _resetSessionState() {
    _sessionEpoch++;
    _activeSessionId.value = null;
    _activeSessionTitle.value = null;
    _drawerOpen = false;
  }

  /// 抽屉选择:null = 新会话(draft);否则内嵌打开该会话。标题不随选择
  /// 注入,由 ChatPage 的 sessions-index 推送回写(桌面端生成)。任何显式
  /// 选择都递增重建代数(A11):重选当前会话即「重开」——全新实例,其
  /// 会话订阅失败态得以自愈;仅 draft(null)→null 幂等不重建。
  void _pickFromDrawer(String? sessionId) {
    final alreadyDraft = sessionId == null && _activeSessionId.value == null;
    if (!alreadyDraft) _sessionEpoch++;
    setState(() {
      _activeSessionId.value = sessionId;
      _activeSessionTitle.value = null;
    });
    // 用户主动打开了该会话，未读即清（draft 复位无对应任务，跳过）。
    if (sessionId != null) unreadEvents.clearTask(sessionId);
    _closeDrawer();
  }

  void _openDrawer() => setState(() => _drawerOpen = true);

  void _closeDrawer() => setState(() => _drawerOpen = false);

  /// A4:当前内嵌会话被删除/归档(从 sessions-index 消失,抽屉 diff 回调)
  /// → 复位到 draft 并提示。抽屉保持打开(用户多半正在管理操作中)。
  void _onCurrentSessionVanished() {
    if (!mounted || _activeSessionId.value == null) return;
    final adopted = _sessionAdoptedAt;
    if (adopted != null &&
        DateTime.now().difference(adopted).inSeconds < 30) {
      // 新会话宽限期内:忽略(索引快照滞后属常态)。
      return;
    }
    _sessionEpoch++;
    setState(() {
      _activeSessionId.value = null;
      _activeSessionTitle.value = null;
    });
    ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('当前会话已删除或归档，已回到新会话')));
  }

  /// 内嵌 ChatPage 回写:会话 id(draft 首条消息 createSession 后采纳)
  /// + 桌面端生成的标题 + 推送发出时实例的重建代数。静默写
  /// ValueNotifier——不 setState,当前内嵌实例继续存活;标题经
  /// ValueListenableBuilder 上头部,id 在下一次壳重建(切 Tab/抽屉)时
  /// 作为已选会话生效。代数已递增 = 旧实例的迟到推送,直接丢弃(A10:
  /// 消毫秒级覆盖竞态——旧实例的采纳/标题不得覆盖用户已做的新选择)。
  void _onSessionInfo(String sessionId, String title, int epoch) {
    if (epoch != _sessionEpoch) return;
    if (sessionId.isNotEmpty && sessionId != _activeSessionId.value) {
      _activeSessionId.value = sessionId;
      // 用户正看着这个会话（draft 采纳），未读即清。
      unreadEvents.clearTask(sessionId);
      // 新会话 adopt 宽限:刚建的会话短暂不在索引快照属常态,30s 内
      // 抽屉的"消失"判定一律忽略(误判会拆掉订阅,回复随之丢失)。
      _sessionAdoptedAt = DateTime.now();
    }
    _activeSessionTitle.value = title;
  }

  /// 当前会话的 adopt 时刻(消失判定宽限基准)。
  DateTime? _sessionAdoptedAt;

  void _showDeviceSwitcher() {
    showModalBottomSheet(
      context: context,
      builder: (context) => _DeviceSwitchSheet(
        session: widget.session,
        store: widget.store,
      ),
    );
  }

  /// 抽屉工作区条 ⌄:底部升起工作区切换层(spec §7.1;设备切换在顶栏,
  /// 工作区切换在抽屉,与 bootstrap→workspaces→sessions 层级一致)。
  /// [sessionCount] 为当前工作区实时会话数(抽屉的 sessions-index 订阅)。
  void _showWorkspaceSwitcher(int sessionCount) {
    final active = _activeWorkspace;
    showModalBottomSheet(
      context: context,
      builder: (context) => _WorkspaceSwitchSheet(
        workspaces: _workspaces,
        activeKey: active == null ? null : workspaceKeyOf(active),
        activeSessionCount: sessionCount,
        onPick: (w) {
          Navigator.pop(context);
          _switchWorkspace(w);
        },
      ),
    );
  }

  Future<void> _pickWorkspace(Map<String, dynamic> workspace) async {
    final key = workspaceKeyOf(workspace);
    if (key == null || widget.session.client == null) return;
    final gen = ++_chainGeneration;
    _teardownDeviceState();
    setState(() => _resetSessionState());
    await _openWorkspace(workspace, gen);
  }

  /// 同一设备内切换工作区:作废在途链、释放旧 bridge、重开新 bridge。
  Future<void> _switchWorkspace(Map<String, dynamic> workspace) async {
    final key = workspaceKeyOf(workspace);
    final active = _activeWorkspace;
    if (key == null || (active != null && key == workspaceKeyOf(active))) {
      return;
    }
    final gen = ++_chainGeneration;
    _teardownDeviceState();
    setState(() => _resetSessionState());
    await _openWorkspace(workspace, gen);
  }

  void _retryConnect() {
    final account = widget.session.current ??
        (widget.store.accounts.isEmpty ? null : widget.store.accounts.first);
    if (account != null) _openAccount(account);
  }

  /// Settings entry: drop the active device's connection. The shell stays
  /// mounted (it is the app home) and shows the disconnected state.
  void _disconnectCurrent() {
    final account = widget.session.current;
    if (account != null) widget.session.disconnect(account.id);
  }

  @override
  Widget build(BuildContext context) {
    final colors = EmberColors.of(context);
    final session = widget.session;
    final bridge = _bridge;
    final workspace = _activeWorkspace;
    final chatMounted = _chatMounted(session, bridge, workspace);
    return Scaffold(
      backgroundColor: colors.bg,
      body: PopScope(
        // Back behavior under home mounting: on the conversations tab the
        // system back exits as usual (canPop=true lets the root route pop),
        // unless the session drawer is open — back closes it first; on other
        // tabs back is intercepted and returns to conversations.
        canPop: _tab == 0 && !_drawerOpen,
        onPopInvokedWithResult: (didPop, result) {
          if (didPop) return;
          setState(() {
            if (_drawerOpen) {
              _drawerOpen = false;
            } else {
              _tab = 0;
            }
          });
        },
        child: SafeArea(
          child: Column(
            children: [
              // 对话 Tab 且内嵌聊天已挂载时,顶栏由 ChatPage 自绘(模型
              // pill/停止/溢出菜单需要会话订阅,见 ChatPage._embeddedHeader);
              // 其余状态与 Tab 用共享 _TopBar(工作区名 + 管理设备)。
              if (!chatMounted)
                _TopBar(
                  account: session.current,
                  workspaceName:
                      workspace == null ? null : workspaceTitle(workspace),
                  onSwitch: _showDeviceSwitcher,
                  onManageDevices: _openDeviceManagement,
                ),
              if (session.client != null)
                _ConnectionBanner(client: session.client!),
              Expanded(
                child: switch (_tab) {
                  0 => _conversationsTab(context, bridge),
                  1 => bridge == null || workspace == null
                      ? _mutedHint(
                          session.client == null
                              ? '连接设备后可用'
                              : '选择工作区后可用',
                          colors)
                      : AutomationPage(
                          key: ValueKey(
                              'auto-${workspaceKeyOf(workspace)}'),
                          bridge: bridge,
                          workspace: workspace,
                          onOpenTask: (taskId, title) =>
                              _openTaskChat(bridge, _chainGeneration, taskId, title),
                        ),
                  _ => SettingsPage(
                      client: session.client,
                      bridge: bridge,
                      store: widget.store,
                      session: session,
                      onDisconnect: _disconnectCurrent,
                      themeController: ThemeControllerProvider.of(context),
                    ),
                },
              ),
            ],
          ),
        ),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) =>
            setState(() {
              _tab = i;
              _drawerOpen = false; // 抽屉仅对话 Tab 有,离开即收
            }),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.forum_outlined),
            selectedIcon: Icon(Icons.forum),
            label: '对话',
          ),
          NavigationDestination(
            icon: Icon(Icons.schedule_outlined),
            selectedIcon: Icon(Icons.schedule),
            label: '自动化',
          ),
          NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings),
            label: '设置',
          ),
        ],
      ),
    );
  }

  /// 设备管理页(home 挂载下 push,无可 pop 回的设备页)。
  void _openDeviceManagement() {
    final workspace = _activeWorkspace;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => DeviceManagementPage(
          store: widget.store,
          session: widget.session,
          // 当前活跃设备已打开的工作区(spec §7.3 设备卡字段);
          // 未打开工作区时为 null,卡片不显示该行。
          activeWorkspaceTitle:
              workspace == null ? null : workspaceTitle(workspace),
        ),
      ),
    );
  }

  /// 对话 Tab 的内嵌聊天是否已挂载(挂载时顶栏由 ChatPage 自绘,
  /// 设备胶囊经 headerLeading 注入)。
  bool _chatMounted(
    AppSession session,
    BridgeSession? bridge,
    Map<String, dynamic>? workspace,
  ) =>
      _tab == 0 &&
      _phase == _ConnectPhase.done &&
      session.current != null &&
      bridge != null &&
      workspace != null;

  Widget _conversationsTab(BuildContext context, BridgeSession? bridge) {
    final colors = EmberColors.of(context);
    final session = widget.session;
    final workspace = _activeWorkspace;
    final account = session.current;
    if (account == null) {
      // 设备缺席的三种形态:没设备(引导添加)/首次连接进行中(转圈)/
      // 连接失败(重试)/曾连上后被挤下线或断开(断开态守卫)。
      if (widget.store.accounts.isEmpty) {
        return _EmptyDevices(onAddDevice: _openDeviceManagement);
      }
      switch (_phase) {
        case _ConnectPhase.connecting:
          return _connectingView(colors);
        case _ConnectPhase.failed:
          return _failedView(colors);
        default:
          return _DisconnectedView(onRetry: _retryConnect);
      }
    }
    switch (_phase) {
      case _ConnectPhase.connecting:
        return _connectingView(colors);
      case _ConnectPhase.failed:
        return _failedView(colors);
      case _ConnectPhase.done:
        if (bridge != null && workspace != null) {
          final sessionId = _activeSessionId.value;
          // 对话 Tab 常驻内嵌 ChatPage(null = draft 新会话,首条消息
          // createSession);会话列表收进左缘抽屉(T2 移交:会话内唯一
          // 的列表入口)。
          return _DrawerHost(
            open: _drawerOpen,
            onOpen: _openDrawer,
            onDismiss: _closeDrawer,
            drawer: SessionDrawer(
              open: _drawerOpen,
              bridge: bridge,
              scope: _scopeOf(workspace),
              workspaceName: workspaceTitle(workspace),
              workspacePath: workspace['workspacePath'] as String? ?? '',
              currentSessionId: sessionId,
              onPick: _pickFromDrawer,
              onSwitchWorkspace: _showWorkspaceSwitcher,
              onCurrentSessionVanished: _onCurrentSessionVanished,
              onManageDevices: () {
                _closeDrawer();
                _openDeviceManagement();
              },
              deviceCount: widget.store.accounts.length,
              deviceOnline: session.client != null,
            ),
            child: ChatPage(
              key: ValueKey(_sessionEpoch),
              embedded: true,
              session: bridge,
              scope: _scopeOf(workspace),
              workspaceKey: workspaceKeyOf(workspace) ?? '',
              sessionId: sessionId,
              title: _activeSessionTitle.value ?? '新会话',
              onSessionInfo: _onSessionInfo,
              sessionEpoch: _sessionEpoch,
              headerLeading: _DeviceCapsule(
                account: session.current,
                onTap: _showDeviceSwitcher,
              ),
              headerTitle: _activeSessionTitle,
              headerWorkspace: workspaceTitle(workspace),
              onOpenDrawer: _openDrawer,
            ),
          );
        }
        // 已连接但未进入工作区:列出可选工作区(U1 连接完成不直接
        // 开会话,由用户选择工作区后再经抽屉选会话)。bridge 是工作区
        // 级的,此刻必为 null,按 relay client 在线判定。
        if (session.client != null) {
          return _WorkspacePicker(
            workspaces: _workspaces,
            onPick: (w) => _pickWorkspace(w),
          );
        }
        return _mutedHint('设备未连接', colors);
      case _ConnectPhase.idle:
        return _mutedHint('设备未连接', colors);
    }
  }

  Widget _connectingView(EmberColors colors) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(height: EmberSpacing.gapM),
          Text('连接设备中…',
              style: TextStyle(
                  fontSize: EmberType.caption, color: colors.textMuted)),
        ],
      ),
    );
  }

  Widget _failedView(EmberColors colors) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: EmberSpacing.page),
            child: Text(
              '连接失败: ${_connectError ?? ''}',
              textAlign: TextAlign.center,
              style:
                  TextStyle(fontSize: EmberType.caption, color: colors.err),
            ),
          ),
          const SizedBox(height: EmberSpacing.gapM),
          TextButton(
            onPressed: _retryConnect,
            style: TextButton.styleFrom(foregroundColor: colors.primary),
            child: const Text('重试'),
          ),
        ],
      ),
    );
  }

  Widget _mutedHint(String text, EmberColors colors) {
    return Center(
      child: Text(text,
          style:
              TextStyle(fontSize: EmberType.caption, color: colors.textMuted)),
    );
  }
}

/// 连接完成、尚未进入工作区时的工作区选择列表(U1:连接后不直接开会话,
/// 先选工作区,再由抽屉选会话或开新会话)。
class _WorkspacePicker extends StatelessWidget {
  final List<dynamic> workspaces;
  final void Function(Map<String, dynamic> workspace) onPick;

  const _WorkspacePicker({required this.workspaces, required this.onPick});

  @override
  Widget build(BuildContext context) {
    final colors = EmberColors.of(context);
    return Material(
      color: colors.bg,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                  EmberSpacing.page, EmberSpacing.gapM, EmberSpacing.page,
                  EmberSpacing.gapS),
              child: Text('选择工作区',
                  style: TextStyle(
                      fontSize: EmberType.title,
                      fontWeight: FontWeight.w600,
                      color: colors.textSolid)),
            ),
            Expanded(
              child: workspaces.isEmpty
                  ? Center(
                      child: Text('桌面端没有可用的工作区',
                          style: TextStyle(
                              fontSize: EmberType.caption,
                              color: colors.textMuted)))
                  : ListView(
                      padding: const EdgeInsets.fromLTRB(
                          EmberSpacing.page, 0, EmberSpacing.page,
                          EmberSpacing.page),
                      children: [
                        for (final w in workspaces)
                          if (w is Map)
                            ListTile(
                              shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(
                                      EmberRadius.control)),
                              leading: Icon(Icons.folder_open,
                                  size: 20, color: colors.primary),
                              title: Text(workspaceTitle(
                                  w.cast<String, dynamic>()),
                                  style: TextStyle(
                                      fontSize: EmberType.body,
                                      fontWeight: FontWeight.w600,
                                      color: colors.textSolid)),
                              subtitle: w['workspacePath'] != null &&
                                      '${w['workspacePath']}'.isNotEmpty
                                  ? Text('${w['workspacePath']}',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                          fontSize: EmberType.caption,
                                          fontFamily: EmberFonts.term,
                                          color: colors.textFaint))
                                  : null,
                              onTap: () => onPick(w.cast<String, dynamic>()),
                            ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 顶栏(共享形态,对话 Tab 内嵌聊天挂载时由 ChatPage 自绘顶栏):
/// 设备切换胶囊(头像 + 设备名 + ▾)+ 工作区名 + 管理设备。
class _TopBar extends StatelessWidget {
  final Account? account;
  final String? workspaceName;
  final VoidCallback onSwitch;
  final VoidCallback onManageDevices;

  const _TopBar({
    required this.account,
    required this.workspaceName,
    required this.onSwitch,
    required this.onManageDevices,
  });

  @override
  Widget build(BuildContext context) {
    final colors = EmberColors.of(context);
    final host = account?.params?.source.host ?? '';
    return Material(
      color: colors.bg,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(EmberSpacing.page, EmberSpacing.gapS,
            EmberSpacing.page, EmberSpacing.gapS),
        child: Row(
          children: [
            _DeviceCapsule(account: account, onTap: onSwitch),
            const SizedBox(width: EmberSpacing.gapM),
            Expanded(
              child: Text(
                workspaceName ?? host,
                style: TextStyle(
                    fontSize: EmberType.secondary, color: colors.textMuted),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            IconButton(
              icon: const Icon(Icons.devices_other, size: 20),
              tooltip: '管理设备',
              onPressed: onManageDevices,
            ),
          ],
        ),
      ),
    );
  }
}

/// 设备切换胶囊(头像圆 + 设备名 + ▾):顶栏与内嵌聊天顶栏共用,
/// 点按下拉切换/管理设备(spec §7.1)。
class _DeviceCapsule extends StatelessWidget {
  final Account? account;
  final VoidCallback onTap;

  const _DeviceCapsule({required this.account, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final colors = EmberColors.of(context);
    final label = account?.label ?? '未连接设备';
    return InkWell(
      borderRadius: BorderRadius.circular(EmberRadius.control),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(
            horizontal: EmberSpacing.gapS, vertical: 5),
        decoration: BoxDecoration(
          color: colors.card,
          borderRadius: BorderRadius.circular(EmberRadius.control),
          border: Border.all(color: colors.hairline),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 22,
              height: 22,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: colors.primary,
                borderRadius: BorderRadius.circular(EmberRadius.avatar),
              ),
              child: Text(
                label.isEmpty ? '?' : label[0],
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: Colors.white,
                ),
              ),
            ),
            const SizedBox(width: EmberSpacing.gapS),
            Flexible(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: EmberType.body,
                  fontWeight: FontWeight.w600,
                  color: colors.textSolid,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Icon(Icons.arrow_drop_down, size: 18, color: colors.textMuted),
          ],
        ),
      ),
    );
  }
}

/// 无设备空态:引导返回设备页添加设备。
class _EmptyDevices extends StatelessWidget {
  final VoidCallback onAddDevice;

  const _EmptyDevices({required this.onAddDevice});

  @override
  Widget build(BuildContext context) {
    final colors = EmberColors.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                color: colors.primary.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(20),
              ),
              child:
                  Icon(Icons.desktop_windows_outlined, size: 34, color: colors.primary),
            ),
            const SizedBox(height: EmberSpacing.gapM),
            Text('还没有设备',
                style: TextStyle(
                    fontSize: EmberType.section,
                    fontWeight: FontWeight.w600,
                    color: colors.textSolid)),
            const SizedBox(height: EmberSpacing.gapS),
            Text(
              '先去添加一台设备，再回到这里开始对话',
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: EmberType.caption,
                  color: colors.textFaint,
                  height: EmberType.lineHeight),
            ),
            const SizedBox(height: EmberSpacing.gapM),
            FilledButton.icon(
              onPressed: onAddDevice,
              icon: const Icon(Icons.add, size: 18),
              label: const Text('添加设备'),
            ),
          ],
        ),
      ),
    );
  }
}

/// 设备缺席守卫:壳常驻 home 无设备页可退,首次添加设备后尚未连接、或
/// 曾连上后被挤下线/断开,都落到这个中性空态页。
class _DisconnectedView extends StatelessWidget {
  final VoidCallback onRetry;

  const _DisconnectedView({required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final colors = EmberColors.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.link_off, size: 44, color: colors.textFaint),
            const SizedBox(height: EmberSpacing.gapM),
            Text('设备未连接',
                style: TextStyle(
                    fontSize: EmberType.section,
                    fontWeight: FontWeight.w600,
                    color: colors.textSolid)),
            const SizedBox(height: EmberSpacing.gapS),
            Text('设备尚未连接，或连接已断开',
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: EmberType.caption,
                    color: colors.textFaint,
                    height: EmberType.lineHeight)),
            const SizedBox(height: EmberSpacing.gapM),
            FilledButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('连接设备'),
            ),
          ],
        ),
      ),
    );
  }
}

/// 会话抽屉宿主:内容 + 左缘 24px 把手(右滑呼出)+ 遮罩 + 76% 宽抽屉
/// 面板(200ms ease-out 平移,spec §5 唯二动效)。关闭动画结束后摘除
/// 面板;开抽屉时系统 back 由壳的 PopScope 拦截为收抽屉。
class _DrawerHost extends StatefulWidget {
  final Widget child;
  final Widget drawer;
  final bool open;
  final VoidCallback onOpen;
  final VoidCallback onDismiss;

  const _DrawerHost({
    required this.child,
    required this.drawer,
    required this.open,
    required this.onOpen,
    required this.onDismiss,
  });

  @override
  State<_DrawerHost> createState() => _DrawerHostState();
}

class _DrawerHostState extends State<_DrawerHost>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<Offset> _slide;

  /// 面板是否在树上。首次打开后常驻(关闭仅滑出屏幕):抽屉数据源
  /// (订阅/置顶/任务列表)随宿主实时推进,再次打开即完整渲染,不再
  /// 每次 mount 从种子/空列表重建造成可见跳变。
  bool _shown = false;

  /// 左缘把手本次拖拽的累计水平位移。
  double _edgeDx = 0;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
      value: widget.open ? 1.0 : 0.0,
    );
    _slide = Tween(begin: const Offset(-1, 0), end: Offset.zero).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOut),
    );
    _shown = widget.open;
    // dismissed 不再摘除(_shown 常驻);关闭态由 SlideTransition 移出
    // 屏幕并 IgnorePointer。
  }

  @override
  void didUpdateWidget(_DrawerHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.open == oldWidget.open) return;
    if (widget.open) {
      setState(() => _shown = true);
      _controller.forward();
    } else {
      _controller.reverse();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      final width = constraints.maxWidth * 0.76;
      return Stack(
        children: [
          Positioned.fill(child: widget.child),
          // 左缘把手:仅在关闭时可交互;widget 恒在(带 IgnorePointer),
          // Stack children 形状恒定——此前"开关时 handle/遮罩/面板条件
          // 挂载"导致 Element 位错,SessionDrawer 被反复重挂重建(列表
          // 每次开关都重排的根因)。translucent:把手只认拖拽。
          Positioned(
            left: 0,
            top: 0,
            bottom: 0,
            width: 24,
            child: IgnorePointer(
              ignoring: widget.open || _shown,
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onHorizontalDragStart: (_) => _edgeDx = 0,
                onHorizontalDragUpdate: (d) => _edgeDx += d.delta.dx,
                onHorizontalDragEnd: (details) {
                  // 位移为主(慢拖),速度兜底(快甩)。
                  if (_edgeDx > 48 || (details.primaryVelocity ?? 0) > 200) {
                    widget.onOpen();
                  }
                },
              ),
            ),
          ),
          // 遮罩+面板:首开后常驻(_shown 恒真),关闭=滑出+禁交互。
          // children 形状恒定 → SessionDrawer State 严格保活。
          if (_shown) ...[
            Positioned.fill(
              child: IgnorePointer(
                ignoring: !widget.open,
                child: GestureDetector(
                  onTap: widget.onDismiss,
                  child: AnimatedBuilder(
                    animation: _controller,
                    builder: (context, _) => ColoredBox(
                      color: Colors.black
                          .withValues(alpha: 0.32 * _controller.value),
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              child: IgnorePointer(
                ignoring: !widget.open,
                child: SizedBox(
                  width: width,
                  child: SlideTransition(
                    position: _slide,
                    child: widget.drawer,
                  ),
                ),
              ),
            ),
          ],
        ],
      );
    });
  }
}

/// 抽屉工作区切换层:列出该设备的全部工作区,活动项打勾并显示实时会话
/// 数(spec §7.1:设备切换在顶栏、工作区切换在抽屉)。会话数仅当前工作区
/// 可得(在途 sessions-index 订阅),其他工作区不显示徽标也不加占位。
class _WorkspaceSwitchSheet extends StatelessWidget {
  final List<dynamic> workspaces;
  final String? activeKey;

  /// 当前工作区实时会话数(宿主自抽屉订阅取)。
  final int activeSessionCount;
  final void Function(Map<String, dynamic> workspace) onPick;

  const _WorkspaceSwitchSheet({
    required this.workspaces,
    required this.activeKey,
    required this.activeSessionCount,
    required this.onPick,
  });

  @override
  Widget build(BuildContext context) {
    final colors = EmberColors.of(context);
    final items = [
      for (final w in workspaces)
        if (w is Map) w.cast<String, dynamic>(),
    ];
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text('切换工作区',
                  style: TextStyle(
                      fontSize: EmberType.section,
                      fontWeight: FontWeight.w700,
                      color: colors.textSolid)),
            ),
          ),
          Flexible(
            child: ListView.separated(
              shrinkWrap: true,
              itemCount: items.length,
              separatorBuilder: (_, _) =>
                  const Divider(height: 1, indent: 16),
              itemBuilder: (context, index) {
                final w = items[index];
                final isActive = workspaceKeyOf(w) == activeKey;
                return ListTile(
                  leading: Icon(
                    isActive
                        ? Icons.folder
                        : Icons.folder_open,
                    color: isActive ? colors.primary : colors.textFaint,
                  ),
                  title: Row(
                    children: [
                      Flexible(
                        child: Text(workspaceTitle(w),
                            style: TextStyle(
                                color: colors.textSolid,
                                fontWeight: isActive
                                    ? FontWeight.w700
                                    : FontWeight.w400)),
                      ),
                      if (isActive) ...[
                        const SizedBox(width: EmberSpacing.gapS),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 1),
                          decoration: BoxDecoration(
                            color: colors.primary.withValues(alpha: 0.14),
                            borderRadius: BorderRadius.circular(5),
                          ),
                          child: Text('$activeSessionCount 会话',
                              style: TextStyle(
                                  fontSize: EmberType.caption,
                                  color: colors.primary)),
                        ),
                      ],
                    ],
                  ),
                  subtitle: w['workspacePath'] is String &&
                          (w['workspacePath'] as String).isNotEmpty
                      ? Text(w['workspacePath'],
                          style: TextStyle(
                              fontSize: 11,
                              fontFamily: EmberFonts.term,
                              color: colors.textFaint))
                      : null,
                  trailing: isActive
                      ? Icon(Icons.check_circle,
                          size: 18, color: colors.primary)
                      : null,
                  onTap: () => onPick(w),
                );
              },
            ),
          ),
          const SizedBox(height: EmberSpacing.gapS),
        ],
      ),
    );
  }
}

/// Bottom sheet: list all devices with per-device connect state; tap to
/// switch (or connect first). Non-active connected devices can be
/// disconnected individually.
class _DeviceSwitchSheet extends StatelessWidget {
  final AppSession session;
  final AccountStore store;

  const _DeviceSwitchSheet({
    required this.session,
    required this.store,
  });

  @override
  Widget build(BuildContext context) {
    final colors = EmberColors.of(context);
    return SafeArea(
      child: AnimatedBuilder(
        animation: Listenable.merge([session, store]),
        builder: (context, _) {
          final accounts = store.accounts;
          final activeId = session.current?.id;
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text('设备列表',
                      style: TextStyle(
                          fontSize: EmberType.section,
                          fontWeight: FontWeight.w700,
                          color: colors.textSolid)),
                ),
              ),
              Flexible(
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: accounts.length,
                  separatorBuilder: (_, _) =>
                      const Divider(height: 1, indent: 16),
                  itemBuilder: (context, index) {
                    final account = accounts[index];
                    final isActive = account.id == activeId;
                    final connected = session.isConnected(account.id);
                    final connecting = session.connecting(account.id);
                    final error = session.errorOf(account.id);
                    return ListTile(
                      leading: Icon(
                        isActive
                            ? Icons.desktop_windows
                            : Icons.desktop_windows_outlined,
                        color: isActive
                            ? colors.primary
                            : colors.textFaint,
                      ),
                      title: Text(account.label,
                          style: TextStyle(
                              color: colors.textSolid,
                              fontWeight: isActive
                                  ? FontWeight.w700
                                  : FontWeight.w400)),
                      subtitle: Text(
                        connecting
                            ? '正在连接…'
                            : error != null
                                ? '连接失败: $error'
                                : connected
                                    ? '已连接'
                                    : '未连接',
                        style: TextStyle(
                          fontSize: 11,
                          color: connecting
                              ? colors.warn
                              : error != null
                                  ? colors.err
                                  : connected
                                      ? colors.ok
                                      : colors.textFaint,
                        ),
                      ),
                      trailing: isActive
                          ? Icon(Icons.check_circle,
                              size: 18, color: colors.primary)
                          : connected
                              ? IconButton(
                                  icon: Icon(Icons.link_off,
                                      size: 18, color: colors.textFaint),
                                  tooltip: '断开该设备',
                                  onPressed: () =>
                                      session.disconnect(account.id),
                                )
                              : connecting
                                  ? const SizedBox(
                                      width: 18,
                                      height: 18,
                                      child: CircularProgressIndicator(
                                          strokeWidth: 2),
                                    )
                                  : null,
                      onTap: () async {
                        if (isActive) {
                          Navigator.pop(context);
                          return;
                        }
                        try {
                          await session.switchTo(account);
                          if (context.mounted) Navigator.pop(context);
                        } catch (e) {
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(content: Text('连接失败: $e')));
                          }
                        }
                      },
                    );
                  },
                ),
              ),
              const SizedBox(height: EmberSpacing.gapS),
            ],
          );
        },
      ),
    );
  }
}

class _ConnectionBanner extends StatelessWidget {
  final ZflowClient client;

  const _ConnectionBanner({required this.client});

  @override
  Widget build(BuildContext context) {
    final colors = EmberColors.of(context);
    return ValueListenableBuilder<RelayState>(
      valueListenable: client.relay.stateListenable,
      builder: (context, state, _) {
        final (color, icon, text) = switch (state) {
          RelayState.reconnecting => (
              colors.warn,
              Icons.sync,
              '连接中断，正在自动重连…'
            ),
          RelayState.error => (
              colors.err,
              Icons.error_outline,
              '连接失败，请返回设备页重连'
            ),
          RelayState.kicked => (
              colors.err,
              Icons.error_outline,
              '连接已被其他终端挤下线'
            ),
          RelayState.waiting => (
              colors.run,
              Icons.hourglass_top,
              '等待桌面端确认配对…'
            ),
          _ => (Colors.transparent, Icons.check, ''),
        };
        if (text.isEmpty) return const SizedBox.shrink();
        // Only errors surface instantly; a reconnect that heals within 5s
        // (locked-screen resume, brief network flap) stays invisible.
        final content = _bannerContent(context, color, icon, text);
        if (state == RelayState.reconnecting) {
          return DelayedVisibility(
            visible: true,
            delay: const Duration(seconds: 5),
            builder: (context) => content,
          );
        }
        return content;
      },
    );
  }

  Widget _bannerContent(
      BuildContext context, Color color, IconData icon, String text) {
    return Container(
      width: double.infinity,
      color: color.withValues(alpha: 0.15),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Row(
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: EmberSpacing.gapS),
          Expanded(
            child: Text(text,
                style: TextStyle(
                    fontSize: EmberType.secondary, color: color)),
          ),
        ],
      ),
    );
  }
}
