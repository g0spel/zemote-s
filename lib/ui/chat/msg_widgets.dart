// 此文件是 chat_page.dart 的一部分(part):同库共享导入与私有类可见。
part of '../chat_page.dart';

class _ModeBanner extends StatelessWidget {
  final String mode;

  const _ModeBanner({required this.mode});

  @override
  Widget build(BuildContext context) {
    final yolo = mode == 'yolo';
    final plan = mode == 'plan';
    if (!yolo && !plan) return const SizedBox.shrink();
    final colors = EmberColors.of(context);
    final color = yolo ? colors.err : colors.warn;
    final text =
        yolo ? 'YOLO 模式 · 全部操作免确认，请确认在工作机上' : '计划模式中 · 只读研究，方案产出后需你确认才会动手';
    return Container(
      width: double.infinity,
      color: color.withValues(alpha: 0.15),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      child: Row(
        children: [
          Icon(yolo ? Icons.warning_amber_rounded : Icons.visibility_outlined,
              size: 14, color: color),
          const SizedBox(width: EmberSpacing.gapS),
          Expanded(
            child: Text(text,
                style: TextStyle(fontSize: EmberType.secondary, color: color)),
          ),
        ],
      ),
    );
  }
}

/// Shows while the bridge is degraded (relay drop / recovery in progress)
/// so the user knows a send may be paused waiting to reconnect.
class _ReconnectBanner extends StatelessWidget {
  final BridgeSession bridge;

