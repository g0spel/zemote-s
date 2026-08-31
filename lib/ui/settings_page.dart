import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../protocol/relay_client.dart';
import '../protocol/zflow_client.dart';
import '../notifications/notifications.dart';
import '../notifications/unread.dart';
import '../state/account_store.dart';
import '../state/app_session.dart';
import '../state/background_prefs.dart';
import '../state/crash_report.dart';
import '../state/log_store.dart';
import '../update/app_version.dart';
import '../update/update_checker.dart';
import '../update/update_dialog.dart';
import 'channel_explorer_page.dart';
import 'device_management_page.dart';
import 'log_page.dart';
import 'model_providers_page.dart';
import 'rpc_explorer_page.dart';
import 'services_page.dart';
import 'theme.dart';
import 'ui_settings.dart';
import 'usage_page.dart';

/// Builds a `{workspacePath, workspaceIdentity?}` scope from a bridge.
Map<String, dynamic> _scopeOf(BridgeSession session) => {
      'workspacePath': session.bridge['workspacePath'],
      if (session.bridge['workspaceIdentity'] != null)
        'workspaceIdentity': session.bridge['workspaceIdentity'],
    };

/// 行组内统一的行导航箭头(与 leading 图标同为 20 档)。
const _chevron = Icon(Icons.chevron_right, size: 20);

/// 设置页(spec §7.3):外观 / 设备与连接 / 模型 / 关于 四组行组,
/// 控制区规范:card 底 + hairline + 小圆角,分组小标题间距字。
class SettingsPage extends StatelessWidget {
  final ZflowClient? client;
  final BridgeSession? bridge;
  final AccountStore store;
  final AppSession session;
  final VoidCallback onDisconnect;
  final ThemeController? themeController;

  const SettingsPage({
    super.key,
    this.client,
    this.bridge,
    required this.store,
    required this.session,
    required this.onDisconnect,
    this.themeController,
  });

