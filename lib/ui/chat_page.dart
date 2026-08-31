import 'dart:async';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../protocol/channel_client.dart';
import '../protocol/conversation.dart';
import '../protocol/rpc_result.dart';
import '../protocol/zflow_client.dart';
import '../state/log_store.dart';
import 'delayed_banner.dart';
import 'diff_view.dart';
import 'markdown_view.dart';
import 'theme.dart';
import 'usage_page.dart';

part 'chat/msg_widgets.dart';
part 'chat/insights.dart';
part 'chat/sheets.dart';
part 'chat/composer.dart';
part 'chat/controller.dart';

/// 由模型 option value 解析 (provider, model)。provider 必须用宿主
/// 显式给的 modelProviderId——value 的 "builtin:x/Model" 前缀不是
/// 注册表 id,直接拆分会得到 "provider not in registry"。
(String, String) providerModelOf(WorkspacePrep? prep, String value) {
  final model =
      value.contains('/') ? value.substring(value.lastIndexOf('/') + 1) : value;
  for (final v
      in prep?.option('model')?.options ?? const <ConfigOptionValue>[]) {
    if (v.value == value) {
      final fallbackProvider = value.contains('/')
          ? value.substring(0, value.lastIndexOf('/'))
          : value;
      return (v.modelProviderId ?? fallbackProvider, model);
    }
  }
  final idx = value.lastIndexOf('/');
  if (idx <= 0) return (value, value);
  return (value.substring(0, idx), model);
}

class ChatPage extends StatefulWidget {
  final BridgeSession session;
  final Map<String, dynamic> scope;
  final String workspaceKey;
  final String? sessionId;
  final String title;

  /// Embedded mode (Ember conversations tab): no Scaffold/AppBar shell —
  /// this widget renders the conversations-tab header row itself (device
  /// capsule + session title + stop + model pill + overflow + drawer) and
  /// outputs the message stream + banners + composer below it. Pushed
  /// usages (automation run history) keep the Scaffold chrome.
  final bool embedded;

  /// Embedded title push: fires whenever the desktop's title for this
  /// session changes (created/renamed — esp. right after a draft's
  /// createSession) and once when a draft adopts its session id, so the
  /// host can write back the now-current session. The host's rebuild epoch
  /// is echoed back as [onSessionInfo]'s third argument so a late push from
  /// a superseded instance can be recognized and ignored (A10). Never
  /// fires in Scaffold mode.
  final void Function(String sessionId, String title, int epoch)? onSessionInfo;

  /// Host shell 的会话重建代数(原样经 [onSessionInfo] 带回)。宿主以
  /// ValueKey(epoch) 重建本页,实例存活期间该值不变。
  final int sessionEpoch;

  /// Embedded header pieces owned by the host shell: the device capsule
  /// (built by the shell, opens the device switcher) and the drawer open
  /// callback. The session title comes through [headerTitle] so renames
  /// land without rebuilding the shell. All ignored in Scaffold mode.
  final Widget? headerLeading;
  final ValueListenable<String?>? headerTitle;

  /// 所属工作区展示名(顶栏第一行,会话标题下方小字;可空)。
  final String? headerWorkspace;
  final VoidCallback? onOpenDrawer;

