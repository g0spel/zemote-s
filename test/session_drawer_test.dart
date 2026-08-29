import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:zemote/protocol/channel_client.dart';
import 'package:zemote/protocol/ipc_codec.dart';
import 'package:zemote/protocol/zemote_client.dart';
import 'package:zemote/state/session_list_cache.dart';
import 'package:zemote/ui/session_drawer.dart';

/// 真实协议驱动的抽屉测试。裸 SessionDrawer 在全新 detached bridge 上的
/// channel 取号是确定性的(FIFO):id0 hello、id1 initialize、id2 索引帧
/// 监听器(同步取号)、id3 subscribeSessionsIndexV4;之后的管理操作依次
/// id4 setTaskPinned / id5 archiveTask / id6 deleteTask。
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

  Future<void> pumpDrawer(WidgetTester tester) async {
    channels = ChannelClient(sendBody: (body) => sent.add(body));
    bridge = BridgeSession.detached(
      {'workspaceKey': '/ws-t'},
      channels: channels,
    );
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SessionDrawer(
          bridge: bridge,
          scope: const {'workspacePath': '/ws-t'},
          workspaceName: 'WS',
          workspacePath: '/ws-t',
          currentSessionId: null,
          onPick: picked.add,
          onSwitchWorkspace: () {},
          onManageDevices: () {},
          deviceCount: 1,
          deviceOnline: true,
        ),
      ),
    ));

    // channel 初始化 + 按确定性顺序应答,随后推索引快照让列表渲染。
    channels.handleMessage(_inFrame(const [ChannelClient.resInitialize, 0]));
    await tester.pump(); // id0 hello
    _respond(channels, 0, <String, dynamic>{});
    await tester.pump(); // id1 initialize
    _respond(channels, 1, <String, dynamic>{});
    await tester.pump(); // id2 帧监听器 + id3 subscribeIndex
    _respond(channels, 3, {
      'ack': {'subscriptionId': 'sub-test'},
    });
    await tester.pump();
    // wire 帧{kind,topic,subscriptionId,frame};内层逻辑帧同样携带
    // subscriptionId(_acceptLogicalFrame 以它过滤)。
    channels.handleMessage(_inFrame([ChannelClient.resEventFire, 2], {
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
    expect(pinHeader, [ChannelClient.reqPromise, 4, 'zcode-task', 'setTaskPinned']);
    expect(pinArgs, [
      {'taskId': 's1', 'workspacePath': '/ws-t', 'pinned': true},
    ]);
    _respond(channels, 4, <String, dynamic>{});
    await tester.pump();
    expect(find.text('已选 1 项'), findsNothing); // 完成后退出多选

    // 归档:args 不带 pinned 字段。
    await selectRow(tester);
    await tester.tap(find.widgetWithText(OutlinedButton, '归档'));
    await tester.pump();
    final (archHeader, archArgs) = _decodeRequest(sent.last);
    expect(archHeader, [ChannelClient.reqPromise, 5, 'zcode-task', 'archiveTask']);
    expect(archArgs, [
      {'taskId': 's1', 'workspacePath': '/ws-t'},
    ]);
    _respond(channels, 5, <String, dynamic>{});
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
    expect(delHeader, [ChannelClient.reqPromise, 6, 'zcode-task', 'deleteTask']);
    expect(delArgs, [
      {'taskId': 's1', 'workspacePath': '/ws-t'},
    ]);
    _respond(channels, 6, <String, dynamic>{});
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
      home: Scaffold(
        body: SessionDrawer(
          bridge: bridge,
          scope: const {'workspacePath': '/ws-t'},
          workspaceName: 'WS',
          workspacePath: '/ws-t',
          currentSessionId: null,
          onPick: picked.add,
          onSwitchWorkspace: () {},
          onManageDevices: () {},
          deviceCount: 1,
          deviceOnline: true,
        ),
      ),
    ));

    // channel 初始化应答,但不推实时快照 —— 抽屉停留在「实时未到达」态。
    channels.handleMessage(_inFrame(const [ChannelClient.resInitialize, 0]));
    await tester.pump();
    _respond(channels, 0, <String, dynamic>{});
    await tester.pump();
    _respond(channels, 1, <String, dynamic>{});
    await tester.pump();
    _respond(channels, 3, {
      'ack': {'subscriptionId': 'sub-test'},
    });
    await tester.pump();

    // 种子显示:订阅未 ready、实时列表为空时,先展示缓存列表。
    expect(find.text('离线缓存会话'), findsOneWidget);
    // 状态点以实时为准:种子条目不渲染状态点(即便缓存 phase=running)。
    expect(statusDotFinder, findsNothing);

    // 实时快照到达 → 覆盖种子;running 条目恢复状态点。
    channels.handleMessage(_inFrame([ChannelClient.resEventFire, 2], {
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

  /// 以 [workspacePath] 为 scope 挂抽屉并完成 channel 握手,但不推实时
  /// 快照 —— 抽屉停留在「实时未到达」态(种子可见)。
  Future<void> pumpDrawerWithoutSnapshot(
      WidgetTester tester, String workspacePath) async {
    channels = ChannelClient(sendBody: (body) => sent.add(body));
    bridge = BridgeSession.detached(
      {'workspaceKey': workspacePath},
      channels: channels,
    );
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SessionDrawer(
          bridge: bridge,
          scope: {'workspacePath': workspacePath},
          workspaceName: workspacePath,
          workspacePath: workspacePath,
          currentSessionId: null,
          onPick: picked.add,
          onSwitchWorkspace: () {},
          onManageDevices: () {},
          deviceCount: 1,
          deviceOnline: true,
        ),
      ),
    ));
    channels.handleMessage(_inFrame(const [ChannelClient.resInitialize, 0]));
    await tester.pump();
    _respond(channels, 0, <String, dynamic>{});
    await tester.pump();
    _respond(channels, 1, <String, dynamic>{});
    await tester.pump();
    _respond(channels, 3, {
      'ack': {'subscriptionId': 'sub-test'},
    });
    await tester.pump();
  }

  testWidgets('切工作区后旧 scope 的离线种子消失', (tester) async {
    // 缓存只喂 /ws-t;/ws-2 无缓存。
    SharedPreferences.setMockInitialValues({
      const SessionListCache().keyFor(const {'workspacePath': '/ws-t'}):
          jsonEncode([
            {
              'sessionId': 'cached-1',
              'title': '离线缓存会话',
              'phase': 'running',
              'lastActivityAt': now.millisecondsSinceEpoch,
              'createdAt': 1,
            },
          ]),
    });

    await pumpDrawerWithoutSnapshot(tester, '/ws-t');
    expect(find.text('离线缓存会话'), findsOneWidget); // 旧 scope 种子在展示

    // 宿主切工作区:同一 bridge,scope 换成 /ws-2(didUpdateWidget → 重挂订阅)。
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SessionDrawer(
          bridge: bridge,
          scope: const {'workspacePath': '/ws-2'},
          workspaceName: 'WS-2',
          workspacePath: '/ws-2',
          currentSessionId: null,
          onPick: picked.add,
          onSwitchWorkspace: () {},
          onManageDevices: () {},
          deviceCount: 1,
          deviceOnline: true,
        ),
      ),
    ));
    await tester.pump();

    // 旧 scope 的种子不得在新工作区名下展示(数据正确性:可点即错会话)。
    expect(find.text('离线缓存会话'), findsNothing);
    expect(find.text('WS-2'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    bridge.dispose();
    await tester.pump(const Duration(seconds: 40));
  });
}
