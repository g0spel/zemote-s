import 'dart:convert';
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

class _AttachmentHarness {
  late final ChannelClient channels;
  late final ConversationTransport transport;
  final List<Map<String, dynamic>> requests = [];
  Object? Function(String method, List args)? respond;

  _AttachmentHarness() {
    channels = ChannelClient(sendBody: (body) {
      final reader = ValueReader(body);
      final header = decodeValue(reader) as List;
      final args = decodeValue(reader) as List;
      final method = header[3] as String;
      requests.add({'method': method, 'args': args});
      final result = respond?.call(method, args);
      if (result != null) {
        channels.handleMessage(
          _frame([ChannelClient.resPromiseSuccess, header[1]], result),
        );
      }
    });
    channels.handleMessage(_frame(const [ChannelClient.resInitialize, 0]));
    transport = ConversationTransport(
      session: BridgeSession.detached(
        {'workspaceKey': '/ws'},
        channels: channels,
      ),
      scope: const {'workspacePath': '/ws'},
    );
  }

  void dispose() {
    transport.session.dispose();
  }
}

void main() {
  test('attachmentRead assembles validated chunks into the result buffer',
      () async {
    final h = _AttachmentHarness();
    addTearDown(h.dispose);
    h.respond = (method, args) {
      switch (method) {
        case 'helloConversationV4':
          return {'connectionId': 'conn-1'};
        case 'initializeConversationV4':
          return {};
        case 'attachmentReadV4':
          final offset = (args.single as Map)['offset'];
          return offset == 0
              ? {
                  'totalBytes': 5,
                  'dataBase64': base64Encode(utf8.encode('abc')),
                  'nextOffset': 3,
                  'mediaType': 'text/plain',
                }
              : {
                  'totalBytes': 5,
                  'dataBase64': base64Encode(utf8.encode('de')),
                  'nextOffset': 5,
                };
      }
      return {};
    };

    final result = await h.transport.attachmentRead('s1', ref: 'ref-1');
    expect(utf8.decode(result.bytes), 'abcde');
    expect(result.mediaType, 'text/plain');
    expect(
      h.requests.where((r) => r['method'] == 'attachmentReadV4'),
      hasLength(2),
    );
  });

  test('attachmentRead accepts legacy responses without totalBytes', () async {
    final h = _AttachmentHarness();
    addTearDown(h.dispose);
    h.respond = (method, args) {
      switch (method) {
        case 'helloConversationV4':
          return {'connectionId': 'conn-1'};
        case 'initializeConversationV4':
          return {};
        case 'attachmentReadV4':
          final offset = (args.single as Map)['offset'];
          return offset == 0
              ? {'dataBase64': 'YQ==', 'nextOffset': 1}
              : {'dataBase64': '', 'nextOffset': 1};
      }
      return {};
    };

    final result = await h.transport.attachmentRead('s1', ref: 'ref-1');
    expect(result.bytes, [97]);
  });

  test('attachmentRead preserves legacy chunks when totalBytes appears later',
      () async {
    final h = _AttachmentHarness();
    addTearDown(h.dispose);
    h.respond = (method, args) {
      switch (method) {
        case 'helloConversationV4':
          return {'connectionId': 'conn-1'};
        case 'initializeConversationV4':
          return {};
        case 'attachmentReadV4':
          final offset = (args.single as Map)['offset'];
          return offset == 0
              ? {'dataBase64': 'YQ==', 'nextOffset': 1}
              : {
                  'totalBytes': 2,
                  'dataBase64': 'Yg==',
                  'nextOffset': 2,
                };
      }
      return {};
    };

    final result = await h.transport.attachmentRead('s1', ref: 'ref-1');
    expect(result.bytes, [97, 98]);
  });

  test('attachmentRead rejects non-contiguous or incomplete responses',
      () async {
    final h = _AttachmentHarness();
    addTearDown(h.dispose);
    h.respond = (method, args) {
      switch (method) {
        case 'helloConversationV4':
          return {'connectionId': 'conn-1'};
        case 'initializeConversationV4':
          return {};
        case 'attachmentReadV4':
          return {
            'totalBytes': 5,
            'dataBase64': base64Encode(utf8.encode('abc')),
            'nextOffset': 5,
          };
      }
      return {};
    };

    await expectLater(
      h.transport.attachmentRead('s1', ref: 'ref-1'),
      throwsA(isA<StateError>()),
    );
  });

  test('attachmentRead rejects malformed base64 and changing totalBytes',
      () async {
    final malformed = _AttachmentHarness();
    addTearDown(malformed.dispose);
    malformed.respond = (method, args) {
      switch (method) {
        case 'helloConversationV4':
          return {'connectionId': 'conn-1'};
        case 'initializeConversationV4':
          return {};
        case 'attachmentReadV4':
          return {
            'totalBytes': 3,
            'dataBase64': 'not base64 %',
            'nextOffset': 3,
          };
      }
      return {};
    };
    await expectLater(
      malformed.transport.attachmentRead('s1', ref: 'ref-1'),
      throwsA(isA<StateError>()),
    );

    final changing = _AttachmentHarness();
    addTearDown(changing.dispose);
    changing.respond = (method, args) {
      switch (method) {
        case 'helloConversationV4':
          return {'connectionId': 'conn-1'};
        case 'initializeConversationV4':
          return {};
        case 'attachmentReadV4':
          final offset = (args.single as Map)['offset'];
          return offset == 0
              ? {
                  'totalBytes': 2,
                  'dataBase64': 'YQ==',
                  'nextOffset': 1,
                }
              : {
                  'totalBytes': 3,
                  'dataBase64': 'Yg==',
                  'nextOffset': 2,
                };
      }
      return {};
    };
    await expectLater(
      changing.transport.attachmentRead('s1', ref: 'ref-1'),
      throwsA(isA<StateError>()),
    );
  });

  test('attachmentPut validates server progress and returned ref', () async {
    final h = _AttachmentHarness();
    addTearDown(h.dispose);
    h.respond = (method, args) {
      switch (method) {
        case 'helloConversationV4':
          return {'connectionId': 'conn-1'};
        case 'initializeConversationV4':
          return {};
        case 'attachmentBeginV4':
          return {'nextChunkIndex': 0};
        case 'attachmentChunkV4':
          return {'nextChunkIndex': 1};
        case 'attachmentCommitV4':
          return {'ref': 'ref-1'};
      }
      return {};
    };

    final descriptor = await h.transport.attachmentPut(
      's1',
      fileName: 'a.txt',
      mime: 'text/plain',
      bytes: Uint8List.fromList([97]),
    );
    expect(descriptor['ref'], 'ref-1');

    final invalid = _AttachmentHarness();
    addTearDown(invalid.dispose);
    invalid.respond = (method, args) {
      switch (method) {
        case 'helloConversationV4':
          return {'connectionId': 'conn-1'};
        case 'initializeConversationV4':
          return {};
        case 'attachmentBeginV4':
          return {'nextChunkIndex': 2};
      }
      return {};
    };
    await expectLater(
      invalid.transport.attachmentPut(
        's1',
        fileName: 'a.txt',
        mime: 'text/plain',
        bytes: Uint8List.fromList([97]),
      ),
      throwsA(isA<StateError>()),
    );
  });

  test('attachmentPut rejects a committed response without a ref', () async {
    final h = _AttachmentHarness();
    addTearDown(h.dispose);
    h.respond = (method, args) {
      switch (method) {
        case 'helloConversationV4':
          return {'connectionId': 'conn-1'};
        case 'initializeConversationV4':
          return {};
        case 'attachmentBeginV4':
          return {'state': 'committed'};
      }
      return {};
    };

    await expectLater(
      h.transport.attachmentPut(
        's1',
        fileName: 'a.txt',
        mime: 'text/plain',
        bytes: Uint8List.fromList([97]),
      ),
      throwsA(isA<StateError>()),
    );
  });
}
