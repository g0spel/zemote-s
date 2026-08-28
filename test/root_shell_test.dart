import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zemote/state/account_store.dart';
import 'package:zemote/state/app_session.dart';
import 'package:zemote/ui/root_shell.dart';
import 'package:zemote/ui/settings_page.dart';
import 'package:zemote/ui/theme.dart';
import 'package:zemote/ui/ui_settings.dart';

import 'fake_credential_storage.dart';

const _deviceUrl =
    'https://zcode.z.ai/remote/v4?sid=s&hash=h&t=1&name=Test';

/// Pumps a [RootShell] inside the production provider stack with an
/// in-memory [AccountStore] seeded via [urls].
Future<void> _pumpShell(
  WidgetTester tester, {
  List<String> urls = const [],
  bool autoConnect = true,
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
            session: AppSession(),
            autoConnect: autoConnect,
          ),
        ),
      ),
    ),
  );
  await tester.pump();
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
}
