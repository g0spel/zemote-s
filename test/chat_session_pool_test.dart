import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zflow/protocol/channel_client.dart';
import 'package:zflow/protocol/ipc_codec.dart';
import 'package:zflow/protocol/zflow_client.dart';
import 'package:zflow/ui/chat_page.dart';

/// 切会话保活(驻留池)端到端:s1 → s2 → 切回 s1,期间
/// subscribeConversationV4 只发两次(每会话各一次),切回零握手。
Uint8List _frame(List<Object?> header, [Object? data]) {
  final w = ValueWriter();
  encodeValue(w, header);
  if (data != null) encodeValue(w, data);
  return w.toBytes();
}

void _respond(BridgeSession bridge, int id, Object? result) => bridge.channels
    .handleMessage(_frame([ChannelClient.resPromiseSuccess, id], result));

Object? _autoReply(String method) {
  switch (method) {
    case 'prepareWorkspace':
      return <String, dynamic>{};
    case 'list':
      return const <dynamic>[];
    case 'helloConversationV4':
    case 'initializeConversationV4':
      return <String, dynamic>{};
    case 'subscribeConversationV4':
      return {
        'ack': {'subscriptionId': 'pool-sub'},
      };
    case 'subscribeSessionsIndexV4':
      return {
        'ack': {'subscriptionId': 'pool-idx'},
      };
    default:
      return <String, dynamic>{};
  }
}

Widget _chat(BridgeSession bridge, String sessionId) => MaterialApp(
      home: Scaffold(
        body: ChatPage(
          session: bridge,
          scope: const {'workspacePath': '/ws'},
          workspaceKey: '/ws',
          sessionId: sessionId,
          title: sessionId,
          embedded: true,
        ),
      ),
    );

Future<void> _settleHandshake(WidgetTester tester, BridgeSession bridge,
    List<Uint8List> sent) async {
  for (var i = 0; i < 8; i++) {
    final pending = <int, Object?>{};
    for (final body in sent) {
      final reader = ValueReader(body);
      final header = decodeValue(reader) as List;
      if (header[0] == ChannelClient.reqPromise) {
        final id = header[1] as int;
        final reply = _autoReply(header[3] as String);
        if (reply != null) pending[id] = reply;
      }
    }
    if (pending.isEmpty) return;
    pending.forEach((id, result) => _respond(bridge, id, result));
    await tester.pump(const Duration(milliseconds: 120));
  }
}

int _subscribeCount(List<Uint8List> sent) {
  var n = 0;
  for (final body in sent) {
    final reader = ValueReader(body);
    final header = decodeValue(reader) as List;
    if (header[0] == ChannelClient.reqPromise &&
        header[3] == 'subscribeConversationV4') {
      n++;
    }
  }
  return n;
}

void main() {
  testWidgets('切回最近会话零重订阅（驻留池命中）', (tester) async {
    final sent = <Uint8List>[];
    final channels = ChannelClient(sendBody: sent.add);
    final bridge =
        BridgeSession.detached({'workspaceKey': '/ws'}, channels: channels);
    channels.handleMessage(_frame(const [ChannelClient.resInitialize, 0]));

    await tester.pumpWidget(_chat(bridge, 's1'));
    await tester.pump();
    await _settleHandshake(tester, bridge, sent);
    final afterS1 = _subscribeCount(sent);
    expect(afterS1, 1, reason: 's1 首次订阅');

    // 切到 s2（同 bridge）：s1 驻留，s2 新订阅。
    await tester.pumpWidget(_chat(bridge, 's2'));
    await tester.pump();
    await _settleHandshake(tester, bridge, sent);
    final afterS2 = _subscribeCount(sent);
    expect(afterS2, 2, reason: 's2 首次订阅');

    // 切回 s1：驻留池命中，不再发订阅请求。
    await tester.pumpWidget(_chat(bridge, 's1'));
    await tester.pump();
    await _settleHandshake(tester, bridge, sent);
    expect(_subscribeCount(sent), 2, reason: '切回 s1 零重订阅');

    await tester.pumpWidget(const SizedBox.shrink());
    bridge.dispose();
    await tester.pump(const Duration(seconds: 40));
  });
}
