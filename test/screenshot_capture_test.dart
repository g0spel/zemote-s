// 截图生成器(README 用):泵真实 widget + 真 wire 帧 + 打包字体,
// 输出 docs 级 PNG。环境门控,普通 `flutter test` 跳过:
//   ZFLOW_SHOTS=1 flutter test --update-goldens test/screenshot_capture_test.dart
// 产物先落 test/goldens/,再拷贝到 docs/screenshots/。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zflow/protocol/channel_client.dart';
import 'package:zflow/protocol/conversation.dart';
import 'package:zflow/protocol/ipc_codec.dart';
import 'package:zflow/protocol/zflow_client.dart';
import 'package:zflow/state/account_store.dart';
import 'package:zflow/state/app_session.dart';
import 'package:zflow/ui/automation_page.dart';
import 'package:zflow/ui/chat_page.dart';
import 'package:zflow/ui/session_drawer.dart';
import 'package:zflow/ui/settings_page.dart';
import 'package:zflow/ui/theme.dart';

import 'fake_credential_storage.dart';

final _enabled = Platform.environment['ZFLOW_SHOTS'] == '1';

Uint8List _frame(List<Object?> header, [Object? data]) {
  final w = ValueWriter();
  encodeValue(w, header);
  if (data != null) encodeValue(w, data);
  return w.toBytes();
}

/// wire 桩:按方法名暂存应答,记录事件监听器;drain 应答全部在途请求。
class _Wire {
  final sent = <Uint8List>[];
  final listeners = <int, String>{};
  final pending = <int, String>{};
  final Map<String, Object?> results;
  late final ChannelClient channels;

  _Wire(this.results) {
    channels = ChannelClient(sendBody: (body) {
      final r = ValueReader(body);
      final h = decodeValue(r) as List;
      if (h[0] == ChannelClient.reqPromise) {
        pending[h[1] as int] = h[3] as String;
      } else if (h[0] == ChannelClient.reqEventListen) {
        listeners[h[1] as int] = h[3] as String;
      }
    });
  }

  int? listenerId(String event) {
    for (final e in listeners.entries) {
      if (e.value == event) return e.key;
    }
    return null;
  }

  /// 应答当前全部在途请求(每个 id 至多一次);未知方法回空对象。
  void drain() {
    for (final id in pending.keys.toList()) {
      final method = pending.remove(id)!;
      channels.handleMessage(_frame(
          [ChannelClient.resPromiseSuccess, id],
          results[method] ?? const <String, dynamic>{}));
    }
  }

  void fire(int id, Object event) =>
      channels.handleMessage(_frame([ChannelClient.resEventFire, id], event));
}

Future<void> _settle(WidgetTester tester, _Wire wire) async {
  for (var round = 0; round < 12; round++) {
    final before = wire.sent.length;
    wire.drain();
    await tester.pump(const Duration(milliseconds: 100));
    if (wire.sent.length == before && wire.pending.isEmpty) break;
  }
}

Future<void> _loadFonts() async {
  Future<ByteData> load(String path) => rootBundle.load(path);
  final ui = FontLoader('Sarasa UI SC')
    ..addFont(load('assets/fonts/Zflow-UI-Regular.ttf'))
    ..addFont(load('assets/fonts/Zflow-UI-Bold.ttf'));
  await ui.load();
  final term = FontLoader('Sarasa Term SC')
    ..addFont(load('assets/fonts/Zflow-Term-Regular.ttf'));
  await term.load();
  // 工具输出/代码块用 fontFamily: 'monospace',测试环境没有系统后备,
  // 把 Term 字体注册到 'monospace' 族,避免豆腐块。
  final mono = FontLoader('monospace')
    ..addFont(load('assets/fonts/Zflow-Term-Regular.ttf'));
  await mono.load();
  // 图标字体:golden 渲染默认不加载 MaterialIcons,不加载就是豆腐块。
  final icons = FontLoader('MaterialIcons')
    ..addFont(load('fonts/MaterialIcons-Regular.otf'));
  await icons.load();
}

Future<void> _phoneSurface(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);
}

Future<void> _shot(WidgetTester tester, String name) async {
  await expectLater(
      find.byType(MaterialApp), matchesGoldenFile('goldens/$name.png'));
}

/// 截图后清理:拆树(取消视图层计时器)→ dispose bridge → 泵过
/// 传输层周期计时器,避免「Timer is still pending」不变量断言。
Future<void> _teardown(
    WidgetTester tester, Future<void> Function() disposeBridge) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await disposeBridge();
  await tester.pump(const Duration(minutes: 1));
}

final _now = DateTime.now();
int _tsAgo(Duration d) => _now.subtract(d).millisecondsSinceEpoch;