  const ChatPage({
    super.key,
    required this.session,
    required this.scope,
    required this.workspaceKey,
    this.sessionId,
    required this.title,
    this.embedded = false,
    this.onSessionInfo,
    this.sessionEpoch = 0,
    this.headerLeading,
    this.headerTitle,
    this.headerWorkspace,
    this.onOpenDrawer,
  });

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class PendingFile {
  final String fileName;
  final String mime;
  final Uint8List bytes;

  PendingFile(this.fileName, this.mime, this.bytes);
}

String _guessMime(String fileName) {
  final ext = fileName.split('.').last.toLowerCase();
  return switch (ext) {
    'png' => 'image/png',
    'jpg' || 'jpeg' => 'image/jpeg',
    'gif' => 'image/gif',
    'webp' => 'image/webp',
    'svg' => 'image/svg+xml',
    'pdf' => 'application/pdf',
    'txt' || 'md' || 'log' => 'text/plain',
    'json' => 'application/json',
    'zip' => 'application/zip',
    _ => 'application/octet-stream',
  };
}

class _StaleChatOperation implements Exception {
  const _StaleChatOperation();
}

/// Retires echoes whose server-confirmed userInput rows have arrived.
/// Counts per text (sending the same text twice must retire exactly two
/// echoes, not both at the first confirmation), oldest echo first, and
/// never retires a `failed` echo — it must stay for retry. Pure for tests.
List<Map<String, dynamic>> removeEchoedTexts(
    List<Map<String, dynamic>> echoes, List<Map<String, dynamic>> rows) {
  if (echoes.isEmpty) return echoes;
  final confirmed = <String, int>{};
  for (final r in rows) {
    if (r['kind'] != 'userInput') continue;
    final t = '${r['text'] ?? ''}'.trim();
    confirmed[t] = (confirmed[t] ?? 0) + 1;
  }
  final remaining = <String, int>{...confirmed};
  return echoes.where((e) {
    if (e['status'] == 'failed') return true;
    final t = '${e['text'] ?? ''}'.trim();
    final n = remaining[t] ?? 0;
    if (n > 0) {
      remaining[t] = n - 1;
      return false;
    }
    return true;
  }).toList();
}

/// rowId of the LAST userInput row (the one whose turn is processed next),
/// or null when the conversation has none. Pure for tests.
num? lastUserInputRowId(List<Map<String, dynamic>> rows) {
  for (final r in rows.reversed) {
    if (r['kind'] == 'userInput') return r['rowId'] as num?;
  }
  return null;
}

/// 聊天页视图:输入框、滚动、菜单与对话框。会话数据、订阅、发送机、
/// 管理命令的所有权在 [ChatController](同库 part 文件 chat/controller),
/// 经 onChanged 收到重绘通知。
class _ChatPageState extends State<ChatPage> {
  final _inputController = TextEditingController();
  final _scrollController = ScrollController();
  late ChatController controller;

  /// Whether to keep the view pinned to the newest message. Starts true so
  /// opening the chat lands at the bottom; the user scrolling up unpins it.
  bool _stickToBottom = true;
  bool _scrollCallbackScheduled = false;
  bool _scrollAnimationInFlight = false;

  /// 源切换/销毁时作废在途滚动回调(滚动为视图私有,controller 的
  /// generation 不覆盖它)。
  int _scrollGeneration = 0;
  bool _showSlash = false;

  @override
  void initState() {
    super.initState();
    controller = ChatController(
      session: widget.session,
      scope: widget.scope,
      workspaceKey: widget.workspaceKey,
      sessionId: widget.sessionId,
      onChanged: () {
        if (mounted) setState(() {});
      },
      onToast: _toast,
      onSessionInfo: widget.onSessionInfo == null
          ? null
          : (sessionId, title) =>
              widget.onSessionInfo!(sessionId, title, widget.sessionEpoch),
      onRowsChanged: _scrollToBottom,
    );
    controller.start();
    _scrollController.addListener(_onScroll);
    _inputController.addListener(() {
      final text = _inputController.text;
      final show = (text.startsWith('/') || text.startsWith('\$')) &&
          !text.contains(' ');
      if (show != _showSlash && mounted) {
        setState(() => _showSlash = show);
      }
    });
  }

  @override
  void didUpdateWidget(covariant ChatPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_sameSource(oldWidget)) return;
    setState(() => _showSlash = false);
    controller.reattach(
      widget.session,
      widget.scope,
      widget.workspaceKey,
      widget.sessionId,
      watchTitle: widget.onSessionInfo != null,
    );
    _scrollGeneration++;
    _scrollAnimationInFlight = false;
    clearGroupRowsCache();
  }

