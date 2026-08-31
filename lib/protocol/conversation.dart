import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import 'channel_client.dart';
import 'id.dart';
import '../state/log_store.dart' show diagLogEnabled;
import 'zflow_client.dart';

/// Conversation V4 protocol over the `zcode-agent` channel.
///
/// Flow (mirrors `sk()`/`uk()` in the web client):
/// 1. `helloConversationV4()` + `initializeConversationV4(clientHello)`
/// 2. `subscribeConversationV4(scope + sessionId)` -> ack.subscriptionId
/// 3. frames pushed via dynamic event `onDynamicConversationFrame(scope)`:
///    wire frames `{wireVersion:3, kind:'complete'|'fragment', topic,
///    subscriptionId, frame | fragment*}`; complete frames carry
///    `{topic, subscriptionId, fromSeq, toSeq, sentAt, payload}` where payload
///    is `{kind:'snapshot', snapshot}` or `{kind:'deltas', deltas}`.
/// 4. commands via `sendConversationCommandV4(scope + envelope)` with
///    envelope `{commandId, clientId, sessionId, type, payload, issuedAt}`.
class ConversationTransport {
  static const channel = Channels.zcodeAgent;

  final BridgeSession session;
  final Map<String, dynamic> scope;
  final String appVersion;
  final void Function(String line)? onLog;

  final String clientId = generateUuid();
  bool _handshaken = false;
  Future<void>? _handshakeFuture;
  late final _SharedSessionsIndex _sessionsIndexShared;
  bool _disposed = false;

  /// From the server hello — required for attachment uploads.
  String? connectionId;

  ConversationTransport({
    required this.session,
    required this.scope,
    this.appVersion = '3.6.5',
    this.onLog,
  }) {
    _sessionsIndexShared = _SharedSessionsIndex(this);
    // A reopened bridge has no handshake state — start over (mirrors the
    // web client's `wD` cache being per service instance).
    session.recovered.addListener(_onBridgeRecovered);
  }

  void _onBridgeRecovered() {
    _handshaken = false;
    _handshakeFuture = null;
    connectionId = null;
    _prepGeneration++;
    _prepRequestGeneration++;
    _prep = null;
    _prepInFlight = null;
    _prepRefreshInFlight = null;
  }

  ChannelClient get _channels => session.channels;
  int get prepGeneration => _prepGeneration;

  void _log(String line) => onLog?.call(line);

  Future<void> handshake() {
    if (_handshaken) return Future.value();
    return _handshakeFuture ??= () async {
      final hello = await _channels.call(channel, 'helloConversationV4', []);
      _log('[v4] hello: $hello');
      if (hello is Map) {
        connectionId = hello['connectionId'] as String?;
      }
      await _channels.call(channel, 'initializeConversationV4', [
        {
          'kind': 'clientHello',
          'protocolVersion': 3,
          'clientId': clientId,
          'clientKind': 'mobileApp',
          'appVersion': appVersion,
        },
      ]);
      _handshaken = true;
    }().catchError((e) {
      _handshakeFuture = null;
      throw e;
    });
  }

  Future<ConversationSubscription> subscribe(String sessionId) {
    final inFlight = _subscribeInFlight[sessionId];
    if (inFlight != null) return inFlight;

    final future = _startSubscription(sessionId);
    _subscribeInFlight[sessionId] = future;
    unawaited(future.then<void>(
      (_) => _clearInFlightSubscription(sessionId, future),
      onError: (Object error, StackTrace stackTrace) {
        _clearInFlightSubscription(sessionId, future);
      },
    ));
    return future;
  }

  Future<ConversationSubscription> _startSubscription(String sessionId) async {
    await handshake();
    final subscription = ConversationSubscription._(this, sessionId);
    try {
      await subscription._start();
    } catch (_) {
      // 订阅失败也必须回收(周期 watchdog/recovered 监听),否则残留
      // 僵尸订阅;错误本身原样上抛给调用方。
      await subscription.dispose();
      rethrow;
    }
    _subscriptions[sessionId] = subscription;
    return subscription;
  }

  void _clearInFlightSubscription(
      String sessionId, Future<ConversationSubscription> future) {
    if (identical(_subscribeInFlight[sessionId], future)) {
      _subscribeInFlight.remove(sessionId);
    }
  }

