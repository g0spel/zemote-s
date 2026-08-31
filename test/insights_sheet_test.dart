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

  group('parseHostPlans(conversationPlansV4 容错解析,纯函数)', () {
    test('解析 {plans: [{title, status}]} 数组', () {
      final plans = parseHostPlans({
        'plans': [
          {'title': 'e141 联合风险预算', 'status': 'in_progress'},
          {'title': 'e140 订单在途', 'status': 'completed'},
        ],
      });
      expect(plans, hasLength(2));
      expect(plans![0].title, 'e141 联合风险预算');
      expect(plans[0].inProgress, isTrue);
      expect(plans[1].completed, isTrue);
    });

    test('解析裸数组与字符串条目', () {
      final plans = parseHostPlans(['第一战役', '第二战役']);
      expect(plans, hasLength(2));
      expect(plans![0].title, '第一战役');
    });

    test('未知形状返回 null(UI 隐藏该段)', () {
      expect(parseHostPlans({'foo': 'bar'}), isNull);
      expect(parseHostPlans(null), isNull);
      expect(parseHostPlans({'plans': [42]}), isNull,
          reason: '条目非对象/字符串 → 全部丢弃');
    });
  });

  group('cacheHitFractionOf(缓存命中率口径,纯函数)', () {
    test('优先取宿主下发的 contextWindow.cache.hitRate', () {
      final fraction = cacheHitFractionOf({
        'contextWindow': {
          'usedTokens': 1000,
          'maxTokens': 200000,
          'cache': {'hitRate': 0.42, 'inputTokens': 5},
        },
        'cumulative': {
          'inputTokens': 10,
          'cacheReadTokens': 9999,
          'cacheWriteTokens': 9999,
        },
      });
      expect(fraction, 0.42,
          reason: '服务端加权值优先,cumulative 回退不参与');
    });

    test('无 cache 对象时按桌面回退公式 缓存读 ÷ 输入(写入不进分母)', () {
      final fraction = cacheHitFractionOf({
        'cumulative': {
          'inputTokens': 100,
          'cacheReadTokens': 80,
          'cacheWriteTokens': 50,
          'outputTokens': 10,
        },
      });
      expect(fraction, closeTo(0.8, 1e-9),
          reason: '80/100,而非 80/(100+50+80)——对齐桌面口径');
    });

    test('cache.hitRate 为 null 或非数值时回退 cumulative', () {
      expect(
        cacheHitFractionOf({
          'contextWindow': {
            'cache': {'hitRate': null},
          },
          'cumulative': {'inputTokens': 100, 'cacheReadTokens': 25},
        }),
        0.25,
      );
      expect(
        cacheHitFractionOf({
          'contextWindow': {
            'cache': {'hitRate': '0.9'},
          },
          'cumulative': {'inputTokens': 100, 'cacheReadTokens': 25},
        }),
        0.25,
      );
    });

    test('无数据返回 null(UI 隐藏该行)', () {
      expect(cacheHitFractionOf({}), isNull);
      expect(
        cacheHitFractionOf({
          'cumulative': {'inputTokens': 0, 'cacheReadTokens': 0},
        }),
        isNull,
        reason: '分母为 0 不产生命中率',
      );
    });
  });

  group('todoStepsOf(todo 工具输出解析,纯函数)', () {
    test('解析裸数组输出(content/status 形状)', () {
      final steps = todoStepsOf({
        'toolName': 'todoread',
        'output': {
          'text':
              '[{"content":"逆向桌面","status":"completed"},{"content":"修正口径","status":"in_progress"}]',
        },
      });
      expect(steps, hasLength(2));
      expect(steps![0].title, '逆向桌面');
      expect(steps[0].completed, isTrue);
      expect(steps[1].inProgress, isTrue);
    });

    test('解析 {todos: [...]} 包装(输入侧形状)', () {
      final steps = todoStepsOf({
        'toolName': 'todowrite',
        'inputText':
            '{"todos": [{"content": "发版", "status": "pending"}]}',
      });
      expect(steps, hasLength(1));
      expect(steps![0].title, '发版');
      expect(steps[0].status, 'pending');
    });

    test('坏 JSON / 非列表形状返回 null(回落原始文本)', () {
      expect(
        todoStepsOf({
          'toolName': 'todoread',
          'output': {'text': 'not json'},
        }),
        isNull,
      );
      expect(
        todoStepsOf({
          'toolName': 'todoread',
          'output': {'text': '{"foo": 1}'},
        }),
        isNull,
      );
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

    testWidgets('状态通知后待办面板实时刷新', (tester) async {
      final state = ConversationState();
      final (bridge, _) = await pumpSheet(tester, state);
      expect(find.text('暂无待办'), findsOneWidget);

      state.rows = [
        {
          'kind': 'toolCall',
          'rowId': 1,
          'toolName': 'TodoWrite',
          'input': {
            'todos': [
              {'content': '新待办', 'status': 'in_progress'},
            ],
          },
        },
      ];
      state.notifyListeners();
      await tester.pump();
      expect(find.text('新待办'), findsOneWidget);
      await _tearDown(tester, bridge);
    });

    testWidgets('切「后台」chip 渲染后台面板(运行中任务)', (tester) async {
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
      final (bridge, _) = await pumpSheet(tester, state);
      // 原把手打开入口已迁入 composer 图标行(InsightsHandle 删除),
      // sheet 本体的后台 chip 切换行为不变。
      await tester.tap(find.descendant(
          of: find.byType(InsightsSheet), matching: find.text('后台 1')));
      await tester.pump();
      expect(find.text('长测试命令'), findsOneWidget);
      await _tearDown(tester, bridge);
    });

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
      // 默认折叠为胶囊(桌面同款):点开后列出全部步骤。
      await tester.tap(find.text('写解析器'));
      await tester.pump();
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

    testWidgets('交互项同一 source 重建时保持 busy,不因 closure 变化重置', (tester) async {
      final (bridge, transport) = _makeBridge();
      final state = ConversationState()
        ..snapshot = {
          'pendingInteractions': [
            {
              'interactionId': 'i1',
              'payload': {
                'kind': 'permission',
                'toolName': 'bash',
                'options': [
                  {'optionId': 'allowOnce', 'label': '允许一次'},
                ],
              },
            },
          ],
        };
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: pendingInteractionsForTest(
            state: state,
            transport: transport,
          ),
        ),
      ));
      await tester.tap(find.text('允许一次'));
      await tester.pump();
      expect(
          tester.widget<OutlinedButton>(find.byType(OutlinedButton)).onPressed,
          isNull);

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: pendingInteractionsForTest(
            state: state,
            transport: transport,
          ),
        ),
      ));
      await tester.pump();
      expect(
          tester.widget<OutlinedButton>(find.byType(OutlinedButton)).onPressed,
          isNull);
      await _tearDown(tester, bridge);
    });

    testWidgets('source 切换后旧 fileChanges 应答不写回 sheet', (tester) async {
      final state = ConversationState()
        ..rows = [
          {
            'kind': 'turnHeader',
            'rowId': 1,
            'entityId': 'e1',
            'state': 'completedSuccess',
            'fileChanges': {'files': 1, 'additions': 1, 'deletions': 0},
          },
        ];
      final channels = ChannelClient(sendBody: (_) {});
      final bridge = BridgeSession.detached(
        {'workspaceKey': '/ws-t'},
        channels: channels,
      );
      final transport = ConversationTransport(
        session: bridge,
        scope: const {'workspacePath': '/ws-t'},
      );
      var current = true;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: InsightsSheet(
            state: state,
            transport: transport,
            sessionId: 's1',
            scrollController: ScrollController(),
            isSourceCurrent: () => current,
          ),
        ),
      ));
      channels.handleMessage(_inFrame(const [ChannelClient.resInitialize, 0]));
      await tester.pump();
      _respond(channels, 0, <String, dynamic>{});
      await tester.pump();
      _respond(channels, 1, <String, dynamic>{});
      await tester.pump();
      current = false;
      _respond(channels, 2, {
        'files': [
          {'path': 'old.dart', 'additions': 1, 'deletions': 0},
        ],
      });
      await tester.pump();
      expect(find.text('old.dart'), findsNothing);
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
      // 最新完成回合自动装载并展开:回合分组标题行 + 逐文件明细都可见。
      expect(find.text('回合 1 · 1 个文件已更改'), findsOneWidget);
      expect(find.text('lib/ui/chat_page.dart'), findsOneWidget);
      // 点击摘要行收起明细,再点重开(条目已缓存,不重发请求)。
      await tester.tap(find.text('回合 1 · 1 个文件已更改'));
      await tester.pump();
      expect(find.text('lib/ui/chat_page.dart'), findsNothing);
      await tester.tap(find.text('回合 1 · 1 个文件已更改'));
      await tester.pump();
      await tester.pump();
      expect(find.text('lib/ui/chat_page.dart'), findsOneWidget);
      await _tearDown(tester, bridge);
    });
  });
}
