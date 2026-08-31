part of '../chat_page.dart';

/// 聊天页的异步/状态所有权:source 绑定与 generation 守卫、会话订阅
/// 生命周期、发送/重试状态机(echo)、prepareWorkspace/skills/draft 偏好、
/// 历史分页、标题推送与管理命令 RPC。视图(_ChatPageState)只保留
/// 输入框、滚动、菜单与对话框,数据变更经 [onChanged] 请求重绘;toast
/// 与 held-queue 处置对话框经回调上抛,提示与交互仍在视图层。
class ChatController {
  ChatController({
    required BridgeSession session,
    required Map<String, dynamic> scope,
    required this.workspaceKey,
    required this.onChanged,
    required this.onToast,
    this.onSessionInfo,
    this.onRowsChanged,
    String? sessionId,
  })  : _scope = scope,
        _sessionId = sessionId {
    transport = session.conversation(_scope);
  }

  /// createSession 的目标工作区键(widget.workspaceKey;不在 scope 里)。
  String workspaceKey;

  /// 数据变更通知(视图接 setState)。
  final void Function() onChanged;

  /// 用户可见错误提示(视图接 SnackBar)。
  final void Function(String message) onToast;

  /// 宿主标题推送回调(null = Scaffold 模式,不订阅标题)。
  final void Function(String sessionId, String title)? onSessionInfo;

  /// 订阅行/控制面变化(视图接滚动跟随)。
  final void Function()? onRowsChanged;

  BridgeSession get session => transport.session;
  late ConversationTransport transport;
  Map<String, dynamic> _scope;
  String? _sessionId;

  String? get sessionId => _sessionId;
  ConversationState? get state => _subscription?.state;

  bool _disposed = false;

  ConversationSubscription? _subscription;
  String? error;
  bool sending = false;

  /// Monotonic source generation. A source is the widget bridge/scope/session
  /// tuple; every source switch invalidates callbacks from the previous one.
  int _sourceGeneration = 0;
  int _subscribeGeneration = 0;
  Future<void>? _subscriptionOperation;
  int _historyGeneration = 0;
  int _filePickGeneration = 0;
  int _sendGeneration = 0;
  int _runGeneration = 0;
  int _sideChatGeneration = 0;
  int _skillsGeneration = 0;
  int _titleGeneration = 0;
  int _draftPrefsGeneration = 0;
  int _fileChangesGeneration = 0;
  Future<void> _draftPrefsSaveChain = Future.value();

  /// 文件变更操作代数(行级延迟操作经 begin/isCurrent 校验)。
  int get fileChangesGeneration => _fileChangesGeneration;

  /// 当前 source 代数(视图在打开 sheet/菜单时捕获快照用)。
  int get sourceGeneration => _sourceGeneration;

  bool isCurrentSource(
    int generation,
    ConversationTransport transport, {
    String? sessionId,
    ConversationSubscription? subscription,
  }) {
    return !_disposed &&
        generation == _sourceGeneration &&
        identical(transport, this.transport) &&
        (sessionId == null || sessionId == _sessionId) &&
        (subscription == null || identical(subscription, _subscription));
  }

  bool isCurrentOperation(
    int sourceGeneration,
    int operationGeneration,
    int currentOperationGeneration,
    ConversationTransport transport, {
    String? sessionId,
  }) {
    return isCurrentSource(sourceGeneration, transport, sessionId: sessionId) &&
        operationGeneration == currentOperationGeneration;
  }

  bool isCurrentForSource(
    int sourceGeneration,
    ConversationTransport transport, {
    String? sessionId,
  }) =>
      isCurrentSource(sourceGeneration, transport, sessionId: sessionId);

  int beginFileChangesOperation() => ++_fileChangesGeneration;

  String requireSession() {
    final sessionId = _sessionId;
    if (sessionId == null) throw StateError('尚无会话');
    return sessionId;
  }

  /// 作废全部在途操作(换源/销毁)。滚动代数是视图私有,由视图自行失效。
  void _invalidateOperations() {
    _sourceGeneration++;
    _subscribeGeneration++;
    _historyGeneration++;
    _filePickGeneration++;
    _sendGeneration++;
    _runGeneration++;
    _sideChatGeneration++;
    _skillsGeneration++;
    _titleGeneration++;
    _draftPrefsGeneration++;
    _fileChangesGeneration++;
  }

  // ------------------------------------------------------- subscription

