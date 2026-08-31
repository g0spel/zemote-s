import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zflow/protocol/channel_client.dart';
import 'package:zflow/protocol/ipc_codec.dart';
import 'package:zflow/protocol/zflow_client.dart';
import 'package:zflow/ui/chat_page.dart';

/// 「最近发送 HH:mm」固定行(用户裁定)回归:实时 delta 行打戳渲染、
/// 快照物化行经 echo 退休转移发送戳后渲染。
Uint8List _frame(List<Object?> header, [Object? data]) {
  final w = ValueWriter();
  encodeValue(w, header);
  if (data != null) encodeValue(w, data);
  return w.toBytes();
}

Object? _autoReply(String method) {
  switch (method) {
    case 'prepareWorkspace':
      return <String, dynamic>{};
    case 'list':
      return const <dynamic>[];
    case 'helloConversationV4':
    case 'initializeConversationV4':
      return <String, dynamic>{};
    case 'createSession':
    case 'sendConversationCommandV4':
      return {
        'status': 'accepted',
        'result': {'sessionId': 's1'},
      };
    case 'subscribeConversationV4':
      return {
        'ack': {'subscriptionId': 'conv-sub'},
      };
    case 'subscribeSessionsIndexV4':
      return {
        'ack': {'subscriptionId': 'sub-idx'},
      };
    default:
      return <String, dynamic>{};
  }
}

/// 泵 ChatPage 并走完整发送流(发送 → createSession/subscribe 握手
/// 就绪),返回会话帧监听器 wire id。
Future<int> _pumpAndSend(WidgetTester tester, BridgeSession bridge,
    ChannelClient channels, Map<int, String> pending,
    Map<int, String> listeners, String text) async {
  await tester.pumpWidget(MaterialApp(
    theme: ThemeData(brightness: Brightness.dark),
    home: Scaffold(
      body: ChatPage(
        session: bridge,
        scope: const {'workspacePath': '/ws'},
        workspaceKey: '/ws',
        sessionId: null,
        title: '新会话',
        embedded: true,
      ),
    ),
  ));
  channels.handleMessage(_frame(const [ChannelClient.resInitialize, 0]));
  await tester.pump();
  await tester.enterText(find.byType(TextField), text);
  await tester.tap(find.byIcon(Icons.arrow_upward));
  for (var i = 0;
      i < 12 && !listeners.containsValue('onDynamicConversationFrame');
      i++) {
    for (final id in pending.keys.toList()) {
      final m = pending.remove(id)!;
      channels.handleMessage(
          _frame([ChannelClient.resPromiseSuccess, id], _autoReply(m)));
    }
    await tester.pump(const Duration(milliseconds: 150));
  }
  for (final id in pending.keys.toList()) {
    final m = pending.remove(id)!;
    channels.handleMessage(
        _frame([ChannelClient.resPromiseSuccess, id], _autoReply(m)));
  }
  await tester.pump();
  return listeners.entries
      .singleWhere((e) => e.value == 'onDynamicConversationFrame')
      .key;
}

void _fire(BridgeSession bridge, int id, Object event) => bridge.channels
    .handleMessage(_frame([ChannelClient.resEventFire, id], event));

void main() {
  testWidgets('delta 路径:row.appended 打戳后 footer 渲染', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    final listeners = <int, String>{};
    final pending = <int, String>{};
    final channels = ChannelClient(sendBody: (body) {
      final r = ValueReader(body);
      final h = decodeValue(r) as List;
      if (h[0] == ChannelClient.reqPromise) {
        pending[h[1] as int] = h[3] as String;
      } else if (h[0] == ChannelClient.reqEventListen) {
        listeners[h[1] as int] = h[3] as String;
      }
    });
    final bridge = BridgeSession.detached({'workspaceKey': '/ws'},
        channels: channels);
    final convId = await _pumpAndSend(
        tester, bridge, channels, pending, listeners, '测试消息');

    _fire(bridge, convId, {
      'kind': 'complete',
      'topic': 'conversation/s1',
      'subscriptionId': 'conv-sub',
      'frame': {
        'subscriptionId': 'conv-sub',
        'toSeq': 2,
        'payload': {
          'kind': 'deltas',
          'deltas': [
            {
              'op': 'row.appended',
              'row': {
                'rowId': 2,
                'kind': 'userInput',
                'text': '测试消息',
                'state': 'completed',
              },
            },
          ],
        },
      },
    });
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pump(const Duration(milliseconds: 150));
    expect(find.textContaining('最近发送'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    bridge.dispose();
    await tester.pump(const Duration(minutes: 1));
  });

  testWidgets('快照物化行未带戳:echo 退休时转移发送戳,footer 仍渲染',
      (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    final listeners = <int, String>{};
    final pending = <int, String>{};
    final channels = ChannelClient(sendBody: (body) {
      final r = ValueReader(body);
      final h = decodeValue(r) as List;
      if (h[0] == ChannelClient.reqPromise) {
        pending[h[1] as int] = h[3] as String;
      } else if (h[0] == ChannelClient.reqEventListen) {
        listeners[h[1] as int] = h[3] as String;
      }
    });
    final bridge = BridgeSession.detached({'workspaceKey': '/ws'},
        channels: channels);
    final convId = await _pumpAndSend(
        tester, bridge, channels, pending, listeners, '测试消息');

    // 行经快照物化(无 ts):echo 退休并把乐观发送时刻转移到物化行。
    _fire(bridge, convId, {
      'kind': 'complete',
      'topic': 'conversation/s1',
      'subscriptionId': 'conv-sub',
      'frame': {
        'subscriptionId': 'conv-sub',
        'toSeq': 2,
        'payload': {
          'kind': 'snapshot',
          'snapshot': {
            'revision': 2,
            'logEpoch': 'e1',
            'rows': {
              'totalCount': 1,
              'firstRowId': 2,
              'window': [
                {
                  'rowId': 2,
                  'kind': 'userInput',
                  'text': '测试消息',
                  'state': 'completed',
                },
              ],
            },
          },
        },
      },
    });
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pump(const Duration(milliseconds: 150));
    expect(find.textContaining('最近发送'), findsOneWidget,
        reason: 'echo 的乐观发送时刻应转移到物化行,footer 常驻');
    await tester.pumpWidget(const SizedBox.shrink());
    bridge.dispose();
    await tester.pump(const Duration(minutes: 1));
  });
}
