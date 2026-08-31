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

class _PendingFile {
  final String fileName;
  final String mime;
  final Uint8List bytes;

  _PendingFile(this.fileName, this.mime, this.bytes);
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
    _inputController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    // Reverse list: offset 0 is the newest (bottom) message.
    _stickToBottom = _scrollController.position.pixels <= 40;
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

  /// Opens an auxiliary (side) chat attached to the current session
  /// (`createSelectionSideSession`) in a fresh ChatPage.
  Future<void> _openSideChat() async {
    final sideId = await controller.createSideSession();
    if (sideId == null || !mounted) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ChatPage(
          session: widget.session,
          scope: widget.scope,
          workspaceKey: widget.workspaceKey,
          sessionId: sideId,
          title: '辅助对话',
        ),
      ),
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
      }, onError: (_, __) {
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
        actions: [
          if (state != null)
            AnimatedBuilder(
              animation: state.controlListenable,
              builder: (context, _) => state.isRunning
                  ? IconButton(
                      icon: Icon(Icons.stop_circle_outlined,
                          color: EmberColors.of(context).err),
                      tooltip: '停止',
                      onPressed: controller.stop,
                    )
                  : const SizedBox.shrink(),
            ),
          if (controller.sessionId != null)
            IconButton(
              icon: const Icon(Icons.quickreply_outlined, size: 20),
              tooltip: '辅助对话',
              onPressed: _openSideChat,
            ),
          IconButton(
            icon: const Icon(Icons.tune, size: 20),
            tooltip: '模型',
            onPressed: _showModelSheet,
          ),
          // 常驻(草稿态禁用会话级条目):出现/消失会导致右侧布局跳动,
          // 把会话列表按钮挤出屏幕。
          PopupMenuButton<String>(
            onSelected:
                controller.sessionId == null ? null : _handleOverflowAction,
            itemBuilder: (context) =>
                _overflowMenuItems(includeSideChat: false),
          ),
        ],
      ),
      body: body,
    );
  }

  // ------------------------------------------------- header overflow

  /// 顶栏溢出菜单:非 embedded(Scaffold)与 embedded 两种布局共用的
  /// 动作集合与分发;布局差异保留(Scaffold 的辅助对话是独立图标,
  /// 不进菜单)。会话级条目草稿态禁用而非隐藏,避免右侧布局跳动。
  List<PopupMenuEntry<String>> _overflowMenuItems(
          {required bool includeSideChat}) =>
      [
        if (includeSideChat)
          PopupMenuItem(
              value: 'side',
              enabled: controller.sessionId != null,
              child: const Text('辅助对话')),
        PopupMenuItem(
            value: 'compact',
            enabled: controller.sessionId != null,
            child: const Text('压缩上下文 (compact)')),
        PopupMenuItem(
            value: 'usage',
            enabled: controller.sessionId != null,
            child: const Text('用量统计')),
      ];

  void _handleOverflowAction(String action) {
    switch (action) {
      case 'side':
        _openSideChat();
      case 'compact':
        controller.compact();
      case 'usage':
        _showUsageSheet();
    }
  }

  // ------------------------------------------------- embedded header

  /// 对话 Tab 顶栏(spec §7.1:设备胶囊 | 会话名 | 停止 + 模型 pill +
  /// 溢出菜单 | 会话抽屉)。胶囊与抽屉回调由壳注入;会话态驱动的停止/
  /// pill/溢出菜单在订阅通知处刷新。
  Widget _embeddedHeader(BuildContext context, ConversationState? state) {
    final colors = EmberColors.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(EmberSpacing.page, EmberSpacing.gapS,
          EmberSpacing.page, EmberSpacing.gapS),
      child: Column(children: [
        // 第一行:设备胶囊 | 会话标题 + 所属工作区 | 会话列表(☰ 靠
        // 第一行最右,第二行留整行给状态与模型)。
        Row(
          children: [
            if (widget.headerLeading != null) widget.headerLeading!,
            const SizedBox(width: EmberSpacing.gapM),
            Expanded(child: _embeddedTitle(context)),
            if (widget.onOpenDrawer != null)
              IconButton(
                icon: const Icon(Icons.menu, size: 22),
                tooltip: '会话列表',
                onPressed: widget.onOpenDrawer,
              ),
          ],
        ),
        // 第二行:状态胶囊(左)| 模型 pill + 溢出(顺移到行尾,原 ☰
        // 的位置)。操作簇放 Expanded+Align:占满剩余宽度、按自然宽度
        // 右对齐——pill 平时完整显示,只在放不下时才经内部省略收缩
        // (此前 Spacer+Flexible 对半分剩余空间,长模型名把 pill 挤成
        // 省略号,真机表现为「模型名彻底丢了」)。
        Row(
          children: [
            // 胶囊随订阅实时跟进:phase 帧只在 state 上通知,页面
            // build 不会因此重跑(真机:轮次结束后仍显示「工作中」)。
            if (state == null)
              _sessionStatusChip(context, state)
            else
              AnimatedBuilder(
                animation: state.controlListenable,
                builder: (context, _) => _sessionStatusChip(context, state),
              ),
            Expanded(
              child: Align(
                alignment: Alignment.centerRight,
                child: _headerActions(context, state, colors),
              ),
            ),
          ],
        ),
      ]),
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

  /// 停止(isRunning 才出现)+ 模型 pill + 溢出菜单(辅助对话/压缩/
  /// 用量/计划,原 AppBar 入口)。state 为 null(draft 未订阅)时静态
  /// 渲染一次,订阅建立后由 AnimatedBuilder 跟进。
  Widget _headerActions(
      BuildContext context, ConversationState? state, EmberColors colors) {
    Widget build() {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (state != null && state.isRunning && controller.sessionId != null)
            IconButton(
              icon:
                  Icon(Icons.stop_circle_outlined, size: 22, color: colors.err),
              tooltip: '停止',
              onPressed: controller.stop,
            ),
          Flexible(child: _modelPill(context, state)),
          // 常驻(草稿态禁用会话级条目),避免会话激活时按钮出现把
          // 右侧会话列表入口挤出屏幕。
          PopupMenuButton<String>(
            icon: Icon(Icons.more_vert, size: 20, color: colors.textMuted),
            tooltip: '更多',
            onSelected:
                controller.sessionId == null ? null : _handleOverflowAction,
            itemBuilder: (context) => _overflowMenuItems(includeSideChat: true),
          ),
        ],
      );
    }

    if (state == null) return build();
    return AnimatedBuilder(
      animation: Listenable.merge([
        state.controlListenable,
        state.configListenable,
      ]),
      builder: (context, _) => build(),
    );
  }

  /// 模型 pill:`模型名 | 强度档名`(U2:模式选择移到输入框左侧,
  /// 顶栏只做模型设置)。显示名优先取 prepareWorkspace 模型/思考选项
  /// 里当前值的展示名,回退会话 config 的裸值;点击展开模型面板。
  Widget _modelPill(BuildContext context, ConversationState? state) {
    final colors = EmberColors.of(context);
    final model = _pillModelLabel(state);
    final thought = _pillThoughtLabel(state);
    return InkWell(
      borderRadius: BorderRadius.circular(EmberRadius.control),
      onTap: _showModelSheet,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: colors.card,
          borderRadius: BorderRadius.circular(EmberRadius.control),
          border: Border.all(color: colors.hairline),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 长模型名在约束内省略(思考档段保留);无约束时自然宽度。
            Flexible(
              child: Text(model,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: EmberType.body,
                      fontWeight: FontWeight.w600,
                      color: colors.textSolid)),
            ),
            if (thought != null) ...[
              const SizedBox(width: 6),
              Text('|',
                  style: TextStyle(
                      fontSize: EmberType.caption, color: colors.textFaint)),
              const SizedBox(width: 6),
              Text(thought,
                  style: TextStyle(
                      fontSize: EmberType.body, color: colors.textMuted)),
            ],
          ],
        ),
      ),
    );
  }

  String? _optionLabel(ConfigOption? opt, String value) {
    for (final v in opt?.options ?? const <ConfigOptionValue>[]) {
      if (v.value == value) return v.name;
    }
    return null;
  }

  /// pill 的模型显示名。draft 用草稿选择/准备默认值;活动会话用
  /// provider/model 现场值(展示名匹配不上时退裸模型名)。
  String _pillModelLabel(ConversationState? state) {
    final opt = controller.prep?.option('model');
    final sessionId = controller.sessionId;
    final isDraft = state == null || sessionId == null || sessionId.isEmpty;
    String value;
    if (isDraft) {
      value =
          controller.draftConfig['model'] ?? '${opt?.currentValue ?? ''}';
    } else {
      final config = state.config ?? const {};
      value = '${config['provider'] ?? ''}/${config['model'] ?? ''}';
      if ('${config['model'] ?? ''}'.isEmpty) {
        value = controller.draftConfig['model'] ?? '${opt?.currentValue ?? ''}';
      }
    }
    if (value.isEmpty) return '模型';
    return _optionLabel(opt, value) ??
        (value.contains('/')
            ? value.substring(value.lastIndexOf('/') + 1)
            : value);
  }

  /// pill 的思考强度档名;无值(draft 未选且准备数据未到)时不显示该段。
  String? _pillThoughtLabel(ConversationState? state) {
    final opt = controller.prep?.option('thought_level');
    final sessionId = controller.sessionId;
    final isDraft = state == null || sessionId == null || sessionId.isEmpty;
    final value = isDraft
        ? (controller.draftConfig['thought'] ?? '${opt?.currentValue ?? ''}')
        : (state.currentThought.isNotEmpty
            ? state.currentThought
            : '${opt?.currentValue ?? ''}');
    if (value.isEmpty) return null;
    return _optionLabel(opt, value) ?? value;
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
              onSend: _send,
              onPlusMenu: _openPlusSheet,
              modeLabel: _currentModeLabel,
              onPickMode: _showModeMenu,
            ),
          ),
        ],
      );
}

// ---------------------------------------------------------------- rows

/// plan/yolo 模式的流内状态条(spec §7.1:权限级提示,模式切回 build
/// 即消失)。计划橙条提示只读需确认,YOLO 红条警示免确认风险。