  void _retireCurrentSubscription() {
    final subscription = _subscription;
    if (subscription == null) return;
    _detachSubscription(subscription);
    _subscriptionOperation = (_subscriptionOperation ?? Future<void>.value())
        .then<void>((_) async {
      await subscription.dispose();
    });
  }

  void _detachSubscription(ConversationSubscription subscription) {
    subscription.state.rowsListenable.removeListener(_fireRowsChanged);
    subscription.state.rowsListenable.removeListener(_dedupeEchoes);
    subscription.state.controlListenable.removeListener(_dedupeEchoes);
    if (identical(_subscription, subscription)) {
      _subscription = null;
      loadingOlder = false;
    }
  }

  void _fireRowsChanged() {
    onRowsChanged?.call();
  }

  Future<void> subscribe() async {
    final sessionId = _sessionId;
    if (sessionId == null) return;
    final sourceGeneration = _sourceGeneration;
    final subscribeGeneration = ++_subscribeGeneration;
    final transport = this.transport;
    _retireCurrentSubscription();

    Future<void> start() async {
      ConversationSubscription? sub;
      try {
        if (!isCurrentOperation(sourceGeneration, subscribeGeneration,
            _subscribeGeneration, transport,
            sessionId: sessionId)) {
          return;
        }
        sub = await transport
            .subscribe(sessionId)
            .timeout(const Duration(seconds: 60));
        if (!isCurrentOperation(sourceGeneration, subscribeGeneration,
            _subscribeGeneration, transport,
            sessionId: sessionId)) {
          _detachSubscription(sub);
          await sub.dispose();
          return;
        }
        final previous = _subscription;
        if (previous != null) {
          _detachSubscription(previous);
          await previous.dispose();
          if (!isCurrentOperation(sourceGeneration, subscribeGeneration,
              _subscribeGeneration, transport,
              sessionId: sessionId)) {
            await sub.dispose();
            return;
          }
        }
        _subscription = sub;
        error = null;
        _notify();
        if (onRowsChanged != null) {
          sub.state.rowsListenable.addListener(_fireRowsChanged);
        }
        sub.state.rowsListenable.addListener(_dedupeEchoes);
        sub.state.controlListenable.addListener(_dedupeEchoes);
        if (sub.state.canLoadOlder) unawaited(loadOlder());
      } catch (e) {
        if (isCurrentOperation(sourceGeneration, subscribeGeneration,
            _subscribeGeneration, transport,
            sessionId: sessionId)) {
          error = '$e';
          _notify();
        }
        if (sub != null) {
          _detachSubscription(sub);
          await sub.dispose();
        }
      }
    }

    final previousOperation = _subscriptionOperation?.catchError((_) {});
    final operation = previousOperation == null
        ? start()
        : previousOperation.then<void>((_) => start());
    _subscriptionOperation = operation.catchError((_) {});
    await operation;
  }

  // --------------------------------------------------------------- echo

  /// Optimistic echoes for just-sent messages: shown the moment the user
  /// hits send, retired once the server's userInput row arrives (see
  /// [removeEchoedTexts]). Status evolves sending → sent; a failed echo
  /// stays for tap-to-retry and is never auto-retired. Never enters
  /// protocol rows/revisions.
  final List<Map<String, dynamic>> _echoes = [];

  List<Map<String, dynamic>> get echoes => _echoes;

  /// 发送已被宿主接受、但订阅侧行数据尚未到达的窗口。此间最新的已发送
  /// 气泡与状态胶囊按「处理中/工作中」乐观显示——工作区桥降级冻结时,
  /// 订阅行可能数十秒后才整体冲刷,反馈不能干等(真机实测)。
  bool turnPending = false;

  /// 历史前插的滚动提示(视图在 post-frame 滚动回调里消费并清除)。
  bool prependScrollPending = false;
  Map<String, dynamic>? prependTailRow;

  void _dedupeEchoes() {
    final state = this.state;
    if (state == null) return;
    if (turnPending &&
        (state.rows.isNotEmpty ||
            (state.phase.isNotEmpty && state.phase != 'draft'))) {
      // 轮次已在订阅侧物化(行到达或相位离开 draft),乐观窗口结束。
      turnPending = false;
      _notify();
    }
    if (_echoes.isEmpty) return;
    final kept = removeEchoedTexts(_echoes, state.rows);
    if (kept.length != _echoes.length) {
      _echoes
        ..clear()
        ..addAll(kept);
      _notify();
    }
  }

