import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zflow/protocol/channel_client.dart';
import 'package:zflow/protocol/ipc_codec.dart';
import 'package:zflow/protocol/zflow_client.dart';
import 'package:zflow/ui/automation_page.dart';

/// 真实协议驱动的 automation 页测试。裸 AutomationPage 在全新 detached
/// bridge 上取号是确定性的(FIFO):id0 listAutomations、id1 listRuns
/// (每条自动化一个)、随后 off-peak-task list。
Uint8List _frame(List<Object?> header, [Object? data]) {
  final w = ValueWriter();
  encodeValue(w, header);
  if (data != null) encodeValue(w, data);
  return w.toBytes();
}

void _respond(BridgeSession bridge, int id, Object? result) => bridge.channels
    .handleMessage(_frame([ChannelClient.resPromiseSuccess, id], result));

/// 挂 AutomationPage 并完成 channel 初始化(不应答业务请求)。
Future<BridgeSession> pumpPage(WidgetTester tester) async {
  final channels = ChannelClient(sendBody: (_) {});
  final bridge = BridgeSession.detached(
    {'workspaceKey': '/ws'},
    channels: channels,
  );
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: AutomationPage(
        bridge: bridge,
        workspace: const {'workspacePath': '/ws', 'label': 'WS'},
        onOpenTask: (_, __) {},
      ),
    ),
  ));
  bridge.channels.handleMessage(_frame(const [ChannelClient.resInitialize, 0]));
  await tester.pump();
  return bridge;
}

void main() {
  testWidgets('无自动化但闲时队列非空:空态提示 + 队列同屏,无 0/0/0 统计卡',
      (tester) async {
    final bridge = await pumpPage(tester);
    _respond(bridge, 0, <dynamic>[]); // listAutomations → 空
    await tester.pump();
    _respond(bridge, 1, <dynamic>[
      {'offPeakTaskId': 'q1', 'title': '闲时任务一', 'status': 'queued'},
    ]); // off-peak-task list → 1 条
    await tester.pump();

    expect(find.text('暂无自动化，点右上角 + 新建'), findsOneWidget);
    expect(find.text('闲时任务一'), findsOneWidget); // 队列照常展示
    expect(find.text('全部'), findsNothing); // 不再渲染 0/0/0 统计卡
    expect(find.text('活跃'), findsNothing);
    expect(find.text('失败'), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    bridge.dispose();
    await tester.pump(const Duration(minutes: 1));
  });

  testWidgets('有自动化:统计卡行照常渲染', (tester) async {
    final bridge = await pumpPage(tester);
    _respond(bridge, 0, <dynamic>[
      {
        'automationId': 'a1',
        'title': '每周回顾',
        'lifecycleStatus': 'active',
        'cronExpr': '0 9 * * 1',
        'enabled': true,
      },
    ]);
    await tester.pump();
    _respond(bridge, 1, <dynamic>[]); // listRuns(a1)
    await tester.pump();
    _respond(bridge, 2, <dynamic>[]); // off-peak-task list
    await tester.pump();

    expect(find.text('全部'), findsOneWidget);
    expect(find.text('活跃'), findsOneWidget);
    expect(find.text('失败'), findsOneWidget);
    expect(find.text('每周回顾'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    bridge.dispose();
    await tester.pump(const Duration(minutes: 1));
  });
}