  const _ReconnectBanner({required this.bridge});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<String?>(
      valueListenable: bridge.degraded,
      builder: (context, degraded, _) {
        // Bridge hiccups that recover within 5s (lock/unlock resume, quick
        // network flap) never surface.
        return DelayedVisibility(
          visible: degraded != null,
          delay: const Duration(seconds: 5),
          builder: (context) => Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            color: EmberColors.of(context).warn.withValues(alpha: 0.15),
            child: Row(
              children: [
                const SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(strokeWidth: 1.5),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text('连接已断开，正在自动重连…',
                      style: TextStyle(
                          fontSize: 12,
                          color: EmberColors.of(context).textSoft)),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// One ordered piece of an assistant turn: either a merged text segment
/// (kind == 'text') or a non-text row (kind == 'row').
typedef AssistantPart = ({
  String kind,
  String? text,
  Map<String, dynamic>? row,
  bool streaming,
});

/// Splits an assistant-turn group into ORDERED parts — consecutive
/// assistantText rows merge into one text segment, while reasoning/tool/
/// subagent rows stay exactly where they occurred in the stream (so
/// "thinking → tool → answer" never renders as "answer → thinking").
typedef AssistantTurnParts = ({
  List<AssistantPart> parts,
  Map<String, dynamic>? header,
  bool streaming,
});

AssistantTurnParts assistantTurnParts(List<Map<String, dynamic>> rows) {
  final parts = <AssistantPart>[];
  Map<String, dynamic>? header;
  StringBuffer? buf;
  Map<String, dynamic>? template;
  var anyStream = false;
  var sawStreaming = false;

  void flushText() {
    if (template != null) {
      final text = buf!.toString().trim();
      if (text.isNotEmpty) {
        parts.add(
            (kind: 'text', text: text, row: template, streaming: anyStream));
      }
      buf = null;
      template = null;
      anyStream = false;
    }
  }

  for (final row in rows) {
    final kind = row['kind'];
    if (kind == 'assistantText') {
      template ??= row;
      buf ??= StringBuffer();
      final t = row['text'] as String? ?? '';
      if (buf!.isNotEmpty) buf!.write('\n\n');
      buf!.write(t);
      if (row['state'] == 'streaming') {
        anyStream = true;
        sawStreaming = true;
      }
    } else if (kind == 'turnHeader') {
      header = row;
    } else {
      flushText();
      parts.add((kind: 'row', text: null, row: row, streaming: false));
    }
  }
  flushText();
  return (parts: parts, header: header, streaming: sawStreaming);
}

/// Groups rows into turns (mirrors the web timeline): a user message starts
/// a new group; assistant text/reasoning/tool rows that follow belong to
/// the same turn and render as ONE message instead of many bubbles.
///
/// A new group starts only on a user message (or the first assistant row
/// after one). Consecutive assistant rows are merged into a single group
/// EVEN IF the server bumps `turnId` mid-response, so one answer never
/// splits into several bubbles each carrying its own feedback buttons.
List<List<Map<String, dynamic>>> _groupRows(List<Map<String, dynamic>> rows) {
  final groups = <List<Map<String, dynamic>>>[];
  List<Map<String, dynamic>>? current;
  for (final row in rows) {
    final kind = row['kind'];
    if (kind == 'timelineMarker') {
      current = null;
      groups.add([row]);
      continue;
    }
    final isUser = kind == 'userInput';
    final startsGroup =
        isUser || current == null || current.first['kind'] == 'userInput';
    if (startsGroup) {
      current = [row];
      groups.add(current);
    } else {
      current.add(row);
    }
  }
  return groups;
}

ConversationState? _groupCacheState;
int _groupCacheVersion = -1;
List<List<Map<String, dynamic>>>? _groupCache;

/// Reuses row grouping while the state has not published a row mutation.
/// Echoes and control-only updates are outside this cache's input.
List<List<Map<String, dynamic>>> cachedGroupRows(ConversationState state) {
  if (identical(_groupCacheState, state) &&
      _groupCacheVersion == state.rowsVersion &&
      _groupCache != null) {
    return _groupCache!;
  }
  final groups = _groupRows(state.rows);
  _groupCacheState = state;
  _groupCacheVersion = state.rowsVersion;
  _groupCache = groups;
  return groups;
}

void clearGroupRowsCache() {
  _groupCacheState = null;
  _groupCacheVersion = -1;
  _groupCache = null;
}

class _TurnGroupWidget extends StatelessWidget {
  final List<Map<String, dynamic>> rows;
  final ConversationTransport transport;
  final String sessionId;
  final Future<void> Function(String, Future<dynamic> Function()) onAction;
  final ConversationState state;
  final bool Function()? isSourceCurrent;
  final int Function()? beginFileChangesOperation;
  final bool Function(int operationGeneration)? isFileChangesOperationCurrent;

  const _TurnGroupWidget({
    super.key,
    required this.rows,
    required this.transport,
    required this.sessionId,
    required this.onAction,
    required this.state,
    this.isSourceCurrent,
    this.beginFileChangesOperation,
    this.isFileChangesOperationCurrent,
  });

  /// First error snippet among this turn's failed tool calls — shown on the
  /// 本轮失败 header so failures are self-explaining.
  String? _errorSummary() {
    for (final r in rows) {
      if (r['kind'] != 'toolCall' || r['status'] != 'error') continue;
      var s = '';
      final e = r['error'];
      if (e is Map) {
        s = '${e['message'] ?? e['text'] ?? e}';
      } else if (e != null) {
        s = '$e';
      }
      s = s.trim();
      if (s.isEmpty || s == 'null') {
        final out = r['output'];
        if (out is Map) s = '${out['text'] ?? ''}'.trim();
      }
      if (s.isNotEmpty) {
        return s.length > 160 ? '${s.substring(0, 160)}…' : s;
      }
    }
    return null;
  }

  /// `HH:mm` for rows observed live (view-layer `_zflowTs` stamp). History
  /// rows carry no timestamp on the wire, so they show none.
  Widget? _timeLabel(BuildContext context) {
    final ts = rows.first['_zflowTs'] as int?;
    if (ts == null) return null;
    final d = DateTime.fromMillisecondsSinceEpoch(ts);
    final text =
        '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
    return Padding(
      padding: const EdgeInsets.only(top: 2, bottom: 2),
      child: Text(text,
          style: TextStyle(
              fontSize: 10, color: EmberColors.of(context).textFaint)),
    );
  }

  @override
  Widget build(BuildContext context) {
    // single timeline marker
    if (rows.length == 1 && rows.first['kind'] == 'timelineMarker') {
      return _TimelineMarkerWidget(row: rows.first);
    }
    final first = rows.first;
    if (first['kind'] == 'userInput') {
      // "Processing" badge: this is the newest user message and its turn
      // is currently running. The badge clears when the turn completes.
      final processing =
          state.isRunning && first['rowId'] == lastUserInputRowId(state.rows);
      // user message + anything attached to the same turn
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _RowWidget(
            row: first,
            transport: transport,
            sessionId: sessionId,
            onAction: onAction,
            state: state,
            isSourceCurrent: isSourceCurrent,
            badge: processing ? 'processing' : null,
          ),
          for (final row in rows.skip(1))
            _RowWidget(
              row: row,
              transport: transport,
              sessionId: sessionId,
              onAction: onAction,
              state: state,
              isSourceCurrent: isSourceCurrent,
            ),
          if (_timeLabel(context) != null)
            Align(alignment: Alignment.centerRight, child: _timeLabel(context)),
        ],
      );
    }
    // assistant turn: render parts in original order (reasoning → text →
    // tool → text …); feedback buttons appear only on the LAST text segment.
    final parts = assistantTurnParts(rows);
    var lastTextIdx = -1;
    for (var i = 0; i < parts.parts.length; i++) {
      if (parts.parts[i].kind == 'text') lastTextIdx = i;
    }
    final children = <Widget>[];
    for (var i = 0; i < parts.parts.length; i++) {
      final p = parts.parts[i];
      if (p.kind == 'text') {
        children.add(_RowWidget(
          row: {
            ...?p.row,
            'kind': 'assistantText',
            'text': p.text,
            if (p.streaming) 'state': 'streaming',
          },
          showFeedback: i == lastTextIdx,
          transport: transport,
          sessionId: sessionId,
          onAction: onAction,
          state: state,
          isSourceCurrent: isSourceCurrent,
          beginFileChangesOperation: beginFileChangesOperation,
          isFileChangesOperationCurrent: isFileChangesOperationCurrent,
        ));
      } else {
        children.add(_RowWidget(
          row: p.row!,
          showFeedback: false,
          transport: transport,
          sessionId: sessionId,
          onAction: onAction,
          state: state,
          isSourceCurrent: isSourceCurrent,
          beginFileChangesOperation: beginFileChangesOperation,
          isFileChangesOperationCurrent: isFileChangesOperationCurrent,
        ));
      }
    }
    final header = parts.header;
    if (header != null) {
      children.add(_TurnHeader(
        row: header,
        errorSummary:
            (header['state'] as String?) == 'failed' ? _errorSummary() : null,
      ));
      // 文件变更条(桌面同款):回合有文件改动时显示可点卡片。
      final fileChanges = header['fileChanges'];
      if (fileChanges is Map &&
          ((fileChanges['files'] as num?)?.toInt() ?? 0) > 0) {
        children.add(_FileChangesCard(
          header: header,
          transport: transport,
          sessionId: sessionId,
          beginFileChangesOperation: beginFileChangesOperation,
          isFileChangesOperationCurrent: isFileChangesOperationCurrent,
          isSourceCurrent: isSourceCurrent,
        ));
      }
    }
    if (_timeLabel(context) != null) {
      children.add(
          Align(alignment: Alignment.centerLeft, child: _timeLabel(context)));
    }
    if (children.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    );
  }
}

class _RowWidget extends StatelessWidget {
  final Map<String, dynamic> row;
  final ConversationTransport transport;
  final String sessionId;
  final Future<void> Function(String, Future<dynamic> Function()) onAction;
  final ConversationState state;
  final bool Function()? isSourceCurrent;
  final int Function()? beginFileChangesOperation;
  final bool Function(int operationGeneration)? isFileChangesOperationCurrent;
  final bool showFeedback;

  /// Delivery badge for user rows (see [_MsgBadge]).
  final String? badge;

  const _RowWidget({
    required this.row,
    required this.transport,
    required this.sessionId,
    required this.onAction,
    required this.state,
    this.isSourceCurrent,
    this.beginFileChangesOperation,
    this.isFileChangesOperationCurrent,
    this.showFeedback = true,
    this.badge,
  });

  Map<String, dynamic> get _target => {
        'rowId': row['rowId'],
        if (row['entityId'] != null) 'entityId': row['entityId'],
      };

  void _showActions(BuildContext context) {
    final kind = row['kind'];
    if (kind != 'userInput' && kind != 'assistantText') return;
    if (isSourceCurrent != null && !isSourceCurrent!()) return;
    showModalBottomSheet(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (kind == 'userInput')
              ListTile(
                leading: const Icon(Icons.edit_outlined, size: 20),
                title: const Text('编辑并重发'),
                onTap: () {
                  Navigator.pop(context);
                  _editQuery(context);
                },
              ),
            ListTile(
              leading: const Icon(Icons.replay, size: 20),
              title: const Text('重试本轮 (retryTurn)'),
              onTap: () {
                Navigator.pop(context);
                if (isSourceCurrent != null && !isSourceCurrent!()) return;
                onAction('重试失败', () => transport.retryTurn(sessionId, _target));
              },
            ),
            ListTile(
              leading: const Icon(Icons.fork_right, size: 20),
              title: const Text('分叉对话 (fork)'),
              onTap: () {
                Navigator.pop(context);
                if (isSourceCurrent != null && !isSourceCurrent!()) return;
                onAction(
                    '分叉失败', () => transport.forkAssistant(sessionId, _target));
              },
            ),
            ListTile(
              leading: const Icon(Icons.history, size: 20),
              title: const Text('回滚文件到此 (rewind)'),
              onTap: () {
                Navigator.pop(context);
                _confirmRewind(context);
              },
            ),
            ListTile(
              leading: const Icon(Icons.difference_outlined, size: 20),
              title: const Text('查看文件变更'),
              onTap: () {
                Navigator.pop(context);
                _showFileChanges(context);
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _editQuery(BuildContext context) async {
    if (isSourceCurrent != null && !isSourceCurrent!()) return;
    final controller =
        TextEditingController(text: row['text'] as String? ?? '');
    final text = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('编辑消息'),
        content: TextField(
          controller: controller,
          maxLines: 5,
          decoration: const InputDecoration(border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context), child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(context, controller.text.trim()),
              child: const Text('重发')),
        ],
      ),
    );
    controller.dispose();
    if (text == null ||
        text.isEmpty ||
        (isSourceCurrent != null && !isSourceCurrent!())) {
      return;
    }
    await onAction(
        '编辑失败', () => transport.editUserQuery(sessionId, _target, text));
  }

  Future<void> _confirmRewind(BuildContext context) async {
    if (isSourceCurrent != null && !isSourceCurrent!()) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('回滚文件？'),
        content: const Text('将把此消息之后产生的文件变更回滚，对话保留'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('回滚'),
          ),
        ],
      ),
    );
    if (confirmed != true ||
        (isSourceCurrent != null && !isSourceCurrent!())) {
      return;
    }
    await onAction('回滚失败', () => transport.applyFileRewind(sessionId, _target));
  }

  Future<void> _showFileChanges(BuildContext context) async {
    // The server guard accepts turnHeader targets only — resolve this
    // row's turn header (rows carry the same turnId).
    final turnId = row['turnId'];
    Map<String, dynamic>? header;
    for (final r in state.rows) {
      if (r['kind'] == 'turnHeader' &&
          r['rowId'] != null &&
          r['entityId'] is String) {
        if (turnId == null || r['turnId'] == turnId) header = r;
      }
    }
    if (header == null) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('该回合没有可查询的文件变更')));
      }
      return;
    }
    await showTurnFileChangesSheet(
      context,
      transport: transport,
      sessionId: sessionId,
      header: header,
      beginFileChangesOperation: beginFileChangesOperation,
      isFileChangesOperationCurrent: isFileChangesOperationCurrent,
      isSourceCurrent: isSourceCurrent,
    );
  }

  @override
  Widget build(BuildContext context) {
    final widget_ = switch (row['kind']) {
      'userInput' => _UserBubble(
          row: row,
          transport: transport,
          sessionId: sessionId,
          badge: badge,
          isSourceCurrent: isSourceCurrent),
      'assistantText' => _AssistantBubble(
          row: row,
          transport: transport,
          sessionId: sessionId,
          state: state,
          showFeedback: showFeedback,
          isSourceCurrent: isSourceCurrent),
      'reasoning' => _ReasoningTile(
          text: row['text'] as String? ?? '',
          streaming: row['state'] == 'streaming'),
      'toolCall' => _ToolCallTile(row: row),
      'turnHeader' => _TurnHeader(row: row),
      'subagent' => _SubagentTile(row: row),
      'timelineMarker' => _TimelineMarkerWidget(row: row),
      _ => const SizedBox.shrink(),
    };
    final kind = row['kind'];
    if (kind != 'userInput' && kind != 'assistantText') return widget_;
    return GestureDetector(
      onLongPress: () => _showActions(context),
      child: widget_,
    );
  }
}