  // ------------------------------------------------------------- remote ops

  Future<void> run(String errorPrefix, Future<dynamic> Function() run) async {
    final sourceGeneration = _sourceGeneration;
    final operationGeneration = ++_runGeneration;
    final transport = this.transport;
    final sessionId = _sessionId;
    if (!isCurrentOperation(sourceGeneration, operationGeneration,
        _runGeneration, transport,
        sessionId: sessionId)) {
      return;
    }
    try {
      final res = await run();
      if (!isCurrentOperation(sourceGeneration, operationGeneration,
          _runGeneration, transport,
          sessionId: sessionId)) {
        return;
      }
      if (isRpcRejected(res)) {
        onToast('$errorPrefix: ${rpcFailureReason(res)}');
      }
    } catch (e) {
      if (isCurrentOperation(sourceGeneration, operationGeneration,
          _runGeneration, transport,
          sessionId: sessionId)) {
        onToast('$errorPrefix: $e');
      }
    }
  }

  Future<void> compact() =>
      run('压缩失败', () => transport.compact(requireSession()));

  Future<void> pauseGoal() =>
      run('暂停目标失败', () => transport.pauseGoal(requireSession()));

  Future<void> resumeGoal() =>
      run('恢复目标失败', () => transport.resumeGoal(requireSession()));

  Future<void> stop() =>
      run('停止失败', () => transport.stop(requireSession()));

  /// Opens an auxiliary (side) chat attached to the current session
  /// (`createSelectionSideSession`)。返回新会话 id;源已失效/失败返回
  /// null(失败已 toast)。
  Future<String?> createSideSession() async {
    final sessionId = _sessionId;
    if (sessionId == null) return null;
    final sourceGeneration = _sourceGeneration;
    final operationGeneration = ++_sideChatGeneration;
    final transport = this.transport;
    try {
      final sideId = await transport.createSelectionSideSession(sessionId);
      if (!isCurrentOperation(
          sourceGeneration, operationGeneration, _sideChatGeneration, transport,
          sessionId: sessionId)) {
        return null;
      }
      return sideId;
    } catch (e) {
      if (isCurrentOperation(
          sourceGeneration, operationGeneration, _sideChatGeneration, transport,
          sessionId: sessionId)) {
        onToast('打开辅助对话失败: $e');
      }
      return null;
    }
  }

  // ------------------------------------------------------------- sending

  bool loadingOlder = false;
  String? progress;
  final List<_PendingFile> _pendingFiles = [];

  List<_PendingFile> get pendingFiles => _pendingFiles;

  void removePendingFileAt(int index) {
    _pendingFiles.removeAt(index);
    _notify();
  }

  double? uploadProgress;

  Future<void> pickFiles() async {
    final sourceGeneration = _sourceGeneration;
    final filePickGeneration = ++_filePickGeneration;
    final transport = this.transport;
    try {
      final files = await FilePicker.pickFiles();
      if (!isCurrentOperation(
          sourceGeneration, filePickGeneration, _filePickGeneration, transport)) {
        return;
      }
      final picked = <_PendingFile>[];
      for (final file in files) {
        final bytes = await file.readAsBytes();
        if (!isCurrentOperation(sourceGeneration, filePickGeneration,
            _filePickGeneration, transport)) {
          return;
        }
        picked.add(_PendingFile(file.name, _guessMime(file.name), bytes));
      }
      if (picked.isEmpty ||
          !isCurrentOperation(sourceGeneration, filePickGeneration,
              _filePickGeneration, transport)) {
        return;
      }
      _pendingFiles.addAll(picked);
      _notify();
    } catch (e) {
      if (isCurrentOperation(sourceGeneration, filePickGeneration,
          _filePickGeneration, transport)) {
        onToast('选择文件失败: $e');
      }
    }
  }

