import 'dart:async';

import 'package:flutter/material.dart';

import '../notifications/notifications.dart';
import '../notifications/task_notifier.dart';
import '../protocol/relay_client.dart';
import '../protocol/zemote_client.dart';
import '../state/account_store.dart';
import '../state/app_session.dart';
import 'automation_page.dart';
import 'chat_page.dart';
import 'conversation_list_page.dart';
import 'delayed_banner.dart';
import 'settings_page.dart';
import 'theme.dart';

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
  bool _bridgeOpening = false;
  StreamSubscription? _updatedSub;
  TaskNotifier? _taskNotifier;
  AppLifecycleListener? _lifecycle;

  /// 当前壳已加载/正在加载的设备 id(防止 session 通知重复触发引导链)。
  String? _loadedAccountId;
  bool _chainInFlight = false;

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
    }
  }

  @override
  void dispose() {
    widget.session.removeListener(_onSessionChanged);
    widget.store.removeListener(_onChanged);
    _lifecycle?.dispose();
    _teardownDeviceState();
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  /// Active device changed (auto-connect finished, or a sheet switch):
  /// bootstrap the shell for the new device.
  void _onSessionChanged() {
    if (!mounted) return;
    setState(() {});
    final account = widget.session.current;
    if (account != null && account.id != _loadedAccountId) {
      _openAccount(account);
    }
  }

  /// Connect (or reuse) [account]'s device, then bootstrap workspaces and
  /// auto-open the first one. Runs at most once at a time.
  Future<void> _openAccount(Account account) async {
    if (_chainInFlight) return;
    _chainInFlight = true;
    _loadedAccountId = account.id;
    _teardownDeviceState();
    setState(() {
      _phase = _ConnectPhase.connecting;
      _connectError = null;
      _workspaces = const [];
      _activeWorkspace = null;
      _bridge = null;
    });
    try {
      final client = await widget.session.connect(account);
      if (!mounted) return;
      _resubscribe(client);
      final bootstrap = await client.bootstrap();
      if (!mounted) return;
      final list = bootstrap['workspaces'];
      setState(() => _workspaces = list is List ? list : const []);
      // Auto-open a workspace (web mobile flow): the only one, else the first.
      for (final w in _workspaces) {
        if (w is Map) {
          await _openWorkspace(w.cast<String, dynamic>());
          break;
        }
      }
      if (!mounted) return;
      setState(() => _phase = _ConnectPhase.done);
    } catch (e) {
      _loadedAccountId = null;
      if (!mounted) return;
      setState(() {
        _phase = _ConnectPhase.failed;
        _connectError = '$e';
      });
    } finally {
      _chainInFlight = false;
    }
  }

  void _teardownDeviceState() {
    _updatedSub?.cancel();
    _updatedSub = null;
    _taskNotifier?.dispose();
    _taskNotifier = null;
    _bridge?.dispose();
    _bridge = null;
    _activeWorkspace = null;
  }

  void _resubscribe(ZemoteClient client) {
    _updatedSub?.cancel();
    _updatedSub = client.workspaceListUpdated.listen((result) {
      if (!mounted || result is! Map) return;
      final list = result['workspaces'];
      if (list is List) setState(() => _workspaces = list);
    });
  }

  Future<void> _openWorkspace(Map<String, dynamic> workspace) async {
    final key = workspaceKeyOf(workspace);
    final client = widget.session.client;
    if (key == null || client == null || _bridgeOpening) return;
    setState(() => _bridgeOpening = true);
    try {
      final session = await client.openBridge(key);
      if (!mounted) {
        session.dispose();
        return;
      }
      setState(() {
        _bridge = session;
        _activeWorkspace = workspace;
        _bridgeOpening = false;
      });
      _startTaskNotifier(session, workspace);
    } catch (e) {
      if (!mounted) return;
      setState(() => _bridgeOpening = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('打开工作区失败: $e')));
    }
  }

  /// Background task notifications: while tasks are running, a silent
  /// foreground-service notification shows live progress and completion
  /// alerts route back into the task's chat (Android only).
  void _startTaskNotifier(BridgeSession bridge, Map<String, dynamic> workspace) {
    if (!Notifications.isSupported || _taskNotifier != null) return;
    final scope = _scopeOf(workspace);
    final workspaceKey = workspaceKeyOf(workspace) ?? '';
    _taskNotifier = TaskNotifier(
      bridge: bridge,
      scope: scope,
      notifications: notificationsService,
      onOpenTask: (taskId, title) async {
        final navigator = Navigator.of(context);
        navigator.push(
          MaterialPageRoute(
            builder: (_) => ChatPage(
              session: bridge,
              scope: scope,
              workspaceKey: workspaceKey,
              sessionId: taskId,
              title: title,
            ),
          ),
        );
      },
    )..start();
  }

  /// Opens a task chat pushed on top of the shell (automation run history).
  void _openTaskChat(BridgeSession bridge, String taskId, String title) {
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

  void _showDeviceSwitcher() {
    showModalBottomSheet(
      context: context,
      builder: (context) => _DeviceSwitchSheet(
        session: widget.session,
        store: widget.store,
      ),
    );
  }

  Future<void> _confirmExit() async {
    final exit = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('返回设备列表？'),
        content: const Text('连接会保持，稍后可直接回到当前设备'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('留在这里')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('返回')),
        ],
      ),
    );
    if (exit == true && mounted) {
      Navigator.of(context).pop();
    }
  }

  void _retryConnect() {
    final account = widget.session.current ??
        (widget.store.accounts.isEmpty ? null : widget.store.accounts.first);
    if (account != null) _openAccount(account);
  }

  void _disconnectCurrent() {
    final account = widget.session.current;
    if (account != null) widget.session.disconnect(account.id);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final colors = EmberColors.of(context);
    final session = widget.session;
    final bridge = _bridge;
    final workspace = _activeWorkspace;
    return Scaffold(
      backgroundColor: colors.bg,
      body: PopScope(
        // Predictable back behavior instead of silently exiting:
        // any tab -> conversations tab -> confirm exit.
        canPop: false,
        onPopInvokedWithResult: (didPop, result) {
          if (didPop) return;
          if (_tab != 0) {
            setState(() => _tab = 0);
            return;
          }
          _confirmExit();
        },
        child: SafeArea(
          child: Column(
            children: [
              _TopBar(
                account: session.current,
                workspaceName:
                    workspace == null ? null : workspaceTitle(workspace),
                onSwitch: _showDeviceSwitcher,
              ),
              if (session.client != null)
                _ConnectionBanner(client: session.client!),
              Expanded(
                child: switch (_tab) {
                  0 => _conversationsTab(context, bridge),
                  1 => bridge == null || workspace == null
                      ? _mutedHint('连接设备后可用', colors)
                      : AutomationPage(
                          key: ValueKey(
                              'auto-${workspaceKeyOf(workspace)}'),
                          bridge: bridge,
                          workspace: workspace,
                          onOpenTask: (taskId, title) =>
                              _openTaskChat(bridge, taskId, title),
                        ),
                  _ => SettingsPage(
                      client: session.client,
                      bridge: bridge,
                      onDisconnect: _disconnectCurrent,
                      themeController: ThemeControllerProvider.of(context),
                    ),
                },
              ),
            ],
          ),
        ),
      ),
      bottomNavigationBar: NavigationBarTheme(
        data: NavigationBarThemeData(
          backgroundColor: colors.card,
          indicatorColor: colors.primary.withValues(alpha: 0.18),
          iconTheme: WidgetStateProperty.resolveWith(
            (states) => IconThemeData(
              size: 22,
              color: states.contains(WidgetState.selected)
                  ? colors.primary
                  : colors.textMuted,
            ),
          ),
          labelTextStyle: WidgetStateProperty.resolveWith(
            (states) => TextStyle(
              fontSize: EmberType.caption,
              fontFamily: EmberFonts.ui,
              fontWeight: states.contains(WidgetState.selected)
                  ? FontWeight.w600
                  : FontWeight.w400,
              color: states.contains(WidgetState.selected)
                  ? colors.primary
                  : colors.textMuted,
            ),
          ),
        ),
        child: NavigationBar(
          selectedIndex: _tab,
          onDestinationSelected: (i) => setState(() => _tab = i),
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
      ),
    );
  }

  Widget _conversationsTab(BuildContext context, BridgeSession? bridge) {
    final colors = EmberColors.of(context);
    final session = widget.session;
    final workspace = _activeWorkspace;
    if (session.current == null && widget.store.accounts.isEmpty) {
      return _EmptyDevices(onAddDevice: () => Navigator.of(context).pop());
    }
    switch (_phase) {
      case _ConnectPhase.connecting:
      case _ConnectPhase.idle when _bridgeOpening:
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
      case _ConnectPhase.failed:
        return Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: EmberSpacing.page),
                child: Text(
                  '连接失败: ${_connectError ?? ''}',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      fontSize: EmberType.caption, color: colors.err),
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
      case _ConnectPhase.done:
        if (bridge != null && workspace != null) {
          return ConversationListPage(
            key: ValueKey(workspaceKeyOf(workspace)),
            bridge: bridge,
            scope: _scopeOf(workspace),
            workspaceKey: workspaceKeyOf(workspace) ?? '',
          );
        }
        return _mutedHint('桌面端没有打开的工作区', colors);
      case _ConnectPhase.idle:
        return _mutedHint('设备未连接', colors);
    }
  }

  Widget _mutedHint(String text, EmberColors colors) {
    return Center(
      child: Text(text,
          style:
              TextStyle(fontSize: EmberType.caption, color: colors.textMuted)),
    );
  }
}

