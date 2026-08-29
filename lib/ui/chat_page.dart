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

  void _dedupeEchoes() {
    final state = _state;
    if (state == null || _echoes.isEmpty) return;
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

  Future<void> _loadPrep() async {
    try {
      final prep = await _transport.prepareWorkspace();
      if (mounted) {
        setState(() => _prep = prep);
        _validateDraftAgainstPrep();
      }
    } catch (_) {}
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
      final sub = await _transport
          .subscribe(sessionId)
          .timeout(const Duration(seconds: 60));
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
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      // Follow the newest message only while the user is pinned to the
      // bottom (or within 400px), so reading history isn't yanked.
      if (_stickToBottom || _scrollController.position.pixels < 400) {
        _scrollController.animateTo(
          0,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
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
      List<_PendingFile> files, String sessionId) async {
    final uploaded = <Map<String, dynamic>>[];
    for (var i = 0; i < files.length; i++) {
      final file = files[i];
      final descriptor = await _transport.attachmentPut(
        sessionId,
        fileName: file.fileName,
        mime: file.mime,
        bytes: file.bytes,
        onProgress: (p) =>
            setState(() => _uploadProgress = (i + p) / files.length),
      );
      uploaded.add(descriptor);
    }
    return uploaded;
  }

  Future<void> _send() async {
    final text = _inputController.text.trim();
    if ((text.isEmpty && _pendingFiles.isEmpty) || _sending) return;

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
      setState(() {
        echo['status'] = status;
        if (error != null) echo['error'] = error;
      });
    }

    try {
      var sessionId = _sessionId;
      if (sessionId == null) {
        // 1) create the session (can take a while when the runtime warms)
        setState(() => _progress = '正在创建会话（首次可能需要预热）…');
        final sw = Stopwatch()..start();
        // Plain text first message is sent WITH createSession (firstInput,
        // mirrors the official composer). This avoids a send-before-subscribe
        // race where the first command can be dropped on a fresh session.
        final text = '${echo['text']}';
        final canUseFirstInput = text.isNotEmpty &&
            (echo['files'] as List).isEmpty &&
            !text.startsWith('/goal ') &&
            heldDisposition == null;
        try {
          sessionId = await _transport.createSession(
            widget.workspaceKey,
            firstText: canUseFirstInput ? text : null,
            config: _buildDraftConfig(),
            timeout: const Duration(seconds: 90),
          );
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
        // 2) subscribe in the background — must NOT block sending
        setState(() => _progress = null);
        if (canUseFirstInput) {
          // Message already sent with the session; the history snapshot
          // will confirm it and retire the echo.
          mark('sent');
          _subscribe();
          return;
        }
        // Attachments / goal commands: the follow-up command needs an active
        // subscription, so wait for it before proceeding.
        await _subscribe();
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
      if (files.isNotEmpty && attachments == null) {
        setState(() => _progress = '正在上传附件…');
        attachments = await _uploadFiles(files, sessionId);
        echo['attachments'] = attachments;
        setState(() => _progress = null);
      }
      final res = await _transport.sendText(
        sessionId,
        text,
        attachments: attachments,
        heldQueueDisposition: heldDisposition,
      );
      if (_ackRejected(res)) {
        mark('failed', _ackReason(res));
        _toast('发送失败: ${_ackReason(res)}');
        return;
      }
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
    if (_draftConfig.isEmpty) return null;
    final config = <String, dynamic>{};
    final modelValue = _draftConfig['model'];
    if (modelValue != null && modelValue.isNotEmpty) {
      final idx = modelValue.lastIndexOf('/');
      if (idx > 0) {
        config['provider'] = modelValue.substring(0, idx);
        config['model'] = modelValue.substring(idx + 1);
      }
    }
    if (_draftConfig['thought'] != null) {
      config['thought'] = _draftConfig['thought'];
    }
    if (_draftConfig['mode'] != null) {
      config['mode'] = _draftConfig['mode'];
    }
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
        state.prependOlderRows(older, firstRowId);
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
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) => _ModelModeSheet(
        state: _state,
        transport: _transport,
        prep: _prep,
        sessionId: _sessionId,
        draftConfig: _draftConfig,
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
  /// 当前协作模式展示名(U2 输入框模式按钮):活动会话用现场值,
  /// 草稿用草稿选择,展示名优先取 prepareWorkspace 选项的命名。
  String get _currentModeLabel {
    final mode = _state?.currentMode ?? _draftConfig['mode'] ?? 'build';
    return _optionLabel(_prep?.option('mode'), mode) ?? mode;
  }

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

  Future<void> _showPlansSheet() async {
    final sessionId = _sessionId;
    if (sessionId == null) return;
    try {
      final plans = await _transport.plans(sessionId);
      if (!mounted) return;
      showModalBottomSheet(
        context: context,
        builder: (context) => _JsonSheet(title: '计划', data: plans),
      );
    } catch (e) {
      _toast('获取计划失败: $e');
    }
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
                      case 'plans':
                        _showPlansSheet();
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
              PopupMenuItem(
                  value: 'plans',
                  enabled: _sessionId != null,
                  child: Text('计划')),
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
      child: Row(
        children: [
          if (widget.headerLeading != null) widget.headerLeading!,
          const SizedBox(width: EmberSpacing.gapM),
          Expanded(child: _embeddedTitle(context)),
          _headerActions(context, state, colors),
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

  /// 会话名:null/空显示「新会话」;经 listenable 跟进桌面端生成的标题。
  Widget _embeddedTitle(BuildContext context) {
    final colors = EmberColors.of(context);
    final listenable = widget.headerTitle;
    if (listenable == null) {
      return Text(widget.title,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
              fontSize: EmberType.body,
              fontWeight: FontWeight.w600,
              color: colors.textSolid));
    }
    return ValueListenableBuilder<String?>(
      valueListenable: listenable,
      builder: (context, title, _) => Text(
        title == null || title.isEmpty ? '新会话' : title,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
            fontSize: EmberType.body,
            fontWeight: FontWeight.w600,
            color: colors.textSolid),
      ),
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
          _modelPill(context, state),
          // 常驻(草稿态禁用会话级条目),避免会话激活时按钮出现把
          // 右侧会话列表入口挤出屏幕。
          PopupMenuButton<String>(
            icon: Icon(Icons.more_horiz, size: 20, color: colors.textMuted),
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
                      case 'plans':
                        _showPlansSheet();
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
              PopupMenuItem(
                  value: 'plans',
                  enabled: _sessionId != null,
                  child: Text('计划')),
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
            Text(model,
                style: TextStyle(
                    fontSize: EmberType.body,
                    fontWeight: FontWeight.w600,
                    color: colors.textSolid)),
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
                                // is visually seamless.
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
                                  badge: '${e['status']}',
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
          _InputBar(
            controller: _inputController,
            sending: _sending,
            onSend: _send,
            onAttach: _pickFiles,
            onPlusMenu: _openPlusSheet,
            modeLabel: _currentModeLabel,
            onPickMode: _showModeMenu,
          ),
        ],
      );
}

// ---------------------------------------------------------------- rows

/// plan/yolo 模式的流内状态条(spec §7.1:权限级提示,模式切回 build
/// 即消失)。计划橙条提示只读需确认,YOLO 红条警示免确认风险。
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
    final text = yolo
        ? 'YOLO 模式 · 全部操作免确认，请确认在工作机上'
        : '计划模式中 · 只读研究，方案产出后需你确认才会动手';
    return Container(
      width: double.infinity,
      color: color.withValues(alpha: 0.15),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      child: Row(
        children: [
          Icon(
              yolo
                  ? Icons.warning_amber_rounded
                  : Icons.visibility_outlined,
              size: 14,
              color: color),
          const SizedBox(width: EmberSpacing.gapS),
          Expanded(
            child: Text(text,
                style: TextStyle(
                    fontSize: EmberType.secondary, color: color)),
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
                          fontSize: 12, color: EmberColors.of(context).textSoft)),
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
        parts.add((kind: 'text', text: text, row: template,
            streaming: anyStream));
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
List<List<Map<String, dynamic>>> _groupRows(
    List<Map<String, dynamic>> rows) {
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
    final startsGroup = isUser ||
        current == null ||
        current.first['kind'] == 'userInput';
    if (startsGroup) {
      current = [row];
      groups.add(current);
    } else {
      current.add(row);
    }
  }
  return groups;
}

class _TurnGroupWidget extends StatelessWidget {
  final List<Map<String, dynamic>> rows;
  final ConversationTransport transport;
  final String sessionId;
  final Future<void> Function(String, Future<dynamic> Function()) onAction;
  final ConversationState state;

  const _TurnGroupWidget({
    super.key,
    required this.rows,
    required this.transport,
    required this.sessionId,
    required this.onAction,
    required this.state,
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
          style: TextStyle(fontSize: 10, color: EmberColors.of(context).textFaint)),
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
      final processing = state.isRunning &&
          first['rowId'] == lastUserInputRowId(state.rows);
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
            badge: processing ? 'processing' : null,
          ),
          for (final row in rows.skip(1))
            _RowWidget(
              row: row,
              transport: transport,
              sessionId: sessionId,
              onAction: onAction,
              state: state,
            ),
          if (_timeLabel(context) != null)
            Align(
                alignment: Alignment.centerRight,
                child: _timeLabel(context)),
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
        ));
      } else {
        children.add(_RowWidget(
          row: p.row!,
          showFeedback: false,
          transport: transport,
          sessionId: sessionId,
          onAction: onAction,
          state: state,
        ));
      }
    }
    final header = parts.header;
    if (header != null) {
      children.add(_TurnHeader(
        row: header,
        errorSummary: (header['state'] as String?) == 'failed'
            ? _errorSummary()
            : null,
      ));
    }
    if (_timeLabel(context) != null) {
      children.add(Align(
          alignment: Alignment.centerLeft, child: _timeLabel(context)));
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
  final bool showFeedback;

  /// Delivery badge for user rows (see [_MsgBadge]).
  final String? badge;

  const _RowWidget({
    required this.row,
    required this.transport,
    required this.sessionId,
    required this.onAction,
    required this.state,
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
                onAction('重试失败',
                    () => transport.retryTurn(sessionId, _target));
              },
            ),
            ListTile(
              leading: const Icon(Icons.fork_right, size: 20),
              title: const Text('分叉对话 (fork)'),
              onTap: () {
                Navigator.pop(context);
                onAction('分叉失败',
                    () => transport.forkAssistant(sessionId, _target));
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
              onPressed: () => Navigator.pop(context),
              child: const Text('取消')),
          FilledButton(
              onPressed: () =>
                  Navigator.pop(context, controller.text.trim()),
              child: const Text('重发')),
        ],
      ),
    );
    controller.dispose();
    if (text == null || text.isEmpty) return;
    await onAction('编辑失败',
        () => transport.editUserQuery(sessionId, _target, text));
  }

  Future<void> _confirmRewind(BuildContext context) async {
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
    if (confirmed != true) return;
    await onAction('回滚失败',
        () => transport.applyFileRewind(sessionId, _target));
  }

  Future<void> _showFileChanges(BuildContext context) async {
    try {
      // The server guard accepts turnHeader targets only — resolve this
      // row's turn header (rows carry the same turnId) and add the
      // Zod-required baseRevision/baseLogEpoch.
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
          ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('该回合没有可查询的文件变更')));
        }
        return;
      }
      final changes = await transport.fileChanges(
        sessionId,
        target: {'rowId': header['rowId'], 'entityId': header['entityId']},
      );
      if (!context.mounted) return;
      showModalBottomSheet(
        context: context,
        builder: (context) => _JsonSheet(title: '文件变更', data: changes),
      );
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('获取失败: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final widget_ = switch (row['kind']) {
      'userInput' => _UserBubble(row: row, transport: transport,
          sessionId: sessionId, badge: badge),
      'assistantText' => _AssistantBubble(
          row: row, transport: transport, sessionId: sessionId,
          state: state, showFeedback: showFeedback),
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
          Icon(Icons.schedule, size: 11, color: EmberColors.of(context).textFaint),
          const SizedBox(width: 3),
          Text('发送中',
              style: TextStyle(fontSize: 9.5, color: EmberColors.of(context).textFaint)),
        ]);
      case 'sent':
        content = Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.check, size: 11, color: EmberColors.of(context).textFaint),
          const SizedBox(width: 3),
          Text('已发送',
              style: TextStyle(fontSize: 9.5, color: EmberColors.of(context).textFaint)),
        ]);
      case 'processing':
        content = Row(mainAxisSize: MainAxisSize.min, children: [
          const SizedBox(
              width: 11,
              height: 11,
              child: CircularProgressIndicator(strokeWidth: 1.4)),
          const SizedBox(width: 3),
          Text('处理中',
              style: TextStyle(
                  fontSize: 9.5,
                  color: EmberColors.of(context).run)),
        ]);
      default: // failed
        content = Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.error_outline,
              size: 12, color: EmberColors.of(context).err),
          const SizedBox(width: 3),
          Text('发送失败 · 点击重试',
              style: TextStyle(
                  fontSize: 9.5,
                  color: EmberColors.of(context).err)),
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
              padding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
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

  const _AttachmentView({
    required this.attachment,
    required this.transport,
    required this.sessionId,
  });

  @override
  State<_AttachmentView> createState() => _AttachmentViewState();
}