  void _untrackSubscription(
      String sessionId, ConversationSubscription subscription) {
    if (identical(_subscriptions[sessionId], subscription)) {
      _subscriptions.remove(sessionId);
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    session.recovered.removeListener(_onBridgeRecovered);
    unawaited(_disposeSharedSessionsIndex());
    for (final subscription in List<ConversationSubscription>.from(_subscriptions.values)) {
      unawaited(subscription.dispose());
    }
    _subscriptions.clear();
  }

  /// Commands that require `baseRevision` (CAS, mirrors `eAe` in the web
  /// client) and row-target commands that also require `baseLogEpoch`
  /// (mirrors `tAe`).
  static const _casCommands = {
    'applyFileRewind',
    'forkAssistant',
    'editUserQuery',
    'retryTurn',
    'setAssistantFeedback',
    'sendQueuedNow',
    'editQueueItem',
    'reorderQueueItem',
    'deleteQueueItem',
    'setAutoDrain',
    'switchModelConfig',
    'switchCollaborationMode',
    'setFollowupMode',
    'pauseGoal',
    'resumeGoal',
  };
  static const _rowTargetCommands = {
    'applyFileRewind',
    'forkAssistant',
    'editUserQuery',
    'retryTurn',
    'setAssistantFeedback',
  };

  /// Live subscriptions by sessionId — source of the current
  /// revision/logEpoch for CAS commands.
  final _subscriptions = <String, ConversationSubscription>{};
  final _subscribeInFlight =
      <String, Future<ConversationSubscription>>{};

  /// Highest revision seen from command acks (`revisionAtDecision`) —
  /// acks land before the follow-up `state.updated` frame, and the next
  /// CAS command must not go stale.
  final _ackedRevisions = <String, int>{};

  Future<dynamic> sendCommand(
    String? sessionId,
    String type,
    Map<String, dynamic> payload, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    await handshake();
    // Gate on a healthy bridge: during a relay drop/recovery the old bridge
    // is dead and requests would otherwise hang until timeout. Once the
    // bridge recovers, the send goes through on the fresh transport.
    await session.waitHealthy(timeout: const Duration(seconds: 45));
    final sub =
        sessionId == null ? null : _subscriptions[sessionId];
    final baseRevision = sessionId == null
        ? null
        : [
            sub?.state.revision ?? 0,
            _ackedRevisions[sessionId] ?? 0,
          ].reduce((a, b) => a > b ? a : b);
    final envelope = {
      'commandId': generateUuid(),
      'clientId': clientId,
      'sessionId': sessionId,
      if (_casCommands.contains(type)) 'baseRevision': baseRevision,
      if (_rowTargetCommands.contains(type) &&
          sub?.state.logEpoch != null)
        'baseLogEpoch': sub!.state.logEpoch,
      'type': type,
      'payload': payload,
      'issuedAt': DateTime.now().millisecondsSinceEpoch,
    };
    _log('[v4] command $type');
    var res = await _sendCommandWithRetry(envelope, timeout);
    // Runtime events (turn completion etc.) also bump the revision, so a
    // CAS base can go stale even with ack tracking. The stale ack tells
    // the server's current revision — retry once with it (mirrors the
    // web client's stale-revision retry).
    if (sessionId != null &&
        res is Map &&
        res['status'] == 'stale' &&
        res['revisionAtDecision'] is num) {
      final serverRevision =
          (res['revisionAtDecision'] as num).toInt();
      _log('[v4] command $type stale, retry at rev $serverRevision');
      if (serverRevision > (_ackedRevisions[sessionId] ?? 0)) {
        _ackedRevisions[sessionId] = serverRevision;
      }
      final retryEnvelope = {
        ...envelope,
        'commandId': generateUuid(),
        'baseRevision': serverRevision,
        'issuedAt': DateTime.now().millisecondsSinceEpoch,
      };
      res = await _sendCommandWithRetry(retryEnvelope, timeout);
    }
    if (sessionId != null &&
        res is Map &&
        res['revisionAtDecision'] is num) {
      final rev = (res['revisionAtDecision'] as num).toInt();
      final status = res['status'];
      // revisionAtDecision is the base at decision time; an accepted
      // command bumps the revision by one, so the next CAS base is +1.
      final floor =
          (status == 'accepted' || status == 'noop' || status == 'duplicate')
              ? rev + 1
              : rev;
      if (floor > (_ackedRevisions[sessionId] ?? 0)) {
        _ackedRevisions[sessionId] = floor;
      }
    }
    return res;
  }

  /// Sends one command envelope; on timeout (likely a relay drop mid-flight)
  /// waits for bridge recovery and retries once with a fresh commandId.
  Future<dynamic> _sendCommandWithRetry(
      Map<String, dynamic> envelope, Duration timeout) async {
    try {
      return await _channels.call(channel, 'sendConversationCommandV4', [
        {...scope, 'envelope': envelope},
      ], timeout: timeout);
    } on TimeoutException {
      // Retry only when the relay dropped mid-flight (bridge degraded): the
      // command then never reached the server. If the bridge is still
      // healthy, rethrow — a retry would double-deliver (e.g. sendText).
      if (session.degraded.value == null) rethrow;
      _log('[v4] command timed out during drop, waiting for recovery and '
          'retrying');
      await session.waitHealthy(timeout: const Duration(seconds: 45));
      final fresh = {
        ...envelope,
        'commandId': generateUuid(),
        'issuedAt': DateTime.now().millisecondsSinceEpoch,
      };
      return _channels.call(channel, 'sendConversationCommandV4', [
        {...scope, 'envelope': fresh},
      ], timeout: timeout);
    }
  }

  /// Creates a new session (mirrors the composer's first-send path):
  /// command `createSession` with a null envelope sessionId. Returns the
  /// new sessionId on `accepted`.
  ///
  /// 宿主校验层要求顶层 workspaceId 字符串;mode/model/thoughtLevel
  /// 为顶层字段——早期猜测的 `firstInput` 与
  /// 嵌套 `config` 字段会被静默剥离:首条文本从未送达,草稿的模型/
  /// 思考档也不生效(真机表现即"新会话第一条消息收不到回复")。文本
  /// 一律在订阅建立后走 sendText;初始模型/思考档走顶层 model/thought。
  Future<String> createSession(
    String workspaceId, {
    Map<String, dynamic>? config,
    String? runtimeModel,
    List<String>? mcpServers,
    Duration timeout = const Duration(seconds: 90),
  }) async {
    final payload = {
      // zcode-agent 通道校验层要求顶层 workspaceId 字符串(真机
      // Invalid input 实证;relay 桥的 workspace 对象在更内层由宿主
      // 自行从 workspaceId 解析)。
      'workspaceId': workspaceId,
        if (config != null) ...{
          if (config['model'] != null)
            'model': {
              'providerId': config['provider'],
              'modelId': config['model'],
            },
          if (config['thought'] != null) 'thoughtLevel': config['thought'],
          if (config['mode'] != null) 'mode': config['mode'],
        },
        if (runtimeModel != null) 'runtimeModel': runtimeModel,
        if (mcpServers != null && mcpServers.isNotEmpty)
          'mcpServers': mcpServers,
    };
    if (diagLogEnabled.value) debugPrint('[chat] createSession req: $payload');
    final res = await sendCommand(null, 'createSession', payload,
        timeout: timeout);
    if (diagLogEnabled.value) debugPrint('[chat] createSession res: $res');
    final map = res is Map ? res.cast<String, dynamic>() : null;
    final status = map?['status'];
    if (status != 'accepted') {
      throw StateError(
          'createSession rejected: ${map?['reasonCode'] ?? status} ${map?['message'] ?? ''}');
    }
    final result = map?['result'];
    final sessionId = result is Map ? result['sessionId'] : null;
    if (sessionId is! String || sessionId.isEmpty) {
      throw StateError('createSession: missing sessionId in result');
    }
    return sessionId;
  }

  /// Creates a selection-side (auxiliary) chat attached to [parentSessionId]
  /// (command `createSelectionSideSession` with an empty payload, mirrors
  /// the web client's "ask in side chat" flow). Returns the new sessionId.
  Future<String> createSelectionSideSession(
    String parentSessionId, {
    Duration timeout = const Duration(seconds: 60),
  }) async {
    final res = await sendCommand(
      parentSessionId,
      'createSelectionSideSession',
      {},
      timeout: timeout,
    );
    final map = res is Map ? res.cast<String, dynamic>() : null;
    final status = map?['status'];
    if (status != 'accepted' && status != 'duplicate') {
      throw StateError(
          'createSelectionSideSession rejected: ${map?['reasonCode'] ?? status} ${map?['message'] ?? ''}');
    }
    final result = map?['result'];
    final sessionId = result is Map ? result['sessionId'] : null;
    if (sessionId is! String || sessionId.isEmpty) {
      throw StateError(
          'createSelectionSideSession: missing sessionId in result');
    }
    return sessionId;
  }

  Future<dynamic> sendText(
    String sessionId,
    String text, {
    List<Map<String, dynamic>>? attachments,
    String? heldQueueDisposition,
    List<String>? expectedHeldQueueItemIds,
    String? automationId,
    String? offPeakTaskId,
    String? offPeakRunType,
    String? botDeliveryTarget,
    List<String>? toolDisallowlist,
  }) =>
      sendCommand(sessionId, 'sendText', {
        'text': text,
        if (attachments != null && attachments.isNotEmpty)
          'attachments': attachments,
        if (heldQueueDisposition != null)
          'heldQueueDisposition': heldQueueDisposition,
        if (expectedHeldQueueItemIds != null &&
            expectedHeldQueueItemIds.isNotEmpty)
          'expectedHeldQueueItemIds': expectedHeldQueueItemIds,
        if (automationId != null) 'automationId': automationId,
        if (offPeakTaskId != null) 'offPeakTaskId': offPeakTaskId,
        if (offPeakRunType != null) 'offPeakRunType': offPeakRunType,
        if (botDeliveryTarget != null) 'botDeliveryTarget': botDeliveryTarget,
        if (toolDisallowlist != null && toolDisallowlist.isNotEmpty)
          'toolDisallowlist': toolDisallowlist,
      });

  Future<dynamic> sendGoalCommand(
    String sessionId,
    String text, {
    String? displayText,
    String? heldQueueDisposition,
    List<String>? expectedHeldQueueItemIds,
  }) =>
      sendCommand(sessionId, 'sendGoalCommand', {
        'text': text,
        if (displayText != null) 'displayText': displayText,
        if (heldQueueDisposition != null)
          'heldQueueDisposition': heldQueueDisposition,
        if (expectedHeldQueueItemIds != null &&
            expectedHeldQueueItemIds.isNotEmpty)
          'expectedHeldQueueItemIds': expectedHeldQueueItemIds,
      });

  Future<dynamic> pauseGoal(String sessionId) =>
      sendCommand(sessionId, 'pauseGoal', {});

  Future<dynamic> resumeGoal(String sessionId) =>
      sendCommand(sessionId, 'resumeGoal', {});

  Future<dynamic> stop(String sessionId) =>
      sendCommand(sessionId, 'stop', {});

  Future<dynamic> compact(String sessionId) =>
      sendCommand(sessionId, 'compact', {});

  /// Switch model config. All of provider/model/thought are required by the
  /// protocol schema — pass current values for the ones not changing.
  /// Thought levels differ per model family (GLM-5.2: max/high/nothink;
  /// Turbo: enabled/off), so on `Unsupported reasoning effort` we retry
  /// with the other family's default.
  Future<dynamic> switchModelConfig(
    String sessionId, {
    required String provider,
    required String model,
    required String thought,
  }) async {
    var res = await sendCommand(sessionId, 'switchModelConfig', {
      'provider': provider,
      'model': model,
      'thought': thought,
    });
    final message = res is Map ? '${res['message'] ?? ''}' : '';
    if (message.contains('Unsupported reasoning effort')) {
      final fallback =
          (thought == 'enabled' || thought == 'off') ? 'max' : 'enabled';
      _log('[v4] switchModelConfig retry with thought=$fallback');
      res = await sendCommand(sessionId, 'switchModelConfig', {
        'provider': provider,
        'model': model,
        'thought': fallback,
      });
    }
    return res;
  }

  /// build / edit / plan / yolo. Mirrors `switchCollaborationMode`.
  Future<dynamic> switchCollaborationMode(String sessionId, String mode) =>
      sendCommand(sessionId, 'switchCollaborationMode', {'mode': mode});

  /// queue / guide followup. Mirrors `setFollowupMode`.
  Future<dynamic> setFollowupMode(String sessionId, String mode) =>
      sendCommand(sessionId, 'setFollowupMode', {'mode': mode});

  /// like / dislike / null on an assistant row. Target is
  /// `{rowId, entityId}` (entityId optional for some row kinds).
  Future<dynamic> setAssistantFeedback(
    String sessionId,
    Map<String, dynamic> target,
    String? feedback,
  ) =>
      sendCommand(sessionId, 'setAssistantFeedback', {
        'target': target,
        'feedback': feedback,
      });

  Future<dynamic> retryTurn(
          String sessionId, Map<String, dynamic> target) =>
      sendCommand(sessionId, 'retryTurn', {'target': target});

  Future<dynamic> sendQueuedNow(String sessionId, String queueItemId) =>
      sendCommand(sessionId, 'sendQueuedNow', {'queueItemId': queueItemId});

  Future<dynamic> editQueueItem(
          String sessionId, String queueItemId, String newText) =>
      sendCommand(sessionId, 'editQueueItem',
          {'queueItemId': queueItemId, 'newText': newText});

  Future<dynamic> deleteQueueItem(String sessionId, String queueItemId) =>
      sendCommand(sessionId, 'deleteQueueItem', {'queueItemId': queueItemId});

  Future<dynamic> setAutoDrain(String sessionId, bool autoDrain) =>
      sendCommand(sessionId, 'setAutoDrain', {'autoDrain': autoDrain});

  Future<dynamic> forkAssistant(
          String sessionId, Map<String, dynamic> target) =>
      sendCommand(sessionId, 'forkAssistant', {'target': target});

  Future<dynamic> editUserQuery(
    String sessionId,
    Map<String, dynamic> target,
    String newText,
  ) =>
      sendCommand(sessionId, 'editUserQuery',
          {'target': target, 'newText': newText});

  Future<dynamic> applyFileRewind(
          String sessionId, Map<String, dynamic> target) =>
      sendCommand(sessionId, 'applyFileRewind', {'target': target});

  /// File-changes query. baseRevision/baseLogEpoch are read from the live
  /// subscription internally: the server guard requires them to EXACTLY
  /// match the publisher snapshot, so callers must not cache a value.
  Future<dynamic> fileChanges(
    String sessionId, {
    required Map<String, dynamic> target,
  }) async {
    await handshake();
    return _fileQueryWithStaleRecovery(
        sessionId, 'conversationFileChangesV4', target);
  }

  /// The fileChanges guard rejects any request whose baseRevision/
  /// baseLogEpoch don't equal the live publisher snapshot
  /// (`proto.staleRevision` / `proto.staleLogEpoch`), and streaming bumps
  /// the revision between our read and the server's check. Mirrors the web
  /// client: treat proto.stale* as retryable — wait for the next
  /// state.updated {revision} to land (a streaming race self-heals within
  /// moments), or force a snapshot resync when nothing advances (logEpoch
  /// drift after a publisher rebuild), then retry once with fresh values.
  Future<dynamic> _fileQueryWithStaleRecovery(
    String sessionId,
    String method,
    Map<String, dynamic> target,
  ) async {
    final sub = _subscriptions[sessionId];
    Future<dynamic> call() => _channels.call(channel, method, [
          {
            ...scope,
            'sessionId': sessionId,
            'target': target,
            'baseRevision': sub?.state.revision ?? 0,
            if (sub?.state.logEpoch != null)
              'baseLogEpoch': sub!.state.logEpoch,
          },
        ]);
    try {
      return await call();
    } catch (e) {
      if (!isStaleConversationError(e) || sub == null) rethrow;
      final revision = sub.state.revision;
      final logEpoch = sub.state.logEpoch;
      _log('[v4] $method stale ($e), waiting for state to advance');
      var advanced = await _waitForStateAdvance(
          sub, revision, logEpoch, const Duration(milliseconds: 2500));
      if (!advanced) {
        unawaited(sub._resync());
        advanced = await _waitForStateAdvance(
            sub, revision, logEpoch, const Duration(seconds: 5));
      }
      if (!advanced) rethrow;
      _log('[v4] $method retrying at revision ${sub.state.revision}');
      return await call();
    }
  }

  /// Resolves true as soon as the subscription state moves past
  /// [revision]/[logEpoch] (checked eagerly first — the frame may already
  /// have landed), false on timeout.
  Future<bool> _waitForStateAdvance(
    ConversationSubscription sub,
    int revision,
    String? logEpoch,
    Duration timeout,
  ) async {
    if (sub.state.revision != revision || sub.state.logEpoch != logEpoch) {
      return true;
    }
    final done = Completer<bool>();
    void onChanged() {
      if (sub.state.revision != revision ||
          sub.state.logEpoch != logEpoch) {
        if (!done.isCompleted) done.complete(true);
      }
    }

    sub.state.addListener(onChanged);
    final timer = Timer(timeout, () {
      if (!done.isCompleted) done.complete(false);
    });
    try {
      return await done.future;
    } finally {
      timer.cancel();
      sub.state.removeListener(onChanged);
    }
  }

  Future<dynamic> fileRewindPreview(
    String sessionId, {
    required Map<String, dynamic> target,
    int? baseRevision,
    String? baseLogEpoch,
  }) async {
    await handshake();
    return _channels.call(channel, 'conversationFileRewindPreviewV4', [
      {
        ...scope,
        'sessionId': sessionId,
        'target': target,
        if (baseRevision != null) 'baseRevision': baseRevision,
        if (baseLogEpoch != null) 'baseLogEpoch': baseLogEpoch,
      },
    ]);
  }

  // ------------------------------------------------------------ attachments

  static const _attachmentChunkBytes = 384 * 1024;
  static const _maxAttachmentReadBytes = 16 * 1024 * 1024;

  static int? _integerValue(Object? value) {
    if (value is int) return value;
    if (value is num && value == value.truncate()) return value.toInt();
    return null;
  }

  static String _attachmentRef(Object? value) {
    if (value is String && value.isNotEmpty) return value;
    throw StateError('fault.attachment.missingRef');
  }

  /// Uploads an attachment (begin/chunk/commit, mirrors `rNe()`).
  /// Returns the attachment descriptor `{ref, fileName, mime, bytes}` to be
  /// passed to sendText/createSession.
  Future<Map<String, dynamic>> attachmentPut(
    String sessionId, {
    required String fileName,
    required String mime,
    required Uint8List bytes,
    void Function(double progress)? onProgress,
  }) async {
    await handshake();
    final connId = connectionId;
    if (connId == null) {
      throw StateError('attachmentPut: missing connectionId');
    }
    final uploadId = 'upload-${generateUuid()}';
    final base = {
      'connectionId': connId,
      'uploadId': uploadId,
      'sessionId': sessionId,
    };
    final totalChunks = (bytes.length + _attachmentChunkBytes - 1) ~/
        _attachmentChunkBytes;
    final checksum =
        'sha256:${sha256.convert(bytes).toString()}';

    final beginRes = await _channels.call(channel, 'attachmentBeginV4', [
      {
        ...scope,
        ...base,
        'fileName': fileName,
        'mime': mime,
        'totalBytes': bytes.length,
        'totalChunks': totalChunks,
        'checksum': checksum,
      },
    ]);
    if (beginRes is! Map) {
      throw StateError('fault.attachment.invalidBeginResponse');
    }
    if (beginRes['state'] == 'committed') {
      final ref = _attachmentRef(beginRes['ref']);
      onProgress?.call(1);
      return {
        'ref': ref,
        'fileName': fileName,
        'mime': mime,
        'bytes': bytes.length,
      };
    }
    final nextChunkValue = beginRes['nextChunkIndex'];
    var nextChunk = nextChunkValue == null
        ? 0
        : _integerValue(nextChunkValue);
    if (nextChunk == null || nextChunk < 0 || nextChunk > totalChunks) {
      throw StateError('fault.attachment.invalidServerProgress');
    }
    for (var n = nextChunk; n < totalChunks; n++) {
      final start = n * _attachmentChunkBytes;
      final end = start + _attachmentChunkBytes > bytes.length
          ? bytes.length
          : start + _attachmentChunkBytes;
      final chunkRes =
          await _channels.call(channel, 'attachmentChunkV4', [
        {
          ...scope,
          ...base,
          'chunkIndex': n,
          'dataBase64': base64.encode(Uint8List.sublistView(bytes, start, end)),
        },
      ]);
      if (chunkRes is! Map) {
        throw StateError('fault.attachment.invalidChunkResponse');
      }
      final nextChunkValue = chunkRes['nextChunkIndex'];
      final responseNext = _integerValue(nextChunkValue);
      if (responseNext == null || responseNext != n + 1) {
        throw StateError('fault.attachment.invalidServerProgress');
      }
      nextChunk = responseNext;
      onProgress?.call(nextChunk / totalChunks);
    }
    onProgress?.call(1);
    final commitRes = await _channels.call(channel, 'attachmentCommitV4', [
      {...scope, ...base},
    ]);
    final ref = _attachmentRef(
        commitRes is Map ? commitRes['ref'] : null);
    return {
      'ref': ref,
      'fileName': fileName,
      'mime': mime,
      'bytes': bytes.length,
    };
  }

  /// Reads an attachment (for previews). Returns `{bytes, mediaType}`.
  Future<({Uint8List bytes, String? mediaType})> attachmentRead(
    String sessionId, {
    required String ref,
  }) async {
    await handshake();
    var offset = 0;
    int? totalBytes;
    Uint8List? result;
    final chunks = BytesBuilder(copy: false);
    String? mediaType;
    for (var round = 0; round < 1024; round++) {
      final res = await _channels.call(channel, 'attachmentReadV4', [
        {
          ...scope,
          'sessionId': sessionId,
          'ref': ref,
          'offset': offset,
          'limit': _attachmentChunkBytes,
        },
      ]);
      if (res is! Map) {
        throw StateError('fault.attachment.invalidReadResponse');
      }

      int? responseTotal;
      if (res.containsKey('totalBytes')) {
        responseTotal = _integerValue(res['totalBytes']);
        if (responseTotal == null ||
            responseTotal < 0 ||
            responseTotal > _maxAttachmentReadBytes) {
          throw StateError('fault.attachment.invalidTotalBytes');
        }
      }
      if (responseTotal != null) {
        if (totalBytes != null && responseTotal != totalBytes) {
          throw StateError('fault.attachment.inconsistentTotalBytes');
        }
        totalBytes ??= responseTotal;
        if (result == null) {
          final existing = chunks.takeBytes();
          if (existing.length > totalBytes) {
            throw StateError('fault.attachment.invalidTotalBytes');
          }
          result = Uint8List(totalBytes);
          result.setRange(0, existing.length, existing);
        }
      }
      final responseMediaType = res['mediaType'];
      if (responseMediaType != null && responseMediaType is! String) {
        throw StateError('fault.attachment.invalidMediaType');
      }
      if (mediaType != null &&
          responseMediaType != null &&
          responseMediaType != mediaType) {
        throw StateError('fault.attachment.inconsistentMediaType');
      }
      mediaType ??= responseMediaType as String?;

      final data = res['dataBase64'];
      if (data is! String) {
        throw StateError('fault.attachment.missingChunk');
      }
      final next = _integerValue(res['nextOffset']);
      if (next == null || next < offset) {
        throw StateError('fault.attachment.invalidReadProgress');
      }
      if (data.isEmpty) {
        // An empty response with an unchanged cursor is the only EOF marker
        // available on older hosts that omit totalBytes.
        if (next == offset && (totalBytes == null || totalBytes == offset)) {
          final bytes = result ?? chunks.takeBytes();
          if (totalBytes != null && bytes.length != totalBytes) {
            throw StateError('fault.attachment.invalidReadProgress');
          }
          return (bytes: bytes, mediaType: mediaType);
        }
        throw StateError('fault.attachment.missingChunk');
      }

      late final Uint8List chunk;
      try {
        chunk = base64.decode(data);
      } on FormatException {
        throw StateError('fault.attachment.invalidChunk');
      }
      if (chunk.isEmpty || chunk.length > _attachmentChunkBytes ||
          next != offset + chunk.length ||
          next > (totalBytes ?? _maxAttachmentReadBytes)) {
        throw StateError('fault.attachment.invalidReadProgress');
      }
      if (result != null) {
        result.setRange(offset, next, chunk);
      } else {
        chunks.add(chunk);
      }
      offset = next;
      if (totalBytes != null && offset == totalBytes) {
        return (bytes: result ?? chunks.takeBytes(), mediaType: mediaType);
      }
    }
    throw StateError('fault.attachment.readLimitExceeded');
  }

  Future<dynamic> resolveInteraction(
    String sessionId,
    String interactionId, {
    String? optionId,
    String? freeText,
    String? action,
    Map<String, dynamic>? content,
  }) =>
      sendCommand(sessionId, 'resolveInteraction', {
        'interactionId': interactionId,
        'answer': {
          if (optionId != null) 'optionId': optionId,
          if (freeText != null) 'freeText': freeText,
          if (action != null) 'action': action,
          if (content != null) 'content': content,
        },
      });

  Future<dynamic> rowsRange(
    String sessionId, {
    int? beforeRowId,
    int limit = 60,
  }) async {
    await handshake();
    return _channels.call(channel, 'conversationRowsRangeV4', [
      {
        ...scope,
        'sessionId': sessionId,
        if (beforeRowId != null) 'beforeRowId': beforeRowId,
        'limit': limit,
      },
    ]);
  }

  // ------------------------------------------------------ sessions-index

  /// Subscribes the sessions-index of this workspace
  /// (`subscribeSessionsIndexV4` + `onDynamicSessionsIndexFrame`).
  /// Multiple consumers of this transport share one wire subscription and
  /// receive independent handles; the final handle release tears it down.
  Future<SessionsIndexSubscription> subscribeSessionsIndex() =>
      _sessionsIndexShared.acquire();

  Future<void> _disposeSharedSessionsIndex() => _sessionsIndexShared.dispose();

  // ---------------------------------------------------- workspace config

  WorkspacePrep? _prep;

  /// prepareWorkspace 在途 future(按是否强刷分开合并,避免 refresh 被普通请求吸附)。
  Future<WorkspacePrep>? _prepInFlight;
  Future<WorkspacePrep>? _prepRefreshInFlight;
  int _prepGeneration = 0;
  int _prepRequestGeneration = 0;

  /// `zcode-task.prepareWorkspace` — returns configOptions (model/mode/
  /// thought selects) and slashCommands (builtin + custom skills/MCP).
  Future<WorkspacePrep> prepareWorkspace({bool refresh = false}) async {
    final cached = _prep;
    if (cached != null && !refresh) return cached;

    final inFlight = refresh
        ? _prepRefreshInFlight
        : (_prepInFlight ?? _prepRefreshInFlight);
    if (inFlight != null) return inFlight;

    final generation = _prepGeneration;
    final requestGeneration = ++_prepRequestGeneration;
    final future = _fetchPrep(generation, requestGeneration);
    if (refresh) {
      _prepRefreshInFlight = future;
    } else {
      _prepInFlight = future;
    }
    try {
      return await future;
    } finally {
      if (refresh) {
        if (identical(_prepRefreshInFlight, future)) {
          _prepRefreshInFlight = null;
        }
      } else if (identical(_prepInFlight, future)) {
        _prepInFlight = null;
      }
    }
  }

  Future<WorkspacePrep> _fetchPrep(
      int generation, int requestGeneration) async {
    final res = await _channels.call(
      Channels.zcodeTask,
      'prepareWorkspace',
      [scope],
    );
    final prep = WorkspacePrep._(res is Map ? res : const {});
    if (generation == _prepGeneration &&
        requestGeneration == _prepRequestGeneration) {
      _prep = prep;
    }
    return prep;
  }

  /// `skills.list` — enabled skills of this workspace (mirrors the web
  /// client's `skillsService.list`). Skills are invoked in the composer as
  /// `$name`. Returns an empty list when the channel rejects or returns no
  /// skill data.
  Future<List<SkillEntry>> skills() async {
    final res = await _channels.call(
      Channels.skills,
      'list',
      [
        {
          'workspacePath': scope['workspacePath'],
          if (scope['workspaceIdentity'] != null)
            'workspaceIdentity': scope['workspaceIdentity'],
          'provider': 'glm',
        },
      ],
      timeout: const Duration(seconds: 20),
    );
    final raw = res is List ? res : (res is Map ? res['skills'] : null);
    if (raw is! List) return const [];
    return [
      for (final item in raw.whereType<Map>())
        SkillEntry._(item.cast<String, dynamic>()),
    ].where((s) => s.name.isNotEmpty).toList();
  }
}

/// Shared base for Conversation/SessionsIndex subscriptions.
/// Extracts the common wire-frame staging, fragment reassembly, bridge
/// recovery, and resubscribe retry logic.
abstract class _SubscriptionBase<T extends ChangeNotifier> {
  final ConversationTransport _transport;
  final String _logTag;

