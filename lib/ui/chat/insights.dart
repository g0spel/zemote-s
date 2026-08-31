// 此文件是 chat_page.dart 的一部分(part):同库共享导入与私有类可见。
part of '../chat_page.dart';

/// Mirrors the desktop host's remote todo derivation: find tool-call rows
/// whose tool name matches todo read/write / update_plan, take the latest,
/// and extract a todos/plan/steps/items array from its payload (raw map or
/// JSON string, from input / output / output.text). All-or-nothing: one
/// malformed item discards the row.
class PlanStep {
  final String id;
  final String title;
  final String status; // pending | in_progress | completed

  const PlanStep({required this.id, required this.title, required this.status});

  bool get completed => status == 'completed';
  bool get inProgress => status == 'in_progress';
}

final _todoPlanToolName = RegExp(
    r'(?:^|[_\s-])(?:todo[_\s-]*(?:read|write)|update[_\s-]*plan)(?:$|[_\s-])',
    caseSensitive: false);

String? _normalizePlanStatus(Object? v) {
  final t = '$v'.replaceAll('-', '_').toLowerCase();
  return t == 'pending' || t == 'in_progress' || t == 'completed' ? t : null;
}

PlanStep? _parsePlanStep(Object? item, int index) {
  if (item is String) {
    final t = item.trim();
    return t.isEmpty
        ? null
        : PlanStep(
            id: t, title: t, status: index == 0 ? 'in_progress' : 'pending');
  }
  if (item is! Map) return null;
  final m = item.cast<String, dynamic>();
  String? str(Object? v) {
    if (v is! String) return null; // host's readString: strings only
    final s = v.trim();
    return s.isEmpty ? null : s;
  }

  final title = str(m['content']) ??
      str(m['step']) ??
      str(m['title']) ??
      str(m['text']) ??
      str(m['activeForm']);
  final status = _normalizePlanStatus(m['status']);
  if (title == null || status == null) return null;
  return PlanStep(id: str(m['id']) ?? title, title: title, status: status);
}

List<PlanStep>? deriveTodoSteps(List<Map<String, dynamic>> rows) {
  for (final row in rows.reversed) {
    final name =
        '${row['toolName'] ?? ''} ${row['title'] ?? ''} ${row['kind'] ?? ''}';
    if (name.trim().isEmpty || !_todoPlanToolName.hasMatch(name)) continue;
    for (final cand in _planPayloadCandidates(row)) {
      final steps = _planStepsFromValue(cand);
      if (steps != null) return steps;
    }
  }
  return null;
}

List<Object?> _planPayloadCandidates(Map<String, dynamic> row) {
  final output = row['output'];
  final out = <Object?>[row['input'], row['inputText'], row['content'], output];
  if (output is Map) out.add(output['text']);
  return out;
}

List<PlanStep>? _planStepsFromValue(Object? v) {
  Object? t = v;
  if (t is String) {
    try {
      t = jsonDecode(t);
    } catch (_) {
      return null;
    }
  }
  // 裸数组(todo 工具常见的输出形状)视同单键列表。
  if (t is List) return _stepsFromArray(t);
  if (t is! Map) return null;
  for (final k in const ['todos', 'plan', 'steps', 'items']) {
    final arr = t[k];
    if (arr is! List || arr.isEmpty) continue;
    return _stepsFromArray(arr);
  }
  return null;
}

List<PlanStep>? _stepsFromArray(List arr) {
  if (arr.isEmpty) return null;
  final steps = <PlanStep>[];
  for (var i = 0; i < arr.length; i++) {
    final s = _parsePlanStep(arr[i], i);
    if (s == null) return null; // all-or-nothing
    steps.add(s);
  }
  return steps;
}

/// Heuristic list extraction for insight panels: recognizes a direct list
/// or `data[one of keys]` as a list of maps. Returns null when the shape is
/// unrecognized (panels then fall back to a raw JSON view — data is never
/// hidden just because the shape changed).
List<Map<String, dynamic>>? parseInsightList(dynamic data, List<String> keys,
    {bool allowEmpty = false}) {
  dynamic list = data is List ? data : null;
  if (data is Map) {
    for (final k in keys) {
      if (data[k] is List) {
        list = data[k];
        break;
      }
    }
  }
  if (list is List && list.every((e) => e is Map)) {
    final mapped =
        list.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList();
    if (mapped.isNotEmpty || allowEmpty) return mapped;
  }
  return null;
}

/// Terminal statuses of an inline `subagent` row (host schema:
/// `status: running|success|failed|cancelled`).
const subagentTerminalStatuses = {'success', 'failed', 'cancelled'};

/// Inline `subagent` rows that have FINISHED, in conversation order. The
/// conversation snapshot's `subagents` block lists only RUNNING subagents
/// plus a bare `endedTotal` count — the summary and terminal status of a
/// finished subagent live solely in its inline row. Pure for tests.
List<Map<String, dynamic>> endedSubagentRows(List<Map<String, dynamic>> rows) {
  return rows
      .where((r) =>
          r['kind'] == 'subagent' &&
          subagentTerminalStatuses.contains('${r['status']}'))
      .toList();
}

/// 容错解析 conversationPlansV4 响应(桌面计划)。宿主形状未承诺:接受
/// `{plans|items|steps|todos: [...]}`、裸数组或单个计划对象;条目沿用
/// PlanStep 的宽容解析(all-or-nothing)。无可识别结构返回 null(UI 隐藏
/// 该段,不报错)。Pure for tests.
List<PlanStep>? parseHostPlans(Object? res) {
  Object? list = res;
  if (res is Map) {
    for (final k in const ['plans', 'items', 'steps', 'todos']) {
      final v = res[k];
      if (v is List) {
        list = v;
        break;
      }
    }
  }
  if (list is Map) {
    final one = _parsePlanStep(list, 0);
    return one == null ? null : [one];
  }
  if (list is! List || list.isEmpty) return null;
  final steps = <PlanStep>[];
  for (var i = 0; i < list.length; i++) {
    final s = _parsePlanStep(list[i], i);
    if (s == null) return null;
    steps.add(s);
  }
  return steps;
}

/// The latest turnHeader of a COMPLETED turn (`state: completedSuccess`
/// with a usable {rowId, entityId}) — the official client's armed target
/// for file-changes loading. A still-running turn must not be queried: the
/// server guard races the streaming revision and rejects it as stale.
/// Pure for tests.
Map<String, dynamic>? latestCompletedTurn(List<Map<String, dynamic>> rows) {  for (final r in rows.reversed) {
    if (r['kind'] != 'turnHeader' || r['state'] != 'completedSuccess') {
      continue;
    }
    if (r['rowId'] == null || r['entityId'] is! String) continue;
    return r;
  }
  return null;
}

/// 后台把手计数徽(spec §7.1 洞察 sheet):运行中的后台任务(无 endedAt
/// 的 running)+ 消息流内联 subagent 行,与后台面板的条目口径一致。
/// Pure for tests.
int insightsBgCount({
  required List<Map<String, dynamic>> backgroundWorks,
  required List<Map<String, dynamic>> rows,
}) {
  return backgroundWorks
          .where((w) => w['status'] == 'running' && w['endedAt'] == null)
          .length +
      rows.where((r) => r['kind'] == 'subagent').length;
}

/// Cached row/snapshot derivations for one insights sheet. Row-only values use
/// ConversationState.rowsVersion; snapshot values use snapshot identity because
/// state.updated does not change rowsVersion.
class _InsightsDerivedCache {
  ConversationState? _state;
  int _rowsVersion = -1;
  Object? _snapshot;
  bool _snapshotInitialized = false;

  List<PlanStep>? todoSteps;
  Map<String, dynamic>? latestCompleted;
  List<Map<String, dynamic>> endedSubagents = const [];
  int turnFileTotal = 0;
  int bgCount = 0;
  List<Map<String, dynamic>> fileHeaders = const [];

  /// turnHeader rowId → 回合序号(自会话起点从 1 计数),文件面板分组
  /// 标题用。
  Map<String, int> turnNumbers = const {};
  List<Map<String, dynamic>> backgroundWorks = const [];
  List<Map<String, dynamic>>? runningSubagents;
  int endedSubagentTotal = 0;
  List<Map<String, dynamic>>? planItems;
  Map<String, dynamic>? goal;

