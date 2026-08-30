import 'dart:async';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../protocol/channel_client.dart';
import '../protocol/conversation.dart';
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

/// 由模型 option value 解析 (provider, model)。provider 必须用宿主
/// 显式给的 modelProviderId——value 的 "builtin:x/Model" 前缀不是
/// 注册表 id,直接拆分会得到 "provider not in registry"。
(String, String) providerModelOf(WorkspacePrep? prep, String value) {
  final model =
      value.contains('/') ? value.substring(value.lastIndexOf('/') + 1) : value;
  for (final v in prep?.option('model')?.options ?? const <ConfigOptionValue>[]) {
    if (v.value == value) {
      final fallbackProvider =
          value.contains('/') ? value.substring(0, value.lastIndexOf('/')) : value;
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
  final void Function(String sessionId, String title, int epoch)?
      onSessionInfo;

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

class _ChatPageState extends State<ChatPage> {
  late final ConversationTransport _transport;
  ConversationSubscription? _subscription;
  final _inputController = TextEditingController();
  final _scrollController = ScrollController();
  String? _sessionId;
  String? _error;
  bool _sending = false;

  /// Optimistic echoes for just-sent messages: shown the moment the user
  /// hits send, retired once the server's userInput row arrives (see
  /// [removeEchoedTexts]). Status evolves sending → sent; a failed echo
  /// stays for tap-to-retry and is never auto-retired. Never enters
  /// protocol rows/revisions.
  final List<Map<String, dynamic>> _echoes = [];

  /// 发送已被宿主接受、但订阅侧行数据尚未到达的窗口。此间最新的已发送
  /// 气泡与状态胶囊按「处理中/工作中」乐观显示——工作区桥降级冻结时,
  /// 订阅行可能数十秒后才整体冲刷,反馈不能干等(真机实测)。
  bool _turnPending = false;

  void _dedupeEchoes() {
    final state = _state;
    if (state == null) return;
    if (_turnPending &&
        (state.rows.isNotEmpty ||
            (state.phase.isNotEmpty && state.phase != 'draft'))) {
      // 轮次已在订阅侧物化(行到达或相位离开 draft),乐观窗口结束。
      setState(() => _turnPending = false);
    }
    if (_echoes.isEmpty) return;
    final kept = removeEchoedTexts(_echoes, state.rows);
    if (kept.length != _echoes.length) {
      setState(() => _echoes
        ..clear()
        ..addAll(kept));
    }
  }
  bool _loadingOlder = false;
  bool _showSlash = false;
  String? _progress;
  final List<_PendingFile> _pendingFiles = [];
  double? _uploadProgress;
  WorkspacePrep? _prep;
  List<SkillEntry> _skills = [];
  bool _skillsLoading = false;

  /// Live sessions-index watch driving [ChatPage.onSessionInfo]; only
  /// mounted in embedded mode. The desktop generates/renames titles
  /// asynchronously, so the host header needs pushes when it changes.
  SessionsIndexSubscription? _titleSub;
  String? _pushedSessionId;
  String? _pushedTitle;

  /// Draft-mode (no session yet) model/mode/thought selection, passed as
  /// `config` to createSession on first send.
  final Map<String, String> _draftConfig = {};

  /// Whether to keep the view pinned to the newest message. Starts true so
  /// opening the chat lands at the bottom; the user scrolling up unpins it.
  bool _stickToBottom = true;
  bool _scrollCallbackScheduled = false;
  bool _scrollAnimationInFlight = false;
  bool _prependScrollPending = false;
  Map<String, dynamic>? _prependTailRow;

  ConversationState? get _state => _subscription?.state;

  @override
  void initState() {
    super.initState();
    _sessionId = widget.sessionId;
    _transport = widget.session.conversation(widget.scope);
    _scrollController.addListener(_onScroll);
    _loadDraftPrefs();
    if (_sessionId != null) {
      _subscribe();
    }
    _loadPrep();
    if (widget.onSessionInfo != null) {
      _watchSessionTitle();
    }
    _inputController.addListener(() {
      final text = _inputController.text;
      final show = (text.startsWith('/') || text.startsWith('\$')) &&
          !text.contains(' ');
      if (show != _showSlash && mounted) {
        setState(() => _showSlash = show);
      }
    });
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    // Reverse list: offset 0 is the newest (bottom) message.
    _stickToBottom = _scrollController.position.pixels <= 40;
  }

  /// prepareWorkspace 最近一次成功拉取时刻(5s 新鲜度窗:窗内重复打开
  /// 模型面板不再发请求,连开即开)。
  DateTime? _prepFetchedAt;
  int _prepGeneration = 0;

  /// 只刷 prepareWorkspace(模型/思考档/模式可选项的实时来源)。
  /// 必须 refresh: true——传输层有会话级缓存,不带参数会直接返回缓存
  /// (模型增删后旧缓存照旧,面板"刷新"实际没上线)。
  Future<void> _refreshPrep() async {
    final generation = ++_prepGeneration;
    final transportGeneration = _transport.prepGeneration;
    try {
      final prep = await _transport.prepareWorkspace(refresh: true);
      if (mounted &&
          generation == _prepGeneration &&
          transportGeneration == _transport.prepGeneration) {
        setState(() {
          _prep = prep;
          _prepFetchedAt = DateTime.now();
        });
        _validateDraftAgainstPrep();
      }
    } catch (_) {}
  }

  /// 面板打开时的取数:新鲜(≤5s)直接用,否则强制拉一次;失败退缓存。
  Future<WorkspacePrep?> _fetchPrepForSheet() async {
    final fetchedAt = _prepFetchedAt;
    if (fetchedAt != null &&
        DateTime.now().difference(fetchedAt) < const Duration(seconds: 5)) {
      return _prep;
    }
    await _refreshPrep();
    return _prep;
  }

  Future<void> _loadPrep() async {
    await _refreshPrep();
    if (mounted) setState(() => _skillsLoading = true);
    try {
      final skills = await _transport.skills();
      if (mounted) setState(() => _skills = skills);
    } catch (_) {
      if (mounted) setState(() => _skills = const []);
    } finally {
      if (mounted) setState(() => _skillsLoading = false);
    }
  }

  @override
  void dispose() {
    _prepGeneration++;
    _subscription?.dispose();
    final titleSub = _titleSub;
    _titleSub = null;
    if (titleSub != null) {
      titleSub.state.removeListener(_pushSessionInfo);
      titleSub.dispose();
    }
    _inputController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _watchSessionTitle() async {
    try {
      final sub = await _transport.subscribeSessionsIndex();
      if (!mounted) {
        await sub.dispose();
        return;
      }
      _titleSub = sub;
      sub.state.addListener(_pushSessionInfo);
      _pushSessionInfo();
    } catch (_) {
      // Title is header cosmetics only — on failure keep the placeholder.
    }
  }

  /// 推送 (sessionId, title, epoch) 给宿主:会话 id 只在变化时推一次
  /// (draft 采纳后宿主立即回写,标题未生成时带空串);标题有值且变化时
  /// 再推。epoch 为宿主重建代数,宿主据此丢弃旧实例的迟到推送。
  void _pushSessionInfo() {
    final sub = _titleSub;
    final sessionId = _sessionId;
    if (sub == null || sessionId == null || !mounted) return;
    final title = sub.state.sessions[sessionId]?.title ?? '';
    final idNew = sessionId != _pushedSessionId;
    final titleNew = title.isNotEmpty && title != _pushedTitle;
    if (!idNew && !titleNew) return;
    _pushedSessionId = sessionId;
    if (titleNew) _pushedTitle = title;
    widget.onSessionInfo!(sessionId, title, widget.sessionEpoch);
  }

  /// Draft 首条消息创建会话后的采纳。索引推送(含桌面端生成的标题)可能
  /// 先于 createSession 返回到达——监听器此刻读到的 _sessionId 还是
  /// null,之后不会再触发;采纳后必须补跑一次推送。
  void _adoptCreatedSession(String sessionId) {
    _sessionId = sessionId;
    _pushSessionInfo();
  }

  Future<void> _subscribe() async {
    final sessionId = _sessionId;
    if (sessionId == null) return;
    try {
      final sw = Stopwatch()..start();
      final sub = await _transport
          .subscribe(sessionId)
          .timeout(const Duration(seconds: 60));
      final diag = diagLogEnabled.value;
      if (diag) {
        debugPrint('[chat] subscribe ack in ${sw.elapsedMilliseconds}ms '
            'rows=${sub.state.rows.length} '
            'thought=${sub.state.currentThought} cfg=${sub.state.config}');
      }
      var deltaCount = 0;
      sub.state.addListener(() {
        deltaCount++;
        if (diag && deltaCount <= 25) {
          debugPrint('[chat] delta#$deltaCount +${sw.elapsedMilliseconds}ms '
              'rows=${sub.state.rows.length} '
              'running=${sub.state.isRunning} phase=${sub.state.phase}');
        }
      });
      if (!mounted) {
        await sub.dispose();
        return;
      }
      setState(() {
        _subscription = sub;
        _error = null;
      });
      // Reverse list: opening lands on the newest message by construction
      // (offset 0 = bottom); the listener below only follows NEW deltas
      // while the user stays pinned near the bottom.
      sub.state.addListener(_scrollToBottom);
      sub.state.addListener(_dedupeEchoes);
      // The server snapshot is a tail window (can be as few as 3 rows).
      // The official client shows the full history immediately, so
      // auto-load the missing older rows once on open.
      if (sub.state.canLoadOlder) {
        await _loadOlder();
      }
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  void _scrollToBottom() {
    if (_scrollCallbackScheduled) return;
    _scrollCallbackScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollCallbackScheduled = false;
      if (!mounted) return;
      final prependTail = _prependScrollPending ? _prependTailRow : null;
      _prependScrollPending = false;
      _prependTailRow = null;
      if (!_scrollController.hasClients) return;
      if (prependTail != null) {
        final rows = _state?.rows;
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
        _scrollAnimationInFlight = false;
      }, onError: (_, __) {
        _scrollAnimationInFlight = false;
      });
    });
  }

  void _toast(String message) {
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    }
  }

  Future<void> _run(String errorPrefix, Future<dynamic> Function() run) async {
    try {
      final res = await run();
      if (res is Map &&
          res['status'] != null &&
          res['status'] != 'accepted' &&
          res['status'] != 'noop') {
        _toast('$errorPrefix: ${res['reasonCode'] ?? res['status']}');
      }
    } catch (e) {
      _toast('$errorPrefix: $e');
    }
  }

  /// Opens an auxiliary (side) chat attached to the current session
  /// (`createSelectionSideSession`) in a fresh ChatPage.
  Future<void> _openSideChat() async {
    final sessionId = _sessionId;
    if (sessionId == null) return;
    try {
      final sideId = await _transport.createSelectionSideSession(sessionId);
      if (!mounted) return;
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
    } catch (e) {
      _toast('打开辅助对话失败: $e');
    }
  }

  // ------------------------------------------------------------ sending

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

  Future<void> _pickFiles() async {
    try {
      final files = await FilePicker.pickFiles();
      final picked = <_PendingFile>[];
      for (final file in files) {
        final bytes = await file.readAsBytes();
        picked.add(_PendingFile(file.name, _guessMime(file.name), bytes));
      }
      if (picked.isEmpty) return;
      setState(() => _pendingFiles.addAll(picked));
    } catch (e) {
      _toast('选择文件失败: $e');
    }
  }

  Future<List<Map<String, dynamic>>> _uploadFiles(
      Map<String, dynamic> echo,
      List<_PendingFile> files,
      String sessionId) async {
    final total = files.length;
    var completed = 0;
    while (files.isNotEmpty) {
      final file = files.first;
      final descriptor = await _transport.attachmentPut(
        sessionId,
        fileName: file.fileName,
        mime: file.mime,
        bytes: file.bytes,
        onProgress: (p) {
          if (!mounted) return;
          setState(() => _uploadProgress = (completed + p) / total);
        },
      );
      files.removeAt(0);
      completed++;
      final existing = (echo['attachments'] as List?)
              ?.whereType<Map>()
              .map((item) => item.cast<String, dynamic>())
              .toList() ??
          <Map<String, dynamic>>[];
      existing.add(descriptor);
      echo['attachments'] = existing;
    }
    return (echo['attachments'] as List?)
            ?.whereType<Map>()
            .map((item) => item.cast<String, dynamic>())
            .toList() ??
        <Map<String, dynamic>>[];
  }

  Future<void> _send() async {
    final text = _inputController.text.trim();
    if ((text.isEmpty && _pendingFiles.isEmpty) || _sending) return;

    if (text.startsWith('/goal ') && _pendingFiles.isNotEmpty) {
      _toast('目标命令不支持附件');
      return;
    }

    // Slash commands (mirrors the web composer).
    if (text == '/compact' || text.startsWith('/compact ')) {
      _inputController.clear();
      setState(() => _showSlash = false);
      await _run('压缩失败', () => _transport.compact(_requireSession()));
      return;
    }
    if (text == '/goal pause') {
      _inputController.clear();
      setState(() => _showSlash = false);
      await _run('暂停目标失败',
          () => _transport.pauseGoal(_requireSession()));
      return;
    }
    if (text == '/goal resume') {
      _inputController.clear();
      setState(() => _showSlash = false);
      await _run('恢复目标失败',
          () => _transport.resumeGoal(_requireSession()));
      return;
    }

    // held-queue confirmation: when inputRouting is `choice` the user
    // picks whether to clear the held queue or keep it. Asked BEFORE the
    // echo goes up so cancelling leaves nothing on screen.
    String? heldDisposition;
    final state = _state;
    if (state != null &&
        state.inputRoutingMode == 'choice' &&
        state.queueItems.isNotEmpty) {
      heldDisposition = await _askHeldQueueDisposition();
      if (heldDisposition == null) return; // cancelled
    }

    // Echo goes up the moment the user hits send (WeChat-style): the
    // message is part of the stream from the start and only its delivery
    // badge evolves — sending → sent → (processing once the turn runs).
    // `files` move into the echo so a failed send keeps them for retry.
    final echo = <String, dynamic>{
      'text': text,
      'ts': DateTime.now().millisecondsSinceEpoch,
      'status': 'sending',
      'attachments': null,
      'files': List<_PendingFile>.from(_pendingFiles),
    };
    setState(() {
      _echoes.add(echo);
      _inputController.clear();
      _pendingFiles.clear();
      _sending = true;
      _uploadProgress = null;
      _showSlash = false;
      _progress = null;
    });
    _scrollToBottom();
    await _deliverEcho(echo, heldDisposition: heldDisposition);
  }

  /// Sends (or re-sends) one echo's message and drives its status:
  /// `sending` → `sent` on an accepted ack, `failed` (+reason) on a
  /// rejection/timeout/error. Handles both the fresh-send path and the
  /// tap-to-retry path (including re-creating a session in draft mode).
  Future<void> _deliverEcho(
    Map<String, dynamic> echo, {
    String? heldDisposition,
  }) async {
    void mark(String status, [String? error]) {
      if (!mounted) return;
      if (diagLogEnabled.value) {
        debugPrint('[chat] echo → $status${error == null ? '' : ' ($error)'}');
      }
      setState(() {
        echo['status'] = status;
        if (error != null) echo['error'] = error;
      });
    }

    try {
      var sessionId = _sessionId;
      if (sessionId == null) {
        // 1) create the session (can take a while when the runtime warms).
        // 宿主 createSession schema(.strict())没有 firstInput/attachments
        // 字段——早期版本把首条文本塞进 firstInput,被宿主静默剥离,文本
        // 从未送达(表现为新会话首条大概率收不到回复)。create 只建会话
        // 并应用草稿的模型/思考档/模式,文本在订阅建立后统一走 sendText。
        setState(() => _progress = '正在创建会话（首次可能需要预热）…');
        final sw = Stopwatch()..start();
        try {
        sessionId = await _transport.createSession(
          widget.workspaceKey,
          config: _buildDraftConfig(),
          timeout: const Duration(seconds: 90),
        );
        if (diagLogEnabled.value) {
          debugPrint('[chat] createSession total ${sw.elapsedMilliseconds}ms'
              ' → $sessionId');
        }
          if (!mounted) return;
        } catch (e) {
          log('[chat] createSession failed after '
              '${sw.elapsedMilliseconds}ms: $e');
          mark('failed', '$e');
          _toast('发送失败: $e');
          return;
        }
        log('[chat] createSession ok in ${sw.elapsedMilliseconds}ms');
        _adoptCreatedSession(sessionId);
        setState(() => _progress = null);
        // 思考档补丁:宿主 createSession 的 thoughtLevel 不落地(真机
        // 实证:请求带 thoughtLevel:max,任务 meta thoughtLevel 仍为空,
        // 会话 config 回读 thought='')。桌面端自身建会话后用
        // switchModelConfig 应用;此处对齐——建完先应用草稿的模型+
        // 思考档,再发首条文本。
        final draft = _buildDraftConfig();
        final provider = draft?['provider'] as String?;
        final model = draft?['model'] as String?;
        final thought = draft?['thought'] as String?;
        if (provider != null &&
            model != null &&
            thought != null &&
            thought.isNotEmpty) {
          try {
            final swSwitch = Stopwatch()..start();
            await _transport.switchModelConfig(sessionId,
                provider: provider, model: model, thought: thought);
            if (diagLogEnabled.value) {
              debugPrint('[chat] switchModelConfig after create '
                  '${swSwitch.elapsedMilliseconds}ms');
            }
          } catch (e) {
            if (diagLogEnabled.value) {
              debugPrint('[chat] switchModelConfig after create failed: $e');
            }
          }
        }
        // 2) 订阅与发送并行:sendText 是 RPC 直达宿主,不依赖本端订阅;
        // 回复经订阅推送,await 订阅只会白等(真机实测首条慢 ~10s)。
        // 订阅在后台补上,回复从建立完成那一刻开始照收。
        unawaited(_subscribe());
      }
      final text = '${echo['text']}';
      if (text.startsWith('/goal ')) {
        final res = await _transport.sendGoalCommand(
          sessionId,
          text.substring('/goal '.length).trim(),
          heldQueueDisposition: heldDisposition,
        );
        if (_ackRejected(res)) {
          mark('failed', _ackReason(res));
          _toast('发送失败: ${_ackReason(res)}');
          return;
        }
        mark('sent');
        return;
      }
      List<Map<String, dynamic>>? attachments =
          (echo['attachments'] as List?)
              ?.whereType<Map>()
              .cast<Map<String, dynamic>>()
              .toList();
      final files = (echo['files'] as List<_PendingFile>?) ?? const [];
      if (files.isNotEmpty) {
        if (mounted) setState(() => _progress = '正在上传附件…');
        final fileList = (echo['files'] as List<_PendingFile>?) ?? [];
        attachments = await _uploadFiles(echo, fileList, sessionId);
        if (mounted) setState(() => _progress = null);
      }
      final swSend = Stopwatch()..start();
      final res = await _transport.sendText(
        sessionId,
        text,
        attachments: attachments,
        heldQueueDisposition: heldDisposition,
      );
      if (diagLogEnabled.value) {
        debugPrint('[chat] sendText ack in ${swSend.elapsedMilliseconds}ms '
            'res=$res');
      }
      if (_ackRejected(res)) {
        mark('failed', _ackReason(res));
        _toast('发送失败: ${_ackReason(res)}');
        return;
      }
      _turnPending = true;
      mark('sent');
    } catch (e) {
      mark('failed', '$e');
      _toast('发送失败: $e');
    } finally {
      if (mounted) {
        setState(() {
          _sending = false;
          _uploadProgress = null;
          _progress = null;
        });
      }
    }
  }

  /// Tap-to-retry for a failed echo: re-asks the held-queue disposition
  /// when applicable, re-uploads attachments that never made it, and
  /// drives the same status machine as the original send.
  Future<void> _retryEcho(Map<String, dynamic> echo) async {
    if (_sending) return;
    String? heldDisposition;
    final state = _state;
    if (state != null &&
        state.inputRoutingMode == 'choice' &&
        state.queueItems.isNotEmpty) {
      heldDisposition = await _askHeldQueueDisposition();
      if (heldDisposition == null) return; // cancelled
    }
    setState(() {
      echo['status'] = 'sending';
      echo['error'] = null;
      _sending = true;
    });
    await _deliverEcho(echo, heldDisposition: heldDisposition);
  }

  bool _ackRejected(dynamic res) =>
      res is Map &&
      res['status'] != null &&
      res['status'] != 'accepted' &&
      res['status'] != 'noop' &&
      res['status'] != 'duplicate';

  String _ackReason(dynamic res) {
    if (res is! Map) return '$res';
    return '${res['reasonCode'] ?? res['message'] ?? res['status']}';
  }

  String _requireSession() {
    final sessionId = _sessionId;
    if (sessionId == null) throw StateError('尚无会话');
    return sessionId;
  }

  /// 草稿选择(模型/思考档/模式)持久化:跨启动恢复上次选择。
  /// prep 到达后按宿主可选项校验,宿主已不提供的值自动丢弃,避免把
  /// 过期模型发给 createSession。
  Future<void> _loadDraftPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!mounted) return;
      setState(() {
        for (final k in const ['model', 'thought', 'mode']) {
          final v = prefs.getString('draft.$k');
          if (v != null && v.isNotEmpty) _draftConfig[k] = v;
        }
      });
      _validateDraftAgainstPrep();
    } catch (_) {}
  }

  void _validateDraftAgainstPrep() {
    final prep = _prep;
    if (prep == null) return;
    final changed = <String, String>{..._draftConfig};
    for (final entry in changed.entries.toList()) {
      final option = prep.option(entry.key == 'thought' ? 'thought_level' : entry.key);
      if (option != null &&
          option.options.isNotEmpty &&
          !option.options.any((o) => o.value == entry.value)) {
        _draftConfig.remove(entry.key);
      }
    }
    if (mounted) setState(() {});
  }

  Future<void> _saveDraftPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      for (final k in const ['model', 'thought', 'mode']) {
        final v = _draftConfig[k];
        if (v == null || v.isEmpty) {
          await prefs.remove('draft.$k');
        } else {
          await prefs.setString('draft.$k', v);
        }
      }
    } catch (_) {}
  }

  /// Builds the createSession `config` payload from the draft selection.
  Map<String, dynamic>? _buildDraftConfig() {
    // 未显式改过的项回填 prepareWorkspace 的当前值(用户在 pill/模式按钮
    // 看到的就是这些值,期望按它建会话;缺省时宿主会用默认档,表现为
    // "思考等级没按选好的来")。
    String? pick(String key, String optionId) =>
        _draftConfig[key] ?? '${_prep?.option(optionId)?.currentValue ?? ''}';
    final modelValue = _draftConfig['model'] ??
        '${_prep?.option('model')?.currentValue ?? ''}';
    final config = <String, dynamic>{};
    if (modelValue.isNotEmpty) {
      final (provider, model) = providerModelOf(_prep, modelValue);
      config['provider'] = provider;
      config['model'] = model;
    }
    final thought = pick('thought', 'thought_level');
    if (thought != null && thought.isNotEmpty) config['thought'] = thought;
    final mode = pick('mode', 'mode');
    if (mode != null && mode.isNotEmpty) config['mode'] = mode;
    return config.isEmpty ? null : config;
  }

  Future<String?> _askHeldQueueDisposition() {
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('有排队中的消息'),
        content: const Text('立即发送将清空排队消息并插队执行'),
        actions: [
          TextButton(
            onPressed: () =>
                Navigator.pop(context, 'keepQueueAndSend'),
            child: const Text('排队发送'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(context, 'clearQueueAndSend'),
            child: const Text('立即发送'),
          ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------ history

  Future<void> _loadOlder() async {
    final state = _state;
    final sessionId = _sessionId;
    if (state == null || sessionId == null || _loadingOlder) return;
    if (!state.canLoadOlder) return;
    setState(() => _loadingOlder = true);
    try {
      // The cursor is the protocol state's oldest held row — see
      // ConversationState.oldestRowId.
      final res = await _transport.rowsRange(
        sessionId,
        beforeRowId: state.oldestRowId,
        limit: 60,
      );
      List? rows;
      int? firstRowId;
      var hasMore = false;
      if (res is Map) {
        final rowsObj = res['rows'];
        if (rowsObj is Map) {
          rows = rowsObj['window'] as List? ?? rowsObj['rows'] as List?;
          firstRowId = (rowsObj['firstRowId'] as num?)?.toInt();
        } else if (rowsObj is List) {
          rows = rowsObj;
        }
        rows ??= res['items'] as List? ?? res['window'] as List?;
        firstRowId ??= (res['firstRowId'] as num?)?.toInt();
        hasMore = res['hasMore'] == true;
      } else if (res is List) {
        rows = res;
      }
      if (rows != null && rows.isNotEmpty) {
        final older = rows
            .whereType<Map>()
            .map((e) => e.cast<String, dynamic>())
            .toList()
          ..sort((a, b) => ((a['rowId'] as num?) ?? 0)
              .compareTo((b['rowId'] as num?) ?? 0));
        final oldLength = state.rows.length;
        final oldFirstRowId = state.firstRowId;
        state.prependOlderRows(older, firstRowId);
        if (state.rows.length != oldLength ||
            state.firstRowId != oldFirstRowId) {
          _prependScrollPending = true;
          _prependTailRow = state.rows.isEmpty ? null : state.rows.last;
        }
        // Reverse list: prepended history extends the top end without
        // moving the viewport — no scroll compensation needed.
        // This batch was the last (server says nothing precedes it): the
        // earliest message is now held — retire the button immediately.
        if (!hasMore) state.historyExhausted = true;
      } else {
        // Exhausted (the server's hasMore is false): stop offering the
        // button instead of re-tapping into empty responses.
        if (!hasMore) state.historyExhausted = true;
        if (state.rows.isNotEmpty) {
          _toast('没有更早的消息了');
        }
      }
    } catch (e) {
      _toast('加载失败: $e');
    } finally {
      if (mounted) setState(() => _loadingOlder = false);
    }
  }

  // ------------------------------------------------------------ sheets

  void _showModelSheet() {
    // 立即用缓存打开(零等待);面板自持刷新——新鲜(≤5s)不发请求,
    // 否则强制拉取,数据到达后原地更新列表(删除的模型随之消失)。
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) => _ModelModeSheet(
        state: _state,
        transport: _transport,
        prep: _prep,
        sessionId: _sessionId,
        draftConfig: _draftConfig,
        onRefreshPrep: _fetchPrepForSheet,
        onDraftChange: (key, value) {
          setState(() => _draftConfig[key] = value);
          _saveDraftPrefs();
        },
      ),
    );
  }

  /// Slash entries = builtin/custom commands from prepareWorkspace plus the
  /// desktop's skills (triggered as `$name` in the composer).
  List<_SlashItem> get _slashItems {
    final items = <_SlashItem>[];
    for (final c in _prep?.slashCommands ?? const <SlashCommand>[]) {
      items.add(_SlashItem(
        name: c.name,
        description: c.description,
        insert: '/${c.name} ',
        isSkill: false,
      ));
    }
    for (final s in _skills) {
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
      _state?.currentMode ?? _draftConfig['mode'] ?? 'build';

  /// 协作模式菜单(U2):与模型面板的模式区同源,选择即时生效。
  void _showModeMenu() {
    final option = _prep?.option('mode');
    final options = option != null && option.options.isNotEmpty
        ? [for (final v in option.options) (v.value, v.name)]
        : const [('build', 'build'), ('edit', 'edit'), ('plan', 'plan'), ('yolo', 'yolo')];
    final current = _state?.currentMode ?? _draftConfig['mode'] ?? 'build';
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
                if (_sessionId == null || _sessionId!.isEmpty) {
                  setState(() => _draftConfig['mode'] = value);
                  _saveDraftPrefs();
                } else {
                  _run('切换失败', () async {
                    await _transport.switchCollaborationMode(
                        _sessionId!, value);
                    _state?.optimisticPatch({
                      'config': {
                        ...?_state!.config,
                        'mode': value,
                      },
                    });
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
        loading: _skillsLoading,
        onSelect: (text) {
          _inputController.text = text;
          _inputController.selection = TextSelection.collapsed(
              offset: _inputController.text.length);
          Navigator.of(sheetContext).pop();
          setState(() => _showSlash = false);
        },
        onAttach: () {
          Navigator.of(sheetContext).pop();
          _pickFiles();
        },
        onRefresh: _loadPrep,
      ),
    );
  }

  void _showUsageSheet() {
    final state = _state;
    final sessionId = _sessionId;
    if (state == null || sessionId == null) return;
    showModalBottomSheet(
      context: context,
      builder: (context) => _UsageSheet(
        state: state,
        session: widget.session,
        scope: widget.scope,
        sessionId: sessionId,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = _state;
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
                animation: state,
                builder: (context, _) => Text(
                  [
                    if (state.phase.isNotEmpty) state.phase,
                    state.currentModel,
                    if (state.currentThought.isNotEmpty)
                      state.currentThought,
                  ].where((s) => s.isNotEmpty).join(' · '),
                  style: TextStyle(fontSize: 11, color: EmberColors.of(context).textFaint),
                ),
              ),
          ],
        ),
        actions: [
          if (state != null)
            AnimatedBuilder(
              animation: state,
              builder: (context, _) => state.isRunning
                  ? IconButton(
                      icon: Icon(Icons.stop_circle_outlined,
                      color: EmberColors.of(context).err),
                      tooltip: '停止',
                      onPressed: () =>
                          _run('停止失败', () => _transport.stop(_sessionId!)),
                    )
                  : const SizedBox.shrink(),
            ),
          if (_sessionId != null)
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
            onSelected: _sessionId == null
                ? null
                : (action) {
                    switch (action) {
                      case 'compact':
                        _run('压缩失败',
                            () => _transport.compact(_sessionId!));
                      case 'usage':
                        _showUsageSheet();
                    }
                  },
            itemBuilder: (context) => [
              PopupMenuItem(
                  value: 'compact',
                  enabled: _sessionId != null,
                  child: Text('压缩上下文 (compact)')),
              PopupMenuItem(
                  value: 'usage',
                  enabled: _sessionId != null,
                  child: Text('用量统计')),
            ],
          ),
        ],
      ),
      body: body,
    );
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
                animation: state,
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
  /// ([_turnPending])同样按工作中显示。
  Widget _sessionStatusChip(BuildContext context, ConversationState? state) {
    final colors = EmberColors.of(context);
    final running = _turnPending || (state != null && state.isRunning);
    final color = running ? colors.primary : colors.textFaint;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(EmberRadius.avatar),
        border: Border.all(
            color: running ? colors.primary.withValues(alpha: 0.4) : colors.hairline),
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
          if (state != null && state.isRunning && _sessionId != null)
            IconButton(
              icon: Icon(Icons.stop_circle_outlined,
                  size: 22, color: colors.err),
              tooltip: '停止',
              onPressed: () =>
                  _run('停止失败', () => _transport.stop(_sessionId!)),
            ),
          Flexible(child: _modelPill(context, state)),
          // 常驻(草稿态禁用会话级条目),避免会话激活时按钮出现把
          // 右侧会话列表入口挤出屏幕。
          PopupMenuButton<String>(
            icon: Icon(Icons.more_vert, size: 20, color: colors.textMuted),
            tooltip: '更多',
            onSelected: _sessionId == null
                ? null
                : (action) {
                    switch (action) {
                      case 'side':
                        _openSideChat();
                      case 'compact':
                        _run('压缩失败',
                            () => _transport.compact(_sessionId!));
                      case 'usage':
                        _showUsageSheet();
                    }
                  },
            itemBuilder: (context) => [
              PopupMenuItem(
                  value: 'side',
                  enabled: _sessionId != null,
                  child: Text('辅助对话')),
              PopupMenuItem(
                  value: 'compact',
                  enabled: _sessionId != null,
                  child: Text('压缩上下文 (compact)')),
              PopupMenuItem(
                  value: 'usage',
                  enabled: _sessionId != null,
                  child: Text('用量统计')),
            ],
          ),
        ],
      );
    }

    if (state == null) return build();
    return AnimatedBuilder(animation: state, builder: (context, _) => build());
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
        padding:
            const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
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
                      fontSize: EmberType.caption,
                      color: colors.textFaint)),
              const SizedBox(width: 6),
              Text(thought,
                  style: TextStyle(
                      fontSize: EmberType.body,
                      color: colors.textMuted)),
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
    final opt = _prep?.option('model');
    final isDraft = state == null || _sessionId == null || _sessionId!.isEmpty;
    String value;
    if (isDraft) {
      value = _draftConfig['model'] ?? '${opt?.currentValue ?? ''}';
    } else {
      final config = state.config ?? const {};
      value = '${config['provider'] ?? ''}/${config['model'] ?? ''}';
      if ('${config['model'] ?? ''}'.isEmpty) {
        value = _draftConfig['model'] ?? '${opt?.currentValue ?? ''}';
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
    final opt = _prep?.option('thought_level');
    final isDraft = state == null || _sessionId == null || _sessionId!.isEmpty;
    final value = isDraft
        ? (_draftConfig['thought'] ?? '${opt?.currentValue ?? ''}')
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
          if (_error != null)
            Material(
              color: EmberColors.of(context).err.withValues(alpha: 0.15),
              child: ListTile(
                dense: true,
                title: Text('订阅失败: $_error',
                    style: const TextStyle(fontSize: 12)),
                trailing: TextButton(
                    onPressed: _subscribe, child: const Text('重试')),
              ),
            ),
          if (state != null)
            AnimatedBuilder(
              animation: state,
              builder: (context, _) => _ContextUsageBar(state: state),
            ),
          if (state != null)
            AnimatedBuilder(
              animation: state,
              builder: (context, _) => _ModeBanner(mode: state.currentMode),
            ),
          Expanded(
            child: state == null
                ? Center(
                    child: _sessionId == null
                        ? Text('输入消息开始新会话',
                            style: TextStyle(color: EmberColors.of(context).textFaint))
                        : const CircularProgressIndicator(),
                  )
                : !state.ready
                    ? const Center(child: CircularProgressIndicator())
                    : AnimatedBuilder(
                        animation: state,
                        builder: (context, _) {
                          final groups = _groupRows(state.rows);
                          // Optimistic echoes render newest-first at the
                          // bottom (reverse index 0..n-1).
                          final echoCount = _echoes.length;
                          final itemCount = groups.length +
                              echoCount +
                              (state.canLoadOlder ? 1 : 0);
                          if (groups.isEmpty &&
                              echoCount == 0 &&
                              !state.canLoadOlder) {
                            return Center(
                                child: Text('暂无消息',
                                    style:
                                        TextStyle(color: EmberColors.of(context).textFaint)));
                          }
                          // Reverse list: index 0 renders at the bottom, so
                          // offset 0 IS the newest message — a freshly
                          // opened chat sits on the latest turn by
                          // construction, and prepended history never
                          // shifts the viewport.
                          return ListView.builder(
                            controller: _scrollController,
                            reverse: true,
                            padding:
                                const EdgeInsets.fromLTRB(14, 14, 14, 8),
                            itemCount: itemCount,
                            itemBuilder: (context, index) {
                              if (index < echoCount) {
                                final e =
                                    _echoes[echoCount - 1 - index];
                                // Same bubble as a confirmed user row, so
                                // retiring the echo (real row takes over)
                                // is visually seamless. 已发送 + 轮次在途
                                // → 乐观升为「处理中」(见 _turnPending)。
                                final badge =
                                    e['status'] == 'sent' && _turnPending
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
                                  transport: _transport,
                                  sessionId: _sessionId ?? '',
                                  badge: badge,
                                  onRetry:
                                      e['status'] == 'failed'
                                          ? () => _retryEcho(e)
                                          : null,
                                );
                              }
                              final mi = index - echoCount;
                              if (state.canLoadOlder && mi == groups.length) {
                                return Center(
                                  child: TextButton.icon(
                                    onPressed: _loadingOlder
                                        ? null
                                        : _loadOlder,
                                    icon: _loadingOlder
                                        ? const SizedBox(
                                            width: 12,
                                            height: 12,
                                            child:
                                                CircularProgressIndicator(
                                                    strokeWidth: 1.5),
                                          )
                                        : const Icon(Icons.history,
                                            size: 14),
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
                                transport: _transport,
                                sessionId: _sessionId ?? '',
                                onAction: _run,
                                state: state,
                              );
                            },
                          );
                        },
                      ),
          ),
          _ReconnectBanner(bridge: _transport.session),
          if (state != null)
            AnimatedBuilder(
              animation: state,
              builder: (context, _) => Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _GoalBanner(state: state),
                  _BackgroundWorksBar(state: state),
                  _QueueBar(state: state, transport: _transport),
                  _PendingInteractions(
                      state: state, transport: _transport),
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
          if (_progress != null)
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
                  Text(_progress!,
                      style: TextStyle(
                          fontSize: 11, color: EmberColors.of(context).textMuted)),
                ],
              ),
            ),
          if (_pendingFiles.isNotEmpty)
            _PendingFilesBar(
              files: _pendingFiles,
              uploadProgress: _uploadProgress,
              onRemove: (i) =>
                  setState(() => _pendingFiles.removeAt(i)),
            ),
          if (state != null && _sessionId != null)
            AnimatedBuilder(
              animation: state,
              builder: (context, _) => InsightsHandle(
                state: state,
                transport: _transport,
                sessionId: _sessionId!,
              ),
            ),
          // 模式按钮随会话 state 跟进(optimisticPatch/宿主确认都要
          // 重建输入栏;此前 InputBar 不在 state 监听内,远端已切、
          // 本地按钮不变)。
          AnimatedBuilder(
            animation: Listenable.merge(
                [if (state != null) state]),
            builder: (context, _) => _InputBar(
              controller: _inputController,
              sending: _sending,
              onSend: _send,
              onAttach: _pickFiles,
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
