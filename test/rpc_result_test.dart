import 'package:flutter_test/flutter_test.dart';
import 'package:zflow/protocol/rpc_result.dart';

void main() {
  group('rpcStatusOf', () {
    test('reads string status from a map', () {
      expect(rpcStatusOf({'status': 'accepted'}), 'accepted');
      expect(rpcStatusOf({'status': 'rejected'}), 'rejected');
    });

    test('returns null for missing, non-string status or non-map', () {
      expect(rpcStatusOf(const <String, dynamic>{}), isNull);
      expect(rpcStatusOf({'status': 3}), isNull);
      expect(rpcStatusOf(null), isNull);
      expect(rpcStatusOf(<dynamic>['accepted']), isNull);
      expect(rpcStatusOf('accepted'), isNull);
    });
  });

  group('isRpcSuccess', () {
    test('accepts the three idempotent statuses', () {
      for (final status in const ['accepted', 'noop', 'duplicate']) {
        expect(isRpcSuccess({'status': status}), isTrue,
            reason: status);
        expect(
            isRpcSuccess({'status': status}, requireStatus: true), isTrue,
            reason: status);
      }
    });

    test('rejects explicit failure statuses', () {
      for (final status in const ['rejected', 'stale', 'error', 'failed']) {
        expect(isRpcSuccess({'status': status}), isFalse, reason: status);
        expect(isRpcRejected({'status': status}), isTrue, reason: status);
      }
    });

    test('treats missing status as compatible success by default', () {
      // Direct/void RPCs return payloads without a status field.
      expect(isRpcSuccess(const <String, dynamic>{}), isTrue);
      expect(isRpcSuccess(null), isTrue);
      expect(isRpcSuccess(<dynamic>[]), isTrue);
      expect(isRpcSuccess('ok'), isTrue);
    });

    test('requireStatus rejects responses without a status', () {
      expect(
          isRpcSuccess(const <String, dynamic>{}, requireStatus: true), isFalse);
      expect(isRpcSuccess(null, requireStatus: true), isFalse);
      expect(
          isRpcSuccess({'status': 3}, requireStatus: true), isFalse);
    });

    test('isRpcRejected is the complement of isRpcSuccess', () {
      for (final res in const [
        null,
        'ok',
        {'status': 'accepted'},
        {'status': 'noop'},
        {'status': 'duplicate'},
        {'status': 'rejected'},
        <String, dynamic>{},
      ]) {
        expect(isRpcRejected(res), !isRpcSuccess(res), reason: '$res');
      }
    });
  });

  group('rpcFailureReason', () {
    test('prefers reasonCode, then message, then status', () {
      expect(
        rpcFailureReason(
            {'status': 'rejected', 'reasonCode': 'busy', 'message': 'm'}),
        'busy',
      );
      expect(rpcFailureReason({'status': 'rejected', 'message': 'nope'}),
          'nope');
      expect(rpcFailureReason({'status': 'stale'}), 'stale');
    });

    test('falls back to rejected when nothing is present', () {
      expect(rpcFailureReason(const <String, dynamic>{}), 'rejected');
    });

    test('stringifies non-map results', () {
      expect(rpcFailureReason(null), 'null');
      expect(rpcFailureReason('boom'), 'boom');
    });
  });
}
