import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zflow/protocol/connection_params.dart';
import 'package:zflow/protocol/zflow_client.dart';
import 'package:zflow/ui/chat_page.dart';
import 'package:zflow/state/account_store.dart';
import 'package:zflow/state/app_session.dart';
import 'package:zflow/ui/session_drawer.dart';
import 'package:zflow/ui/device_management_page.dart';
import 'package:zflow/ui/root_shell.dart';
import 'package:zflow/ui/settings_page.dart';
import 'package:zflow/ui/theme.dart';
import 'package:zflow/ui/ui_settings.dart';

import 'fake_credential_storage.dart';

const _deviceUrl =
    'https://zcode.z.ai/remote/v4?sid=s&hash=h&t=1&name=Test';

String _url(String sid, String name) =>
    'https://zcode.z.ai/remote/v4?sid=$sid&hash=h&t=1&name=$name';

/// Fake [ZflowClient]: no sockets. [gate] (when uncompleted) holds
/// connect() open so tests can stage in-flight chains; bootstrap/openBridge
/// answer from [workspaces] with detached bridge sessions.
class _FakeClient extends ZflowClient {
  final Completer<void> connectGate;
  final List<Map<String, dynamic>> workspaces;

  _FakeClient(
    super.params, {
    Completer<void>? gate,
    this.workspaces = const [],
  }) : connectGate = gate ?? (Completer<void>()..complete());

  @override
  Future<void> connect() => connectGate.future;

  @override
  Future<void> waitPaired({Duration timeout = const Duration(seconds: 60)}) =>
      Future.value();

  @override
  Future<Map<String, dynamic>> bootstrap() async =>
      {'workspaces': workspaces};

  @override
  Future<BridgeSession> openBridge(
    String workspaceKey, {
    String? taskId,
    Duration timeout = const Duration(seconds: 30),
  }) async =>
      BridgeSession.detached({'workspaceKey': workspaceKey});

  @override
  void pokeRelay() {}

  @override
  Future<void> dispose() async {}
}