/// Delivery badge under a user bubble. States: `sending` (command in
/// flight), `sent` (server accepted), `processing` (this message's turn
/// is running), `failed` (tap to retry).
class _MsgBadge extends StatelessWidget {
  final String status;
  final VoidCallback? onRetry;

  const _MsgBadge({required this.status, this.onRetry});

  @override
  Widget build(BuildContext context) {
    final failed = status == 'failed';
    final Widget content;
    switch (status) {
      case 'sending':
        content = Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.schedule,
              size: 11, color: EmberColors.of(context).textFaint),
          const SizedBox(width: 3),
          Text('发送中',
              style: TextStyle(
                  fontSize: 9.5, color: EmberColors.of(context).textFaint)),
        ]);
      case 'sent':
        content = Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.check, size: 11, color: EmberColors.of(context).textFaint),
          const SizedBox(width: 3),
          Text('已发送',
              style: TextStyle(
                  fontSize: 9.5, color: EmberColors.of(context).textFaint)),
        ]);
      case 'processing':
        content = Row(mainAxisSize: MainAxisSize.min, children: [
          const SizedBox(
              width: 11,
              height: 11,
              child: CircularProgressIndicator(strokeWidth: 1.4)),
          const SizedBox(width: 3),
          Text('处理中',
              style:
                  TextStyle(fontSize: 9.5, color: EmberColors.of(context).run)),
        ]);
      default: // failed
        content = Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.error_outline,
              size: 12, color: EmberColors.of(context).err),
          const SizedBox(width: 3),
          Text('发送失败 · 点击重试',
              style:
                  TextStyle(fontSize: 9.5, color: EmberColors.of(context).err)),
        ]);
    }
    if (!failed) {
      return Padding(
        padding: const EdgeInsets.only(top: 3),
        child: content,
      );
    }
    return Padding(
      padding: const EdgeInsets.only(top: 3),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onRetry,
        child: content,
      ),
    );
  }
}

class _UserBubble extends StatelessWidget {
  final Map<String, dynamic> row;
  final ConversationTransport transport;
  final String sessionId;
  final bool Function()? isSourceCurrent;

  /// Delivery badge (see [_MsgBadge]); null renders none.
  final String? badge;

  /// Retry callback shown when [badge] is `failed`.
  final VoidCallback? onRetry;

  const _UserBubble({
    required this.row,
    required this.transport,
    required this.sessionId,
    this.badge,
    this.onRetry,
    this.isSourceCurrent,
  });

  @override
  Widget build(BuildContext context) {
    final text = row['text'] as String? ?? '';
    final attachments = row['attachments'];
    return Align(
      alignment: Alignment.centerRight,
      child: Container(
        margin: const EdgeInsets.only(left: 56, top: 4, bottom: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: EmberColors.of(context).primary,
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(EmberRadius.content),
                  topRight: Radius.circular(EmberRadius.content),
                  bottomLeft: Radius.circular(EmberRadius.content),
                  bottomRight: Radius.circular(EmberRadius.bubbleTail),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  if (attachments is List)
                    for (final a in attachments)
                      if (a is Map)
                        _AttachmentView(
                          attachment: a.cast<String, dynamic>(),
                          transport: transport,
                          sessionId: sessionId,
                          isSourceCurrent: isSourceCurrent,
                        ),
                  if (text.isNotEmpty)
                    SelectableText(text,
                        style: const TextStyle(
                            fontSize: 14, height: 1.5, color: Colors.white)),
                ],
              ),
            ),
            // 徽标挂在气泡外的 bg 上(时间戳位):faint/run/err 相对 bg
            // 才有正常对比度,放在橙底内会被主色压住。
            if (badge != null) _MsgBadge(status: badge!, onRetry: onRetry),
          ],
        ),
      ),
    );
  }
}

class _AttachmentView extends StatefulWidget {
  final Map<String, dynamic> attachment;
  final ConversationTransport transport;
  final String sessionId;
  final bool Function()? isSourceCurrent;

  const _AttachmentView({
    required this.attachment,
    required this.transport,
    required this.sessionId,
    this.isSourceCurrent,
  });

  @override
  State<_AttachmentView> createState() => _AttachmentViewState();
}

class _AttachmentViewState extends State<_AttachmentView> {
  Uint8List? _imageBytes;
  bool _failed = false;
  int _loadGeneration = 0;

