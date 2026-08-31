import 'dart:async';

import 'package:flutter/material.dart';

import '../protocol/channel_client.dart';
import '../protocol/conversation.dart';
import '../protocol/rpc_result.dart';
import '../protocol/zflow_client.dart';
import '../state/log_store.dart';
import '../state/session_list_cache.dart';
import 'ember_pressable.dart';
import 'task_detail_page.dart';
import 'theme.dart';

part 'session_drawer_controller.dart';

/// Conversation list primitives shared by the session drawer (Ember shell):
/// task entries are the primary data (zcode-task listTasks), enriched by
/// the live `sessions-index` subscription — the pre-redesign task_home
/// skeleton, restored (UI 大改期间曾倒置为索引单一源,已回退).

/// Newest first, by last activity.
List<SessionEntry> sortSessions(List<SessionEntry> entries) {
  final list = [...entries]
    ..sort((a, b) => b.lastActivityAt.compareTo(a.lastActivityAt));
  return list;
}

/// Status dot color: running/prewarming → run blue, waiting → warn yellow,
/// anything else renders no dot. Locked to the dark palette (the Ember
/// design baseline), independent of theme.
Color? statusDotColor(String phase) => switch (phase) {
      'running' || 'prewarming' => EmberColors.dark().run,
      'waiting' => EmberColors.dark().warn,
      _ => null,
    };

/// 标题 contains 过滤(大小写不敏感;空白查询返回原列表)。
List<SessionEntry> filterSessions(List<SessionEntry> entries, String query) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return entries;
  return entries
      .where((e) => e.title.toLowerCase().contains(q))
      .toList(growable: false);
}

/// 两档分组(活跃/归档;键序即展示序)。[sorted] 需为 sortSessions 的
/// 降序输出;归档条目(isArchived)单独成组,其余全入活跃组(置顶项在
/// 活跃组内排最前,保持 sorted 顺序)。空组剔除,展示文案由调用方按键
/// 映射。
Map<String, List<SessionEntry>> groupSessions(
  List<SessionEntry> sorted,
  Set<String> pinnedIds,
) {
  final pinned = <SessionEntry>[];
  final active = <SessionEntry>[];
  final archived = <SessionEntry>[];
  for (final e in sorted) {
    if (e.isArchived) {
      archived.add(e);
    } else if (pinnedIds.contains(e.sessionId)) {
      pinned.add(e);
    } else {
      active.add(e);
    }
  }
  return {
    'active': [...pinned, ...active],
    'archived': archived
  }..removeWhere((_, v) => v.isEmpty);
}

const _weekdays = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];

/// Today → `HH:mm`, yesterday → `昨天`, within the last week → `周X`,
/// else `M月d日` (with year when it differs from today's).
/// 会话最近活跃时间(对照桌面端 sidePane.time 阶梯):刚刚 / N 分钟前 /
/// N 小时前 / N 天前;超过一周落回日期(昨天带时刻,本周内周X,更早
/// M月d日 / 年月日)。
String _relativeDayLabel(int millis) {
  if (millis <= 0) return '';
  final time = DateTime.fromMillisecondsSinceEpoch(millis);
  final now = DateTime.now();
  final diff = now.difference(time);
  if (diff.inMinutes < 1) return '刚刚';
  if (diff.inHours < 1) return '${diff.inMinutes} 分钟前';
  if (diff.inDays < 1) return '${diff.inHours} 小时前';
  if (diff.inDays < 7) return '${diff.inDays} 天前';
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(time.year, time.month, time.day);
  final hhmm =
      '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
  final daysAgo = today.difference(day).inDays;
  if (daysAgo == 1) return '昨天 $hhmm';
  if (daysAgo < 7) return _weekdays[time.weekday - 1];
  if (time.year == now.year) return '${time.month}月${time.day}日';
  return '${time.year}年${time.month}月${time.day}日';
}

/// 会话抽屉面板(spec §7.1):工作区条 / 搜索 / ＋新会话 / 分组会话列表
/// (置顶/今天/更早三档,置顶集来自 listPinnedTasks;运行中蓝点、等待
/// 黄点)/「管理」多选(置顶/归档/删除,走 zcode-task RPC)/ 底部设备
/// 状态条。宿主(root_shell 的 _DrawerHost)约束 76% 宽、滑出动画与遮罩。
/// onPick(null) = 新会话;列表条目点击 = 打开该会话。
class SessionDrawer extends StatefulWidget {
  final BridgeSession bridge;

