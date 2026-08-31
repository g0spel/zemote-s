part of 'session_drawer.dart';

/// 抽屉的异步/状态所有权:source 绑定与 generation 守卫、sessions-index
/// 订阅、任务/置顶/归档拉取、离线种子与缓存复本、消失检测、管理操作
/// RPC。视图(_SessionDrawerState)只保留搜索/多选/对话框/导航,数据
/// 变更经 [onChanged] 请求重绘;管理操作的失败文案经回调上抛,提示
/// 展示仍在视图层。
class SessionDrawerController {
  SessionDrawerController({
    required this.bridge,
    required Map<String, dynamic> scope,
    required this.onChanged,
    required this.onVanished,
  }) : _scope = Map<String, dynamic>.from(scope) {
    _sourceScopeKey = _scopeKeyOf(_scope);
    transport = bridge.conversation(_scope, onLog: log);
  }

  static const _cache = SessionListCache();

  /// 数据变更通知(视图接 setState)。
  final void Function() onChanged;

  /// 当前内嵌会话从实时列表消失(见过再消失且任务列表确认已无)时回调。
  final VoidCallback onVanished;

  BridgeSession bridge;
  final Map<String, dynamic> _scope;
  late String _sourceScopeKey;
  late ConversationTransport transport;

  bool _disposed = false;
  bool _open = false;
  String? _currentSessionId;

  int _sourceGeneration = 0;
  int _subscribeGeneration = 0;
  int _pinnedGeneration = 0;
  int _seedGeneration = 0;
  int _cacheGeneration = 0;
  int _tasksGeneration = 0;
  int _managementGeneration = 0;
  Future<void> _cacheWrite = Future.value();
  SessionsIndexSubscription? _sub;
  VoidCallback? _subStateListener;

  List<SessionEntry> entries = const [];
  bool ready = false;

  /// 最近一次非空实时列表(粘性):快照重放(resync/gap)会把 state.list
  /// 瞬时清空,直接通知会让抽屉闪一下空列表;重放完成前沿用旧列表。
  List<SessionEntry> _lastNonEmpty = const [];
  String? error;

  /// 离线种子(2c):打开抽屉先展示上次缓存,实时数据到达即覆盖。
  List<SessionEntry> seed = const [];

  /// 置顶会话 id 集(spec §7.1 置顶组):抽屉打开时与列表订阅并行经
  /// zcode-task.listPinnedTasks 拉取,失败容错为空集(仅置顶组不显示)。
  Set<String> pinnedIds = const {};

  /// 归档任务(zcode-task `listArchivedTasks`,旧版 task_home 同源):
  /// V4 索引的存量种子会漏归档条目,这里既是归档组的数据源,也提供
  /// _archivedIds 供活跃列表剔除(双向纠偏)。
  List<SessionEntry> archived = const [];
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
  SessionsIndexSubscription? _cachePendingSub;

  /// 当前内嵌会话是否已在实时列表中出现过(A4 消失检测的基准:draft 采纳
  /// 等场景下列表尚未收录该会话不算消失)。
  bool _currentSeen = false;

  /// 索引条目键样本探针只打一次(诊断混入:索引 vs 任务列表的 id 交集)。
  bool _idxProbed = false;

  /// 索引里已见过的会话 id(_maybeRefreshTasksFor 的单调集合)。
  final Set<String> _seenIndexIds = {};

  /// 任务拉取在途标志(周期刷新/未知 id 触发/管理操作可能并发);
  /// 在途期间的再请求不丢弃,完成后续跑一次(最新归属优先)。
  bool _loadingTasks = false;
  bool _reloadQueued = false;

  /// 上次任务归属拉取时刻(毫秒钟)。抽屉打开期间借索引推送(~10s 一跳)
  /// 做刷新时钟:距上次 ≥15s 且抽屉展开 → 重拉。不另起 Timer,避免常驻
  /// 定时器(widget 测试与后台功耗都不友好)。
  int _lastTasksLoadMs = 0;

  /// 管理操作在途(批量/单条共用;视图据此禁用操作栏按钮)。源切换由
  /// [reattach] 复位,与旧行为一致。
  bool acting = false;