  bool get _isImage =>
      '${widget.attachment['mime'] ?? ''}'.startsWith('image/');

  @override
  void initState() {
    super.initState();
    if (_isImage) _load();
  }

  @override
  void didUpdateWidget(covariant _AttachmentView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.transport != widget.transport ||
        oldWidget.sessionId != widget.sessionId ||
        oldWidget.attachment['ref'] != widget.attachment['ref']) {
      _loadGeneration++;
      _imageBytes = null;
      _failed = false;
      if (_isImage) _load();
    }
  }

  @override
  void dispose() {
    _loadGeneration++;
    super.dispose();
  }

  Future<void> _load() async {
    final generation = ++_loadGeneration;
    final ref = widget.attachment['ref'] as String?;
    final sessionId = widget.sessionId;
    final transport = widget.transport;
    bool current() =>
        mounted &&
        generation == _loadGeneration &&
        transport == widget.transport &&
        sessionId == widget.sessionId &&
        (widget.isSourceCurrent?.call() ?? true);
    if (ref == null || !current()) return;
    try {
      final res = await transport.attachmentRead(sessionId, ref: ref);
      if (!current()) return;
      setState(() => _imageBytes = res.bytes);
    } catch (_) {
      if (current()) setState(() => _failed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final fileName = '${widget.attachment['fileName'] ?? '附件'}';
    if (!_isImage) {
      return Container(
        margin: const EdgeInsets.only(bottom: 6),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: EmberColors.of(context).raise,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.insert_drive_file_outlined, size: 16),
            const SizedBox(width: 6),
            Flexible(
              child: Text(fileName,
                  style: const TextStyle(fontSize: 12),
                  overflow: TextOverflow.ellipsis),
            ),
          ],
        ),
      );
    }
    if (_failed) {
      return Text('[图片加载失败] $fileName',
          style: TextStyle(
              fontSize: 11, color: EmberColors.of(context).textFaint));
    }
    if (_imageBytes == null) {
      return const Padding(
        padding: EdgeInsets.all(12),
        child: SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 1.5)),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Image.memory(
          _imageBytes!,
          width: 220,
          fit: BoxFit.cover,
          // Decode at DISPLAY size, not source size — a 12MP photo is
          // ~48MB RGBA at full decode; this caps it at 220 logical px.
          cacheWidth: (220 * MediaQuery.devicePixelRatioOf(context)).round(),
        ),
      ),
    );
  }
}

class _StreamingMarkdown extends StatefulWidget {
  final String text;
  final bool streaming;

  const _StreamingMarkdown({
    super.key,
    required this.text,
    required this.streaming,
  });

  @override
  State<_StreamingMarkdown> createState() => _StreamingMarkdownState();
}

class _StreamingMarkdownState extends State<_StreamingMarkdown> {
  static const _window = Duration(milliseconds: 250);

  late String _renderedText = widget.text;
  late String _latestText = widget.text;
  Timer? _timer;

  @override
  void didUpdateWidget(covariant _StreamingMarkdown oldWidget) {
    super.didUpdateWidget(oldWidget);
    _latestText = widget.text;
    if (!widget.streaming) {
      _timer?.cancel();
      _timer = null;
      _renderedText = widget.text;
      return;
    }
    if (widget.text != _renderedText && _timer == null) {
      _timer = Timer(_window, () {
        _timer = null;
        if (!mounted || _latestText == _renderedText) return;
        setState(() => _renderedText = _latestText);
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _timer = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      ZflowMarkdown(_renderedText, fontSize: 13);
}

@visibleForTesting
Widget streamingMarkdownForTest({
  Key? key,
  required String text,
  required bool streaming,
}) =>
    _StreamingMarkdown(key: key, text: text, streaming: streaming);

Key? _assistantMarkdownKey(Map<String, dynamic> row) {
  final rowId = row['rowId'];
  if (rowId == null) return null;
  return ValueKey('assistant-md:$rowId:${row['entityId'] ?? ''}');
}

class _AssistantBubble extends StatelessWidget {
  final Map<String, dynamic> row;
  final ConversationTransport transport;
  final String sessionId;
  final ConversationState state;
  final bool showFeedback;
  final bool Function()? isSourceCurrent;

  const _AssistantBubble({
    required this.row,
    required this.transport,
    required this.sessionId,
    required this.state,
    this.showFeedback = true,
    this.isSourceCurrent,
  });

  void _setFeedback(String? value) {
    if (sessionId.isEmpty ||
        (isSourceCurrent != null && !isSourceCurrent!())) {
      return;
    }
    // Optimistic: update the icon instantly; server row.upserted confirms.
    state.optimisticRowUpdate(row['rowId'] as num?, {'feedback': value});
    transport
        .setAssistantFeedback(
          sessionId,
          {
            'rowId': row['rowId'],
            if (row['entityId'] != null) 'entityId': row['entityId'],
          },
          value,
        )
        .catchError((_) {});
  }

  @override
  Widget build(BuildContext context) {
    final text = row['text'] as String? ?? '';
    final streaming = row['state'] == 'streaming';
    final feedback = row['feedback'] as String?;
    final rowTs = _rowTsOf(row);
    return Container(
      margin: const EdgeInsets.only(right: 24, top: 4, bottom: 4),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: EmberColors.of(context).card,
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(EmberRadius.content),
          topRight: Radius.circular(EmberRadius.content),
          bottomRight: Radius.circular(EmberRadius.content),
          bottomLeft: Radius.circular(EmberRadius.bubbleTail),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          streaming
              ? _StreamingMarkdown(
                  key: _assistantMarkdownKey(row),
                  text: text,
                  streaming: true,
                )
              : ZflowMarkdown(text, fontSize: 13),
          if (showFeedback)
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (streaming)
                  const Padding(
                    padding: EdgeInsets.only(top: 6),
                    child: SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(strokeWidth: 1.5),
                    ),
                  )
                else ...[
                  _FeedbackButton(
                    icon: Icons.copy_outlined,
                    active: false,
                    onTap: () =>
                        Clipboard.setData(ClipboardData(text: text)),
                  ),
                  _FeedbackButton(
                    icon: Icons.thumb_up_alt_outlined,
                    active: feedback == 'like',
                    onTap: () =>
                        _setFeedback(feedback == 'like' ? null : 'like'),
                  ),
                  _FeedbackButton(
                    icon: Icons.thumb_down_alt_outlined,
                    active: feedback == 'dislike',
                    onTap: () =>
                        _setFeedback(feedback == 'dislike' ? null : 'dislike'),
                  ),
                  // 回合时间戳(桌面端约定:行尾小字,今天只给时刻)。
                  Text(_messageTimeLabel(rowTs),
                      style: TextStyle(
                          fontSize: 11,
                          color: EmberColors.of(context).textFaint)),
                ],
              ],
            ),
        ],
      ),
    );
  }
}

/// 行级时间戳:协议 ts 优先(历史行带真实时间),回落视图层到达戳。
int? _rowTsOf(Map<String, dynamic> row) {
  final ts = (row['ts'] as num?)?.toInt() ?? 0;
  if (ts > 0) return ts;
  return (row['_zflowTs'] as num?)?.toInt();
}

