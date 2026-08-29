import 'dart:async';

import 'package:flutter/material.dart';

import '../protocol/channel_client.dart';
import '../protocol/conversation.dart';
import '../protocol/zflow_client.dart';
import '../state/log_store.dart';
import '../state/session_list_cache.dart';
import 'ember_pressable.dart';
import 'theme.dart';

/// Conversation list primitives shared by the session drawer (Ember shell):
/// the single source is the live `sessions-index` subscription, no
/// channel-list merge (2b 裁决:双源合并逻辑不迁移).

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
  return {'active': [...pinned, ...active], 'archived': archived}
    ..removeWhere((_, v) => v.isEmpty);
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

  const SessionDrawer({
    super.key,
    required this.bridge,
    required this.scope,
    required this.workspaceName,
    required this.workspacePath,
    required this.currentSessionId,
    required this.onPick,
    required this.onSwitchWorkspace,
    required this.onCurrentSessionVanished,
    required this.onManageDevices,
    required this.deviceCount,
    required this.deviceOnline,
  });

  @override
  State<SessionDrawer> createState() => _SessionDrawerState();
}

class _SessionDrawerState extends State<SessionDrawer> {
  static const _cache = SessionListCache();

  final _searchController = TextEditingController();

  String _query = '';

  /// 多选管理模式(「管理」入口 / 长按快捷进入)。
  bool _managing = false;
  final Set<String> _selected = {};
  bool _acting = false;

  late final ConversationTransport _transport;
  SessionsIndexSubscription? _sub;
  List<SessionEntry> _entries = const [];
  bool _ready = false;

  /// 最近一次非空实时列表(粘性):快照重放(resync/gap)会把 state.list
  /// 瞬时清空,直接 setState 会让抽屉闪一下空列表;重放完成前沿用旧列表。
  List<SessionEntry> _lastNonEmpty = const [];
  String? _error;

  /// 离线种子(2c):打开抽屉先展示上次缓存,实时数据到达即覆盖。
  List<SessionEntry> _seed = const [];

  /// 置顶会话 id 集(spec §7.1 置顶组):抽屉打开时与列表订阅并行经
  /// zcode-task.listPinnedTasks 拉取,失败容错为空集(仅置顶组不显示)。
  Set<String> _pinnedIds = const {};

  /// 归档任务(zcode-task `listArchivedTasks`,旧版 task_home 同源):
  /// V4 索引的存量种子会漏归档条目,这里既是归档组的数据源,也提供
  /// _archivedIds 供活跃列表剔除(双向纠偏)。
  List<SessionEntry> _archived = const [];
  Set<String> _archivedIds = const {};

  /// 任务列表(活跃+归档)已到达:到达前活跃列表不做归档剔除,避免
  /// 索引先到/任务后到的中间帧闪一下"空/骤减"。
  bool _tasksLoaded = false;

  /// zcode-task listTasks 的活跃任务 id 集(权威):vanished 判定以
  /// 「索引消失 && 不在权威活跃集」为准——新建会话尚未进索引快照、或
  /// 短暂被归档种子挤出的场景不再误判"已归档,回到新会话"。
  Set<String> _activeTaskIds = const {};

  /// 已写过缓存复本的订阅(每个订阅只写首个 ready 快照;write 完成才标记)。
  SessionsIndexSubscription? _cacheSyncedSub;

  /// 当前内嵌会话是否已在实时列表中出现过(A4 消失检测的基准:draft 采纳
  /// 等场景下列表尚未收录该会话不算消失)。
  bool _currentSeen = false;

  @override
  void initState() {
    super.initState();
    debugPrint('[zflow] SessionDrawer initState #$hashCode');
    _transport = widget.bridge.conversation(widget.scope, onLog: log);
    _subscribe();
    _seedFromCache();
    _loadPinned();
    _loadTasks();
  }