  final T state;

  String? _subscriptionId;
  String? get subscriptionId => _subscriptionId;
  void Function()? _cancelFrameListener;
  bool _disposed = false;
  bool _resyncing = false;
  Timer? _resubscribeTimer;
  Future<void>? _resubscribeFuture;

  final _stagedFrames = <Map<String, dynamic>>[];
  final _fragments = <String, _LogicalFrameAssembly>{};
  int _fragmentBytes = 0;
  static const _maxLogicalFragments = 64;
  static const _maxLogicalFrameBytes = 16 * 1024 * 1024;
  static const _maxFragmentAssemblies = 32;
  static const _maxFragmentBytes = 32 * 1024 * 1024;
  static const _maxStagedFrames = 128;
  Timer? _fragmentCleanup;

  _SubscriptionBase(this._transport, this.state, this._logTag) {
    _transport.session.recovered.addListener(_onBridgeRecovered);
    _fragmentCleanup =
        Timer.periodic(const Duration(seconds: 30), (_) => _purgeFragments());
  }

  // --- abstract: subclasses define channel/protocol specifics

  /// Frame event name (e.g. `onDynamicConversationFrame`).
  String get _frameEventName;

  /// Subscribe method name (e.g. `subscribeConversationV4`).
  String get _subscribeMethod;

