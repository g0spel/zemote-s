import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zflow/protocol/channel_client.dart';
import 'package:zflow/protocol/ipc_codec.dart';
import 'package:zflow/protocol/zflow_client.dart';
import 'package:zflow/ui/chat_page.dart';

/// 真实协议驱动(channel 帧):ChatPage 在全新 detached bridge 上的请求
/// 取号是确定性的(channel.call 先等 ready、按 FIFO 取号);全部请求
/// 都应答,避免悬空超时定时器污染测试收尾:
///   id0 prepareWorkspace      id1 helloConversationV4
///   id2 initializeV4          id3 索引帧监听器(同步取号)
///   id4 subscribeSessionsIndexV4   id5 skills.list
///   id6 createSession(首条消息)   id7 会话帧监听器
///   id8 subscribeConversationV4
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
  testWidgets('draft:索引标题先于 createSession 返回时,采纳会话后补推标题',
      (tester) async {
    final bridge = BridgeSession.detached({'workspaceKey': '/ws-t'});
    final pushed = <List<Object>>[];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ChatPage(
          session: bridge,
          scope: const {'workspacePath': '/ws-t'},
          workspaceKey: '/ws-t',
          sessionId: null,
          title: '新会话',
          embedded: true,
          onSessionInfo: (sessionId, title, epoch) =>
              pushed.add([sessionId, title, epoch]),
        ),
      ),
    ));

    // 完成 channel 初始化帧(真实协议路径),随后按确定性顺序应答。
    bridge.channels
        .handleMessage(_frame(const [ChannelClient.resInitialize, 0]));
    await tester.pump(); // id0 prepareWorkspace / id1 hello 取号
    _respond(bridge, 1, <String, dynamic>{});
    await tester.pump(); // id2 initialize 取号
    _respond(bridge, 2, <String, dynamic>{});
    await tester.pump(); // id3 索引帧监听器 + id4 subscribeIndex 取号
    _respond(bridge, 4, {
      'ack': {'subscriptionId': 'sub-test'},
    });
    _respond(bridge, 0, <String, dynamic>{});
    await tester.pump(); // id5 skills.list 取号
    _respond(bridge, 5, const <dynamic>[]);

    // 发送首条消息:createSession 在途(id6)。
    await tester.enterText(find.byType(TextField), '你好');
    await tester.tap(find.byIcon(Icons.arrow_upward));
    await tester.pump();
    await tester.pump();

    // 竞态:桌面端先推索引(标题已生成),createSession 尚未返回。
    // wire 帧{kind,topic,subscriptionId,frame};内层逻辑帧按协议同样
    // 携带 subscriptionId(_acceptLogicalFrame 以它过滤)。
    _fire(bridge, 3, {
      'kind': 'complete',
      'topic': 'sessions-index//ws-t',
      'subscriptionId': 'sub-test',
      'frame': {
        'subscriptionId': 'sub-test',
        'toSeq': 1,
        'payload': {
          'kind': 'snapshot',
          'snapshot': {
            'sessions': [
              {
                'sessionId': 's-new',
                'title': '桌面起的标题',
                'phase': 'running',
                'lastActivityAt': 9,
                'createdAt': 1,
              },
            ],
          },
        },
      },
    });
    await tester.pump();
    expect(pushed, isEmpty); // 会话尚未采纳,不推

    _respond(bridge, 6, {
      'status': 'accepted',
      'result': {'sessionId': 's-new'},
    });
    await tester.pump();
    // 首条消息随 createSession 发出,后台订阅会话流(id7 监听/id8 请求)。
    _respond(bridge, 8, {
      'ack': {'subscriptionId': 'conv-sub'},
    });
    await tester.pump();
    await tester.pump();

    // 修复点:采纳 sessionId 后补跑推送,且携带会话 id 供壳回写
    // (修复前此处为空;Task 4 起回调签名为 (sessionId, title),
    // A10 起追加宿主重建代数 epoch,未注入时恒为 0)。
    expect(pushed, [
      ['s-new', '桌面起的标题', 0],
    ]);
    // 回归:发送完成后 composer 回到可输入态。
    expect(find.byIcon(Icons.arrow_upward), findsOneWidget);

    // 清理:卸载(两个订阅各自 unsubscribe)、释放桥(其帧装配心跳
    // 定时器不在树上,须显式 dispose),再冲刷残余定时器。
    await tester.pumpWidget(const SizedBox.shrink());
    bridge.dispose();
    await tester.pump(const Duration(seconds: 40));
  });
}
