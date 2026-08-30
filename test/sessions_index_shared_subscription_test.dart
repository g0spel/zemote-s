import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:zflow/protocol/channel_client.dart';
import 'package:zflow/protocol/conversation.dart';
import 'package:zflow/protocol/ipc_codec.dart';
import 'package:zflow/protocol/zflow_client.dart';

Uint8List _frame(List<Object?> header, [Object? data]) {
  final writer = ValueWriter();
  encodeValue(writer, header);
  if (data != null) encodeValue(writer, data);
  return writer.toBytes();
}

({int id, String method, Object? args}) _request(Uint8List body) {
  final reader = ValueReader(body);
  final header = decodeValue(reader) as List;
  return (
    id: (header[1] as num).toInt(),
    method: header[3] as String,
    args: decodeValue(reader),
  );
}

void _respond(ChannelClient channels, int id, Object? result) {
  channels.handleMessage(
      _frame([ChannelClient.resPromiseSuccess, id], result));
}

Future<void> _flush() => Future<void>.delayed(Duration.zero);

void main() {
  test('same scope shares one sessions-index wire subscription', () async {
    final sent = <Uint8List>[];
    final channels = ChannelClient(sendBody: sent.add);
    final bridge = BridgeSession.detached(
      {'workspaceKey': '/ws'},
      channels: channels,
    );
    final transport = ConversationTransport(
      session: bridge,
      scope: const {'workspacePath': '/ws', 'workspaceIdentity': 'id-1'},
    );
    addTearDown(() {
      transport.dispose();
      bridge.dispose();
    });
    channels.handleMessage(_frame(const [ChannelClient.resInitialize, 0]));

    final firstFuture = transport.subscribeSessionsIndex();
    final secondFuture = transport.subscribeSessionsIndex();
    await _flush();

    var requests = sent.map(_request).toList();
    final hello = requests.singleWhere((r) => r.method == 'helloConversationV4');
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
    _respond(channels, subscribe.id, {
      'ack': {'subscriptionId': 'shared-sub'},
    });

    final subscriptions = await Future.wait([firstFuture, secondFuture]);
    requests = sent.map(_request).toList();
    expect(
      requests.where((r) => r.method == 'subscribeSessionsIndexV4'),
      hasLength(1),
    );
    expect(identical(subscriptions[0].state, subscriptions[1].state), isTrue);

    var stateNotifications = 0;
    subscriptions[1].state.addListener(() => stateNotifications++);
    final listener = requests
        .singleWhere((r) => r.method == 'onDynamicSessionsIndexFrame')
        .id;
    channels.handleMessage(_frame([ChannelClient.resEventFire, listener], {
      'kind': 'complete',
      'topic': 'sessions-index/id-1',
      'subscriptionId': 'shared-sub',
      'frame': {
        'subscriptionId': 'shared-sub',
        'toSeq': 1,
        'payload': {
          'kind': 'snapshot',
          'snapshot': {
            'workspaceId': '/ws',
            'sessions': [
              {
                'sessionId': 's1',
                'title': 'Shared',
                'phase': 'idle',
                'lastActivityAt': 1,
              },
            ],
          },
        },
      },
    }));
    expect(subscriptions[0].state.sessions['s1']?.title, 'Shared');
    expect(stateNotifications, 1);

    await subscriptions[0].dispose();
    expect(
      sent.map(_request).where((r) => r.method == 'unsubscribeSessionsIndexV4'),
      isEmpty,
    );

    final lastDispose = subscriptions[1].dispose();
    await _flush();
    requests = sent.map(_request).toList();
    final unsubscribe = requests
        .singleWhere((r) => r.method == 'unsubscribeSessionsIndexV4');
    _respond(channels, unsubscribe.id, <String, dynamic>{});
    await lastDispose;
  });

  test('different workspace scopes do not share sessions-index state', () async {
    final sent = <Uint8List>[];
    final channels = ChannelClient(sendBody: sent.add);
    final bridge = BridgeSession.detached(
      {'workspaceKey': '/ws'},
      channels: channels,
    );
    final firstTransport = ConversationTransport(
      session: bridge,
      scope: const {'workspacePath': '/ws', 'workspaceIdentity': 'id-1'},
    );
    final secondTransport = ConversationTransport(
      session: bridge,
      scope: const {'workspacePath': '/other', 'workspaceIdentity': 'id-2'},
    );
    addTearDown(() {
      firstTransport.dispose();
      secondTransport.dispose();
      bridge.dispose();
    });
    channels.handleMessage(_frame(const [ChannelClient.resInitialize, 0]));

    final firstFuture = firstTransport.subscribeSessionsIndex();
    final secondFuture = secondTransport.subscribeSessionsIndex();
    await _flush();
    var requests = sent.map(_request).toList();
    for (final request in requests
        .where((r) => r.method == 'helloConversationV4')) {
      _respond(channels, request.id, <String, dynamic>{});
    }
    await _flush();
    requests = sent.map(_request).toList();
    for (final request in requests
        .where((r) => r.method == 'initializeConversationV4')) {
      _respond(channels, request.id, <String, dynamic>{});
    }
    await _flush();
    requests = sent.map(_request).toList();
    final subscribeRequests = requests
        .where((r) => r.method == 'subscribeSessionsIndexV4')
        .toList();
    expect(subscribeRequests, hasLength(2));
    for (var i = 0; i < subscribeRequests.length; i++) {
      _respond(channels, subscribeRequests[i].id, {
        'ack': {'subscriptionId': 'sub-$i'},
      });
    }

    final subscriptions = await Future.wait([firstFuture, secondFuture]);
    expect(identical(subscriptions[0].state, subscriptions[1].state), isFalse);
    final topics = requests
        .where((r) => r.method == 'onDynamicSessionsIndexFrame')
        .map((r) => ((r.args as Map)['workspacePath'] as String))
        .toList();
    expect(topics, containsAll(['/ws', '/other']));

    final disposeFutures = subscriptions.map((s) => s.dispose()).toList();
    await _flush();
    requests = sent.map(_request).toList();
    final unsubscribes = requests
        .where((r) => r.method == 'unsubscribeSessionsIndexV4')
        .toList();
    expect(unsubscribes, hasLength(2));
    for (final request in unsubscribes) {
      _respond(channels, request.id, <String, dynamic>{});
    }
    await Future.wait(disposeFutures);
  });
}