  bool _sameSource(ChatPage oldWidget) {
    return identical(oldWidget.session, widget.session) &&
        oldWidget.workspaceKey == widget.workspaceKey &&
        mapEquals(oldWidget.scope, widget.scope) &&
        oldWidget.sessionId == widget.sessionId;
  }

  @override
  void dispose() {
    controller.dispose();
    _scrollGeneration++;
    _scrollAnimationInFlight = false;
    _showJumpToBottom.dispose();
    _inputController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  /// 是否显示「滚到底」浮钮:未钉底且有内容。
  final ValueNotifier<bool> _showJumpToBottom = ValueNotifier(false);

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    // Reverse list: offset 0 is the newest (bottom) message.
    _stickToBottom = _scrollController.position.pixels <= 40;
    _syncJumpToBottom();
  }

  void _syncJumpToBottom() {
    final hasRows = controller.state?.rows.isNotEmpty ?? false;
    _showJumpToBottom.value = !_stickToBottom && hasRows;
  }

  void _jumpToBottom() {
    if (!_scrollController.hasClients) return;
    _scrollController.animateTo(0,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut);
  }

  Future<void> _send() async {
    await controller.send(
      _inputController.text.trim(),
      askHeldQueueDisposition: _askHeldQueueDisposition,
      onCleared: () {
        _inputController.clear();
        setState(() => _showSlash = false);
      },
      onEchoEnqueued: _scrollToBottom,
    );
  }