  /// Unsubscribe method name (e.g. `unsubscribeConversationV4`).
  String get _unsubscribeMethod;

  /// Resync method name (e.g. `resyncConversationV4`).
  String get _resyncMethod;

  /// Extra subscribe request args (merged with scope).
  Map<String, dynamic> get _subscribeArgs;

  /// Extra unsubscribe request args.
  Map<String, dynamic> get _unsubscribeArgs;

  /// Extra resync request args.
  Map<String, dynamic> get _resyncArgs;

  /// Topic for wire-frame routing.
  String get topic;

  /// Process a logical frame against [state].
  void _acceptLogicalFrame(Map<String, dynamic> frame);

  /// Called with the subscribe ack map — hook for state-specific processing.
  void _onSubscribeAck(Map<String, dynamic> ack) {}

  /// Called after a successful _start() — hook for post-start logic.
  void _onStarted() {}

  /// Called during resubscribe cleanup before re-connect.
  void _onResubscribeCleanup() {}

  /// Called during dispose — extra cleanup.
  Future<void> _onDispose() async {}

  int get _resyncSeq => 0;
  String? get _resyncEpoch => null;

  void _purgeFragments() {
    if (_disposed) return;
    final stale = <String>[];
    final now = DateTime.now();
    _fragments.forEach((id, a) {
      if (now.difference(a.createdAt).inSeconds > 60) stale.add(id);
    });
    for (final id in stale) {
      final assembly = _fragments.remove(id);
      if (assembly != null) _fragmentBytes -= assembly.receivedBytes;
      _transport._log('[$_logTag] purged stale fragment $id');
    }
  }

  void _dropFragment(String id) {
    final assembly = _fragments.remove(id);
    if (assembly != null) _fragmentBytes -= assembly.receivedBytes;
  }

  Future<void> _start() async {
    await _transport.handshake();
    if (_disposed) return;
    _cancelFrameListener = _transport._channels.addEventListener(
      ConversationTransport.channel,
      _frameEventName,
      _handleWireFrame,
      arg: _transport.scope,
    );
    final res = await _transport._channels.call(
      ConversationTransport.channel,
      _subscribeMethod,
      [{..._transport.scope, ..._subscribeArgs}],
      // The desktop may need to warm the session runtime before answering —
      // give the subscribe call generous room instead of timing out at the
      // 30s channel default.
      timeout: const Duration(seconds: 60),
    );
    if (_disposed) return;
    final ack = (res as Map?)?['ack'] as Map?;
    _subscriptionId = ack?['subscriptionId'] as String?;
    _transport._log('[$_logTag] subscribed $topic id=$_subscriptionId');
    if (_subscriptionId == null) {
      throw StateError('$_subscribeMethod: missing ack.subscriptionId');
    }
    _onSubscribeAck(ack?.cast<String, dynamic>() ?? const {});
    final staged = List<Map<String, dynamic>>.from(_stagedFrames);
    _stagedFrames.clear();
    for (final frame in staged) {
      _acceptLogicalFrame(frame);
    }
    _onStarted();
  }

  void _onBridgeRecovered() {
    if (_disposed || _resubscribeFuture != null) return;
    _transport._log('[$_logTag] bridge recovered, resubscribing $topic');
    final future = _resubscribeWithRetry();
    _resubscribeFuture = future;
    unawaited(future.whenComplete(() {
      if (identical(_resubscribeFuture, future)) {
        _resubscribeFuture = null;
      }
    }));
  }

  Future<void> _resubscribeWithRetry() async {
    _resubscribeTimer?.cancel();
    _resubscribeTimer = null;
    try {
      await _resubscribe();
    } catch (e) {
      if (_disposed) return;
      _transport._log('[$_logTag] resubscribe failed: $e');
      _resubscribeTimer = Timer(const Duration(seconds: 3), () {
        if (!_disposed && _subscriptionId == null) _onBridgeRecovered();
      });
    }
  }

  Future<void> _resubscribe() async {
    if (_disposed) return;
    final oldId = _subscriptionId;
    // Mark the subscription unavailable before handshake so a handshake
    // failure enters the existing retry timer instead of looking healthy
    // forever under the old (now dead) subscription id.
    _subscriptionId = null;
    await _transport.handshake();
    if (_disposed) return;
    _onResubscribeCleanup();
    final cancel = _cancelFrameListener;
    _cancelFrameListener = null;
    cancel?.call();
    _stagedFrames.clear();
    _fragments.clear();
    _fragmentBytes = 0;
    if (oldId != null && !_transport.session.isDisposed) {
      try {
        await _transport._channels.call(
          ConversationTransport.channel,
          _unsubscribeMethod,
          [{..._transport.scope, 'subscriptionId': oldId, ..._unsubscribeArgs}],
        );
      } catch (_) {}
    }
    await _start();
  }