  /// `{workspacePath, workspaceIdentity?}` — 列表订阅与任务 RPC 的 scope。
  final Map<String, dynamic> scope;

  /// 工作区条展示值(宿主经 root_shell.workspaceTitle / workspacePath 取好)。
  final String workspaceName;
  final String workspacePath;

  /// 当前内嵌会话 id(null = draft),列表高亮用。
  final String? currentSessionId;

  /// 选择会话(null = 新会话)。宿主负责关闭抽屉。
  final ValueChanged<String?> onPick;

  /// 「辅助对话」入口:基于当前内嵌会话创建 side session(宿主实现;
  /// 草稿态按钮禁用)。
  final VoidCallback onOpenSideChat;

  /// 工作区条 ⌄:宿主弹出工作区切换 sheet;携带当前工作区的实时会话数
  /// (取自本抽屉的在途 sessions-index 订阅;其他工作区无数据来源,由
  /// 宿主决定不显示)。
  final ValueChanged<int> onSwitchWorkspace;

  /// 当前内嵌会话从 sessions-index 消失(本抽屉曾见到、后被删除/归档)
  /// 时回调宿主复位到 draft。订阅失败或列表未就绪不触发。
  final VoidCallback onCurrentSessionVanished;

  /// 底部设备状态条点击:进设备管理页。
  final VoidCallback onManageDevices;

  final int deviceCount;
  final bool deviceOnline;

  /// 抽屉是否展开(壳注入)。打开期间周期重拉任务归属,桌面端的归档/
  /// 删除操作才能同步进分组;关闭时不刷。
  final bool open;

  const SessionDrawer({
    super.key,
    required this.bridge,
    required this.scope,
    required this.workspaceName,
    required this.workspacePath,
    required this.currentSessionId,
    required this.onPick,
    required this.onOpenSideChat,
    required this.onSwitchWorkspace,
    required this.onCurrentSessionVanished,
    required this.onManageDevices,
    required this.deviceCount,
    required this.deviceOnline,
    this.open = false,
  });

  @override
  State<SessionDrawer> createState() => _SessionDrawerState();
}

/// 抽屉视图:搜索/多选/对话框/导航与布局。会话数据、订阅、管理 RPC
/// 的所有权在 [SessionDrawerController](同库 part 文件),经 onChanged
/// 收到重绘通知。
class _SessionDrawerState extends State<SessionDrawer> {
  final _searchController = TextEditingController();

  String _query = '';

  /// 多选管理模式(「管理」入口 / 长按快捷进入)。
  bool _managing = false;
  final Set<String> _selected = {};

  late SessionDrawerController _controller;

  @override
  void initState() {
    super.initState();
    if (diagLogEnabled.value) {
      debugPrint('[zflow] SessionDrawer initState #$hashCode');
    }
    _controller = SessionDrawerController(
      bridge: widget.bridge,
      scope: widget.scope,
      onChanged: () {
        if (mounted) setState(() {});
      },
      onVanished: () => widget.onCurrentSessionVanished(),
    );
    _controller.setCurrentSessionId(widget.currentSessionId);
    _controller.start();
  }