/// Pumps a [RootShell] inside the production provider stack with an
/// in-memory [AccountStore] seeded via [urls]. Returns the store so tests
/// can reach the seeded accounts. [clientFactory] injects fake clients
/// (omit for the never-connecting default session).
Future<AccountStore> _pumpShell(
  WidgetTester tester, {
  List<String> urls = const [],
  bool autoConnect = true,
  ZflowClient Function(ZflowConnectionParams params,
          void Function(String line)? onLog)?
      clientFactory,
}) async {
  final store = AccountStore(storage: FakeCredentialStorage());
  for (final url in urls) {
    await store.addUrl(url);
  }
  await tester.pumpWidget(
    MaterialApp(
      theme: buildDarkTheme(),
      home: ThemeControllerProvider(
        controller: ThemeController(),
        child: UiSettingsProvider(
          settings: UiSettings(),
          child: RootShell(
            store: store,
            session: AppSession(clientFactory: clientFactory),
            autoConnect: autoConnect,
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  // U1:连接完成后进入工作区选择;测试统一选第一个工作区,
  // 等价于旧流程的"连接后自动进入工作区"。
  await _pickFirstWorkspace(tester);
  return store;
}

/// U1:设备切换/连接完成后落在工作区选择器,统一选第一个工作区。
Future<void> _pickFirstWorkspace(WidgetTester tester) async {
  for (var i = 0;
      i < 20 &&
          find.text('选择工作区').evaluate().isEmpty &&
          tester.widgetList<ChatPage>(find.byType(ChatPage)).isEmpty;
      i++) {
    await tester.pump(const Duration(milliseconds: 25));
  }
  if (find.text('选择工作区').evaluate().isNotEmpty) {
    await tester.tap(find.byType(ListTile).first);
    await tester.pump();
  }
}

String? _chatSessionId(WidgetTester tester) =>
    tester.widget<ChatPage>(find.byType(ChatPage)).sessionId;

/// 以当前内嵌实例自身的代数回写(模拟该实例的 onSessionInfo 推送;
/// A10 起回调签名携带 epoch)。
void _pushSessionInfo(WidgetTester tester, String sessionId, String title) {
  final chat = tester.widget<ChatPage>(find.byType(ChatPage));
  chat.onSessionInfo!(sessionId, title, chat.sessionEpoch);
}

Future<void> _openDrawer(WidgetTester tester) async {
  await tester.tap(find.byIcon(Icons.menu));
  // 有界 pump:200ms 开启动画走完即可;内嵌会话的加载转圈会让
  // pumpAndSettle 永不静止。
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

/// 抽屉关闭动画(200ms)的有界等待。
Future<void> _pumpDrawerClose(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

/// Flushes the fake-async timers leaked by mounted pages' pending RPC
/// requests (their 30s/45s response timeouts) so the test ends clean.
Future<void> _flushPendingTimers(WidgetTester tester) async {
  await tester.pump(const Duration(minutes: 5));
}

void main() {
  testWidgets('无设备时显示“添加设备”空态引导', (tester) async {
    await _pumpShell(tester);
    expect(find.textContaining('添加设备'), findsWidgets);
  });

  testWidgets('有设备不自动连时三 Tab 常驻且默认选中对话', (tester) async {
    await _pumpShell(tester, urls: [_deviceUrl], autoConnect: false);
    final bar = tester.widget<NavigationBar>(find.byType(NavigationBar));
    expect(bar.selectedIndex, 0);
    expect(find.text('对话'), findsOneWidget);
    expect(find.text('自动化'), findsOneWidget);
    expect(find.text('设置'), findsOneWidget);
  });

  testWidgets('自动化 Tab 无 bridge 时显示连接提示', (tester) async {
    await _pumpShell(tester, urls: [_deviceUrl], autoConnect: false);
    await tester.tap(find.text('自动化'));
    await tester.pumpAndSettle();
    expect(find.text('连接设备后可用'), findsOneWidget);
  });

  testWidgets('设置 Tab 渲染 SettingsPage 标题', (tester) async {
    await _pumpShell(tester, urls: [_deviceUrl], autoConnect: false);
    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();
    expect(find.byType(SettingsPage), findsOneWidget);
    // 页面标题「设置」+ 底部导航标签「设置」共两处。
    expect(find.text('设置'), findsNWidgets(2));
  });

  testWidgets('空态点“添加设备”push 设备管理页', (tester) async {
    await _pumpShell(tester);
    await tester.tap(find.text('添加设备'));
    await tester.pumpAndSettle();
    expect(find.byType(DeviceManagementPage), findsOneWidget);
    expect(find.text('设备管理'), findsOneWidget); // AppBar 标题
    // 页内有虚线添加按钮;点开是扫码/粘贴两入口的添加 sheet。
    await tester.tap(find.text('添加设备'));
    await tester.pumpAndSettle();
    expect(find.text('扫码添加'), findsOneWidget);
    expect(find.text('粘贴链接添加'), findsOneWidget);
  });

  testWidgets('自动连接进行中切换设备:后切换者最终生效(顶栏 + bridge)', (tester) async {
    final gateA = Completer<void>();
    final store = await _pumpShell(
      tester,
      urls: [_url('a', 'DeviceA'), _url('b', 'DeviceB')],
      clientFactory: (params, onLog) => _FakeClient(
        params,
        gate: params.deviceSid == 'a' ? gateA : null,
        workspaces: [
          {'workspacePath': '/ws-${params.deviceSid}', 'label': 'WS'},
        ],
      ),
    );
    // A 的连接被 gate 挡住 → 壳停在“连接中”。
    expect(find.text('连接设备中…'), findsOneWidget);

    // 连接进行中切到 B:B 立即连上并开桥(顶栏胶囊 + 内嵌 draft 聊天)。
    await sessionOf(tester).switchTo(store.accounts[1]);
    await tester.pump();
    await tester.pump();
    await _pickFirstWorkspace(tester);
    expect(find.text('DeviceB'), findsOneWidget); // 顶栏胶囊
    expect(_chatSessionId(tester), isNull); // B 的工作区 draft

    // 释放 A:A 完成后不得抢回激活态,壳最终仍是 B。
    gateA.complete();
    await tester.pump();
    await tester.pump();
    expect(sessionOf(tester).current?.label, 'DeviceB');
    expect(find.text('DeviceB'), findsOneWidget);
    expect(_chatSessionId(tester), isNull);
    await _flushPendingTimers(tester);
  });

  testWidgets('切换设备后回到对话 Tab', (tester) async {
    final store = await _pumpShell(
      tester,
      urls: [_url('a', 'DeviceA'), _url('b', 'DeviceB')],
      clientFactory: (params, onLog) => _FakeClient(
        params,
        workspaces: [
          {'workspacePath': '/ws-${params.deviceSid}', 'label': 'WS'},
        ],
      ),
    );
    await tester.pumpAndSettle(); // A 链完成
    expect(_chatSessionId(tester), isNull); // A 的 draft

    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();
    expect(
        tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
        2);

    await sessionOf(tester).switchTo(store.accounts[1]);
    await tester.pumpAndSettle();
    await _pickFirstWorkspace(tester);
    expect(
        tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
        0);
    expect(find.text('DeviceB'), findsOneWidget);
    expect(_chatSessionId(tester), isNull);
    await _flushPendingTimers(tester);
  });

  testWidgets('当前设备被外部断开后显示断开态而非残留内容', (tester) async {
    final store = await _pumpShell(
      tester,
      urls: [_deviceUrl],
      clientFactory: (params, onLog) => _FakeClient(
        params,
        workspaces: [
          {'workspacePath': '/ws-a', 'label': 'WS'},
        ],
      ),
    );
    await tester.pumpAndSettle(); // 链完成,对话页挂载
    expect(_chatSessionId(tester), isNull);

    // 模拟被挤下线/外部断开:session.current 变 null。
    await sessionOf(tester).disconnect(store.accounts[0].id);
    await tester.pumpAndSettle();

    // 文案中性:同一守卫页也覆盖“首次添加设备后尚未连接”的落点。
    expect(find.text('设备未连接'), findsOneWidget);
    expect(find.text('连接设备'), findsOneWidget);
    expect(
        tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
        0);
    expect(find.byType(ChatPage), findsNothing); // 残留会话已卸载
    await _flushPendingTimers(tester);
  });

  testWidgets('对话 Tab 系统 back 可退出,非对话 Tab back 回对话 Tab', (tester) async {
    await _pumpShell(tester, urls: [_deviceUrl], autoConnect: false);
    // byType 撞 PopScope<T> 的泛型实例化,用谓词匹配。
    PopScope shellPopScope() => tester.widget<PopScope>(
          find.byWidgetPredicate((w) => w is PopScope),
        );

    // 对话 Tab:canPop=true,系统 back 交给系统默认(可退出)。
    expect(shellPopScope().canPop, isTrue);

    // 非对话 Tab:back 被拦截,壳切回对话 Tab 而不是退出应用。
    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();
    expect(shellPopScope().canPop, isFalse);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(
        tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
        0);

    // 回到对话 Tab 后,back 恢复为系统默认(可退出)。
    expect(shellPopScope().canPop, isTrue);
  });

  /// 开一条带工作区 bridge 的假链,链完成后对话 Tab 处于"未选会话"态。
  Future<void> pumpWithBridge(WidgetTester tester) async {
    await _pumpShell(
      tester,
      urls: [_deviceUrl],
      clientFactory: (params, onLog) => _FakeClient(
        params,
        workspaces: [
          {'workspacePath': '/ws-a', 'label': 'WS'},
        ],
      ),
    );
    await tester.pumpAndSettle(); // 链完成
  }

  testWidgets('有 bridge 时对话 Tab 默认渲染 draft 新会话(列表收进抽屉)',
      (tester) async {
    await pumpWithBridge(tester);
    expect(find.byType(ChatPage), findsOneWidget);
    expect(find.byType(SessionDrawer), findsNothing);
    expect(find.text('输入消息开始新会话'), findsOneWidget);
    await _flushPendingTimers(tester);
  });

  testWidgets('☰ 呼出抽屉:工作区条/搜索/＋新会话/设备状态条渲染',
      (tester) async {
    await pumpWithBridge(tester);
    await _openDrawer(tester);

    expect(find.byType(SessionDrawer), findsOneWidget);
    expect(find.text('WS'), findsOneWidget); // 工作区名
    expect(find.text('/ws-a'), findsOneWidget); // 等宽路径
    expect(find.text('1 台设备'), findsOneWidget); // 底部设备状态条
    // 抽屉内「＋新会话」入口。
    expect(
        find.descendant(
            of: find.byType(SessionDrawer), matching: find.text('新会话')),
        findsOneWidget);
    await _flushPendingTimers(tester);
  });

  testWidgets('左缘右滑呼出抽屉', (tester) async {
    await pumpWithBridge(tester);
    final gesture = await tester.startGesture(const Offset(2, 400));
    await gesture.moveBy(const Offset(60, 0));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(find.byType(SessionDrawer), findsOneWidget);
    await _flushPendingTimers(tester);
  });

  testWidgets('抽屉点「新会话」→ 关抽屉回 draft(输入框可发)', (tester) async {
    await pumpWithBridge(tester);
    await _openDrawer(tester);

    await tester.tap(find.descendant(
        of: find.byType(SessionDrawer), matching: find.text('新会话')));
    await tester.pumpAndSettle();

    expect(find.byType(SessionDrawer), findsNothing); // 选后自动关
    expect(find.byType(ChatPage), findsOneWidget);
    expect(find.text('输入消息开始新会话'), findsOneWidget);
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.enabled, isNot(false));
    await _flushPendingTimers(tester);
  });

  testWidgets('选中会话内嵌渲染消息流(无 AppBar);会话内呼出抽屉选另一会话可切换',
      (tester) async {
    await pumpWithBridge(tester);

    await _openDrawer(tester);
    tester
        .widget<SessionDrawer>(find.byType(SessionDrawer))
        .onPick('s1'); // 模拟点会话条目
    await _pumpDrawerClose(tester);

    expect(find.byType(SessionDrawer), findsNothing); // 选后自动关
    expect(_chatSessionId(tester), 's1');
    expect(find.byType(ChatPage), findsOneWidget);
    // embedded 模式:无 Scaffold/AppBar 外壳(壳自身用自定义 _TopBar)。
    expect(find.byType(AppBar), findsNothing);

    // T2 移交 Medium:会话内呼出抽屉,点另一会话直接切换。
    await _openDrawer(tester);
    tester
        .widget<SessionDrawer>(find.byType(SessionDrawer))
        .onPick('s2');
    await _pumpDrawerClose(tester);

    expect(_chatSessionId(tester), 's2');
    await _flushPendingTimers(tester);
  });

  testWidgets('draft 首条消息创建会话后回写选择:切走再切回不再开新 draft',
      (tester) async {
    await pumpWithBridge(tester);
    expect(_chatSessionId(tester), isNull);

    // 模拟 draft 首条消息 createSession 成功后 ChatPage 的回写
    // (onSessionInfo 自 Task 4 起携带 sessionId)。
    _pushSessionInfo(tester, 's-new', '桌面起的标题');
    await tester.pump();

    // 标题即时上头部(ValueListenable);回写不重建内嵌实例(draft 态保留)。
    expect(find.text('桌面起的标题'), findsOneWidget);
    await _openDrawer(tester);
    expect(
      tester
          .widget<SessionDrawer>(find.byType(SessionDrawer))
          .currentSessionId,
      's-new', // 抽屉高亮跟随回写
    );
    await _pumpDrawerClose(tester);

    // 切走(自动化 Tab 卸载内嵌 ChatPage)再切回:按回写的会话恢复,
    // 而不是落到一个新 draft。
    await tester.tap(find.text('自动化'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('对话'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(_chatSessionId(tester), 's-new');
    await _flushPendingTimers(tester);
  });

  testWidgets('回写后抽屉点「新会话」仍显式开新 draft,点回写会话无缝恢复',
      (tester) async {
    await pumpWithBridge(tester);
    _pushSessionInfo(tester, 's-new', '桌面起的标题');
    await tester.pump();

    // 显式「＋新会话」:用户意图优先,回到全新 draft(不动回写前的实例态)。
    await _openDrawer(tester);
    tester
        .widget<SessionDrawer>(find.byType(SessionDrawer))
        .onPick(null);
    await _pumpDrawerClose(tester);
    expect(_chatSessionId(tester), isNull);
    expect(find.text('输入消息开始新会话'), findsOneWidget);

    // 点回写会话:恢复 s-new,不再是 draft。
    await _openDrawer(tester);
    tester.widget<SessionDrawer>(find.byType(SessionDrawer)).onPick('s-new');
    await _pumpDrawerClose(tester);
    expect(_chatSessionId(tester), 's-new');
    await _flushPendingTimers(tester);
  });

  testWidgets('抽屉重选当前会话即重开(实例重建,订阅失败自愈);draft→draft 幂等',
      (tester) async {
    await pumpWithBridge(tester);

    // 回写会话选择 + 桌面端生成的标题。
    _pushSessionInfo(tester, 's1', '桌面起的标题');
    await tester.pump();
    expect(find.text('桌面起的标题'), findsOneWidget);

    // 重选当前高亮会话:「重选」即重开(A11)——epoch 递增,内嵌实例
    // 全新(element 不换不了),标题清空回落占位,等新实例的索引推送回写
    // (订阅失败态由此自愈:新实例重新发起订阅)。
    final elementBefore = tester.element(find.byType(ChatPage));
    await _openDrawer(tester);
    tester.widget<SessionDrawer>(find.byType(SessionDrawer)).onPick('s1');
    await _pumpDrawerClose(tester);
    expect(find.byType(SessionDrawer), findsNothing);
    expect(_chatSessionId(tester), 's1'); // 仍是该会话,但实例已重建
    expect(tester.element(find.byType(ChatPage)), isNot(same(elementBefore)));
    expect(find.text('桌面起的标题'), findsNothing);
    expect(find.text('新会话'), findsOneWidget);

    // 新实例经 onSessionInfo 回写后标题恢复。
    _pushSessionInfo(tester, 's1', '重开后的标题');
    await tester.pump();
    expect(find.text('重开后的标题'), findsOneWidget);

    // draft →「新会话」:已是 draft,幂等不重建(element 不换)。
    await _openDrawer(tester);
    tester.widget<SessionDrawer>(find.byType(SessionDrawer)).onPick(null);
    await _pumpDrawerClose(tester);
    final draftElement = tester.element(find.byType(ChatPage));
    await _openDrawer(tester);
    tester.widget<SessionDrawer>(find.byType(SessionDrawer)).onPick(null);
    await _pumpDrawerClose(tester);
    expect(_chatSessionId(tester), isNull);
    expect(tester.element(find.byType(ChatPage)), same(draftElement));
    await _flushPendingTimers(tester);
  });

  testWidgets('旧实例的迟到 onSessionInfo 推送被 epoch 代际戳丢弃(A10)',
      (tester) async {
    await pumpWithBridge(tester);

    // 捕获 draft 实例(epoch N)的推送回调,随后切走:epoch 递增。
    final staleChat = tester.widget<ChatPage>(find.byType(ChatPage));
    await _openDrawer(tester);
    tester.widget<SessionDrawer>(find.byType(SessionDrawer)).onPick('s2');
    await _pumpDrawerClose(tester);
    expect(_chatSessionId(tester), 's2');

    // 旧 draft 实例的迟到推送(createSession 完成于切换之后):不得把
    // 用户的 s2 选择覆盖回 s-late。
    staleChat.onSessionInfo!('s-late', '迟到标题', staleChat.sessionEpoch);
    await tester.pump();
    expect(_chatSessionId(tester), 's2'); // 未被覆盖
    expect(find.text('迟到标题'), findsNothing);

    // 现役实例的推送仍正常生效。
    _pushSessionInfo(tester, 's2', '现役标题');
    await tester.pump();
    expect(find.text('现役标题'), findsOneWidget);
    await _flushPendingTimers(tester);
  });

  testWidgets('选中会话后切换设备:抽屉关闭回到 draft(复位)', (tester) async {
    final store = await _pumpShell(
      tester,
      urls: [_url('a', 'DeviceA'), _url('b', 'DeviceB')],
      clientFactory: (params, onLog) => _FakeClient(
        params,
        workspaces: [
          {'workspacePath': '/ws-${params.deviceSid}', 'label': 'WS'},
        ],
      ),
    );
    await tester.pumpAndSettle(); // A 链完成

    await _openDrawer(tester);
    tester.widget<SessionDrawer>(find.byType(SessionDrawer)).onPick('s1');
    await _pumpDrawerClose(tester);
    expect(_chatSessionId(tester), 's1');

    await _openDrawer(tester); // 抽屉开着时切换设备
    await sessionOf(tester).switchTo(store.accounts[1]);
    await _pumpDrawerClose(tester);
    await _pickFirstWorkspace(tester);

    // 复位:抽屉关闭、会话选择失效,落到 B 的 draft。
    expect(find.byType(SessionDrawer), findsNothing);
    expect(_chatSessionId(tester), isNull);
    expect(find.text('输入消息开始新会话'), findsOneWidget);
    await _flushPendingTimers(tester);
  });

  testWidgets('当前会话从索引消失:宿主复位回 draft 并提示(A4 宿主侧)', (tester) async {
    await pumpWithBridge(tester);

    await _openDrawer(tester);
    tester.widget<SessionDrawer>(find.byType(SessionDrawer)).onPick('s1');
    await _pumpDrawerClose(tester);
    expect(_chatSessionId(tester), 's1');
    final elementBefore = tester.element(find.byType(ChatPage));

    // 抽屉打开(生产中删除/归档就发生在抽屉内)时,diff 出当前会话已从
    // 索引消失 → 回调宿主。
    await _openDrawer(tester);
    tester
        .widget<SessionDrawer>(find.byType(SessionDrawer))
        .onCurrentSessionVanished();
    await tester.pump();

    // 回 draft:内嵌实例重建(epoch bump),抽屉保持打开,并提示用户。
    expect(_chatSessionId(tester), isNull);
    expect(find.byType(SessionDrawer), findsOneWidget);
    expect(tester.element(find.byType(ChatPage)), isNot(same(elementBefore)));
    expect(find.text('当前会话已删除或归档，已回到新会话'), findsOneWidget);
    await _flushPendingTimers(tester);
  });

  testWidgets('工作区切换 sheet:当前工作区行显示实时会话数,他区不显示(A15)',
      (tester) async {
    await _pumpShell(
      tester,
      urls: [_deviceUrl],
      clientFactory: (params, onLog) => _FakeClient(
        params,
        workspaces: [
          {'workspacePath': '/ws-a', 'label': 'WS-A'},
          {'workspacePath': '/ws-b', 'label': 'WS-B'},
        ],
      ),
    );
    await tester.pumpAndSettle(); // 链完成,打开第一个工作区

    await _openDrawer(tester);
    await tester.tap(find.text('WS-A')); // 工作区条 → sheet
    await tester.pumpAndSettle();

    // 当前工作区行:实时会话数徽(测试环境订阅无快照 → 0);他区无徽标。
    expect(find.text('0 会话'), findsOneWidget);
    expect(find.text('WS-A'), findsWidgets); // 抽屉条 + sheet 活动行
    expect(find.text('WS-B'), findsOneWidget);

    await _flushPendingTimers(tester);
  });

  testWidgets('选中会话并开抽屉后设备被外部断开:回断开态且抽屉不残留',
      (tester) async {
    final store = await _pumpShell(
      tester,
      urls: [_deviceUrl],
      clientFactory: (params, onLog) => _FakeClient(
        params,
        workspaces: [
          {'workspacePath': '/ws-a', 'label': 'WS'},
        ],
      ),
    );
    await tester.pumpAndSettle(); // 链完成

    await _openDrawer(tester);
    tester.widget<SessionDrawer>(find.byType(SessionDrawer)).onPick('s1');
    await _pumpDrawerClose(tester);
    expect(_chatSessionId(tester), 's1');

    await _openDrawer(tester);
    await sessionOf(tester).disconnect(store.accounts[0].id);
    await _pumpDrawerClose(tester);

    expect(find.text('设备未连接'), findsOneWidget);
    expect(find.byType(SessionDrawer), findsNothing);
    expect(find.byType(ChatPage), findsNothing);
    await _flushPendingTimers(tester);
  });
}

/// The RootShell under test is the app home; dig it out of the tree.
AppSession sessionOf(WidgetTester tester) {
  final root = tester.widget<RootShell>(
    find.byType(RootShell),
  );
  return root.session;
}