final _chatRows = <Map<String, dynamic>>[
  {
    'rowId': 1,
    'kind': 'userInput',
    'text': '帮我排查移动端切会话慢的问题',
    'state': 'completed',
    'ts': _tsAgo(const Duration(seconds: 4)),
  },
  {
    'rowId': 2,
    'kind': 'reasoning',
    'text': '切会话慢的根因在订阅生命周期:旧实现每次进入会话都要完整重订阅'
        '(握手 + initialize + 快照),弱网下首屏要等 2~3 秒。'
        '如果把最近几个订阅保持在连接上,切回时就只需重挂监听器……'
        '用 LRU 驻留池,容量取 8 应该够覆盖来回横跳的场景。',
    'state': 'completedSuccess',
  },
  {
    'rowId': 3,
    'kind': 'toolCall',
    'toolName': 'bash',
    'status': 'success',
    'inputText': "grep -rn '_parkedSubscriptions' lib/protocol | head -5",
    'output': {
      'text': 'lib/protocol/conversation.dart:47:  final _parkedSubscriptions =\n'
          'lib/protocol/conversation.dart:312: parkSubscription(sub)\n'
          'lib/protocol/conversation.dart:358: takeParkedSubscription(key)'
    },
  },
  {
    'rowId': 4,
    'kind': 'assistantText',
    'text': '定位到了:旧实现每次切会话都要完整重订阅,快照越大首屏越慢。'
        '方案是引入 LRU 驻留池(容量 8):离开会话时把订阅 park 在传输层'
        '(继续收帧、不断开),切回时身份校验后直接复用热订阅,实现秒开。',
    'state': 'completed',
  },
  {
    'rowId': 5,
    'kind': 'turnHeader',
    'state': 'completedSuccess',
    'fileChanges': {'files': 2, 'additions': 36, 'deletions': 4},
  },
  {
    'rowId': 6,
    'kind': 'assistantText',
    'text': '正在补「s1→s2→s1 仅两次订阅」的端到端测试,随后更新设置页说明…',
    'state': 'streaming',
  },
];