  @override
  Widget build(BuildContext context) {
    final controller = themeController;
    final ui = UiSettingsProvider.of(context);
    final colors = EmberColors.of(context);
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Text(tr(context, 'settings.title'),
            style: const TextStyle(
                fontSize: EmberType.title, fontWeight: FontWeight.w700)),
        const SizedBox(height: 20),
        if (controller != null) ...[
          _groupTitle(context, '外观'),
          _GroupCard(
            children: [
              Padding(
                padding: const EdgeInsets.all(EmberSpacing.cardPad),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(tr(context, 'settings.appearance'),
                        style: TextStyle(
                            fontSize: EmberType.body,
                            fontWeight: FontWeight.w600,
                            color: colors.textSolid)),
                    const SizedBox(height: EmberSpacing.gapM),
                    AnimatedBuilder(
                      animation: controller,
                      builder: (context, _) => SegmentedButton<ThemeMode>(
                        segments: [
                          ButtonSegment(
                              value: ThemeMode.dark,
                              icon: const Icon(Icons.dark_mode_outlined,
                                  size: 16),
                              label: Text(tr(context, 'settings.theme.dark'),
                                  style: const TextStyle(
                                      fontSize: EmberType.secondary))),
                          ButtonSegment(
                              value: ThemeMode.light,
                              icon: const Icon(Icons.light_mode_outlined,
                                  size: 16),
                              label: Text(tr(context, 'settings.theme.light'),
                                  style: const TextStyle(
                                      fontSize: EmberType.secondary))),
                          ButtonSegment(
                              value: ThemeMode.system,
                              icon: const Icon(Icons.settings_suggest_outlined,
                                  size: 16),
                              label:
                                  Text(tr(context, 'settings.theme.system'),
                                      style: const TextStyle(
                                          fontSize:
                                              EmberType.secondary))),
                        ],
                        selected: {controller.mode},
                        onSelectionChanged: (modes) =>
                            controller.setMode(modes.first),
                        style: const ButtonStyle(
                          visualDensity: VisualDensity.compact,
                          textStyle: WidgetStatePropertyAll(
                              TextStyle(fontSize: EmberType.secondary)),
                          iconSize: WidgetStatePropertyAll(16),
                        ),
                      ),
                    ),
                    if (ui != null) ...[
                      const SizedBox(height: 16),
                      Text(tr(context, 'settings.language'),
                          style: TextStyle(
                              fontSize: EmberType.body,
                              color: colors.textSoft)),
                      const SizedBox(height: 8),
                      AnimatedBuilder(
                        animation: ui,
                        builder: (context, _) =>
                            SegmentedButton<String>(
                          segments: const [
                            ButtonSegment(
                                value: 'zh-CN',
                                label: Text('中文',
                                    style: TextStyle(
                                        fontSize: EmberType.secondary))),
                            ButtonSegment(
                                value: 'en-US',
                                label: Text('English',
                                    style: TextStyle(
                                        fontSize: EmberType.secondary))),
                          ],
                          selected: {ui.locale},
                          onSelectionChanged: (v) => ui.setLocale(v.first),
                          style: const ButtonStyle(
                            visualDensity: VisualDensity.compact,
                            textStyle: WidgetStatePropertyAll(
                                TextStyle(fontSize: EmberType.secondary)),
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      Text(
                          '${tr(context, 'settings.textScale')} · ${ui.textScale.toStringAsFixed(2)}x',
                          style: TextStyle(
                              fontSize: EmberType.body,
                              color: colors.textSoft)),
                      AnimatedBuilder(
                        animation: ui,
                        builder: (context, _) => Slider(
                          value: ui.textScale,
                          min: 0.8,
                          max: 1.4,
                          divisions: 12,
                          onChanged: ui.setTextScale,
                        ),
                      ),
                      Text(
                          '${tr(context, 'settings.codeFont')} · ${ui.codeFontSize.toStringAsFixed(1)}',
                          style: TextStyle(
                              fontSize: EmberType.body,
                              color: colors.textSoft)),
                      AnimatedBuilder(
                        animation: ui,
                        builder: (context, _) => Slider(
                          value: ui.codeFontSize,
                          min: 10,
                          max: 20,
                          divisions: 20,
                          onChanged: ui.setCodeFontSize,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
        ],
        _groupTitle(context, '设备与连接'),
        _GroupCard(
          children: [
            _DevicesTile(store: store, session: session),
            const Divider(indent: 52),
            const _VerboseFramesTile(),
            const Divider(indent: 52),
            const _DiagLogTile(),
          ],
        ),
        if (Notifications.isSupported) ...[
          const SizedBox(height: 12),
          _groupTitle(context, '后台与通知'),
          _GroupCard(
            children: const [
              _KeepAliveTile(),
              Divider(indent: 52),
              _WakeLockTile(),
              Divider(indent: 52),
              _BatteryWhitelistTile(),
              Divider(indent: 52),
              _NotifyToggle(kind: NotifyKind.approvals),
              Divider(indent: 52),
              _NotifyToggle(kind: NotifyKind.completions),
              Divider(indent: 52),
              _NotifyToggle(kind: NotifyKind.failures),
            ],
          ),
        ],
        if (bridge != null) ...[
          const SizedBox(height: 12),
          _groupTitle(context, '模型'),
          _GroupCard(
            children: [
              ListTile(
                leading: const Icon(Icons.model_training, size: 20),
                title: const Text('模型供应商'),
                subtitle: const Text('添加 / 启停 / 删除模型供应商'),
                trailing: _chevron,
                onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                        builder: (_) => ModelProvidersPage(
                              session: bridge!,
                              scope: _scopeOf(bridge!),
                            ))),
              ),
              const Divider(indent: 52),
              ListTile(
                leading: const Icon(Icons.query_stats, size: 20),
                title: const Text('用量'),
                subtitle: const Text('额度 / 配额限制 / 订阅详情'),
                trailing: _chevron,
                onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                        builder: (_) => UsagePage(session: bridge!))),
              ),
              const Divider(indent: 52),
              ListTile(
                leading: const Icon(Icons.extension_outlined, size: 20),
                title: const Text('服务管理'),
                subtitle: const Text('插件 / 技能 / 命令'),
                trailing: _chevron,
                onTap: () => Navigator.of(context)
                    .push(MaterialPageRoute(
                        builder: (_) => ServicesPage(
                              session: bridge!,
                              scope: _scopeOf(bridge!),
                            ))),
              ),
            ],
          ),
        ],
        const SizedBox(height: 12),
        _groupTitle(context, '关于'),
        _GroupCard(
          children: [
            ListTile(
              leading: const Icon(Icons.system_update_alt, size: 20),
              title: const Text('检查更新'),
              subtitle: const Text('当前版本 v$appVersion · 检测 GitHub 最新发布'),
              trailing: _chevron,
              onTap: () => _checkUpdates(context),
            ),
            const Divider(indent: 52),
            ListTile(
              leading: const Icon(Icons.monitor_heart_outlined, size: 20),
              title: const Text('诊断与日志'),
              subtitle: const Text('诊断日志 / 协议日志 / 调试器'),
              trailing: _chevron,
              onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                      builder: (_) =>
                          _DiagnosticsPage(client: client, bridge: bridge))),
            ),
            const Divider(indent: 52),
            ListTile(
              leading: const Icon(Icons.info_outline, size: 20),
              title: const Text('关于'),
              subtitle: const Text('Zflow v$appVersion · 协议复刻版'),
              trailing: _chevron,
              onTap: () => _showAbout(context),
            ),
          ],
        ),
        const SizedBox(height: 12),
        _GroupCard(
          children: [
            ListTile(
              leading: Icon(Icons.link_off,
                  color: EmberColors.of(context).err, size: 20),
              title: Text('断开当前设备',
                  style: TextStyle(
                      fontSize: EmberType.emphasis,
                      color: EmberColors.of(context).err)),
              onTap: onDisconnect,
            ),
          ],
        ),
        const SizedBox(height: 24),
      ],
    );
  }

  Widget _groupTitle(BuildContext context, String text) {
    final colors = EmberColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 6),
      child: Text(text.toUpperCase(),
          style: TextStyle(
              fontSize: EmberType.caption,
              letterSpacing: 2,
              color: colors.textMuted)),
    );
  }

  void _showAbout(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Zflow'),
        content: Text(
            'Zflow (Flutter) v$appVersion · 协议复刻版\n\n'
            'GitHub: https://github.com/g0spel/zflow'),
        actions: [
          TextButton(
            onPressed: () => _copyUrl(
                context, 'https://github.com/g0spel/zflow'),
            child: const Text('复制链接'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  Future<void> _copyUrl(BuildContext context, String url) async {
    await Clipboard.setData(ClipboardData(text: url));
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('已复制 GitHub 链接')));
    }
  }

  /// Manual update check: shows a spinner, then either the update prompt
  /// (Android: in-app APK download + install) or an up-to-date notice.
  Future<void> _checkUpdates(BuildContext context) async {
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(
        child: Card(
          child: Padding(
            padding: EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator(),
                SizedBox(height: 12),
                Text('正在检查更新…', style: TextStyle(fontSize: 13)),
              ],
            ),
          ),
        ),
      ),
    );
    try {
      final info = await checkForUpdates();
      if (!context.mounted) return;
      Navigator.of(context).pop(); // close the spinner
      if (info.isNewer) {
        await showUpdateDialog(context, info);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('已是最新版本 v$appVersion')));
      }
    } catch (e) {
      if (!context.mounted) return;
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('检查更新失败: $e')));
    }
  }
}

