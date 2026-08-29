import 'dart:async';

import 'package:flutter/material.dart';

import '../protocol/channel_client.dart';
import '../protocol/conversation.dart';
import '../protocol/zflow_client.dart';
import '../state/log_store.dart';
import '../state/session_list_cache.dart';
import 'ember_pressable.dart';
import 'task_detail_page.dart';
import 'theme.dart';

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

  /// listTasks 的活跃任务条目(旧版 task_home 同源的主体数据):索引
  /// 还没收录的活跃任务照常显示(容差);索引到达的条目由其字段富化
  /// (preview/实时 phase)。UI 大改期间曾被倒置为"索引为主体、任务只做
  /// 过滤",r25–r33 的混入/归档空/滞后隐藏均源于此——已回退旧骨架,
  /// 仅叠加孤儿过滤与归档剔除两个已验证修复。
  List<SessionEntry> _activeTasks = const [];

  /// 已写过缓存复本的订阅(每个订阅只写首个 ready 快照;write 完成才标记)。
  SessionsIndexSubscription? _cacheSyncedSub;

  /// 当前内嵌会话是否已在实时列表中出现过(A4 消失检测的基准:draft 采纳
  /// 等场景下列表尚未收录该会话不算消失)。
  bool _currentSeen = false;

  /// 索引条目键样本探针只打一次(诊断混入:索引 vs 任务列表的 id 交集)。
  bool _idxProbed = false;

  /// 索引里已见过的会话 id(_maybeRefreshTasksFor 的单调集合)。
  final Set<String> _seenIndexIds = {};

  /// _loadTasks 在途标志(周期刷新/未知 id 触发/管理操作可能并发);
  /// 在途期间的再请求不丢弃,完成后续跑一次(最新归属优先)。
  bool _loadingTasks = false;
  bool _reloadQueued = false;

  /// 上次任务归属拉取时刻(毫秒钟)。抽屉打开期间借索引推送(~10s 一跳)
  /// 做刷新时钟:距上次 ≥15s 且抽屉展开 → 重拉。不另起 Timer,避免常驻
  /// 定时器(widget 测试与后台功耗都不友好)。
  int _lastTasksLoadMs = 0;

  @override
  void initState() {
    super.initState();
    if (diagLogEnabled.value) {
      debugPrint('[zflow] SessionDrawer initState #$hashCode');
    }
    _transport = widget.bridge.conversation(widget.scope, onLog: log);
    _subscribe();
    _seedFromCache();
    _loadPinned();
    _loadTasks();
  }

  @override
  void didUpdateWidget(SessionDrawer oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 每次展开都拿最新归属(桌面端可能归档/删除过任务)。
    if (widget.open && !oldWidget.open) _loadTasks();
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
    if (diagLogEnabled.value) {
      debugPrint('[zflow] _onState ready=${sub.state.ready} n=${list.length}');
    }
    final prevIds = _entries.map((e) => e.sessionId).toSet();
    if (diagLogEnabled.value && list.isNotEmpty && !_idxProbed) {
      _idxProbed = true;
      final raw = list.first.raw;
      final ids = list.map((e) => e.sessionId).toSet();
      final orphan = ids
          .where((id) =>
              !_archivedIds.contains(id) && !_activeTaskIds.contains(id))
          .length;
      debugPrint('[zflow] idxSampleKeys=${raw.keys.toList()} '
          'idxArchivedFlag=${raw['archived'] ?? raw['archivedAt'] ?? '-'} '
          'overlapArch=${ids.where(_archivedIds.contains).length} '
          'overlapAct=${ids.where(_activeTaskIds.contains).length} '
          'orphan=$orphan');
    }
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
    _maybeRefreshTasksFor(list);
    // 索引移除了此前活跃的会话(桌面端删除/归档):归属集已过期,重拉
    // 后由 _loadTasks 末尾的补判定决定是否复位(在途旧数据不误判存活)。
    if (_tasksLoaded && prevIds.isNotEmpty) {
      final gone =
          prevIds.difference(list.map((e) => e.sessionId).toSet());
      if (gone.any(_activeTaskIds.contains)) _loadTasks();
    }
  }

  /// 索引出现未见过的会话(本端新建首条落地/桌面新建)→ 重拉任务归属,
  /// 否则新会话要等下次开抽屉才出现在活跃组。_seenIndexIds 单调记录,
  /// 已删任务的孤儿不会反复触发(它们不在任何任务列表里,但只刷新一次)。
  void _maybeRefreshTasksFor(List<SessionEntry> list) {
    if (!_tasksLoaded) return;
    var fresh = false;
    for (final e in list) {
      if (_seenIndexIds.add(e.sessionId)) fresh = true;
    }
    if (fresh) {
      _loadTasks();
      return;
    }
    // 无新面孔时的节流刷新:抽屉展开期间(桌面端可能归档/删除过任务,
    // 索引条目无归档标志,只能重拉归属),距上次拉取 ≥15s 才动手。
    if (widget.open &&
        DateTime.now().millisecondsSinceEpoch - _lastTasksLoadMs >= 15000) {
      _loadTasks();
    }
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
    if (diagLogEnabled.value) debugPrint('[zflow] seed: ${raw.length} entries');
    if (!mounted || raw.isEmpty) return;
    setState(() {
      _seed = [for (final m in raw) SessionEntry({...m, 'phase': ''})];
    });
  }

  /// zcode-task `listTasks` + `listArchivedTasks`(旧版 task_home 同源):
  /// 任务条目是列表主体(_activeTasks),归档组由 archList 条目直构,
  /// 双 id 集供孤儿过滤与 vanished 三重确认。任一失败保留旧数据不 wipe。
  Future<void> _loadTasks() async {
    if (_loadingTasks) {
      _reloadQueued = true;
      return;
    }
    _loadingTasks = true;
    _lastTasksLoadMs = DateTime.now().millisecondsSinceEpoch;
    try {
      Future<(bool, dynamic)> call(String method) => widget.bridge.channels
          .call(Channels.zcodeTask, method, [widget.scope])
          .then((r) => (true, r))
          .catchError((Object _) => (false, const <dynamic>[]));
      final (tasksOk, tasksData) = await call('listTasks');
      // 归档并集:listArchivedTasks 是归档列表的显式来源(listTasks 可能
      // 直接不下发归档条目);条目级 archived 标志若在也并入。
      final (archOk, archData) = await call('listArchivedTasks');
      if (!mounted) return;
      final list = tasksOk && tasksData is List ? tasksData : const [];
      final archList = archOk && archData is List ? archData : const [];
      SessionEntry entryOf(Map t, {bool archived = false}) => SessionEntry({
        'sessionId': '${t['taskId']}',
        'title': '${t['title'] ?? ''}',
        'phase': '${t['displayStatus'] ?? ''}',
        'lastActivityAt': (t['updatedAt'] as num?)?.toInt() ??
            (t['createdAt'] as num?)?.toInt() ??
            0,
        'createdAt': (t['createdAt'] as num?)?.toInt() ?? 0,
        'hasBackgroundWork': t['hasBackgroundWork'] == true,
        if (archived) 'archived': 1,
      });
      final active = <SessionEntry>[];
      final archived = <SessionEntry>[
        // 归档组主体:listArchivedTasks 的条目本身(listTasks 不下发
        // 归档任务,此前误把 archIds 当标记、归档组因此恒空)。
        for (final t in archList)
          if (t is Map && t['taskId'] != null) entryOf(t.cast<String, dynamic>(), archived: true),
      ];
      final seenArchived = <String>{for (final e in archived) e.sessionId};
      for (final t in list) {
        if (t is! Map) continue;
        final e = entryOf(t.cast<String, dynamic>(),
            archived: t['archived'] == true);
        if (e.isArchived) {
          if (!seenArchived.contains(e.sessionId)) archived.add(e);
        } else {
          active.add(e);
        }
      }
      if (diagLogEnabled.value) {
        debugPrint('[zflow] _loadTasks total=${list.length} '
            'active=${active.length} archived=${archived.length} '
            'sampleKeys=${list.isEmpty ? '-' : '${(list.first as Map).keys.toList()}'}');
        final actIds = {for (final e in active) e.sessionId};
        final archIds = {for (final e in archived) e.sessionId};
        final idxIds = _entries.map((e) => e.sessionId).toSet();
        if (idxIds.isNotEmpty) {
          debugPrint('[zflow] _loadTasks x-index: idx=${idxIds.length} '
              'inAct=${idxIds.where(actIds.contains).length} '
              'inArch=${idxIds.where(archIds.contains).length} '
              'orphan=${idxIds.where((id) => !actIds.contains(id) && !archIds.contains(id)).length}');
        }
      }
      // 主体数据落位:任务条目(_activeTasks,索引未收录也照常显示)+
      // 归档组(archList 直构)+ 双 id 集(孤儿过滤与 vanished 三重确认)。
      setState(() {
        _activeTasks = active;
        _activeTaskIds = {for (final e in active) e.sessionId};
        _archived = archived;
        _archivedIds = {for (final e in archived) e.sessionId};
        _tasksLoaded = true;
      });
      // 归属更新后再判一次消失:索引移除触发的重拉在此拿到新任务集,
      // 已删除的当前会话此刻才能正确复位(旧集会误判"仍存活")。
      _notifyCurrentVanished();
    } catch (e) {
      log('[诊断] listTasks 拉取失败: $e');
    } finally {
      _loadingTasks = false;
      if (_reloadQueued) {
        _reloadQueued = false;
        scheduleMicrotask(_loadTasks);
      }
    }
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

  /// 活跃显示列表 = 任务条目为主体 + 索引富化(旧版 task_home 骨架):
  ///
  /// - 索引收录且属于活跃任务的条目 → 用索引字段(preview/实时
  ///   phase/桌面端生成的标题),每次索引推送即时刷新;
  /// - 索引还没收录的活跃任务(桌面端新建,快照秒级滞后)→ 任务条目
  ///   照常显示(旧版容差,曾在此版倒置中丢失);
  /// - 已归档(_archivedIds)与已删任务的孤儿(不在任何任务列表)的
  ///   索引条目不引入——sessions-index 会广播它们且条目无归档标志,
  ///   归档组走 _archived,孤儿隐藏(与桌面端任务列表一致)。
  /// 任务未载回前(!_tasksLoaded)按索引原样展示,载回即收敛。
  List<SessionEntry> get _displayActive {
    if (!_tasksLoaded) return _entries;
    final byId = <String, SessionEntry>{};
    for (final e in _entries) {
      if (_archivedIds.contains(e.sessionId)) continue;
      if (!_activeTaskIds.contains(e.sessionId)) continue;
      byId[e.sessionId] = e;
    }
    for (final t in _activeTasks) {
      byId.putIfAbsent(t.sessionId, () => t);
    }
    return sortSessions(byId.values.toList());
  }

  List<SessionEntry> get _filtered =>
      filterSessions(_displayActive, _query);

  // ------------------------------------------------------- manage actions

  Map<String, dynamic> _taskArgs(String sessionId, {bool? pinned}) => {
        'taskId': sessionId,
        ...widget.scope,
        if (pinned != null) 'pinned': pinned,
      };

  /// 批量置顶/归档/删除。列表归属以任务列表为准、字段以索引推送富化:
  /// 不做乐观移除,操作完成后重拉任务集并等索引刷新。[pinned] 仅
  /// setTaskPinned 需要(抽屉无取消置顶语义,恒 true;对照
  /// integration_test 服务端契约)。
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

  // ---------------------------------------------------- single-item actions

  /// 长按单条操作(UI 大改前的单条能力恢复;RPC 与旧版 task_home 同源):
  /// 活跃条目 = 置顶/重命名/归档/删除/查看原始快照;归档条目 =
  /// 取消归档/删除/查看原始快照。批量多选仍走「管理」。
  Future<void> _showItemActions(SessionEntry entry) async {
    final colors = EmberColors.of(context);
    final pinned = _pinnedIds.contains(entry.sessionId);
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
                leading: Icon(
                    pinned ? Icons.push_pin : Icons.push_pin_outlined,
                    size: 20),
                title: Text(pinned ? '取消置顶' : '置顶'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _itemAction(
                      'setTaskPinned', entry, '置顶失败',
                      args: _taskArgs(entry.sessionId, pinned: !pinned));
                },
              ),
              ListTile(
                dense: true,
                leading: const Icon(Icons.edit_outlined, size: 20),
                title: const Text('重命名'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _renameEntry(entry);
                },
              ),
              ListTile(
                dense: true,
                leading: const Icon(Icons.archive_outlined, size: 20),
                title: const Text('归档'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _itemAction('archiveTask', entry, '归档失败');
                },
              ),
            ] else
              ListTile(
                dense: true,
                leading: const Icon(Icons.unarchive_outlined, size: 20),
                title: const Text('取消归档'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _itemAction('unarchiveTask', entry, '取消归档失败');
                },
              ),
            ListTile(
              dense: true,
              leading: const Icon(Icons.code, size: 20),
              title: const Text('查看原始快照'),
              onTap: () {
                Navigator.pop(sheetContext);
                Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => TaskDetailPage(
                    taskId: entry.sessionId,
                    title: entry.title.isEmpty ? '任务详情' : entry.title,
                    scope: widget.scope,
                    session: widget.bridge,
                  ),
                ));
              },
            ),
            ListTile(
              dense: true,
              leading: Icon(Icons.delete_outline, size: 20, color: colors.err),
              title:
                  Text('删除', style: TextStyle(color: colors.err)),
              onTap: () {
                Navigator.pop(sheetContext);
                _deleteEntry(entry);
              },
            ),
          ],
        ),
      ),
    );
  }

  /// 单条 zcode-task RPC + 失败提示 + 归属刷新。
  Future<void> _itemAction(
    String method,
    SessionEntry entry,
    String errorPrefix, {
    Map<String, dynamic>? args,
  }) async {
    try {
      await widget.bridge.channels.call(
          Channels.zcodeTask, method, [args ?? _taskArgs(entry.sessionId)]);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('$errorPrefix: $e')));
      return;
    }
    unawaited(_loadPinned());
    unawaited(_loadTasks());
  }

  Future<void> _renameEntry(SessionEntry entry) async {
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
              onPressed: () => Navigator.pop(context),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(context, controller.text.trim()),
              child: const Text('保存')),
        ],
      ),
    );
    controller.dispose();
    if (title == null || title.isEmpty) return;
    await _itemAction('renameTask', entry, '重命名失败',
        args: {..._taskArgs(entry.sessionId), 'title': title});
  }

  Future<void> _deleteEntry(SessionEntry entry) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除会话？'),
        content: Text('将删除「${entry.title.isEmpty ? entry.sessionId : entry.title}」，此操作不可恢复'),
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
    await _itemAction('deleteTask', entry, '删除失败');
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
