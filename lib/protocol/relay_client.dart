import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'connection_params.dart';
import 'device_info.dart';
import 'proof.dart';

enum RelayState {
  idle,
  connecting,
  authenticating,
  waiting,
  paired,
  reconnecting,
  error,
  kicked,
  closed,
}

class RelayFailure {
  final String reason;
  final String? message;
  const RelayFailure(this.reason, [this.message]);

  @override
  String toString() => message == null ? reason : '$reason: $message';
}

/// Close-code mapping, mirrors `VC()` / `BC` in the web client.
String? relayCloseReason(int code) {
  switch (code) {
    case 4004:
      return 'session-not-found';
    case 4009:
      return 'session-conflict';
    case 4010:
      return 'desktop-disconnected';
    case 4011:
      return 'session-expired';
    case 4012:
      return 'workspace-closed';
    case 4013:
      return 'invalid-mobile-connection';
    default:
      return null;
  }
}

/// Reimplementation of the relay terminal socket (`pen` class in the web
/// client). JSON text frames over `wss://<host>/ws`.
class RelayClient {
  final ZemoteConnectionParams params;
  final void Function(String line)? onLog;

  static const heartbeatInterval = Duration(seconds: 10);
  static const heartbeatAckTimeout = Duration(seconds: 30);
  static const waitingTimeout = Duration(seconds: 30);
  static const reconnectWaitTimeout = Duration(seconds: 20);

  WebSocketChannel? _socket;
  StreamSubscription? _socketSub;

  final _state = ValueNotifier<RelayState>(RelayState.idle);
  ValueListenable<RelayState> get stateListenable => _state;
  RelayState get state => _state.value;

  final _payloadController =
      StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get payloads => _payloadController.stream;

  final _failureController = StreamController<RelayFailure>.broadcast();
  Stream<RelayFailure> get failures => _failureController.stream;

  bool _wasPaired = false;
  bool _intentionallyClosed = false;
  bool _disposed = false;
  int _reconnectAttempt = 0;
  int _hbTick = 0;
  bool _staleProbeSent = false;

  /// Verbose per-frame relay logging (`[relay] << / >>` raw frames).
  /// Costs a jsonEncode + truncation on EVERY inbound/outbound frame —
  /// meaningful CPU during streaming — so it defaults off in release and is
  /// toggleable from 设置. Diagnostics/errors always log.
  static bool verboseFrames = false;
  DateTime _lastPairStatusAckAt = DateTime.now();

  /// Last time ANY inbound frame arrived. A healthy paired socket gets at
  /// least heartbeat acks every 10s — zero inbound for >25s means the link
  /// died while the app was frozen (locked screen / backgrounded), so the
  /// resume poke can skip the probe dance and reconnect outright.
  DateTime _lastInboundAt = DateTime.now();
  static const _deadLinkThreshold = Duration(seconds: 25);

  Timer? _heartbeatTimer;
  Timer? _waitingTimer;
  Timer? _reconnectTimer;
  Timer? _rewaitTimer;

  RelayClient(this.params, {this.onLog});

  void _log(String line) => onLog?.call(line);

  void _setState(RelayState s) {
    _state.value = s;
    _log('[relay] state -> $s');
  }

  Future<void> start() async {
    _disposed = false;
    _intentionallyClosed = false;
    _reconnectAttempt = 0;
    _setState(RelayState.connecting);
    await _connect();
  }

  Future<void> _connect() async {
    _socketSub?.cancel();
    _socket?.sink.close();
    // Mirror the official client's reconnectNow(): a fresh socket starts a
    // fresh liveness window, else the first tick after a reconnect sees a
    // stale clock and immediately tears down again.
    _lastPairStatusAckAt = DateTime.now();
    _lastInboundAt = DateTime.now();
    final uri = params.relayWsUri;
    _log('[relay] connecting $uri');
    WebSocketChannel socket;
    try {
      socket = WebSocketChannel.connect(uri);
      await socket.ready;
    } catch (e) {
      _log('[relay] connect failed: $e');
      _handleSocketClosed(1006, e.toString());
      return;
    }
    if (_disposed) {
      socket.sink.close();
      return;
    }
    _socket = socket;
    _socketSub = socket.stream.listen(
      _handleRawMessage,
      onError: (e) => _log('[relay] socket error: $e'),
      onDone: () =>
          _handleSocketClosed(socket.closeCode ?? 1006, socket.closeReason),
    );
    _setState(RelayState.authenticating);
    _send({
      'type': 'auth_init',
      'role': 'terminal',
      'device_sid': params.deviceSid,
      'meta': {
        'platform': zemotePlatformName(),
        'version': params.appVersion ?? 'web',
        'name': zemoteAppName,
      },
      'client_ts': DateTime.now().millisecondsSinceEpoch,
    });
  }

  void _send(Map<String, dynamic> frame) {
    final socket = _socket;
    if (socket == null) return;
    if (verboseFrames) _log('[relay] >> ${jsonEncode(frame)}');
    socket.sink.add(jsonEncode(frame));
  }

