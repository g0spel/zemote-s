import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zflow/protocol/channel_client.dart';
import 'package:zflow/protocol/conversation.dart';
import 'package:zflow/protocol/ipc_codec.dart';
import 'package:zflow/protocol/zflow_client.dart';
import 'package:zflow/ui/chat_page.dart';

/// wire 帧([resInitialize, 0] 初始化帧或 [type, id] 响应帧 + data)。
Uint8List _inFrame(List<Object?> header, [Object? data]) {
  final w = ValueWriter();
  encodeValue(w, header);
  if (data != null) encodeValue(w, data);
  return w.toBytes();
}

void _respond(ChannelClient channels, int id, Object? result) => channels
    .handleMessage(_inFrame([ChannelClient.resPromiseSuccess, id], result));

/// detached bridge + 可捕获 outgoing 的 ChannelClient(真实协议栈)。
(BridgeSession, ConversationTransport) _makeBridge() {
  final bridge = BridgeSession.detached(
    {'workspaceKey': '/ws-t'},
    channels: ChannelClient(sendBody: (_) {}),
  );
  return (
    bridge,
    ConversationTransport(
      session: bridge,
      scope: const {'workspacePath': '/ws-t'},
    ),
  );
}

/// 收尾:卸载树 + 释放 bridge(取消 RpcFrameTransport 的周期清理定时器)
/// + 推进 fake 时钟冲掉残留超时定时器,满足 pending-timer 不变量。
Future<void> _tearDown(WidgetTester tester, BridgeSession bridge) async {
  await tester.pumpWidget(const SizedBox.shrink());
  bridge.dispose();
  await tester.pump(const Duration(seconds: 40));
}