class _AttachmentViewState extends State<_AttachmentView> {
  Uint8List? _imageBytes;
  bool _failed = false;

  bool get _isImage =>
      '${widget.attachment['mime'] ?? ''}'.startsWith('image/');

  @override
  void initState() {
    super.initState();
    if (_isImage) _load();
  }

  Future<void> _load() async {
    final ref = widget.attachment['ref'] as String?;
    if (ref == null) return;
    try {
      final res = await widget.transport
          .attachmentRead(widget.sessionId, ref: ref);
      if (mounted) setState(() => _imageBytes = res.bytes);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
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
          style: TextStyle(fontSize: 11, color: EmberColors.of(context).textFaint));
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
          cacheWidth:
              (220 * MediaQuery.devicePixelRatioOf(context)).round(),
        ),
      ),
    );
  }
}

class _AssistantBubble extends StatelessWidget {
  final Map<String, dynamic> row;
  final ConversationTransport transport;
  final String sessionId;
  final ConversationState state;
  final bool showFeedback;

  const _AssistantBubble({
    required this.row,
    required this.transport,
    required this.sessionId,
    required this.state,
    this.showFeedback = true,
  });

  void _setFeedback(String? value) {
    if (sessionId.isEmpty) return;
    // Optimistic: update the icon instantly; server row.upserted confirms.
    state.optimisticRowUpdate(row['rowId'] as num?, {'feedback': value});
    transport.setAssistantFeedback(
      sessionId,
      {
        'rowId': row['rowId'],
        if (row['entityId'] != null) 'entityId': row['entityId'],
      },
      value,
    );
  }

