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

  testWidgets('旧供应商卡片 source 切换后不再发 save RPC', (tester) async {
    final h = _ProviderHarness();
    addTearDown(h.dispose);
    const oldScope = {
      'workspacePath': '/old',
      'workspaceIdentity': 'old-identity',
    };
    const nextScope = {
      'workspacePath': '/new',
      'workspaceIdentity': 'new-identity',
    };
    final provider = <String, dynamic>{
      'id': 'provider-1',
      'name': 'Provider 1',
      'enabled': true,
      'models': const [],
    };

    await tester.pumpWidget(MaterialApp(
      theme: buildDarkTheme(),
      home: ModelProvidersPage(session: h.bridge, scope: oldScope),
    ));
    await tester.pump();
    h.respond(0, [provider]);
    await tester.pump();
    await tester.pump();
    // 完成旧 source 的实时模型请求,确保后续只观察 mutation RPC。
    for (var round = 0; round < 4; round++) {
      final before = h.requests.length;
      for (var i = 1; i < h.requests.length; i++) {
        if (h.requests[i].method == 'prepareWorkspace') {
          h.respond(i, {
            'configOptions': [
              {'id': 'model', 'options': const []},
            ],
          });
        }
      }
      await tester.pump();
      if (h.requests.length == before) break;
    }

    final oldSwitch = tester.widget<Switch>(find.byType(Switch));
    final oldOnChanged = oldSwitch.onChanged!;
    final oldRequestCount = h.requests.length;

    await tester.pumpWidget(MaterialApp(
      theme: buildDarkTheme(),
      home: ModelProvidersPage(session: h.bridge, scope: nextScope),
    ));
    await tester.pump();
    oldOnChanged(false);
    await tester.pump();

    expect(
      h.requests.skip(oldRequestCount).where((r) => r.method == 'save'),
      isEmpty,
    );

    // source 切换会启动新 source 的 getAll,其完成后再启动 prep；两拍都
    // 应答，避免测试结束时留下 ChannelClient 超时计时器。
    for (var round = 0; round < 4; round++) {
      final before = h.requests.length;
      for (var i = oldRequestCount; i < h.requests.length; i++) {
        final method = h.requests[i].method;
        if (method == 'getAll') {
          h.respond(i, const []);
        } else if (method == 'prepareWorkspace') {
          h.respond(i, {
            'configOptions': [
              {'id': 'model', 'options': const []},
            ],
          });
        }
      }
      await tester.pump();
      if (h.requests.length == before) break;
    }
    await tester.pumpWidget(const SizedBox.shrink());
    h.dispose();
    await tester.pump(const Duration(seconds: 40));
  });
}
