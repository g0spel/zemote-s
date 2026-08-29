import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter_test/flutter_test.dart';
import 'package:zflow/protocol/connection_params.dart';
import 'package:zflow/protocol/zflow_client.dart';

/// Arg-shape discovery for zcode-agent automation methods, via a
/// create → toggle → update → runs → delete cycle on a throwaway
/// automation titled "zmote 探测测试".
void main() {
  test('automation rpc arg-shape cycle', () async {
    final probeUrl = Platform.environment['ZEMOTE_PROBE_URL'] ??
        const String.fromEnvironment('ZEMOTE_PROBE_URL', defaultValue: '');
    final params =
        probeUrl.isEmpty ? null : ZflowConnectionParams.parse(probeUrl);
    if (params == null) {
      // ignore: avoid_print
      print('SKIP');
      return;
    }
    String enc(Object? o, [int max = 3000]) {
      final s = const JsonEncoder.withIndent('  ').convert(o);
      return s.length > max ? '${s.substring(0, max)}…(${s.length})' : s;
    }

    String brief(Object e) {
      final m = '$e';
      return m.length > 260 ? m.substring(0, 260) : m;
    }

    final client = ZflowClient(params);
    await client.connect();
    await client.waitPaired(timeout: const Duration(seconds: 60));
    final bootstrap = await client.bootstrap();
    final wsList = bootstrap['workspaces'];
    if (wsList is! List || wsList.isEmpty) {
      await client.dispose();
      return;
    }
    // Use the first workspace (any works — the cycle cleans up after itself).
    final w = (wsList.first as Map).cast<String, dynamic>();
    final scope = {
      'workspacePath': w['workspacePath'],
      if (w['workspaceIdentity'] != null)
        'workspaceIdentity': w['workspaceIdentity'],
    };
    final bridge = await client.openBridge(
        w['workspaceIdentity'] as String? ?? w['workspacePath'] as String);
    // ignore: avoid_print
    print('=== bridge ready ===');

    Future<Object?> call(String m, List<Object?> args,
        [String tag = '']) async {
      try {
        final res = await bridge.channels.call('zcode-agent', m, args,
            timeout: const Duration(seconds: 8));
        // ignore: avoid_print
        print('>> $m$tag OK ${enc(res, 900)}');
        return res;
      } catch (e) {
        // ignore: avoid_print
        print('>> $m$tag ERR ${brief(e)}');
        return null;
      }
    }

    // 0. Current list — capture the existing automation id (never touched).
    final list0 = await call('listAutomations', [scope]);
    String? existingId;
    if (list0 is List && list0.isNotEmpty) {
      existingId = (list0.first as Map)['automationId'] as String?;
    }

    // 1. listAutomationRuns on the EXISTING automation (read-only).
    if (existingId != null) {
      await call('listAutomationRuns', [
        {...scope, 'automationId': existingId}
      ], '(obj)');
      final r = await call('listAutomationRuns', [existingId], '(id)');
        if (r == null) {
          await call('listAutomationRuns', [
            existingId,
            scope
          ], '(id+scope)');
        }
    }

    // 2. createAutomation — minimal plausible object.
    final createArgs = <Object?>[
      {
        ...scope,
        'title': 'zmote 探测测试-可安全删除',
        'cronExpr': '30 3 * * *',
        'prompt': 'zmote 探测测试：这条自动化由移动端接口探测创建，马上会被删除，请勿执行任何操作。',
      }
    ];
    var created = await call('createAutomation', createArgs, '(min)');
    String? testId;
    if (created is Map) {
      testId = created['automationId'] as String?;
    } else if (created is String) {
      testId = created;
    }
    if (testId == null) {
      // maybe args[1] carries the object
      created = await call('createAutomation', [
        scope,
        {
          'title': 'zmote 探测测试-可安全删除',
          'cronExpr': '30 3 * * *',
          'prompt': 'zmote 探测测试，可安全删除。',
        }
      ], '(scope+obj)');
      testId ??= created is Map
          ? created['automationId'] as String?
          : created is String
              ? created
              : null;
    }

    if (testId == null) {
      // ignore: avoid_print
      print('!! create failed — list to check for a leftover test row:');
      await call('listAutomations', [scope], '(recheck)');
      bridge.dispose();
      await client.dispose();
      return;
    }
    // ignore: avoid_print
    print('== created test automation: $testId ==');

    // 3. setAutomationEnabled variants on the test row.
    await call('setAutomationEnabled', [
      {...scope, 'automationId': testId, 'enabled': true}
    ], '(obj)');
    await call('setAutomationEnabled', [
      {...scope, 'automationId': testId, 'enabled': false}
    ], '(obj-off)');

    // 4. updateAutomation on the test row.
    await call('updateAutomation', [
      {...scope, 'automationId': testId, 'title': 'zmote 探测测试-已改名'}
    ], '(obj)');

    // 5. deleteAutomation — try object first, fallbacks after.
    final objDeleted = await call('deleteAutomation', [
      {...scope, 'automationId': testId}
    ], '(obj)');
    final deleted = objDeleted ??
        await call('deleteAutomation', [testId], '(id)') ??
        await call('deleteAutomation', [
          testId,
          scope
        ], '(id+scope)');
    // ignore: avoid_print
    print('== delete result: $deleted ==');

    // 6. Final verification: test row must be gone, existing intact.
    final listEnd = await call('listAutomations', [scope], '(final)');
    if (listEnd is List) {
      final ids = listEnd.map((e) => (e as Map)['automationId']).toList();
      // ignore: avoid_print
      print('== final ids: $ids | testDeleted=${!ids.contains(testId)} | existingIntact=${ids.contains(existingId)} ==');
    }

    bridge.dispose();
    await client.dispose();
    // ignore: avoid_print
    print('=== done ===');
  }, timeout: const Timeout(Duration(minutes: 4)));
}