/// 控制区行组容器:card 底 + hairline + 小圆角(spec §4/§7.3)。
/// 行组字阶一处定义:title=emphasis 15、subtitle=secondary 12 muted,
/// 行内不再逐个写样式。
class _GroupCard extends StatelessWidget {
  final List<Widget> children;

  const _GroupCard({required this.children});

  @override
  Widget build(BuildContext context) {
    final colors = EmberColors.of(context);
    return Container(
      decoration: BoxDecoration(
        color: colors.card,
        borderRadius: BorderRadius.circular(EmberRadius.control),
        border: Border.all(color: colors.hairline),
      ),
      clipBehavior: Clip.antiAlias,
      // ListTile paints ink on the nearest Material; without this the
      // decorated Container would hide the splash (framework assertion).
      child: Material(
        type: MaterialType.transparency,
        child: ListTileTheme.merge(
          titleTextStyle: TextStyle(
              fontSize: EmberType.emphasis, color: colors.textSolid),
          subtitleTextStyle: TextStyle(
              fontSize: EmberType.secondary, color: colors.textMuted),
          child: Column(children: children),
        ),
      ),
    );
  }
}

/// Toggles per-frame relay logging ([RelayClient.verboseFrames]). Off by
/// default in release: every inbound frame costs a jsonEncode + truncation,
/// which is real CPU during streaming. Diagnostics always log regardless.
class _VerboseFramesTile extends StatefulWidget {
  const _VerboseFramesTile();