/// 消息时间标签(对照桌面 chat.message.time):今天 HH:mm,昨天带
/// "昨天"前缀,同年 M月d日,跨年带年份。
String _messageTimeLabel(int? millis) {
  if (millis == null || millis <= 0) return '';
  final t = DateTime.fromMillisecondsSinceEpoch(millis);
  final now = DateTime.now();
  final hhmm =
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  final day = DateTime(t.year, t.month, t.day);
  final today = DateTime(now.year, now.month, now.day);
  final daysAgo = today.difference(day).inDays;
  if (daysAgo == 0) return hhmm;
  if (daysAgo == 1) return '昨天 $hhmm';
  if (t.year == now.year) return '${t.month}月${t.day}日 $hhmm';
  return '${t.year}年${t.month}月${t.day}日 $hhmm';
}

class _FeedbackButton extends StatelessWidget {
  final IconData icon;
  final bool active;
  final VoidCallback onTap;

  const _FeedbackButton({
    required this.icon,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: Icon(icon,
          size: 15,
          color: active
              ? EmberColors.of(context).primary
              : EmberColors.of(context).textFaint),
      onPressed: onTap,
      visualDensity: VisualDensity.compact,
    );
  }
}

/// Assistant thinking block. Ember look: tile one step darker than card
/// (the bg↔card midpoint, per theme), 10pt radius, 3px state rail (run
/// while streaming, faint when done). The label is a standalone faint
/// caption row (▸/▾ prefix) toggling the body, replacing the old
/// ExpansionTile header text.
class _ReasoningTile extends StatefulWidget {
  final String text;
  final bool streaming;

  const _ReasoningTile({required this.text, this.streaming = false});

  @override
  State<_ReasoningTile> createState() => _ReasoningTileState();
}

class _ReasoningTileState extends State<_ReasoningTile> {
  /// 默认展开（用户裁定）；折叠时显示一行预览。
  bool _open = true;

  @override
  Widget build(BuildContext context) {
    final e = EmberColors.of(context);
    final arrow = _open ? '▾ ' : '▸ ';
    final preview = widget.text
        .split('\n')
        .firstWhere((l) => l.trim().isNotEmpty, orElse: () => '');
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      decoration: BoxDecoration(
        color: Color.lerp(e.bg, e.card, 0.5),
        borderRadius: BorderRadius.circular(EmberRadius.control),
        // Status accent rail: run while thinking, neutral when done. Drawn
        // as a border rather than a stretched sibling Row child — Row
        // + CrossAxisAlignment.stretch hands infinite height to its children
        // inside the unbounded message list (crashes layout in debug and
        // corrupts it in release).
        border: Border(
          left: BorderSide(
            width: 3,
            color: widget.streaming ? e.run : e.textFaint,
          ),
        ),
      ),
      // Compensate the border's painted width so content lines up exactly
      // where the old rail child sat.
      child: Padding(
        padding: const EdgeInsets.only(left: 3),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => setState(() => _open = !_open),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
                child: Row(
                  children: [
                    Text('$arrow${widget.streaming ? '思考中…' : '思考'}',
                        style: TextStyle(
                            // 标签加大(用户裁定:可读性优先),预览仍
                            // 保持小字弱化。
                            fontSize: EmberType.body,
                            fontWeight: FontWeight.w600,
                            color: e.textSoft)),
                    if (!_open && preview.isNotEmpty) ...[
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(preview,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: EmberType.caption,
                                color: e.textFaint.withValues(alpha: 0.7))),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            if (_open)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                child: ZflowMarkdown(widget.text, fontSize: 12),
              ),
          ],
        ),
      ),
    );
  }
}

/// 工具族的强调色(用户裁定:不同工具输出块分色),全部取自 Ember 色板:
/// todo/计划类主色、执行类(bash)琥珀、写文件类绿色、读/检索类蓝色、
/// 其余回落主色。err 保留给错误状态,不参与分色。
Color _toolAccent(String toolName, EmberColors e) {
  final n = toolName.toLowerCase();
  if (n.contains('todo') || n.contains('plan')) return e.primary;
  if (n == 'bash' || n.contains('shell') || n.contains('terminal')) {
    return e.warn;
  }
  if (n.contains('edit') || n.contains('write')) return e.ok;
  if (n.contains('read') ||
      n.contains('grep') ||
      n.contains('glob') ||
      n.contains('search') ||
      n.contains('find')) {
    return e.run;
  }
  return e.primary;
}

/// todo/计划工具输出解析(纯函数,公开给测试):逐个尝试
/// input/inputText/content/output(含 output.text),全部失败返回 null
/// (回落原始文本)。复用洞察面板的容错解析器。
List<PlanStep>? todoStepsOf(Map<String, dynamic> row) {
  for (final cand in _planPayloadCandidates(row)) {
    final steps = _planStepsFromValue(cand);
    if (steps != null) return steps;
  }
  return null;
}

/// 步骤列表块(工具块内的 todo 展示):状态图标 + 标题,完成项划线。
Widget _todoStepsBlock(BuildContext context, List<PlanStep> steps) {
  final e = EmberColors.of(context);
  return Padding(
    padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final s in steps)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(
              children: [
                Icon(
                  s.completed
                      ? Icons.check_circle
                      : s.inProgress
                          ? Icons.play_circle_outline
                          : Icons.radio_button_unchecked,
                  size: 13,
                  color: s.completed
                      ? e.ok
                      : s.inProgress
                          ? e.run
                          : e.textFaint,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    s.title,
                    style: TextStyle(
                        fontSize: 12,
                        color: e.textSoft,
                        decoration: s.completed
                            ? TextDecoration.lineThrough
                            : TextDecoration.none),
                  ),
                ),
              ],
            ),
          ),
      ],
    ),
  );
}

/// 工具调用块。Ember look matches [_ReasoningTile]: tile one step
/// darker than card, 10pt radius, 3px rail colored by status (success→ok,
/// error→err, running→run). The tool name is a standalone caption row
/// (▸/▾ prefix, term font, 工具族强调色) toggling the input/output/error
/// detail.
class _ToolCallTile extends StatefulWidget {
  final Map<String, dynamic> row;

  const _ToolCallTile({required this.row});

  @override
  State<_ToolCallTile> createState() => _ToolCallTileState();
}

class _ToolCallTileState extends State<_ToolCallTile> {
  /// 默认展开（用户裁定）；折叠时显示一行预览。
  bool _open = true;

