import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zflow/protocol/channel_client.dart';
import 'package:zflow/protocol/ipc_codec.dart';
import 'package:zflow/protocol/zflow_client.dart';
import 'package:zflow/ui/chat_page.dart';

/// 布局回归(真机 v0.11.0 症状:消息流文字堆叠 / 不可滚动):
/// embedded ChatPage 采纳会话并收到快照后,消息流 ListView 的滚动
/// position 必须唯一,不同消息条目的渲染矩形不得互相重叠,且列表
/// 可实际滚动。
///
/// 根因回顾:思考/工具卡片曾用 Row+CrossAxisAlignment.stretch 画状态
/// 轨;在无界高度(滚动列表条目)下 stretch 把 h=Infinity 传给子级,
/// debug 抛 infinite-height 异常、release 断言剥离后布局坍缩——正是
/// 真机的文字堆叠与滚动僵死形态。本测试在修复前可复现该异常。
///
/// 驱动不依赖取号顺序:sendBody 侧按 (channel, method) 自动生成应答,
/// 事件监听器按事件名定位(真实 socket 上应答时序本就不确定)。
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

Object? _autoReply(String method) {
  switch (method) {
    case 'prepareWorkspace':
      return <String, dynamic>{};
    case 'list': // skills.list
      return const <dynamic>[];
    case 'helloConversationV4':
    case 'initializeConversationV4':
      return <String, dynamic>{};
    case 'createSession':
    case 'sendConversationCommandV4': // createSession 的信封方法
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

void main() {
  testWidgets('快照后:position 唯一、条目不重叠且可滚动', (tester) async {
    tester.view.physicalSize = const Size(1080, 2280);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    final listeners = <int, String>{}; // 监听器 id -> 事件名
    final pending = <int, Object?>{}; // 待投递的 RPC 应答
    final channels = ChannelClient(sendBody: (body) {
      final r = ValueReader(body);
      final h = decodeValue(r) as List;
      if (h[0] == ChannelClient.reqPromise) {
        pending[h[1] as int] = _autoReply(h[3] as String);
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
          sessionId: null,
          title: '新会话',
          embedded: true,
        ),
      ),
    ));

    bridge.channels
        .handleMessage(_frame(const [ChannelClient.resInitialize, 0]));
    await tester.pump();

    await tester.enterText(find.byType(TextField), '第一条用户消息');
    await tester.tap(find.byIcon(Icons.arrow_upward));

    // 泵到握手/订阅全部就绪(会话帧监听器已注册)。
    for (var i = 0; i < 12 && !listeners.containsValue(
        'onDynamicConversationFrame'); i++) {
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

    // 会话快照:首三条定锚,后续行撑出滚动余量(reverse 懒构建,
    // 视口内是末尾几行)。
    _fire(bridge, convListener, {
      'kind': 'complete',
      'topic': 'conversation/s1',
      'subscriptionId': 'conv-sub',
      'frame': {
        'subscriptionId': 'conv-sub',
        'toSeq': 30,
        'payload': {
          'kind': 'snapshot',
          'snapshot': {
            'revision': 1,
            'logEpoch': 'e1',
            'control': {'phase': 'running'},
            'rows': {
              'totalCount': 30,
              'firstRowId': 1,
              'window': [
                {
                  'rowId': 1,
                  'kind': 'userInput',
                  'text': '第一条用户消息',
                  'state': 'completed',
                },
                {
                  'rowId': 2,
                  'kind': 'reasoning',
                  'text': '先梳理需求:这是一段足够长的思考文本,'
                      '用于验证条目高度与渲染位置;补充第二句。',
                  'state': 'completedSuccess',
                },
                {
                  'rowId': 3,
                  'kind': 'assistantText',
                  'text': '助手回复正文:这段文本用于断言两个不同消息条目'
                      '的渲染矩形互不重叠;再补一句使文本跨多行。',
                  'state': 'completed',
                },
                for (var i = 4; i <= 30; i++)
                  {
                    'rowId': i,
                    'kind': i.isEven ? 'reasoning' : 'assistantText',
                    'text': '第$i行:继续填充较长的正文内容以撑出滚动余量,'
                        '这里连续铺陈数行文字,保证单条目高度足够、'
                        '整体列表远超视口。',
                    'state': i == 30 ? 'streaming' : 'completed',
                  },
              ],
            },
          },
        },
      },
    });
    // 每帧通知经 100ms 合并定时器,pump 需推进假时钟。
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pump(const Duration(milliseconds: 150));

    // --- 断言 1:消息流 ListView 已挂载且 position 唯一 ---
    final lists = tester.widgetList<ListView>(find.byType(ListView)).toList();
    expect(lists, isNotEmpty, reason: '快照后消息流 ListView 应已挂载');
    for (final lv in lists) {
      expect(lv.controller, isNotNull);
      expect(lv.controller!.positions.length, 1,
          reason: 'controller 被多个 viewport attach(release 模式下即'
              '真机的文字堆叠/滚动僵死形态)');
    }

    // --- 断言 2:不同消息条目的渲染矩形互不重叠 ---
    final first = tester.getRect(find.textContaining('第29行').first);
    final reply = tester.getRect(find.textContaining('第30行').first);
    final separated =
        first.bottom <= reply.top || reply.bottom <= first.top;
    expect(separated, isTrue,
        reason: '相邻两条消息($first / $reply)渲染矩形重叠'
            '——真机文字堆叠形态');

    // --- 断言 3:消息流可滚动 ---
    // reverse 列表 offset 0 是最新一端,手指下滑(内容下移)翻出更早
    // 内容、offset 增大;上滑在此处是 overscroll,被 Clamping 钳住。
    final lv = lists.where((l) => l.controller != null).first;
    await tester.drag(find.byType(ListView), const Offset(0, 120));
    await tester.pumpAndSettle();
    expect(lv.controller!.offset,
        isNot(equals(lv.controller!.initialScrollOffset)),
        reason: '拖拽后 offset 未变化——真机滚动僵死形态');

    // 清理:卸载、释放桥(帧装配心跳定时器不在树上)、冲刷定时器。
    await tester.pumpWidget(const SizedBox.shrink());
    bridge.dispose();
    await tester.pump(const Duration(seconds: 40));
  });

  testWidgets('状态胶囊随订阅实时翻转:轮次结束帧后不靠 setState 也变空闲',
      (tester) async {
    tester.view.physicalSize = const Size(1080, 2280);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    final listeners = <int, String>{};
    final pending = <int, Object?>{};
    final channels = ChannelClient(sendBody: (body) {
      final r = ValueReader(body);
      final h = decodeValue(r) as List;
      if (h[0] == ChannelClient.reqPromise) {
        pending[h[1] as int] = _autoReply(h[3] as String);
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
          sessionId: null,
          title: '新会话',
          embedded: true,
        ),
      ),
    ));

    bridge.channels
        .handleMessage(_frame(const [ChannelClient.resInitialize, 0]));
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'hi');
    await tester.tap(find.byIcon(Icons.arrow_upward));
    for (var i = 0; i < 12 &&
        !listeners.containsValue('onDynamicConversationFrame'); i++) {
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

    // 运行中快照:userInput 行落地(echo 退役,之后不再有页面 setState)。
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
    // 运行中带本轮用时后缀(用户裁定):「工作中 · Ns」。
    expect(find.textContaining('工作中'), findsOneWidget);

    // 轮次结束:仅 state.updated 增量(无任何页面 setState)。胶囊必须
    // 经自身订阅监听翻转为「空闲」——真机症状:结束后仍显示工作中。
    _fire(bridge, convListener, {
      'kind': 'complete',
      'topic': 'conversation/s1',
      'subscriptionId': 'conv-sub',
      'frame': {
        'subscriptionId': 'conv-sub',
        'fromSeq': 2,
        'toSeq': 3,
        'payload': {
          'kind': 'deltas',
          'deltas': [
            {
              'op': 'state.updated',
              'patch': {
                'control': {'phase': 'completedSuccess'},
              },
            },
          ],
        },
      },
    });
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pump(const Duration(milliseconds: 150));
    expect(find.text('空闲'), findsOneWidget,
        reason: '轮次结束帧后胶囊应实时翻转为空闲');
    expect(find.textContaining('工作中'), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    bridge.dispose();
    await tester.pump(const Duration(seconds: 40));
  });

  testWidgets('长模型名不把会话列表按钮挤出屏(pill 省略,☰ 在界内)',
      (tester) async {
    tester.view.physicalSize = const Size(1080, 2280);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    final listeners = <int, String>{};
    final pending = <int, Object?>{};
    final channels = ChannelClient(sendBody: (body) {
      final r = ValueReader(body);
      final h = decodeValue(r) as List;
      if (h[0] == ChannelClient.reqPromise) {
        pending[h[1] as int] = _autoReply(h[3] as String);
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
          sessionId: null,
          title: '新会话',
          embedded: true,
          onOpenDrawer: () {},
        ),
      ),
    ));

    bridge.channels
        .handleMessage(_frame(const [ChannelClient.resInitialize, 0]));
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'hi');
    await tester.tap(find.byIcon(Icons.arrow_upward));
    for (var i = 0; i < 12 &&
        !listeners.containsValue('onDynamicConversationFrame'); i++) {
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

    // 运行中(停止按钮在场)+ 超长模型名:顶栏第二行最挤的形态。
    // RenderFlex 溢出会直接抛异常判失败;☰ 必须完整落在界内。
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
            'config': {
              'provider': 'builtin:bigmodel-coding-plan',
              'model': 'claude-sonnet-4-5-20250929-very-long-name',
            },
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

    expect(find.byIcon(Icons.menu), findsOneWidget);
    final rect = tester.getRect(find.byIcon(Icons.menu));
    expect(rect.right, lessThanOrEqualTo(360), // 1080/3 逻辑宽
        reason: '会话列表按钮被长模型名挤出屏幕(真机三杠出界形态)');
    // 模型/思考设置已内联进输入区卡片(桌面同款):图标必须在场。
    expect(find.byIcon(Icons.view_in_ar), findsOneWidget);
    expect(find.byIcon(Icons.psychology), findsOneWidget);
    // 运行中 + 输入为空 → 发送键变停止方块。
    expect(find.byIcon(Icons.stop), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    bridge.dispose();
    await tester.pump(const Duration(seconds: 40));
  });
}