  /// 抽屉展开态。置 true 即重拉任务归属——每次展开都拿最新数据
  /// (桌面端可能归档/删除过任务)。
  set open(bool value) {
    _open = value;
    if (value) loadTasks();
  }

  bool get open => _open;

  String? get currentSessionId => _currentSessionId;

  void setCurrentSessionId(String? id) {
    if (id != _currentSessionId) _currentSeen = false;
    _currentSessionId = id;
  }

  /// source 是否已漂移(视图 didUpdateWidget 判定用)。
  bool sourceMatches(BridgeSession bridge, Map<String, dynamic> scope) =>
      identical(bridge, this.bridge) && _scopeKeyOf(scope) == _sourceScopeKey;

  static String _scopeKeyOf(Map<String, dynamic> scope) =>
      '${scope['workspacePath'] ?? ''}\u0000${scope['workspaceIdentity'] ?? ''}';

  bool isCurrentSource(int generation, BridgeSession bridge, String scopeKey) =>
      !_disposed &&
      generation == _sourceGeneration &&
      identical(bridge, this.bridge) &&
      scopeKey == _sourceScopeKey;

  DrawerActionSource captureActionSource(Iterable<String> targetIds) =>
      DrawerActionSource(
        generation: _sourceGeneration,
        bridge: bridge,
        scope: Map<String, dynamic>.from(_scope),
        scopeKey: _sourceScopeKey,
        targets: {
          for (final id in targetIds)
            if (id.isNotEmpty)
              for (final entry in [
                ...entries,
                ..._activeTasks,
                ...archived,
                ...seed,
              ])
                if (entry.sessionId == id) id: entry,
        },
      );

  bool isCurrentActionSource(DrawerActionSource source, String targetId) =>
      targetId.isNotEmpty &&
      source.targets.containsKey(targetId) &&
      isCurrentSource(source.generation, source.bridge, source.scopeKey);

  /// 首次挂载/换源后的启动序列:订阅 + 种子 + 置顶 + 任务归属。
  void start() {
    subscribe();
    _seedFromCache();
    _loadPinned();
    loadTasks();
  }

  /// 换源(bridge/scope 变化):作废全部在途请求与数据,按新 source
  /// 重启。视图侧的多选/管理模式由视图自行复位。
  void reattach(BridgeSession nextBridge, Map<String, dynamic> nextScope) {
    final oldSub = _detachSubscription();
    if (oldSub != null) unawaited(oldSub.dispose());
    _sourceGeneration++;
    _subscribeGeneration++;
    _pinnedGeneration++;
    _seedGeneration++;
    _cacheGeneration++;
    _tasksGeneration++;
    _managementGeneration++;
    bridge = nextBridge;
    _scope
      ..clear()
      ..addAll(nextScope);
    _sourceScopeKey = _scopeKeyOf(_scope);
    transport = bridge.conversation(_scope, onLog: log);
    _loadingTasks = false;
    _reloadQueued = false;
    _cacheSyncedSub = null;
    _cachePendingSub = null;
    _lastNonEmpty = const [];
    entries = const [];
    seed = const [];
    pinnedIds = const {};
    archived = const [];
    _archivedIds = const {};
    _activeTaskIds = const {};
    _activeTasks = const [];
    _tasksLoaded = false;
    _currentSeen = false;
    _idxProbed = false;
    _seenIndexIds.clear();
    acting = false;
    ready = false;
    error = null;
    _notify();
    start();
  }

  void dispose() {
    _disposed = true;
    _sourceGeneration++;
    _subscribeGeneration++;
    _pinnedGeneration++;
    _seedGeneration++;
    _cacheGeneration++;
    _tasksGeneration++;
    _managementGeneration++;
    final sub = _detachSubscription();
    if (sub != null) sub.dispose();
  }

  void _notify() {
    if (!_disposed) onChanged();
  }

  SessionsIndexSubscription? _detachSubscription() {
    final sub = _sub;
    _sub = null;
    if (sub != null) {
      sub.state.removeListener(_subStateListener ?? _onStateChanged);
    }
    _subStateListener = null;
    return sub;
  }