  Future<List<Map<String, dynamic>>> _uploadFiles(
    Map<String, dynamic> echo,
    List<_PendingFile> files,
    String sessionId, {
    required int sourceGeneration,
    required int sendGeneration,
    required ConversationTransport transport,
  }) async {
    final total = files.length;
    var completed = 0;
    while (files.isNotEmpty) {
      if (!isCurrentOperation(
          sourceGeneration, sendGeneration, _sendGeneration, transport,
          sessionId: sessionId)) {
        throw const _StaleChatOperation();
      }
      final file = files.first;
      final descriptor = await transport.attachmentPut(
        sessionId,
        fileName: file.fileName,
        mime: file.mime,
        bytes: file.bytes,
        onProgress: (p) {
          if (isCurrentOperation(
              sourceGeneration, sendGeneration, _sendGeneration, transport,
              sessionId: sessionId)) {
            uploadProgress = (completed + p) / total;
            _notify();
          }
        },
      );
      if (!isCurrentOperation(
          sourceGeneration, sendGeneration, _sendGeneration, transport,
          sessionId: sessionId)) {
        throw const _StaleChatOperation();
      }
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

  /// 发送入口(视图传输入框文本)。slash 快捷(/compact、/goal pause/
  /// resume)在此一并处理;echo 路径先经 [onCleared] 让视图清空输入框,
  /// 再落 echo 并经 [onEchoEnqueued] 通知视图滚到底部。
  Future<void> send(
    String text, {
    required Future<String?> Function() askHeldQueueDisposition,
    required void Function() onCleared,
    required void Function() onEchoEnqueued,
  }) async {
    if ((text.isEmpty && _pendingFiles.isEmpty) || sending) return;

    if (text.startsWith('/goal ') && _pendingFiles.isNotEmpty) {
      onToast('目标命令不支持附件');
      return;
    }

    // Slash commands (mirrors the web composer).
    if (text == '/compact' || text.startsWith('/compact ')) {
      onCleared();
      await compact();
      return;
    }
    if (text == '/goal pause') {
      onCleared();
      await pauseGoal();
      return;
    }
    if (text == '/goal resume') {
      onCleared();
      await resumeGoal();
      return;
    }

    final sourceGeneration = _sourceGeneration;
    final sendGeneration = ++_sendGeneration;
    final transport = this.transport;
    final sourceSessionId = _sessionId;

    // held-queue confirmation: when inputRouting is `choice` the user
    // picks whether to clear the held queue or keep it. Asked BEFORE the
    // echo goes up so cancelling leaves nothing on screen.
    String? heldDisposition;
    final state = this.state;
    if (state != null &&
        state.inputRoutingMode == 'choice' &&
        state.queueItems.isNotEmpty) {
      heldDisposition = await askHeldQueueDisposition();
      if (!isCurrentOperation(
          sourceGeneration, sendGeneration, _sendGeneration, transport,
          sessionId: sourceSessionId)) {
        return;
      }
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
    if (!isCurrentOperation(
        sourceGeneration, sendGeneration, _sendGeneration, transport,
        sessionId: sourceSessionId)) {
      return;
    }
    onCleared();
    _echoes.add(echo);
    _pendingFiles.clear();
    sending = true;
    uploadProgress = null;
    progress = null;
    _notify();
    onEchoEnqueued();
    await _deliverEcho(
      echo,
      heldDisposition: heldDisposition,
      sourceGeneration: sourceGeneration,
      sendGeneration: sendGeneration,
      transport: transport,
    );
  }

  /// Sends (or re-sends) one echo's message and drives its status:
  /// `sending` → `sent` on an accepted ack, `failed` (+reason) on a
  /// rejection/timeout/error. Handles both the fresh-send path and the
  /// tap-to-retry path (including re-creating a session in draft mode).
  Future<void> _deliverEcho(
    Map<String, dynamic> echo, {
    String? heldDisposition,
    required int sourceGeneration,
    required int sendGeneration,
    required ConversationTransport transport,
  }) async {
    var sessionId = _sessionId;
    bool current() => isCurrentOperation(
          sourceGeneration,
          sendGeneration,
          _sendGeneration,
          transport,
          sessionId: sessionId,
        );

    void mark(String status, [String? err]) {
      if (!current()) return;
      if (diagLogEnabled.value) {
        debugPrint('[chat] echo → $status${err == null ? '' : ' ($err)'}');
      }
      echo['status'] = status;
      if (err != null) echo['error'] = err;
      _notify();
    }

    try {
      if (sessionId == null) {
        // 1) create the session (can take a while when the runtime warms).
        // 宿主 createSession schema(.strict())没有 firstInput/attachments
        // 字段——早期版本把首条文本塞进 firstInput,被宿主静默剥离,文本
        // 从未送达(表现为新会话首条大概率收不到回复)。create 只建会话
        // 并应用草稿的模型/思考档/模式,文本在订阅建立后统一走 sendText。
        progress = '正在创建会话（首次可能需要预热）…';
        _notify();
        final sw = Stopwatch()..start();
        try {
          final created = await transport.createSession(
            workspaceKey,
            config: _buildDraftConfig(),
            timeout: const Duration(seconds: 90),
          );
          if (!current()) return;
          sessionId = created;
          _adoptCreatedSession(created);
          if (!current()) return;
          if (diagLogEnabled.value) {
            debugPrint('[chat] createSession total ${sw.elapsedMilliseconds}ms'
                ' → $sessionId');
          }
        } catch (e) {
          if (!current()) return;
          log('[chat] createSession failed after '
              '${sw.elapsedMilliseconds}ms: $e');
          mark('failed', '$e');
          onToast('发送失败: $e');
          return;
        }
        log('[chat] createSession ok in ${sw.elapsedMilliseconds}ms');
        progress = null;
        _notify();
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
            await transport.switchModelConfig(sessionId,
                provider: provider, model: model, thought: thought);
            if (!current()) return;
            if (diagLogEnabled.value) {
              debugPrint('[chat] switchModelConfig after create '
                  '${swSwitch.elapsedMilliseconds}ms');
            }
          } catch (e) {
            if (current() && diagLogEnabled.value) {
              debugPrint('[chat] switchModelConfig after create failed: $e');
            }
          }
        }
        // 2) 订阅与发送并行:sendText 是 RPC 直达宿主,不依赖本端订阅;
        // 回复经订阅推送,await 订阅只会白等(真机实测首条慢 ~10s)。
        // 订阅在后台补上,回复从建立完成那一刻开始照收。
        if (!current()) return;
        unawaited(subscribe());
      }
      if (!current()) return;
      final text = '${echo['text']}';
      if (text.startsWith('/goal ')) {
        final res = await transport.sendGoalCommand(
          sessionId,
          text.substring('/goal '.length).trim(),
          heldQueueDisposition: heldDisposition,
        );
        if (!current()) return;
        if (isRpcRejected(res)) {
          mark('failed', rpcFailureReason(res));
          onToast('发送失败: ${rpcFailureReason(res)}');
          return;
        }
        mark('sent');
        return;
      }
      List<Map<String, dynamic>>? attachments = (echo['attachments'] as List?)
          ?.whereType<Map>()
          .cast<Map<String, dynamic>>()
          .toList();
      final files = (echo['files'] as List<_PendingFile>?) ?? const [];
      if (files.isNotEmpty) {
        progress = '正在上传附件…';
        _notify();
        final fileList = (echo['files'] as List<_PendingFile>?) ?? [];
        attachments = await _uploadFiles(
          echo,
          fileList,
          sessionId,
          sourceGeneration: sourceGeneration,
          sendGeneration: sendGeneration,
          transport: transport,
        );
        if (!current()) return;
        progress = null;
        _notify();
      }
      final swSend = Stopwatch()..start();
      final res = await transport.sendText(sessionId, text,
          attachments: attachments, heldQueueDisposition: heldDisposition);
      if (!current()) return;
      if (diagLogEnabled.value) {
        debugPrint('[chat] sendText ack in ${swSend.elapsedMilliseconds}ms '
            'res=$res');
      }
      if (isRpcRejected(res)) {
        mark('failed', rpcFailureReason(res));
        onToast('发送失败: ${rpcFailureReason(res)}');
        return;
      }
      turnPending = true;
      mark('sent');
    } catch (e) {
      if (!current() || e is _StaleChatOperation) return;
      mark('failed', '$e');
      onToast('发送失败: $e');
    } finally {
      if (current()) {
        sending = false;
        uploadProgress = null;
        progress = null;
        _notify();
      }
    }
  }

  /// Tap-to-retry for a failed echo: re-asks the held-queue disposition
  /// when applicable, re-uploads attachments that never made it, and
  /// drives the same status machine as the original send.
  Future<void> retryEcho(
    Map<String, dynamic> echo, {
    required Future<String?> Function() askHeldQueueDisposition,
  }) async {
    if (sending) return;
    final sourceGeneration = _sourceGeneration;
    final sendGeneration = ++_sendGeneration;
    final transport = this.transport;
    final sessionId = _sessionId;
    String? heldDisposition;
    final state = this.state;
    if (state != null &&
        state.inputRoutingMode == 'choice' &&
        state.queueItems.isNotEmpty) {
      heldDisposition = await askHeldQueueDisposition();
      if (!isCurrentOperation(
          sourceGeneration, sendGeneration, _sendGeneration, transport,
          sessionId: sessionId)) {
        return;
      }
      if (heldDisposition == null) return; // cancelled
    }
    if (!isCurrentOperation(
        sourceGeneration, sendGeneration, _sendGeneration, transport,
        sessionId: sessionId)) {
      return;
    }
    echo['status'] = 'sending';
    echo['error'] = null;
    sending = true;
    _notify();
    await _deliverEcho(
      echo,
      heldDisposition: heldDisposition,
      sourceGeneration: sourceGeneration,
      sendGeneration: sendGeneration,
      transport: transport,
    );
  }

  // ------------------------------------------------------------- history

  Future<void> loadOlder() async {
    final state = this.state;
    final sessionId = _sessionId;
    if (state == null || sessionId == null || loadingOlder) return;
    if (!state.canLoadOlder) return;
    final sourceGeneration = _sourceGeneration;
    final historyGeneration = ++_historyGeneration;
    final transport = this.transport;
    final subscription = _subscription;
    loadingOlder = true;
    _notify();
    try {
      // The cursor is the protocol state's oldest held row — see
      // ConversationState.oldestRowId.
      final res = await transport.rowsRange(
        sessionId,
        beforeRowId: state.oldestRowId,
        limit: 60,
      );
      if (!isCurrentOperation(sourceGeneration, historyGeneration,
              _historyGeneration, transport,
              sessionId: sessionId) ||
          !identical(subscription, _subscription) ||
          !identical(state, this.state)) {
        return;
      }
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
          ..sort((a, b) =>
              ((a['rowId'] as num?) ?? 0).compareTo((b['rowId'] as num?) ?? 0));
        final oldLength = state.rows.length;
        final oldFirstRowId = state.firstRowId;
        state.prependOlderRows(older, firstRowId);
        if (state.rows.length != oldLength ||
            state.firstRowId != oldFirstRowId) {
          prependScrollPending = true;
          prependTailRow = state.rows.isEmpty ? null : state.rows.last;
        }
        // Reverse list: prepended history extends the top end without
        // moving the viewport — no scroll compensation needed.
        // This batch was the last (server says nothing precedes it): the
        // earliest message is now held — retire the button immediately.
        if (!hasMore) state.markHistoryExhausted(true);
      } else {
        // Exhausted (the server's hasMore is false): stop offering the
        // button instead of re-tapping into empty responses.
        if (!hasMore) state.markHistoryExhausted(true);
        if (state.rows.isNotEmpty) {
          onToast('没有更早的消息了');
        }
      }
    } catch (e) {
      if (isCurrentOperation(sourceGeneration, historyGeneration,
              _historyGeneration, transport,
              sessionId: sessionId) &&
          identical(subscription, _subscription) &&
          identical(state, this.state)) {
        onToast('加载失败: $e');
      }
    } finally {
      if (isCurrentOperation(sourceGeneration, historyGeneration,
              _historyGeneration, transport,
              sessionId: sessionId) &&
          identical(subscription, _subscription)) {
        loadingOlder = false;
        _notify();
      }
    }
  }

