import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../protocol/channel_client.dart';
import '../protocol/conversation.dart';
import '../protocol/zemote_client.dart';
import '../state/log_store.dart';
import '../state/session_list_cache.dart';
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

/// 按 今天/更早 两档分组(spec §7.1;键序即展示序)。
/// TODO(置顶组): channel 置顶数据源接入后,在最前增加「置顶」分组
/// (列表数据本身仍以 sessions-index 为准,置顶仅是展示分组)。
/// 返回 Map 按插入序迭代(今天在前)。
Map<String, List<SessionEntry>> groupSessions(
  List<SessionEntry> entries, {
  DateTime? now,
}) {
  final at = now ?? DateTime.now();
  final today = DateTime(at.year, at.month, at.day);
  final todayList = <SessionEntry>[];
  final earlier = <SessionEntry>[];
  for (final e in entries) {
    final t = DateTime.fromMillisecondsSinceEpoch(e.lastActivityAt);
    (DateTime(t.year, t.month, t.day).isAtSameMomentAs(today)
            ? todayList
            : earlier)
        .add(e);
  }
  return {'今天': todayList, '更早': earlier}
    ..removeWhere((_, v) => v.isEmpty);
}

const _weekdays = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];

/// Today → `HH:mm`, yesterday → `昨天`, within the last week → `周X`,
/// else `M月d日` (with year when it differs from today's).
String _relativeDayLabel(int millis) {
  if (millis <= 0) return '';
  final time = DateTime.fromMillisecondsSinceEpoch(millis);
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(time.year, time.month, time.day);
  final hhmm =
      '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
  final daysAgo = today.difference(day).inDays;
  if (daysAgo <= 0) return hhmm;
  if (daysAgo == 1) return '昨天';
  if (daysAgo < 7) return _weekdays[time.weekday - 1];
  if (time.year == now.year) return '${time.month}月${time.day}日';
  return '${time.year}年${time.month}月${time.day}日';
}

/// 会话抽屉面板(spec §7.1):工作区条 / 搜索 / ＋新会话 / 分组会话列表
/// (运行中蓝点、等待黄点)/「管理」多选(置顶/归档/删除,走 zcode-task
/// RPC)/ 底部设备状态条。宿主(root_shell 的 _DrawerHost)约束 76% 宽、
/// 滑出动画与遮罩。onPick(null) = 新会话;列表条目点击 = 打开该会话。
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

  /// 工作区条 ⌄:宿主弹出工作区切换 sheet。
  final VoidCallback onSwitchWorkspace;

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
  String? _error;

  /// 离线种子(2c):打开抽屉先展示上次缓存,实时数据到达即覆盖。
  List<SessionEntry> _seed = const [];

  /// 已写过缓存复本的订阅(每个订阅只写首个 ready 快照)。
  SessionsIndexSubscription? _cacheSyncedSub;

  @override
  void initState() {
    super.initState();
    _transport = widget.bridge.conversation(widget.scope, onLog: log);
    _subscribe();
    _seedFromCache();
  }

  @override
  void didUpdateWidget(SessionDrawer oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 宿主切换了工作区/桥:旧订阅属于旧 scope,重挂。
    if (oldWidget.bridge != widget.bridge ||
        !mapEquals(oldWidget.scope, widget.scope)) {
      _resubscribe();
    }
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

  Future<void> _resubscribe() async {
    // 旧 scope 的种子随订阅一起作废:先清空,再按新 scope 重新播种 ——
    // 否则上一个工作区的缓存会话会在新工作区名下展示且可点(终审修复)。
    setState(() => _seed = const []);
    unawaited(_seedFromCache());
    final sub = _sub;
    _sub = null;
    if (sub != null) {
      sub.state.removeListener(_onState);
      await sub.dispose();
    }
    await _subscribe();
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

  void _onState() {
    final sub = _sub;
    if (sub == null || !mounted) return;
    setState(() {
      _entries = sortSessions(sub.state.list);
      _ready = sub.state.ready;
    });
    _syncCache(sub);
  }

  // ------------------------------------------------------- offline cache

  /// 打开抽屉先 read 播种(2c):仅当实时列表未到达(!ready)时展示,
  /// 真实数据到达即覆盖。种子条目 phase 清空 —— 状态点以实时为准(裁决),
  /// 缓存里的 running/waiting 可能早已过期。
  Future<void> _seedFromCache() async {
    final raw = await _cache.read(widget.scope);
    if (!mounted || raw.isEmpty) return;
    setState(() {
      _seed = [for (final m in raw) SessionEntry({...m, 'phase': ''})];
    });
  }

  /// 订阅 ready 后 write(2c):把当前列表落盘,供下次打开时秒开。
  /// 空列表不写(失败/清空不覆盖好数据,与旧实现一致)。
  void _syncCache(SessionsIndexSubscription sub) {
    if (!sub.state.ready || _cacheSyncedSub == sub) return;
    _cacheSyncedSub = sub;
    unawaited(_cache
        .write(widget.scope, [for (final e in _entries) e.raw]));
  }

  List<SessionEntry> get _filtered => filterSessions(_entries, _query);

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
      onTap: widget.onSwitchWorkspace,
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
    if (_error != null) {
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
    if (!_ready && _seed.isNotEmpty) return _buildSessionList(_seed);
    if (!_ready) {
      return const Center(
        child: SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    if (_entries.isEmpty) {
      return Center(
        child: Text('暂无会话，点「＋新会话」开始对话',
            style: TextStyle(
                fontSize: EmberType.caption, color: colors.textFaint)),
      );
    }
    final filtered = _filtered;
    if (filtered.isEmpty) {
      return Center(
        child: Text('没有匹配「$_query」的会话',
            style: TextStyle(
                fontSize: EmberType.caption, color: colors.textFaint)),
      );
    }
    return _buildSessionList(filtered);
  }

  /// 分组会话列表(spec §7.1:今天/更早),实时列表与离线种子共用。
  Widget _buildSessionList(List<SessionEntry> entries) {
    final colors = EmberColors.of(context);
    return ListView(
      padding: const EdgeInsets.symmetric(
          horizontal: EmberSpacing.page, vertical: EmberSpacing.gapS),
      children: [
        for (final group in groupSessions(entries).entries) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(
                EmberSpacing.cardPad, EmberSpacing.gapS, 0, 4),
            child: Text(group.key,
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
    return InkWell(
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
