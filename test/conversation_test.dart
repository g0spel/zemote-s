import 'package:flutter_test/flutter_test.dart';

import 'package:zflow/protocol/conversation.dart';

void main() {
  group('ConversationState delta application', () {
    late ConversationState state;

    setUp(() {
      state = ConversationState();
    });

    test('snapshot clears and replaces state', () {
      state.applyFrame({
        'payload': {
          'kind': 'snapshot',
          'snapshot': {
            'logEpoch': 'epoch-1',
            'revision': 5,
            'rows': {
              'window': [
                {'rowId': 1, 'kind': 'user', 'text': 'hello'},
                {'rowId': 2, 'kind': 'assistant', 'text': 'hi'},
              ],
              'totalCount': 2,
              'firstRowId': 1,
            },
          },
        },
        'toSeq': 10,
      }, onGap: () => fail('should not gap on snapshot'));

      expect(state.rows, hasLength(2));
      expect(state.rows[0]['text'], 'hello');
      expect(state.seq, 10);
      expect(state.logEpoch, 'epoch-1');
      expect(state.revision, 5);
      expect(state.firstRowId, 1);
      expect(state.totalCount, 2);
      expect(state.ready, isTrue);
    });

    test('row.appended adds to end', () {
      _injectSnapshot(state, seq: 1);
      state.applyFrame({
        'payload': {
          'kind': 'deltas',
          'deltas': [
            {'op': 'row.appended', 'row': {'rowId': 99, 'kind': 'user', 'text': 'new'}},
          ],
        },
        'fromSeq': 1,
        'toSeq': 2,
      }, onGap: () => fail('should not gap'));

      expect(state.rows, hasLength(1));
      expect(state.rows[0]['rowId'], 99);
      expect(state.seq, 2);
      expect(state.totalCount, 1);
    });

    test('row.upserted replaces existing row', () {
      _injectSnapshot(state, rows: [
        {'rowId': 1, 'kind': 'user', 'text': 'old'},
      ]);

      state.applyFrame({
        'payload': {
          'kind': 'deltas',
          'deltas': [
            {'op': 'row.upserted', 'row': {'rowId': 1, 'kind': 'user', 'text': 'updated'}},
          ],
        },
        'fromSeq': 5,
        'toSeq': 6,
      }, onGap: () => fail('should not gap'));

      expect(state.rows, hasLength(1));
      expect(state.rows[0]['text'], 'updated');
    });

    test('row.removed removes from rowId upward', () {
      _injectSnapshot(state, rows: [
        {'rowId': 1, 'kind': 'user', 'text': 'a'},
        {'rowId': 2, 'kind': 'assistant', 'text': 'b'},
        {'rowId': 3, 'kind': 'user', 'text': 'c'},
      ], totalCount: 3);

      state.applyFrame({
        'payload': {
          'kind': 'deltas',
          'deltas': [
            {'op': 'row.removed', 'fromRowId': 2},
          ],
        },
        'fromSeq': 5,
        'toSeq': 6,
      }, onGap: () => fail('should not gap'));

      expect(state.rows, hasLength(1));
      expect(state.rows[0]['rowId'], 1);
      // totalCount was 3, 2 rows removed (rowId>=2), so remaining = 1
      // clamp: (3-2).clamp(0, 1<<31) = 1
      expect(state.totalCount, 1);
    });

    test('row.delta appends text', () {
      _injectSnapshot(state, rows: [
        {'rowId': 1, 'kind': 'assistantText', 'text': 'Hello'},
      ]);

      state.applyFrame({
        'payload': {
          'kind': 'deltas',
          'deltas': [
            {'op': 'row.delta', 'rowId': 1, 'path': 'text', 'append': ' World'},
          ],
        },
        'fromSeq': 5,
        'toSeq': 6,
      }, onGap: () => fail('should not gap'));

      expect(state.rows[0]['text'], 'Hello World');
    });

    test('row.delta on toolCall inputText', () {
      _injectSnapshot(state, rows: [
        {'rowId': 1, 'kind': 'toolCall', 'inputText': 'ls'},
      ]);

      state.applyFrame({
        'payload': {
          'kind': 'deltas',
          'deltas': [
            {'op': 'row.delta', 'rowId': 1, 'path': 'inputText', 'append': ' -la'},
          ],
        },
        'fromSeq': 5,
        'toSeq': 6,
      }, onGap: () => fail('should not gap'));

      expect(state.rows[0]['inputText'], 'ls -la');
    });

    test('row.delta on toolCall output.text merges into nested map', () {
      _injectSnapshot(state, rows: [
        {
          'rowId': 1,
          'kind': 'toolCall',
          'output': {'text': 'file1'},
        },
      ]);

      state.applyFrame({
        'payload': {
          'kind': 'deltas',
          'deltas': [
            {'op': 'row.delta', 'rowId': 1, 'path': 'output.text', 'append': '\nfile2'},
          ],
        },
        'fromSeq': 5,
        'toSeq': 6,
      }, onGap: () => fail('should not gap'));

      final output = state.rows[0]['output'] as Map;
      expect(output['text'], 'file1\nfile2');
    });

    test('state.updated merges into snapshot', () {
      _injectSnapshot(state, revision: 5, snapshot: {
        'control': {'phase': 'idle', 'canStop': false},
      });

      state.applyFrame({
        'payload': {
          'kind': 'deltas',
          'deltas': [
            {'op': 'state.updated', 'patch': {'revision': 6}},
          ],
        },
        'fromSeq': 5,
        'toSeq': 6,
      }, onGap: () => fail('should not gap'));

      expect(state.revision, 6);
      expect(state.phase, 'idle'); // phase lives under control, not top-level
    });

    test('state.updated before snapshot is buffered', () {
      state.applyFrame({
        'payload': {
          'kind': 'deltas',
          'deltas': [
            {'op': 'state.updated', 'patch': {'revision': 3}},
          ],
        },
        'fromSeq': 0,
        'toSeq': 1,
      }, onGap: () => fail('should not gap'));

      // Still pending, snapshot not yet arrived
      expect(state.revision, 0);

      // Snapshot arrives — buffered patch merges
      _injectSnapshot(state, revision: 1, seq: 2);
      expect(state.revision, 3);
    });

    test('fromSeq mismatch triggers onGap', () {
      _injectSnapshot(state, seq: 10);

      var gapCalled = false;
      state.applyFrame({
        'payload': {
          'kind': 'deltas',
          'deltas': [],
        },
        'fromSeq': 5, // mismatch — current seq is 10
        'toSeq': 11,
      }, onGap: () => gapCalled = true);

      expect(gapCalled, isTrue);
      expect(state.seq, 10); // unchanged
    });

    test('optimisticRowUpdate mutates in place', () {
      _injectSnapshot(state, rows: [
        {'rowId': 1, 'kind': 'assistant', 'feedback': null},
      ]);

      state.optimisticRowUpdate(1, {'feedback': 'like'});
      expect(state.rows[0]['feedback'], 'like');
    });

    test('optimisticRemoveQueueItem removes from queue items', () {
      _injectSnapshot(state, snapshot: {
        'revision': 1,
        'rows': {'window': [], 'totalCount': 0},
        'queue': {
          'items': [
            {'queueItemId': 'q1', 'text': 'a'},
            {'queueItemId': 'q2', 'text': 'b'},
          ],
        },
      });

      state.optimisticRemoveQueueItem('q1');
      final q = state.queue;
      final items = q?['items'] as List;
      expect(items, hasLength(1));
      expect(items[0]['queueItemId'], 'q2');
    });

    test('canLoadOlder is true when more rows exist', () {
      _injectSnapshot(state, rows: [
        {'rowId': 10, 'kind': 'user', 'text': 'latest'},
      ], totalCount: 100, firstRowId: 10);

      expect(state.canLoadOlder, isTrue);
    });

    test('canLoadOlder is false when all rows loaded', () {
      _injectSnapshot(state, rows: [
        {'rowId': 1, 'kind': 'user', 'text': 'first'},
      ], totalCount: 1, firstRowId: 1);

      expect(state.canLoadOlder, isFalse);
    });

    test('prependOlderRows inserts before existing', () {
      _injectSnapshot(state, rows: [
        {'rowId': 3, 'kind': 'assistant', 'text': 'c'},
      ], totalCount: 3, firstRowId: 3);

      state.prependOlderRows([
        {'rowId': 1, 'kind': 'user', 'text': 'a'},
        {'rowId': 2, 'kind': 'assistant', 'text': 'b'},
      ], 1);

      expect(state.rows, hasLength(3));
      expect(state.rows[0]['rowId'], 1);
      expect(state.rows[1]['rowId'], 2);
      expect(state.rows[2]['rowId'], 3);
      expect(state.firstRowId, 1);
    });

    test('prependOlderRows deduplicates by rowId', () {
      _injectSnapshot(state, rows: [
        {'rowId': 2, 'kind': 'assistant', 'text': 'existing'},
      ]);

      state.prependOlderRows([
        {'rowId': 1, 'kind': 'user', 'text': 'old'},
        {'rowId': 2, 'kind': 'user', 'text': 'dup'},
      ], 1);

      expect(state.rows, hasLength(2));
      expect(state.rows[0]['text'], 'old');
      expect(state.rows[1]['text'], 'existing');
    });

    test('computed properties from snapshot', () {
      _injectSnapshot(state, snapshot: {
        'revision': 5,
        'control': {'phase': 'running', 'canStop': true},
        'config': {'model': 'GLM-5.2', 'thought': 'max', 'mode': 'build'},
        'usage': {'contextWindow': {'usedTokens': 100, 'maxTokens': 200000}},
      });

      expect(state.isRunning, isTrue);
      expect(state.canStop, isTrue);
      expect(state.currentModel, 'GLM-5.2');
      expect(state.currentThought, 'max');
      expect(state.currentMode, 'build');
      expect(state.usage, isNotNull);
    });

    test('draft phase is not running', () {
      _injectSnapshot(state, snapshot: {
        'revision': 1,
        'control': {'phase': 'draft'},
        'rows': {'window': [], 'totalCount': 0},
      });

      expect(state.isRunning, isFalse);
      expect(state.canStop, isFalse);
    });
  });

  group('SessionsIndexState delta application', () {
    late SessionsIndexState state;
    late int gapCount;

    void onGap() => gapCount++;

    setUp(() {
      state = SessionsIndexState();
      gapCount = 0;
    });

    test('snapshot loads sessions', () {
      state.applyFrame({
        'payload': {
          'kind': 'snapshot',
          'snapshot': {
            'workspaceId': 'ws-1',
            'logEpoch': 'epoch-1',
            'sessions': [
              {
                'sessionId': 's1',
                'title': 'Task A',
                'phase': 'running',
                'lastActivityAt': 1000,
                'createdAt': 900,
              },
              {
                'sessionId': 's2',
                'title': 'Task B',
                'phase': 'completed',
                'lastActivityAt': 2000,
                'createdAt': 800,
              },
            ],
          },
        },
        'toSeq': 5,
      }, onGap: onGap);

      expect(state.sessions, hasLength(2));
      expect(state.ready, isTrue);
      expect(state.workspaceId, 'ws-1');
      expect(gapCount, 0);
    });

    test('list is sorted by lastActivityAt descending', () {
      state.applyFrame({
        'payload': {
          'kind': 'snapshot',
          'snapshot': {
            'sessions': [
              {'sessionId': 'older', 'lastActivityAt': 100, 'createdAt': 50, 'phase': 'draft', 'title': 'Old'},
              {'sessionId': 'newer', 'lastActivityAt': 200, 'createdAt': 50, 'phase': 'draft', 'title': 'New'},
            ],
          },
        },
        'toSeq': 1,
      }, onGap: onGap);

      final list = state.list;
      expect(list[0].sessionId, 'newer');
      expect(list[1].sessionId, 'older');
    });

    test('session.upserted delta', () {
      _injectSessionsSnapshot(state);
      state.applyFrame({
        'payload': {
          'kind': 'deltas',
          'deltas': [
            {
              'op': 'session.upserted',
              'session': {
                'sessionId': 'new-task',
                'title': 'Fresh',
                'phase': 'draft',
                'lastActivityAt': 500,
                'createdAt': 400,
              },
            },
          ],
        },
        'fromSeq': 1,
        'toSeq': 2,
      }, onGap: onGap);

      expect(state.sessions, hasLength(1));
      expect(state.sessions['new-task']!.title, 'Fresh');
    });

    test('session.removed delta', () {
      _injectSessionsSnapshot(state, sessions: [
        {'sessionId': 's1', 'title': 'T1', 'phase': 'draft', 'lastActivityAt': 0, 'createdAt': 0},
        {'sessionId': 's2', 'title': 'T2', 'phase': 'draft', 'lastActivityAt': 0, 'createdAt': 0},
      ]);

      state.applyFrame({
        'payload': {
          'kind': 'deltas',
          'deltas': [
            {'op': 'session.removed', 'sessionId': 's1'},
          ],
        },
        'fromSeq': 1,
        'toSeq': 2,
      }, onGap: onGap);

      expect(state.sessions, hasLength(1));
      expect(state.sessions.containsKey('s1'), isFalse);
      expect(state.sessions.containsKey('s2'), isTrue);
    });

    test('session entry parses parentSessionId (side chat marker)', () {
      state.applyFrame({
        'payload': {
          'kind': 'snapshot',
          'snapshot': {
            'sessions': [
              {
                'sessionId': 'side-1',
                'parentSessionId': 'main-1',
                'title': 'Side chat',
                'phase': 'running',
                'lastActivityAt': 100,
                'createdAt': 90,
              },
              {
                'sessionId': 'main-1',
                'title': 'Main task',
                'phase': 'draft',
                'lastActivityAt': 200,
                'createdAt': 50,
              },
            ],
          },
        },
        'toSeq': 1,
      }, onGap: onGap);

      expect(state.sessions['side-1']!.parentSessionId, 'main-1');
      expect(state.sessions['main-1']!.parentSessionId, isNull);
    });
  });


  group('arrival stamps (_zemoteTs)', () {
    late ConversationState state;

    setUp(() {
      state = ConversationState();
    });

    test('row.appended stamps arrival time', () {
      _injectSnapshot(state, seq: 1);
      state.applyFrame({
        'payload': {
          'kind': 'deltas',
          'deltas': [
            {'op': 'row.appended', 'row': {'rowId': 7, 'kind': 'userInput', 'text': 'hi'}},
          ],
        },
        'fromSeq': 1,
        'toSeq': 2,
      }, onGap: () => fail('no gap'));
      final ts = state.rows.single['_zemoteTs'];
      expect(ts, isA<int>());
      expect(ts, greaterThan(0));
    });

    test('snapshot replacement carries stamps by rowId', () {
      _injectSnapshot(state, seq: 1);
      state.applyFrame({
        'payload': {
          'kind': 'deltas',
          'deltas': [
            {'op': 'row.appended', 'row': {'rowId': 7, 'kind': 'userInput', 'text': 'hi'}},
          ],
        },
        'fromSeq': 1,
        'toSeq': 2,
      }, onGap: () => fail('no gap'));
      final stamped = state.rows.single['_zemoteTs'];

      // Server resyncs with a fresh snapshot containing the same row.
      state.applyFrame({
        'payload': {
          'kind': 'snapshot',
          'snapshot': {
            'rows': {
              'window': [
                {'rowId': 1, 'kind': 'assistantText', 'text': 'history'},
                {'rowId': 7, 'kind': 'userInput', 'text': 'hi'},
              ],
              'totalCount': 2,
              'firstRowId': 1,
            },
          },
        },
        'toSeq': 3,
      }, onGap: () => fail('no gap'));

      final byId = {for (final r in state.rows) r['rowId']: r};
      expect(byId[7]!['_zemoteTs'], stamped); // carried over
      expect(byId[1]!.containsKey('_zemoteTs'), isFalse); // history unstamped
    });

    test('resync snapshot keeps rows older than the tail window', () {
      // Initial tail window + paged-in history below the window head.
      _injectSnapshot(state, rows: [
        {'rowId': 50, 'kind': 'userInput', 'text': 'newest'},
      ], totalCount: 5, firstRowId: 1, seq: 1);
      state.prependOlderRows([
        {'rowId': 10, 'kind': 'assistantText', 'text': 'old A'},
        {'rowId': 20, 'kind': 'assistantText', 'text': 'old B'},
      ], 10);

      // Reconnect resync delivers a fresh TAIL snapshot; row 20 also
      // reappears inside the window (updated copy must win).
      state.applyFrame({
        'payload': {
          'kind': 'snapshot',
          'snapshot': {
            'rows': {
              'window': [
                {'rowId': 20, 'kind': 'assistantText', 'text': 'old B (upsert)'},
                {'rowId': 50, 'kind': 'userInput', 'text': 'newest'},
              ],
              'totalCount': 5,
              'firstRowId': 1,
            },
          },
        },
        'toSeq': 9,
      }, onGap: () => fail('no gap'));

      expect(state.rows.map((r) => r['rowId']), [10, 20, 50]);
      // The window's copy replaced the stale kept row.
      expect(
          state.rows
              .firstWhere((r) => r['rowId'] == 20)['text'],
          'old B (upsert)');
      expect(state.totalCount, 5);
    });

    test('empty snapshot window clears rows (session reset)', () {
      _injectSnapshot(state, rows: [
        {'rowId': 5, 'kind': 'userInput', 'text': 'x'},
      ], totalCount: 1, firstRowId: 1, seq: 1);
      state.applyFrame({
        'payload': {
          'kind': 'snapshot',
          'snapshot': {
            'rows': {'window': [], 'totalCount': 0, 'firstRowId': null},
          },
        },
        'toSeq': 2,
      }, onGap: () => fail('no gap'));
      expect(state.rows, isEmpty);
    });

    test('row.upserted keeps the original stamp', () {
      _injectSnapshot(state, rows: [
        {'rowId': 1, 'kind': 'user', 'text': 'old'},
      ]);
      // Upsert of an unstamped row must not blow up on typed maps.
      state.applyFrame({
        'payload': {
          'kind': 'deltas',
          'deltas': [
            {'op': 'row.upserted', 'row': {'rowId': 1, 'kind': 'user', 'text': 'updated'}},
          ],
        },
        'fromSeq': 5,
        'toSeq': 6,
      }, onGap: () => fail('no gap'));
      expect(state.rows.single['text'], 'updated');
      expect(state.rows.single.containsKey('_zemoteTs'), isFalse);
    });
  });

  group('history paging to the earliest row', () {
    late ConversationState state;

    setUp(() {
      state = ConversationState();
    });

    /// Mirrors the host's getRowsRange exactly: rows with a SMALLER
    /// rowId than the cursor, last [limit] of them, plus hasMore.
    (List<Map<String, dynamic>>, bool) serverRowsRange(
        int? beforeRowId, int limit) {
      var pool = List<Map<String, dynamic>>.generate(
          250, (i) => {'rowId': i + 1, 'kind': 'assistantText', 'text': 'm$i'});
      if (beforeRowId != null) {
        pool = pool.where((r) => (r['rowId'] as num) < beforeRowId).toList();
      }
      final page =
          pool.length > limit ? pool.sublist(pool.length - limit) : pool;
      return (page, pool.length > page.length);
    }

    test('pages down to the first row of the conversation', () {
      // Wire snapshot: 60-row tail window, totalCount/firstRowId of the
      // FULL projection (host semantics).
      final tail = List<Map<String, dynamic>>.generate(
          60,
          (i) =>
              {'rowId': i + 191, 'kind': 'assistantText', 'text': 'm${i + 190}'});
      _injectSnapshot(state, rows: tail, totalCount: 250, firstRowId: 1, seq: 1);

      expect(state.canLoadOlder, isTrue, reason: 'totalCount 250 vs 60 rows');
      // The snapshot's firstRowId is the projection head — the OLD cursor
      // bug: using it as beforeRowId yields an empty page forever.
      final (bugged, _) = serverRowsRange(state.firstRowId, 60);
      expect(bugged, isEmpty,
          reason: 'projection-head cursor filters everything out');

      // Drive the fixed loop: cursor = oldest held row, until hasMore
      // says the batch was the last.
      var guard = 0;
      while (state.canLoadOlder && guard++ < 10) {
        final (page, hasMore) = serverRowsRange(state.oldestRowId, 60);
        state.prependOlderRows(page, null);
        if (!hasMore) state.historyExhausted = true;
      }

      expect(state.rows.first['rowId'], 1, reason: 'earliest row reached');
      expect(state.rows, hasLength(250));
      expect(state.rows.last['rowId'], 250);
      expect(state.canLoadOlder, isFalse, reason: 'exhausted retires it');
      // Rows stay ordered and deduped across pages.
      for (var i = 0; i < state.rows.length; i++) {
        expect(state.rows[i]['rowId'], i + 1);
      }
    });

    test('resync mid-paging keeps the already-loaded older rows', () {
      final tail = List<Map<String, dynamic>>.generate(
          60, (i) => {'rowId': i + 191, 'kind': 'assistantText', 'text': 'm'});
      _injectSnapshot(state, rows: tail, totalCount: 250, firstRowId: 1, seq: 1);
      final (page, _) = serverRowsRange(state.oldestRowId, 60);
      state.prependOlderRows(page, null);
      expect(state.rows.first['rowId'], 131);

      // Reconnect resync: fresh tail window (two new rows arrived).
      _injectSnapshot(state,
          rows: List<Map<String, dynamic>>.generate(
              60, (i) => {'rowId': i + 193, 'kind': 'assistantText', 'text': 'm'}),
          totalCount: 252,
          firstRowId: 1,
          seq: 5);

      expect(state.rows.first['rowId'], 131, reason: 'paged-in history kept');
      expect(state.rows.last['rowId'], 252);
      // The cursor still advances from the kept head.
      expect(state.oldestRowId, 131);
      expect(state.canLoadOlder, isTrue);
    });

    test('oldestRowId falls back to firstRowId on an empty row list', () {
      _injectSnapshot(state,
          rows: const [], totalCount: 10, firstRowId: 3, seq: 1);
      expect(state.oldestRowId, 3);
    });
  });

}


void _injectSnapshot(
  ConversationState state, {
  int seq = 5,
  int revision = 1,
  List<Map<String, dynamic>>? rows,
  int totalCount = 0,
  int? firstRowId,
  Map<String, dynamic>? snapshot,
}) {
  final snap = {
    'revision': revision,
    'rows': {
      'window': rows ?? [],
      'totalCount': totalCount,
      if (firstRowId != null) 'firstRowId': firstRowId,
    },
    ...?snapshot,
  };
  state.applyFrame({
    'payload': {'kind': 'snapshot', 'snapshot': snap},
    'toSeq': seq,
  }, onGap: () => fail('unexpected gap'));
}

void _injectSessionsSnapshot(
  SessionsIndexState state, {
  List<Map<String, dynamic>>? sessions,
}) {
  final list = sessions ?? [];
  state.applyFrame({
    'payload': {
      'kind': 'snapshot',
      'snapshot': {'sessions': list},
    },
    'toSeq': 1,
  }, onGap: () => fail('unexpected gap'));
}