  @override
  Widget build(BuildContext context) {
    final text = row['text'] as String? ?? '';
    final streaming = row['state'] == 'streaming';
    final feedback = row['feedback'] as String?;
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
          ZflowMarkdown(text, fontSize: 13),
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
                    icon: Icons.thumb_up_alt_outlined,
                    active: feedback == 'like',
                    onTap: () =>
                        _setFeedback(feedback == 'like' ? null : 'like'),
                  ),
                  _FeedbackButton(
                    icon: Icons.thumb_down_alt_outlined,
                    active: feedback == 'dislike',
                    onTap: () => _setFeedback(
                        feedback == 'dislike' ? null : 'dislike'),
                  ),
                ],
              ],
            ),
        ],
      ),
    );
  }
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
          size: 15, color: active ? EmberColors.of(context).primary : EmberColors.of(context).textFaint),
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
  bool _open = true;

  @override
  Widget build(BuildContext context) {
    final e = EmberColors.of(context);
    final arrow = _open ? '▾ ' : '▸ ';
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
                child: Text(
                  '$arrow${widget.streaming ? '思考中…' : '思考过程'}',
                  style: TextStyle(
                      fontSize: EmberType.caption, color: e.textFaint),
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

/// Tool call block. Ember look matches [_ReasoningTile]: tile one step
/// darker than card, 10pt radius, 3px rail colored by status (success→ok,
/// error→err, running→run). The tool name is a standalone faint caption row
/// (▸/▾ prefix, term font) toggling the input/output/error detail.
class _ToolCallTile extends StatefulWidget {
  final Map<String, dynamic> row;

  const _ToolCallTile({required this.row});

  @override
  State<_ToolCallTile> createState() => _ToolCallTileState();
}

class _ToolCallTileState extends State<_ToolCallTile> {
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
                            fontSize: EmberType.caption,
                            color: e.textFaint)),
                    Icon(icon, size: 12, color: color),
                    const SizedBox(width: 4),
                    Flexible(
                      child: Text(toolName,
                          style: TextStyle(
                              fontSize: EmberType.caption,
                              fontFamily: EmberFonts.term,
                              color: e.textFaint),
                          overflow: TextOverflow.ellipsis),
                    ),
                  ],
                ),
              ),
            ),
            if (_open) ...[
              if (inputText.isNotEmpty) _kv(context, '输入', inputText),
              if (outputText.isNotEmpty) _kv(context, '输出', outputText),
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
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Image.memory(
                      base64Decode(image['base64'] as String),
                      fit: BoxFit.contain,
                      // Cap the decode at viewport width — inline tool
                      // outputs can embed multi-megapixel renders.
                      cacheWidth: (MediaQuery.sizeOf(context).width *
                              MediaQuery.devicePixelRatioOf(context))
                          .round(),
                      errorBuilder: (_, __, ___) =>
                          const SizedBox.shrink(),
                    ),
                  ),
                ),
          ],
        ),
      ),
    );
  }

  Widget _kv(BuildContext context, String label, String value) {
    // Pretty-print JSON input when possible (official shows structured view)
    var display = value;
    try {
      final decoded = jsonDecode(value);
      display = const JsonEncoder.withIndent('  ').convert(decoded);
    } catch (_) {}
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: TextStyle(
                  fontSize: 10.5, color: EmberColors.of(context).textFaint)),
          const SizedBox(height: 2),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: EmberColors.of(context).codeBlockBg,
              borderRadius: BorderRadius.circular(8),
            ),
            child: SelectableText(
              display.length > 4000
                  ? '${display.substring(0, 4000)}…'
                  : display,
              style: TextStyle(
                  fontFamily: 'monospace', fontSize: 11,
                  color: EmberColors.of(context).textSolid),
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
      'running' => liveLabel.isEmpty
          ? '本轮执行中'
          : '本轮执行中 · $liveLabel',
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
                    fontSize: 11,
                    color: color.withValues(alpha: 0.9)),
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
        padding:
            const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
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
                Text(
                    '${row['status'] ?? ''}  ${row['summaryText'] ?? ''}',
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
    final color =
        ratio > 0.8 ? EmberColors.of(context).warn : EmberColors.of(context).primary;
    String fmt(int v) =>
        v >= 1000 ? '${(v / 1000).toStringAsFixed(1)}k' : '$v';
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
  if (t is! Map) return null;
  for (final k in const ['todos', 'plan', 'steps', 'items']) {
    final arr = t[k];
    if (arr is! List || arr.isEmpty) continue;
    final steps = <PlanStep>[];
    for (var i = 0; i < arr.length; i++) {
      final s = _parsePlanStep(arr[i], i);
      if (s == null) return null; // all-or-nothing
      steps.add(s);
    }
    return steps;
  }
  return null;
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

/// The latest turnHeader of a COMPLETED turn (`state: completedSuccess`
/// with a usable {rowId, entityId}) — the official client's armed target
/// for file-changes loading. A still-running turn must not be queried: the
/// server guard races the streaming revision and rejects it as stale.
/// Pure for tests.
Map<String, dynamic>? latestCompletedTurn(List<Map<String, dynamic>> rows) {
  for (final r in rows.reversed) {
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

/// 洞察 sheet 把手(spec §7.1):输入区上方常驻的 40×4 圆角条,点击或
/// 上滑呼出底部 sheet;后台有运行任务时右端浮出「后台 N」计数徽,
/// 面板数据为空也常驻。公开给测试(与 SessionDrawer 同例)。
class InsightsHandle extends StatelessWidget {
  final ConversationState state;
  final ConversationTransport transport;
  final String sessionId;

  const InsightsHandle({
    super.key,
    required this.state,
    required this.transport,
    required this.sessionId,
  });

  void _openSheet(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.62,
        builder: (context, scrollController) => InsightsSheet(
          state: state,
          transport: transport,
          sessionId: sessionId,
          scrollController: scrollController,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ember = EmberColors.of(context);
    final bg = insightsBgCount(
        backgroundWorks: state.backgroundWorks, rows: state.rows);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _openSheet(context),
      onVerticalDragEnd: (details) {
        if ((details.primaryVelocity ?? 0) < 0) _openSheet(context);
      },
      child: SizedBox(
        height: 20,
        width: double.infinity,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: ember.textFaint,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            if (bg > 0)
              Positioned(
                right: EmberSpacing.page,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: ember.primary.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(EmberRadius.control),
                  ),
                  child: Text('后台 $bg',
                      style: TextStyle(
                          fontSize: EmberType.caption, color: ember.primary)),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 洞察底部 sheet(spec §7.1):62% 高升起、可拖至全屏;三 chip 切换
/// 待办/文件/后台面板。数据逻辑自 _InsightsRowState 整体平移——文件
/// 的 fire-once 预加载与 stale 重试语义保持(sheet 打开期间每个新完成
/// 回合只拉一次;选「文件」chip 时无数据才补拉)。公开给测试。
class InsightsSheet extends StatefulWidget {
  final ConversationState state;
  final ConversationTransport transport;
  final String sessionId;

  /// DraggableScrollableSheet 的滚动控制器,接入各面板主列表,让列表
  /// 区域的拖拽可以展开/收起 sheet。
  final ScrollController scrollController;

  const InsightsSheet({
    super.key,
    required this.state,
    required this.transport,
    required this.sessionId,
    required this.scrollController,
  });

  @override
  State<InsightsSheet> createState() => _InsightsSheetState();
}

class _InsightsSheetState extends State<InsightsSheet> {
  static const _todo = 0, _files = 1, _bg = 2;

  int _tab = _todo;

  dynamic _fileChanges;
  bool _filesLoading = false;
  String? _filesError;

  /// Turn (rowId) whose file changes are already loaded — the armed
  /// pattern mirrors the web client: each turn completing reloads once,
  /// whether or not the panel is open, so opening it always shows the
  /// latest turn's diff instantly.
  String? _loadedTurnKey;

  @override
  void initState() {
    super.initState();
    widget.state.addListener(_onStateChanged);
  }

  @override
  void didUpdateWidget(InsightsSheet oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.state != widget.state) {
      oldWidget.state.removeListener(_onStateChanged);
      widget.state.addListener(_onStateChanged);
    }
  }

  @override
  void dispose() {
    widget.state.removeListener(_onStateChanged);
    super.dispose();
  }

  void _onStateChanged() {
    final turn = latestCompletedTurn(widget.state.rows);
    final key = turn == null ? null : '${turn['rowId']}';
    if (key == null || key == _loadedTurnKey) return;
    _loadedTurnKey = key;
    _loadFiles();
  }

  void _selectTab(int index) {
    setState(() => _tab = index);
    // Skip when a prefetch for this turn is already in flight.
    if (_tab == _files &&
        !_filesLoading &&
        _fileChanges == null &&
        _filesError == null) {
      _loadFiles();
    }
  }

  /// File changes are turn-scoped: the target must be the turnHeader of a
  /// COMPLETED turn (the running turn's guard races the streaming
  /// revision). baseRevision/baseLogEpoch are read inside the transport.
  Future<void> _loadFiles() async {
    final target = latestCompletedTurn(widget.state.rows);
    if (target == null) {
      setState(() => _fileChanges = null);
      return;
    }
    setState(() {
      _filesLoading = true;
      _filesError = null;
    });
    // Fire-once per turn (armed): mark before awaiting so a failed load
    // doesn't retrigger on every streaming state notification — the
    // manual refresh stays available for retries.
    _loadedTurnKey = '${target['rowId']}';
    try {
      final res = await widget.transport.fileChanges(
        widget.sessionId,
        target: {'rowId': target['rowId'], 'entityId': target['entityId']},
      );
      if (!mounted) return;
      setState(() => _fileChanges = res);
    } catch (e) {
      if (!mounted) return;
      setState(() => _filesError = _fmtRpcError(e));
    } finally {
      if (mounted) setState(() => _filesLoading = false);
    }
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
    var n = deriveTodoSteps(widget.state.rows)?.length ?? 0;
    final planItems = parseInsightList(
        widget.state.plan ?? const {}, const ['items'], allowEmpty: false);
    // Plan-mode progress counts toward the chip when no TodoWrite todos
    // exist (the plan IS the active checklist then).
    if (n == 0 && planItems != null) n = planItems.length;
    return n;
  }

  int get _turnFileTotal {
    var total = 0;
    for (final r in widget.state.rows) {
      if (r['kind'] != 'turnHeader') continue;
      final fc = r['fileChanges'];
      if (fc is Map) {
        final n = fc['files'] as num?;
        if (n != null) total += n.toInt();
      }
    }
    return total;
  }

  int get _bgCount => insightsBgCount(
      backgroundWorks: widget.state.backgroundWorks,
      rows: widget.state.rows);

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

  Widget _chip(
      BuildContext context, int index, IconData icon, String label, int? count) {
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
                  color: selected ? EmberColors.of(context).primary : EmberColors.of(context).textSoft),
              const SizedBox(width: 4),
              Text(
                count != null ? '$label $count' : label,
                style: TextStyle(
                  fontSize: 11.5,
                  color: selected ? EmberColors.of(context).primary : EmberColors.of(context).textSoft,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _panelHeader(BuildContext context, String title, VoidCallback onRefresh,
      {bool loading = false}) {
    return Row(
      children: [
        Text(title,
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
        const Spacer(),
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

  Widget _jsonFallback(dynamic data) {
    const encoder = JsonEncoder.withIndent('  ');
    return SingleChildScrollView(
      controller: widget.scrollController,
      physics: const AlwaysScrollableScrollPhysics(),
      child: SelectableText(
        data == null ? '（无数据）' : encoder.convert(data),
        style: const TextStyle(fontFamily: 'monospace', fontSize: 10),
      ),
    );
  }

  // ------------------------------------------------------------ todo panel

  Widget _todoPanel(BuildContext context) {
    final steps = deriveTodoSteps(widget.state.rows);
    // Plan-mode progress from the conversation snapshot
    // (plan: {items: [{id, content, status: pending|inProgress|completed}],
    // updatedAt}). Displayed INSIDE the todo panel — progress of the
    // structured plan, not a separate surface.
    final planObj = widget.state.plan;
    final parsedPlanItems = planObj == null
        ? null
        : parseInsightList(planObj, const ['items'], allowEmpty: false);
    final planItems = (parsedPlanItems == null || parsedPlanItems.isEmpty)
        ? null
        : parsedPlanItems;
    final todoSteps = steps ?? const <PlanStep>[];
    final Widget body;
    if (todoSteps.isEmpty && planItems == null) {
      body = Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Text('暂无待办',
            style: TextStyle(fontSize: 11.5, color: EmberColors.of(context).textFaint)),
      );
    } else {
      body = ListView.builder(
        controller: widget.scrollController,
        physics: const AlwaysScrollableScrollPhysics(),
        shrinkWrap: true,
        // +1 slot is the plan-section header — only when a plan exists
        // (todos without a plan snapshot must not dereference it).
        itemCount: todoSteps.length +
            (planItems?.length ?? 0) +
            (planItems != null ? 1 : 0),
        itemBuilder: (context, i) {
          if (i < todoSteps.length) {
            final s = todoSteps[i];
            return Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  s.completed
                      ? Icons.check_circle
                      : s.inProgress
                          ? Icons.play_circle_outline
                          : Icons.radio_button_unchecked,
                  size: 14,
                  color: s.completed
                      ? EmberColors.of(context).ok
                      : s.inProgress
                          ? EmberColors.of(context).primary
                          : EmberColors.of(context).textFaint,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    s.title,
                    style: TextStyle(
                      fontSize: 11.5,
                      color: s.completed
                          ? EmberColors.of(context).textFaint
                          : EmberColors.of(context).textSolid,
                      decoration: s.completed ? TextDecoration.lineThrough : null,
                    ),
                  ),
                ),
              ],
            ),
          );
          }
          // Plan section header before the first plan item.
          if (i == todoSteps.length) {
            final done = planItems!
                .where((e) => '${e['status']}' == 'completed')
                .length;
            return Padding(
              padding: const EdgeInsets.only(top: 6, bottom: 2),
              child: Row(
                children: [
                  Icon(Icons.flag_outlined,
                      size: 12, color: EmberColors.of(context).primary),
                  const SizedBox(width: 5),
                  Text('计划进度 · $done / ${planItems.length}',
                      style: TextStyle(
                          fontSize: 10.5, color: EmberColors.of(context).textFaint)),
                ],
              ),
            );
          }
          final item =
              planItems![i - todoSteps.length - 1];
          final status = '${item['status']}';
          final completed = status == 'completed';
          final inProgress = status == 'inProgress';
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
                      ? EmberColors.of(context).ok
                      : inProgress
                          ? EmberColors.of(context).primary
                          : EmberColors.of(context).textFaint,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '${item['content'] ?? item['id'] ?? ''}',
                    style: TextStyle(
                      fontSize: 11.5,
                      color: completed
                          ? EmberColors.of(context).textFaint
                          : EmberColors.of(context).textSolid,
                      decoration:
                          completed ? TextDecoration.lineThrough : null,
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _panelHeader(context, '待办（最新 TodoWrite）', () {}),
        Flexible(child: body),
      ],
    );
  }

  // ----------------------------------------------------------- files panel

  Widget _filesPanel(BuildContext context) {
    final headers = widget.state.rows
        .where((r) =>
            r['kind'] == 'turnHeader' &&
            r['fileChanges'] is Map &&
            ((r['fileChanges'] as Map)['files'] as num? ?? 0) > 0)
        .toList()
        .reversed
        .toList();

    Widget body;
    if (_filesLoading) {
      body = const Center(
          child: SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 1.5)));
    } else if (_filesError != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _panelHeader(context, '文件', _loadFiles),
          _errorRow(_filesError!, _loadFiles),
        ],
      );
    } else {
      final entries = parseInsightList(
          _fileChanges, const ['files', 'changes', 'fileChanges', 'items'],
          allowEmpty: true);
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (headers.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(
                '最近回合：'
                '${headers.map((h) {
                  final fc = (h['fileChanges'] as Map).cast<String, dynamic>();
                  return '+${fc['additions'] ?? 0} −${fc['deletions'] ?? 0} · ${fc['files']} 文件';
                }).join('；')}',
                style:
                    TextStyle(fontSize: 10.5, color: EmberColors.of(context).textFaint),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          if (_fileChanges == null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text('暂无文件变更数据',
                  style:
                      TextStyle(fontSize: 11.5, color: EmberColors.of(context).textFaint)),
            )
          else if (entries == null)
            Flexible(child: _jsonFallback(_fileChanges))
          else if (entries.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text('本回合无文件变更',
                  style:
                      TextStyle(fontSize: 11.5, color: EmberColors.of(context).textFaint)),
            )
          else
            Flexible(
              child: ListView.builder(
                controller: widget.scrollController,
                physics: const AlwaysScrollableScrollPhysics(),
                shrinkWrap: true,
                itemCount: entries.length,
                itemBuilder: (context, i) =>
                    _fileTile(context, entries[i]),
              ),
            ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _panelHeader(context, '文件', _loadFiles, loading: _filesLoading),
        Flexible(child: body),
      ],
    );
  }

  void _showFileDetail(BuildContext context, Map<String, dynamic> e) {
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
                  style: const TextStyle(
                      fontSize: 11, fontFamily: 'monospace'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis),
            ),
            if (adds != null && dels != null)
              Text('+${adds.toInt()} −${dels.toInt()}',
                  style: TextStyle(
                      fontSize: 10.5, color: EmberColors.of(context).textFaint)),
            Icon(Icons.chevron_right, size: 14, color: EmberColors.of(context).textFaint),
          ],
        ),
      ),
    );
  }

  // ------------------------------------------------------------- bg panel

  String _fmtMs(num? v) {
    if (v == null) return '';
    final d = DateTime.fromMillisecondsSinceEpoch(v.toInt());
    return '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  }

  /// backgroundWorks entry: {workId, kind: bash|subagent, title,
  /// status: running|resultPending|failed|cancelled, startedAt(ms),
  /// endedAt?(ms), cancellable?, blocked?, childSessionId?}
  Widget _workTile(BuildContext context, Map<String, dynamic> w) {
    final status = '${w['status']}';
    final Widget leading;
    String suffix = '';
    if (status == 'running') {
      leading = const SizedBox(
          width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 1.5));
    } else if (status == 'failed') {
      leading = Icon(Icons.error_outline, size: 13, color: EmberColors.of(context).err);
      suffix = ' · 失败';
    } else if (status == 'cancelled') {
      leading = Icon(Icons.block, size: 13, color: EmberColors.of(context).warn);
      suffix = ' · 已取消';
    } else {
      leading = Icon(Icons.hourglass_bottom,
          size: 13, color: EmberColors.of(context).textFaint);
      suffix = ' · 待取结果';
    }
    final kindIcon = w['kind'] == 'bash' ? Icons.terminal : Icons.smart_toy_outlined;
    final endedAt = w['endedAt'];
    final startedAt = w['startedAt'];
    final time = endedAt != null
        ? ' · ${_fmtMs(endedAt as num?)} 结束'
        : startedAt != null
            ? ' · ${_fmtMs(startedAt as num?)} 开始'
            : '';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Icon(kindIcon, size: 13, color: EmberColors.of(context).textFaint),
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
        ],
      ),
    );
  }

  /// snapshot.subagents.running entry: {childSessionId, agentId?,
  /// toolCallId?, subagentType, title, summary?, status:
  /// running|waiting|blocked, startedAt?(ms)}
  Widget _subagentTile(BuildContext context, Map<String, dynamic> s) {
    final status = '${s['status']}';
    final Widget leading;
    if (status == 'running') {
      leading = const SizedBox(
          width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 1.5));
    } else if (status == 'blocked') {
      leading = Icon(Icons.lock_outline, size: 13, color: EmberColors.of(context).warn);
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
              style: TextStyle(fontSize: 11, color: EmberColors.of(context).textSoft),
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
  Widget _subagentRowTile(BuildContext context, Map<String, dynamic> r) {
    final status = '${r['status']}';
    final (leading, suffix) = switch (status) {
      'success' => (
        Icon(Icons.check_circle_outline,
            size: 13, color: EmberColors.of(context).ok),
        ' · 已完成'
      ),
      'failed' => (
        Icon(Icons.error_outline, size: 13, color: EmberColors.of(context).err),
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
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          leading,
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              '${summary.isEmpty ? '子代理 · ${r['subagentType'] ?? ''}' : summary}'
              '$suffix$time',
              style: TextStyle(fontSize: 11, color: EmberColors.of(context).textSoft),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  Widget _bgPanel(BuildContext context) {
    final works = widget.state.backgroundWorks;
    // Authoritative RUNNING subagent status lives in snapshot.subagents
    // {revision, childSessionIds, running[], endedTotal}; the snapshot never
    // lists finished subagents — their summary + terminal status live in
    // inline `subagent` rows (endedTotal only counts them). Inline running
    // rows are used only by streams without the snapshot field.
    final subsObj = widget.state.snapshot?['subagents'];
    final subs = subsObj is Map ? subsObj.cast<String, dynamic>() : null;
    final runningSubs =
        subs == null ? null : parseInsightList(subs['running'], const []);
    final endedTotal = (subs?['endedTotal'] as num?)?.toInt() ?? 0;
    final endedRows = endedSubagentRows(widget.state.rows);
    final fallbackRunningRows = subs == null
        ? widget.state.rows
            .where((r) => r['kind'] == 'subagent' && '${r['status']}' == 'running')
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
                style:
                    TextStyle(fontSize: 11.5, color: EmberColors.of(context).textFaint)),
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
              for (final w in works) _workTile(context, w),
              if ((runningSubs?.isNotEmpty ?? false) ||
                  fallbackRunningRows.isNotEmpty) ...[
                Padding(
                  padding: const EdgeInsets.only(top: 4, bottom: 2),
                  child: Text('运行中的子代理',
                      style: TextStyle(
                          fontSize: 10.5, color: EmberColors.of(context).textFaint)),
                ),
                if (runningSubs != null)
                  for (final s in runningSubs) _subagentTile(context, s),
                for (final r in fallbackRunningRows)
                  _subagentRowTile(context, r),
              ],
              if (endedRows.isNotEmpty) ...[
                Padding(
                  padding: const EdgeInsets.only(top: 4, bottom: 2),
                  child: Text('已结束的子代理',
                      style: TextStyle(
                          fontSize: 10.5, color: EmberColors.of(context).textFaint)),
                ),
                for (final r in endedRows) _subagentRowTile(context, r),
                // Rows outside the loaded window aren't available — the
                // snapshot count keeps the total honest.
                if (endedTotal > endedRows.length)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text('以及更早的 ${endedTotal - endedRows.length} 个子代理',
                        style: TextStyle(
                            fontSize: 10.5, color: EmberColors.of(context).textFaint)),
                  ),
              ] else if (endedTotal > 0)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text('已结束 $endedTotal 个子代理',
                      style: TextStyle(
                          fontSize: 10.5, color: EmberColors.of(context).textFaint)),
                ),
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
        border:
            Border.all(color: EmberColors.of(context).ok.withValues(alpha: 0.25)),
      ),
      child: Row(
        children: [
          Icon(Icons.flag_outlined,
              size: 14, color: EmberColors.of(context).ok),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              objective,
              style:
                  TextStyle(fontSize: 12, color: EmberColors.of(context).textSoft),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (status.isNotEmpty)
            Text(status,
                style: TextStyle(
                    fontSize: 11, color: EmberColors.of(context).ok)),
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
              style:
                  TextStyle(fontSize: 11.5, color: EmberColors.of(context).textSoft),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

class _QueueBar extends StatelessWidget {
  final ConversationState state;
  final ConversationTransport transport;

  const _QueueBar({required this.state, required this.transport});

  @override
  Widget build(BuildContext context) {
    final items = state.queueItems;
    if (items.isEmpty) return const SizedBox.shrink();
    final sessionId = state.snapshot?['sessionId'] as String? ?? '';
    return Container(
      margin: const EdgeInsets.fromLTRB(14, 4, 14, 0),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: EmberColors.of(context).primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border:
            Border.all(color: EmberColors.of(context).primary.withValues(alpha: 0.25)),
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
                      fontSize: 12,
                      color: EmberColors.of(context).primary)),
              const Spacer(),
              InkWell(
                onTap: () {
                  final next = !state.autoDrain;
                  state.optimisticPatch({
                    'queue': {...?state.queue, 'autoDrain': next},
                  });
                  transport.setAutoDrain(sessionId, next);
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
                          fontSize: 12, color: EmberColors.of(context).textSoft),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  _QueueAction(
                    icon: Icons.play_arrow,
                    tooltip: '立即发送',
                    onTap: () {
                      final id = '${item['queueItemId']}';
                      state.optimisticRemoveQueueItem(id);
                      transport.sendQueuedNow(sessionId, id);
                    },
                  ),
                  _QueueAction(
                    icon: Icons.edit_outlined,
                    tooltip: '编辑',
                    onTap: () => _edit(context, sessionId, item),
                  ),
                  _QueueAction(
                    icon: Icons.close,
                    tooltip: '删除',
                    onTap: () async {
                      final id = '${item['queueItemId']}';
                      final confirmed = await showDialog<bool>(
                        context: context,
                        builder: (context) => AlertDialog(
                          title: const Text('删除排队消息？'),
                          content: Text(
                              '将删除「${item['text'] ?? ''}」',
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis),
                          actions: [
                            TextButton(
                                onPressed: () =>
                                    Navigator.pop(context, false),
                                child: const Text('取消')),
                            FilledButton(
                              style: FilledButton.styleFrom(
                                  backgroundColor: EmberColors.of(context).err),
                              onPressed: () =>
                                  Navigator.pop(context, true),
                              child: const Text('删除'),
                            ),
                          ],
                        ),
                      );
                      if (confirmed != true) return;
                      state.optimisticRemoveQueueItem(id);
                      transport.deleteQueueItem(sessionId, id);
                    },
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _edit(BuildContext context, String sessionId,
      Map<String, dynamic> item) async {
    final controller =
        TextEditingController(text: '${item['text'] ?? ''}');
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
              onPressed: () => Navigator.pop(context),
              child: const Text('取消')),
          FilledButton(
              onPressed: () =>
                  Navigator.pop(context, controller.text.trim()),
              child: const Text('保存')),
        ],
      ),
    );
    controller.dispose();
    if (text == null || text.isEmpty) return;
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
    await transport.editQueueItem(
        sessionId, '${item['queueItemId']}', text);
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
  final List<_PendingFile> files;
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

class _PendingInteractions extends StatelessWidget {
  final ConversationState state;
  final ConversationTransport transport;

  const _PendingInteractions({required this.state, required this.transport});

  @override
  Widget build(BuildContext context) {
    final interactions = state.pendingInteractions;
    if (interactions.isEmpty) return const SizedBox.shrink();
    final sessionId = state.snapshot?['sessionId'] as String? ?? '';
    return Column(
      children: [
        for (final interaction in interactions)
          _InteractionCard(
            interaction: interaction,
            onResolve: ({optionId, freeText, action, content}) =>
                transport.resolveInteraction(
              sessionId,
              interaction['interactionId'] as String? ?? '',
              optionId: optionId,
              freeText: freeText,
              action: action,
              content: content,
            ),
          ),
      ],
    );
  }
}

class _InteractionCard extends StatefulWidget {
  final Map<String, dynamic> interaction;
  final Future<dynamic> Function({
    String? optionId,
    String? freeText,
    String? action,
    Map<String, dynamic>? content,
  }) onResolve;

  const _InteractionCard({required this.interaction, required this.onResolve});

  @override
  State<_InteractionCard> createState() => _InteractionCardState();
}

class _InteractionCardState extends State<_InteractionCard> {
  final _freeTextController = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
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
    setState(() => _busy = true);
    try {
      await widget.onResolve(
          optionId: optionId,
          freeText: freeText,
          action: action,
          content: content);
    } catch (_) {
    } finally {
      if (mounted) setState(() => _busy = false);
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

    final title = kind == 'permission'
        ? '权限请求 · ${payload['toolName'] ?? ''}'
        : '等待你的输入';

    final ember = EmberColors.of(context);
    return Container(
      margin: const EdgeInsets.fromLTRB(14, 4, 14, 0),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: ember.primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border:
            Border.all(color: ember.primary.withValues(alpha: 0.55)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.privacy_tip_outlined,
                  size: 14, color: ember.primary),
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
                              ? _resolve(
                                  optionId: '${option['optionId']}')
                              : _resolve(
                                  action: 'accept', content: {}),
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
                      : () => _resolve(
                          freeText: _freeTextController.text.trim()),
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
            selected: _answers['${widget.questions[i]['question']}']
                ?? const <String>[],
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

// ---------------------------------------------------------------- sheets

class _ModelModeSheet extends StatefulWidget {
  final ConversationState? state;
  final ConversationTransport transport;
  final WorkspacePrep? prep;
  final String? sessionId;
  final Map<String, String>? draftConfig;
  final void Function(String key, String value)? onDraftChange;

  const _ModelModeSheet({
    required this.state,
    required this.transport,
    this.prep,
    this.sessionId,
    this.draftConfig,
    this.onDraftChange,
  });

  @override
  State<_ModelModeSheet> createState() => _ModelModeSheetState();
}

/// Stateful 的原因:面板内点选必须立即反映(此前 StatelessWidget 只在
/// 重开面板时才看到新值);草稿选择镜像在 [_draft],会话态变化经
/// AnimatedBuilder 跟进。
class _ModelModeSheetState extends State<_ModelModeSheet> {
  late final Map<String, String> _draft = Map.of(widget.draftConfig ?? const {});

  bool get _isDraft => widget.sessionId == null || widget.sessionId!.isEmpty;

  void _setDraft(String key, String value) {
    setState(() => _draft[key] = value);
    widget.onDraftChange?.call(key, value);
  }

  /// Config options beyond the model/mode/thought selects (e.g. max output
  /// length, search enhancement) surfaced read-only from prepareWorkspace.
  List<ConfigOption> get _otherOptions {
    const known = {'model', 'mode', 'thought_level'};
    final options = widget.prep?.configOptions;
    if (options == null) return const [];
    return options.where((o) => !known.contains(o.id)).toList();
  }

  /// 'builtin:zai-coding-plan/GLM-5.2' → (provider, model)
  (String, String) _splitModelValue(String value) {
    final idx = value.lastIndexOf('/');
    if (idx <= 0) return (value, value);
    return (value.substring(0, idx), value.substring(idx + 1));
  }

  @override
  Widget build(BuildContext context) {
    // 会话态驱动(乐观补丁/宿主确认)时整面板跟随重建;draft 态由
    // _setDraft 的 setState 驱动。
    final state = widget.state;
    if (state != null) {
      return AnimatedBuilder(
          animation: state, builder: (context, _) => _content(context));
    }
    return _content(context);
  }

  Widget _content(BuildContext context) {
    final sid = widget.sessionId ?? '';
    final config = widget.state?.config ?? const {};
    final modelOption = widget.prep?.option('model');
    final thoughtOption = widget.prep?.option('thought_level');
    final followup = '${config['followupMode'] ?? 'queue'}';

    // Current selection: prefer the LIVE session config (updates after a
    // switch), fall back to prepareWorkspace's currentValue / draft.
    final liveModelValue =
        '${config['provider'] ?? ''}/${config['model'] ?? ''}';
    final currentModelValue =
        _isDraft || config['model'] == null || '${config['model']}'.isEmpty
            ? (_draft['model'] ??
                '${modelOption?.currentValue ?? ''}')
            : liveModelValue;
    final currentThoughtValue = _isDraft
        ? (_draft['thought'] ??
            '${thoughtOption?.currentValue ?? ''}')
        : (widget.state?.currentThought.isNotEmpty == true
            ? widget.state!.currentThought
            : '${thoughtOption?.currentValue ?? ''}');
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_isDraft ? '新会话 · 模型' : '模型',
                style: const TextStyle(
                    fontSize: 16, fontWeight: FontWeight.w600)),
            const SizedBox(height: 16),
            const SizedBox(height: 12),
            if (thoughtOption != null &&
                thoughtOption.options.isNotEmpty) ...[
              Text(thoughtOption.name,
                  style: const TextStyle(fontSize: 13)),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: [
                  for (final v in thoughtOption.options)
                    ChoiceChip(
                      label: Text(v.name),
                      selected: currentThoughtValue == v.value ||
                          widget.state?.currentThought == v.value,
                      onSelected: (_) {
                        if (_isDraft) {
                          _setDraft('thought', v.value);
                        } else {
                          final modelValue = currentModelValue;
                          final (provider, model) =
                              modelValue.isNotEmpty
                                  ? _splitModelValue(modelValue)
                                  : (
                                      '${config['provider'] ?? ''}',
                                      '${config['model'] ?? ''}'
                                    );
                          _apply(
                            context,
                            () => widget.transport.switchModelConfig(
                              sid,
                              provider: provider,
                              model: model,
                              thought: v.value,
                            ),
                            onAccepted: () => widget.state?.optimisticPatch({
                              'config': {
                                ...?widget.state!.config,
                                'thought': v.value,
                              },
                            }),
                          );
                        }
                      },
                    ),
                ],
              ),
            ] else if ((widget.state?.thoughtLevels ?? const []).isNotEmpty) ...[
              const Text('思考等级', style: TextStyle(fontSize: 13)),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: [
                  for (final level in widget.state!.thoughtLevels)
                    ChoiceChip(
                      label: Text(level),
                      selected: widget.state?.currentThought == level,
                      onSelected: (_) => _apply(
                        context,
                        () => widget.transport.switchModelConfig(
                          sid,
                          provider: '${config['provider'] ?? ''}',
                          model: '${config['model'] ?? ''}',
                          thought: level,
                        ),
                      ),
                    ),
                ],
              ),
            ],
            const SizedBox(height: 12),
            if (modelOption != null && modelOption.options.isNotEmpty) ...[
              Text(modelOption.name,
                  style: const TextStyle(fontSize: 13)),
              const SizedBox(height: 8),
              for (final v in modelOption.options)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    currentModelValue == v.value
                        ? Icons.radio_button_checked
                        : Icons.radio_button_off,
                    size: 18,
                    color: currentModelValue == v.value
                        ? EmberColors.of(context).primary
                        : EmberColors.of(context).textFaint,
                  ),
                  title: Text(v.name,
                      style: const TextStyle(fontSize: 13)),
                  subtitle: v.modelProviderName != null
                      ? Text(v.modelProviderName!,
                          style: TextStyle(
                              fontSize: 11, color: EmberColors.of(context).textFaint))
                      : null,
                  onTap: () {
                    if (_isDraft) {
                      _setDraft('model', v.value);
                    } else {
                      final (provider, model) =
                          _splitModelValue(v.value);
                      // thought must be valid for the target model:
                      // keep current if supported, else fall back to the
                      // thought option's currentValue (Turbo: enabled/off)
                      final currentThought =
                          widget.state?.currentThought ?? '';
                      final thoughtOpt = widget.prep?.option('thought_level');
                      final thought = currentThought.isNotEmpty &&
                              (thoughtOpt?.options.any(
                                      (o) => o.value == currentThought) ??
                                  false)
                          ? currentThought
                          : '${thoughtOpt?.currentValue ?? (currentThought.isNotEmpty ? currentThought : 'enabled')}';
                      _apply(
                        context,
                        () => widget.transport.switchModelConfig(
                          sid,
                          provider: provider,
                          model: model,
                          thought: thought,
                        ),
                        onAccepted: () => widget.state?.optimisticPatch({
                          'config': {
                            ...?widget.state!.config,
                            'provider': provider,
                            'model': model,
                            'thought': thought,
                          },
                        }),
                      );
                    }
                  },
                ),
            ] else
              Text('当前模型: ${widget.state?.currentModel ?? ''}',
                  style: TextStyle(
                      fontSize: 12, color: EmberColors.of(context).textMuted)),
            if (!_isDraft) ...[
              const SizedBox(height: 16),
              const Text('后续消息', style: TextStyle(fontSize: 13)),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: [
                for (final f in const ['queue', 'guide'])
                  ChoiceChip(
                    label: Text(f == 'queue' ? '排队' : '引导'),
                    selected: followup == f,
                    onSelected: (_) => _apply(
                      context,
                      () => widget.transport.setFollowupMode(sid, f),
                      onAccepted: () => widget.state?.optimisticPatch({
                        'config': {
                          ...?widget.state!.config,
                          'followupMode': f,
                        },
                      }),
                    ),
                  ),
                ],
              ),
            ],
            if (_otherOptions.isNotEmpty) ...[
              const SizedBox(height: 16),
              const Text('其他配置', style: TextStyle(fontSize: 13)),
              const SizedBox(height: 8),
              for (final o in _otherOptions)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Text(o.name,
                            style: const TextStyle(fontSize: 13)),
                      ),
                      const SizedBox(width: 8),
                      Text('${o.currentValue}',
                          style: TextStyle(
                              fontSize: 12, color: EmberColors.of(context).textMuted)),
                    ],
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _apply(
    BuildContext context,
    Future<dynamic> Function() run, {
    void Function()? onAccepted,
  }) async {
    try {
      final res = await run();
      if (context.mounted) {
        if (res is Map &&
            res['status'] != null &&
            res['status'] != 'accepted') {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content:
                  Text('被拒绝: ${res['reasonCode'] ?? res['status']}')));
        } else {
          onAccepted?.call();
          Navigator.pop(context);
        }
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('失败: $e')));
      }
    }
  }
}