  @override
  State<_VerboseFramesTile> createState() => _VerboseFramesTileState();
}

class _VerboseFramesTileState extends State<_VerboseFramesTile> {
  late bool _value = RelayClient.verboseFrames;

  @override
  Widget build(BuildContext context) {
    return SwitchListTile(
      secondary: const Icon(Icons.article_outlined, size: 20),
      title: const Text('协议帧日志（详细）'),
      subtitle: const Text('逐帧记录收发原文；流式期间有性能开销，排查协议时开启'),
      value: _value,
      onChanged: (v) async {
        setState(() => _value = v);
        RelayClient.verboseFrames = v;
        try {
          final prefs = await SharedPreferences.getInstance();
          await prefs.setBool('relayVerboseFrames', v);
        } catch (_) {}
      },
    );
  }
}

/// 诊断日志开关:开 = [wire]/[chat]/[zflow] 探针同时写 logcat
/// (release 真机取证:连接/桥/订阅/发送的时序与降级-恢复循环只在
/// wire 层可见);关 = 仅应用内协议日志页。
class _DiagLogTile extends StatefulWidget {
  const _DiagLogTile();

  @override
  State<_DiagLogTile> createState() => _DiagLogTileState();
}

class _DiagLogTileState extends State<_DiagLogTile> {
  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: diagLogEnabled,
      builder: (context, value, _) => SwitchListTile(
        secondary: const Icon(Icons.bug_report_outlined, size: 20),
        title: const Text('诊断日志（logcat）'),
        subtitle: const Text('连接/订阅/发送时序探针输出到系统日志，排查故障时开启'),
        value: value,
        onChanged: (v) => setDiagLogEnabled(v),
      ),
    );
  }
}

/// 设备管理入口(带未读徽标):后台/别处产生的任务事件推成通知后计未读,
/// 打开对应会话即清。
class _DevicesTile extends StatefulWidget {
  final AccountStore store;
  final AppSession session;

  const _DevicesTile({required this.store, required this.session});

  @override
  State<_DevicesTile> createState() => _DevicesTileState();
}

class _DevicesTileState extends State<_DevicesTile> {
  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([widget.store, UnreadEvents.instance]),
      builder: (context, _) {
        final unread = UnreadEvents.instance.total;
        return ListTile(
          leading: const Icon(Icons.devices_other, size: 20),
          title: const Text('设备管理'),
          subtitle: Text(unread > 0
              ? '$unread 条未读 · ${widget.store.accounts.length} 台设备'
              : '${widget.store.accounts.length} 台设备 · 扫码/导入添加'),
          trailing: unread > 0
              ? Badge(
                  label: Text('$unread'),
                  child: const Icon(Icons.notifications_none, size: 20),
                )
              : _chevron,
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => DeviceManagementPage(
                  store: widget.store, session: widget.session),
            ),
          ),
        );
      },
    );
  }
}

/// 会话保活开关:前台服务常驻（有已配对设备时），后台/息屏不掉线。
class _KeepAliveTile extends StatefulWidget {
  const _KeepAliveTile();

  @override
  State<_KeepAliveTile> createState() => _KeepAliveTileState();
}

class _KeepAliveTileState extends State<_KeepAliveTile> {
  @override
  Widget build(BuildContext context) {
    final prefs = BackgroundPrefs.instance;
    return AnimatedBuilder(
      animation: prefs,
      builder: (context, _) => SwitchListTile(
        secondary: const Icon(Icons.sync_lock_outlined, size: 20),
        title: const Text('会话保活'),
        subtitle: const Text('前台服务常驻，后台与息屏下保持连接；通知栏常驻低重要性提醒'),
        value: prefs.keepAliveEnabled,
        onChanged: (v) async {
          await prefs.setKeepAliveEnabled(v);
          if (v && context.mounted) await _guideBatteryWhitelist(context);
        },
      ),
    );
  }

  /// 开启时引导一次电池优化白名单（系统确认框;拒绝也可稍后手动再来）。
  Future<void> _guideBatteryWhitelist(BuildContext context) async {
    final notifications = notificationsService;
    if (!Notifications.isSupported) return;
    if (await notifications.isIgnoringBatteryOptimizations()) return;
    final remembered =
        (await SharedPreferences.getInstance()).getBool('battery.guideShown') ?? false;
    if (remembered) return;
    await SharedPreferences.getInstance()
        .then((p) => p.setBool('battery.guideShown', true));
    if (!context.mounted) return;
    await notifications.requestIgnoreBatteryOptimizations();
  }
}