/// 顶栏:设备切换胶囊(头像圆 + 设备名 + ▾)+ 当前工作区名。
class _TopBar extends StatelessWidget {
  final Account? account;
  final String? workspaceName;
  final VoidCallback onSwitch;

  const _TopBar({
    required this.account,
    required this.workspaceName,
    required this.onSwitch,
  });

  @override
  Widget build(BuildContext context) {
    final colors = EmberColors.of(context);
    final label = account?.label ?? '未连接设备';
    final host = account?.params?.source.host ?? '';
    return Material(
      color: colors.bg,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(EmberSpacing.page, EmberSpacing.gapS,
            EmberSpacing.page, EmberSpacing.gapS),
        child: Row(
          children: [
            InkWell(
              borderRadius: BorderRadius.circular(EmberRadius.control),
              onTap: onSwitch,
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
                        borderRadius:
                            BorderRadius.circular(EmberRadius.avatar),
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
                    Icon(Icons.arrow_drop_down,
                        size: 18, color: colors.textMuted),
                  ],
                ),
              ),
            ),
            const SizedBox(width: EmberSpacing.gapM),
            Expanded(
              child: Text(
                workspaceName ?? host,
                style: TextStyle(
                    fontSize: EmberType.secondary, color: colors.textMuted),
                overflow: TextOverflow.ellipsis,
              ),
            ),
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
                  separatorBuilder: (_, __) =>
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
  final ZemoteClient client;

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