Future<BridgeSession> _pumpChat(WidgetTester tester, _Wire wire,
    {required GlobalKey<ScaffoldState> scaffoldKey}) async {
  final bridge = BridgeSession.detached({'workspaceKey': '/ws'},
      channels: wire.channels);
  await tester.pumpWidget(MaterialApp(
      debugShowCheckedModeBanner: false,
    theme: buildDarkTheme(),
    home: Scaffold(
      key: scaffoldKey,
      drawer: Drawer(
          width: 304,
          child: SessionDrawer(
            bridge: bridge,
            scope: const {'workspacePath': '/ws'},
            workspaceName: '主力机',
            workspacePath: '/ws',
            currentSessionId: 's1',
            onPick: (_) {},
            onOpenSideChat: () {},
            onSwitchWorkspace: (_) {},
            onCurrentSessionVanished: () {},
            onManageDevices: () {},
            deviceCount: 1,
            deviceOnline: true,
          )),
      body: ChatPage(
        session: bridge,
        scope: const {'workspacePath': '/ws'},
        workspaceKey: '/ws',
        sessionId: null,
        title: '排查移动端切会话慢',
        embedded: true,
        onOpenDrawer: () => scaffoldKey.currentState?.openDrawer(),
      ),
    ),
  ));
  wire.channels.handleMessage(_frame(const [ChannelClient.resInitialize, 0]));
  await _settle(tester, wire);

  // 发送流(与回归测试同款):发送 → createSession/subscribe 握手全部
  // 就绪,会话行监听器注册后再注入快照。
  await tester.enterText(find.byType(TextField), '帮我排查移动端切会话慢的问题');
  await tester.tap(find.byIcon(Icons.arrow_upward));
  await _settle(tester, wire);

  final convId = wire.listenerId('onDynamicConversationFrame');
  if (convId != null) {
    wire.fire(convId, {
      'kind': 'complete',
      'topic': 'conversation/s1',
      'subscriptionId': 'conv-sub',
      'frame': {
        'subscriptionId': 'conv-sub',
        'toSeq': 6,
        'payload': {
          'kind': 'snapshot',
          'snapshot': {
            'revision': 1,
            'logEpoch': 'e1',
            'control': {'phase': 'running'},
            'usage': {
              'contextWindow': {
                'usedTokens': 51200,
                'maxTokens': 200000,
              },
              'cumulative': {
                'inputTokens': 183400,
                'outputTokens': 26400,
                'cacheReadTokens': 821000,
                'cacheWriteTokens': 41200,
              },
            },
            'rows': {
              'totalCount': 6,
              'firstRowId': 1,
              'window': _chatRows,
            },
          },
        },
      },
    });
    // 会话索引快照:抽屉会话列表(当前会话 + 历史)。
    final idxId = wire.listenerId('onDynamicSessionsIndexFrame');
    if (idxId != null) {
      wire.fire(idxId, {
        'kind': 'complete',
        'topic': 'sessions-index//ws',
        'subscriptionId': 'sub-idx',
        'frame': {
          'subscriptionId': 'sub-idx',
          'toSeq': 1,
          'payload': {
            'kind': 'snapshot',
            'snapshot': {
              'sessions': [
                {
                  'sessionId': 's1',
                  'title': '排查移动端切会话慢',
                  'phase': 'running',
                  'lastActivityAt': _tsAgo(const Duration(minutes: 1)),
                },
                {
                  'sessionId': 's2',
                  'title': '协议重连测试',
                  'phase': 'idle',
                  'lastActivityAt': _tsAgo(const Duration(hours: 5)),
                },
                {
                  'sessionId': 's3',
                  'title': '自动化页 UI 重构',
                  'phase': 'idle',
                  'lastActivityAt': _tsAgo(const Duration(days: 2)),
                },
              ],
            },
          },
        },
      });
    }
  }
  await tester.pump(const Duration(milliseconds: 150));
  await tester.pump(const Duration(milliseconds: 150));
  return bridge;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    if (!_enabled) return;
    await _loadFonts();
    // 设置页电池白名单 tile 会查询平台通道,mock 掉避免 MissingPlugin。
    const channel = MethodChannel('zflow/notifications');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'isIgnoringBatteryOptimizations') return true;
      return null;
    });
  });

  testWidgets('chat-main:对话页(运行中:两行计时胶囊 / 思考 / 工具 / 文件卡)',
      (tester) async {
    if (!_enabled) return;
    await _phoneSurface(tester);
    final wire = _Wire({
      'helloConversationV4': <String, dynamic>{},
      'initializeConversationV4': <String, dynamic>{},
      'prepareWorkspace': <String, dynamic>{},
      'list': const <dynamic>[],
      'createSession': {
        'status': 'accepted',
        'result': {'sessionId': 's1'},
      },
      'sendConversationCommandV4': {
        'status': 'accepted',
        'result': {'sessionId': 's1'},
      },
      'subscribeConversationV4': {
        'ack': {'subscriptionId': 'conv-sub'}
      },
      'subscribeSessionsIndexV4': {
        'ack': {'subscriptionId': 'sub-idx'}
      },
    });
    final scaffoldKey = GlobalKey<ScaffoldState>();
    final bridge = await _pumpChat(tester, wire, scaffoldKey: scaffoldKey);
    await _shot(tester, 'chat-main');
    await _teardown(tester, () async => bridge.dispose());
  });

  testWidgets('chat-drawer:会话抽屉(叠在对话页上)', (tester) async {
    if (!_enabled) return;
    await _phoneSurface(tester);
    final wire = _Wire({
      'helloConversationV4': <String, dynamic>{},
      'initializeConversationV4': <String, dynamic>{},
      'prepareWorkspace': <String, dynamic>{},
      'list': const <dynamic>[],
      'createSession': {
        'status': 'accepted',
        'result': {'sessionId': 's1'},
      },
      'sendConversationCommandV4': {
        'status': 'accepted',
        'result': {'sessionId': 's1'},
      },
      'listPinnedTasks': <dynamic>[
        {'taskId': 's2'},
      ],
      'listTasks': <dynamic>[
        {'taskId': 's1', 'title': '排查移动端切会话慢'},
        {'taskId': 's2', 'title': '协议重连测试'},
        {'taskId': 's3', 'title': '自动化页 UI 重构'},
      ],
      'listArchivedTasks': const <dynamic>[],
      'subscribeConversationV4': {
        'ack': {'subscriptionId': 'conv-sub'}
      },
      'subscribeSessionsIndexV4': {
        'ack': {'subscriptionId': 'sub-idx'}
      },
    });
    final scaffoldKey = GlobalKey<ScaffoldState>();
    final bridge = await _pumpChat(tester, wire, scaffoldKey: scaffoldKey);
    scaffoldKey.currentState?.openDrawer();
    await tester.pump(const Duration(milliseconds: 400));
    // 抽屉打开时才订阅会话索引:就绪后补发快照 + 再应答任务归属拉取。
    await _settle(tester, wire);
    final idxId2 = wire.listenerId('onDynamicSessionsIndexFrame');
    if (idxId2 != null) {
      wire.fire(idxId2, {
        'kind': 'complete',
        'topic': 'sessions-index//ws',
        'subscriptionId': 'sub-idx',
        'frame': {
          'subscriptionId': 'sub-idx',
          'toSeq': 1,
          'payload': {
            'kind': 'snapshot',
            'snapshot': {
              'sessions': [
                {
                  'sessionId': 's1',
                  'title': '排查移动端切会话慢',
                  'phase': 'running',
                  'lastActivityAt': _tsAgo(const Duration(minutes: 1)),
                },
                {
                  'sessionId': 's2',
                  'title': '协议重连测试',
                  'phase': 'idle',
                  'lastActivityAt': _tsAgo(const Duration(hours: 5)),
                },
                {
                  'sessionId': 's3',
                  'title': '自动化页 UI 重构',
                  'phase': 'idle',
                  'lastActivityAt': _tsAgo(const Duration(days: 2)),
                },
              ],
            },
          },
        },
      });
    }
    await _settle(tester, wire);
    await tester.pump(const Duration(milliseconds: 200));
    await _shot(tester, 'chat-drawer');
    await _teardown(tester, () async => bridge.dispose());
  });

  testWidgets('insights:洞察 sheet(目标面板)', (tester) async {
    if (!_enabled) return;
    await _phoneSurface(tester);
    final wire = _Wire({
      'helloConversationV4': <String, dynamic>{},
      'initializeConversationV4': <String, dynamic>{},
    });
    final bridge =
        BridgeSession.detached({'workspaceKey': '/ws'}, channels: wire.channels);
    final transport = ConversationTransport(
      session: bridge,
      scope: const {'workspacePath': '/ws'},
    );
    final state = ConversationState()
      ..snapshot = {
        'goal': {
          'objective': '周末前把移动端协议层与桌面端对齐',
          'status': 'running',
        },
        'plan': {
          'items': [
            {'content': '定位重订阅开销', 'status': 'completed'},
            {'content': '驻留池设计与落地', 'status': 'in_progress'},
            {'content': '真机回归与发版', 'status': 'pending'},
          ],
        },
      }
      ..rows = [
        {
          'rowId': 1,
          'kind': 'toolCall',
          'toolName': 'TodoWrite',
          'input': {
            'todos': [
              {'content': '跑全量门禁', 'status': 'in_progress'},
            ],
          },
        },
      ];
    await tester.pumpWidget(MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildDarkTheme(),
      home: Scaffold(
        backgroundColor: const Color(0xFF1B1917),
        body: DraggableScrollableSheet(
          initialChildSize: 0.62,
          builder: (context, scrollController) => InsightsSheet(
            state: state,
            transport: transport,
            sessionId: 's1',
            scrollController: scrollController,
          ),
        ),
      ),
    ));
    await _settle(tester, wire);
    await tester.pump(const Duration(milliseconds: 400));
    await _shot(tester, 'insights');
    await _teardown(tester, () async => bridge.dispose());
  });

  testWidgets('automation:自动化页(统计卡 + 任务卡 + 闲时队列)', (tester) async {
    if (!_enabled) return;
    await _phoneSurface(tester);
    final wire = _Wire({
      'listAutomations': <dynamic>[
        {
          'automationId': 'a1',
          'title': '每周回顾',
          'lifecycleStatus': 'active',
          'cronExpr': '0 9 * * 1',
          'enabled': true,
        },
        {
          'automationId': 'a2',
          'title': '夜间风险扫描',
          'lifecycleStatus': 'active',
          'cronExpr': '0 22 * * *',
          'enabled': true,
        },
      ],
      'listRuns': const <dynamic>[],
      'list': <dynamic>[
        {
          'offPeakTaskId': 'q1',
          'title': '闲时整理会议纪要',
          'status': 'queued',
        },
      ],
    });
    final bridge =
        BridgeSession.detached({'workspaceKey': '/ws'}, channels: wire.channels);
    await tester.pumpWidget(MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildDarkTheme(),
      home: Scaffold(
        body: AutomationPage(
          bridge: bridge,
          workspace: const {'workspacePath': '/ws', 'label': '主力机'},
          onOpenTask: (_, _) {},
        ),
      ),
    ));
    wire.channels.handleMessage(_frame(const [ChannelClient.resInitialize, 0]));
    await _settle(tester, wire);
    await tester.pump(const Duration(milliseconds: 200));
    await _shot(tester, 'automation');
    await _teardown(tester, () async => bridge.dispose());
  });

  testWidgets('settings:设置页(设备 / 后台与通知 / 诊断)', (tester) async {
    if (!_enabled) return;
    await _phoneSurface(tester);
    final store = AccountStore(storage: FakeCredentialStorage());
    await tester.pumpWidget(MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildDarkTheme(),
      home: SettingsPage(
        store: store,
        session: AppSession(),
        onDisconnect: () {},
      ),
    ));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    await _shot(tester, 'settings');
  });
}