void main() {
  group('insightsBgCount(后台把手计数徽,纯函数)', () {
    test('running 且未结束(无 endedAt)的后台任务计数', () {
      final n = insightsBgCount(
        backgroundWorks: [
          {'workId': 'w1', 'kind': 'bash', 'status': 'running'},
          {'workId': 'w2', 'kind': 'bash', 'status': 'running', 'endedAt': 123},
          {'workId': 'w3', 'kind': 'bash', 'status': 'failed'},
          {'workId': 'w4', 'kind': 'bash', 'status': 'cancelled'},
        ],
        rows: const [],
      );
      expect(n, 1);
    });

    test('消息流内联 subagent 行计入(任意状态)', () {
      final n = insightsBgCount(
        backgroundWorks: const [],
        rows: [
          {'kind': 'subagent', 'rowId': 1, 'status': 'running'},
          {'kind': 'subagent', 'rowId': 2, 'status': 'success'},
          {'kind': 'assistantText', 'rowId': 3, 'text': 'hi'},
        ],
      );
      expect(n, 2);
    });

    test('后台任务 + 内联行合并计数', () {
      final n = insightsBgCount(
        backgroundWorks: [
          {'workId': 'w1', 'status': 'running'},
        ],
        rows: [
          {'kind': 'subagent', 'rowId': 1, 'status': 'success'},
        ],
      );
      expect(n, 2);
    });

    test('空会话为 0——把手常驻但不浮计数徽', () {
      expect(
        insightsBgCount(backgroundWorks: const [], rows: const []),
        0,
      );
    });
  });

  group('InsightsHandle(输入区上方把手)', () {
    Future<BridgeSession> pumpHandle(
        WidgetTester tester, ConversationState state) async {
      final (bridge, transport) = _makeBridge();
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              const Expanded(child: SizedBox.shrink()),
              InsightsHandle(
                state: state,
                transport: transport,
                sessionId: 's1',
              ),
            ],
          ),
        ),
      ));
      await tester.pump();
      return bridge;
    }

    testWidgets('面板数据为空也常驻渲染,且无计数徽', (tester) async {
      final bridge = await pumpHandle(tester, ConversationState());
      expect(find.byType(InsightsHandle), findsOneWidget);
      expect(find.textContaining('后台'), findsNothing);
      await _tearDown(tester, bridge);
    });

    testWidgets('后台有运行任务时显示「后台 N」计数徽', (tester) async {
      final state = ConversationState()
        ..snapshot = {
          'backgroundWorks': [
            {'workId': 'w1', 'kind': 'bash', 'status': 'running'},
          ],
        };
      final bridge = await pumpHandle(tester, state);
      expect(find.text('后台 1'), findsOneWidget);
      await _tearDown(tester, bridge);
    });

    testWidgets('点击把手弹出洞察 sheet(空数据也渲染「暂无待办」)', (tester) async {
      final bridge = await pumpHandle(tester, ConversationState());
      await tester.tap(find.byType(InsightsHandle));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(InsightsSheet), findsOneWidget);
      expect(find.text('暂无待办'), findsOneWidget);
      await _tearDown(tester, bridge);
    });

    testWidgets('上滑把手同样弹出洞察 sheet', (tester) async {
      final bridge = await pumpHandle(tester, ConversationState());
      await tester.fling(
          find.byType(InsightsHandle), const Offset(0, -200), 800);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(InsightsSheet), findsOneWidget);
      await _tearDown(tester, bridge);
    });

    testWidgets('sheet 内切「后台」chip 渲染后台面板', (tester) async {
      final state = ConversationState()
        ..snapshot = {
          'backgroundWorks': [
            {
              'workId': 'w1',
              'kind': 'bash',
              'title': '长测试命令',
              'status': 'running',
            },
          ],
        };
      final bridge = await pumpHandle(tester, state);
      await tester.tap(find.byType(InsightsHandle));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      // sheet 内的后台 chip(把手计数徽同文案,限定 sheet 子树)。
      await tester.tap(find.descendant(
          of: find.byType(InsightsSheet), matching: find.text('后台 1')));
      await tester.pump();
      expect(find.text('长测试命令'), findsOneWidget);
      await _tearDown(tester, bridge);
    });
  });

  group('InsightsSheet(chip 切换渲染对应面板)', () {
    /// 直接挂 sheet(不经把手):返回 wire 通道供应答注入。
    Future<(BridgeSession, ChannelClient)> pumpSheet(
        WidgetTester tester, ConversationState state) async {
      final channels = ChannelClient(sendBody: (_) {});
      final bridge = BridgeSession.detached(
        {'workspaceKey': '/ws-t'},
        channels: channels,
      );
      final transport = ConversationTransport(
        session: bridge,
        scope: const {'workspacePath': '/ws-t'},
      );
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: InsightsSheet(
            state: state,
            transport: transport,
            sessionId: 's1',
            scrollController: ScrollController(),
          ),
        ),
      ));
      await tester.pump();
      return (bridge, channels);
    }

    testWidgets('默认待办 Tab:TodoWrite 推导为待办行', (tester) async {
      final state = ConversationState()
        ..rows = [
          {
            'kind': 'toolCall',
            'rowId': 1,
            'toolName': 'TodoWrite',
            'input': {
              'todos': [
                {'content': '调研协议', 'status': 'completed'},
                {'content': '写解析器', 'status': 'in_progress'},
              ],
            },
          },
        ];
      final (bridge, _) = await pumpSheet(tester, state);
      expect(find.text('调研协议'), findsOneWidget);
      expect(find.text('写解析器'), findsOneWidget);
      expect(find.text('待办 2'), findsOneWidget);
      await _tearDown(tester, bridge);
    });

    testWidgets('切「后台」chip:后台任务与运行中子代理混排', (tester) async {
      final state = ConversationState()
        ..snapshot = {
          'backgroundWorks': [
            {
              'workId': 'w1',
              'kind': 'bash',
              'title': '长测试命令',
              'status': 'running',
            },
          ],
          'subagents': {
            'running': [
              {
                'childSessionId': 'c1',
                'subagentType': 'Explore',
                'title': '探索协议层',
              },
            ],
            'endedTotal': 0,
          },
        };
      final (bridge, _) = await pumpSheet(tester, state);
      await tester.tap(find.text('后台 1'));
      await tester.pump();
      expect(find.text('长测试命令'), findsOneWidget);
      expect(find.textContaining('探索协议层'), findsOneWidget);
      await _tearDown(tester, bridge);
    });

    testWidgets('切「文件」chip:wire 级应答 fileChanges 并渲染文件行', (tester) async {
      final state = ConversationState()
        ..rows = [
          {
            'kind': 'turnHeader',
            'rowId': 1,
            'entityId': 'e1',
            'state': 'completedSuccess',
            'fileChanges': {'files': 1, 'additions': 2, 'deletions': 1},
          },
        ];
      final (bridge, channels) = await pumpSheet(tester, state);
      channels.handleMessage(_inFrame(const [ChannelClient.resInitialize, 0]));
      await tester.tap(find.text('文件 1'));
      await tester.pump(); // ready 就绪 → hello id0
      _respond(channels, 0, <String, dynamic>{});
      await tester.pump(); // initialize id1
      _respond(channels, 1, <String, dynamic>{});
      await tester.pump(); // fileChanges id2
      _respond(channels, 2, {
        'files': [
          {'path': 'lib/ui/chat_page.dart', 'additions': 2, 'deletions': 1},
        ],
      });
      await tester.pump();
      await tester.pump();
      expect(find.textContaining('最近回合'), findsOneWidget); // 回合摘要行
      expect(find.text('lib/ui/chat_page.dart'), findsOneWidget);
      await _tearDown(tester, bridge);
    });
  });
}