  // ------------------------------------------------- prep / skills / draft

  WorkspacePrep? prep;

  /// prepareWorkspace 最近一次成功拉取时刻(5s 新鲜度窗:窗内重复打开
  /// 模型面板不再发请求,连开即开)。
  DateTime? _prepFetchedAt;
  int _prepGeneration = 0;
  List<SkillEntry> skills = [];
  bool skillsLoading = false;

  /// 只刷 prepareWorkspace(模型/思考档/模式可选项的实时来源)。
  /// 必须 refresh: true——传输层有会话级缓存,不带参数会直接返回缓存
  /// (模型增删后旧缓存照旧,面板"刷新"实际没上线)。
  Future<void> _refreshPrep() async {
    final generation = ++_prepGeneration;
    final sourceGeneration = _sourceGeneration;
    final transport = this.transport;
    final transportGeneration = transport.prepGeneration;
    try {
      final fresh = await transport.prepareWorkspace(refresh: true);
      if (isCurrentOperation(
          sourceGeneration, generation, _prepGeneration, transport)) {
        if (transportGeneration != transport.prepGeneration) return;
        prep = fresh;
        _prepFetchedAt = DateTime.now();
        _notify();
        _validateDraftAgainstPrep();
      }
    } catch (_) {}
  }

  /// 面板打开时的取数:新鲜(≤5s)直接用,否则强制拉一次;失败退缓存。
  Future<WorkspacePrep?> fetchPrepForSheet() async {
    final sourceGeneration = _sourceGeneration;
    final transport = this.transport;
    final fetchedAt = _prepFetchedAt;
    if (fetchedAt != null &&
        DateTime.now().difference(fetchedAt) < const Duration(seconds: 5)) {
      return prep;
    }
    await _refreshPrep();
    if (!isCurrentForSource(sourceGeneration, transport)) return null;
    return prep;
  }