/// 息屏保持在线:息屏期间持部分 WakeLock,防 Doze 冻结连接(耗电换稳定)。
class _WakeLockTile extends StatefulWidget {
  const _WakeLockTile();

  @override
  State<_WakeLockTile> createState() => _WakeLockTileState();
}

class _WakeLockTileState extends State<_WakeLockTile> {
  @override
  Widget build(BuildContext context) {
    final prefs = BackgroundPrefs.instance;
    return AnimatedBuilder(
      animation: prefs,
      builder: (context, _) => SwitchListTile(
        secondary: const Icon(Icons.screen_lock_portrait_outlined, size: 20),
        title: const Text('息屏保持在线'),
        subtitle: const Text('息屏期间保持 CPU 唤醒，连接最稳；耗电略增'),
        value: prefs.keepAliveEnabled && prefs.wakeLock,
        onChanged: prefs.keepAliveEnabled
            ? (v) => prefs.setWakeLock(v)
            : null,
      ),
    );
  }
}

/// 电池优化白名单状态行:未加白显 ⚠,点按弹系统确认框。
class _BatteryWhitelistTile extends StatefulWidget {
  const _BatteryWhitelistTile();

  @override
  State<_BatteryWhitelistTile> createState() => _BatteryWhitelistTileState();
}

class _BatteryWhitelistTileState extends State<_BatteryWhitelistTile> {
  bool _ignoring = true;

  @override
  void initState() {
    super.initState();
    notificationsService.isIgnoringBatteryOptimizations().then((v) {
      if (mounted) setState(() => _ignoring = v);
    });
  }

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: _ignoring
          ? const Icon(Icons.battery_saver_outlined, size: 20)
          : Icon(Icons.warning_amber_outlined,
              size: 20, color: EmberColors.of(context).warn),
      title: const Text('电池优化白名单'),
      subtitle: Text(_ignoring
          ? '已加白：后台连接不受电池优化影响'
          : '未加白：系统可能冻结后台连接，建议允许'),
      trailing: _ignoring
          ? const Icon(Icons.check, size: 20)
          : const Icon(Icons.chevron_right, size: 20),
      onTap: _ignoring
          ? null
          : () async {
              await notificationsService.requestIgnoreBatteryOptimizations();
              final ok = await notificationsService.isIgnoringBatteryOptimizations();
              if (mounted) setState(() => _ignoring = ok);
            },
    );
  }
}

enum NotifyKind { approvals, completions, failures }

/// 通知三分开关：审批请求 / 任务完成 / 任务失败。
class _NotifyToggle extends StatefulWidget {
  final NotifyKind kind;

  const _NotifyToggle({required this.kind});

  @override
  State<_NotifyToggle> createState() => _NotifyToggleState();
}

class _NotifyToggleState extends State<_NotifyToggle> {
  @override
  Widget build(BuildContext context) {
    final prefs = BackgroundPrefs.instance;
    return AnimatedBuilder(
      animation: prefs,
      builder: (context, _) {
        final (title, subtitle, icon, value) = switch (widget.kind) {
          NotifyKind.approvals => (
              '审批请求',
              '任务等待权限批准或输入时横幅提醒',
              Icons.approval_outlined,
              prefs.notifyApprovals,
            ),
          NotifyKind.completions => (
              '任务完成',
              '任务完成时静默提醒',
              Icons.task_alt_outlined,
              prefs.notifyCompletions,
            ),
          NotifyKind.failures => (
              '任务失败',
              '任务失败或中断时静默提醒',
              Icons.error_outline,
              prefs.notifyFailures,
            ),
        };
        return SwitchListTile(
          secondary: Icon(icon, size: 20),
          title: Text(title),
          subtitle: Text(subtitle),
          value: value,
          onChanged: (v) => switch (widget.kind) {
            NotifyKind.approvals => prefs.setNotifyApprovals(v),
            NotifyKind.completions => prefs.setNotifyCompletions(v),
            NotifyKind.failures => prefs.setNotifyFailures(v),
          },
        );
      },
    );
  }
}

