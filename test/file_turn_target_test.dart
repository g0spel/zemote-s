import 'package:flutter_test/flutter_test.dart';

import 'package:zflow/protocol/channel_client.dart';
import 'package:zflow/protocol/conversation.dart';
import 'package:zflow/ui/chat_page.dart';

void main() {
  group('latestCompletedTurn', () {
    test('picks the last completedSuccess turnHeader', () {
      final rows = [
        {
          'kind': 'turnHeader',
          'rowId': 1,
          'entityId': 'e1',
          'state': 'completedSuccess',
        },
        {'kind': 'userInput', 'rowId': 2, 'text': 'hi'},
        {
          'kind': 'turnHeader',
          'rowId': 3,
          'entityId': 'e3',
          'state': 'completedSuccess',
        },
      ];
      final turn = latestCompletedTurn(rows);
      expect(turn, isNotNull);
      expect(turn!['rowId'], 3);
    });

    test('skips running / failed / interrupted turns and bare headers', () {
      final rows = [
        {
          'kind': 'turnHeader',
          'rowId': 1,
          'entityId': 'e1',
          'state': 'completedSuccess',
        },
        {
          'kind': 'turnHeader',
          'rowId': 2,
          'entityId': 'e2',
          'state': 'failed',
        },
        {
          'kind': 'turnHeader',
          'rowId': 3,
          'entityId': 'e3',
          'state': 'completedInterrupted',
        },
        {
          'kind': 'turnHeader',
          'rowId': 4,
          'entityId': 'e4',
          'state': 'running',
        },
        {
          'kind': 'turnHeader',
          'rowId': 5,
          'state': 'completedSuccess', // no entityId — unusable target
        },
      ];
      final turn = latestCompletedTurn(rows);
      expect(turn!['rowId'], 1);
    });

    test('running-only conversation yields null (nothing to query)', () {
      final rows = [
        {
          'kind': 'turnHeader',
          'rowId': 1,
          'entityId': 'e1',
          'state': 'running',
        },
      ];
      expect(latestCompletedTurn(rows), isNull);
      expect(latestCompletedTurn(const []), isNull);
    });
  });

  group('isStaleConversationError', () {
    test('matches proto.stale* codes in message or data', () {
      expect(
          isStaleConversationError(
              ChannelRpcError('proto.staleRevision', null)),
          isTrue);
      expect(
          isStaleConversationError(ChannelRpcError('proto.staleLogEpoch', null)),
          isTrue);
      expect(
          isStaleConversationError(
              ChannelRpcError('query rejected', {'reason': 'proto.staleTarget'})),
          isTrue);
    });

    test('other errors are not stale', () {
      expect(
          isStaleConversationError(
              ChannelRpcError('guard.actionUnavailable', null)),
          isFalse);
      expect(isStaleConversationError(StateError('proto.staleRevision')),
          isFalse);
    });
  });
}
