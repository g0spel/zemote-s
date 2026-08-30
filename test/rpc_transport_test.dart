import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:zflow/protocol/crc32.dart';
import 'package:zflow/protocol/rpc_transport.dart';

void main() {
  late List<Map<String, dynamic>> sent;
  late RpcFrameTransport transport;
  late List<Uint8List> received;

  setUp(() {
    sent = [];
    received = [];
    transport = RpcFrameTransport(
      bridgeSessionId: 'bridge-1',
      sendPayload: (p) => sent.add(p),
    );
    transport.messages.listen((msg) => received.add(msg));
  });

  tearDown(() {
    transport.dispose();
  });

  test('send single-fragment message and receive via acceptPayload', () async {
    final received = <Uint8List>[];
    final transport = RpcFrameTransport(
      bridgeSessionId: 'bridge-1',
      sendPayload: (_) {},
    );
    transport.messages.listen((msg) => received.add(msg));

    final payload = Uint8List.fromList([1, 2, 3, 4, 5]);

    transport.acceptPayload({
      'zcode_type': 'rpc-frame',
      'bridgeSessionId': 'bridge-1',
      'seq': 1,
      'messageSeq': 1,
      'fragmentIndex': 0,
      'fragmentCount': 1,
      'messageBytes': 5,
      'dataBase64': base64.encode(payload),
    });
    await Future.delayed(Duration.zero);
    expect(received, hasLength(1));
    expect(received[0], [1, 2, 3, 4, 5]);
    await transport.dispose();
  });

  test('multi-fragment message roundtrip', () async {
    final sent = <Map<String, dynamic>>[];
    final received = <Uint8List>[];
    final transport = RpcFrameTransport(
      bridgeSessionId: 'bridge-1',
      sendPayload: (p) => sent.add(p),
    );
    transport.messages.listen((msg) => received.add(msg));

    final payload = Uint8List(1024 * 1024 + 100);
    for (var i = 0; i < payload.length; i++) {
      payload[i] = (i % 256);
    }
    transport.sendMessage(payload);
    expect(sent, hasLength(3)); // 2 full + 1 partial fragment

    final frames = List<Map<String, dynamic>>.from(sent.reversed);
    for (final frame in frames) {
      transport.acceptPayload(frame);
    }
    await Future.delayed(Duration.zero);
    expect(received, hasLength(1));
    expect(received[0], payload);
    await transport.dispose();
  });

  test('rpc-frame-ack is consumed', () {
    expect(
      transport.acceptPayload({
        'zcode_type': 'rpc-frame-ack',
        'bridgeSessionId': 'bridge-1',
      }),
      isTrue,
    );
  });

  test('non-rpc-frame passes through unconsumed', () {
    expect(
      transport.acceptPayload({'zcode_type': 'workspace-list-updated'}),
      isFalse,
    );
  });

  test('mismatched bridgeSessionId is not consumed', () {
    expect(
      transport.acceptPayload({
        'zcode_type': 'rpc-frame',
        'bridgeSessionId': 'other-bridge',
      }),
      isFalse,
    );
  });

  test('invalid base64 data is handled gracefully', () {
    expect(
      transport.acceptPayload({
        'zcode_type': 'rpc-frame',
        'bridgeSessionId': 'bridge-1',
        'messageSeq': 1,
        'fragmentIndex': 0,
        'fragmentCount': 1,
        'messageBytes': 5,
        'dataBase64': '!!!not-valid-base64!!!',
      }),
      isTrue,
    );
    expect(received, isEmpty);
  });

  test('missing required fields returns consumed without crash', () {
    expect(
      transport.acceptPayload({
        'zcode_type': 'rpc-frame',
        'bridgeSessionId': 'bridge-1',
      }),
      isTrue,
    );
    expect(received, isEmpty);
  });

  test('checksum mismatch does not emit message', () {
    final payload = Uint8List.fromList([1, 2, 3]);

    transport.acceptPayload({
      'zcode_type': 'rpc-frame',
      'bridgeSessionId': 'bridge-1',
      'messageSeq': 1,
      'fragmentIndex': 0,
      'fragmentCount': 1,
      'messageBytes': 3,
      'dataBase64': base64.encode(payload),
      'checksum': {'algorithm': 'crc32', 'value': '00000000'},
    });
    expect(received, isEmpty);
  });

  test('ack is sent on successful assembly', () {
    final payload = Uint8List.fromList([7, 8, 9]);
    final checksum = Crc32.hexOf(payload);

    sent.clear();
    transport.acceptPayload({
      'zcode_type': 'rpc-frame',
      'bridgeSessionId': 'bridge-1',
      'messageSeq': 1,
      'fragmentIndex': 0,
      'fragmentCount': 1,
      'messageBytes': 3,
      'dataBase64': base64.encode(payload),
      'checksum': {'algorithm': 'crc32', 'value': checksum},
    });

    final ack = sent.firstWhere(
      (p) => p['zcode_type'] == 'rpc-frame-ack',
      orElse: () => <String, dynamic>{},
    );
    expect(ack['zcode_type'], 'rpc-frame-ack');
    expect(ack['ackMessageSeq'], 1);
    expect(ack['bridgeSessionId'], 'bridge-1');
  });

  test('sendMessage throws on empty payload', () {
    expect(
      () => transport.sendMessage(Uint8List(0)),
      throwsA(isA<StateError>()),
    );
  });

  test('disposed transport ignores late frames and sends nothing', () async {
    final localSent = <Map<String, dynamic>>[];
    final localReceived = <Uint8List>[];
    final t = RpcFrameTransport(
      bridgeSessionId: 'bridge-disposed',
      sendPayload: localSent.add,
    );
    t.messages.listen(localReceived.add);
    await t.dispose();

    t.sendMessage(Uint8List.fromList([1, 2, 3]));
    expect(
      t.acceptPayload({
        'zcode_type': 'rpc-frame',
        'bridgeSessionId': 'bridge-disposed',
        'messageSeq': 1,
        'fragmentIndex': 0,
        'fragmentCount': 1,
        'messageBytes': 3,
        'dataBase64': base64.encode(Uint8List.fromList([1, 2, 3])),
      }),
      isTrue,
    );
    await Future<void>.delayed(Duration.zero);
    expect(localSent, isEmpty);
    expect(localReceived, isEmpty);
  });

  test('dispose is idempotent', () async {
    await transport.dispose();
    await transport.dispose();
    transport.sendMessage(Uint8List.fromList([1]));
    expect(sent, isEmpty);
  });

  test('rejects invalid inbound fragment bounds without allocating', () {
    expect(
      transport.acceptPayload({
        'zcode_type': 'rpc-frame',
        'bridgeSessionId': 'bridge-1',
        'messageSeq': 9,
        'fragmentIndex': 0,
        'fragmentCount': RpcFrameTransport.maxFragments + 1,
        'messageBytes': 1,
        'dataBase64': base64.encode(Uint8List.fromList([1])),
      }),
      isTrue,
    );
    expect(received, isEmpty);
    expect(sent, isEmpty);
  });

  test('drops an assembly when fragment metadata changes', () {
    final chunk = base64.encode(Uint8List.fromList([1]));
    transport.acceptPayload({
      'zcode_type': 'rpc-frame',
      'bridgeSessionId': 'bridge-1',
      'messageSeq': 10,
      'fragmentIndex': 0,
      'fragmentCount': 2,
      'messageBytes': 2,
      'dataBase64': chunk,
    });
    transport.acceptPayload({
      'zcode_type': 'rpc-frame',
      'bridgeSessionId': 'bridge-1',
      'messageSeq': 10,
      'fragmentIndex': 1,
      'fragmentCount': 3,
      'messageBytes': 3,
      'dataBase64': chunk,
    });
    transport.acceptPayload({
      'zcode_type': 'rpc-frame',
      'bridgeSessionId': 'bridge-1',
      'messageSeq': 10,
      'fragmentIndex': 1,
      'fragmentCount': 2,
      'messageBytes': 2,
      'dataBase64': chunk,
    });
    expect(received, isEmpty);
    expect(sent, isEmpty);
  });

  test('rejects assembled length mismatch', () async {
    transport.acceptPayload({
      'zcode_type': 'rpc-frame',
      'bridgeSessionId': 'bridge-1',
      'messageSeq': 11,
      'fragmentIndex': 0,
      'fragmentCount': 1,
      'messageBytes': 2,
      'dataBase64': base64.encode(Uint8List.fromList([1])),
    });
    await Future<void>.delayed(Duration.zero);
    expect(received, isEmpty);
    expect(sent.where((p) => p['zcode_type'] == 'rpc-frame-ack'), isEmpty);
  });

  test('reassembly with out-of-order fragments', () async {
    final received = <Uint8List>[];
    final transport = RpcFrameTransport(
      bridgeSessionId: 'bridge-1',
      sendPayload: (_) {},
    );
    transport.messages.listen((msg) => received.add(msg));

    final payload = Uint8List.fromList(List.generate(200, (i) => i % 256));

    // Simulate two fragments arriving out of order
    transport.acceptPayload({
      'zcode_type': 'rpc-frame',
      'bridgeSessionId': 'bridge-1',
      'messageSeq': 1,
      'fragmentIndex': 1,
      'fragmentCount': 2,
      'messageBytes': 200,
      'dataBase64': base64.encode(Uint8List.sublistView(payload, 100, 200)),
    });
    expect(received, isEmpty); // not complete yet

    transport.acceptPayload({
      'zcode_type': 'rpc-frame',
      'bridgeSessionId': 'bridge-1',
      'messageSeq': 1,
      'fragmentIndex': 0,
      'fragmentCount': 2,
      'messageBytes': 200,
      'dataBase64': base64.encode(Uint8List.sublistView(payload, 0, 100)),
    });
    await Future.delayed(Duration.zero);
    expect(received, hasLength(1));
    expect(received[0], payload);
    await transport.dispose();
  });

  test('identity includes bridgeGeneration and recoveryId', () {
    final t = RpcFrameTransport(
      bridgeSessionId: 'b1',
      bridgeGeneration: 5,
      recoveryId: 'rec-99',
      sendPayload: (_) {},
    );
    expect(t.bridgeGeneration, 5);
    expect(t.recoveryId, 'rec-99');
    t.dispose();
  });
}