  Future<void> loadPrep() async {
    final sourceGeneration = _sourceGeneration;
    final transport = this.transport;
    final skillsGeneration = ++_skillsGeneration;
    await _refreshPrep();
    if (!isCurrentOperation(
        sourceGeneration, skillsGeneration, _skillsGeneration, transport)) {
      return;
    }
    skillsLoading = true;
    _notify();
    try {
      final loaded = await transport.skills();
      if (isCurrentOperation(
          sourceGeneration, skillsGeneration, _skillsGeneration, transport)) {
        skills = loaded;
        _notify();
      }
    } catch (_) {
      if (isCurrentOperation(
          sourceGeneration, skillsGeneration, _skillsGeneration, transport)) {
        skills = const [];
        _notify();
      }
    } finally {
      if (isCurrentOperation(
          sourceGeneration, skillsGeneration, _skillsGeneration, transport)) {
        skillsLoading = false;
        _notify();
      }
    }
  }

  /// Draft-mode (no session yet) model/mode/thought selection, passed as
  /// `config` to createSession on first send.
  final Map<String, String> _draftConfig = {};

  Map<String, String> get draftConfig => _draftConfig;

  /// 模型面板/模式菜单的草稿选择落地:守卫由调用方(持打开时快照)负责。
  void setDraftOption(String key, String value) {
    _draftConfig[key] = value;
    _notify();
    _saveDraftPrefs();
  }