  /// Outbound data payloads are queued while unpaired (reconnecting /
  /// waiting) and flushed once the relay reports `matched` — otherwise
  /// requests sent during a reconnect vanish into a dead socket and the
  /// caller hangs until timeout.
  final _outboundQueue = <Map<String, dynamic>>[];

  void sendPayload(Map<String, dynamic> payload) {
    if (state != RelayState.paired || _socket == null) {
      if (_outboundQueue.length < 100) {
        _log('[relay] queued (state=$state): ${payload['zcode_type']}');
        _outboundQueue.add(payload);
      }
      return;
    }
    _send({
      'type': 'data',
      'payload': payload,
      'client_ts': DateTime.now().millisecondsSinceEpoch,
    });
  }

  void _flushOutboundQueue() {
    if (_outboundQueue.isEmpty) return;
    _log('[relay] flushing ${_outboundQueue.length} queued payload(s)');
    final queued = List<Map<String, dynamic>>.from(_outboundQueue);
    _outboundQueue.clear();
    for (final payload in queued) {
      _send({
        'type': 'data',
        'payload': payload,
        'client_ts': DateTime.now().millisecondsSinceEpoch,
      });
    }
  }

  void _handleRawMessage(dynamic data) {
    _lastInboundAt = DateTime.now();
    Map<String, dynamic>? frame;
    try {
      final text = data is String ? data : utf8.decode(data as List<int>);
      if (verboseFrames) _log('[relay] << $text');
      final decoded = jsonDecode(text);
      if (decoded is Map<String, dynamic> && decoded.containsKey('type')) {
        frame = decoded;
      }
    } catch (e) {
      _log('[relay] bad frame: $e');
      _log('[诊断] relay 连接收到无法解析的帧 — 桌面端协议可能已变更或链路异常，'
          '请导出协议日志反馈');
      return;
    }
    if (frame == null) return;
    switch (frame['type']) {
      case 'auth_challenge':
        final nonce = frame['nonce'] as String?;
        if (nonce == null || nonce.isEmpty) {
          _log('[诊断] 配对挑战缺少 nonce 字段 — 桌面端协议可能已变更，'
              '请导出协议日志反馈');
          _handleRelayError('auth-malformed', 'auth_challenge without nonce');
          return;
        }
        _send({
          'type': 'auth_response',
          'device_sid': params.deviceSid,
          'proof': calculateProof(
            passHash: params.passHash,
            nonce: nonce,
            role: 'terminal',
            deviceSid: params.deviceSid,
          ),
          'client_ts': DateTime.now().millisecondsSinceEpoch,
        });
        break;
      case 'auth_ack':
      case 'pair_status_ack':
        _applyPairStatus(frame['pair_status'] as String?);
        break;
      case 'data':
        final payload = frame['payload'];
        if (payload is Map<String, dynamic>) {
          _payloadController.add(payload);
        }
        break;
      case 'error':
        _handleRelayError(
            frame['code'] as String?, frame['message'] as String?);
        break;
      default:
        _log('[诊断] 收到未知帧类型 "${frame['type']}"'
            '（字段: ${frame.keys.toList().join(', ')}）— '
            '桌面端协议可能已变更，请导出协议日志反馈');
        break;
    }
  }

  void _applyPairStatus(String? status) {
    _lastPairStatusAckAt = DateTime.now();
    _staleProbeSent = false;
    if (status == 'waiting') {
      if (_wasPaired) {
        _clearWaitingTimer();
        _setState(RelayState.waiting);
        _startHeartbeat();
        // A reconnecting mobile that was already paired should be matched
        // immediately; if the server keeps saying "waiting", force another
        // reconnect instead of hanging forever.
        _rewaitTimer?.cancel();
        _rewaitTimer = Timer(reconnectWaitTimeout, () {
          if (_wasPaired && state == RelayState.waiting && !_disposed) {
            _log('[relay] re-pair stuck in waiting, reconnecting');
            _reconnect();
          }
        });
      } else {
        _setState(RelayState.waiting);
        _startWaitingTimer();
      }
      return;
    }
    if (status == 'matched') {
      _rewaitTimer?.cancel();
      _reconnectAttempt = 0;
      _clearWaitingTimer();
      _setState(RelayState.paired);
      _wasPaired = true;
      _startHeartbeat();
      _flushOutboundQueue();
    }
  }

  void _handleRelayError(String? code, String? message) {
    _log('[relay] error frame: $code $message');
    if (code == 'KICKED') {
      _setState(RelayState.kicked);
      _intentionallyClosed = true;
      _failureController.add(RelayFailure('kicked', message));
      _socket?.sink.close();
    }
  }

