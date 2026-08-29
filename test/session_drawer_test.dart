import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:zflow/protocol/channel_client.dart';
import 'package:zflow/protocol/ipc_codec.dart';
import 'package:zflow/protocol/zflow_client.dart';
import 'package:zflow/state/session_list_cache.dart';
import 'package:zflow/ui/session_drawer.dart';

/// 真实协议驱动的抽屉测试。裸 SessionDrawer 在全新 detached bridge 上的
/// channel 取号是确定性的(FIFO):id0 hello、id1 listPinnedTasks(与
/// 订阅并行拉取)、id2 initialize、id3 索引帧监听器(同步取号)、id4
/// subscribeSessionsIndexV4;之后的管理操作与其后的置顶集刷新依次为
/// id5 setTaskPinned、id6 listPinnedTasks、id7 archiveTask、id8 刷新、
/// id9 deleteTask、id10 刷新。sessions-index 事件帧经 id3(帧监听器)
/// 注入。
///
/// incoming 帧经 `channels.handleMessage` 注入;outgoing 请求由 recorder
/// 的 sendBody 捕获,解码断言真实 wire 的 channel/method/args。

Uint8List _inFrame(List<Object?> header, [Object? data]) {
  final w = ValueWriter();
  encodeValue(w, header);
  if (data != null) encodeValue(w, data);
  return w.toBytes();
}

void _respond(ChannelClient channels, int id, Object? result) => channels
    .handleMessage(_inFrame([ChannelClient.resPromiseSuccess, id], result));

/// 解码一条 outgoing 请求:([100, id, channel, method], args)。
(Object?, Object?) _decodeRequest(Uint8List body) {
  final reader = ValueReader(body);
  final header = decodeValue(reader);
  final args = decodeValue(reader);
  return (header, args);
}

