import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zemote/protocol/connection_params.dart';
import 'package:zemote/protocol/zemote_client.dart';
import 'package:zemote/state/account_store.dart';
import 'package:zemote/state/app_session.dart';
import 'package:zemote/ui/conversation_list_page.dart';
import 'package:zemote/ui/device_management_page.dart';
import 'package:zemote/ui/root_shell.dart';
import 'package:zemote/ui/settings_page.dart';
import 'package:zemote/ui/theme.dart';
import 'package:zemote/ui/ui_settings.dart';

import 'fake_credential_storage.dart';

const _deviceUrl =
    'https://zcode.z.ai/remote/v4?sid=s&hash=h&t=1&name=Test';

String _url(String sid, String name) =>
    'https://zcode.z.ai/remote/v4?sid=$sid&hash=h&t=1&name=$name';

/// Fake [ZemoteClient]: no sockets. [gate] (when uncompleted) holds
/// connect() open so tests can stage in-flight chains; bootstrap/openBridge
/// answer from [workspaces] with detached bridge sessions.
class _FakeClient extends ZemoteClient {
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
  ZemoteClient Function(ZemoteConnectionParams params,
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
  return store;
}

String? _conversationKey(WidgetTester tester) {
  for (final w in tester.widgetList(find.byType(ConversationListPage))) {
    return (w as ConversationListPage).workspaceKey;
  }
  return null;
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

    // 连接进行中切到 B:B 立即连上并开桥。
    await sessionOf(tester).switchTo(store.accounts[1]);
    await tester.pump();
    await tester.pump();
    expect(find.text('DeviceB'), findsOneWidget); // 顶栏胶囊
    expect(_conversationKey(tester), '/ws-b'); // bridge 是 B 的工作区

    // 释放 A:A 完成后不得抢回激活态,壳最终仍是 B。
    gateA.complete();
    await tester.pump();
    await tester.pump();
    expect(sessionOf(tester).current?.label, 'DeviceB');
    expect(find.text('DeviceB'), findsOneWidget);
    expect(_conversationKey(tester), '/ws-b');
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
    expect(_conversationKey(tester), '/ws-a');

    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();
    expect(
        tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
        2);

    await sessionOf(tester).switchTo(store.accounts[1]);
    await tester.pumpAndSettle();
    expect(
        tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
        0);
    expect(find.text('DeviceB'), findsOneWidget);
    expect(_conversationKey(tester), '/ws-b');
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
    expect(_conversationKey(tester), '/ws-a');

    // 模拟被挤下线/外部断开:session.current 变 null。
    await sessionOf(tester).disconnect(store.accounts[0].id);
    await tester.pumpAndSettle();

    // 文案中性:同一守卫页也覆盖“首次添加设备后尚未连接”的落点。
    expect(find.text('设备未连接'), findsOneWidget);
    expect(find.text('连接设备'), findsOneWidget);
    expect(
        tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
        0);
    expect(_conversationKey(tester), isNull); // 残留 bridge 已卸载
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
}

/// The RootShell under test is the app home; dig it out of the tree.
AppSession sessionOf(WidgetTester tester) {
  final root = tester.widget<RootShell>(
    find.byType(RootShell),
  );
  return root.session;
}