  @override
  Widget build(BuildContext context) {
    final row = widget.row;
    final e = EmberColors.of(context);
    final toolName = row['toolName'] as String? ?? 'tool';
    final status = row['status'] as String? ?? '';
    final inputText = row['inputText'] as String? ?? '';
    final output = row['output'];
    final outputText = output is Map ? output['text'] as String? ?? '' : '';
    final error = row['error'];
    final progress = row['progress'];
    final display = row['display'];
    final diff = extractDiff(row);

    /// 折叠态的一行预览:输入首行优先,回落输出首行。
    final toolPreview = (inputText.isNotEmpty ? inputText : outputText)
        .split('\n')
        .firstWhere((l) => l.trim().isNotEmpty, orElse: () => '');

    /// bash 工具保留原始输入输出;其余工具直接展示结果。
    final isBash = toolName.toLowerCase() == 'bash';

    /// 工具族强调色(分色 + 名称着色,用户裁定)。
    final accent = _toolAccent(toolName, e);

    /// todo/计划工具:输出 JSON 解析成步骤列表展示(用户裁定:不铺
    /// 原始 JSON)。仅对 todo/计划类工具启用,解析失败回落原始文本。
    final todoSteps =
        isBash || !_todoPlanToolName.hasMatch(toolName)
            ? null
            : todoStepsOf(row);

    final (icon, color) = switch (status) {
      'running' || 'inputStreaming' || 'pendingApproval' => (
          Icons.hourglass_top,
          e.run
        ),
      'success' => (Icons.check, e.ok),
      'error' => (Icons.error_outline, e.err),
      'cancelled' => (Icons.block, e.warn),
      _ => (Icons.build_outlined, e.textFaint),
    };

    final images = display is Map &&
            display['kind'] == 'node_repl_images' &&
            display['images'] is List
        ? display['images'] as List
        : const [];

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 3),
      decoration: BoxDecoration(
        color: Color.lerp(e.bg, e.card, 0.5),
        borderRadius: BorderRadius.circular(EmberRadius.control),
        // Status rail mirrors the icon color so the state reads at a glance
        // even while collapsed. Drawn as a border rather than a stretched
        // sibling Row child — Row + CrossAxisAlignment.stretch hands
        // infinite height to its children inside the unbounded message list
        // (crashes layout in debug and corrupts it in release).
        border: Border(
          left: BorderSide(width: 3, color: color),
        ),
      ),
      // Compensate the border's painted width so content lines up exactly
      // where the old rail child sat.
      child: Padding(
        padding: const EdgeInsets.only(left: 3),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => setState(() => _open = !_open),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
                child: Row(
                  children: [
                    Text(_open ? '▾ ' : '▸ ',
                        style: TextStyle(
                            fontSize: EmberType.caption, color: e.textFaint)),
                    Icon(icon, size: 12, color: color),
                    const SizedBox(width: 4),
                    Flexible(
                      child: Text(toolName,
                          style: TextStyle(
                              // 名称加大着色(用户裁定:可读性优先),
                              // 与左侧状态图标、标题族色一致。
                              fontSize: EmberType.body,
                              fontFamily: EmberFonts.term,
                              color: accent),
                          overflow: TextOverflow.ellipsis),
                    ),
                    // 执行状态文字(用户裁定):标题里直接可见,不只靠颜色。
                    if (status == 'running' ||
                        status == 'inputStreaming' ||
                        status == 'pendingApproval') ...[
                      const SizedBox(width: 6),
                      Text('执行中',
                          style: TextStyle(
                              fontSize: EmberType.caption, color: e.run)),
                    ] else if (status == 'success') ...[
                      const SizedBox(width: 6),
                      Text('执行完毕',
                          style: TextStyle(
                              fontSize: EmberType.caption, color: e.textFaint)),
                    ],
                    if (!_open) ...[
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          toolPreview,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: EmberType.caption,
                              color: e.textFaint.withValues(alpha: 0.7)),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            if (_open) ...[
              // 用户裁定:bash 保留原始输入输出,其余工具直接展示结果
              // (不再铺原始输入/输出 kv);todo/计划工具解析成步骤列表。
              if (isBash) ...[
                if (inputText.isNotEmpty) _kv(context, '输入', inputText, accent),
                if (outputText.isNotEmpty)
                  _kv(context, '输出', outputText, accent),
              ] else if (todoSteps != null)
                _todoStepsBlock(context, todoSteps)
              else if (outputText.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      // 输出块按工具族着色(用户裁定):同一强调色的
                      // 低透明度底,随明暗主题自动适配。
                      color: accent.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: SelectableText(
                      outputText,
                      style: TextStyle(
                          fontSize: 11.5,
                          height: 1.45,
                          color: EmberColors.of(context).textSoft),
                    ),
                  ),
                ),
              if (error is Map)
                _kv(context, '错误',
                    '${error['code'] ?? ''} ${error['message'] ?? ''}'),
            ],
            if (progress is Map) _ProgressRow(progress: progress),
            if (diff != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                child: DiffView(diff: diff),
              ),
            for (final image in images)
              if (image is Map && image['base64'] is String)
                Builder(
                  builder: (context) {
                    final bytes =
                        decodeInlineToolImage(image['base64'] as String);
                    if (bytes == null) return const SizedBox.shrink();
                    return Padding(
                      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: Image.memory(
                          bytes,
                          fit: BoxFit.contain,
                          // Cap the decode at viewport width — inline tool
                          // outputs can embed multi-megapixel renders.
                          cacheWidth: (MediaQuery.sizeOf(context).width *
                                  MediaQuery.devicePixelRatioOf(context))
                              .round(),
                          errorBuilder: (_, _, _) => const SizedBox.shrink(),
                        ),
                      ),
                    );
                  },
                ),
          ],
        ),
      ),
    );
  }

  Widget _kv(BuildContext context, String label, String value,
      [Color? accent]) {
    final e = EmberColors.of(context);
    // Pretty-print JSON input when possible (official shows structured view)
    final display = formatToolValue(value);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: TextStyle(
                  fontSize: 10.5, color: accent ?? e.textFaint)),
          const SizedBox(height: 2),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              // 工具族分色(用户裁定):有强调色时以低透明度着底,否则
              // 用共用代码表面。
              color: accent != null
                  ? accent.withValues(alpha: 0.1)
                  : e.codeBlockBg,
              borderRadius: BorderRadius.circular(8),
            ),
            child: SelectableText(
              display,
              style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 11,
                  color: e.textSolid),
            ),
          ),
        ],
      ),
    );
  }
}

class _ProgressRow extends StatelessWidget {
  final Map progress;

  const _ProgressRow({required this.progress});

  @override
  Widget build(BuildContext context) {
    final bytes = (progress['bytes'] as num?)?.toInt() ?? 0;
    final preview = progress['previewLine'] as String? ?? '';
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
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
              [
                if (preview.isNotEmpty) preview,
                '${(bytes / 1024).toStringAsFixed(1)} KB',
              ].join(' · '),
              style: TextStyle(
                  fontSize: 11, color: EmberColors.of(context).textFaint),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

class _TurnHeader extends StatefulWidget {
  final Map<String, dynamic> row;

  /// First error snippet of this turn's failed tool calls (failure state).
  final String? errorSummary;

  const _TurnHeader({required this.row, this.errorSummary});

  @override
  State<_TurnHeader> createState() => _TurnHeaderState();
}

class _TurnHeaderState extends State<_TurnHeader> {
  final Stopwatch _watch = Stopwatch();
  Timer? _ticker;

  String get _state => widget.row['state'] as String? ?? '';

  @override
  void initState() {
    super.initState();
    _syncTimer();
  }

  @override
  void didUpdateWidget(covariant _TurnHeader oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncTimer();
  }

  /// The wire only sends activeMs on completion, so while running the
  /// elapsed time ticks from a local stopwatch (started when the running
  /// header first appeared — reopening an already-running turn counts from
  /// open). If a live activeMs shows up in deltas, it wins.
  void _syncTimer() {
    final running = _state == 'running';
    if (running && !_watch.isRunning) {
      _watch.start();
      _ticker ??= Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted && _watch.isRunning) setState(() {});
      });
    } else if (!running && _watch.isRunning) {
      _watch.stop();
      _ticker?.cancel();
      _ticker = null;
      if (mounted) setState(() {});
    }
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  String _fmtDuration(int? ms) {
    if (ms == null || ms <= 0) return '';
    if (ms < 1000) return '${ms}ms';
    final s = ms / 1000;
    if (s < 60) return '${s.toStringAsFixed(1)}s';
    final m = s ~/ 60;
    return '${m}m${(s % 60).round()}s';
  }

