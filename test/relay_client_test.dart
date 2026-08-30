import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'package:zflow/protocol/connection_params.dart';
import 'package:zflow/protocol/relay_client.dart';

class _FakeSocket implements WebSocketChannel {
  final Future<void> readyFuture;
  final incoming = StreamController<Object?>();
  final sent = <Object?>[];
  int? _closeCode;
  String? _closeReason;
  late final WebSocketSink _sink = _FakeSink(this);

  _FakeSocket(this.readyFuture);

  @override
  String? get protocol => null;

  @override
  int? get closeCode => _closeCode;

  @override
  String? get closeReason => _closeReason;

  @override
  Future<void> get ready => readyFuture;

  @override
  Stream<Object?> get stream => incoming.stream;

  @override
  WebSocketSink get sink => _sink;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);

  bool _closed = false;

  Future<void> close([int? code, String? reason]) async {
    if (_closed) return;
    _closed = true;
    _closeCode = code;
    _closeReason = reason;
    await incoming.close();
  }
}

class _FakeSink implements WebSocketSink {
  final _FakeSocket socket;
  final _done = Completer<void>();

  _FakeSink(this.socket);

  @override
  Future<void> get done => _done.future;

  @override
  void add(Object? data) => socket.sent.add(data);

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future<void> addStream(Stream<Object?> stream) async {
    await for (final value in stream) {
      add(value);
    }
  }

  @override
  Future<void> close([int? closeCode, String? closeReason]) async {
    await socket.close(closeCode, closeReason);
    if (!_done.isCompleted) _done.complete();
  }
}

ZflowConnectionParams _params() => ZflowConnectionParams(
      deviceSid: 'device-test',
      passHash: 'hash-test',
      timestamp: 1,
      source: Uri.parse(
          'https://zcode.z.ai/remote/v4?sid=device-test&hash=hash-test&t=1'),
    );

Future<void> _pair(_FakeSocket socket) async {
  socket.incoming.add(jsonEncode({'type': 'auth_challenge', 'nonce': 'nonce'}));
  socket.incoming.add(jsonEncode({
    'type': 'auth_ack',
    'pair_status': 'matched',
  }));
  await Future<void>.delayed(Duration.zero);
}

void main() {
  test('concurrent start calls share one socket attempt', () async {
    final ready = Completer<void>();
    final sockets = <_FakeSocket>[];
    final client = RelayClient(
      _params(),
      socketFactory: (_) {
        final socket = _FakeSocket(ready.future);
        sockets.add(socket);
        return socket;
      },
    );

    final first = client.start();
    final second = client.start();
    await Future<void>.delayed(Duration.zero);
    expect(sockets, hasLength(1));

    ready.complete();
    await Future.wait([first, second]);
    await _pair(sockets.single);
    expect(client.state, RelayState.paired);
    expect(sockets.single.sent, isNotEmpty);

    await client.dispose();
  });

  test('timed-out queued direct request is not flushed', () async {
    late _FakeSocket socket;
    final client = RelayClient(
      _params(),
      socketFactory: (_) => socket = _FakeSocket(Future<void>.value()),
    );
    await client.start();

    client.sendPayload({
      'zcode_type': 'bootstrap-request',
      'requestId': 'req-timeout',
    });
    client.cancelQueuedRequest('req-timeout');
    await _pair(socket);

    final payloads = socket.sent
        .whereType<String>()
        .map(jsonDecode)
        .whereType<Map>()
        .map((frame) => frame['payload'])
        .whereType<Map>();
    expect(payloads.any((p) => p['requestId'] == 'req-timeout'), isFalse);
    await client.dispose();
  });

  test('queued mobile view state keeps only the newest value', () async {
    late _FakeSocket socket;
    final client = RelayClient(
      _params(),
      socketFactory: (_) => socket = _FakeSocket(Future<void>.value()),
    );
    await client.start();

    client.sendPayload({
      'zcode_type': 'mobile-view-state-update',
      'viewState': {'activeTaskId': 'old'},
    });
    client.sendPayload({
      'zcode_type': 'mobile-view-state-update',
      'viewState': {'activeTaskId': 'new'},
    });
    await _pair(socket);

    final payloads = socket.sent
        .whereType<String>()
        .map(jsonDecode)
        .whereType<Map>()
        .map((frame) => frame['payload'])
        .whereType<Map>()
        .where((p) => p['zcode_type'] == 'mobile-view-state-update')
        .toList();
    expect(payloads, hasLength(1));
    expect((payloads.single['viewState'] as Map)['activeTaskId'], 'new');
    await client.dispose();
  });
}