class _UsageSheet extends StatelessWidget {
  final ConversationState state;
  final BridgeSession session;
  final Map<String, dynamic> scope;
  final String sessionId;

  const _UsageSheet({
    required this.state,
    required this.session,
    required this.scope,
    required this.sessionId,
  });

  @override
  Widget build(BuildContext context) {
    final usage = state.usage ?? const {};
    final cumulative = usage['cumulative'];
    final contextWindow = usage['contextWindow'];
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('用量统计',
                style:
                    TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            const SizedBox(height: 16),
            if (contextWindow is Map) ...[
              _UsageRow('上下文',
                  '${contextWindow['usedTokens'] ?? '-'} / ${contextWindow['maxTokens'] ?? '-'} tokens'),
            ],
            if (cumulative is Map) ...[
              _UsageRow('累计输入', '${cumulative['inputTokens'] ?? 0}'),
              _UsageRow('累计输出', '${cumulative['outputTokens'] ?? 0}'),
              _UsageRow(
                  '缓存读取', '${cumulative['cacheReadTokens'] ?? 0}'),
              _UsageRow(
                  '缓存写入', '${cumulative['cacheWriteTokens'] ?? 0}'),
            ],
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                icon: const Icon(Icons.query_stats, size: 16),
                label: const Text('查询任务级用量 (getTaskTokenUsage)'),
                onPressed: () async {
                  try {
                    final res = await session.channels.call(
                      Channels.zcodeTask,
                      'getTaskTokenUsage',
                      [
                        {...scope, 'taskId': sessionId},
                      ],
                    );
                    if (context.mounted) {
                      showModalBottomSheet(
                        context: context,
                        builder: (context) =>
                            _JsonSheet(title: '任务用量', data: res),
                      );
                    }
                  } catch (e) {
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('查询失败: $e')));
                    }
                  }
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _UsageRow extends StatelessWidget {
  final String label;
  final String value;

  const _UsageRow(this.label, this.value);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label,
              style:
                  TextStyle(fontSize: 13, color: EmberColors.of(context).textMuted)),
          Text(value,
              style: const TextStyle(
                  fontSize: 13, fontFamily: 'monospace')),
        ],
      ),
    );
  }
}