void main() {
  late ChannelClient channels;
  late BridgeSession bridge;
  final sent = <Uint8List>[];
  final picked = <String?>[];
  final switchCounts = <int>[];
  final vanishedCalls = <int>[];

  final now = DateTime.now();
  final entries = [
    {
      'sessionId': 's1',
      'title': '修复登录',
      'phase': 'running',
      'lastActivityAt': now.millisecondsSinceEpoch,
      'createdAt': 1,
    },
    {
      'sessionId': 's2',
      'title': '重构 API',
      'phase': 'idle',
      'lastActivityAt': now.subtract(const Duration(days: 2)).millisecondsSinceEpoch,
      'createdAt': 1,
    },
  ];

  /// 按 wire id 找已发出的请求并解码。
  (Object?, Object?) requestById(int id) => sent
      .map(_decodeRequest)
      .firstWhere((r) => (r.$1 as List)[1] == id);

  SessionDrawer buildDrawer(String workspacePath, {String? currentSessionId}) =>
      SessionDrawer(
        bridge: bridge,
        scope: {'workspacePath': workspacePath},
        workspaceName: 'WS',
        workspacePath: workspacePath,
        currentSessionId: currentSessionId,
        onPick: picked.add,
        onSwitchWorkspace: switchCounts.add,
        onCurrentSessionVanished: () => vanishedCalls.add(1),
        onManageDevices: () {},
        deviceCount: 1,
        deviceOnline: true,
      );

  /// 应答 id1 的 listPinnedTasks([pinned] 为服务端任务列表,元素带 taskId)。
  void respondPinned(List<Object?> pinned) =>
      _respond(channels, 1, pinned);

  Future<void> pumpDrawer(WidgetTester tester,
      {List<Object?> pinned = const []}) async {
    channels = ChannelClient(sendBody: (body) => sent.add(body));
    bridge = BridgeSession.detached(
      {'workspaceKey': '/ws-t'},
      channels: channels,
    );
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: buildDrawer('/ws-t')),
    ));

    // channel 初始化 + 按确定性顺序应答,随后推索引快照让列表渲染。
    channels.handleMessage(_inFrame(const [ChannelClient.resInitialize, 0]));
    await tester.pump(); // id0 hello + id1 listPinnedTasks
    _respond(channels, 0, <String, dynamic>{});
    await tester.pump(); // id2 initialize
    respondPinned(pinned); // id1 应答
    _respond(channels, 2, <String, dynamic>{});
    await tester.pump(); // id3 帧监听器 + id4 subscribeIndex
    _respond(channels, 4, {
      'ack': {'subscriptionId': 'sub-test'},
    });
    await tester.pump();
    // wire 帧{kind,topic,subscriptionId,frame};内层逻辑帧同样携带
    // subscriptionId(_acceptLogicalFrame 以它过滤)。
    channels.handleMessage(_inFrame([ChannelClient.resEventFire, 3], {
      'kind': 'complete',
      'topic': 'sessions-index//ws-t',
      'subscriptionId': 'sub-test',
      'frame': {
        'subscriptionId': 'sub-test',
        'toSeq': 1,
        'payload': {
          'kind': 'snapshot',
          'snapshot': {'sessions': entries},
        },
      },
    }));
    await tester.pump();
    expect(find.text('修复登录'), findsOneWidget); // 列表已渲染
  }

  /// 选中一条并断言已进入多选。
  Future<void> selectRow(WidgetTester tester) async {
    await tester.tap(find.text('管理'));
    await tester.pump();
    await tester.tap(find.text('修复登录'));
    await tester.pump();
    expect(find.text('已选 1 项'), findsOneWidget);
  }

  testWidgets('点会话条目真实触发 onPick(sessionId)', (tester) async {
    await pumpDrawer(tester);
    await tester.tap(find.text('修复登录'));
    await tester.pump();
    expect(picked, ['s1']);
    await tester.tap(find.text('重构 API'));
    await tester.pump();
    expect(picked, ['s1', 's2']);
    await tester.pumpWidget(const SizedBox.shrink());
    bridge.dispose();
    await tester.pump(const Duration(seconds: 40));
  });

  testWidgets('管理操作依次发出 setTaskPinned(pinned:true)/archiveTask/deleteTask',
      (tester) async {
    await pumpDrawer(tester);

    // 置顶:args 必须含 pinned:true(对照 integration_test 服务端契约)。
    await selectRow(tester);
    await tester.tap(find.widgetWithText(OutlinedButton, '置顶'));
    await tester.pump();
    final (pinHeader, pinArgs) = _decodeRequest(sent.last);
    expect(pinHeader, [ChannelClient.reqPromise, 5, 'zcode-task', 'setTaskPinned']);
    expect(pinArgs, [
      {'taskId': 's1', 'workspacePath': '/ws-t', 'pinned': true},
    ]);
    _respond(channels, 5, <String, dynamic>{});
    await tester.pump(); // 完成后退出多选 + id6 置顶集刷新
    respondPinned(const []); // 刷新应答:置顶集清空
    await tester.pump();
    expect(find.text('已选 1 项'), findsNothing); // 完成后退出多选

    // 归档:args 不带 pinned 字段。
    await selectRow(tester);
    await tester.tap(find.widgetWithText(OutlinedButton, '归档'));
    await tester.pump();
    final (archHeader, archArgs) = _decodeRequest(sent.last);
    expect(archHeader, [ChannelClient.reqPromise, 7, 'zcode-task', 'archiveTask']);
    expect(archArgs, [
      {'taskId': 's1', 'workspacePath': '/ws-t'},
    ]);
    _respond(channels, 7, <String, dynamic>{});
    await tester.pump(); // id8 刷新
    respondPinned(const []);
    await tester.pump();
    expect(find.text('已选 1 项'), findsNothing);

    // 删除:确认对话框 → deleteTask。
    await selectRow(tester);
    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pump();
    expect(find.byType(AlertDialog), findsOneWidget);
    await tester.tap(find.descendant(
        of: find.byType(AlertDialog), matching: find.text('删除')));
    await tester.pump();
    final (delHeader, delArgs) = _decodeRequest(sent.last);
    expect(delHeader, [ChannelClient.reqPromise, 9, 'zcode-task', 'deleteTask']);
    expect(delArgs, [
      {'taskId': 's1', 'workspacePath': '/ws-t'},
    ]);
    _respond(channels, 9, <String, dynamic>{});
    await tester.pump(); // id10 刷新
    respondPinned(const []);
    await tester.pump();
    expect(find.text('已选 1 项'), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    bridge.dispose();
    await tester.pump(const Duration(seconds: 40));
  });

  testWidgets('打开抽屉先播种离线缓存;实时数据到达即覆盖;状态点以实时为准',
      (tester) async {
    // 状态点 = 会话行内 8×8 且非空的 SizedBox(种子条目 child 为 null)。
    final statusDotFinder = find.byWidgetPredicate((w) =>
        w is SizedBox && w.width == 8 && w.height == 8 && w.child != null);
    SharedPreferences.setMockInitialValues({
      const SessionListCache().keyFor(const {'workspacePath': '/ws-t'}):
          jsonEncode([
            {
              'sessionId': 'cached-1',
              'title': '离线缓存会话',
              // 缓存里的过期运行态:种子显示,但状态点以实时为准(裁决)。
              'phase': 'running',
              'lastActivityAt':
                  now.subtract(const Duration(days: 1)).millisecondsSinceEpoch,
              'createdAt': 1,
            },
          ]),
    });

    channels = ChannelClient(sendBody: (body) => sent.add(body));
    bridge = BridgeSession.detached(
      {'workspaceKey': '/ws-t'},
      channels: channels,
    );
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: buildDrawer('/ws-t')),
    ));

    // channel 初始化应答,但不推实时快照 —— 抽屉停留在「实时未到达」态。
    channels.handleMessage(_inFrame(const [ChannelClient.resInitialize, 0]));
    await tester.pump(); // id0 hello + id1 listPinnedTasks
    _respond(channels, 0, <String, dynamic>{});
    await tester.pump(); // id2 initialize
    respondPinned(const []);
    _respond(channels, 2, <String, dynamic>{});
    await tester.pump(); // id3 帧监听器 + id4 subscribeIndex
    _respond(channels, 4, {
      'ack': {'subscriptionId': 'sub-test'},
    });
    await tester.pump();

    // 种子显示:订阅未 ready、实时列表为空时,先展示缓存列表。
    expect(find.text('离线缓存会话'), findsOneWidget);
    // 状态点以实时为准:种子条目不渲染状态点(即便缓存 phase=running)。
    expect(statusDotFinder, findsNothing);

    // 实时快照到达 → 覆盖种子;running 条目恢复状态点。
    channels.handleMessage(_inFrame([ChannelClient.resEventFire, 3], {
      'kind': 'complete',
      'topic': 'sessions-index//ws-t',
      'subscriptionId': 'sub-test',
      'frame': {
        'subscriptionId': 'sub-test',
        'toSeq': 1,
        'payload': {
          'kind': 'snapshot',
          'snapshot': {'sessions': entries},
        },
      },
    }));
    await tester.pump();
    expect(find.text('离线缓存会话'), findsNothing);
    expect(find.text('修复登录'), findsOneWidget);
    expect(statusDotFinder, findsOneWidget);

    // 订阅 ready 后 write-through:缓存被实时列表覆盖。
    await tester.pump();
    final prefs = await SharedPreferences.getInstance();
    final stored = jsonDecode(prefs.getString(
        const SessionListCache().keyFor(const {'workspacePath': '/ws-t'}))!)
        as List;
    expect(stored.first['sessionId'], 's1');

    await tester.pumpWidget(const SizedBox.shrink());
    bridge.dispose();
    await tester.pump(const Duration(seconds: 40));
  });

  /// 以 [workspacePath] 为 scope 挂抽屉并完成 channel 握手(id0-id2),
  /// 不应答订阅请求 —— 由调用方决定订阅成功(ack)还是失败(error)。
  Future<void> pumpDrawerHandshake(
    WidgetTester tester,
    String workspacePath, {
    String? currentSessionId,
  }) async {
    channels = ChannelClient(sendBody: (body) => sent.add(body));
    bridge = BridgeSession.detached(
      {'workspaceKey': workspacePath},
      channels: channels,
    );
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: buildDrawer(workspacePath, currentSessionId: currentSessionId),
      ),
    ));
    channels.handleMessage(_inFrame(const [ChannelClient.resInitialize, 0]));
    await tester.pump(); // id0 hello + id1 listPinnedTasks
    _respond(channels, 0, <String, dynamic>{});
    await tester.pump(); // id2 initialize
    respondPinned(const []);
    _respond(channels, 2, <String, dynamic>{});
    await tester.pump(); // id3 帧监听器 + id4 subscribe 发出,由调用方应答
  }

  /// 握手 + 订阅 ack,但不推实时快照 —— 抽屉停留在「实时未到达」态(种子可见)。
  Future<void> pumpDrawerWithoutSnapshot(
    WidgetTester tester,
    String workspacePath, {
    String? currentSessionId,
  }) async {
    await pumpDrawerHandshake(
      tester,
      workspacePath,
      currentSessionId: currentSessionId,
    );
    _respond(channels, 4, {
      'ack': {'subscriptionId': 'sub-test'},
    });
    await tester.pump();
  }

  /// 推一张 sessions-index 快照(逐帧走真实 wire 路径)。
  void pushSnapshot(List<Object?> sessions) {
    channels.handleMessage(_inFrame([ChannelClient.resEventFire, 3], {
      'kind': 'complete',
      'topic': 'sessions-index//ws-t',
      'subscriptionId': 'sub-test',
      'frame': {
        'subscriptionId': 'sub-test',
        'toSeq': 1,
        'payload': {
          'kind': 'snapshot',
          'snapshot': {'sessions': sessions},
        },
      },
    }));
  }

  testWidgets('订阅失败但有离线种子:展示种子列表 + 离线横幅 + 重试', (tester) async {
    SharedPreferences.setMockInitialValues({
      const SessionListCache().keyFor(const {'workspacePath': '/ws-t'}):
          jsonEncode([
            {
              'sessionId': 'cached-1',
              'title': '离线缓存会话',
              'phase': '',
              'lastActivityAt': now.millisecondsSinceEpoch,
              'createdAt': 1,
            },
          ]),
    });
    await pumpDrawerHandshake(tester, '/ws-t');
    // 订阅请求(id4)应答错误 → _error 态。
    channels.handleMessage(_inFrame(
        [ChannelClient.resPromiseError, 4], {'message': 'sub exploded'}));
    await tester.pump();
    // 订阅失败路径含订阅对象回收(异步多跳),两次 pump 保证错误上屏。
    await tester.pump();

    // 不再只显示错误页:种子列表兜底,横幅标记离线数据,重试保留。
    expect(find.text('离线缓存会话'), findsOneWidget);
    expect(find.text('离线数据 · 可能不是最新'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
    expect(find.textContaining('会话列表加载失败'), findsNothing);

    // 重试成功 → 错误横幅消失,回到「实时未到达」种子态。
    await tester.tap(find.text('重试'));
    await tester.pump();
    _respond(channels, 6, {
      'ack': {'subscriptionId': 'sub-test'},
    });
    await tester.pump();
    expect(find.text('离线数据 · 可能不是最新'), findsNothing);
    expect(find.text('离线缓存会话'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    bridge.dispose();
    await tester.pump(const Duration(seconds: 40));
  });

  testWidgets('订阅失败且无种子:仍显示错误页', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await pumpDrawerHandshake(tester, '/ws-t');
    channels.handleMessage(_inFrame(
        [ChannelClient.resPromiseError, 4], {'message': 'sub exploded'}));
    await tester.pump();

    expect(find.textContaining('会话列表加载失败'), findsOneWidget);
    expect(find.text('离线数据 · 可能不是最新'), findsNothing);
    expect(find.text('重试'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    bridge.dispose();
    await tester.pump(const Duration(seconds: 40));
  });

  testWidgets('种子列表同样过搜索过滤', (tester) async {
    SharedPreferences.setMockInitialValues({
      const SessionListCache().keyFor(const {'workspacePath': '/ws-t'}):
          jsonEncode([
            {
              'sessionId': 'cached-1',
              'title': '离线缓存会话',
              'phase': '',
              'lastActivityAt': now.millisecondsSinceEpoch,
              'createdAt': 1,
            },
          ]),
    });
    await pumpDrawerWithoutSnapshot(tester, '/ws-t');
    expect(find.text('离线缓存会话'), findsOneWidget);

    // 命中查询:种子保留。
    await tester.enterText(find.byType(TextField), '离线');
    await tester.pump();
    expect(find.text('离线缓存会话'), findsOneWidget);

    // 未命中:种子被过滤,显示无匹配占位。
    await tester.enterText(find.byType(TextField), '重构');
    await tester.pump();
    expect(find.text('离线缓存会话'), findsNothing);
    expect(find.text('没有匹配「重构」的会话'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    bridge.dispose();
    await tester.pump(const Duration(seconds: 40));
  });

  testWidgets('当前会话从索引消失时回调宿主复位;未收录过的会话消失不误报', (tester) async {
    switchCounts.clear();
    vanishedCalls.clear();
    await pumpDrawerHandshake(tester, '/ws-t', currentSessionId: 's1');
    _respond(channels, 4, {
      'ack': {'subscriptionId': 'sub-test'},
    });
    await tester.pump();

    // 订阅刚就绪、当前会话已在列表(见过)。
    pushSnapshot(entries);
    await tester.pump();
    expect(vanishedCalls, isEmpty);
    expect(switchCounts, isEmpty);

    // s1 被删除/归档:增量推送把它从索引移除 → 回调宿主一次。
    channels.handleMessage(_inFrame([ChannelClient.resEventFire, 3], {
      'kind': 'complete',
      'topic': 'sessions-index//ws-t',
      'subscriptionId': 'sub-test',
      'frame': {
        'subscriptionId': 'sub-test',
        'toSeq': 2,
        'payload': {
          'kind': 'deltas',
          'deltas': [
            {'op': 'session.removed', 'sessionId': 's1'},
          ],
        },
      },
    }));
    await tester.pump();
    expect(find.text('修复登录'), findsNothing);
    expect(vanishedCalls.length, 1);

    await tester.pumpWidget(const SizedBox.shrink());
    bridge.dispose();
    await tester.pump(const Duration(seconds: 40));
  });

  testWidgets('draft 采纳后列表尚未收录该会话:不算消失,不误报复位', (tester) async {
    switchCounts.clear();
    vanishedCalls.clear();
    await pumpDrawerHandshake(tester, '/ws-t', currentSessionId: 's-new');
    _respond(channels, 4, {
      'ack': {'subscriptionId': 'sub-test'},
    });
    await tester.pump();

    // 快照里没有 s-new(draft 采纳瞬间的常态):从未「见过」不触发回调。
    pushSnapshot([entries[1]]);
    await tester.pump();
    expect(find.text('重构 API'), findsOneWidget);
    expect(vanishedCalls, isEmpty);

    await tester.pumpWidget(const SizedBox.shrink());
    bridge.dispose();
    await tester.pump(const Duration(seconds: 40));
  });

  testWidgets('工作区条回调携带当前工作区实时会话数', (tester) async {
    switchCounts.clear();
    await pumpDrawer(tester);
    expect(switchCounts, isEmpty);

    await tester.tap(find.text('WS')); // 工作区条
    await tester.pump();
    expect(switchCounts, [2]); // 实时列表两条

    await tester.pumpWidget(const SizedBox.shrink());
    bridge.dispose();
    await tester.pump(const Duration(seconds: 40));
  });

  testWidgets('抽屉打开并行拉取 listPinnedTasks,命中会话渲染进置顶组',
      (tester) async {
    await pumpDrawer(tester, pinned: [
      {'taskId': 's2'}, // s2 原属「更早」,置顶后进置顶组
    ]);

    // wire 断言:listPinnedTasks 以会话 scope 为参,与订阅并行发出。
    final (header, args) = requestById(1);
    expect(
        header, [ChannelClient.reqPromise, 1, 'zcode-task', 'listPinnedTasks']);
    expect(args, [
      {'workspacePath': '/ws-t'},
    ]);

    // 三档分组:s2 进置顶组,更早组因空被剔除。
    expect(find.text('置顶'), findsOneWidget);
    expect(find.text('今天'), findsOneWidget);
    expect(find.text('更早'), findsNothing);
    expect(find.text('重构 API'), findsOneWidget);

    // 组序与行序:置顶 → s2 → 今天 → s1。
    double dy(Finder f) => tester.getTopLeft(f).dy;
    expect(dy(find.text('置顶')), lessThan(dy(find.text('重构 API'))));
    expect(dy(find.text('重构 API')), lessThan(dy(find.text('今天'))));
    expect(dy(find.text('今天')), lessThan(dy(find.text('修复登录'))));

    await tester.pumpWidget(const SizedBox.shrink());
    bridge.dispose();
    await tester.pump(const Duration(seconds: 40));
  });

  testWidgets('listPinnedTasks 失败容错为空集:列表照常 今天/更早 两档',
      (tester) async {
    await pumpDrawerHandshake(tester, '/ws-t');
    channels.handleMessage(_inFrame(
        [ChannelClient.resPromiseError, 1], {'message': 'pinned exploded'}));
    _respond(channels, 4, {
      'ack': {'subscriptionId': 'sub-test'},
    });
    await tester.pump();
    pushSnapshot(entries);
    await tester.pump();

    expect(find.text('置顶'), findsNothing);
    expect(find.text('今天'), findsOneWidget);
    expect(find.text('更早'), findsOneWidget);
    expect(find.text('修复登录'), findsOneWidget);
    expect(find.text('重构 API'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    bridge.dispose();
    await tester.pump(const Duration(seconds: 40));
  });

  testWidgets('置顶操作完成后重拉置顶集,条目随即进置顶组', (tester) async {
    await pumpDrawer(tester); // 初始置顶集为空
    expect(find.text('置顶'), findsNothing);

    await selectRow(tester); // 选中 s1
    await tester.tap(find.widgetWithText(OutlinedButton, '置顶'));
    await tester.pump();
    final (pinHeader, _) = _decodeRequest(sent.last);
    expect(
        pinHeader, [ChannelClient.reqPromise, 5, 'zcode-task', 'setTaskPinned']);
    _respond(channels, 5, <String, dynamic>{});
    await tester.pump(); // 退出多选 + id6 置顶集刷新请求发出

    // 刷新是紧随操作的新一次 listPinnedTasks。
    final (refreshHeader, refreshArgs) = requestById(6);
    expect(refreshHeader,
        [ChannelClient.reqPromise, 6, 'zcode-task', 'listPinnedTasks']);
    expect(refreshArgs, [
      {'workspacePath': '/ws-t'},
    ]);

    _respond(channels, 6, [
      {'taskId': 's1'},
    ]);
    await tester.pump();

    expect(find.text('已选 1 项'), findsNothing); // 已退出多选
    expect(find.text('置顶'), findsOneWidget);
    double dy(Finder f) => tester.getTopLeft(f).dy;
    expect(dy(find.text('置顶')), lessThan(dy(find.text('修复登录'))));
    expect(find.text('今天'), findsNothing); // s1 移入置顶,今天组空
    expect(find.text('更早'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    bridge.dispose();
    await tester.pump(const Duration(seconds: 40));
  });
}
