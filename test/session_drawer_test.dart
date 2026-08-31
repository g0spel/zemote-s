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
/// subscribeSessionsIndexV4、id5 listSessions(归档列表);之后的管理
/// 操作与其后的置顶集刷新依次顺延。sessions-index 事件帧经 id3(帧
/// 监听器)注入。应答一律按 wire id 十进制字面量,新增并行请求时按序
/// 补应答。
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

/// 按 channel.method 应答其最小 wire id(替代手写 id 序列:抽屉初始化
/// 的并行 RPC(listTasks/listArchivedTasks/listPinnedTasks)顺序不稳,
/// 字面量 id 一加请求就全体错位)。
/// 按 channel.method 应答第一个未应答([skip] 中)的请求,返回其 wire id
/// (null = 无可应答)。抽屉初始化的并行 RPC 顺序不稳定,字面量 id 一加
/// 请求就全体错位,按名应答一劳永逸。
int? respondMethod(ChannelClient channels, List<Uint8List> sent, String method,
    {Object? result = const <String, dynamic>{},
    String? channel,
    Set<int>? skip}) {
  for (final body in sent) {
    final (header, _) = _decodeRequest(body);
    final h = header as List;
    if (h[0] == ChannelClient.reqPromise &&
        h[3] == method &&
        (channel == null || h[2] == channel) &&
        (skip == null || !skip.contains(h[1] as int))) {
      _respond(channels, h[1] as int, result);
      return h[1] as int;
    }
  }
  return null;
}

/// 按方法应答最新的一条请求(重拉产生的新 wire id 大于初次请求;
/// respondMethod 总命中首条已应答的旧请求,答不到重拉)。
int? respondLast(ChannelClient channels, List<Uint8List> sent, String method,
    {Object? result = const <String, dynamic>{}}) {
  for (final body in sent.reversed) {
    final (header, _) = _decodeRequest(body);
    final h = header as List;
    if (h[0] == ChannelClient.reqPromise && h[3] == method) {
      _respond(channels, h[1] as int, result);
      return h[1] as int;
    }
  }
  return null;
}

/// 按方法应答**全部**历史请求(含已应答的——信道对重复应答幂等忽略,
/// 天然免跟踪状态)。串行 await 的重拉分两拍:第一拍答在途请求,泵一拍
/// 让下一拍请求发出再答。比按 id 精确应答简单且不惧请求序错位。
int respondAllMethod(ChannelClient channels, List<Uint8List> sent,
    String method, Object? result) {
  var n = 0;
  for (final body in sent) {
    final (header, _) = _decodeRequest(body);
    final h = header as List;
    if (h[0] == ChannelClient.reqPromise && h[3] == method) {
      _respond(channels, h[1] as int, result);
      n++;
    }
  }
  return n;
}

/// 找监听器(resEventListen)的 wire id:onDynamicSessionsIndexFrame。
int listenerId(List<Uint8List> sent) {
  for (final body in sent) {
    final (header, _) = _decodeRequest(body);
    final h = header as List;
    if (h[0] == ChannelClient.reqEventListen &&
        h[3] == 'onDynamicSessionsIndexFrame') {
      return h[1] as int;
    }
  }
  return -1;
}