  void _handleWireFrame(dynamic data) {
    if (_disposed || data is! Map) return;
    final frame = data.cast<String, dynamic>();
    if (frame['topic'] != topic) return;
    switch (frame['kind']) {
      case 'complete':
        final inner = frame['frame'];
        if (inner is Map) {
          try {
            _acceptOrStage(inner.cast<String, dynamic>());
          } catch (e) {
            // Protocol drift must not kill the whole subscription: skip the
            // malformed frame and leave evidence for diagnosis.
            _transport._log('[$_logTag][诊断] 逻辑帧处理失败，已跳过该帧: $e — '
                '桌面端协议可能已变更，请导出协议日志反馈');
          }
        }
        break;
      case 'fragment':
        _acceptFragment(frame);
        break;
      default:
        _transport._log('[$_logTag][诊断] 未知 wire 帧类型 "${frame['kind']}"'
            '（字段: ${frame.keys.toList().join(', ')}）— '
            '桌面端协议可能已变更，请导出协议日志反馈');
        break;
    }
  }

  void _acceptOrStage(Map<String, dynamic> frame) {
    if (_subscriptionId == null) {
      if (_stagedFrames.length < _maxStagedFrames) {
        _stagedFrames.add(frame);
      } else {
        _transport._log('[$_logTag] staged frame limit reached');
      }
      return;
    }
    _acceptLogicalFrame(frame);
  }

  void _acceptFragment(Map<String, dynamic> frame) {
    try {
      final id = frame['logicalFrameId'] as String?;
      final index = (frame['fragmentIndex'] as num?)?.toInt();
      final count = (frame['fragmentCount'] as num?)?.toInt();
      final messageBytes = (frame['messageBytes'] as num?)?.toInt();
      final dataBase64 = frame['dataBase64'] as String?;
      if (id == null ||
          id.isEmpty ||
          index == null ||
          count == null ||
          dataBase64 == null) {
        return;
      }
      if (index < 0 ||
          count <= 0 ||
          count > _maxLogicalFragments ||
          index >= count ||
          (messageBytes != null &&
              (messageBytes <= 0 || messageBytes > _maxLogicalFrameBytes))) {
        _transport._log('[$_logTag] invalid logical fragment bounds');
        _dropFragment(id);
        return;
      }
      final Uint8List chunk;
      try {
        chunk = base64.decode(dataBase64);
      } catch (_) {
        _dropFragment(id);
        return;
      }
      if (chunk.isEmpty || chunk.length > _maxLogicalFrameBytes) {
        _dropFragment(id);
        return;
      }
      var assembly = _fragments[id];
      if (assembly == null) {
        if (_fragments.length >= _maxFragmentAssemblies ||
            _fragmentBytes + chunk.length > _maxFragmentBytes) {
          _transport._log('[$_logTag] logical fragment limit reached');
          return;
        }
        assembly = _LogicalFrameAssembly(count, messageBytes);
        _fragments[id] = assembly;
      } else if (!assembly.matches(count, messageBytes)) {
        _transport._log('[$_logTag] logical fragment metadata mismatch');
        _dropFragment(id);
        return;
      }
      final added = assembly.add(index, chunk);
      if (added) _fragmentBytes += chunk.length;
      if (assembly.receivedBytes > _maxLogicalFrameBytes ||
          (messageBytes != null && assembly.receivedBytes > messageBytes)) {
        _transport._log('[$_logTag] logical fragment exceeds declared size');
        _dropFragment(id);
        return;
      }
      if (!assembly.isComplete) return;
      _dropFragment(id);
      final bytes = assembly.assemble();
      if (messageBytes != null && bytes.length != messageBytes) {
        _transport._log('[$_logTag] logical fragment size mismatch');
        return;
      }
      try {
        final decoded = jsonDecode(utf8.decode(bytes));
        if (decoded is Map) {
          _acceptOrStage(decoded.cast<String, dynamic>());
        }
      } catch (e) {
        _transport._log('[$_logTag] bad logical frame: $e');
      }
    } catch (e) {
      _transport._log('[$_logTag] malformed logical fragment: $e');
    }
  }

  Future<void> _resync() async {
    final id = _subscriptionId;
    if (id == null || _disposed || _resyncing) return;
    _resyncing = true;
    _transport._log(
        '[$_logTag] resync (gap detected) seq=$_resyncSeq logEpoch=$_resyncEpoch');
    try {
      await _transport._channels.call(
        ConversationTransport.channel,
        _resyncMethod,
        [
          {
            ..._transport.scope,
            'subscriptionId': id,
            ..._resyncArgs,
            if (_resyncEpoch != null)
              'base': {'logEpoch': _resyncEpoch, 'seq': _resyncSeq},
          },
        ],
      );
    } catch (e) {
      _transport._log('[$_logTag] resync failed: $e');
    } finally {
      _resyncing = false;
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    _resubscribeTimer?.cancel();
    _fragmentCleanup?.cancel();
    await _onDispose();
    _transport.session.recovered.removeListener(_onBridgeRecovered);
    final cancel = _cancelFrameListener;
    _cancelFrameListener = null;
    cancel?.call();
    final id = _subscriptionId;
    _subscriptionId = null;
    if (id != null) {
      try {
        await _transport._channels.call(
          ConversationTransport.channel,
          _unsubscribeMethod,
          [
            {..._transport.scope, 'subscriptionId': id, ..._unsubscribeArgs},
          ],
        );
      } catch (_) {}
    }
    _fragments.clear();
    _fragmentBytes = 0;
  }
}

class ConversationSubscription extends _SubscriptionBase<ConversationState> {
  final String sessionId;

  DateTime _lastFrameAt = DateTime.now();
  Timer? _watchdog;

  ConversationSubscription._(ConversationTransport transport, this.sessionId)
      : super(transport, ConversationState(), 'v4');

  @override String get _frameEventName => 'onDynamicConversationFrame';
  @override String get _subscribeMethod => 'subscribeConversationV4';
  @override String get _unsubscribeMethod => 'unsubscribeConversationV4';
  @override String get _resyncMethod => 'resyncConversationV4';
  @override Map<String, dynamic> get _subscribeArgs => {'sessionId': sessionId};
  @override Map<String, dynamic> get _unsubscribeArgs => const {};
  @override Map<String, dynamic> get _resyncArgs => const {'forceSnapshot': true};
  @override String get topic => 'conversation/$sessionId';
  @override int get _resyncSeq => state.seq;
  @override String? get _resyncEpoch => state.logEpoch;

  @override
  void _onSubscribeAck(Map<String, dynamic> ack) {
    if (ack['logEpoch'] is String) {
      state.logEpoch = ack['logEpoch'] as String;
    }
  }

  @override
  void _onStarted() {
    _startWatchdog();
  }

  @override
  void _onResubscribeCleanup() {
    _watchdog?.cancel();
  }

  @override
  Future<void> _onDispose() async {
    _watchdog?.cancel();
    _transport._untrackSubscription(sessionId, this);
    state.dispose();
  }

  @override
  void _acceptLogicalFrame(Map<String, dynamic> frame) {
    final subId = subscriptionId;
    if (subId == null || frame['subscriptionId'] != subId) return;
    _lastFrameAt = DateTime.now();
    state.applyFrame(frame, onGap: _resync);
  }

  void _startWatchdog() {
    _watchdog?.cancel();
    _watchdog = Timer.periodic(const Duration(seconds: 10), (_) {
      if (_disposed) return;
      final quietSeconds =
          DateTime.now().difference(_lastFrameAt).inSeconds;
      if (quietSeconds < 20) return;
      final streaming = state.rows.any((r) => r['state'] == 'streaming');
      if (state.isRunning || streaming) {
        _transport._log(
            '[v4] watchdog: no frames for ${quietSeconds}s while active, resync');
        _resync();
      }
    });
  }
}

class WorkspacePrep {
  final List<ConfigOption> configOptions;
  final List<SlashCommand> slashCommands;
  final Map raw;

  WorkspacePrep._(this.raw)
      : configOptions = [
          if (raw['configOptions'] is List)
            for (final o in raw['configOptions'] as List)
              if (o is Map) ConfigOption._(o),
        ],
        slashCommands = [
          if (raw['slashCommands'] is List)
            for (final c in raw['slashCommands'] as List)
              if (c is Map) SlashCommand._(c),
        ];

  ConfigOption? option(String id) {
    for (final o in configOptions) {
      if (o.id == id) return o;
    }
    return null;
  }
}

/// A desktop skill (`skills.list`), triggered in the composer as `$name`.
class SkillEntry {
  final String id;
  final String name;
  final String path;
  final String scope;
  final String? description;
  final String? argumentHint;
  final bool enabled;

  SkillEntry._(Map raw)
      : id = '${raw['id'] ?? ''}',
        name = '${raw['name'] ?? ''}',
        path = '${raw['path'] ?? ''}',
        scope = '${raw['scope'] ?? 'workspace'}',
        description = raw['description'] as String?,
        argumentHint = raw['argumentHint'] as String?,
        enabled = raw['enabled'] != false;
}

class ConfigOption {
  final String id;
  final String name;
  final String category;
  final String type;
  final Object? currentValue;
  final List<ConfigOptionValue> options;

  ConfigOption._(Map raw)
      : id = '${raw['id'] ?? ''}',
        name = '${raw['name'] ?? ''}',
        category = '${raw['category'] ?? ''}',
        type = '${raw['type'] ?? ''}',
        currentValue = raw['currentValue'],
        options = [
          if (raw['options'] is List)
            for (final v in raw['options'] as List)
              if (v is Map) ConfigOptionValue._(v),
        ];
}

class ConfigOptionValue {
  final String value;
  final String name;
  final String? description;
  final String? modelProviderName;

  /// 宿主注册表里的 provider id(switchModelConfig 的 provider 参数必须
  /// 用它,value 前缀里的 "builtin:x" 不是注册表 id)。
  final String? modelProviderId;
  final List<String> modelThoughtLevels;

  ConfigOptionValue._(Map raw)
      : value = '${raw['value'] ?? ''}',
        name = '${raw['name'] ?? raw['value'] ?? ''}',
        description = raw['description'] as String?,
        modelProviderName = raw['modelProviderName'] as String?,
        modelProviderId = raw['modelProviderId'] as String?,
        modelThoughtLevels = [
          if (raw['modelThoughtLevels'] is List)
            for (final v in raw['modelThoughtLevels'] as List) '$v',
        ];
}

class SlashCommand {
  final String name;
  final String description;
  final String? inputHint;
  final String source;

