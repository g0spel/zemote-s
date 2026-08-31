import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zflow/protocol/channel_client.dart';
import 'package:zflow/protocol/ipc_codec.dart';
import 'package:zflow/protocol/zflow_client.dart';
import 'package:zflow/ui/chat_page.dart';

/// RPC 成功状态统一(P5-2)的 UI 集成回归:
/// `_run` 管理命令(stop/compact/...)接受 {accepted,noop,duplicate} 为成功,
/// 明确 rejected 才提示;duplicate 此前会被误报为失败。
Uint8List _frame(List<Object?> header, [Object? data]) {
  final w = ValueWriter();
  encodeValue(w, header);
  if (data != null) encodeValue(w, data);
  return w.toBytes();
}

void _respond(BridgeSession bridge, int id, Object? result) => bridge.channels
    .handleMessage(_frame([ChannelClient.resPromiseSuccess, id], result));

void _fire(BridgeSession bridge, int id, Object? event) => bridge.channels
    .handleMessage(_frame([ChannelClient.resEventFire, id], event));

void main() {
  testWidgets('停止命令 duplicate 不提示失败,rejected 才提示原因',
      (tester) async {
    tester.view.physicalSize = const Size(1080, 2280);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    var commandReply = const <String, dynamic>{'status': 'duplicate'};
    final listeners = <int, String>{};
    final pending = <int, Object?>{};
    final channels = ChannelClient(sendBody: (body) {
      final r = ValueReader(body);
      final h = decodeValue(r) as List;
      if (h[0] == ChannelClient.reqPromise) {
        switch (h[3] as String) {
          case 'prepareWorkspace':
            pending[h[1] as int] = const <String, dynamic>{};
          case 'list':
            pending[h[1] as int] = const <dynamic>[];
          case 'helloConversationV4':
          case 'initializeConversationV4':
            pending[h[1] as int] = const <String, dynamic>{};
          case 'subscribeConversationV4':
            pending[h[1] as int] = const <String, dynamic>{
              'ack': {'subscriptionId': 'conv-sub'},
            };
          case 'subscribeSessionsIndexV4':
            pending[h[1] as int] = const <String, dynamic>{
              'ack': {'subscriptionId': 'sub-idx'},
            };
          case 'sendConversationCommandV4':
            pending[h[1] as int] = commandReply;
          default:
            pending[h[1] as int] = const <String, dynamic>{};
        }
      } else if (h[0] == ChannelClient.reqEventListen) {
        listeners[h[1] as int] = h[3] as String;
      }
    });
    final bridge = BridgeSession.detached({'workspaceKey': '/ws'},
        channels: channels);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ChatPage(
          session: bridge,
          scope: const {'workspacePath': '/ws'},
          workspaceKey: '/ws',
          sessionId: 's1',
          title: '会话',
          embedded: true,
        ),
      ),
    ));

    bridge.channels
        .handleMessage(_frame(const [ChannelClient.resInitialize, 0]));
    await tester.pump();

    // 泵到会话帧监听器注册、全部握手应答完毕。
    for (var i = 0;
        i < 12 && !listeners.containsValue('onDynamicConversationFrame');
        i++) {
      for (final id in pending.keys.toList()) {
        _respond(bridge, id, pending.remove(id));
      }
      await tester.pump(const Duration(milliseconds: 150));
    }
    for (final id in pending.keys.toList()) {
      _respond(bridge, id, pending.remove(id));
    }
    await tester.pump();
    final convListener = listeners.entries
        .singleWhere((e) => e.value == 'onDynamicConversationFrame')
        .key;

    _fire(bridge, convListener, {
      'kind': 'complete',
      'topic': 'conversation/s1',
      'subscriptionId': 'conv-sub',
      'frame': {
        'subscriptionId': 'conv-sub',
        'toSeq': 2,
        'payload': {
          'kind': 'snapshot',
          'snapshot': {
            'revision': 1,
            'logEpoch': 'e1',
            'control': {'phase': 'running'},
            'config': {'provider': 'p', 'model': 'm'},
            'rows': {
              'totalCount': 1,
              'firstRowId': 1,
              'window': [
                {'rowId': 1, 'kind': 'userInput', 'text': 'hi'},
              ],
            },
          },
        },
      },
    });
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pump(const Duration(milliseconds: 150));

    final stopIcon = find.byIcon(Icons.stop_circle_outlined);
    expect(stopIcon, findsOneWidget, reason: '运行中应显示停止按钮');

    // 重复停止 → duplicate 是幂等成功,不得提示失败。
    await tester.tap(stopIcon);
    for (final id in pending.keys.toList()) {
      _respond(bridge, id, pending.remove(id));
    }
    await tester.pump(const Duration(milliseconds: 150));
    expect(find.byType(SnackBar), findsNothing,
        reason: 'duplicate 应视为成功,不弹失败提示');

    // 明确 rejected → 提示并携带原因。
    commandReply = const {'status': 'rejected', 'reasonCode': 'busy'};
    await tester.tap(stopIcon);
    for (final id in pending.keys.toList()) {
      _respond(bridge, id, pending.remove(id));
    }
    await tester.pump(const Duration(milliseconds: 150));
    expect(find.byType(SnackBar), findsOneWidget);
    expect(find.textContaining('停止失败'), findsOneWidget);
    expect(find.textContaining('busy'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    bridge.dispose();
    await tester.pump(const Duration(seconds: 40));
  });
}