  void sync(ConversationState state) {
    final rowsChanged =
        !identical(_state, state) || _rowsVersion != state.rowsVersion;
    if (rowsChanged) {
      _state = state;
      _rowsVersion = state.rowsVersion;
      todoSteps = deriveTodoSteps(state.rows);
      latestCompleted = latestCompletedTurn(state.rows);
      endedSubagents = endedSubagentRows(state.rows);
      var files = 0;
      var turnCounter = 0;
      final headers = <Map<String, dynamic>>[];
      final numbers = <String, int>{};
      for (final row in state.rows) {
        if (row['kind'] != 'turnHeader') continue;
        turnCounter++;
        numbers['${row['rowId']}'] = turnCounter;
        final fileChanges = row['fileChanges'];
        if (fileChanges is! Map) continue;
        final count = (fileChanges['files'] as num?)?.toInt() ?? 0;
        files += count;
        if (count > 0) headers.add(row);
      }
      turnFileTotal = files;
      turnNumbers = numbers;
      fileHeaders = headers.reversed.toList(growable: false);
    }

    final snapshot = state.snapshot;
    final snapshotChanged =
        !_snapshotInitialized || !identical(_snapshot, snapshot);
    if (snapshotChanged) {
      _snapshotInitialized = true;
      _snapshot = snapshot;
      planItems = parseInsightList(state.plan ?? const {}, const ['items'],
          allowEmpty: false);
      goal = state.goal;
      backgroundWorks = state.backgroundWorks;
      final subsObj = snapshot?['subagents'];
      final subs = subsObj is Map ? subsObj.cast<String, dynamic>() : null;
      runningSubagents =
          subs == null ? null : parseInsightList(subs['running'], const []);
      endedSubagentTotal = (subs?['endedTotal'] as num?)?.toInt() ?? 0;
    }
    if (rowsChanged || snapshotChanged) {
      bgCount =
          insightsBgCount(backgroundWorks: backgroundWorks, rows: state.rows);
    }
  }
}

String _insightsTurnKey(
    ConversationState state, String sessionId, Map<String, dynamic>? turn) {
  if (turn == null) return '';
  return '$sessionId|${state.logEpoch ?? ''}|${turn['rowId']}|${turn['entityId']}';
}

/// 洞察底部 sheet(spec §7.1):62% 高升起、可拖至全屏;三 chip 切换
/// 待办/文件/后台面板。数据逻辑自 _InsightsRowState 整体平移——文件
/// 的 fire-once 预加载与 stale 重试语义保持(sheet 打开期间每个新完成
/// 回合只拉一次;选「文件」chip 时无数据才补拉)。公开给测试。
/// (原输入区上方把手已删,打开入口迁入 composer 图标行,用户裁定。)
class InsightsSheet extends StatefulWidget {
  final ConversationState state;
  final ConversationTransport transport;
  final String sessionId;
  final bool Function()? isSourceCurrent;

  /// DraggableScrollableSheet 的滚动控制器,接入各面板主列表,让列表
  /// 区域的拖拽可以展开/收起 sheet。
  final ScrollController scrollController;

  const InsightsSheet({
    super.key,
    required this.state,
    required this.transport,
    required this.sessionId,
    required this.scrollController,
    this.isSourceCurrent,
  });

  @override
  State<InsightsSheet> createState() => _InsightsSheetState();
}

class _InsightsSheetState extends State<InsightsSheet> {
  static const _todo = 0, _files = 1, _bg = 2;

  int _tab = _todo;

  /// 文件面板按回合装载:rowId → 已拉取条目/错误/展开态。
  final Map<String, List<Map<String, dynamic>>> _turnEntries = {};
  final Map<String, String> _turnErrors = {};
  final Set<String> _turnExpanded = {};
  final Set<String> _turnLoading = {};

  /// 后台面板已展开项(workId/rowId 键)。
  final Set<String> _bgExpanded = {};

  /// 已装载过的最新完成回合（arming 模式,对齐 web 客户端:回合完成
  /// 即自动装载一次）。
  String? _loadedTurnKey;
  int _fileRequestGeneration = 0;
  final _derived = _InsightsDerivedCache();

  /// 宿主计划(conversationPlansV4):sheet 打开时拉取一次;解析不出
  /// 可识别结构则为 null(隐藏该段),失败静默。
  List<PlanStep>? _hostPlans;
  bool _hostPlansLoading = false;

  bool _isSourceCurrent() => widget.isSourceCurrent?.call() ?? true;

  @override
  void initState() {
    super.initState();
    _syncDerived();
    widget.state.addListener(_onStateChanged);
    _onStateChanged();
    _loadHostPlans();
  }

  /// 宿主计划拉取:响应形状未承诺,parseHostPlans 容错;失败按无计划
  /// 处理,不打扰面板其余功能。
  Future<void> _loadHostPlans() async {
    if (_hostPlans != null || _hostPlansLoading) return;
    _hostPlansLoading = true;
    try {
      final res = await widget.transport.plans(widget.sessionId);
      if (!mounted || !_isSourceCurrent()) return;
      setState(() => _hostPlans = parseHostPlans(res));
    } catch (_) {
      if (mounted) setState(() => _hostPlans = const []);
    } finally {
      _hostPlansLoading = false;
    }
  }

  void _syncDerived() {
    _derived.sync(widget.state);
  }

  @override
  void didUpdateWidget(InsightsSheet oldWidget) {
    super.didUpdateWidget(oldWidget);
    final sourceChanged = oldWidget.state != widget.state ||
        oldWidget.transport != widget.transport ||
        oldWidget.sessionId != widget.sessionId;
    if (sourceChanged) {
      if (oldWidget.state != widget.state) {
        oldWidget.state.removeListener(_onStateChanged);
        widget.state.addListener(_onStateChanged);
      }
      _fileRequestGeneration++;
      _loadedTurnKey = null;
      _turnEntries.clear();
      _turnErrors.clear();
      _turnExpanded.clear();
      _turnLoading.clear();
      _hostPlans = null;
      _hostPlansLoading = false;
      _loadHostPlans();
    }
    _syncDerived();
    _onStateChanged();
  }

  @override
  void dispose() {
    widget.state.removeListener(_onStateChanged);
    super.dispose();
  }

  void _onStateChanged() {
    if (!mounted || !_isSourceCurrent()) return;
    _syncDerived();
    final turn = _derived.latestCompleted;
    final key = _insightsTurnKey(widget.state, widget.sessionId, turn);
    if (key.isEmpty) {
      _fileRequestGeneration++;
      _loadedTurnKey = null;
    } else if (key != _loadedTurnKey) {
      // 最新完成回合自动装载并展开:当前回合一结束就能看到编辑明细。
      _loadedTurnKey = key;
      if (turn != null) {
        _turnExpanded.add('${turn['rowId']}');
        unawaited(_loadTurnFiles(turn));
      }
    }
    setState(() {});
  }

  void _selectTab(int index) {
    if (!_isSourceCurrent()) return;
    setState(() => _tab = index);
    // 切到文件 Tab 时,若最新完成回合还没装载过就先装载它。
    if (_tab == _files && _loadedTurnKey == null) {
      final turn = _derived.latestCompleted;
      if (turn != null) unawaited(_loadTurnFiles(turn));
    }
  }