  SlashCommand._(Map raw)
      : name = '${raw['name'] ?? ''}',
        description = '${raw['description'] ?? ''}',
        inputHint = raw['inputHint'] as String?,
        source = '${raw['source'] ?? ''}';
}

class _LogicalFrameAssembly {
  final int count;
  final int? messageBytes;
  final List<Uint8List?> parts;
  final DateTime createdAt = DateTime.now();
  int received = 0;

  _LogicalFrameAssembly(this.count, this.messageBytes)
      : parts = List<Uint8List?>.filled(count, null);

  int get receivedBytes =>
      parts.fold<int>(0, (sum, part) => sum + (part?.length ?? 0));

  bool matches(int otherCount, int? otherBytes) =>
      count == otherCount && messageBytes == otherBytes;

  bool add(int index, Uint8List data) {
    if (index < 0 || index >= count || parts[index] != null) return false;
    parts[index] = data;
    received += 1;
    return true;
  }

  bool get isComplete => received == count;

  Uint8List assemble() {
    final builder = BytesBuilder();
    for (final p in parts) {
      if (p != null) builder.add(p);
    }
    return builder.toBytes();
  }
}

/// Live sessions-index state (task list of a workspace), mirrors the
/// sessions-index subscription in the web client (`QAe` delta application).
class SessionEntry {
  final String sessionId;
  final String? parentSessionId;
  final String title;
  final String phase;
  final String? lastAssistantPreview;
  final int lastActivityAt;
  final int createdAt;
  final bool hasBackgroundWork;
  final Map<String, dynamic>? pendingInteraction;
  final Map<String, dynamic> raw;

  /// 归档时间戳(宿主 time_archived);0/缺省 = 未归档。桌面端归档后
  /// 列表数据会带上该字段,列表据此分流到「归档」组。
  ///
  /// 字段名双方言:V4 索引(phase/lastActivityAt/archived)与
  /// listSessions 的 Bae 投影(status/updatedAt/archivedAt)并存,
  /// 解析时两套都认。
  final int archivedAt;

  bool get isArchived => archivedAt > 0;

  SessionEntry(this.raw)
      : sessionId = '${raw['sessionId'] ?? ''}',
        parentSessionId = raw['parentSessionId'] as String?,
        title = '${raw['title'] ?? ''}',
        phase = '${raw['phase'] ?? raw['status'] ?? ''}',
        lastAssistantPreview = raw['lastAssistantPreview'] as String?,
        lastActivityAt = (raw['lastActivityAt'] as num?)?.toInt() ??
            (raw['updatedAt'] as num?)?.toInt() ??
            0,
        createdAt = (raw['createdAt'] as num?)?.toInt() ?? 0,
        hasBackgroundWork = raw['hasBackgroundWork'] == true,
        archivedAt = (raw['archived'] as num?)?.toInt() ??
            (raw['archivedAt'] as num?)?.toInt() ??
            0,
        pendingInteraction =
            (raw['pendingInteraction'] as Map?)?.cast<String, dynamic>();
}

class SessionsIndexState extends ChangeNotifier {
  String? workspaceId;
  String? logEpoch;
  int seq = 0;
  final Map<String, SessionEntry> sessions = {};
  bool ready = false;

  int _sessionsVersion = 0;
  int _sortedSessionsVersion = -1;
  int _nextSessionOrder = 0;
  final Map<String, int> _sessionOrder = {};
  List<SessionEntry>? _sortedSessions;

  List<SessionEntry> get list {
    if (_sortedSessionsVersion != _sessionsVersion) {
      final values = sessions.values.toList(growable: true)
        ..sort((a, b) {
          final activity = b.lastActivityAt.compareTo(a.lastActivityAt);
          if (activity != 0) return activity;
          return (_sessionOrder[a.sessionId] ?? 0)
              .compareTo(_sessionOrder[b.sessionId] ?? 0);
        });
      _sortedSessions = List.unmodifiable(values);
      _sortedSessionsVersion = _sessionsVersion;
    }
    return _sortedSessions!;
  }

  void _sessionsChanged() {
    _sessionsVersion++;
    _sortedSessionsVersion = -1;
    _sortedSessions = null;
  }

  void _ensureSessionOrder(String sessionId) {
    _sessionOrder.putIfAbsent(sessionId, () => _nextSessionOrder++);
  }

  void applyFrame(Map<String, dynamic> frame,
      {required void Function() onGap}) {
    final payload = frame['payload'];
    if (payload is! Map) return;
    final toSeq = (frame['toSeq'] as num?)?.toInt() ?? seq;

    if (payload['kind'] == 'snapshot') {
      final snap = (payload['snapshot'] as Map).cast<String, dynamic>();
      workspaceId = snap['workspaceId'] as String?;
      logEpoch = snap['logEpoch'] as String?;
      sessions.clear();
      _sessionOrder.clear();
      _nextSessionOrder = 0;
      final list = snap['sessions'];
      if (list is List) {
        for (final s in list) {
          if (s is Map) {
            final entry =
                SessionEntry(s.cast<String, dynamic>());
            _ensureSessionOrder(entry.sessionId);
            sessions[entry.sessionId] = entry;
          }
        }
      }
      _sessionsChanged();
      seq = toSeq;

    } else if (payload['kind'] == 'deltas') {
      final fromSeq = (frame['fromSeq'] as num?)?.toInt() ?? seq;
      if (fromSeq != seq) {
        onGap();
        return;
      }
      final deltas = payload['deltas'];
      if (deltas is List) {
        for (final d in deltas) {
          if (d is! Map) continue;
          if (d['op'] == 'session.upserted' && d['session'] is Map) {
            final entry = SessionEntry(
                (d['session'] as Map).cast<String, dynamic>());
            _ensureSessionOrder(entry.sessionId);
            sessions[entry.sessionId] = entry;
            _sessionsChanged();
          } else if (d['op'] == 'session.removed') {
            final id = '${d['sessionId']}';
            if (sessions.remove(id) != null) {
              _sessionOrder.remove(id);
              _sessionsChanged();
            }
          }
        }
      }
      seq = toSeq;
    }
    ready = true;
    notifyListeners();
  }
}

class _SessionsIndexWireSubscription
    extends _SubscriptionBase<SessionsIndexState> {
  _SessionsIndexWireSubscription(ConversationTransport transport)
      : super(transport, SessionsIndexState(), 'v4-si');

  @override String get _frameEventName => 'onDynamicSessionsIndexFrame';
  @override String get _subscribeMethod => 'subscribeSessionsIndexV4';
  @override String get _unsubscribeMethod => 'unsubscribeSessionsIndexV4';
  @override String get _resyncMethod => 'resyncSessionsIndexV4';
  @override
  Map<String, dynamic> get _subscribeArgs =>
      const {'runtimePolicy': 'existing-only'};
  @override
  Map<String, dynamic> get _unsubscribeArgs =>
      const {'runtimePolicy': 'existing-only'};
  @override
  Map<String, dynamic> get _resyncArgs =>
      const {'runtimePolicy': 'existing-only'};
  @override
  String get topic =>
      'sessions-index/${_transport.scope['workspaceIdentity'] ?? _transport.scope['workspacePath']}';
  @override int get _resyncSeq => state.seq;
  @override String? get _resyncEpoch => state.logEpoch;

  @override
  Future<void> _onDispose() async {
    state.dispose();
  }

  @override
  void _acceptLogicalFrame(Map<String, dynamic> frame) {
    final subId = subscriptionId;
    if (subId == null || frame['subscriptionId'] != subId) return;
    state.applyFrame(frame, onGap: _resync);
  }
}

class _SharedSessionsIndex {
  final ConversationTransport _transport;
  _SessionsIndexWireSubscription? _wire;
  Future<_SessionsIndexWireSubscription>? _starting;
  Future<void>? _stopping;
  int _references = 0;
  bool _disposed = false;

  String? get subscriptionId => _wire?.subscriptionId;
  String get topic =>
      'sessions-index/${_transport.scope['workspaceIdentity'] ?? _transport.scope['workspacePath']}';

  _SharedSessionsIndex(this._transport);

  Future<SessionsIndexSubscription> acquire() async {
    if (_disposed) throw StateError('sessions-index registry disposed');
    final stopping = _stopping;
    if (stopping != null) await stopping;
    if (_disposed) throw StateError('sessions-index registry disposed');
    var wire = _wire;
    if (wire == null) {
      final starting = _starting ??= _startWire();
      try {
        wire = await starting;
      } finally {
        if (identical(_starting, starting)) _starting = null;
      }
    }
    if (_disposed || wire._disposed) {
      throw StateError('sessions-index registry disposed');
    }
    _references++;
    return SessionsIndexSubscription._(this, wire.state);
  }

  Future<_SessionsIndexWireSubscription> _startWire() async {
    await _transport.handshake();
    if (_disposed) throw StateError('sessions-index registry disposed');
    final wire = _SessionsIndexWireSubscription(_transport);
    try {
      await wire._start();
    } catch (_) {
      await wire.dispose();
      rethrow;
    }
    if (_disposed) {
      await wire.dispose();
      throw StateError('sessions-index registry disposed');
    }
    _wire = wire;
    return wire;
  }

  Future<void> release() async {
    if (_references == 0) return;
    _references--;
    if (_references != 0) return;
    final wire = _wire;
    _wire = null;
    if (wire != null) {
      final stopping = wire.dispose();
      _stopping = stopping;
      try {
        await stopping;
      } finally {
        if (identical(_stopping, stopping)) _stopping = null;
      }
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _references = 0;
    final starting = _starting;
    final stopping = _stopping;
    if (stopping != null) await stopping;
    final wire = _wire;
    _wire = null;
    if (wire != null) await wire.dispose();
    if (starting != null) {
      try {
        final pending = await starting;
        if (!identical(pending, wire)) await pending.dispose();
      } catch (_) {}
    }
  }
}

class SessionsIndexSubscription {
  final _SharedSessionsIndex _shared;
  final SessionsIndexState state;
  bool _disposed = false;

