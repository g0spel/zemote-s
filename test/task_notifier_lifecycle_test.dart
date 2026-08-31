import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:zflow/notifications/notifications.dart';
import 'package:zflow/notifications/task_notifier.dart';
import 'package:zflow/protocol/channel_client.dart';
import 'package:zflow/protocol/ipc_codec.dart';
import 'package:zflow/protocol/zflow_client.dart';

class _FakeNotifications extends Notifications {
  Future<void> Function(Map<String, dynamic> payload)? tapHandler;
  int stopForegroundCalls = 0;

  @override
  void setTapHandler(
      Future<void> Function(Map<String, dynamic> payload)? handler) {
    tapHandler = handler;
  }

  @override
  Future<void> stopForeground() async {
    stopForegroundCalls++;
  }
}

Uint8List _frame(List<Object?> header, [Object? data]) {
  final writer = ValueWriter();
  encodeValue(writer, header);
  if (data != null) encodeValue(writer, data);
  return writer.toBytes();
}

({int id, String method}) _request(Uint8List body) {
  final reader = ValueReader(body);
  final header = decodeValue(reader) as List;
  return (id: (header[1] as num).toInt(), method: header[3] as String);
}

void _respond(ChannelClient channels, int id, Object? result) {
  channels.handleMessage(_frame([ChannelClient.resPromiseSuccess, id], result));
}

void _respondError(ChannelClient channels, int id, Object? error) {
  channels.handleMessage(_frame([ChannelClient.resPromiseError, id], error));
}