  @override
  Widget build(BuildContext context) {
    final state = _state;
    final fileChanges = widget.row['fileChanges'];
    final activeMs = (widget.row['activeMs'] as num?)?.toInt();
    final duration = _fmtDuration(activeMs);
    final liveMs = (activeMs != null && activeMs > 0)
        ? activeMs
        : _watch.elapsedMilliseconds;

    String stats = '';
    if (fileChanges is Map) {
      final adds = fileChanges['additions'];
      final dels = fileChanges['deletions'];
      final files = fileChanges['files'];
      final parts = <String>[
        if (adds is num && adds > 0) '+$adds',
        if (dels is num && dels > 0) '-$dels',
        if (files is num && files > 0) '$files 文件',
      ];
      stats = parts.join(' ');
    }

    final errSummary = widget.errorSummary?.trim();
    final liveLabel = _fmtDuration(liveMs);
    final label = switch (state) {
      'running' => liveLabel.isEmpty ? '本轮执行中' : '本轮执行中 · $liveLabel',
      'completedSuccess' => [
          '本轮完成',
          if (duration.isNotEmpty) duration,
          if (stats.isNotEmpty) stats,
        ].join(' · '),
      'completedInterrupted' => '已中断',
      'failed' => [
          '本轮失败',
          if (errSummary != null && errSummary.isNotEmpty) errSummary,
        ].join(' · '),
      _ => '',
    };
    if (label.isEmpty) return const SizedBox.shrink();
    final color = switch (state) {
      'running' => EmberColors.of(context).run,
      'failed' => EmberColors.of(context).err,
      'completedInterrupted' => EmberColors.of(context).warn,
      _ => EmberColors.of(context).textFaint,
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          const Expanded(child: Divider()),
          Flexible(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Text(
                label,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 11, color: color.withValues(alpha: 0.9)),
              ),
            ),
          ),
          const Expanded(child: Divider()),
        ],
      ),
    );
  }
}

class _TimelineMarkerWidget extends StatelessWidget {
  final Map<String, dynamic> row;

  const _TimelineMarkerWidget({required this.row});