  @override
  void didUpdateWidget(SessionDrawer oldWidget) {
    super.didUpdateWidget(oldWidget);
    final sourceChanged = !_controller.sourceMatches(widget.bridge, widget.scope);
    if (oldWidget.currentSessionId != widget.currentSessionId) {
      _controller.setCurrentSessionId(widget.currentSessionId);
    }
    if (sourceChanged) {
      setState(() {
        _managing = false;
        _selected.clear();
      });
      _controller.reattach(widget.bridge, widget.scope);
    } else if (widget.open && !oldWidget.open) {
      // 每次展开都拿最新归属(桌面端可能归档/删除过任务)。
      _controller.open = true;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _searchController.dispose();
    super.dispose();
  }

  /// 搜索过滤后的活跃显示列表(controller 数据 + 视图查询词)。
  List<SessionEntry> get _filtered =>
      filterSessions(_controller.displayActive, _query);

  // ---------------------------------------------------- manage actions (view)

  /// 批量操作入口:RPC 与守卫在 controller,视图传当前多选并接管完成
  /// 后的模式退出与提示。
  Future<void> _applySelection(String method, String errorPrefix,
      {bool? pinned}) {
    return _controller.applySelection(
      method,
      selected: Set<String>.of(_selected),
      pinned: pinned,
      onFinished: (failed) {
        if (!mounted) return;
        setState(() {
          _managing = false;
          _selected.clear();
        });
        if (failed > 0) {
          ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('$errorPrefix: $failed 项失败')));
        }
      },
    );
  }

  /// 单条操作入口:失败提示在视图层。
  Future<void> _itemAction(
    String method,
    SessionEntry entry,
    String errorPrefix, {
    Map<String, dynamic>? args,
    DrawerActionSource? actionSource,
  }) {
    return _controller.itemAction(
      method,
      entry,
      args: args,
      actionSource: actionSource,
      onError: (message) {
        if (!mounted) return;
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$errorPrefix: $message')));
      },
    );
  }

  Future<void> _deleteSelection() async {
    if (_selected.isEmpty) return;
    final source = _controller.captureActionSource(_selected);
    if (!_selected
        .every((id) => _controller.isCurrentActionSource(source, id))) {
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除会话？'),
        content: Text('将删除选中的 ${_selected.length} 个会话，此操作不可恢复'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: EmberColors.of(context).err),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _controller.applySelection(
      'deleteTask',
      selected: Set<String>.of(_selected),
      actionSource: source,
      onFinished: (failed) {
        if (!mounted) return;
        setState(() {
          _managing = false;
          _selected.clear();
        });
        if (failed > 0) {
          ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('删除失败: $failed 项失败')));
        }
      },
    );
  }

  // ---------------------------------------------------- single-item actions

  /// 长按单条操作(UI 大改前的单条能力恢复;RPC 与旧版 task_home 同源):
  /// 活跃条目 = 置顶/重命名/归档/删除/查看原始快照;归档条目 =
  /// 取消归档/删除/查看原始快照。批量多选仍走「管理」。
  Future<void> _showItemActions(SessionEntry entry) async {
    final source = _controller.captureActionSource([entry.sessionId]);
    if (!_controller.isCurrentActionSource(source, entry.sessionId)) return;
    final colors = EmberColors.of(context);
    final pinned = _controller.pinnedIds.contains(entry.sessionId);
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                  EmberSpacing.page, 0, EmberSpacing.page, EmberSpacing.gapS),
              child: Text(
                entry.title.isEmpty ? '会话操作' : entry.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: EmberType.body,
                    fontWeight: FontWeight.w600,
                    color: colors.textSolid),
              ),
            ),
            if (!entry.isArchived) ...[
              ListTile(
                dense: true,
                leading: Icon(pinned ? Icons.push_pin : Icons.push_pin_outlined,
                    size: 20),
                title: Text(pinned ? '取消置顶' : '置顶'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _itemAction(
                    'setTaskPinned',
                    entry,
                    '置顶失败',
                    actionSource: source,
                    args: _controller.taskArgs(entry.sessionId,
                        pinned: !pinned, scope: source.scope),
                  );
                },
              ),
              ListTile(
                dense: true,
                leading: const Icon(Icons.edit_outlined, size: 20),
                title: const Text('重命名'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _renameEntry(entry, source);
                },
              ),
              ListTile(
                dense: true,
                leading: const Icon(Icons.archive_outlined, size: 20),
                title: const Text('归档'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _itemAction('archiveTask', entry, '归档失败',
                      actionSource: source);
                },
              ),
            ] else
              ListTile(
                dense: true,
                leading: const Icon(Icons.unarchive_outlined, size: 20),
                title: const Text('取消归档'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _itemAction('unarchiveTask', entry, '取消归档失败',
                      actionSource: source);
                },
              ),
            ListTile(
              dense: true,
              leading: const Icon(Icons.code, size: 20),
              title: const Text('查看原始快照'),
              onTap: () {
                Navigator.pop(sheetContext);
                if (!_controller
                    .isCurrentActionSource(source, entry.sessionId)) {
                  return;
                }
                Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => TaskDetailPage(
                    taskId: entry.sessionId,
                    title: entry.title.isEmpty ? '任务详情' : entry.title,
                    scope: source.scope,
                    session: source.bridge,
                  ),
                ));
              },
            ),
            ListTile(
              dense: true,
              leading: Icon(Icons.delete_outline, size: 20, color: colors.err),
              title: Text('删除', style: TextStyle(color: colors.err)),
              onTap: () {
                Navigator.pop(sheetContext);
                _deleteEntry(entry, source);
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _renameEntry(
      SessionEntry entry, DrawerActionSource source) async {
    if (!_controller.isCurrentActionSource(source, entry.sessionId)) return;
    final controller = TextEditingController(text: entry.title);
    final title = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('重命名会话'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(border: OutlineInputBorder()),
          autofocus: true,
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context), child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(context, controller.text.trim()),
              child: const Text('保存')),
        ],
      ),
    );
    controller.dispose();
    if (title == null ||
        title.isEmpty ||
        !_controller.isCurrentActionSource(source, entry.sessionId)) {
      return;
    }
    await _itemAction('renameTask', entry, '重命名失败',
        actionSource: source,
        args: {
          ..._controller.taskArgs(entry.sessionId, scope: source.scope),
          'title': title,
        });
  }

  Future<void> _deleteEntry(
      SessionEntry entry, DrawerActionSource source) async {
    if (!_controller.isCurrentActionSource(source, entry.sessionId)) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除会话？'),
        content: Text(
            '将删除「${entry.title.isEmpty ? entry.sessionId : entry.title}」，此操作不可恢复'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: EmberColors.of(context).err),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true ||
        !_controller.isCurrentActionSource(source, entry.sessionId)) {
      return;
    }
    await _itemAction('deleteTask', entry, '删除失败', actionSource: source);
  }

  // -------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    final colors = EmberColors.of(context);
    return Material(
      color: colors.card,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildWorkspaceBar(context),
          _buildSearchField(context),
          Padding(
            padding: const EdgeInsets.fromLTRB(
                EmberSpacing.page, 0, EmberSpacing.page, EmberSpacing.gapS),
            child: Row(
              children: [
                Expanded(
                  child: _DashedActionButton(
                    label: '新会话',
                    onTap: () => widget.onPick(null),
                  ),
                ),
                // 辅助对话(原顶栏入口移此):基于当前内嵌会话创建
                // side session;草稿态(无会话)禁用。
                const SizedBox(width: EmberSpacing.gapS),
                Expanded(
                  child: _DashedActionButton(
                    label: '辅助对话',
                    icon: Icons.quickreply_outlined,
                    enabled: widget.currentSessionId != null,
                    onTap: widget.onOpenSideChat,
                  ),
                ),
              ],
            ),
          ),
          if (_managing)
            _buildSelectionBar(context)
          else if (_controller.entries.isNotEmpty)
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () => setState(() => _managing = true),
                child: const Text('管理'),
              ),
            ),
          Expanded(child: _buildListArea(context)),
          if (_managing && _selected.isNotEmpty) _buildActionBar(context),
          _buildDeviceBar(context),
        ],
      ),
    );
  }

  Widget _buildWorkspaceBar(BuildContext context) {
    final colors = EmberColors.of(context);
    return InkWell(
      onTap: () => widget.onSwitchWorkspace(_controller.entries.length),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(EmberSpacing.page, EmberSpacing.gapM,
            EmberSpacing.page, EmberSpacing.gapM),
        child: Row(
          children: [
            Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                color: colors.primary.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(EmberRadius.avatar),
              ),
              child: Icon(Icons.folder_open, size: 16, color: colors.primary),
            ),
            const SizedBox(width: EmberSpacing.gapS),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.workspaceName,
                    style: TextStyle(
                        fontSize: EmberType.emphasis,
                        fontWeight: FontWeight.w600,
                        color: colors.textSolid),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (widget.workspacePath.isNotEmpty)
                    Text(
                      widget.workspacePath,
                      style: TextStyle(
                          fontSize: EmberType.caption,
                          fontFamily: EmberFonts.term,
                          color: colors.textFaint),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                ],
              ),
            ),
            Icon(Icons.keyboard_arrow_down, size: 20, color: colors.textMuted),
          ],
        ),
      ),
    );
  }

  Widget _buildSearchField(BuildContext context) {
    final colors = EmberColors.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          EmberSpacing.page, 0, EmberSpacing.page, EmberSpacing.gapS),
      child: TextField(
        controller: _searchController,
        style: TextStyle(fontSize: EmberType.body, color: colors.textSolid),
        decoration: InputDecoration(
          isDense: true,
          hintText: '搜索会话',
          prefixIcon: Icon(Icons.search, size: 18, color: colors.textFaint),
          suffixIcon: _query.isEmpty
              ? null
              : IconButton(
                  icon: const Icon(Icons.clear, size: 16),
                  onPressed: () {
                    _searchController.clear();
                    setState(() => _query = '');
                  },
                ),
        ),
        onChanged: (v) => setState(() => _query = v),
      ),
    );
  }

  Widget _buildSelectionBar(BuildContext context) {
    final colors = EmberColors.of(context);
    return Container(
      color: colors.primary.withValues(alpha: 0.15),
      padding: const EdgeInsets.symmetric(
          horizontal: EmberSpacing.page, vertical: 6),
      child: Row(
        children: [
          Icon(Icons.checklist, size: 16, color: colors.primary),
          const SizedBox(width: EmberSpacing.gapS),
          Expanded(
            child: Text('已选 ${_selected.length} 项',
                style: TextStyle(
                    fontSize: EmberType.secondary,
                    fontWeight: FontWeight.w600,
                    color: colors.primary)),
          ),
          TextButton(
            onPressed: () => setState(() {
              _managing = false;
              _selected.clear();
            }),
            child: const Text('取消'),
          ),
        ],
      ),
    );
  }

  Widget _buildActionBar(BuildContext context) {
    final colors = EmberColors.of(context);
    return Container(
      decoration: BoxDecoration(
          border: Border(top: BorderSide(color: colors.hairline))),
      padding: const EdgeInsets.symmetric(
          horizontal: EmberSpacing.page, vertical: EmberSpacing.gapS),
      child: Row(
        children: [
          Expanded(
            child: OutlinedButton(
              onPressed: _controller.acting
                  ? null
                  : () =>
                      _applySelection('setTaskPinned', '置顶失败', pinned: true),
              child: const Text('置顶'),
            ),
          ),
          const SizedBox(width: EmberSpacing.gapS),
          Expanded(
            child: OutlinedButton(
              onPressed: _controller.acting
                  ? null
                  : () => _applySelection('archiveTask', '归档失败'),
              child: const Text('归档'),
            ),
          ),
          const SizedBox(width: EmberSpacing.gapS),
          Expanded(
            child: FilledButton(
              style: FilledButton.styleFrom(backgroundColor: colors.err),
              onPressed: _controller.acting ? null : _deleteSelection,
              child: const Text('删除'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildListArea(BuildContext context) {
    final colors = EmberColors.of(context);
    // A7:种子与实时列表共用同一搜索过滤语义。
    final seed = filterSessions(_controller.seed, _query);
    if (_controller.error != null) {
      // A3:订阅失败但离线种子可用 —— 展示种子列表兜底,横幅标记非最新。
      if (seed.isNotEmpty) {
        return Column(
          children: [
            _offlineBanner(context),
            Expanded(child: _buildSessionList(seed)),
          ],
        );
      }
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('会话列表加载失败: ${_controller.error}',
                style: TextStyle(
                    fontSize: EmberType.caption, color: colors.textMuted)),
            const SizedBox(height: EmberSpacing.gapS),
            TextButton(
              onPressed: _controller.subscribe,
              style: TextButton.styleFrom(foregroundColor: colors.primary),
              child: const Text('重试'),
            ),
          ],
        ),
      );
    }
    // 实时列表未到达时先展示离线种子(2c):仅当实时列表为空,数据到达即覆盖。
    if (!_controller.ready) {
      if (_controller.seed.isEmpty) {
        return const Center(
          child: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        );
      }
      return seed.isEmpty ? _noMatch(context) : _buildSessionList(seed);
    }
    final filtered = _filtered;
    final archived = filterSessions(_controller.archived, _query);
    if (filtered.isEmpty && archived.isEmpty) {
      if (_query.trim().isNotEmpty) return _noMatch(context);
      return Center(
        child: Text('暂无会话，点「＋新会话」开始对话',
            style: TextStyle(
                fontSize: EmberType.caption, color: colors.textFaint)),
      );
    }
    return _buildSessionList(filtered);
  }

  Widget _noMatch(BuildContext context) {
    final colors = EmberColors.of(context);
    return Center(
      child: Text('没有匹配「$_query」的会话',
          style:
              TextStyle(fontSize: EmberType.caption, color: colors.textFaint)),
    );
  }

  /// A3 离线横幅:订阅失败仍展示缓存种子时,顶部 muted 提示数据可能过期,
  /// 并保留重试入口。
  Widget _offlineBanner(BuildContext context) {
    final colors = EmberColors.of(context);
    return Container(
      width: double.infinity,
      color: colors.raise.withValues(alpha: 0.6),
      padding: const EdgeInsets.symmetric(
          horizontal: EmberSpacing.page, vertical: 4),
      child: Row(
        children: [
          Icon(Icons.cloud_off_outlined, size: 14, color: colors.textMuted),
          const SizedBox(width: EmberSpacing.gapS),
          Expanded(
            child: Text('离线数据 · 可能不是最新',
                style: TextStyle(
                    fontSize: EmberType.secondary, color: colors.textMuted)),
          ),
          TextButton(
            onPressed: _controller.subscribe,
            style: TextButton.styleFrom(
              foregroundColor: colors.primary,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              minimumSize: const Size(0, 32),
            ),
            child: const Text('重试'),
          ),
        ],
      ),
    );
  }

  /// 分组会话列表(spec §7.1:置顶/今天/更早),实时列表与离线种子共用。
  static const _groupLabels = {'active': '活跃', 'archived': '归档'};

  Widget _buildSessionList(List<SessionEntry> entries) {
    final colors = EmberColors.of(context);
    final groups = groupSessions(
        [...entries, ...filterSessions(_controller.archived, _query)],
        _controller.pinnedIds);
    final items = <({String group, SessionEntry? entry, int occurrence})>[];
    for (final group in groups.entries) {
      items.add((group: group.key, entry: null, occurrence: 0));
      final occurrences = <String, int>{};
      for (final entry in group.value) {
        final occurrence = occurrences.update(
          entry.sessionId,
          (count) => count + 1,
          ifAbsent: () => 0,
        );
        items.add((
          group: group.key,
          entry: entry,
          occurrence: occurrence,
        ));
      }
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(
          horizontal: EmberSpacing.page, vertical: EmberSpacing.gapS),
      itemCount: items.length,
      itemBuilder: (context, index) {
        final item = items[index];
        final entry = item.entry;
        if (entry == null) {
          return KeyedSubtree(
            key: ValueKey('session-group-${item.group}'),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                  EmberSpacing.cardPad, EmberSpacing.gapS, 0, 4),
              child: Text(_groupLabels[item.group] ?? item.group,
                  style: TextStyle(
                      fontSize: EmberType.caption,
                      fontWeight: FontWeight.w600,
                      color: colors.textFaint)),
            ),
          );
        }
        return KeyedSubtree(
          key: ValueKey(
              'session-row-${item.group}-${entry.sessionId}-${item.occurrence}'),
          child: _buildRow(context, entry),
        );
      },
    );
  }

  Widget _buildRow(BuildContext context, SessionEntry entry) {
    final colors = EmberColors.of(context);
    final dot = statusDotColor(entry.phase);
    final selected = _selected.contains(entry.sessionId);
    final isCurrent = entry.sessionId == widget.currentSessionId;
    // 行按压缩放(spec §5 动效);InkWell 水波保留。
    return EmberPressable(
      child: InkWell(
        onTap: () {
          if (_managing) {
            setState(() => selected
                ? _selected.remove(entry.sessionId)
                : _selected.add(entry.sessionId));
            return;
          }
          widget.onPick(entry.sessionId);
        },
        onLongPress: () {
          if (_managing) return;
          _showItemActions(entry);
        },
        child: Container(
          padding: const EdgeInsets.symmetric(
              horizontal: EmberSpacing.cardPad, vertical: 10),
          decoration: BoxDecoration(
            color: selected
                ? colors.primary.withValues(alpha: 0.12)
                : isCurrent
                    ? colors.raise.withValues(alpha: 0.6)
                    : Colors.transparent,
            borderRadius: BorderRadius.circular(EmberRadius.control),
          ),
          child: Row(
            children: [
              if (_managing) ...[
                Icon(
                  selected ? Icons.check_circle : Icons.radio_button_unchecked,
                  size: 18,
                  color: selected ? colors.primary : colors.textFaint,
                ),
                const SizedBox(width: EmberSpacing.gapM),
              ],
              SizedBox(
                width: 8,
                height: 8,
                child: dot == null
                    ? null
                    : DecoratedBox(
                        decoration:
                            BoxDecoration(color: dot, shape: BoxShape.circle),
                      ),
              ),
              const SizedBox(width: EmberSpacing.gapM),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      entry.title.isEmpty ? entry.sessionId : entry.title,
                      style: TextStyle(
                          fontSize: EmberType.body,
                          fontWeight:
                              isCurrent ? FontWeight.w600 : FontWeight.w400,
                          color: colors.textSolid),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if ((entry.lastAssistantPreview ?? '').isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        entry.lastAssistantPreview!,
                        style: TextStyle(
                            fontSize: EmberType.caption,
                            color: colors.textMuted),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: EmberSpacing.gapS),
              Text(
                _relativeDayLabel(entry.lastActivityAt),
                style: TextStyle(fontSize: 10, color: colors.textFaint),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDeviceBar(BuildContext context) {
    final colors = EmberColors.of(context);
    return InkWell(
      onTap: widget.onManageDevices,
      child: Container(
        decoration: BoxDecoration(
            border: Border(top: BorderSide(color: colors.hairline))),
        padding: const EdgeInsets.symmetric(
            horizontal: EmberSpacing.page, vertical: 10),
        child: Row(
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: widget.deviceOnline ? colors.ok : colors.textFaint,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: EmberSpacing.gapS),
            Text('${widget.deviceCount} 台设备',
                style: TextStyle(
                    fontSize: EmberType.secondary, color: colors.textMuted)),
            const Spacer(),
            Icon(Icons.chevron_right, size: 16, color: colors.textFaint),
          ],
        ),
      ),
    );
  }
}

/// 虚线「＋新会话」按钮(spec:虚线常驻入口)。
class _DashedActionButton extends StatelessWidget {
  final String label;
  final VoidCallback onTap;

  /// 前置图标(默认 ＋);[enabled] false 时整钮禁用置灰。
  final IconData icon;
  final bool enabled;

  const _DashedActionButton({
    required this.label,
    required this.onTap,
    this.icon = Icons.add,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    final colors = EmberColors.of(context);
    final tint = enabled ? colors.primary : colors.textFaint;
    return CustomPaint(
      painter: _DashedRectPainter(
          color: enabled ? colors.textFaint : colors.hairline),
      child: InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(EmberRadius.control),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 16, color: tint),
              const SizedBox(width: EmberSpacing.gapS),
              Text(label,
                  style: TextStyle(fontSize: EmberType.body, color: tint)),
            ],
          ),
        ),
      ),
    );
  }
}

class _DashedRectPainter extends CustomPainter {
  static const _dashWidth = 4.0;
  static const _dashGap = 3.0;

  final Color color;

  _DashedRectPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    final rrect = RRect.fromRectAndRadius(
        Offset.zero & size, const Radius.circular(EmberRadius.control));
    final path = Path()..addRRect(rrect);
    for (final metric in path.computeMetrics()) {
      var dist = 0.0;
      while (dist < metric.length) {
        final next = (dist + _dashWidth).clamp(0.0, metric.length);
        canvas.drawPath(metric.extractPath(dist, next), paint);
        dist = next + _dashGap;
      }
    }
  }

  @override
  bool shouldRepaint(_DashedRectPainter oldDelegate) =>
      oldDelegate.color != color;
}