Future<void> _flush() => Future<void>.delayed(Duration.zero);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('旧 TaskNotifier dispose 不会清掉新 notifier 的 tap handler', () async {
    final notifications = _FakeNotifications();
    final bridge = BridgeSession.detached({'workspaceKey': '/ws'});
    var oldOpened = 0;
    var newOpened = 0;

    final oldNotifier = TaskNotifier(
      bridge: bridge,
      scope: const {'workspacePath': '/ws'},
      notifications: notifications,
      onOpenTask: (taskId, title) async => oldOpened++,
    );
    final oldHandler = notifications.tapHandler!;
    final newNotifier = TaskNotifier(
      bridge: bridge,
      scope: const {'workspacePath': '/ws'},
      notifications: notifications,
      onOpenTask: (taskId, title) async => newOpened++,
    );
    final newHandler = notifications.tapHandler!;

    await oldNotifier.dispose();
    expect(notifications.tapHandler, same(newHandler));

    await oldHandler({'taskId': 'old'});
    await newHandler({'taskId': 'new'});
    expect(oldOpened, 0);
    expect(newOpened, 1);

    await newNotifier.dispose();
    expect(notifications.tapHandler, isNull);
    expect(notifications.stopForegroundCalls, 1);
    bridge.dispose();
  });

  test('启动失败后下一次 start 会重试订阅', () async {
    final sent = <Uint8List>[];
    final channels = ChannelClient(sendBody: sent.add);
    final bridge = BridgeSession.detached(
      {'workspaceKey': '/ws'},
      channels: channels,
    );
    final notifications = _FakeNotifications();
    addTearDown(bridge.dispose);
    channels.handleMessage(_frame(const [ChannelClient.resInitialize, 0]));

    final notifier = TaskNotifier(
      bridge: bridge,
      scope: const {'workspacePath': '/ws'},
      notifications: notifications,
      onOpenTask: (taskId, title) async {},
    );

    final firstStart = notifier.start();
    final concurrentStart = notifier.start();
    expect(identical(firstStart, concurrentStart), isTrue);
    await _flush();
    var requests = sent.map(_request).toList();
    final hello =
        requests.singleWhere((r) => r.method == 'helloConversationV4');
    _respond(channels, hello.id, <String, dynamic>{});
    await _flush();
    requests = sent.map(_request).toList();
    final initialize =
        requests.singleWhere((r) => r.method == 'initializeConversationV4');
    _respond(channels, initialize.id, <String, dynamic>{});
    await _flush();
    requests = sent.map(_request).toList();
    final firstSubscribe =
        requests.singleWhere((r) => r.method == 'subscribeSessionsIndexV4');
    _respondError(channels, firstSubscribe.id, {'message': 'start failed'});
    await firstStart;
    expect(notifier.isActive, isFalse);

    final retryStart = notifier.start();
    await _flush();
    requests = sent.map(_request).toList();
    final subscribeRequests =
        requests.where((r) => r.method == 'subscribeSessionsIndexV4').toList();
    expect(subscribeRequests, hasLength(2));
    _respond(channels, subscribeRequests.last.id, {
      'ack': {'subscriptionId': 'retry-sub'},
    });
    await retryStart;
    expect(notifier.isActive, isTrue);

    final disposeFuture = notifier.dispose();
    await _flush();
    requests = sent.map(_request).toList();
    final unsubscribe =
        requests.singleWhere((r) => r.method == 'unsubscribeSessionsIndexV4');
    _respond(channels, unsubscribe.id, <String, dynamic>{});
    await disposeFuture;
  });

  test(
      'dispose during start does not wait, and a late old start preserves replacement owner',
      () async {
    final sent = <Uint8List>[];
    final channels = ChannelClient(sendBody: sent.add);
    final bridge = BridgeSession.detached(
      {'workspaceKey': '/ws'},
      channels: channels,
    );
    final notifications = _FakeNotifications();
    var oldOpened = 0;
    var newOpened = 0;
    addTearDown(bridge.dispose);
    channels.handleMessage(_frame(const [ChannelClient.resInitialize, 0]));

    final oldNotifier = TaskNotifier(
      bridge: bridge,
      scope: const {'workspacePath': '/ws'},
      notifications: notifications,
      onOpenTask: (taskId, title) async => oldOpened++,
    );
    final oldHandler = notifications.tapHandler!;
    final oldStart = oldNotifier.start();
    await _flush();

    var requests = sent.map(_request).toList();
    final hello =
        requests.singleWhere((r) => r.method == 'helloConversationV4');
    _respond(channels, hello.id, <String, dynamic>{});
    await _flush();
    requests = sent.map(_request).toList();
    final initialize =
        requests.singleWhere((r) => r.method == 'initializeConversationV4');
    _respond(channels, initialize.id, <String, dynamic>{});
    await _flush();
    requests = sent.map(_request).toList();
    final subscribe =
        requests.singleWhere((r) => r.method == 'subscribeSessionsIndexV4');

    final disposeFuture = oldNotifier.dispose();
    await disposeFuture;

    final newNotifier = TaskNotifier(
      bridge: bridge,
      scope: const {'workspacePath': '/ws'},
      notifications: notifications,
      onOpenTask: (taskId, title) async => newOpened++,
    );
    final newHandler = notifications.tapHandler!;
    expect(notifications.tapHandler, same(newHandler));

    _respond(channels, subscribe.id, {
      'ack': {'subscriptionId': 'late-old-sub'},
    });
    await oldStart;
    await _flush();

    await oldHandler({'taskId': 'old'});
    await newHandler({'taskId': 'new'});
    expect(oldOpened, 0);
    expect(newOpened, 1);
    expect(notifications.tapHandler, same(newHandler));

    requests = sent.map(_request).toList();
    final unsubscribe =
        requests.singleWhere((r) => r.method == 'unsubscribeSessionsIndexV4');
    _respond(channels, unsubscribe.id, <String, dynamic>{});
    await newNotifier.dispose();
  });

  test('dispose after bridge release skips unsubscribe on the released bridge',
      () async {
    final sent = <Uint8List>[];
    final channels = ChannelClient(sendBody: sent.add);
    final bridge = BridgeSession.detached(
      {'workspaceKey': '/ws'},
      channels: channels,
    );
    final notifications = _FakeNotifications();
    addTearDown(bridge.dispose);
    channels.handleMessage(_frame(const [ChannelClient.resInitialize, 0]));

    final notifier = TaskNotifier(
      bridge: bridge,
      scope: const {'workspacePath': '/ws'},
      notifications: notifications,
      onOpenTask: (taskId, title) async {},
    );
    final start = notifier.start();
    await _flush();
    var requests = sent.map(_request).toList();
    for (final request
        in requests.where((r) => r.method == 'helloConversationV4')) {
      _respond(channels, request.id, <String, dynamic>{});
    }
    await _flush();
    requests = sent.map(_request).toList();
    for (final request
        in requests.where((r) => r.method == 'initializeConversationV4')) {
      _respond(channels, request.id, <String, dynamic>{});
    }
    await _flush();
    requests = sent.map(_request).toList();
    final subscribe =
        requests.singleWhere((r) => r.method == 'subscribeSessionsIndexV4');
    _respond(channels, subscribe.id, {
      'ack': {'subscriptionId': 'released-bridge-sub'},
    });
    await start;

    bridge.dispose();
    await notifier.dispose();

    expect(
      sent.map(_request).where((r) => r.method == 'unsubscribeSessionsIndexV4'),
      isEmpty,
    );
  });
}