class _JsonSheet extends StatelessWidget {
  final String title;
  final Object? data;

  const _JsonSheet({required this.title, required this.data});

  @override
  Widget build(BuildContext context) {
    const encoder = JsonEncoder.withIndent('  ');
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title,
                style: const TextStyle(
                    fontSize: 16, fontWeight: FontWeight.w600)),
            const SizedBox(height: 12),
            Flexible(
              child: SingleChildScrollView(
                child: SelectableText(
                  data == null ? '（无数据）' : encoder.convert(data),
                  style: const TextStyle(
                      fontFamily: 'monospace', fontSize: 11),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- input

/// One entry in the slash popup: a builtin/custom command or a skill.
class _SlashItem {
  final String name;
  final String description;
  final String insert;
  final bool isSkill;

  const _SlashItem({
    required this.name,
    required this.description,
    required this.insert,
    this.isSkill = false,
  });
}

class _SlashCommandBar extends StatelessWidget {
  final String query;
  final List<_SlashItem> items;
  final void Function(_SlashItem item) onSelect;

  const _SlashCommandBar({
    required this.query,
    required this.items,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    final q = query.startsWith('/') || query.startsWith('\$')
        ? query.substring(1)
        : query;
    final filtered = q.isEmpty
        ? items
        : items
            .where((c) => c.name.toLowerCase().startsWith(q.toLowerCase()))
            .toList();
    if (filtered.isEmpty) {
      return Container(
        margin: const EdgeInsets.fromLTRB(14, 4, 14, 0),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text('没有匹配的命令',
            style: TextStyle(fontSize: 12, color: EmberColors.of(context).textFaint)),
      );
    }
    return Container(
      margin: const EdgeInsets.fromLTRB(14, 4, 14, 0),
      constraints: const BoxConstraints(maxHeight: 260),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
        border:
            Border.all(color: Colors.white.withValues(alpha: 0.1)),
      ),
      child: ListView(
        shrinkWrap: true,
        children: [
          for (final command in filtered)
            ListTile(
              dense: true,
              leading: Icon(
                command.isSkill
                    ? Icons.auto_awesome_outlined
                    : (command.name == 'compact'
                        ? Icons.compress
                        : Icons.bolt),
                size: 16,
                color: command.isSkill
                    ? EmberColors.of(context).warn
                    : EmberColors.of(context).primary,
              ),
              title: Text(
                command.isSkill ? '\$${command.name}' : '/${command.name}',
                style: const TextStyle(
                    fontSize: 13, fontFamily: 'monospace')),
              subtitle: Text(
                command.description,
                style: TextStyle(
                    fontSize: 11, color: EmberColors.of(context).textFaint),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              onTap: () => onSelect(command),
            ),
        ],
      ),
    );
  }
}

/// 输入框左侧的协作模式按钮(U2):紧凑胶囊,展示当前模式名,
/// 点击弹出模式菜单。modeLabel 为空时不渲染。
class _ModeButton extends StatelessWidget {
  final String? label;
  final VoidCallback? onTap;

  const _ModeButton({this.label, this.onTap});

  @override
  Widget build(BuildContext context) {
    if (label == null || label!.isEmpty) return const SizedBox.shrink();
    final colors = EmberColors.of(context);
    return InkWell(
      borderRadius: BorderRadius.circular(EmberRadius.control),
      onTap: onTap,
      child: Container(
        height: 36,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(EmberRadius.control),
          border: Border.all(color: colors.hairline),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.bolt, size: 15, color: colors.primary),
          const SizedBox(width: 3),
          Text(label!,
              style: TextStyle(
                  fontSize: EmberType.caption,
                  fontWeight: FontWeight.w600,
                  color: colors.textMuted)),
        ]),
      ),
    );
  }
}

/// "+"面板(U2):斜杠命令 / Skills / 附件 三段合一。
class _PlusSheet extends StatelessWidget {
  final List<_SlashItem> slashItems;
  final bool loading;
  final void Function(String insert) onSelect;
  final VoidCallback onAttach;
  final Future<void> Function() onRefresh;

  const _PlusSheet({
    required this.slashItems,
    required this.loading,
    required this.onSelect,
    required this.onAttach,
    required this.onRefresh,
  });

  @override
  Widget build(BuildContext context) {
    final colors = EmberColors.of(context);
    final commands =
        slashItems.where((i) => !i.isSkill).toList(growable: false);
    final skills =
        slashItems.where((i) => i.isSkill).toList(growable: false);
    Widget section(String title, List<_SlashItem> items) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 10, 20, 4),
              child: Text(title,
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: colors.textMuted)),
            ),
            if (items.isEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 6),
                child: Text('无',
                    style: TextStyle(
                        fontSize: 12, color: colors.textFaint)),
              )
            else
              for (final item in items)
                ListTile(
                  dense: true,
                  leading: Text(item.isSkill ? r'$' : '/',
                      style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          fontFamily: EmberFonts.term,
                          color: colors.primary)),
                  title: Text(item.name,
                      style: const TextStyle(fontSize: 13)),
                  subtitle: item.description.isNotEmpty
                      ? Text(item.description,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 11, color: colors.textFaint))
                      : null,
                  onTap: () => onSelect(item.insert),
                ),
          ],
        );

    return SafeArea(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Row(children: [
              const Text('插入',
                  style:
                      TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
              const Spacer(),
              IconButton(
                icon: Icon(Icons.refresh,
                    size: 18, color: colors.textMuted),
                tooltip: '刷新',
                onPressed: onRefresh,
              ),
            ]),
          ),
        ),
        if (loading)
          const Padding(
            padding: EdgeInsets.all(16),
            child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
          )
        else ...[
          Flexible(
            child: SingleChildScrollView(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    section('斜杠命令', commands),
                    section('Skills', skills),
                  ]),
            ),
          ),
          ListTile(
            leading: Icon(Icons.attach_file, size: 20, color: colors.textMuted),
            title: const Text('附件',
                style: TextStyle(fontSize: 13)),
            onTap: onAttach,
          ),
          const SizedBox(height: 8),
        ],
      ]),
    );
  }
}