  void _toast(String message) {
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    }
  }

  void _scrollToBottom() {
    if (_scrollCallbackScheduled) return;
    final scrollGeneration = _scrollGeneration;
    _scrollCallbackScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollCallbackScheduled = false;
      if (!mounted || scrollGeneration != _scrollGeneration) return;
      _syncJumpToBottom();
      final prependTail =
          controller.prependScrollPending ? controller.prependTailRow : null;
      controller.prependScrollPending = false;
      controller.prependTailRow = null;
      if (!_scrollController.hasClients) return;
      if (prependTail != null) {
        final rows = controller.state?.rows;
        final currentTail = rows == null || rows.isEmpty ? null : rows.last;
        if (identical(currentTail, prependTail)) return;
      }
      // Follow the newest message only while the user is pinned to the
      // bottom (or within 400px), so reading history isn't yanked.
      final position = _scrollController.position;
      if ((!_stickToBottom && position.pixels >= 400) ||
          position.pixels <= 1 ||
          _scrollAnimationInFlight) {
        return;
      }
      _scrollAnimationInFlight = true;
      _scrollController
          .animateTo(
        0,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      )
          .then<void>((_) {
        if (mounted && scrollGeneration == _scrollGeneration) {
          _scrollAnimationInFlight = false;
        }
      }, onError: (_, _) {
        if (mounted && scrollGeneration == _scrollGeneration) {
          _scrollAnimationInFlight = false;
        }
      });
    });
  }

  // ------------------------------------------------------------ sending

  Future<String?> _askHeldQueueDisposition() {
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('有排队中的消息'),
        content: const Text('立即发送将清空排队消息并插队执行'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, 'keepQueueAndSend'),
            child: const Text('排队发送'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, 'clearQueueAndSend'),
            child: const Text('立即发送'),
          ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------ sheets

  void _showModelSheet() {
    _showSessionConfigSheet(_SheetSection.model);
  }

  void _showThoughtSheet() {
    _showSessionConfigSheet(_SheetSection.thought);
  }

  void _showSessionConfigSheet(_SheetSection section) {
    final sourceGeneration = controller.sourceGeneration;
    final transport = controller.transport;
    final sessionId = controller.sessionId;
    // 立即用缓存打开(零等待);面板自持刷新——新鲜(≤5s)不发请求,
    // 否则强制拉取,数据到达后原地更新列表(删除的模型随之消失)。
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) => _ModelModeSheet(
        state: controller.state,
        transport: transport,
        prep: controller.prep,
        sessionId: sessionId,
        section: section,
        draftConfig: controller.draftConfig,
        isSourceCurrent: () => controller.isCurrentForSource(
          sourceGeneration,
          transport,
          sessionId: sessionId,
        ),
        onRefreshPrep: controller.fetchPrepForSheet,
        onDraftChange: (key, value) {
          if (!controller.isCurrentForSource(sourceGeneration, transport,
              sessionId: sessionId)) {
            return;
          }
          controller.setDraftOption(key, value);
        },
      ),
    );
  }

  /// Slash entries = builtin/custom commands from prepareWorkspace plus the
  /// desktop's skills (triggered as `$name` in the composer).
  List<_SlashItem> get _slashItems {
    final items = <_SlashItem>[];
    for (final c in controller.prep?.slashCommands ?? const <SlashCommand>[]) {
      items.add(_SlashItem(
        name: c.name,
        description: c.description,
        insert: '/${c.name} ',
        isSkill: false,
      ));
    }
    for (final s in controller.skills) {
      items.add(_SlashItem(
        name: s.name,
        description: s.description ??
            (s.argumentHint != null ? '${s.argumentHint}' : ''),
        insert: '\$${s.name} ',
        isSkill: true,
      ));
    }
    return items;
  }

  /// Dedicated skill picker so skills are one tap away (no `/` guessing).
  /// 当前协作模式 value(U2 输入框模式按钮):活动会话用现场值,
  /// 草稿用草稿选择。
  String get _currentModeLabel =>
      controller.state?.currentMode ?? controller.draftConfig['mode'] ?? 'build';

  /// 协作模式菜单(U2):与模型面板的模式区同源,选择即时生效。
  void _showModeMenu() {
    final option = controller.prep?.option('mode');
    final options = option != null && option.options.isNotEmpty
        ? [for (final v in option.options) (v.value, v.name)]
        : const [
            ('build', 'build'),
            ('edit', 'edit'),
            ('plan', 'plan'),
            ('yolo', 'yolo')
          ];
    final current =
        controller.state?.currentMode ?? controller.draftConfig['mode'] ?? 'build';
    final sourceGeneration = controller.sourceGeneration;
    final sourceTransport = controller.transport;
    final sourceSessionId = controller.sessionId;
    final sourceState = controller.state;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Padding(
              padding: EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text('协作模式',
                      style: TextStyle(
                          fontSize: 16, fontWeight: FontWeight.w600)))),
          for (final (value, name) in options)
            ListTile(
              dense: true,
              leading: Icon(
                current == value
                    ? Icons.radio_button_checked
                    : Icons.radio_button_off,
                size: 18,
                color: current == value
                    ? EmberColors.of(context).primary
                    : EmberColors.of(context).textFaint,
              ),
              title: Text(name, style: const TextStyle(fontSize: 13)),
              onTap: () {
                Navigator.of(sheetContext).pop();
                if (!controller.isCurrentForSource(sourceGeneration,
                    sourceTransport,
                    sessionId: sourceSessionId)) {
                  return;
                }
                if (sourceSessionId == null || sourceSessionId.isEmpty) {
                  controller.setDraftOption('mode', value);
                } else {
                  controller.run('切换失败', () async {
                    if (!controller.isCurrentForSource(
                        sourceGeneration, sourceTransport,
                        sessionId: sourceSessionId)) {
                      return null;
                    }
                    await sourceTransport.switchCollaborationMode(
                        sourceSessionId, value);
                    if (controller.isCurrentForSource(
                            sourceGeneration, sourceTransport,
                            sessionId: sourceSessionId) &&
                        identical(controller.state, sourceState)) {
                      sourceState?.optimisticPatch({
                        'config': {
                          ...?sourceState.config,
                          'mode': value,
                        },
                      });
                    }
                    return null;
                  });
                }
              },
            ),
        ]),
      ),
    );
  }

  /// "+"面板(U2):斜杠命令 / Skills / 附件,三段合一。
  void _openPlusSheet() {
    final items = _slashItems;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => _PlusSheet(
        slashItems: items,
        loading: controller.skillsLoading,
        onSelect: (text) {
          _inputController.text = text;
          _inputController.selection =
              TextSelection.collapsed(offset: _inputController.text.length);
          Navigator.of(sheetContext).pop();
          setState(() => _showSlash = false);
        },
        onAttach: () {
          Navigator.of(sheetContext).pop();
          controller.pickFiles();
        },
        onRefresh: controller.loadPrep,
      ),
    );
  }

  void _showUsageSheet() {
    final state = controller.state;
    final sessionId = controller.sessionId;
    if (state == null || sessionId == null) return;
    final sourceGeneration = controller.sourceGeneration;
    final transport = controller.transport;
    showModalBottomSheet(
      context: context,
      builder: (context) => _UsageSheet(
        state: state,
        session: widget.session,
        scope: widget.scope,
        sessionId: sessionId,
        isSourceCurrent: () => controller.isCurrentForSource(
          sourceGeneration,
          transport,
          sessionId: sessionId,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = controller.state;
    final body = _content(context, state);
    if (widget.embedded) {
      return Column(
        children: [
          _embeddedHeader(context, state),
          Expanded(child: body),
        ],
      );
    }
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.title,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 15)),
            if (state != null)
              AnimatedBuilder(
                animation: state.controlListenable,
                builder: (context, _) => Text(
                  [
                    if (state.phase.isNotEmpty) state.phase,
                    state.currentModel,
                    if (state.currentThought.isNotEmpty) state.currentThought,
                  ].where((s) => s.isNotEmpty).join(' · '),
                  style: TextStyle(
                      fontSize: 11, color: EmberColors.of(context).textFaint),
                ),
              ),
          ],
        ),
      ),
      body: body,
    );
  }

  // ------------------------------------------------- embedded header

  /// 对话 Tab 顶栏(桌面客户端单行结构):设备胶囊 | 会话标题 | 状态
  /// 胶囊 | 会话列表。会话设置(模型/思考/模式)在输入区卡片,无溢出
  /// 菜单;状态胶囊随订阅实时跟进(phase 帧只在 state 上通知)。
  Widget _embeddedHeader(BuildContext context, ConversationState? state) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(EmberSpacing.page, EmberSpacing.gapS,
          EmberSpacing.page, EmberSpacing.gapS),
      child: Row(
        children: [
          if (widget.headerLeading != null) widget.headerLeading!,
          const SizedBox(width: EmberSpacing.gapM),
          Expanded(child: _embeddedTitle(context)),
          // 状态胶囊随订阅实时跟进:phase 帧只在 state 上通知,页面
          // build 不会因此重跑。
          if (state == null)
            _sessionStatusChip(context, state)
          else
            AnimatedBuilder(
              animation: state.controlListenable,
              builder: (context, _) => _sessionStatusChip(context, state),
            ),
          if (widget.onOpenDrawer != null)
            IconButton(
              icon: const Icon(Icons.menu, size: 22),
              tooltip: '会话列表',
              onPressed: widget.onOpenDrawer,
            ),
        ],
      ),
    );
  }

  /// 会话流工作状态胶囊(UX 反馈:文字+图标)。运行中 = 旋转箭头 +
  /// 「工作中」(primary),空闲 = 空心圆 + 「空闲」(textFaint);draft
  /// 无订阅时同样按空闲处理。发送已接受、订阅行未到的乐观窗口
  /// ([ChatController.turnPending])同样按工作中显示。
  Widget _sessionStatusChip(BuildContext context, ConversationState? state) {
    final colors = EmberColors.of(context);
    final running =
        controller.turnPending || (state != null && state.isRunning);
    final color = running ? colors.primary : colors.textFaint;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(EmberRadius.avatar),
        border: Border.all(
            color: running
                ? colors.primary.withValues(alpha: 0.4)
                : colors.hairline),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(running ? Icons.motion_photos_on : Icons.radio_button_unchecked,
            size: 12, color: color),
        const SizedBox(width: 4),
        Text(running ? '工作中' : '空闲',
            style: TextStyle(
                fontSize: EmberType.caption,
                fontWeight: FontWeight.w600,
                color: color)),
      ]),
    );
  }

  /// 会话名:null/空显示「新会话」;经 listenable 跟进桌面端生成的标题。
  /// 标题下方小字显示所属工作区(UX 反馈:第一行 = 标题 + 工作区)。
  Widget _embeddedTitle(BuildContext context) {
    final colors = EmberColors.of(context);
    final listenable = widget.headerTitle;
    final ws = widget.headerWorkspace ?? '';
    TextStyle titleStyle() => TextStyle(
        fontSize: EmberType.body,
        fontWeight: FontWeight.w600,
        color: colors.textSolid);
    Widget titleWidget;
    if (listenable == null) {
      titleWidget = Text(widget.title,
          overflow: TextOverflow.ellipsis, style: titleStyle());
    } else {
      titleWidget = ValueListenableBuilder<String?>(
        valueListenable: listenable,
        builder: (context, title, _) => Text(
          title == null || title.isEmpty ? '新会话' : title,
          overflow: TextOverflow.ellipsis,
          style: titleStyle(),
        ),
      );
    }
    if (ws.isEmpty) return titleWidget;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        titleWidget,
        Text(ws,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                fontSize: EmberType.caption, color: colors.textFaint)),
      ],
    );
  }

  /// 消息流 + 横幅组 + 输入区。embedded(对话 Tab 内嵌)直接输出,
  /// 不包 Scaffold/AppBar 外壳。
  Widget _content(BuildContext context, ConversationState? state) => Column(
        children: [
          if (controller.error != null)
            Material(
              color: EmberColors.of(context).err.withValues(alpha: 0.15),
              child: ListTile(
                dense: true,
                title: Text('订阅失败: ${controller.error}',
                    style: const TextStyle(fontSize: 12)),
                trailing: TextButton(
                    onPressed: controller.subscribe, child: const Text('重试')),
              ),
            ),
          if (state != null)
            AnimatedBuilder(
              animation: state.usageListenable,
              builder: (context, _) => _ContextUsageBar(state: state),
            ),
          if (state != null)
            AnimatedBuilder(
              animation: state.configListenable,
              builder: (context, _) => _ModeBanner(mode: state.currentMode),
            ),
          Expanded(
            child: Stack(
              children: [
                Positioned.fill(
                  child: state == null
                ? Center(
                    child: controller.sessionId == null
                        ? Text('输入消息开始新会话',
                            style: TextStyle(
                                color: EmberColors.of(context).textFaint))
                        : const CircularProgressIndicator(),
                  )
                : !state.ready
                    ? const Center(child: CircularProgressIndicator())
                    : AnimatedBuilder(
                        animation: Listenable.merge([
                          state.rowsListenable,
                          state.controlListenable,
                        ]),
                        builder: (context, _) {
                          final groups = cachedGroupRows(state);
                          // Optimistic echoes render newest-first at the
                          // bottom (reverse index 0..n-1).
                          final echoCount = controller.echoes.length;
                          final itemCount = groups.length +
                              echoCount +
                              (state.canLoadOlder ? 1 : 0);
                          if (groups.isEmpty &&
                              echoCount == 0 &&
                              !state.canLoadOlder) {
                            return Center(
                                child: Text('暂无消息',
                                    style: TextStyle(
                                        color: EmberColors.of(context)
                                            .textFaint)));
                          }
                          // Reverse list: index 0 renders at the bottom, so
                          // offset 0 IS the newest message — a freshly
                          // opened chat sits on the latest turn by
                          // construction, and prepended history never
                          // shifts the viewport.
                          final sourceGeneration = controller.sourceGeneration;
                          final sourceTransport = controller.transport;
                          final sourceSessionId =
                              controller.sessionId ?? '';
                          return ListView.builder(
                            controller: _scrollController,
                            reverse: true,
                            padding: const EdgeInsets.fromLTRB(14, 14, 14, 8),
                            itemCount: itemCount,
                            itemBuilder: (context, index) {
                              if (index < echoCount) {
                                final e =
                                    controller.echoes[echoCount - 1 - index];
                                // Same bubble as a confirmed user row, so
                                // retiring the echo (real row takes over)
                                // is visually seamless. 已发送 + 轮次在途
                                // → 乐观升为「处理中」(见 turnPending)。
                                final badge =
                                    e['status'] == 'sent' &&
                                            controller.turnPending
                                        ? 'processing'
                                        : '${e['status']}';
                                return _UserBubble(
                                  row: {
                                    'kind': 'userInput',
                                    'text': e['text'],
                                    '_zflowTs': e['ts'],
                                    if (e['attachments'] != null)
                                      'attachments': e['attachments'],
                                  },
                                  transport: sourceTransport,
                                  sessionId: sourceSessionId,
                                  isSourceCurrent: () =>
                                      controller.isCurrentForSource(
                                        sourceGeneration,
                                        sourceTransport,
                                        sessionId: sourceSessionId,
                                      ),
                                  badge: badge,
                                  onRetry: e['status'] == 'failed'
                                      ? () => controller.retryEcho(e,
                                          askHeldQueueDisposition:
                                              _askHeldQueueDisposition)
                                      : null,
                                );
                              }
                              final mi = index - echoCount;
                              if (state.canLoadOlder && mi == groups.length) {
                                return Center(
                                  child: TextButton.icon(
                                    onPressed: controller.loadingOlder
                                        ? null
                                        : controller.loadOlder,
                                    icon: controller.loadingOlder
                                        ? const SizedBox(
                                            width: 12,
                                            height: 12,
                                            child: CircularProgressIndicator(
                                                strokeWidth: 1.5),
                                          )
                                        : const Icon(Icons.history, size: 14),
                                    label: const Text('加载更早消息',
                                        style: TextStyle(fontSize: 12)),
                                  ),
                                );
                              }
                              final group = groups[groups.length - 1 - mi];
                              return _TurnGroupWidget(
                                key: ValueKey(
                                    'g${group.first['rowId'] ?? group.length}'),
                                rows: group,
                                transport: sourceTransport,
                                sessionId: sourceSessionId,
                                onAction: controller.run,
                                isSourceCurrent: () =>
                                    controller.isCurrentForSource(
                                      sourceGeneration,
                                      sourceTransport,
                                      sessionId: sourceSessionId,
                                    ),
                                beginFileChangesOperation:
                                    controller.beginFileChangesOperation,
                                isFileChangesOperationCurrent: (generation) =>
                                    generation ==
                                        controller.fileChangesGeneration &&
                                    controller.isCurrentForSource(
                                      sourceGeneration,
                                      sourceTransport,
                                      sessionId: sourceSessionId,
                                    ),
                                state: state,
                              );
                            },
                          );
                        },
                      ),
                ),
                // 滚到底浮钮(桌面同款):未钉底时出现。
                Positioned(
                  right: 16,
                  bottom: 16,
                  child: ValueListenableBuilder<bool>(
                    valueListenable: _showJumpToBottom,
                    builder: (context, visible, _) => visible
                        ? InkWell(
                            onTap: _jumpToBottom,
                            borderRadius: BorderRadius.circular(24),
                            child: Container(
                              width: 40,
                              height: 40,
                              decoration: BoxDecoration(
                                color: EmberColors.of(context)
                                    .card
                                    .withValues(alpha: 0.92),
                                shape: BoxShape.circle,
                                border: Border.all(
                                    color:
                                        EmberColors.of(context).hairline),
                              ),
                              child: Icon(Icons.arrow_downward,
                                  size: 20,
                                  color: EmberColors.of(context).textMuted),
                            ),
                          )
                        : const SizedBox.shrink(),
                  ),
                ),
              ],
            ),
          ),
          _ReconnectBanner(bridge: controller.transport.session),
          if (state != null)
            AnimatedBuilder(
              animation: Listenable.merge([
                state.controlListenable,
                state.backgroundListenable,
                state.queueListenable,
                state.interactionListenable,
              ]),
              builder: (context, _) => Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _GoalBanner(state: state),
                  _BackgroundWorksBar(state: state),
                  _QueueBar(state: state, transport: controller.transport),
                  _PendingInteractions(
                      state: state, transport: controller.transport),
                ],
              ),
            ),
          if (_showSlash)
            _SlashCommandBar(
              query: _inputController.text,
              items: _slashItems,
              onSelect: (item) {
                if (item.name == 'compact') {
                  _inputController.text = '/compact';
                  _send();
                } else {
                  _inputController.text = item.insert;
                  _inputController.selection = TextSelection.collapsed(
                      offset: _inputController.text.length);
                  setState(() => _showSlash = false);
                }
              },
            ),
          if (controller.progress != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
              child: Row(
                children: [
                  const SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(strokeWidth: 1.5),
                  ),
                  const SizedBox(width: 8),
                  Text(controller.progress!,
                      style: TextStyle(
                          fontSize: 11,
                          color: EmberColors.of(context).textMuted)),
                ],
              ),
            ),
          if (controller.pendingFiles.isNotEmpty)
            _PendingFilesBar(
              files: controller.pendingFiles,
              uploadProgress: controller.uploadProgress,
              onRemove: controller.removePendingFileAt,
            ),
          if (state != null && controller.sessionId != null)
            AnimatedBuilder(
              animation: Listenable.merge([
                state.rowsListenable,
                state.backgroundListenable,
              ]),
              builder: (context, _) {
                final handleSourceGeneration = controller.sourceGeneration;
                final handleTransport = controller.transport;
                final handleSessionId = controller.sessionId;
                final handleState = state;
                return InsightsHandle(
                  state: state,
                  transport: handleTransport,
                  sessionId: handleSessionId!,
                  isSourceCurrent: () =>
                      controller.isCurrentForSource(handleSourceGeneration,
                          handleTransport,
                          sessionId: handleSessionId) &&
                      identical(controller.state, handleState),
                );
              },
            ),
          // 模式按钮随会话 state 跟进(optimisticPatch/宿主确认都要
          // 重建输入栏;此前 InputBar 不在 state 监听内,远端已切、
          // 本地按钮不变)。
          AnimatedBuilder(
            animation: state == null
                ? const AlwaysStoppedAnimation(null)
                : Listenable.merge([
                    state.configListenable,
                    state.controlListenable,
                  ]),
            builder: (context, _) => _InputBar(
              controller: _inputController,
              sending: controller.sending,
              running: controller.turnPending ||
                  (state?.isRunning ?? false),
              queueCount: controller.echoes.length,
              modeValue: _currentModeLabel,
              onPickMode: _showModeMenu,
              onSend: _send,
              onStop: controller.stop,
              onPlusMenu: _openPlusSheet,
              onPickModel: _showModelSheet,
              onPickThought: _showThoughtSheet,
              onPickUsage:
                  controller.sessionId == null ? null : _showUsageSheet,
            ),
          ),
        ],
      );
}

// ---------------------------------------------------------------- rows

/// plan/yolo 模式的流内状态条(spec §7.1:权限级提示,模式切回 build
/// 即消失)。计划橙条提示只读需确认,YOLO 红条警示免确认风险。
