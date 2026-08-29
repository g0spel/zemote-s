import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter_test/flutter_test.dart';
import 'package:zflow/protocol/connection_params.dart';
import 'package:zflow/protocol/zflow_client.dart';

/// One-off discovery probe for the `off-peak-task` channel (automations).
/// Calls candidate method names with a workspace scope and prints each
/// response or validation error — Zod errors enumerate the expected fields,
/// which is how we reverse-engineer the RPC surface.
/// Run with: ZEMOTE_PROBE_URL=`<remote-control url>` flutter test test/offpeak_probe_test.dart
void main() {
  test('off-peak-task channel method discovery', () async {
    final probeUrl = Platform.environment['ZEMOTE_PROBE_URL'] ??
        const String.fromEnvironment('ZEMOTE_PROBE_URL', defaultValue: '');
    final params =
        probeUrl.isEmpty ? null : ZflowConnectionParams.parse(probeUrl);
    if (params == null) {
      // ignore: avoid_print
      print('SKIP: ZEMOTE_PROBE_URL not set.');
      return;
    }

    String enc(Object? o, [int max = 2600]) {
      final s = const JsonEncoder.withIndent('  ').convert(o);
      return s.length > max ? '${s.substring(0, max)}\n…(${s.length} chars)' : s;
    }

    final client = ZflowClient(params);
    await client.connect();
    await client.waitPaired(timeout: const Duration(seconds: 60));
    final bootstrap = await client.bootstrap();
    final wsList = bootstrap['workspaces'];
    if (wsList is! List || wsList.isEmpty) {
      // ignore: avoid_print
      print('no workspaces');
      await client.dispose();
      return;
    }
    // Round 1 result: `list` is the ONLY method on this channel (everything
    // else: Method not found). Now call it per-workspace to capture the
    // real item schema from an account that has automations.
    for (final wRaw in wsList) {
      if (wRaw is! Map) continue;
      final w = wRaw.cast<String, dynamic>();
      final scope = {
        'workspacePath': w['workspacePath'],
        if (w['workspaceIdentity'] != null)
          'workspaceIdentity': w['workspaceIdentity'],
      };
      final bridge = await client.openBridge(
          w['workspaceIdentity'] as String? ?? w['workspacePath'] as String);
      try {
        final res = await bridge.channels
            .call('off-peak-task', 'list', [scope],
                timeout: const Duration(seconds: 8))
            .catchError((Object e) => 'ERR: $e');
        // ignore: avoid_print
        print('>> list @ ${w['workspacePath']} →\n${enc(res, 4000)}');
      } finally {
        bridge.dispose();
      }
    }

    await client.dispose();
    // ignore: avoid_print
    print('=== done ===');
  }, timeout: const Timeout(Duration(minutes: 5)));
}

// Round 3 (kept for reference): SessionEntry.raw markers + sibling channels.
// Run with the same env var.