  Future<void> subscribe() async {
    // 重挂路径异步到达时组件可能已卸载(旧订阅 dispose 要等 unsubscribe 应答)。
    if (_disposed) return;
    final generation = _sourceGeneration;
    final session = bridge;
    final scopeKey = _sourceScopeKey;
    final requestGeneration = ++_subscribeGeneration;
    error = null;
    _notify();
    try {
      final sub = await transport.subscribeSessionsIndex();
      if (!isCurrentSource(generation, session, scopeKey) ||
          requestGeneration != _subscribeGeneration) {
        await sub.dispose();
        return;
      }
      final previous = _detachSubscription();
      if (previous != null) unawaited(previous.dispose());
      _sub = sub;
      void listener() {
        if (!isCurrentSource(generation, session, scopeKey) ||
            requestGeneration != _subscribeGeneration ||
            !identical(_sub, sub)) {
          return;
        }
        _onStateChanged();
      }

      _subStateListener = listener;
      sub.state.addListener(listener);
      _onStateChanged();
    } catch (e) {
      if (isCurrentSource(generation, session, scopeKey) &&
          requestGeneration == _subscribeGeneration) {
        error = '$e';
        _notify();
      }
    }
  }

  /// 拉取置顶 id 集(对照桌面端 task_home_page 的 listPinnedTasks:任务
  /// 列表元素带 taskId)。失败容错为空集 —— 置顶组退化为不显示,列表
  /// 其余功能不受影响。
  Future<void> _loadPinned() async {
    final generation = _sourceGeneration;
    final requestGeneration = ++_pinnedGeneration;
    final session = bridge;
    final scopeKey = _sourceScopeKey;
    try {
      final tasks =
          await session.channels.call(Channels.zcodeTask, 'listPinnedTasks', [
        _scope,
      ]);
      if (!isCurrentSource(generation, session, scopeKey) ||
          requestGeneration != _pinnedGeneration) {
        return;
      }
      pinnedIds = {
        for (final t in (tasks is List ? tasks : const <dynamic>[]))
          if (t is Map && t['taskId'] != null) '${t['taskId']}',
      };
      _notify();
    } catch (_) {
      if (isCurrentSource(generation, session, scopeKey) &&
          requestGeneration == _pinnedGeneration) {
        pinnedIds = const {};
        _notify();
      }
    }
  }

  void _onStateChanged() {
    final sub = _sub;
    if (sub == null || _disposed) return;
    final list = sortSessions(sub.state.list);
    if (diagLogEnabled.value) {
      debugPrint('[zflow] _onState ready=${sub.state.ready} n=${list.length}');
    }
    final prevIds = entries.map((e) => e.sessionId).toSet();
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
    entries = list;
    ready = sub.state.ready;
    _notify();
    _notifyCurrentVanished();
    _syncCache(sub);
    _maybeRefreshTasksFor(list);
    // 索引移除了此前活跃的会话(桌面端删除/归档):归属集已过期,重拉
    // 后由 _loadTasks 末尾的补判定决定是否复位(在途旧数据不误判存活)。
    if (_tasksLoaded && prevIds.isNotEmpty) {
      final gone = prevIds.difference(list.map((e) => e.sessionId).toSet());
      if (gone.any(_activeTaskIds.contains)) loadTasks();
    }
  }

  /// 索引出现未见过的会话(本端新建首条落地/桌面新建)→ 重拉任务归属,
  /// 否则新会话要等下次开抽屉才出现在活跃组。_seenIndexIds 单调记录,
  /// 已删任务的孤儿不会反复触发(它们不在任何任务列表里,但只刷新一次)。
  void _maybeRefreshTasksFor(List<SessionEntry> list) {
    if (!_tasksLoaded) return;
    var fresh = false;
    for (final e in list) {
      if (!_seenIndexIds.add(e.sessionId)) continue;
      // 首拉在快照前完成的常态:索引"新面孔"其实已在首拉的任务集里
      // (宿主建任务先于索引收录),归属已知,无需重拉——省掉挂载期的
      // 双份 listTasks/listArchivedTasks。真正未知(本端/桌面新建)才刷。
      if (_activeTaskIds.contains(e.sessionId) ||
          _archivedIds.contains(e.sessionId)) {
        continue;
      }
      fresh = true;
    }
    if (fresh) {
      loadTasks();
      return;
    }
    // 无新面孔时的节流刷新:抽屉展开期间(桌面端可能归档/删除过任务,
    // 索引条目无归档标志,只能重拉归属),距上次拉取 ≥15s 才动手。
    if (_open && DateTime.now().millisecondsSinceEpoch - _lastTasksLoadMs >= 15000) {
      loadTasks();
    }
  }