  /// File changes are turn-scoped: the target must be the turnHeader of a
  /// COMPLETED turn (the running turn's guard races the streaming
  /// revision). baseRevision/baseLogEpoch are read inside the transport.
  /// 结果按回合 rowId 缓存,展开时按需装载。
  Future<void> _loadTurnFiles(Map<String, dynamic> header) async {
    final key = '${header['rowId']}';
    if (_turnLoading.contains(key) || _turnEntries.containsKey(key)) return;
    final sourceState = widget.state;
    final sourceTransport = widget.transport;
    final sourceSessionId = widget.sessionId;
    if (!_isSourceCurrent()) return;
    final requestGeneration = ++_fileRequestGeneration;
    bool isCurrent() =>
        mounted &&
        requestGeneration == _fileRequestGeneration &&
        _isSourceCurrent() &&
        identical(widget.state, sourceState) &&
        identical(widget.transport, sourceTransport) &&
        widget.sessionId == sourceSessionId;
    _turnLoading.add(key);
    if (mounted) setState(() {});
    try {
      final res = await sourceTransport.fileChanges(
        sourceSessionId,
        target: {'rowId': header['rowId'], 'entityId': header['entityId']},
      );
      if (!isCurrent()) return;
      final entries = parseInsightList(
          res, const ['files', 'changes', 'fileChanges', 'items'],
          allowEmpty: true);
      _turnEntries[key] = entries ?? const [];
      _turnErrors[key] = _turnEntries[key]!.isEmpty ? '无文件变更数据' : '';
    } catch (e) {
      if (!isCurrent()) return;
      _turnErrors[key] = _fmtRpcError(e);
    } finally {
      _turnLoading.remove(key);
      if (isCurrent()) setState(() {});
    }
  }

  void _toggleTurnFiles(Map<String, dynamic> header) {
    final key = '${header['rowId']}';
    if (_turnExpanded.contains(key)) {
      _turnExpanded.remove(key);
      setState(() {});
      return;
    }
    _turnExpanded.add(key);
    setState(() {});
    final headerState = '${header['state']}';
    if (headerState == 'completedSuccess') unawaited(_loadTurnFiles(header));
  }

  /// ChannelRpcError often carries the real cause in [ChannelRpcError.data]
  /// with an empty message — surface both.
  static String _fmtRpcError(Object e) {
    if (e is ChannelRpcError) {
      final msg = e.message.isEmpty ? '(服务端未返回错误信息)' : e.message;
      return e.data == null ? msg : '$msg · ${e.data}';
    }
    return '$e';
  }

  int get _todoCount {
    _syncDerived();
    var n = _derived.todoSteps?.length ?? 0;
    final planItems = _derived.planItems;
    // Plan-mode progress counts toward the chip when no TodoWrite todos
    // exist (the plan IS the active checklist then).
    if (n == 0 && planItems != null) n = planItems.length;
    return n;
  }

  int get _turnFileTotal {
    _syncDerived();
    return _derived.turnFileTotal;
  }

  int get _bgCount {
    _syncDerived();
    return _derived.bgCount;
  }