  SessionsIndexSubscription._(this._shared, this.state);

  String? get subscriptionId => _shared.subscriptionId;
  String get topic => _shared.topic;

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _shared.release();
  }
}

/// Conversation snapshot + row state, mirrors `fke()`/`pke()` delta
/// application in the web client.
class ConversationState extends ChangeNotifier {
  Map<String, dynamic>? snapshot;
  List<Map<String, dynamic>> _rows = [];
  int _rowsVersion = 0;
  int _rowIndexVersion = -1;
  final Map<int, int> _rowIdIndex = {};
  final Set<int> _duplicateRowIds = {};

  List<Map<String, dynamic>> get rows => _rows;

  set rows(List<Map<String, dynamic>> value) {
    _replaceRows(value);
  }

  /// Version of the row collection for UI-derived caches. This is separate
  /// from [seq] because history paging changes rows without advancing the
  /// wire sequence.
  int get rowsVersion => _rowsVersion;

  void _replaceRows(List<Map<String, dynamic>> value) {
    _rows = value;
    _rowsVersion++;
    _rowIndexVersion = -1;
    _markDomains(_domainRows);
  }

  void _rowsChanged() {
    _rowsVersion++;
    _rowIndexVersion = -1;
    _markDomains(_domainRows);
  }

  int? _normalizedRowId(Object? value) =>
      value is num ? value.toInt() : null;

  void _ensureRowIndex() {
    if (_rowIndexVersion == _rowsVersion) return;
    _rowIdIndex.clear();
    _duplicateRowIds.clear();
    for (var i = 0; i < _rows.length; i++) {
      final id = _normalizedRowId(_rows[i]['rowId']);
      if (id == null || _duplicateRowIds.contains(id)) continue;
      final previous = _rowIdIndex[id];
      if (previous != null) {
        _rowIdIndex.remove(id);
        _duplicateRowIds.add(id);
      } else {
        _rowIdIndex[id] = i;
      }
    }
    _rowIndexVersion = _rowsVersion;
  }

  int _indexOfRowId(num? rowId) {
    final id = _normalizedRowId(rowId);
    if (id == null) {
      return _rows.indexWhere((row) => row['rowId'] == null);
    }
    _ensureRowIndex();
    if (_duplicateRowIds.contains(id)) {
      return _rows.indexWhere(
          (row) => _normalizedRowId(row['rowId']) == id);
    }
    return _rowIdIndex[id] ?? -1;
  }

  int seq = 0;
  String? logEpoch;
  int? firstRowId;
  int totalCount = 0;
  bool ready = false;

  static const _domainRows = 1 << 0;
  static const _domainControl = 1 << 1;
  static const _domainConfig = 1 << 2;
  static const _domainUsage = 1 << 3;
  static const _domainQueue = 1 << 4;
  static const _domainInteraction = 1 << 5;
  static const _domainBackground = 1 << 6;
  static const _domainAll = _domainRows |
      _domainControl |
      _domainConfig |
      _domainUsage |
      _domainQueue |
      _domainInteraction |
      _domainBackground;

  final _rowsNotifier = ChangeNotifier();
  final _controlNotifier = ChangeNotifier();
  final _configNotifier = ChangeNotifier();
  final _usageNotifier = ChangeNotifier();
  final _queueNotifier = ChangeNotifier();
  final _interactionNotifier = ChangeNotifier();
  final _backgroundNotifier = ChangeNotifier();
  int _pendingDomainMask = 0;

  Listenable get rowsListenable => _rowsNotifier;
  Listenable get controlListenable => _controlNotifier;
  Listenable get configListenable => _configNotifier;
  Listenable get usageListenable => _usageNotifier;
  Listenable get queueListenable => _queueNotifier;
  Listenable get interactionListenable => _interactionNotifier;
  Listenable get backgroundListenable => _backgroundNotifier;

  void _markDomains(int mask) {
    _pendingDomainMask |= mask;
  }

  void _markSnapshotDomains(Map<String, dynamic> patch) {
    var mask = 0;
    if (patch.containsKey('control') ||
        patch.containsKey('plan') ||
        patch.containsKey('goal')) {
      mask |= _domainControl;
    }
    if (patch.containsKey('config')) mask |= _domainConfig;
    if (patch.containsKey('usage')) mask |= _domainUsage;
    if (patch.containsKey('queue')) mask |= _domainQueue;
    if (patch.containsKey('inputRouting') ||
        patch.containsKey('pendingInteractions')) {
      mask |= _domainInteraction;
    }
    if (patch.containsKey('backgroundWorks') ||
        patch.containsKey('subagents')) {
      mask |= _domainBackground;
    }
    if (patch.containsKey('rows')) mask |= _domainRows;
    _markDomains(mask);
  }

  void _notifyDomains(int mask) {
    if (mask & _domainRows != 0) _rowsNotifier.notifyListeners();
    if (mask & _domainControl != 0) _controlNotifier.notifyListeners();
    if (mask & _domainConfig != 0) _configNotifier.notifyListeners();
    if (mask & _domainUsage != 0) _usageNotifier.notifyListeners();
    if (mask & _domainQueue != 0) _queueNotifier.notifyListeners();
    if (mask & _domainInteraction != 0) {
      _interactionNotifier.notifyListeners();
    }
    if (mask & _domainBackground != 0) {
      _backgroundNotifier.notifyListeners();
    }
  }

  // Streaming bursts fire many small deltas per second; notifying the UI on
  // each one burns the main thread on full-list rebuilds. Coalesce: at most
  // one notify per 100ms, flushed on the timer (a trailing notify lands ≤
  // 100ms after the last frame — imperceptible for chat streaming).
  Timer? _notifyTimer;

  void _scheduleNotify() {
    _notifyTimer ??= Timer(const Duration(milliseconds: 100), () {
      _notifyTimer = null;
      final mask = _pendingDomainMask;
      _pendingDomainMask = 0;
      _notifyDomains(mask);
      notifyListeners();
    });
  }

  @override
  void dispose() {
    _notifyTimer?.cancel();
    _rowsNotifier.dispose();
    _controlNotifier.dispose();
    _configNotifier.dispose();
    _usageNotifier.dispose();
    _queueNotifier.dispose();
    _interactionNotifier.dispose();
    _backgroundNotifier.dispose();
    super.dispose();
  }

  void applyFrame(
    Map<String, dynamic> frame, {
    required void Function() onGap,
  }) {
    final payload = frame['payload'];
    if (payload is! Map) return;
    final toSeq = (frame['toSeq'] as num?)?.toInt() ?? seq;

    if (payload['kind'] == 'snapshot') {
      final snap = (payload['snapshot'] as Map).cast<String, dynamic>();
      _applySnapshot(snap, toSeq);
    } else if (payload['kind'] == 'deltas') {
      final fromSeq = (frame['fromSeq'] as num?)?.toInt() ?? seq;
      if (fromSeq != seq) {
        onGap();
        return;
      }
      final deltas = payload['deltas'];
      if (deltas is List) {
        for (final d in deltas) {
          if (d is Map) _applyDelta(d.cast<String, dynamic>());
        }
      }
      seq = toSeq;
    }
    ready = true;
    _scheduleNotify();
  }

  void _applySnapshot(Map<String, dynamic> snap, int toSeq) {
    snapshot = snap;
    _markDomains(_domainAll);
    if (_pendingPatch != null) {
      snapshot = {...snap, ..._pendingPatch!};
      _pendingPatch = null;
    }
    seq = toSeq;
    logEpoch = snap['logEpoch'] as String?;
    final rowsObj = snap['rows'];
    if (rowsObj is Map) {
      final window = rowsObj['window'];
      if (window is List) {
        // Snapshots carry only a tail window: keep the older rows already
        // loaded via rowsRange (rowId below the window head). A resync
        // (gap, lock-screen reconnect, bridge recovery) must not wipe the
        // paged-in history — the list would collapse and the viewport
        // would slam to its top. View-layer arrival stamps carry over by
        // rowId for the same reason.
        final windowList = window.whereType<Map>().toList();
        final windowHeadRowId =
            windowList.isEmpty ? null : (windowList.first['rowId'] as num?)?.toInt();
        final prev = <String, dynamic>{};
        final keepOld = <Map<String, dynamic>>[];
        for (final r in rows) {
          final id = r['rowId'];
          if (id != null) prev['$id'] = r['_zflowTs'];
          final rowId = (id as num?)?.toInt();
          if (rowId != null &&
              windowHeadRowId != null &&
              rowId < windowHeadRowId) {
            keepOld.add(r);
          }
        }
        final list = <Map<String, dynamic>>[];
        for (final e in windowList) {
          final row = e.cast<String, dynamic>();
          final ts = prev['${row['rowId']}'];
          if (ts != null) row['_zflowTs'] = ts;
          list.add(row);
        }
        _replaceRows([...keepOld, ...list]);
      } else {
        _replaceRows([]);
      }
      totalCount = (rowsObj['totalCount'] as num?)?.toInt() ?? rows.length;
      firstRowId = (rowsObj['firstRowId'] as num?)?.toInt();
    } else {
      _replaceRows([]);
      totalCount = 0;
      firstRowId = null;
    }
  }

