import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zflow/state/account_store.dart';
import 'package:zflow/state/app_session.dart';
import 'package:zflow/state/log_store.dart';
import 'package:zflow/ui/log_page.dart';
import 'package:zflow/ui/settings_page.dart';

import 'fake_credential_storage.dart';

void main() {
  // LogStore.instance is app-wide; keep tests self-contained by clearing.
  setUp(() => LogStore.instance.clear());
  tearDown(() => LogStore.instance.clear());

  Future<void> pump(WidgetTester tester, LogPage page) async {
    await tester.pumpWidget(MaterialApp(home: page));
    // Advance past the 250ms coalesced-flush window so the pending Timer
    // settles and the entries are visible.
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets('diagnostics page shows only [诊断] entries', (tester) async {
    LogStore.instance.add('[诊断] 未知关闭码 4908');
    LogStore.instance.add('[v4] frame seq=12');
    LogStore.instance.add('[诊断] 快照解析失败');

    await pump(tester, const LogPage(diagnosticsOnly: true));

    expect(find.text('诊断日志'), findsOneWidget);
    expect(find.text('[诊断] 未知关闭码 4908'), findsOneWidget);
    expect(find.text('[诊断] 快照解析失败'), findsOneWidget);
    expect(find.text('[v4] frame seq=12'), findsNothing);
  });

  testWidgets('protocol log page excludes [诊断] entries', (tester) async {
    LogStore.instance.add('[诊断] 未知关闭码 4908');
    LogStore.instance.add('[v4] frame seq=12');

    await pump(tester, const LogPage());

    expect(find.text('协议日志'), findsOneWidget);
    expect(find.text('[v4] frame seq=12'), findsOneWidget);
    expect(find.text('[诊断] 未知关闭码 4908'), findsNothing);
    // Destructive clear lives only on the full log page.
    expect(find.byIcon(Icons.delete_outline), findsOneWidget);
  });

  testWidgets('clear action is not offered on the diagnostics page',
      (tester) async {
    LogStore.instance.add('[诊断] 未知关闭码 4908');
    await pump(tester, const LogPage(diagnosticsOnly: true));
    expect(find.byIcon(Icons.delete_outline), findsNothing);
  });

  testWidgets('诊断入口页计数徽随 LogStore 实时刷新(A8)', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: SettingsPage(
        store: AccountStore(storage: FakeCredentialStorage()),
        session: AppSession(),
        onDisconnect: () {},
      ),
    ));
    await tester.pumpAndSettle();

    // 进页时无诊断条目:只有行尾箭头,无计数徽。
    await tester.tap(find.text('诊断与日志'));
    await tester.pumpAndSettle();
    expect(find.text('1'), findsNothing);

    // 进页后新增诊断条目 → 250ms 合并刷新窗口后计数徽出现(实时)。
    LogStore.instance.add('[诊断] 测试新增条目');
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('1'), findsOneWidget);

    // 再加一条 → 计数变 2。
    LogStore.instance.add('[诊断] 又一条');
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('2'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 300));
  });
}