  @override
  void dispose() {
    final sub = _sub;
    _sub = null;
    if (sub != null) {
      sub.state.removeListener(_onState);
      sub.dispose();
    }
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _subscribe() async {
    // 重挂路径异步到达时组件可能已卸载(旧订阅 dispose 要等 unsubscribe 应答)。
    if (!mounted) return;
    setState(() => _error = null);
    try {
      final sub = await _transport.subscribeSessionsIndex();
      if (!mounted) {
        await sub.dispose();
        return;
      }
      _sub = sub;
      sub.state.addListener(_onState);
      _onState();
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  /// 拉取置顶 id 集(对照桌面端 task_home_page 的 listPinnedTasks:任务
  /// 列表元素带 taskId)。失败容错为空集 —— 置顶组退化为不显示,列表
  /// 其余功能不受影响。
  Future<void> _loadPinned() async {
    try {
      final tasks = await widget.bridge.channels
          .call(Channels.zcodeTask, 'listPinnedTasks', [widget.scope]);
      if (!mounted) return;
      setState(() {
        _pinnedIds = {
          for (final t in (tasks is List ? tasks : const <dynamic>[]))
            if (t is Map && t['taskId'] != null) '${t['taskId']}',
        };
      });
    } catch (_) {
      if (mounted) setState(() => _pinnedIds = const {});
    }
  }

  void _onState() {
    final sub = _sub;
    if (sub == null || !mounted) return;
    final list = sortSessions(sub.state.list);
    debugPrint('[zflow] _onState ready=${sub.state.ready} n=${list.length}');
    if (list.isEmpty && _lastNonEmpty.isNotEmpty && sub.state.ready) {
      // 重放瞬间:沿用上次列表,等重放后的真实快照(非空或确认清空)。
      return;
    }
    _lastNonEmpty = list;
    setState(() {
      _entries = list;
      _ready = sub.state.ready;
    });
    _notifyCurrentVanished();
    _syncCache(sub);
  }

  /// A4:当前内嵌会话曾出现在实时列表、后又消失(删除/归档)→ 回调宿主
  /// 复位到 draft。仅以「见过再消失」为准,避免 draft 采纳瞬间列表尚未
  /// 收录新会话被误判;订阅失败/未就绪不触发。
  void _notifyCurrentVanished() {
    final id = widget.currentSessionId;
    if (id == null || id.isEmpty || !_ready) return;
    final present = _entries.any((e) => e.sessionId == id);
    if (present) {
      _currentSeen = true;
      return;
    }
    if (_currentSeen) {
      // 索引里不在了,但任务列表(权威)说它还活着(活跃或在归档区):
      // 不是删除,绝不能复位——此前这里误判,把刚建的新会话判成
      // "已归档"复位,回复随之丢失(真机复现)。
      final knownAlive =
          _activeTaskIds.contains(id) || _archivedIds.contains(id);
      if (knownAlive) return;
      _currentSeen = false;
      widget.onCurrentSessionVanished();
    }
  }

  // ------------------------------------------------------- offline cache

  /// 打开抽屉先 read 播种(2c):仅当实时列表未到达(!ready)时展示,
  /// 真实数据到达即覆盖。种子条目 phase 清空 —— 状态点以实时为准(裁决),
  /// 缓存里的 running/waiting 可能早已过期。
  Future<void> _seedFromCache() async {
    final raw = await _cache.read(widget.scope);
    debugPrint('[zflow] seed: ${raw.length} entries');
    if (!mounted || raw.isEmpty) return;
    setState(() {
      _seed = [for (final m in raw) SessionEntry({...m, 'phase': ''})];
    });
  }

  /// zcode-task 任务列表(活跃 + 归档):活跃集用于把 V4 索引漏出的
  /// 归档条目从今天/更早剔除;归档集填「归档」组。失败静默(索引仍在)。
  Future<void> _loadTasks() async {
    Future<(bool, dynamic)> call(String method) => widget.bridge.channels
        .call(Channels.zcodeTask, method, [widget.scope])
        .then((r) => (true, r))
        .catchError((Object _) => (false, const <dynamic>[]));
    final (tasksOk, tasksData) = await call('listTasks');
    final (_, archivedData) = await call('listArchivedTasks');
    if (!mounted) return;
    final archivedList = archivedData is List ? archivedData : const [];
    final archived = <SessionEntry>[
      for (final t in archivedList)
        if (t is Map)
          SessionEntry({
            'sessionId': '${t['taskId']}',
            'title': '${t['title'] ?? ''}',
            'phase': '${t['displayStatus'] ?? t['status'] ?? ''}',
            'lastActivityAt':
                (t['updatedAt'] as num?)?.toInt() ??
                    (t['createdAt'] as num?)?.toInt() ??
                    0,
            'createdAt': (t['createdAt'] as num?)?.toInt() ?? 0,
            'hasBackgroundWork': t['hasBackgroundWork'] == true,
            'archived': 1,
          }),
    ];
    log('[v4] 任务列表:归档 ${archived.length} 条');
    debugPrint('[zflow] _loadTasks archived=${archived.length}');
    setState(() {
      _archived = archived;
      _archivedIds = {for (final e in archived) e.sessionId};
      if (tasksOk && tasksData is List) {
        _activeTaskIds = {
          for (final t in tasksData)
            if (t is Map && t['taskId'] != null) '${t['taskId']}',
        };
      }
      _tasksLoaded = true;
    });
  }

  /// 订阅 ready 后 write(2c):把当前列表落盘,供下次打开时秒开。
  /// 空列表不写(失败/清空不覆盖好数据,与旧实现一致)。write 完成后才
  /// 标记 _cacheSyncedSub:失败或被中断时标记未锁定,下个快照可重试。
  void _syncCache(SessionsIndexSubscription sub) {
    if (!sub.state.ready || _cacheSyncedSub == sub) return;
    unawaited(_cache
        .write(widget.scope, [for (final e in _entries) e.raw])
        .whenComplete(() => _cacheSyncedSub = sub));
  }

  List<SessionEntry> get _filtered => filterSessions(_entries, _query)
      .where((e) => !_tasksLoaded || !_archivedIds.contains(e.sessionId))
      .toList();

  // ------------------------------------------------------- manage actions

  Map<String, dynamic> _taskArgs(String sessionId, {bool? pinned}) => {
        'taskId': sessionId,
        ...widget.scope,
        if (pinned != null) 'pinned': pinned,
      };

  /// 批量置顶/归档/删除。列表以 sessions-index 推送为准(裁决):不做
  /// 乐观移除,操作完成后等索引刷新。[pinned] 仅 setTaskPinned 需要
  /// (抽屉无取消置顶语义,恒 true;对照 integration_test 服务端契约)。
  Future<void> _applySelection(
    String method,
    String errorPrefix, {
    bool? pinned,
  }) async {
    if (_acting || _selected.isEmpty) return;
    setState(() => _acting = true);
    var failed = 0;
    for (final id in _selected) {
      try {
        await widget.bridge.channels
            .call(Channels.zcodeTask, method, [_taskArgs(id, pinned: pinned)]);
      } catch (_) {
        failed++;
      }
    }
    if (!mounted) return;
    setState(() {
      _acting = false;
      _managing = false;
      _selected.clear();
    });
    if (failed > 0) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$errorPrefix: $failed 项失败')));
    }
    // 操作(置顶/归档/删除)改变置顶集与归档集 → 重拉刷新分组。
    unawaited(_loadPinned());
    unawaited(_loadTasks());
  }

  Future<void> _deleteSelection() async {
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
    await _applySelection('deleteTask', '删除失败');
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
            child: _DashedActionButton(
              label: '新会话',
              onTap: () => widget.onPick(null),
            ),
          ),
          if (_managing)
            _buildSelectionBar(context)
          else if (_entries.isNotEmpty)
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
      onTap: () => widget.onSwitchWorkspace(_entries.length),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(EmberSpacing.page,
            EmberSpacing.gapM, EmberSpacing.page, EmberSpacing.gapM),
        child: Row(
          children: [
            Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                color: colors.primary.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(EmberRadius.avatar),
              ),
              child:
                  Icon(Icons.folder_open, size: 16, color: colors.primary),
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
            Icon(Icons.keyboard_arrow_down,
                size: 20, color: colors.textMuted),
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
        style:
            TextStyle(fontSize: EmberType.body, color: colors.textSolid),
        decoration: InputDecoration(
          isDense: true,
          hintText: '搜索会话',
          prefixIcon:
              Icon(Icons.search, size: 18, color: colors.textFaint),
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
              onPressed: _acting
                  ? null
                  : () => _applySelection('setTaskPinned', '置顶失败',
                      pinned: true),
              child: const Text('置顶'),
            ),
          ),
          const SizedBox(width: EmberSpacing.gapS),
          Expanded(
            child: OutlinedButton(
              onPressed: _acting
                  ? null
                  : () => _applySelection('archiveTask', '归档失败'),
              child: const Text('归档'),
            ),
          ),
          const SizedBox(width: EmberSpacing.gapS),
          Expanded(
            child: FilledButton(
              style: FilledButton.styleFrom(backgroundColor: colors.err),
              onPressed: _acting ? null : _deleteSelection,
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
    final seed = filterSessions(_seed, _query);
    if (_error != null) {
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
            Text('会话列表加载失败: $_error',
                style: TextStyle(
                    fontSize: EmberType.caption, color: colors.textMuted)),
            const SizedBox(height: EmberSpacing.gapS),
            TextButton(
              onPressed: _subscribe,
              style: TextButton.styleFrom(foregroundColor: colors.primary),
              child: const Text('重试'),
            ),
          ],
        ),
      );
    }
    // 实时列表未到达时先展示离线种子(2c):仅当实时列表为空,数据到达即覆盖。
    if (!_ready) {
      if (_seed.isEmpty) {
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
    if (_entries.isEmpty) {
      return Center(
        child: Text('暂无会话，点「＋新会话」开始对话',
            style: TextStyle(
                fontSize: EmberType.caption, color: colors.textFaint)),
      );
    }
    final filtered = _filtered;
    if (filtered.isEmpty) return _noMatch(context);
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
            onPressed: _subscribe,
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
    return ListView(
      padding: const EdgeInsets.symmetric(
          horizontal: EmberSpacing.page, vertical: EmberSpacing.gapS),
      children: [
        for (final group in groupSessions(
            [...entries, ...filterSessions(_archived, _query)], _pinnedIds)
            .entries) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(
                EmberSpacing.cardPad, EmberSpacing.gapS, 0, 4),
            child: Text(_groupLabels[group.key] ?? group.key,
                style: TextStyle(
                    fontSize: EmberType.caption,
                    fontWeight: FontWeight.w600,
                    color: colors.textFaint)),
          ),
          for (final e in group.value) _buildRow(context, e),
        ],
      ],
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
        // 长按快捷进入多选,并选中该条。
        if (_managing) return;
        setState(() {
          _managing = true;
          _selected.add(entry.sessionId);
        });
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
                selected
                    ? Icons.check_circle
                    : Icons.radio_button_unchecked,
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
                    fontSize: EmberType.secondary,
                    color: colors.textMuted)),
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

  const _DashedActionButton({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final colors = EmberColors.of(context);
    return CustomPaint(
      painter: _DashedRectPainter(color: colors.textFaint),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(EmberRadius.control),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.add, size: 16, color: colors.primary),
              const SizedBox(width: EmberSpacing.gapS),
              Text(label,
                  style: TextStyle(
                      fontSize: EmberType.body, color: colors.primary)),
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
