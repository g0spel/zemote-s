import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:zflow/protocol/channel_client.dart';
import 'package:zflow/protocol/conversation.dart';
import 'package:zflow/protocol/ipc_codec.dart';
import 'package:zflow/protocol/zflow_client.dart';

Uint8List _frame(List<Object?> header, [Object? data]) {
  final writer = ValueWriter();
  encodeValue(writer, header);
  if (data != null) encodeValue(writer, data);
  return writer.toBytes();
}

class _PrepHarness {
  late final ChannelClient channels;
  late final BridgeSession bridge;
  late final ConversationTransport transport;
  final requests = <({int id, String method, List args})>[];

  _PrepHarness() {
    channels = ChannelClient(sendBody: (body) {
      final reader = ValueReader(body);
      final header = decodeValue(reader) as List;
      final args = decodeValue(reader) as List;
      requests.add((
        id: (header[1] as num).toInt(),
        method: header[3] as String,
        args: args.cast<Object?>(),
      ));
    });
    bridge = BridgeSession.detached(
      {'workspaceKey': '/ws'},
      channels: channels,
    );
    transport = ConversationTransport(
      session: bridge,
      scope: const {
        'workspacePath': '/ws',
        'workspaceIdentity': 'identity-1',
      },
    );
    channels.handleMessage(_frame(const [ChannelClient.resInitialize, 0]));
  }

  void respond(int requestIndex, Object? result) {
    final request = requests[requestIndex];
    channels.handleMessage(
      _frame([ChannelClient.resPromiseSuccess, request.id], result),
    );
  }

  void dispose() => bridge.dispose();
}

Map<String, dynamic> _prep(String model) => {
      'configOptions': [
        {
          'id': 'model',
          'options': [
            {
              'value': 'builtin:$model',
              'name': model,
              'modelProviderId': 'provider-1',
            },
          ],
        },
      ],
    };

void main() {
  test('conversation transport cache is isolated by full workspace scope', () {
    final h = _PrepHarness();
    addTearDown(h.dispose);
    final cached = h.bridge.conversation(const {
      'workspacePath': '/ws',
      'workspaceIdentity': 'identity-1',
    });
    final otherPath = h.bridge.conversation(const {
      'workspacePath': '/ws-moved',
      'workspaceIdentity': 'identity-1',
    });
    final otherIdentity = h.bridge.conversation(const {
      'workspacePath': '/ws',
      'workspaceIdentity': 'identity-2',
    });

    expect(
        cached,
        same(h.bridge.conversation(const {
          'workspacePath': '/ws',
          'workspaceIdentity': 'identity-1',
        })));
    expect(identical(cached, otherPath), isFalse);
    expect(identical(cached, otherIdentity), isFalse);
  });

  test('prepareWorkspace preserves scope and coalesces ordinary requests',
      () async {
    final h = _PrepHarness();
    addTearDown(h.dispose);

    final first = h.transport.prepareWorkspace();
    await Future<void>.delayed(Duration.zero);
    expect(h.requests, hasLength(1));
    expect(h.requests.single.method, 'prepareWorkspace');
    expect(h.requests.single.args, [
      {
        'workspacePath': '/ws',
        'workspaceIdentity': 'identity-1',
      },
    ]);

    final second = h.transport.prepareWorkspace();
    expect(identical(first, second), isFalse);
    h.respond(0, _prep('model-a'));
    final result = await first;
    expect((await second).option('model')?.options.single.value,
        'builtin:model-a');
    expect(result.option('model')?.options.single.value, 'builtin:model-a');
    expect(await h.transport.prepareWorkspace(), same(result));
    expect(h.requests, hasLength(1));
  });

  test('refresh does not attach to an unrelated ordinary in-flight request',
      () async {
    final h = _PrepHarness();
    addTearDown(h.dispose);

    final ordinary = h.transport.prepareWorkspace();
    await Future<void>.delayed(Duration.zero);
    final refresh = h.transport.prepareWorkspace(refresh: true);
    await Future<void>.delayed(Duration.zero);
    expect(h.requests, hasLength(2));
    expect(identical(ordinary, refresh), isFalse);

    h.respond(1, _prep('refresh'));
    final refreshResult = await refresh;
    h.respond(0, _prep('ordinary'));
    expect((await ordinary).option('model')?.options.single.value,
        'builtin:ordinary');
    expect(
        refreshResult.option('model')?.options.single.value, 'builtin:refresh');
    expect(await h.transport.prepareWorkspace(), same(refreshResult));
  });

  test('recovery detaches old prep future and prevents stale cache write',
      () async {
    final h = _PrepHarness();
    addTearDown(h.dispose);

    final old = h.transport.prepareWorkspace(refresh: true);
    await Future<void>.delayed(Duration.zero);
    expect(h.requests, hasLength(1));

    h.bridge.recovered.value++;
    final fresh = h.transport.prepareWorkspace(refresh: true);
    await Future<void>.delayed(Duration.zero);
    expect(h.requests, hasLength(2));

    h.respond(1, _prep('fresh'));
    final freshResult = await fresh;
    h.respond(0, _prep('stale'));
    await old;

    expect(await h.transport.prepareWorkspace(), same(freshResult));
    expect(h.requests, hasLength(2));
  });
}
