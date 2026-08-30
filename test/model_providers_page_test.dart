import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zflow/protocol/channel_client.dart';
import 'package:zflow/protocol/ipc_codec.dart';
import 'package:zflow/protocol/zflow_client.dart';
import 'package:zflow/ui/model_providers_page.dart';
import 'package:zflow/ui/theme.dart';

Uint8List _frame(List<Object?> header, [Object? data]) {
  final writer = ValueWriter();
  encodeValue(writer, header);
  if (data != null) encodeValue(writer, data);
  return writer.toBytes();
}

class _ProviderHarness {
  late final ChannelClient channels;
  late final BridgeSession bridge;
  final requests = <({int id, String channel, String method, List args})>[];

  _ProviderHarness() {
    channels = ChannelClient(sendBody: (body) {
      final reader = ValueReader(body);
      final header = decodeValue(reader) as List;
      final args = decodeValue(reader) as List;
      requests.add((
        id: (header[1] as num).toInt(),
        channel: header[2] as String,
        method: header[3] as String,
        args: args.cast<Object?>(),
      ));
    });
    bridge = BridgeSession.detached(
      {'workspaceKey': '/ws'},
      channels: channels,
    );
    channels.handleMessage(_frame(const [ChannelClient.resInitialize, 0]));
  }

  void respond(int index, Object? result) {
    final request = requests[index];
    channels.handleMessage(
      _frame([ChannelClient.resPromiseSuccess, request.id], result),
    );
  }

  void dispose() => bridge.dispose();
}

void main() {
  testWidgets('provider page uses scoped prep and clears stale live models',
      (tester) async {
    final h = _ProviderHarness();
    addTearDown(h.dispose);
    const scope = {
      'workspacePath': '/ws',
      'workspaceIdentity': 'identity-1',
    };

    await tester.pumpWidget(MaterialApp(
      theme: buildDarkTheme(),
      home: ModelProvidersPage(session: h.bridge, scope: scope),
    ));
    await tester.pump();
    expect(h.requests, hasLength(1));
    expect(h.requests.single.method, 'getAll');

    h.respond(0, [
      {
        'id': 'provider-1',
        'name': 'Provider 1',
        'models': [
            {
              'id': 'deleted-model',
              'name': 'Deleted model',
            },
        ],
      },
    ]);
    await tester.pump();
    await tester.pump();

    expect(h.requests, hasLength(2));
    final prep = h.requests[1];
    expect(prep.channel, 'zcode-task');
    expect(prep.method, 'prepareWorkspace');
    expect(prep.args, [scope]);

    h.respond(1, {
      'configOptions': [
        {
          'id': 'model',
          'options': [
            {
              'value': 'builtin:other-model',
              'name': 'Other model',
              'modelProviderId': 'provider-1',
            },
          ],
        },
      ],
    });
    await tester.pump();
    await tester.pump();

    expect(find.textContaining('0 / 1 个模型可用'), findsOneWidget);
    await tester.tap(find.byType(ExpansionTile));
    await tester.pump();
    expect(find.textContaining('已下线'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    h.dispose();
  });
}