/// 诊断与日志二级页(spec §7.4 诊断中心):上次崩溃摘要前置,
/// 二级列表:诊断日志 / 协议日志 / RPC 调试器 / 信道浏览器。
class _DiagnosticsPage extends StatelessWidget {
  final ZflowClient? client;
  final BridgeSession? bridge;

  const _DiagnosticsPage({this.client, this.bridge});

  /// 诊断计数前置(spec §7.4):有 [诊断] 条目时在行尾显示计数徽。
  /// AnimatedBuilder 挂 LogStore:进页后新增条目实时刷新(A8)。
  Widget _diagCountTrailing(BuildContext context) {
    return AnimatedBuilder(
      animation: LogStore.instance,
      builder: (context, _) {
        final count = LogStore.instance.entries
            .where((e) => e.isDiagnostic)
            .length;
        return Row(mainAxisSize: MainAxisSize.min, children: [
          if (count > 0) ...[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: EmberColors.of(context).warn.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(5),
              ),
              child: Text('$count',
                  style: TextStyle(
                      fontSize: EmberType.caption,
                      color: EmberColors.of(context).warn)),
            ),
            const SizedBox(width: EmberSpacing.gapS),
          ],
          _chevron,
        ]);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('诊断与日志')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const _LastCrashCard(),
          const SizedBox(height: 12),
          _GroupCard(
            children: [
              ListTile(
                leading: const Icon(Icons.bug_report_outlined, size: 20),
                title: const Text('诊断日志'),
                subtitle: const Text('故障原因与协议失配提示'),
                trailing: _diagCountTrailing(context),
                onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                        builder: (_) =>
                            const LogPage(diagnosticsOnly: true))),
              ),
              const Divider(indent: 52),
              ListTile(
                leading: const Icon(Icons.terminal, size: 20),
                title: const Text('协议日志'),
                subtitle: const Text('查看 relay / IPC / V4 帧日志'),
                trailing: _chevron,
                onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const LogPage())),
              ),
              if (client != null) ...[
                const Divider(indent: 52),
                ListTile(
                  leading: const Icon(Icons.bug_report_outlined, size: 20),
                  title: const Text('RPC 调试器'),
                  subtitle: const Text('发送原始 relay payload'),
                  trailing: _chevron,
                  onTap: () => Navigator.of(context)
                      .push(MaterialPageRoute(
                          builder: (_) =>
                              RpcExplorerPage(client: client!))),
                ),
              ],
              if (bridge != null) ...[
                const Divider(indent: 52),
                ListTile(
                  leading: const Icon(Icons.hub_outlined, size: 20),
                  title: const Text('信道浏览器'),
                  subtitle: const Text(
                      '调用任意 channel 方法（zcode-task / skills / mcp …）'),
                  trailing: _chevron,
                  onTap: () => Navigator.of(context)
                      .push(MaterialPageRoute(
                          builder: (_) =>
                              ChannelExplorerPage(session: bridge!))),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

/// Shows the last persisted crash (from [crashStore]), hidden when none.
class _LastCrashCard extends StatefulWidget {
  const _LastCrashCard();

  @override
  State<_LastCrashCard> createState() => _LastCrashCardState();
}

class _LastCrashCardState extends State<_LastCrashCard> {
  CrashInfo? _crash;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final c = await crashStore?.read();
    if (mounted) setState(() => _crash = c);
  }

  void _showDetails() {
    final c = _crash;
    if (c == null) return;
    final text = '时间: ${c.time}\n类型: ${c.kind}\n版本: v${c.appVersion}\n\n'
        '${c.error}\n\n${c.stack ?? ''}';
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('上次崩溃'),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: SelectableText(
              text,
              style: TextStyle(
                  fontFamily: EmberFonts.term, fontSize: 10.5),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: text));
              ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('崩溃详情已复制')));
            },
            child: const Text('复制'),
          ),
          TextButton(
            onPressed: () async {
              await crashStore?.clear();
              if (context.mounted) Navigator.pop(context);
              await _load();
            },
            child: const Text('清除'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = _crash;
    if (c == null) return const SizedBox.shrink();
    final colors = EmberColors.of(context);
    return _GroupCard(
      children: [
        ListTile(
          leading:
              Icon(Icons.bug_report_outlined, size: 20, color: colors.err),
          title: const Text('上次崩溃'),
          subtitle: Text(
            '${c.time} · ${c.error.split('\n').first}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: _chevron,
          onTap: _showDetails,
        ),
      ],
    );
  }
}