  @override
  Widget build(BuildContext context) {
    final ember = EmberColors.of(context);
    return Container(
      decoration: BoxDecoration(
        color: ember.raise,
        borderRadius: const BorderRadius.vertical(
            top: Radius.circular(EmberRadius.sheet)),
      ),
      // 底部 SafeArea:手势条区域不遮挡面板内容。
      child: SafeArea(
        top: false,
        child: Column(
          children: [
            // sheet 顶部把手条(与输入区把手同形,提示可拖拽)。
            Center(
              child: Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(top: 8, bottom: 4),
                decoration: BoxDecoration(
                  color: ember.textFaint,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 6, 14, 6),
              child: Row(
                children: [
                  _chip(context, _todo, Icons.checklist_outlined, '待办',
                      _todoCount),
                  const SizedBox(width: 6),
                  _chip(context, _files, Icons.folder_outlined, '文件',
                      _turnFileTotal),
                  const SizedBox(width: 6),
                  _chip(context, _bg, Icons.hub_outlined, '后台', _bgCount),
                ],
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: EmberColors.of(context).card,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: switch (_tab) {
                    _todo => _todoPanel(context),
                    _files => _filesPanel(context),
                    _ => _bgPanel(context),
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _chip(BuildContext context, int index, IconData icon, String label,
      int? count) {
    final selected = _tab == index;
    return Expanded(
      child: GestureDetector(
        onTap: () => _selectTab(index),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 6),
          decoration: BoxDecoration(
            color: selected
                ? EmberColors.of(context).primary.withValues(alpha: 0.14)
                : EmberColors.of(context).card,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon,
                  size: 14,
                  color: selected
                      ? EmberColors.of(context).primary
                      : EmberColors.of(context).textSoft),
              const SizedBox(width: 4),
              Text(
                count != null ? '$label $count' : label,
                style: TextStyle(
                  fontSize: 11.5,
                  color: selected
                      ? EmberColors.of(context).primary
                      : EmberColors.of(context).textSoft,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 待办面板内的小节标题(计划进度/待办/计划)。
  Widget _sectionLabel(String text) {
    return Padding(
      padding: const EdgeInsets.only(top: 6, bottom: 2),
      child: Text(text,
          style: TextStyle(
              fontSize: 10.5, color: EmberColors.of(context).textFaint)),
    );
  }

  Widget _panelHeader(
      BuildContext context, String title, VoidCallback onRefresh,
      {bool loading = false}) {
    return Row(
      children: [
        Text(title,
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),        const Spacer(),
        if (loading)
          const SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(strokeWidth: 1.5))
        else
          GestureDetector(
            onTap: onRefresh,
            child: Icon(Icons.refresh,
                size: 15, color: EmberColors.of(context).textFaint),
          ),
      ],
    );
  }

  Widget _errorRow(String error, VoidCallback onRetry) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('加载失败: $error',
            style: TextStyle(fontSize: 11, color: EmberColors.of(context).err),
            maxLines: 2,
            overflow: TextOverflow.ellipsis),
        TextButton(onPressed: onRetry, child: const Text('重试')),
      ],
    );
  }

  // ------------------------------------------------------------ todo panel

  Widget _todoPanel(BuildContext context) {
    _syncDerived();
    final steps = _derived.todoSteps;
    // Plan-mode progress from the conversation snapshot
    // (plan: {items: [{id, content, status: pending|inProgress|completed}],
    // updatedAt}). Displayed INSIDE the todo panel — progress of the
    // structured plan, not a separate surface.
    final parsedPlanItems = _derived.planItems;
    final planItems = (parsedPlanItems == null || parsedPlanItems.isEmpty)
        ? null
        : parsedPlanItems;
    // 会话里有结构化执行计划时只显示计划:宿主侧计划与 TodoWrite 由
    // 同一代理流程驱动,内容一致——此前两段并列显示,用户看到两份
    // 一模一样的清单。无计划时退回 TodoWrite 待办。
    final todoSteps =
        planItems != null ? const <PlanStep>[] : (steps ?? const <PlanStep>[]);
    // 会话目标(Goal):快照 goal 对象。文本字段以 goalSet 事件同名的
    // objective 为准(wire 实证),缺失时退 text/goal;status 映射状态徽。
    final goal = _derived.goal;
    final goalText = goal == null
        ? null
        : '${goal['objective'] ?? goal['text'] ?? goal['goal'] ?? ''}'.trim();
    final hasGoal = goalText != null && goalText.isNotEmpty;
    final (goalLabel, goalColor) = switch ('${goal?['status'] ?? ''}') {
      'running' => ('进行中', EmberColors.of(context).primary),
      'paused' => ('已暂停', EmberColors.of(context).warn),
      'verified' => ('已验证', EmberColors.of(context).ok),
      _ => ('', EmberColors.of(context).textFaint),
    };
    final hostPlans = _hostPlans;
    final colors = EmberColors.of(context);

    Widget stepRow({required String title, required bool completed, required bool inProgress}) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              completed
                  ? Icons.check_circle
                  : inProgress
                      ? Icons.play_circle_outline
                      : Icons.radio_button_unchecked,
              size: 14,
              color: completed
                  ? colors.ok
                  : inProgress
                      ? colors.primary
                      : colors.textFaint,
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                title,
                style: TextStyle(
                  fontSize: 11.5,
                  color: completed ? colors.textFaint : colors.textSolid,
                  decoration: completed ? TextDecoration.lineThrough : null,
                ),
              ),
            ),
          ],
        ),
      );
    }

    final sections = <Widget>[];
    if (hasGoal) {
      final running = '${goal?['status']}' == 'running';
      final paused = '${goal?['status']}' == 'paused';
      sections.add(Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(EmberRadius.control),
            border: Border.all(color: colors.hairline),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.adjust, size: 13, color: colors.primary),
              const SizedBox(width: 6),
              Expanded(
                child: Text(goalText,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 11.5, color: colors.textSolid)),
              ),
              if (goalLabel.isNotEmpty) ...[
                const SizedBox(width: 6),
                Text(goalLabel,
                    style: TextStyle(
                        fontSize: 10.5,
                        fontWeight: FontWeight.w600,
                        color: goalColor)),
              ],
              // 开始/暂停目标(桌面同款):运行中可暂停,已暂停可开始。
              if ((running || paused) && widget.sessionId.isNotEmpty)
                IconButton(
                  visualDensity:
                      const VisualDensity(horizontal: -4, vertical: -4),
                  constraints:
                      const BoxConstraints(minWidth: 28, minHeight: 28),
                  padding: EdgeInsets.zero,
                  icon: Icon(
                    running
                        ? Icons.pause_circle_outline
                        : Icons.play_circle_outline,
                    size: 18,
                    color: colors.primary,
                  ),
                  tooltip: running ? '暂停目标' : '开始目标',
                  onPressed: () => _toggleGoal(widget.state),
                ),
            ],
          ),
        ),
      ));
    }
    if (planItems != null) {
      final done =
          planItems.where((e) => '${e['status']}' == 'completed').length;
      sections.add(_sectionLabel('计划进度 · $done / ${planItems.length}'));
      for (final item in planItems) {
        final status = '${item['status']}';
        sections.add(stepRow(
          title: '${item['content'] ?? item['id'] ?? ''}',
          completed: status == 'completed',
          inProgress: status == 'inProgress',
        ));
      }
    } else if (todoSteps.isNotEmpty) {
      sections.add(_sectionLabel('待办（最新 TodoWrite）'));
      for (final s in todoSteps) {
        sections.add(stepRow(
            title: s.title,
            completed: s.completed,
            inProgress: s.inProgress));
      }
    }
    if (hostPlans != null && hostPlans.isNotEmpty) {
      sections.add(_sectionLabel('计划（宿主）'));
      for (final s in hostPlans) {
        sections.add(stepRow(
            title: s.title,
            completed: s.completed,
            inProgress: s.inProgress));
      }
    }
    if (sections.isEmpty) {
      sections.add(Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Text('暂无待办',
            style: TextStyle(fontSize: 11.5, color: colors.textFaint)),
      ));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _panelHeader(context, '目标', () {}),
        Flexible(
          child: ListView(
            controller: widget.scrollController,
            physics: const AlwaysScrollableScrollPhysics(),
            shrinkWrap: true,
            children: sections,
          ),
        ),
      ],
    );
  }

  /// 目标 开始/暂停(桌面同款):乐观置状态,宿主确认后回读一致。
  Future<void> _toggleGoal(ConversationState state) async {
    if (!_isSourceCurrent() || widget.sessionId.isEmpty) return;
    final goal = state.goal;
    if (goal == null) return;
    final running = '${goal['status']}' == 'running';
    try {
      if (running) {
        await widget.transport.pauseGoal(widget.sessionId);
        state.optimisticPatch({
          'goal': {...goal, 'status': 'paused'},
        });
      } else {
        await widget.transport.resumeGoal(widget.sessionId);
        state.optimisticPatch({
          'goal': {...goal, 'status': 'running'},
        });
      }
    } catch (_) {
      // 失败保持原状态;宿主状态回读会纠正。
    }
  }

  // ----------------------------------------------------------- files panel

  Widget _filesPanel(BuildContext context) {
    _syncDerived();
    final headers = _derived.fileHeaders;

    Widget body;
    if (headers.isEmpty) {
      body = Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Text('暂无文件变更数据',
            style: TextStyle(
                fontSize: 11.5,
                color: EmberColors.of(context).textFaint)),
      );
    } else {
      // 接入 sheet 滚动控制器(与目标/后台面板一致):多个回合分组同时
      // 展开时内容可滚动,不再溢出截断。
      body = ListView(
        controller: widget.scrollController,
        physics: const AlwaysScrollableScrollPhysics(),
        shrinkWrap: true,
        children: [
          for (var i = 0; i < headers.length; i++)
            _turnFileRow(context, headers[i],
                _derived.turnNumbers['${headers[i]['rowId']}'])
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _panelHeader(context, '编辑', _refreshFiles,
            loading: _turnLoading.isNotEmpty),
        Flexible(child: body),
      ],
    );
  }

  /// 回合文件变更行(桌面变更面板样式):「回合 N」分组标题 + 摘要行可
  /// 点,展开后显示该回合逐文件明细;运行中的回合尚不能查询(服务端
  /// stale guard),仅显状态。
  Widget _turnFileRow(BuildContext context, Map<String, dynamic> header,
      int? turnNumber) {
    final colors = EmberColors.of(context);
    final fc = header['fileChanges'] as Map? ?? const {};
    final files = (fc['files'] as num?)?.toInt() ?? 0;
    final adds = (fc['additions'] as num?)?.toInt();
    final dels = (fc['deletions'] as num?)?.toInt();
    final key = '${header['rowId']}';
    final completed = '${header['state']}' == 'completedSuccess';
    final expanded = _turnExpanded.contains(key);
    final loading = _turnLoading.contains(key);
    final error = _turnErrors[key];
    final entries = _turnEntries[key];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: completed ? () => _toggleTurnFiles(header) : null,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 5),
            child: Row(
              children: [
                Text(expanded ? '▾' : '▸',
                    style: TextStyle(
                        fontSize: 10.5, color: colors.textFaint)),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                      // 分组标题(用户裁定):回合序号区分多个分组。
                      turnNumber != null
                          ? '回合 $turnNumber · $files 个文件已更改'
                          : '$files 个文件已更改',
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: completed
                              ? colors.textSolid
                              : colors.textMuted)),
                ),
                if (!completed)
                  Text('运行中',
                      style: TextStyle(fontSize: 10.5, color: colors.warn))
                else ...[
                  if (adds != null && adds > 0)
                    Text('+$adds',
                        style: TextStyle(fontSize: 10.5, color: colors.ok)),
                  if (dels != null && dels > 0) ...[
                    const SizedBox(width: 6),
                    Text('-$dels',
                        style: TextStyle(fontSize: 10.5, color: colors.err)),
                  ],
                ],
              ],
            ),
          ),
        ),
        if (expanded) ...[
          if (loading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 6),
              child: SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 1.5)),
            )
          else if (error != null && error.isNotEmpty)
            _errorRow(error, () => _loadTurnFiles(header))
          else if (entries == null || entries.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Text('本回合无文件变更',
                  style: TextStyle(
                      fontSize: 11, color: colors.textFaint)),
            )
          else
            for (final e in entries) _fileTile(context, e),
        ],
      ],
    );
  }

  /// 手动刷新:重载已展开回合;未展开任何回合时装载最新完成回合。
  void _refreshFiles() {
    _syncDerived();
    var refreshed = false;
    for (final h in _derived.fileHeaders) {
      final key = '${h['rowId']}';
      if (_turnExpanded.contains(key)) {
        _turnEntries.remove(key);
        _turnErrors.remove(key);
        unawaited(_loadTurnFiles(h));
        refreshed = true;
      }
    }
    if (!refreshed) {
      final turn = _derived.latestCompleted;
      if (turn != null) {
        _turnExpanded.add('${turn['rowId']}');
        unawaited(_loadTurnFiles(turn));
      }
    }
    if (mounted) setState(() {});
  }

  void _showFileDetail(BuildContext context, Map<String, dynamic> e) {
    if (!_isSourceCurrent()) return;
    final path = e['path'] ?? e['filePath'] ?? e['file'] ?? e['name'] ?? '文件';
    DiffData? diff = extractDiff(e);
    // The real conversationFileChangesV4 payload: items[].patches[] with
    // unified-diff `lines` (+/-/space) — render them as one diff.
    if (diff == null) {
      final patches = e['patches'];
      if (patches is List && patches.isNotEmpty) {
        final lines = <DiffLine>[];
        for (final hunk in patches) {
          if (hunk is! Map) continue;
          final h = hunk.cast<String, dynamic>();
          lines.add(DiffLine(
              DiffLineType.context,
              '@@ -${h['oldStart'] ?? 0},${h['oldLines'] ?? 0} '
              '+${h['newStart'] ?? 0},${h['newLines'] ?? 0} @@'));
          final hunkLines = h['lines'];
          if (hunkLines is! List) continue;
          for (final line in hunkLines) {
            if (line is! String) continue;
            if (line.startsWith('+')) {
              lines.add(DiffLine(DiffLineType.added, line));
            } else if (line.startsWith('-')) {
              lines.add(DiffLine(DiffLineType.removed, line));
            } else {
              lines.add(DiffLine(DiffLineType.context, line));
            }
          }
        }
        if (lines.isNotEmpty) {
          diff = DiffData(filePath: path as String?, lines: lines);
        }
      }
    }
    // A raw unified-diff string field is also worth rendering.
    if (diff == null) {
      for (final k in const ['diff', 'patch']) {
        final v = e[k];
        if (v is String && v.contains('\n')) {
          final lines = <DiffLine>[];
          for (final line in v.split('\n')) {
            if (line.startsWith('+')) {
              lines.add(DiffLine(DiffLineType.added, line));
            } else if (line.startsWith('-')) {
              lines.add(DiffLine(DiffLineType.removed, line));
            } else {
              lines.add(DiffLine(DiffLineType.context, line));
            }
          }
          diff = DiffData(filePath: path as String?, lines: lines);
          break;
        }
      }
    }
    if (!_isSourceCurrent()) return;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        builder: (context, scrollController) => SingleChildScrollView(
          controller: scrollController,
          padding: const EdgeInsets.all(16),
          child: diff != null
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('$path',
                        style: const TextStyle(
                            fontSize: 13, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 8),
                    DiffView(diff: diff),
                  ],
                )
              : _JsonSheet(title: '$path', data: e),
        ),
      ),
    );
  }

  Widget _fileTile(BuildContext context, Map<String, dynamic> e) {
    final path = e['path'] ?? e['filePath'] ?? e['file'] ?? e['name'] ?? '文件';
    final adds = (e['additions'] ?? e['added'] ?? e['insertions']) as num?;
    final dels = (e['deletions'] ?? e['deleted'] ?? e['removed']) as num?;
    return GestureDetector(
      onTap: () => _showFileDetail(context, e),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          children: [
            const Icon(Icons.description_outlined, size: 13),
            const SizedBox(width: 6),
            Expanded(
              child: Text('$path',
                  style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis),
            ),
            if (adds != null && dels != null)
              Text('+${adds.toInt()} −${dels.toInt()}',
                  style: TextStyle(
                      fontSize: 10.5,
                      color: EmberColors.of(context).textFaint)),
            Icon(Icons.chevron_right,
                size: 14, color: EmberColors.of(context).textFaint),
          ],
        ),
      ),
    );
  }

  // ------------------------------------------------------------- bg panel

  /// 后台面板分组小标题(后台任务/子代理)。
  Widget _bgGroupLabel(String text) {
    return Padding(
      padding: const EdgeInsets.only(top: 6, bottom: 2),
      child: Text(text,
          style: TextStyle(
              fontSize: 10.5,
              fontWeight: FontWeight.w600,
              color: EmberColors.of(context).textFaint)),
    );
  }

  String _fmtMs(num? v) {
    if (v == null) return '';
    final d = DateTime.fromMillisecondsSinceEpoch(v.toInt());
    return '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  }

  /// backgroundWorks entry: {workId, kind: bash|subagent, title,
  /// status: running|resultPending|failed|cancelled, startedAt(ms),
  /// endedAt?(ms), cancellable?, blocked?, childSessionId?}
  /// 已结束项可点开展开完整信息([expanded]/[onToggle])。
  Widget _workTile(
    BuildContext context,
    Map<String, dynamic> w, {
    bool expanded = false,
    VoidCallback? onToggle,
  }) {
    final colors = EmberColors.of(context);
    final status = '${w['status']}';
    final Widget leading;
    String suffix = '';
    if (status == 'running') {
      leading = const SizedBox(
          width: 12,
          height: 12,
          child: CircularProgressIndicator(strokeWidth: 1.5));
    } else if (status == 'failed') {
      leading = Icon(Icons.error_outline,
          size: 13, color: EmberColors.of(context).err);
      suffix = ' · 失败';
    } else if (status == 'cancelled') {
      leading =
          Icon(Icons.block, size: 13, color: EmberColors.of(context).warn);
      suffix = ' · 已取消';
    } else {
      leading = Icon(Icons.hourglass_bottom,
          size: 13, color: EmberColors.of(context).textFaint);
      suffix = ' · 待取结果';
    }
    final kindIcon =
        w['kind'] == 'bash' ? Icons.terminal : Icons.smart_toy_outlined;
    final endedAt = w['endedAt'];
    final startedAt = w['startedAt'];
    final time = endedAt != null
        ? ' · ${_fmtMs(endedAt as num?)} 结束'
        : startedAt != null
            ? ' · ${_fmtMs(startedAt as num?)} 开始'
            : '';
    final tile = Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: InkWell(
        onTap: onToggle,
        borderRadius: BorderRadius.circular(EmberRadius.control),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(kindIcon,
                    size: 13, color: EmberColors.of(context).textFaint),
                const SizedBox(width: 5),
                leading,
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '${w['title'] ?? w['kind'] ?? '后台任务'}$suffix$time',
                    style: const TextStyle(fontSize: 11.5),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (onToggle != null)
                  Icon(
                    expanded
                        ? Icons.keyboard_arrow_up
                        : Icons.keyboard_arrow_down,
                    size: 13,
                    color: EmberColors.of(context).textFaint,
                  ),
              ],
            ),
            if (expanded) ...[
              const SizedBox(height: 4),
              Padding(
                padding: const EdgeInsets.only(left: 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if ('${w['title'] ?? ''}'.isNotEmpty)
                      Text('${w['title']}',
                          style: TextStyle(
                              fontSize: 11, color: colors.textSolid)),
                    const SizedBox(height: 2),
                    Text(
                      [
                        '类型 ${w['kind'] ?? '-'}',
                        '状态 $status',
                        if (w['workId'] != null) 'id ${w['workId']}',
                        if (w['childSessionId'] != null)
                          '会话 ${w['childSessionId']}',
                        if (startedAt != null)
                          '开始 ${_fmtMs(startedAt as num?)}',
                        if (endedAt != null) '结束 ${_fmtMs(endedAt as num?)}',
                      ].join(' · '),
                      style: TextStyle(
                          fontSize: 10.5,
                          color: EmberColors.of(context).textMuted),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
    return tile;
  }

  /// snapshot.subagents.running entry: {childSessionId, agentId?,
  /// toolCallId?, subagentType, title, summary?, status:
  /// running|waiting|blocked, startedAt?(ms)}
  Widget _subagentTile(BuildContext context, Map<String, dynamic> s) {
    final status = '${s['status']}';
    final Widget leading;
    if (status == 'running') {
      leading = const SizedBox(
          width: 12,
          height: 12,
          child: CircularProgressIndicator(strokeWidth: 1.5));
    } else if (status == 'blocked') {
      leading = Icon(Icons.lock_outline,
          size: 13, color: EmberColors.of(context).warn);
    } else {
      leading = Icon(Icons.hourglass_bottom,
          size: 13, color: EmberColors.of(context).textFaint); // waiting
    }
    final summary = '${s['summary'] ?? ''}';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          leading,
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              '${s['title'] ?? '子代理'} · ${s['subagentType'] ?? ''}'
              '${status == 'waiting' ? ' · 等待中' : status == 'blocked' ? ' · 被阻塞' : ''}'
              '${s['startedAt'] != null ? ' · ${_fmtMs(s['startedAt'] as num?)} 开始' : ''}'
              '${summary.trim().isNotEmpty ? '\n$summary' : ''}',
              style: TextStyle(
                  fontSize: 11, color: EmberColors.of(context).textSoft),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  /// Inline `subagent` row (host schema): {subagentType, status:
  /// running|success|failed|cancelled, summaryText, startedAt?(ms),
  /// endedAt?(ms)}. Terminal rows back the finished-subagent list; running
  /// rows back the fallback stream (no snapshot `subagents` field).
  /// 已结束行可点开展开完整摘要([expanded]/[onToggle])。
  Widget _subagentRowTile(
    BuildContext context,
    Map<String, dynamic> r, {
    bool expanded = false,
    VoidCallback? onToggle,
  }) {
    final status = '${r['status']}';
    final (leading, suffix) = switch (status) {
      'success' => (
          Icon(Icons.check_circle_outline,
              size: 13, color: EmberColors.of(context).ok),
          ' · 已完成'
        ),
      'failed' => (
          Icon(Icons.error_outline,
              size: 13, color: EmberColors.of(context).err),
          ' · 失败'
        ),
      'cancelled' => (
          Icon(Icons.block, size: 13, color: EmberColors.of(context).warn),
          ' · 已取消'
        ),
      _ => (
          const SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(strokeWidth: 1.5)),
          ''
        ),
    };
    final summary = '${r['summaryText'] ?? ''}'.trim();
    final endedAt = r['endedAt'];
    final startedAt = r['startedAt'];
    final time = endedAt != null
        ? ' · ${_fmtMs(endedAt as num?)} 结束'
        : startedAt != null
            ? ' · ${_fmtMs(startedAt as num?)} 开始'
            : '';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: InkWell(
        onTap: onToggle,
        borderRadius: BorderRadius.circular(EmberRadius.control),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                leading,
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '${summary.isEmpty ? '子代理 · ${r['subagentType'] ?? ''}' : summary}'
                    '$suffix$time',
                    style: TextStyle(
                        fontSize: 11, color: EmberColors.of(context).textSoft),
                    maxLines: expanded ? null : 2,
                    overflow: expanded
                        ? TextOverflow.visible
                        : TextOverflow.ellipsis,
                  ),
                ),
                if (onToggle != null)
                  Icon(
                    expanded
                        ? Icons.keyboard_arrow_up
                        : Icons.keyboard_arrow_down,
                    size: 13,
                    color: EmberColors.of(context).textFaint,
                  ),
              ],
            ),
            if (expanded) ...[
              const SizedBox(height: 4),
              Padding(
                padding: const EdgeInsets.only(left: 19),
                child: Text(
                  [
                    '类型 ${r['subagentType'] ?? '-'}',
                    '状态 $status',
                    if (startedAt != null) '开始 ${_fmtMs(startedAt as num?)}',
                    if (endedAt != null) '结束 ${_fmtMs(endedAt as num?)}',
                  ].join(' · '),
                  style: TextStyle(
                      fontSize: 10.5,
                      color: EmberColors.of(context).textMuted),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _bgPanel(BuildContext context) {
    _syncDerived();
    final works = _derived.backgroundWorks;
    // Authoritative RUNNING subagent status lives in snapshot.subagents
    // {revision, childSessionIds, running[], endedTotal}; the snapshot never
    // lists finished subagents — their summary + terminal status live in
    // inline `subagent` rows (endedTotal only counts them). Inline running
    // rows are used only by streams without the snapshot field.
    final runningSubs = _derived.runningSubagents;
    final endedTotal = _derived.endedSubagentTotal;
    final endedRows = _derived.endedSubagents;
    final fallbackRunningRows = runningSubs == null
        ? widget.state.rows
            .where(
                (r) => r['kind'] == 'subagent' && '${r['status']}' == 'running')
            .toList()
        : const <Map<String, dynamic>>[];

    if (works.isEmpty &&
        (runningSubs == null || runningSubs.isEmpty) &&
        fallbackRunningRows.isEmpty &&
        endedRows.isEmpty &&
        endedTotal == 0) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _panelHeader(context, '后台', () {}),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text('暂无后台任务',
                style: TextStyle(
                    fontSize: 11.5, color: EmberColors.of(context).textFaint)),
          ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _panelHeader(context, '后台', () {}),
        Flexible(
          child: ListView(
            controller: widget.scrollController,
            physics: const AlwaysScrollableScrollPhysics(),
            shrinkWrap: true,
            children: [
              // 后台任务组(bash/agent 作业)。
              if (works.isNotEmpty) ...[
                _bgGroupLabel('后台任务'),
                for (final w in works)
                  _workTile(
                    context,
                    w,
                    expanded: _bgExpanded.contains('w${w['workId']}'),
                    onToggle: () => setState(() =>
                        _bgExpanded.contains('w${w['workId']}')
                            ? _bgExpanded.remove('w${w['workId']}')
                            : _bgExpanded.add('w${w['workId']}')),
                  ),
              ],
              // 子代理组:运行中在前,已结束在后(均可点开展开)。
              if ((runningSubs?.isNotEmpty ?? false) ||
                  fallbackRunningRows.isNotEmpty ||
                  endedRows.isNotEmpty ||
                  endedTotal > 0) ...[
                _bgGroupLabel('子代理'),
                if (runningSubs != null)
                  for (final s in runningSubs) _subagentTile(context, s),
                for (final r in fallbackRunningRows)
                  _subagentRowTile(context, r),
                for (final r in endedRows)
                  _subagentRowTile(
                    context,
                    r,
                    expanded: _bgExpanded.contains('s${r['rowId']}'),
                    onToggle: () => setState(() =>
                        _bgExpanded.contains('s${r['rowId']}')
                            ? _bgExpanded.remove('s${r['rowId']}')
                            : _bgExpanded.add('s${r['rowId']}')),
                  ),
                // Rows outside the loaded window aren't available — the
                // snapshot count keeps the total honest.
                if (endedTotal > endedRows.length)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text('以及更早的 ${endedTotal - endedRows.length} 个子代理',
                        style: TextStyle(
                            fontSize: 10.5,
                            color: EmberColors.of(context).textFaint)),
                  ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _GoalBanner extends StatelessWidget {
  final ConversationState state;

  const _GoalBanner({required this.state});

  @override
  Widget build(BuildContext context) {
    final goal = state.goal;
    if (goal == null) return const SizedBox.shrink();
    final objective = '${goal['objective'] ?? ''}';
    if (objective.isEmpty) return const SizedBox.shrink();
    final status = '${goal['status'] ?? ''}';
    return Container(
      margin: const EdgeInsets.fromLTRB(14, 4, 14, 0),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: EmberColors.of(context).ok.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
            color: EmberColors.of(context).ok.withValues(alpha: 0.25)),
      ),
      child: Row(
        children: [
          Icon(Icons.flag_outlined,
              size: 14, color: EmberColors.of(context).ok),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              objective,
              style: TextStyle(
                  fontSize: 12, color: EmberColors.of(context).textSoft),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (status.isNotEmpty)
            Text(status,
                style:
                    TextStyle(fontSize: 11, color: EmberColors.of(context).ok)),
        ],
      ),
    );
  }
}

class _BackgroundWorksBar extends StatelessWidget {
  final ConversationState state;

  const _BackgroundWorksBar({required this.state});

  @override
  Widget build(BuildContext context) {
    final works = state.backgroundWorks
        .where((w) => w['status'] == 'running' && w['endedAt'] == null)
        .toList();
    if (works.isEmpty) return const SizedBox.shrink();
    return Container(
      margin: const EdgeInsets.fromLTRB(14, 4, 14, 0),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.deepPurple.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          const SizedBox(
            width: 12,
            height: 12,
            child: CircularProgressIndicator(strokeWidth: 1.5),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '后台任务 ${works.length} 个运行中: '
              '${works.map((w) => w['title'] ?? w['kind']).join('、')}',
              style: TextStyle(
                  fontSize: 11.5, color: EmberColors.of(context).textSoft),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

class _QueueBar extends StatefulWidget {
  final ConversationState state;
  final ConversationTransport transport;

  const _QueueBar({required this.state, required this.transport});

  @override
  State<_QueueBar> createState() => _QueueBarState();
}

class _QueueBarState extends State<_QueueBar> {
  int _sourceGeneration = 0;
  ConversationState? _boundState;
  ConversationTransport? _boundTransport;
  String? _boundSessionId;

  String _sessionId(ConversationState state) =>
      state.snapshot?['sessionId'] as String? ?? '';

  void _syncSourceTarget() {
    final state = widget.state;
    final transport = widget.transport;
    final sessionId = _sessionId(state);
    if (_boundState == null) {
      _boundState = state;
      _boundTransport = transport;
      _boundSessionId = sessionId;
      return;
    }
    if (!identical(_boundState, state) ||
        !identical(_boundTransport, transport) ||
        _boundSessionId != sessionId) {
      _boundState = state;
      _boundTransport = transport;
      _boundSessionId = sessionId;
      _sourceGeneration++;
    }
  }

  bool _isCurrent(
    int generation,
    ConversationState state,
    ConversationTransport transport,
    String sessionId,
  ) =>
      mounted &&
      generation == _sourceGeneration &&
      identical(widget.state, state) &&
      identical(widget.transport, transport) &&
      _sessionId(widget.state) == sessionId;

  @override
  void didUpdateWidget(_QueueBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.state, widget.state) ||
        !identical(oldWidget.transport, widget.transport) ||
        _sessionId(oldWidget.state) != _sessionId(widget.state)) {
      _sourceGeneration++;
    }
  }

  Future<void> _setAutoDrain(
    int generation,
    ConversationState state,
    ConversationTransport transport,
    String sessionId,
    bool value,
  ) async {
    if (!_isCurrent(generation, state, transport, sessionId)) return;
    try {
      await transport.setAutoDrain(sessionId, value);
    } catch (_) {}
  }

  Future<void> _sendQueuedNow(
    int generation,
    ConversationState state,
    ConversationTransport transport,
    String sessionId,
    String id,
  ) async {
    if (!_isCurrent(generation, state, transport, sessionId)) return;
    state.optimisticRemoveQueueItem(id);
    try {
      await transport.sendQueuedNow(sessionId, id);
    } catch (_) {}
  }

  Future<void> _deleteQueuedItem(
    BuildContext context,
    int generation,
    ConversationState state,
    ConversationTransport transport,
    String sessionId,
    String id,
    String text,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除排队消息？'),
        content:
            Text('将删除「$text」', maxLines: 3, overflow: TextOverflow.ellipsis),
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
    if (!_isCurrent(generation, state, transport, sessionId) ||
        confirmed != true) {
      return;
    }
    state.optimisticRemoveQueueItem(id);
    try {
      await transport.deleteQueueItem(sessionId, id);
    } catch (_) {}
  }

  Future<void> _edit(
    BuildContext context,
    int generation,
    ConversationState state,
    ConversationTransport transport,
    String sessionId,
    Map<String, dynamic> item,
  ) async {
    final controller = TextEditingController(text: '${item['text'] ?? ''}');
    final text = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('编辑排队消息'),
        content: TextField(
          controller: controller,
          maxLines: 4,
          decoration: const InputDecoration(border: OutlineInputBorder()),
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
    if (text == null ||
        text.isEmpty ||
        !_isCurrent(generation, state, transport, sessionId)) {
      return;
    }
    // Optimistic text update; server queue patch confirms.
    final q = state.queue;
    if (q != null && q['items'] is List) {
      final items = [
        for (final i in q['items'] as List)
          if (i is Map && '${i['queueItemId']}' == '${item['queueItemId']}')
            {...i, 'text': text}
          else
            i,
      ];
      state.optimisticPatch({
        'queue': {...q, 'items': items},
      });
    }
    try {
      await transport.editQueueItem(sessionId, '${item['queueItemId']}', text);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    _syncSourceTarget();
    final state = widget.state;
    final transport = widget.transport;
    final items = state.queueItems;
    if (items.isEmpty) return const SizedBox.shrink();
    final sessionId = _sessionId(state);
    final generation = _sourceGeneration;
    return Container(
      margin: const EdgeInsets.fromLTRB(14, 4, 14, 0),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: EmberColors.of(context).primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
            color: EmberColors.of(context).primary.withValues(alpha: 0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.queue_outlined,
                  size: 14, color: EmberColors.of(context).primary),
              const SizedBox(width: 6),
              Text('排队消息 ${items.length}',
                  style: TextStyle(
                      fontSize: 12, color: EmberColors.of(context).primary)),
              const Spacer(),
              InkWell(
                onTap: () {
                  if (!_isCurrent(generation, state, transport, sessionId)) {
                    return;
                  }
                  final next = !state.autoDrain;
                  state.optimisticPatch({
                    'queue': {...?state.queue, 'autoDrain': next},
                  });
                  unawaited(_setAutoDrain(
                      generation, state, transport, sessionId, next));
                },
                child: Text(
                  state.autoDrain ? '自动发送: 开' : '自动发送: 关',
                  style: TextStyle(
                      fontSize: 11, color: EmberColors.of(context).textMuted),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          for (final item in items)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '${item['text'] ?? ''}',
                      style: TextStyle(
                          fontSize: 12,
                          color: EmberColors.of(context).textSoft),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  _QueueAction(
                    icon: Icons.play_arrow,
                    tooltip: '立即发送',
                    onTap: () => unawaited(_sendQueuedNow(generation, state,
                        transport, sessionId, '${item['queueItemId']}')),
                  ),
                  _QueueAction(
                    icon: Icons.edit_outlined,
                    tooltip: '编辑',
                    onTap: () => _edit(
                        context, generation, state, transport, sessionId, item),
                  ),
                  _QueueAction(
                    icon: Icons.close,
                    tooltip: '删除',
                    onTap: () => unawaited(_deleteQueuedItem(
                        context,
                        generation,
                        state,
                        transport,
                        sessionId,
                        '${item['queueItemId']}',
                        '${item['text'] ?? ''}')),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _QueueAction extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  const _QueueAction({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: Icon(icon, size: 16, color: EmberColors.of(context).textMuted),
      tooltip: tooltip,
      onPressed: onTap,
      visualDensity: VisualDensity.compact,
    );
  }
}

class _PendingFilesBar extends StatelessWidget {
  final List<PendingFile> files;
  final double? uploadProgress;
  final void Function(int index) onRemove;

  const _PendingFilesBar({
    required this.files,
    required this.uploadProgress,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(14, 4, 14, 0),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: EmberColors.of(context).card,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (uploadProgress != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: LinearProgressIndicator(value: uploadProgress),
            ),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (var i = 0; i < files.length; i++)
                Chip(
                  avatar: const Icon(Icons.attach_file, size: 14),
                  label: Text(files[i].fileName,
                      style: const TextStyle(fontSize: 11)),
                  onDeleted: () => onRemove(i),
                  deleteIcon: const Icon(Icons.close, size: 14),
                  visualDensity: VisualDensity.compact,
                ),
            ],
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- interactions

@visibleForTesting
Widget pendingInteractionsForTest({
  required ConversationState state,
  required ConversationTransport transport,
}) =>
    _PendingInteractions(state: state, transport: transport);

class _PendingInteractions extends StatefulWidget {
  final ConversationState state;
  final ConversationTransport transport;

  const _PendingInteractions({required this.state, required this.transport});

  @override
  State<_PendingInteractions> createState() => _PendingInteractionsState();
}

class _PendingInteractionsState extends State<_PendingInteractions> {
  int _sourceGeneration = 0;
  ConversationState? _boundState;
  ConversationTransport? _boundTransport;
  String? _boundSessionId;

  String _sessionId(ConversationState state) =>
      state.snapshot?['sessionId'] as String? ?? '';

  void _syncSourceTarget() {
    final state = widget.state;
    final transport = widget.transport;
    final sessionId = _sessionId(state);
    if (_boundState == null) {
      _boundState = state;
      _boundTransport = transport;
      _boundSessionId = sessionId;
      return;
    }
    if (!identical(_boundState, state) ||
        !identical(_boundTransport, transport) ||
        _boundSessionId != sessionId) {
      _boundState = state;
      _boundTransport = transport;
      _boundSessionId = sessionId;
      _sourceGeneration++;
    }
  }

  @override
  void initState() {
    super.initState();
    _syncSourceTarget();
  }

  bool _isCurrent(
    int generation,
    ConversationState state,
    ConversationTransport transport,
    String sessionId,
  ) =>
      mounted &&
      generation == _sourceGeneration &&
      identical(widget.state, state) &&
      identical(widget.transport, transport) &&
      _sessionId(widget.state) == sessionId;

  @override
  void didUpdateWidget(_PendingInteractions oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncSourceTarget();
  }

  @override
  Widget build(BuildContext context) {
    _syncSourceTarget();
    final state = widget.state;
    final transport = widget.transport;
    final interactions = state.pendingInteractions;
    if (interactions.isEmpty) return const SizedBox.shrink();
    final sessionId = _sessionId(state);
    final generation = _sourceGeneration;
    return Column(
      children: [
        for (final interaction in interactions)
          _InteractionCard(
            key: ValueKey('${interaction['interactionId']}'),
            interaction: interaction,
            state: state,
            transport: transport,
            sessionId: sessionId,
            onResolve: ({optionId, freeText, action, content}) {
              if (!_isCurrent(generation, state, transport, sessionId)) {
                return Future<void>.value();
              }
              return transport.resolveInteraction(
                sessionId,
                interaction['interactionId'] as String? ?? '',
                optionId: optionId,
                freeText: freeText,
                action: action,
                content: content,
              );
            },
          ),
      ],
    );
  }
}

class _InteractionCard extends StatefulWidget {
  final Map<String, dynamic> interaction;
  final ConversationState state;
  final ConversationTransport transport;
  final String sessionId;
  final Future<dynamic> Function({
    String? optionId,
    String? freeText,
    String? action,
    Map<String, dynamic>? content,
  }) onResolve;

  const _InteractionCard({
    super.key,
    required this.interaction,
    required this.state,
    required this.transport,
    required this.sessionId,
    required this.onResolve,
  });

  @override
  State<_InteractionCard> createState() => _InteractionCardState();
}

class _InteractionCardState extends State<_InteractionCard> {
  final _freeTextController = TextEditingController();
  bool _busy = false;
  int _requestGeneration = 0;

  @override
  void didUpdateWidget(_InteractionCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.interaction['interactionId'] !=
            widget.interaction['interactionId'] ||
        !identical(oldWidget.state, widget.state) ||
        !identical(oldWidget.transport, widget.transport) ||
        oldWidget.sessionId != widget.sessionId) {
      _requestGeneration++;
      _busy = false;
    }
  }

  @override
  void dispose() {
    _requestGeneration++;
    _freeTextController.dispose();
    super.dispose();
  }

  Future<void> _resolve({
    String? optionId,
    String? freeText,
    String? action,
    Map<String, dynamic>? content,
  }) async {
    if (_busy) return;
    final requestGeneration = ++_requestGeneration;
    setState(() => _busy = true);
    try {
      await widget.onResolve(
          optionId: optionId,
          freeText: freeText,
          action: action,
          content: content);
    } catch (_) {
    } finally {
      if (mounted && requestGeneration == _requestGeneration) {
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final payload = widget.interaction['payload'];
    if (payload is! Map) return const SizedBox.shrink();
    final kind = payload['kind'];
    final options = payload['options'];
    final questions = payload['questions'];
    final freeText = payload['freeText'] == true;

    final title =
        kind == 'permission' ? '权限请求 · ${payload['toolName'] ?? ''}' : '等待你的输入';

    final ember = EmberColors.of(context);
    return Container(
      margin: const EdgeInsets.fromLTRB(14, 4, 14, 0),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: ember.primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: ember.primary.withValues(alpha: 0.55)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.privacy_tip_outlined, size: 14, color: ember.primary),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(fontSize: 13),
                ),
              ),
            ],
          ),
          if (kind == 'userInput' &&
              (payload['prompt'] as String? ?? '').isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text('${payload['prompt']}',
                  style: TextStyle(
                      fontSize: 12, color: EmberColors.of(context).textSoft)),
            ),
          if (kind == 'permission' && payload['summary'] != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text('${payload['summary']}',
                  style: TextStyle(
                      fontSize: 12, color: EmberColors.of(context).textSoft)),
            ),
          const SizedBox(height: 8),
          if (options is List && options.isNotEmpty)
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final option in options)
                  if (option is Map)
                    OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 6),
                        minimumSize: Size.zero,
                        foregroundColor: ember.primary,
                        side: BorderSide(color: ember.primary),
                      ),
                      onPressed: _busy
                          ? null
                          // The server normalizes userInput answers by
                          // action/freeText/allow*-optionId and treats
                          // everything else as decline: non-permission
                          // option taps must be sent as an accept.
                          : () => kind == 'permission'
                              ? _resolve(optionId: '${option['optionId']}')
                              : _resolve(action: 'accept', content: {}),
                      child: Text(
                        _optionLabel(option),
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
              ],
            ),
          if (questions is List && questions.isNotEmpty)
            _QuestionsView(
              questions: questions.cast<Map>(),
              busy: _busy,
              onResolve: (answers) => _resolve(
                action: 'accept',
                content: {'answers': answers},
              ),
            ),
          if (freeText)
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _freeTextController,
                    style: const TextStyle(fontSize: 13),
                    decoration: const InputDecoration(
                      isDense: true,
                      hintText: '输入回复…',
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  icon: const Icon(Icons.send, size: 18),
                  onPressed: _busy
                      ? null
                      : () =>
                          _resolve(freeText: _freeTextController.text.trim()),
                ),
              ],
            ),
        ],
      ),
    );
  }

  String _optionLabel(Map option) {
    final label = option['label'] as String?;
    if (label != null && label.isNotEmpty) return label;
    final kind = option['kind'] as String?;
    return switch (kind) {
      'allowOnce' => '允许一次',
      'allowAlways' => '总是允许',
      'deny' => '拒绝',
      'custom' => '自定义',
      _ => '${option['optionId'] ?? '选择'}',
    };
  }
}

/// Renders a form-style `userInput` interaction (the `questions` payload).
/// Answers are collected LOCALLY and submitted in ONE resolveInteraction —
/// the pending interaction is consumed by the first answer, so per-question
/// submission would strand the remaining questions.
class _QuestionsView extends StatefulWidget {
  final List<Map> questions;
  final bool busy;
  final void Function(Map<String, List<String>> answers) onResolve;

  const _QuestionsView({
    required this.questions,
    required this.busy,
    required this.onResolve,
  });

  @override
  State<_QuestionsView> createState() => _QuestionsViewState();
}

class _QuestionsViewState extends State<_QuestionsView> {
  /// Keyed by question TEXT — the server reads content.answers[question].
  final _answers = <String, List<String>>{};

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < widget.questions.length; i++)
          _QuestionItem(
            index: i,
            question: widget.questions[i],
            busy: widget.busy,
            selected: _answers['${widget.questions[i]['question']}'] ??
                const <String>[],
            onChanged: (selected) => setState(() {
              final key = '${widget.questions[i]['question']}';
              if (selected.isEmpty) {
                _answers.remove(key);
              } else {
                _answers[key] = selected;
              }
            }),
          ),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(
            // Unanswered questions are allowed — the model is told it
            // should use its best judgment for those.
            onPressed: widget.busy || _answers.isEmpty
                ? null
                : () => widget.onResolve(Map.of(_answers)),
            child: const Text('提交答案', style: TextStyle(fontSize: 12)),
          ),
        ),
      ],
    );
  }
}

class _QuestionItem extends StatelessWidget {
  final int index;
  final Map question;
  final bool busy;
  final List<String> selected;
  final void Function(List<String> selected) onChanged;

  const _QuestionItem({
    required this.index,
    required this.question,
    required this.busy,
    required this.selected,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final q = question;
    final label = q['label'] ?? q['question'] ?? q['value'] ?? '';
    final options = q['options'];
    final multi = q['multiSelect'] == true;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('${index + 1}. $label',
              style: const TextStyle(fontSize: 12, height: 1.4)),
          if (q['description'] != null)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text('${q['description']}',
                  style: TextStyle(
                      fontSize: 11, color: EmberColors.of(context).textFaint)),
            ),
          if (options is List && options.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  for (final o in options)
                    if (o is Map)
                      FilterChip(
                        label: Text('${o['label'] ?? o['value'] ?? ''}',
                            style: const TextStyle(fontSize: 12)),
                        selected: selected.contains('${o['value']}'),
                        onSelected: busy
                            ? null
                            : (on) {
                                final value = '${o['value']}';
                                if (multi) {
                                  onChanged(on
                                      ? [...selected, value]
                                      : selected
                                          .where((v) => v != value)
                                          .toList());
                                } else {
                                  // Tapping the selected chip clears it.
                                  onChanged(on ? [value] : const []);
                                }
                              },
                      ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