/// 应答所有未应答的 reqPromise(空结果),消化超时定时器。
Future<void> drainPending(
    ChannelClient channels, List<Uint8List> sent, WidgetTester tester) async {
  while (true) {
    final pending = <int>[];
    for (final body in sent) {
      final (header, _) = _decodeRequest(body);
      final h = header as List;
      if (h[0] == ChannelClient.reqPromise) pending.add(h[1] as int);
    }
    final before = sent.length;
    for (final id in pending) {
      _respond(channels, id, const <String, dynamic>{});
    }
    await tester.pump(const Duration(milliseconds: 100));
    if (sent.length == before) break;
  }
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
      'lastActivityAt':
          now.subtract(const Duration(days: 2)).millisecondsSinceEpoch,
      'createdAt': 1,
    },
  ];

  /// 按 wire id 找已发出的请求并解码。
  (Object?, Object?) requestById(int id) =>
      sent.map(_decodeRequest).firstWhere((r) => (r.$1 as List)[1] == id);

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
  void respondPinned(List<Object?> pinned) => _respond(channels, 1, pinned);

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

    // channel 初始化 + 泵到稳定:循环应答已知方法(握手→任务列表→
    // initialize→订阅),直至不再产生新请求;最后应答订阅 ack。
    channels.handleMessage(_inFrame(const [ChannelClient.resInitialize, 0]));
    // listTasks 按种子会话生成活跃任务(任务为主体:索引未收录的
    // 活跃任务也显示;不在任务列表的索引条目=孤儿被隐藏)。
    final activeTasks = [
      for (final e in entries)
        if ((e['archived'] as num? ?? 0) == 0)
          {'taskId': e['sessionId'], 'title': e['title']},
    ];
    final results = <String, Object?>{
      'helloConversationV4': <String, dynamic>{},
      'initializeConversationV4': <String, dynamic>{},
      'listPinnedTasks': pinned,
      'listTasks': activeTasks,
      'listArchivedTasks': const [],
    };
    for (var round = 0; round < 6; round++) {
      final before = sent.length;
      for (final entry in results.entries) {
        respondMethod(channels, sent, entry.key, result: entry.value);
      }
      await tester.pump();
      if (sent.length == before) break;
    }
    respondMethod(channels, sent, 'subscribeSessionsIndexV4', result: {
      'ack': {'subscriptionId': 'sub-test'},
    });
    await tester.pump();
    await tester.pump();
    // wire 帧{kind,topic,subscriptionId,frame};内层逻辑帧同样携带
    // subscriptionId(_acceptLogicalFrame 以它过滤)。
    channels.handleMessage(_inFrame([
      ChannelClient.resEventFire,
      listenerId(sent)
    ], {
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
    // 快照带来未知 id → 抽屉重拉任务归属(串行 await,两波应答)。
    respondLast(channels, sent, 'listTasks', result: activeTasks);
    await tester.pump();
    respondLast(channels, sent, 'listArchivedTasks', result: const []);
    await tester.pump();
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
    await drainPending(channels, sent, tester);
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
    final h = pinHeader as List;
    expect(h[2], 'zcode-task');
    expect(h[3], 'setTaskPinned');
    expect(pinArgs, [
      {'taskId': 's1', 'workspacePath': '/ws-t', 'pinned': true},
    ]);
    final skip = <int>{};
    skip.add(respondMethod(channels, sent, 'setTaskPinned',
            result: <String, dynamic>{}) ??
        -1);
    await tester.pump(); // 完成后退出多选 + id6 置顶集刷新
    respondPinned(const []); // 刷新应答:置顶集清空
    await tester.pump();
    expect(find.text('已选 1 项'), findsNothing); // 完成后退出多选

    // 归档:args 不带 pinned 字段。
    await selectRow(tester);
    await tester.tap(find.widgetWithText(OutlinedButton, '归档'));
    await tester.pump();
    final (archHeader, archArgs) = _decodeRequest(sent.last);
    expect((archHeader as List)[3], 'archiveTask');
    expect(archArgs, [
      {'taskId': 's1', 'workspacePath': '/ws-t'},
    ]);
    skip.add(respondMethod(channels, sent, 'archiveTask',
            result: <String, dynamic>{}) ??
        -1);
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
    expect((delHeader as List)[3], 'deleteTask');
    expect(delArgs, [
      {'taskId': 's1', 'workspacePath': '/ws-t'},
    ]);
    skip.add(respondMethod(channels, sent, 'deleteTask',
            result: <String, dynamic>{}) ??
        -1);
    await tester.pump(); // 完成后的置顶/任务列表刷新
    // 置顶集刷新(listPinnedTasks 二次)与 _loadTasks 的任务列表刷新
    // 全部应答掉,避免 30s 超时定时器悬挂到测试结束。
    while (true) {
      final p2 = respondMethod(channels, sent, 'listPinnedTasks',
          result: const [], skip: skip);
      final t1 = respondMethod(channels, sent, 'listTasks',
          result: const [], skip: skip);
      final t2 = respondMethod(channels, sent, 'listArchivedTasks',
          result: const [], skip: skip);
      if (p2 == null && t1 == null && t2 == null) break;
      for (final id in [p2, t1, t2]) {
        if (id != null) skip.add(id);
      }
      await tester.pump();
    }
    expect(find.text('已选 1 项'), findsNothing);

    await drainPending(channels, sent, tester);
    await tester.pumpWidget(const SizedBox.shrink());
    bridge.dispose();
    await tester.pump(const Duration(seconds: 40));
  });

  testWidgets('打开抽屉先播种离线缓存;实时数据到达即覆盖;状态点以实时为准', (tester) async {
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

    // channel 初始化应答(泵到稳定),但不推实时快照 —— 抽屉停留在
    // 「实时未到达」态。
    channels.handleMessage(_inFrame(const [ChannelClient.resInitialize, 0]));
    final initResults = <String, Object?>{
      'helloConversationV4': <String, dynamic>{},
      'initializeConversationV4': <String, dynamic>{},
      'listPinnedTasks': const [],
      'listTasks': [
        for (final e in entries)
          {'taskId': e['sessionId'], 'title': e['title']},
      ],
      'listArchivedTasks': const [],
    };
    for (var round = 0; round < 6; round++) {
      final before = sent.length;
      for (final entry in initResults.entries) {
        respondMethod(channels, sent, entry.key, result: entry.value);
      }
      await tester.pump();
      if (sent.length == before) break;
    }
    respondMethod(channels, sent, 'subscribeSessionsIndexV4', result: {
      'ack': {'subscriptionId': 'sub-test'},
    });
    await tester.pump();
    await tester.pump();

    // 种子显示:订阅未 ready、实时列表为空时,先展示缓存列表。
    expect(find.text('离线缓存会话'), findsOneWidget);
    // 状态点以实时为准:种子条目不渲染状态点(即便缓存 phase=running)。
    expect(statusDotFinder, findsNothing);

    // 实时快照到达 → 覆盖种子;running 条目恢复状态点。
    channels.handleMessage(_inFrame([
      ChannelClient.resEventFire,
      listenerId(sent)
    ], {
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

    await drainPending(channels, sent, tester);
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
    final results = <String, Object?>{
      'helloConversationV4': <String, dynamic>{},
      'initializeConversationV4': <String, dynamic>{},
      'listPinnedTasks': const [],
      'listTasks': [
        for (final e in entries)
          {'taskId': e['sessionId'], 'title': e['title']},
      ],
      'listArchivedTasks': const [],
    };
    for (var round = 0; round < 6; round++) {
      final before = sent.length;
      for (final entry in results.entries) {
        respondMethod(channels, sent, entry.key, result: entry.value);
      }
      await tester.pump();
      if (sent.length == before) break;
    }
    // subscribe ack 由调用方应答(respondMethod 'subscribeSessionsIndexV4')。
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
    respondMethod(channels, sent, 'subscribeSessionsIndexV4', result: {
      'ack': {'subscriptionId': 'sub-test'},
    });
    await tester.pump();
  }

  /// 推一张 sessions-index 快照(逐帧走真实 wire 路径)。
  void pushSnapshot(List<Object?> sessions) {
    channels.handleMessage(_inFrame([
      ChannelClient.resEventFire,
      listenerId(sent)
    ], {
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
    // 订阅请求应答错误 → _error 态(id 按方法名解析)。
    final subId = sent.map(_decodeRequest).map((r) => r.$1 as List).firstWhere(
        (h) =>
            h[0] == ChannelClient.reqPromise &&
            h[3] == 'subscribeSessionsIndexV4')[1] as int;
    channels.handleMessage(_inFrame(
        [ChannelClient.resPromiseError, subId], {'message': 'sub exploded'}));
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
    respondMethod(channels, sent, 'subscribeSessionsIndexV4', result: {
      'ack': {'subscriptionId': 'sub-test'},
    });
    await tester.pump();
    expect(find.text('离线数据 · 可能不是最新'), findsNothing);
    expect(find.text('离线缓存会话'), findsOneWidget);

    await drainPending(channels, sent, tester);
    await tester.pumpWidget(const SizedBox.shrink());
    bridge.dispose();
    await tester.pump(const Duration(seconds: 40));
  });

  testWidgets('订阅失败且无种子:仍显示错误页', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await pumpDrawerHandshake(tester, '/ws-t');
    final subId = sent.map(_decodeRequest).map((r) => r.$1 as List).firstWhere(
        (h) =>
            h[0] == ChannelClient.reqPromise &&
            h[3] == 'subscribeSessionsIndexV4')[1] as int;
    channels.handleMessage(_inFrame(
        [ChannelClient.resPromiseError, subId], {'message': 'sub exploded'}));
    await tester.pump();

    expect(find.textContaining('会话列表加载失败'), findsOneWidget);
    expect(find.text('离线数据 · 可能不是最新'), findsNothing);
    expect(find.text('重试'), findsOneWidget);

    await drainPending(channels, sent, tester);
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

    await drainPending(channels, sent, tester);
    await tester.pumpWidget(const SizedBox.shrink());
    bridge.dispose();
    await tester.pump(const Duration(seconds: 40));
  });

  testWidgets('当前会话从索引消失时回调宿主复位;未收录过的会话消失不误报', (tester) async {
    switchCounts.clear();
    vanishedCalls.clear();
    await pumpDrawerHandshake(tester, '/ws-t', currentSessionId: 's1');
    respondMethod(channels, sent, 'subscribeSessionsIndexV4', result: {
      'ack': {'subscriptionId': 'sub-test'},
    });
    await tester.pump();

    // 订阅刚就绪、当前会话已在列表(见过)。
    pushSnapshot(entries);
    await tester.pump();
    expect(vanishedCalls, isEmpty);
    expect(switchCounts, isEmpty);

    // s1 被删除/归档:增量推送把它从索引移除 → 触发归属重拉 → 复位回调。
    // 宿主语义:删除后任务不再出现在 listTasks(deleted 排除)。
    channels.handleMessage(_inFrame([
      ChannelClient.resEventFire,
      listenerId(sent)
    ], {
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
    respondLast(channels, sent, 'listTasks', result: [
      {'taskId': 's2', 'title': '重构 API'},
    ]);
    await tester.pump(); // listArchivedTasks 请求此拍才发出(串行 await)
    respondLast(channels, sent, 'listArchivedTasks', result: const []);
    await tester.pump(); // 归属落位(setState)后再渲染一帧
    await tester.pump();
    expect(find.text('修复登录'), findsNothing);
    expect(vanishedCalls.length, 1);

    await drainPending(channels, sent, tester);
    await tester.pumpWidget(const SizedBox.shrink());
    bridge.dispose();
    await tester.pump(const Duration(seconds: 40));
  });

  testWidgets('draft 采纳后列表尚未收录该会话:不算消失,不误报复位', (tester) async {
    switchCounts.clear();
    vanishedCalls.clear();
    await pumpDrawerHandshake(tester, '/ws-t', currentSessionId: 's-new');
    respondMethod(channels, sent, 'subscribeSessionsIndexV4', result: {
      'ack': {'subscriptionId': 'sub-test'},
    });
    await tester.pump();

    // 快照里没有 s-new(draft 采纳瞬间的常态):从未「见过」不触发回调。
    pushSnapshot([entries[1]]);
    await tester.pump();
    expect(find.text('重构 API'), findsOneWidget);
    expect(vanishedCalls, isEmpty);

    await drainPending(channels, sent, tester);
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

    await drainPending(channels, sent, tester);
    await tester.pumpWidget(const SizedBox.shrink());
    bridge.dispose();
    await tester.pump(const Duration(seconds: 40));
  });

  testWidgets('抽屉打开并行拉取 listPinnedTasks,命中会话渲染进置顶组', (tester) async {
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

    // 两档分组:置顶的 s2 在活跃组内排最前。
    expect(find.text('活跃'), findsOneWidget);
    expect(find.text('归档'), findsNothing);
    expect(find.text('重构 API'), findsOneWidget);

    double dy(Finder f) => tester.getTopLeft(f).dy;
    expect(dy(find.text('活跃')), lessThan(dy(find.text('重构 API'))));
    expect(dy(find.text('重构 API')), lessThan(dy(find.text('修复登录'))));

    await drainPending(channels, sent, tester);
    await tester.pumpWidget(const SizedBox.shrink());
    bridge.dispose();
    await tester.pump(const Duration(seconds: 40));
  });

  testWidgets('listPinnedTasks 失败容错为空集:列表照常活跃组渲染', (tester) async {
    await pumpDrawerHandshake(tester, '/ws-t');
    channels.handleMessage(_inFrame(
        [ChannelClient.resPromiseError, 1], {'message': 'pinned exploded'}));
    respondMethod(channels, sent, 'subscribeSessionsIndexV4', result: {
      'ack': {'subscriptionId': 'sub-test'},
    });
    await tester.pump();
    pushSnapshot(entries);
    await tester.pump();

    expect(find.text('活跃'), findsOneWidget);
    expect(find.text('修复登录'), findsOneWidget);
    expect(find.text('重构 API'), findsOneWidget);

    await drainPending(channels, sent, tester);
    await tester.pumpWidget(const SizedBox.shrink());
    bridge.dispose();
    await tester.pump(const Duration(seconds: 40));
  });

  testWidgets('延迟条目操作在 source 切换后不发送旧 RPC', (tester) async {
    await pumpDrawer(tester);
    final oldBridge = bridge;
    final oldChannels = channels;
    final oldRequestStart = sent.length;

    await tester.longPress(find.text('修复登录'));
    await tester.pump();
    expect(find.byType(BottomSheet), findsOneWidget);
    final archiveTile =
        tester.widget<ListTile>(find.widgetWithText(ListTile, '归档'));
    final oldArchiveAction = archiveTile.onTap!;

    final nextSent = <Uint8List>[];
    final nextChannels = ChannelClient(sendBody: nextSent.add);
    final nextBridge = BridgeSession.detached(
      {'workspaceKey': '/ws-new'},
      channels: nextChannels,
    );
    channels = nextChannels;
    bridge = nextBridge;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: buildDrawer('/ws-new')),
    ));
    await tester.pump();

    // 旧 action sheet 的回调保留旧 source,切换后执行也不能发送。
    oldArchiveAction();
    await tester.pump();

    bool hasMethod(Iterable<Uint8List> bodies, String method) =>
        bodies.any((body) {
          final (header, _) = _decodeRequest(body);
          final h = header as List;
          return h[0] == ChannelClient.reqPromise && h[3] == method;
        });
    expect(hasMethod(sent.skip(oldRequestStart), 'archiveTask'), isFalse);
    expect(hasMethod(nextSent, 'archiveTask'), isFalse);

    await drainPending(nextChannels, nextSent, tester);
    await drainPending(oldChannels, sent, tester);
    await tester.pumpWidget(const SizedBox.shrink());
    oldBridge.dispose();
    nextBridge.dispose();
    await tester.pump(const Duration(seconds: 80));
  });

  testWidgets('置顶操作完成后重拉置顶集,条目随即进置顶组', (tester) async {
    await pumpDrawer(tester); // 初始置顶集为空
    expect(find.text('活跃'), findsOneWidget);

    await selectRow(tester); // 选中 s1
    await tester.tap(find.widgetWithText(OutlinedButton, '置顶'));
    await tester.pump();
    final (pinHeader, _) = _decodeRequest(sent.last);
    expect((pinHeader as List)[3], 'setTaskPinned');
    final skip = <int>{};
    skip.add(respondMethod(channels, sent, 'setTaskPinned',
            result: <String, dynamic>{}) ??
        -1);
    await tester.pump(); // 退出多选 + 置顶集/归档集刷新请求发出

    // 刷新是紧随操作的新一次 listPinnedTasks:取该方法最新的 wire id
    // (初次的已被握手泵应答),应答 s1 已置顶。
    var refreshId = -1;
    for (final body in sent) {
      final (header, _) = _decodeRequest(body);
      final h = header as List;
      if (h[0] == ChannelClient.reqPromise && h[3] == 'listPinnedTasks') {
        refreshId = h[1] as int;
      }
    }
    expect(refreshId, greaterThan(0));
    final (refreshHeader, refreshArgs) = requestById(refreshId);
    expect((refreshHeader as List)[3], 'listPinnedTasks');
    expect(refreshArgs, [
      {'workspacePath': '/ws-t'},
    ]);
    _respond(channels, refreshId, [
      {'taskId': 's1'},
    ]);
    // 归属刷新同轮发出(串行 await,两波应答;活跃集仍含 s1/s2,
    // 空集会把索引条目全变成孤儿隐藏)。
    respondLast(channels, sent, 'listTasks', result: [
      {'taskId': 's1', 'title': '修复登录'},
      {'taskId': 's2', 'title': '重构 API'},
    ]);
    await tester.pump();
    respondLast(channels, sent, 'listArchivedTasks', result: const []);
    await tester.pump();

    expect(find.text('已选 1 项'), findsNothing); // 已退出多选
    expect(find.text('活跃'), findsOneWidget);
    double dy(Finder f) => tester.getTopLeft(f).dy;
    expect(dy(find.text('活跃')), lessThan(dy(find.text('修复登录'))));
    expect(find.text('归档'), findsNothing);

    await drainPending(channels, sent, tester);
    await drainPending(channels, sent, tester);
    await tester.pumpWidget(const SizedBox.shrink());
    bridge.dispose();
    await tester.pump(const Duration(seconds: 40));
  });
}