  Future<void> _loadDraftPrefs() async {
    final sourceGeneration = _sourceGeneration;
    final draftPrefsGeneration = ++_draftPrefsGeneration;
    final transport = this.transport;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!isCurrentOperation(sourceGeneration, draftPrefsGeneration,
          _draftPrefsGeneration, transport)) {
        return;
      }
      for (final k in const ['model', 'thought', 'mode']) {
        final v = prefs.getString('draft.$k');
        if (v != null && v.isNotEmpty) _draftConfig[k] = v;
      }
      _notify();
      _validateDraftAgainstPrep();
    } catch (_) {}
  }

  void _validateDraftAgainstPrep() {
    final prep = this.prep;
    if (prep == null) return;
    final changed = <String, String>{..._draftConfig};
    for (final entry in changed.entries.toList()) {
      final option =
          prep.option(entry.key == 'thought' ? 'thought_level' : entry.key);
      if (option != null &&
          option.options.isNotEmpty &&
          !option.options.any((o) => o.value == entry.value)) {
        _draftConfig.remove(entry.key);
      }
    }
    _notify();
  }

  Future<void> _saveDraftPrefs() async {
    final sourceGeneration = _sourceGeneration;
    final draftPrefsGeneration = ++_draftPrefsGeneration;
    final transport = this.transport;
    // Keep writes ordered while allowing a newer selection to supersede the
    // callbacks from an older save operation.
    _draftPrefsSaveChain = _draftPrefsSaveChain.then((_) async {
      try {
        final prefs = await SharedPreferences.getInstance();
        if (!isCurrentOperation(sourceGeneration, draftPrefsGeneration,
            _draftPrefsGeneration, transport)) {
          return;
        }
        for (final k in const ['model', 'thought', 'mode']) {
          final v = _draftConfig[k];
          if (!isCurrentOperation(sourceGeneration, draftPrefsGeneration,
              _draftPrefsGeneration, transport)) {
            return;
          }
          if (v == null || v.isEmpty) {
            await prefs.remove('draft.$k');
          } else {
            await prefs.setString('draft.$k', v);
          }
        }
      } catch (_) {}
    });
    await _draftPrefsSaveChain;
  }

  /// Builds the createSession `config` payload from the draft selection.
  Map<String, dynamic>? _buildDraftConfig() {
    // 未显式改过的项回填 prepareWorkspace 的当前值(用户在 pill/模式按钮
    // 看到的就是这些值,期望按它建会话;缺省时宿主会用默认档,表现为
    // "思考等级没按选好的来")。
    String? pick(String key, String optionId) =>
        _draftConfig[key] ?? '${prep?.option(optionId)?.currentValue ?? ''}';
    final modelValue =
        _draftConfig['model'] ?? '${prep?.option('model')?.currentValue ?? ''}';
    final config = <String, dynamic>{};
    if (modelValue.isNotEmpty) {
      final (provider, model) = providerModelOf(prep, modelValue);
      config['provider'] = provider;
      config['model'] = model;
    }
    final thought = pick('thought', 'thought_level');
    if (thought != null && thought.isNotEmpty) config['thought'] = thought;
    final mode = pick('mode', 'mode');
    if (mode != null && mode.isNotEmpty) config['mode'] = mode;
    return config.isEmpty ? null : config;
  }

  // ---------------------------------------------------------- title watch

  /// Live sessions-index watch driving [ChatPage.onSessionInfo]; only
  /// mounted in embedded mode. The desktop generates/renames titles
  /// asynchronously, so the host header needs pushes when it changes.
  SessionsIndexSubscription? _titleSub;
  String? _pushedSessionId;
  String? _pushedTitle;

  Future<void> _watchSessionTitle() async {
    final sourceGeneration = _sourceGeneration;
    final titleGeneration = ++_titleGeneration;
    final transport = this.transport;
    try {
      final sub = await transport.subscribeSessionsIndex();
      if (!isCurrentOperation(
          sourceGeneration, titleGeneration, _titleGeneration, transport)) {
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
    if (sub == null || sessionId == null || _disposed) return;
    final title = sub.state.sessions[sessionId]?.title ?? '';
    final idNew = sessionId != _pushedSessionId;
    final titleNew = title.isNotEmpty && title != _pushedTitle;
    if (!idNew && !titleNew) return;
    _pushedSessionId = sessionId;
    if (titleNew) _pushedTitle = title;
    onSessionInfo?.call(sessionId, title);
  }

  /// Draft 首条消息创建会话后的采纳。索引推送(含桌面端生成的标题)可能
  /// 先于 createSession 返回到达——监听器此刻读到的 _sessionId 还是
  /// null,之后不会再触发;采纳后必须补跑一次推送。
  void _adoptCreatedSession(String sessionId) {
    _sessionId = sessionId;
    _pushSessionInfo();
  }

  // ---------------------------------------------------------- lifecycle

  /// 首挂启动序列。
  void start() {
    _loadDraftPrefs();
    if (_sessionId != null) {
      subscribe();
    }
    loadPrep();
    if (onSessionInfo != null) {
      _watchSessionTitle();
    }
  }

  /// 换源(widget bridge/scope/session 变化):作废全部在途请求与数据,
  /// 按新 source 重启。滚动代数与分组缓存由视图自行失效。
  void reattach(
    BridgeSession session,
    Map<String, dynamic> scope,
    String workspaceKey,
    String? sessionId, {
    required bool watchTitle,
  }) {
    _retireCurrentSubscription();
    final oldTitleSub = _titleSub;
    _invalidateOperations();
    _prepGeneration++;
    _titleSub = null;
    if (oldTitleSub != null) {
      oldTitleSub.state.removeListener(_pushSessionInfo);
      oldTitleSub.dispose();
    }
    _scope = scope;
    this.workspaceKey = workspaceKey;
    _sessionId = sessionId;
    transport = session.conversation(_scope);
    _pushedSessionId = null;
    _pushedTitle = null;
    error = null;
    loadingOlder = false;
    prep = null;
    _prepFetchedAt = null;
    skills = [];
    skillsLoading = false;
    sending = false;
    uploadProgress = null;
    progress = null;
    turnPending = false;
    _echoes.clear();
    _pendingFiles.clear();
    _notify();
    if (_sessionId != null) subscribe();
    loadPrep();
    if (watchTitle) _watchSessionTitle();
  }

  void dispose() {
    _disposed = true;
    _invalidateOperations();
    _prepGeneration++;
    _retireCurrentSubscription();
    final titleSub = _titleSub;
    _titleSub = null;
    if (titleSub != null) {
      titleSub.state.removeListener(_pushSessionInfo);
      titleSub.dispose();
    }
  }

  void _notify() {
    if (!_disposed) onChanged();
  }
}