  @override
  Widget build(BuildContext context) {
    final marker = row['marker'];
    if (marker is! Map) return const SizedBox.shrink();
    final type = '${marker['type'] ?? ''}';

    final (icon, text, color) = switch (type) {
      'compact' => (
          Icons.compress,
          '压缩上下文 · ${marker['status'] ?? ''}'
              '${marker['tokensBefore'] != null ? ' · ${marker['tokensBefore']}→${marker['tokensAfter'] ?? '?'} tokens' : ''}',
          EmberColors.of(context).primary
        ),
      'forkNotice' => (
          Icons.fork_right,
          '从会话分叉而来',
          EmberColors.of(context).textFaint
        ),
      'forkCreated' => (
          Icons.fork_right,
          '已创建分叉会话',
          EmberColors.of(context).textFaint
        ),
      'modelChange' => (
          Icons.swap_horiz,
          '模型切换 ${marker['fromModel'] ?? ''} → ${marker['toModel'] ?? ''}',
          EmberColors.of(context).warn
        ),
      'goalSet' => (
          Icons.flag_outlined,
          '设定目标: ${marker['objective'] ?? ''}',
          EmberColors.of(context).ok
        ),
      'goalVerify' => (
          Icons.fact_check_outlined,
          '目标验证 第${marker['iteration'] ?? '?'}轮 · ${marker['outcome'] ?? ''}',
          EmberColors.of(context).ok
        ),
      'retryNotice' => (
          Icons.refresh,
          '自动重试 第${marker['attempt'] ?? '?'}次 (${marker['reasonCode'] ?? ''})',
          EmberColors.of(context).warn
        ),
      'checkpointRestored' => (
          Icons.restore,
          '已恢复检查点',
          EmberColors.of(context).textFaint
        ),
      _ => (Icons.info_outline, type, EmberColors.of(context).textFaint),
    };

    return Center(
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 6),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 12, color: color),
            const SizedBox(width: 5),
            Flexible(
              child: Text(
                text,
                style: TextStyle(fontSize: 11, color: color),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SubagentTile extends StatelessWidget {
  final Map<String, dynamic> row;

  const _SubagentTile({required this.row});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.deepPurple.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          const Icon(Icons.smart_toy_outlined,
              size: 15, color: Colors.deepPurpleAccent),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('子代理 · ${row['subagentType'] ?? ''}',
                    style: const TextStyle(fontSize: 12)),
                Text('${row['status'] ?? ''}  ${row['summaryText'] ?? ''}',
                    style: TextStyle(
                        fontSize: 11, color: EmberColors.of(context).textFaint),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 回合文件变更的查看器:拉取 conversationFileChangesV4 并展示。解析出
/// 文件清单时用结构化列表(路径 + 增删行数,桌面变更条同款信息),形状
/// 未知时回退原始 JSON。
Future<void> showTurnFileChangesSheet(
  BuildContext context, {
  required ConversationTransport transport,
  required String sessionId,
  required Map<String, dynamic> header,
  int Function()? beginFileChangesOperation,
  bool Function(int generation)? isFileChangesOperationCurrent,
  bool Function()? isSourceCurrent,
}) async {
  if (isSourceCurrent != null && !isSourceCurrent()) return;
  final operationGeneration = beginFileChangesOperation?.call();
  try {
    final changes = await transport.fileChanges(
      sessionId,
      target: {'rowId': header['rowId'], 'entityId': header['entityId']},
    );
    if (!context.mounted ||
        (isSourceCurrent != null && !isSourceCurrent()) ||
        (operationGeneration != null &&
            !(isFileChangesOperationCurrent?.call(operationGeneration) ??
                true))) {
      return;
    }
    final entries = parseFileChangeEntries(changes);
    if (entries == null) {
      showModalBottomSheet(
        context: context,
        builder: (context) => _JsonSheet(title: '编辑', data: changes),
      );
      return;
    }
    final adds = (header['fileChanges']?['additions'] as num?)?.toInt();
    final dels = (header['fileChanges']?['deletions'] as num?)?.toInt();
    showModalBottomSheet(
      context: context,
      builder: (context) => _FileChangesSheet(
        entries: entries,
        additions: adds,
        deletions: dels,
      ),
    );
  } catch (e) {
    if (context.mounted &&
        (isSourceCurrent == null || isSourceCurrent()) &&
        (operationGeneration == null ||
            (isFileChangesOperationCurrent?.call(operationGeneration) ??
                true))) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('获取失败: $e')));
    }
  }
}

/// 解析文件变更响应为条目(path/状态/增删)。形状未知返回 null(回退
/// 原始 JSON 展示)。
List<({String path, int? additions, int? deletions})>?
    parseFileChangeEntries(Object? changes) {
  List? list;
  if (changes is List) {
    list = changes;
  } else if (changes is Map) {
    for (final k in const ['files', 'changes', 'entries', 'items']) {
      final v = changes[k];
      if (v is List && v.isNotEmpty) {
        list = v;
        break;
      }
    }
    if (list == null && changes['path'] != null) list = [changes];
  }
  if (list == null) return null;
  final entries = <({String path, int? additions, int? deletions})>[];
  for (final item in list) {
    if (item is! Map) return null;
    final path = '${item['path'] ?? item['file'] ?? item['name'] ?? ''}';
    if (path.isEmpty) return null;
    entries.add((
      path: path,
      additions: (item['additions'] as num?)?.toInt() ??
          (item['added'] as num?)?.toInt(),
      deletions: (item['deletions'] as num?)?.toInt() ??
          (item['removed'] as num?)?.toInt(),
    ));
  }
  return entries.isEmpty ? null : entries;
}

/// 回合内文件变更卡(桌面 `› N 个文件已更改 +312 -2` 样式):点击拉取
/// 明细并展示。
class _FileChangesCard extends StatelessWidget {
  final Map<String, dynamic> header;
  final ConversationTransport transport;
  final String sessionId;
  final int Function()? beginFileChangesOperation;
  final bool Function(int generation)? isFileChangesOperationCurrent;
  final bool Function()? isSourceCurrent;

  const _FileChangesCard({
    required this.header,
    required this.transport,
    required this.sessionId,
    this.beginFileChangesOperation,
    this.isFileChangesOperationCurrent,
    this.isSourceCurrent,
  });

  @override
  Widget build(BuildContext context) {
    final colors = EmberColors.of(context);
    final fileChanges = header['fileChanges'] as Map? ?? const {};
    final files = (fileChanges['files'] as num?)?.toInt() ?? 0;
    final adds = (fileChanges['additions'] as num?)?.toInt();
    final dels = (fileChanges['deletions'] as num?)?.toInt();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: InkWell(
        borderRadius: BorderRadius.circular(EmberRadius.control),
        onTap: () => showTurnFileChangesSheet(
          context,
          transport: transport,
          sessionId: sessionId,
          header: header,
          beginFileChangesOperation: beginFileChangesOperation,
          isFileChangesOperationCurrent: isFileChangesOperationCurrent,
          isSourceCurrent: isSourceCurrent,
        ),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          decoration: BoxDecoration(
            color: Color.lerp(colors.bg, colors.card, 0.5),
            borderRadius: BorderRadius.circular(EmberRadius.control),
            border: Border.all(color: colors.hairline),
          ),
          child: Row(
            children: [
              Icon(Icons.chevron_right, size: 14, color: colors.textFaint),
              const SizedBox(width: 6),
              Expanded(
                child: Text('$files 个文件已更改',
                    style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        color: colors.textSolid)),
              ),
              if (adds != null && adds > 0)
                Text('+$adds',
                    style: TextStyle(fontSize: 12, color: colors.ok)),
              if (dels != null && dels > 0) ...[
                const SizedBox(width: 6),
                Text('-$dels',
                    style: TextStyle(fontSize: 12, color: colors.err)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// 结构化文件变更明细(桌面变更面板样式):统计头 + 路径/增删行。
class _FileChangesSheet extends StatelessWidget {
  final List<({String path, int? additions, int? deletions})> entries;
  final int? additions;
  final int? deletions;

  const _FileChangesSheet({
    required this.entries,
    this.additions,
    this.deletions,
  });

  @override
  Widget build(BuildContext context) {
    final colors = EmberColors.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(0, 12, 0, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: EmberSpacing.page),
              child: Row(
                children: [
                  Text('编辑 · ${entries.length}',
                      style: TextStyle(
                          fontSize: EmberType.body,
                          fontWeight: FontWeight.w600,
                          color: colors.textSolid)),
                  const Spacer(),
                  if (additions != null && additions! > 0)
                    Text('+$additions',
                        style: TextStyle(fontSize: 12.5, color: colors.ok)),
                  if (deletions != null && deletions! > 0) ...[
                    const SizedBox(width: 8),
                    Text('-$deletions',
                        style: TextStyle(fontSize: 12.5, color: colors.err)),
                  ],
                ],
              ),
            ),
            const Divider(height: 16),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: entries.length,
                itemBuilder: (context, i) {
                  final e = entries[i];
                  final name =
                      e.path.split('/').where((p) => p.isNotEmpty).last;
                  final dir = e.path.substring(
                      0, e.path.length - name.length);
                  return ListTile(
                    dense: true,
                    leading: Icon(Icons.insert_drive_file_outlined,
                        size: 16, color: colors.textFaint),
                    title: Text(name,
                        style: TextStyle(
                            fontSize: 12.5, color: colors.textSolid)),
                    subtitle: dir.isEmpty
                        ? null
                        : Text(dir,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: 10.5, color: colors.textFaint)),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (e.additions != null && e.additions! > 0)
                          Text('+${e.additions}',
                              style: TextStyle(
                                  fontSize: 11.5, color: colors.ok)),
                        if (e.deletions != null && e.deletions! > 0) ...[
                          const SizedBox(width: 6),
                          Text('-${e.deletions}',
                              style: TextStyle(
                                  fontSize: 11.5, color: colors.err)),
                        ],
                      ],
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- bars

class _ContextUsageBar extends StatelessWidget {
  final ConversationState state;

  const _ContextUsageBar({required this.state});

  @override
  Widget build(BuildContext context) {
    final usage = state.usage;
    final window = usage?['contextWindow'];
    if (window is! Map) return const SizedBox.shrink();
    final used = (window['usedTokens'] as num?)?.toInt();
    final max = (window['maxTokens'] as num?)?.toInt();
    if (used == null || max == null || max <= 0) {
      return const SizedBox.shrink();
    }
    final ratio = (used / max).clamp(0.0, 1.0);
    final color = ratio > 0.8
        ? EmberColors.of(context).warn
        : EmberColors.of(context).primary;
    String fmt(int v) => v >= 1000 ? '${(v / 1000).toStringAsFixed(1)}k' : '$v';
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
      child: Row(
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: ratio,
                minHeight: 4,
                backgroundColor: EmberColors.of(context).raise,
                valueColor: AlwaysStoppedAnimation(color),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            '${fmt(used)}/${fmt(max)}',
            style: TextStyle(fontSize: 10, color: color),
          ),
        ],
      ),
    );
  }
}