class _InputBar extends StatefulWidget {
  final TextEditingController controller;
  final bool sending;
  final VoidCallback onSend;
  final VoidCallback onAttach;
  final VoidCallback onPlusMenu;

  /// 当前协作模式展示名(空则不渲染模式按钮)与菜单回调(U2)。
  final String? modeLabel;
  final VoidCallback? onPickMode;

  const _InputBar({
    required this.controller,
    required this.sending,
    required this.onSend,
    required this.onAttach,
    this.modeLabel,
    this.onPickMode,
    required this.onPlusMenu,
  });

  @override
  State<_InputBar> createState() => _InputBarState();
}

class _InputBarState extends State<_InputBar> {
  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 6, 14, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            _ModeButton(
              label: widget.modeLabel,
              onTap: widget.sending ? null : widget.onPickMode,
            ),
            IconButton(
              icon: Icon(Icons.add_circle_outline,
                  size: 22, color: EmberColors.of(context).textMuted),
              tooltip: 'Skills / 命令 / 附件',
              onPressed: widget.sending ? null : widget.onPlusMenu,
            ),
            Expanded(
              child: TextField(
                controller: widget.controller,
                minLines: 1,
                maxLines: 5,
                style: const TextStyle(fontSize: 14),
                decoration: const InputDecoration(
                  hintText: '向 ZCode 发送消息…',
                ),
                textInputAction: TextInputAction.newline,
              ),
            ),
            const SizedBox(width: 10),
            Container(
              decoration: BoxDecoration(
                color: EmberColors.of(context).primary,
                shape: BoxShape.circle,
              ),
              child: IconButton(
                onPressed: widget.sending ? null : widget.onSend,
                icon: widget.sending
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white),
                      )
                    : const Icon(Icons.arrow_upward,
                        color: Colors.white, size: 20),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