  void _applyDelta(Map<String, dynamic> delta) {
    switch (delta['op']) {
      case 'row.appended':
        final row = (delta['row'] as Map).cast<String, dynamic>();
        // View-layer arrival stamp (ms since epoch). The wire rows carry no
        // timestamps, so the UI can only show times for rows observed live;
        // history loaded from snapshots stays unstamped. Never sent back.
        row['_zflowTs'] = DateTime.now().millisecondsSinceEpoch;
        rows.add(row);
        _rowsChanged();
        if (row['kind'] == 'subagent') _markDomains(_domainBackground);
        totalCount += 1;
        firstRowId ??= (row['rowId'] as num?)?.toInt();
        break;
      case 'row.upserted':
        final row = (delta['row'] as Map).cast<String, dynamic>();
        final id = (row['rowId'] as num?)?.toInt();
        final index = _indexOfRowId(id);
        if (index != -1) {
          // Upserts replace the whole row; keep the original arrival stamp
          // so streaming edits don't reset the bubble's displayed time.
          // (Guarded write: the wire map may be typed with non-nullable
          // values, which rejects a null assignment.)
          final wasSubagent = rows[index]['kind'] == 'subagent';
          final prev = rows[index]['_zflowTs'];
          if (prev != null) row['_zflowTs'] = prev;
          rows[index] = row;
          _rowsChanged();
          if (wasSubagent || row['kind'] == 'subagent') {
            _markDomains(_domainBackground);
          }
        }
        break;
      case 'row.removed':
        // Mirrors `fke()` in the web client: KEEP rows with
        // rowId < fromRowId (i.e. remove rows >= fromRowId).
        final fromRowId = (delta['fromRowId'] as num?)?.toInt() ?? 0;
        final kept = rows
            .where((r) => ((r['rowId'] as num?)?.toInt() ?? 0) < fromRowId)
            .toList();
        final removed = rows.length - kept.length;
        final removedSubagent = rows.any((row) =>
            row['kind'] == 'subagent' &&
            ((row['rowId'] as num?)?.toInt() ?? 0) >= fromRowId);
        if (removed > 0) {
          if (removedSubagent) _markDomains(_domainBackground);
          _replaceRows(kept);
        }
        if (firstRowId != null && fromRowId <= firstRowId!) {
          totalCount = 0;
          firstRowId = null;
        } else {
          totalCount = (totalCount - removed).clamp(0, 1 << 31);
        }
        break;
      case 'row.delta':
        final rowId = (delta['rowId'] as num?)?.toInt();
        final path = delta['path'] as String?;
        final append = delta['append'] as String? ?? '';
        final index = _indexOfRowId(rowId);
        if (index != -1) {
          final wasSubagent = rows[index]['kind'] == 'subagent';
          rows[index] = _appendToRow(rows[index], path, append);
          _rowsChanged();
          if (wasSubagent) _markDomains(_domainBackground);
        }
        break;
      case 'state.updated':
        final patch = delta['patch'];
        if (patch is Map) {
          final normalizedPatch = patch.cast<String, dynamic>();
          if (snapshot != null) {
            snapshot = {...snapshot!, ...normalizedPatch};
          } else {
            // Patch arrived before the initial snapshot — buffer and
            // merge when the snapshot lands (otherwise config/queue/
            // control updates are silently lost).
            _pendingPatch = {
              ...?_pendingPatch,
              ...normalizedPatch,
            };
          }
          _markSnapshotDomains(normalizedPatch);
        }
        break;
    }
  }

  Map<String, dynamic>? _pendingPatch;

  /// Optimistic local update (command already accepted; the confirming
  /// `state.updated` frame may lag). Merges into snapshot immediately.
  void optimisticPatch(Map<String, dynamic> patch) {
    if (snapshot == null) return;
    snapshot = {...snapshot!, ...patch};
    _markSnapshotDomains(patch);
    _scheduleNotify();
  }

  /// Optimistic row edit (e.g. feedback) — mutates the row in place and
  /// notifies; the server row.upserted will confirm.
  void optimisticRowUpdate(num? rowId, Map<String, dynamic> patch) {
    final index = _indexOfRowId(rowId);
    if (index == -1) return;
    rows[index] = {...rows[index], ...patch};
    final isSubagent = rows[index]['kind'] == 'subagent';
    _rowsChanged();
    if (isSubagent) _markDomains(_domainBackground);
    _scheduleNotify();
  }

  /// Optimistic queue removal (sendQueuedNow / deleteQueueItem accepted).
  void optimisticRemoveQueueItem(String queueItemId) {
    final q = queue;
    if (q == null) return;
    final items = (q['items'] as List?)
        ?.where((i) => i is Map && '${i['queueItemId']}' != queueItemId)
        .toList();
    snapshot = {
      ...snapshot!,
      'queue': {...q, 'items': items ?? []},
    };
    _markDomains(_domainQueue);
    _scheduleNotify();
  }

  /// Mirrors `dke()`: append streamed text to a row field.
  Map<String, dynamic> _appendToRow(
      Map<String, dynamic> row, String? path, String append) {
    switch (path) {
      case 'text':
        if (row['kind'] == 'assistantText' || row['kind'] == 'reasoning') {
          return {...row, 'text': '${row['text'] ?? ''}$append'};
        }
        return row;
      case 'inputText':
        if (row['kind'] == 'toolCall') {
          return {...row, 'inputText': '${row['inputText'] ?? ''}$append'};
        }
        return row;
      case 'output.text':
        if (row['kind'] == 'toolCall' && row['output'] is Map) {
          final output = (row['output'] as Map).cast<String, dynamic>();
          return {
            ...row,
            'output': {...output, 'text': '${output['text'] ?? ''}$append'},
          };
        }
        return row;
      case 'summaryText':
        if (row['kind'] == 'subagent') {
          return {
            ...row,
            'summaryText': '${row['summaryText'] ?? ''}$append',
          };
        }
        return row;
      default:
        return row;
    }
  }

  Map<String, dynamic>? get control =>
      (snapshot?['control'] as Map?)?.cast<String, dynamic>();

  /// Current conversation revision (CAS commands base this on).
  int get revision =>
      (snapshot?['revision'] as num?)?.toInt() ?? 0;

  String get phase => control?['phase'] as String? ?? '';

  bool get canStop => control?['canStop'] == true;

  bool get isRunning =>
      phase == 'running' || phase == 'prewarming';

  /// Session config: {provider, model, thought, thoughtLevels, followupMode,
  /// mode}.
  Map<String, dynamic>? get config =>
      (snapshot?['config'] as Map?)?.cast<String, dynamic>();

  String get currentModel => config?['model'] as String? ?? '';
  String get currentThought => config?['thought'] as String? ?? '';
  String get currentMode => config?['mode'] as String? ?? 'build';
  List<String> get thoughtLevels => config?['thoughtLevels'] is List
      ? (config!['thoughtLevels'] as List).map((e) => '$e').toList()
      : const [];

  /// Held queue: {items: [...], autoDrain}.
  Map<String, dynamic>? get queue =>
      (snapshot?['queue'] as Map?)?.cast<String, dynamic>();

  List<Map<String, dynamic>> get queueItems {
    final items = queue?['items'];
    if (items is! List) return const [];
    return items
        .whereType<Map>()
        .map((e) => e.cast<String, dynamic>())
        .toList();
  }

  bool get autoDrain => queue?['autoDrain'] != false;

  /// Token usage: {contextWindow: {usedTokens, maxTokens, ...}?, cumulative}.
  Map<String, dynamic>? get usage =>
      (snapshot?['usage'] as Map?)?.cast<String, dynamic>();

  /// Older history exists beyond the current window. Cleared logically by
  /// [historyExhausted] once the server reports no more rows — the
  /// snapshot's totalCount can stay above the loaded count while the
  /// projection itself is out of paged rows.
  bool get canLoadOlder =>
      !historyExhausted && firstRowId != null && totalCount > rows.length;

  /// Set when rowsRange came back empty with hasMore=false: there is
  /// nothing older to fetch even though totalCount still counts rows the
  /// profile filtered out.
  bool historyExhausted = false;

  void markHistoryExhausted(bool value) {
    if (historyExhausted == value) return;
    historyExhausted = value;
    _markDomains(_domainRows);
    _scheduleNotify();
  }

  /// rowsRange pagination cursor: the OLDEST row we already hold. The
  /// snapshot's firstRowId is the FULL projection's head (not the window
  /// head) — using it as beforeRowId filters everything out.
  int? get oldestRowId => rows.isEmpty
      ? firstRowId
      : (rows.first['rowId'] as num?)?.toInt();

  /// Prepends older rows loaded via rowsRange (deduped by rowId).
  void prependOlderRows(List<Map<String, dynamic>> older, int? newFirstRowId) {
    final existing =
        rows.map((r) => (r['rowId'] as num?)?.toInt()).toSet();
    final fresh = older
        .where((r) => !existing.contains((r['rowId'] as num?)?.toInt()))
        .toList();
    if (fresh.isNotEmpty) {
      _replaceRows([...fresh, ...rows]);
      if (fresh.any((row) => row['kind'] == 'subagent')) {
        _markDomains(_domainBackground);
      }
      final firstFresh = (fresh.first['rowId'] as num?)?.toInt();
      firstRowId = newFirstRowId ?? firstFresh ?? firstRowId;
      _scheduleNotify();
    } else if (newFirstRowId != null && newFirstRowId != firstRowId) {
      firstRowId = newFirstRowId;
      _markDomains(_domainRows);
      _scheduleNotify();
    }
  }

  List<Map<String, dynamic>> get backgroundWorks {
    final list = snapshot?['backgroundWorks'];
    if (list is! List) return const [];
    return list
        .whereType<Map>()
        .map((e) => e.cast<String, dynamic>())
        .toList();
  }

  Map<String, dynamic>? get goal =>
      (snapshot?['goal'] as Map?)?.cast<String, dynamic>();

  Map<String, dynamic>? get plan =>
      (snapshot?['plan'] as Map?)?.cast<String, dynamic>();

  /// inputRouting: {mode: startNow|enqueue|guide|reject|choice, reasonCode?}
  String get inputRoutingMode =>
      (snapshot?['inputRouting'] as Map?)?['mode'] as String? ??
      'startNow';

  List<Map<String, dynamic>> get pendingInteractions {
    final list = snapshot?['pendingInteractions'];
    if (list is! List) return const [];
    return list
        .whereType<Map>()
        .map((e) => e.cast<String, dynamic>())
        .toList();
  }
}

/// The conversation V4 query guards (fileChanges / fileRewindPreview) throw
/// these when baseRevision/baseLogEpoch lag the live publisher snapshot —
/// expected while streaming, always worth one retry after resyncing.
/// Mirrors the web client's retryable-stale set.
bool isStaleConversationError(Object e) =>
    e is ChannelRpcError &&
    ('${e.message}${e.data ?? ''}').contains('proto.stale');