  void _handleSocketClosed(int code, String? reason) {
    if (_disposed) return;
    _stopHeartbeat();
    _clearWaitingTimer();
    final mapped = relayCloseReason(code);
    _log('[relay] closed code=$code reason=$reason mapped=$mapped');
    if (mapped == null && !_intentionallyClosed && code != 1006) {
      _log('[诊断] 关闭码 $code 不在已知映射表 — 可能是新错误语义，'
          '请导出协议日志反馈');
    }
    if (_intentionallyClosed) return;
    if (_wasPaired || mapped == 'desktop-disconnected') {
      _scheduleReconnect();
      return;
    }
    _setState(RelayState.error);
    _failureController.add(RelayFailure(
      mapped ?? 'relay-unavailable',
      reason ?? 'connection closed ($code)',
    ));
  }

  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(heartbeatInterval, (_) {
      if (state != RelayState.paired && state != RelayState.waiting) return;
      // Halve the heartbeat while waiting (nothing is streaming; saves
      // mobile radio wakeups).
      _hbTick++;
      if (state == RelayState.waiting && _hbTick.isOdd) return;
      if (DateTime.now().difference(_lastPairStatusAckAt) >
          heartbeatAckTimeout) {
        // Probe-before-drop: timer freezes (app switch / doze) and brief
        // network stalls read as stale acks even on a live socket. Send one
        // extra query and only tear down if the NEXT tick is still stale.
        if (!_staleProbeSent) {
          _staleProbeSent = true;
          _log('[relay] heartbeat stale, probing before reconnect');
        } else {
          _staleProbeSent = false;
          _log('[relay] heartbeat ack timeout, reconnecting');
          _reconnect();
          return;
        }
      } else {
        _staleProbeSent = false;
      }
      _send({
        'type': 'pair_status_query',
        'device_sid': params.deviceSid,
        'client_ts': DateTime.now().millisecondsSinceEpoch,
      });
    });
  }

  /// App-resume liveness action. Paired + fresh inbound traffic → probe
  /// with a query; paired but ZERO inbound for >25s (the app was frozen
  /// with the screen locked — the socket is dead even if the OS hasn't
  /// delivered the close event yet) → reconnect NOW, skipping the
  /// 20-second stale-probe dance; mid-reconnect → retry without backoff.
  void poke() {
    if (_disposed || _intentionallyClosed) return;
    if (state == RelayState.paired) {
      if (DateTime.now().difference(_lastInboundAt) > _deadLinkThreshold) {
        _log('[relay] poke: no inbound since '
            '${_lastInboundAt.hour}:${_lastInboundAt.minute}, '
            'reconnecting immediately');
        _reconnect();
        return;
      }
      _send({
        'type': 'pair_status_query',
        'device_sid': params.deviceSid,
        'client_ts': DateTime.now().millisecondsSinceEpoch,
      });
    } else if (state == RelayState.reconnecting) {
      _log('[relay] poke: retrying reconnect immediately');
      _reconnectTimer?.cancel();
      _reconnectTimer = null;
      _connect();
    }
  }

  void _stopHeartbeat() => _heartbeatTimer?.cancel();

  void _startWaitingTimer() {
    _clearWaitingTimer();
    _waitingTimer = Timer(waitingTimeout, () {
      if (state == RelayState.waiting && !_wasPaired) {
        _setState(RelayState.error);
        _failureController.add(const RelayFailure(
          'invalid-mobile-connection',
          'Desktop did not match this mobile connection before the waiting timeout.',
        ));
      }
    });
  }

  void _clearWaitingTimer() {
    _waitingTimer?.cancel();
    _rewaitTimer?.cancel();
  }

  void _scheduleReconnect() {
    if (_disposed || _intentionallyClosed) return;
    _setState(RelayState.reconnecting);
    final delayMs =
        (1000 * (1 << _reconnectAttempt.clamp(0, 4))).clamp(1000, 15000);
    _reconnectAttempt += 1;
    _log('[relay] reconnect in ${delayMs}ms (attempt $_reconnectAttempt)');
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(Duration(milliseconds: delayMs), () {
      if (!_disposed) _connect();
    });
  }

  Future<void> _reconnect() async {
    _reconnectTimer?.cancel();
    // Go through `reconnecting` so listeners (bridge recovery) know the
    // connection dropped — the heartbeat-timeout path used to skip this and
    // bridges were never recovered after re-pairing.
    _setState(RelayState.reconnecting);
    await _connect();
  }

  /// Diagnostics: forcefully drops the socket to exercise the
  /// reconnect/bridge-recovery path (used by integration probes).
  Future<void> debugDropSocket() async {
    _intentionallyClosed = false;
    await _socketSub?.cancel();
    _socketSub = null;
    final socket = _socket;
    _socket = null;
    try {
      await socket?.sink.close(3000, 'debug-drop');
    } catch (_) {}
    _handleSocketClosed(1006, 'debug-drop');
  }

  Future<void> dispose() async {
    _disposed = true;
    _intentionallyClosed = true;
    _stopHeartbeat();
    _clearWaitingTimer();
    _reconnectTimer?.cancel();
    _rewaitTimer?.cancel();
    await _socketSub?.cancel();
    _socket?.sink.close();
    _setState(RelayState.closed);
    await _payloadController.close();
    await _failureController.close();
  }
}
