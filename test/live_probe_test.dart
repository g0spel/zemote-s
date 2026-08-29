import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter_test/flutter_test.dart';
import 'package:zflow/protocol/channel_client.dart';
import 'package:zflow/protocol/connection_params.dart';
import 'package:zflow/protocol/zflow_client.dart';
import 'package:zflow/ui/chat_page.dart' show deriveTodoSteps;

/// Read-only debug probe for the insight panels: dumps the REAL payload
/// shapes of conversationPlansV4 / conversationFileChangesV4 /
/// snapshot.backgroundWorks so their parsers can be adapted precisely.
/// Run with: ZEMOTE_PROBE_URL=`<remote-control url>` flutter test test/live_probe_test.dart
void main() {
  test('insight panels payload probe', () async {
    // Env var (README's documented injection; `flutter test` on current
    // stable does not forward --dart-define), dart-define as fallback.
    final probeUrl = Platform.environment['ZEMOTE_PROBE_URL'] ??
        const String.fromEnvironment('ZEMOTE_PROBE_URL', defaultValue: '');
    final params =
        probeUrl.isEmpty ? null : ZflowConnectionParams.parse(probeUrl);
    if (params == null) {
      // ignore: avoid_print
      print('SKIP: ZEMOTE_PROBE_URL not set.');
      return;
    }

    String enc(Object? o, [int max = 6000]) {
      final s = const JsonEncoder.withIndent('  ').convert(o);
      return s.length > max ? '${s.substring(0, max)}\n…(${s.length} chars)' : s;
    }

    String fmtErr(Object e) => e is ChannelRpcError
        ? 'ChannelRpcError message="${e.message}" data=${enc(e.data, 800)}'
        : '$e';

    final client = ZflowClient(params);
    await client.connect();
    await client.waitPaired(timeout: const Duration(seconds: 60));
    // ignore: avoid_print
    print('=== paired ===');

    final bootstrap = await client.bootstrap();
    final wsList = bootstrap['workspaces'];
    if (wsList is! List || wsList.isEmpty) {
      // ignore: avoid_print
      print('no workspaces');
      await client.dispose();
      return;
    }

    // Iterate EVERY workspace; stop after finding a task with non-empty
    // plans and a successful fileChanges sample.
    var plansFound = false;
    var filesFound = false;
    for (final wRaw in wsList) {
      if (wRaw is! Map) continue;
      final w = wRaw.cast<String, dynamic>();
      final scope = {
        'workspacePath': w['workspacePath'],
        if (w['workspaceIdentity'] != null)
          'workspaceIdentity': w['workspaceIdentity'],
      };
      final workspaceKey = w['workspaceIdentity'] as String? ??
          w['workspacePath'] as String;
      final bridge = await client.openBridge(workspaceKey);
      final transport = bridge.conversation(scope);
      // ignore: avoid_print
      print('=== bridge opened on ${w['workspacePath']} ===');

      final si = await transport.subscribeSessionsIndex();
      final siDeadline = DateTime.now().add(const Duration(seconds: 15));
      while (!si.state.ready && DateTime.now().isBefore(siDeadline)) {
        await Future.delayed(const Duration(milliseconds: 200));
      }
      final sessions = si.state.list;
      // ignore: avoid_print
      print('=== sessions-index: ${sessions.length} sessions ===');
      for (final s in sessions.take(4)) {
        // ignore: avoid_print
        print('  ${s.sessionId} | ${s.title} | phase=${s.phase}');
      }

      for (final target in sessions.take(4)) {
        if (plansFound && filesFound) break;
        final sid = target.sessionId;
        // ignore: avoid_print
        print('\n########## task $sid "${target.title}" ##########');

        final conv = await transport.subscribe(sid);
        final convDeadline = DateTime.now().add(const Duration(seconds: 20));
        while (!conv.state.ready && DateTime.now().isBefore(convDeadline)) {
          await Future.delayed(const Duration(milliseconds: 200));
        }

        if (!plansFound) {
          final derived = deriveTodoSteps(conv.state.rows);
          if (derived != null) {
            // ignore: avoid_print
            print('---- deriveTodoSteps(rows) FOUND ${derived.length} ----');
            for (final s in derived) {
              // ignore: avoid_print
              print('  [${s.status}] ${s.title}');
            }
            plansFound = true;
          } else {
            // ignore: avoid_print
            print('---- deriveTodoSteps(rows): none in this task ----');
          }
        }

        final snap = conv.state.snapshot;
        final bg = snap?['backgroundWorks'];
        if (bg is List && bg.isNotEmpty) {
          // ignore: avoid_print
          print('---- snapshot.backgroundWorks (NON-EMPTY) ----\n${enc(bg, 2500)}');
        }

        if (!filesFound) {
          // Guard contract (from the desktop host): target must be the
          // turnHeader of a COMPLETED turn {rowId, entityId};
          // baseRevision/baseLogEpoch are read from the live subscription
          // inside the transport (with stale-recovery retry).
          Map<String, dynamic>? header;
          for (final r in conv.state.rows) {
            if (r['kind'] == 'turnHeader' &&
                r['rowId'] != null &&
                r['entityId'] is String) {
              header = r;
            }
          }
          if (header != null) {
            try {
              final res = await transport.fileChanges(
                sid,
                target: {
                  'rowId': header['rowId'],
                  'entityId': header['entityId'],
                },
              );
              // ignore: avoid_print
              print('---- fileChanges[turnHeader+rev+epoch] OK ----\n${enc(res, 3500)}');
              filesFound = true;
            } catch (err) {
              // ignore: avoid_print
              print('---- fileChanges FAILED: ${fmtErr(err)}');
            }
          } else {
            // ignore: avoid_print
            print('---- no turnHeader row with entityId ----');
          }
        }

        await conv.dispose();
      }
      await si.dispose();
      bridge.dispose();
      if (plansFound && filesFound) break;
    }

    await client.dispose();
    // ignore: avoid_print
    print('\n=== done (plansFound=$plansFound filesFound=$filesFound) ===');
  }, timeout: const Timeout(Duration(minutes: 4)));
}