  /// A4:当前内嵌会话曾出现在实时列表、后又消失(删除/归档)→ 回调宿主
  /// 复位到 draft。仅以「见过再消失」为准,避免 draft 采纳瞬间列表尚未
  /// 收录新会话被误判;订阅失败/未就绪不触发。
  void _notifyCurrentVanished() {
    final id = _currentSessionId;
    if (id == null || id.isEmpty || !ready) return;
    final present = entries.any((e) => e.sessionId == id);
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
      onVanished();
    }
  }

  // ------------------------------------------------------- offline cache

  /// 打开抽屉先 read 播种(2c):仅当实时列表未到达(!ready)时展示,
  /// 真实数据到达即覆盖。种子条目 phase 清空 —— 状态点以实时为准(裁决),
  /// 缓存里的 running/waiting 可能早已过期。
  Future<void> _seedFromCache() async {
    final generation = _sourceGeneration;
    final requestGeneration = ++_seedGeneration;
    final session = bridge;
    final scopeKey = _sourceScopeKey;
    final raw = await _cache.read(_scope);
    if (diagLogEnabled.value) {
      debugPrint('[zflow] seed: ${raw.length} entries');
    }
    if (!isCurrentSource(generation, session, scopeKey) ||
        requestGeneration != _seedGeneration ||
        raw.isEmpty) {
      return;
    }
    seed = [for (final m in raw) SessionEntry({...m, 'phase': ''})];
    _notify();
  }

  /// zcode-task `listTasks` + `listArchivedTasks`(旧版 task_home 同源):
  /// 任务条目是列表主体(_activeTasks),归档组由 archList 条目直构,
  /// 双 id 集供孤儿过滤与 vanished 三重确认。任一失败保留旧数据不 wipe。
  Future<void> loadTasks() async {
    if (_loadingTasks) {
      _reloadQueued = true;
      return;
    }
    _loadingTasks = true;
    final generation = _sourceGeneration;
    final requestGeneration = ++_tasksGeneration;
    final session = bridge;
    final scopeKey = _sourceScopeKey;
    _lastTasksLoadMs = DateTime.now().millisecondsSinceEpoch;
    try {
      Future<(bool, dynamic)> call(String method) => session.channels
          .call(Channels.zcodeTask, method, [_scope])
          .then((r) => (true, r))
          .catchError((Object _) => (false, const <dynamic>[]));
      final (tasksOk, tasksData) = await call('listTasks');
      // 归档并集:listArchivedTasks 是归档列表的显式来源(listTasks 可能
      // 直接不下发归档条目);条目级 archived 标志若在也并入。
      final (archOk, archData) = await call('listArchivedTasks');
      if (!isCurrentSource(generation, session, scopeKey) ||
          requestGeneration != _tasksGeneration) {
        return;
      }
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
      final archivedList = <SessionEntry>[
        // 归档组主体:listArchivedTasks 的条目本身(listTasks 不下发
        // 归档任务,此前误把 archIds 当标记、归档组因此恒空)。
        for (final t in archList)
          if (t is Map && t['taskId'] != null)
            entryOf(t.cast<String, dynamic>(), archived: true),
      ];
      final seenArchived = <String>{for (final e in archivedList) e.sessionId};
      for (final t in list) {
        if (t is! Map) continue;
        final e =
            entryOf(t.cast<String, dynamic>(), archived: t['archived'] == true);
        if (e.isArchived) {
          if (!seenArchived.contains(e.sessionId)) archivedList.add(e);
        } else {
          active.add(e);
        }
      }
      if (diagLogEnabled.value) {
        debugPrint('[zflow] _loadTasks total=${list.length} '
            'active=${active.length} archived=${archivedList.length} '
            'sampleKeys=${list.isEmpty ? '-' : '${(list.first as Map).keys.toList()}'}');
        final actIds = {for (final e in active) e.sessionId};
        final archIds = {for (final e in archivedList) e.sessionId};
        final idxIds = entries.map((e) => e.sessionId).toSet();
        if (idxIds.isNotEmpty) {
          debugPrint('[zflow] _loadTasks x-index: idx=${idxIds.length} '
              'inAct=${idxIds.where(actIds.contains).length} '
              'inArch=${idxIds.where(archIds.contains).length} '
              'orphan=${idxIds.where((id) => !actIds.contains(id) && !archIds.contains(id)).length}');
        }
      }
      // 主体数据落位:任务条目(_activeTasks,索引未收录也照常显示)+
      // 归档组(archList 直构)+ 双 id 集(孤儿过滤与 vanished 三重确认)。
      _activeTasks = active;
      _activeTaskIds = {for (final e in active) e.sessionId};
      archived = archivedList;
      _archivedIds = {for (final e in archivedList) e.sessionId};
      _tasksLoaded = true;
      _notify();
      // 归属更新后再判一次消失:索引移除触发的重拉在此拿到新任务集,
      // 已删除的当前会话此刻才能正确复位(旧集会误判"仍存活")。
      _notifyCurrentVanished();
    } catch (e) {
      log('[诊断] listTasks 拉取失败: $e');
    } finally {
      if (isCurrentSource(generation, session, scopeKey) &&
          requestGeneration == _tasksGeneration) {
        _loadingTasks = false;
        if (_reloadQueued && !_disposed) {
          _reloadQueued = false;
          scheduleMicrotask(loadTasks);
        }
      }
    }
  }

  /// 订阅 ready 后 write(2c):把当前列表落盘,供下次打开时秒开。
  /// 空列表不写(失败/清空不覆盖好数据,与旧实现一致)。write 完成后才
  /// 标记 _cacheSyncedSub:失败或被中断时标记未锁定,下个快照可重试。
  void _syncCache(SessionsIndexSubscription sub) {
    if (!sub.state.ready || _cacheSyncedSub == sub) return;
    final generation = _sourceGeneration;
    final requestGeneration = ++_cacheGeneration;
    final session = bridge;
    final scopeKey = _sourceScopeKey;
    _cachePendingSub = sub;
    final rawEntries = [for (final e in entries) e.raw];
    _cacheWrite = _cacheWrite.then((_) async {
      if (!isCurrentSource(generation, session, scopeKey) ||
          requestGeneration != _cacheGeneration ||
          !identical(_cachePendingSub, sub)) {
        return;
      }
      await _cache.write(_scope, rawEntries);
      if (isCurrentSource(generation, session, scopeKey) &&
          requestGeneration == _cacheGeneration &&
          identical(_cachePendingSub, sub)) {
        _cacheSyncedSub = sub;
        _cachePendingSub = null;
      }
    });
  }

  /// 活跃显示列表 = 任务条目为主体 + 索引富化(旧版 task_home 骨架):
  ///
  /// - 索引收录且属于活跃任务的条目 → 用索引字段(preview/实时
  ///   phase/桌面端生成的标题),每次索引推送即时刷新;
  /// - 索引还没收录的活跃任务(桌面端新建,快照秒级滞后)→ 任务条目
  ///   照常显示(旧版容差,曾在此版倒置中丢失);
  /// - 已归档(_archivedIds)与已删任务的孤儿(不在任何任务列表)的
  ///   索引条目不引入——sessions-index 会广播它们且条目无归档标志,
  ///   归档组走 archived,孤儿隐藏(与桌面端任务列表一致)。
  /// 任务未载回前(!_tasksLoaded)按索引原样展示,载回即收敛。
  List<SessionEntry> get displayActive {
    if (!_tasksLoaded) return entries;
    final byId = <String, SessionEntry>{};
    for (final e in entries) {
      if (_archivedIds.contains(e.sessionId)) continue;
      if (!_activeTaskIds.contains(e.sessionId)) continue;
      byId[e.sessionId] = e;
    }
    for (final t in _activeTasks) {
      byId.putIfAbsent(t.sessionId, () => t);
    }
    return sortSessions(byId.values.toList());
  }

  // ------------------------------------------------------- manage actions

  Map<String, dynamic> taskArgs(String sessionId,
          {bool? pinned, Map<String, dynamic>? scope}) =>
      {
        'taskId': sessionId,
        ...(scope ?? _scope),
        'pinned': ?pinned,
      };

  /// 批量置顶/归档/删除。列表归属以任务列表为准、字段以索引推送富化:
  /// 不做乐观移除,操作完成后重拉任务集并等索引刷新。[pinned] 仅
  /// setTaskPinned 需要(抽屉无取消置顶语义,恒 true;对照
  /// integration_test 服务端契约)。多选集合由视图传入,操作完成经
  /// [onFinished] 上抛失败数,由视图退出管理模式并提示。
  Future<void> applySelection(
    String method, {
    required Set<String> selected,
    bool? pinned,
    DrawerActionSource? actionSource,
    required void Function(int failed) onFinished,
  }) async {
    if (acting || selected.isEmpty) return;
    final source = actionSource ?? captureActionSource(selected);
    if (source.targetIds.length != selected.length ||
        !selected.every(source.targetIds.contains) ||
        !selected.every((id) => isCurrentActionSource(source, id))) {
      return;
    }
    final managementGeneration = ++_managementGeneration;
    acting = true;
    _notify();
    var failed = 0;
    for (final id in selected) {
      if (!isCurrentActionSource(source, id) ||
          managementGeneration != _managementGeneration) {
        // 源已切换(reattach 复位 acting)或新管理操作接管(其自己
        // 管理 acting):此处直接退出,不触碰状态。
        return;
      }
      try {
        final res = await source.bridge.channels.call(Channels.zcodeTask,
            method, [taskArgs(id, pinned: pinned, scope: source.scope)]);
        if (isRpcRejected(res)) throw Exception(rpcFailureReason(res));
      } catch (_) {
        failed++;
      }
    }
    if (!isCurrentSource(source.generation, source.bridge, source.scopeKey) ||
        managementGeneration != _managementGeneration) {
      return;
    }
    acting = false;
    _notify();
    onFinished(failed);
    // 操作(置顶/归档/删除)改变置顶集与归档集 → 重拉刷新分组。
    unawaited(_loadPinned());
    unawaited(loadTasks());
  }

  /// 单条 zcode-task 管理操作:source 预检、generation 守卫 RPC、失败
  /// 文案经 [onError] 上抛(视图负责展示)、完成后重拉归属。
  Future<void> itemAction(
    String method,
    SessionEntry entry, {
    Map<String, dynamic>? args,
    DrawerActionSource? actionSource,
    required void Function(String message) onError,
  }) async {
    final source = actionSource ?? captureActionSource([entry.sessionId]);
    if (!isCurrentActionSource(source, entry.sessionId)) return;
    final managementGeneration = ++_managementGeneration;
    if (!isCurrentActionSource(source, entry.sessionId)) return;
    try {
      final res = await source.bridge.channels.call(Channels.zcodeTask,
          method, [args ?? taskArgs(entry.sessionId, scope: source.scope)]);
      // 无 status 直接返回保持兼容;明确 rejected 走错误提示。
      if (isRpcRejected(res)) throw Exception(rpcFailureReason(res));
    } catch (e) {
      if (!isCurrentActionSource(source, entry.sessionId) ||
          managementGeneration != _managementGeneration) {
        return;
      }
      onError('$e');
      return;
    }
    if (!isCurrentActionSource(source, entry.sessionId) ||
        managementGeneration != _managementGeneration) {
      return;
    }
    unawaited(_loadPinned());
    unawaited(loadTasks());
  }
}

/// 一次管理操作执行时的 source 快照(generation + bridge + scope + 目标
/// 条目)。RPC 返回后逐项比对,漂移即放弃写回。
class DrawerActionSource {
  final int generation;
  final BridgeSession bridge;
  final Map<String, dynamic> scope;
  final String scopeKey;
  final Map<String, SessionEntry> targets;

  DrawerActionSource({
    required this.generation,
    required this.bridge,
    required this.scope,
    required this.scopeKey,
    required this.targets,
  });

  Set<String> get targetIds => targets.keys.toSet();
}
