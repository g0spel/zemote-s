import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:zflow/notifications/notifications.dart';
import 'package:zflow/notifications/task_notifier.dart';
import 'package:zflow/notifications/unread.dart';
import 'package:zflow/protocol/channel_client.dart';
import 'package:zflow/protocol/ipc_codec.dart';
import 'package:zflow/protocol/zflow_client.dart';
import 'package:zflow/state/background_prefs.dart';

class _RecordingNotifications extends Notifications {
  Future<void> Function(Map<String, dynamic> payload)? tapHandler;
  final List<({String channel, String title, String taskId})> events = [];

  @override
  Future<void> setTapHandler(
      Future<void> Function(Map<String, dynamic> payload)? handler) async {
    tapHandler = handler;
  }

  @override
  Future<void> setRunning(String title, String text) async {}

  @override
  Future<void> releaseRunning() async {}

  @override
  Future<void> notifyEvent({
    required String channel,
    required String title,
    required String text,
    required Map<String, dynamic> payload,
  }) async {
    events.add((
      channel: channel,
      title: title,
      taskId: payload['taskId'] as String? ?? '',
    ));
  }
}

Uint8List _frame(List<Object?> header, [Object? data]) {
  final writer = ValueWriter();
  encodeValue(writer, header);
  if (data != null) encodeValue(writer, data);
  return writer.toBytes();
}

int _listenerId(List<Uint8List> sent) {
  for (final body in sent) {
    final reader = ValueReader(body);
    final header = decodeValue(reader) as List;
    if (header[0] == ChannelClient.reqEventListen &&
        header[3] == 'onDynamicSessionsIndexFrame') {
      return header[1] as int;
    }
  }
  return -1;
}

void _pushSnapshot(
    ChannelClient channels, List<Uint8List> sent, String subId, int seq,
    List<Object?> sessions) {
  channels.handleMessage(_frame([
    ChannelClient.resEventFire,
    _listenerId(sent),
  ], {
    'kind': 'complete',
    'topic': 'sessions-index//ws',
    'subscriptionId': subId,
    'frame': {
      'subscriptionId': subId,
      'toSeq': seq,
      'payload': {
        'kind': 'snapshot',
        'snapshot': {'sessions': sessions},
      },
    },
  }));
}

Map<String, dynamic> _entry(
  String id,
  String phase, {
  Map<String, dynamic>? pendingInteraction,
}) =>
    {
      'sessionId': id,
      'title': '任务 $id',
      'phase': phase,
      'lastActivityAt': 1000,
      'createdAt': 1,
      'pendingInteraction': ?pendingInteraction,    };

/// 应答订阅握手（hello → initialize → subscribe ack）；按 wire id 去重，
/// 迭代推进直到 subscribe 应答完成。
Future<void> _handshake(
    ChannelClient channels, List<Uint8List> sent, String subId) async {
  final responded = <int>{};
  for (var round = 0; round < 6; round++) {
    for (final body in sent) {
      final reader = ValueReader(body);
      final header = decodeValue(reader) as List;
      if (header[0] != ChannelClient.reqPromise) continue;
      final id = header[1] as int;
      if (responded.contains(id)) continue;
      final method = header[3] as String;
      if (method == 'helloConversationV4' ||
          method == 'initializeConversationV4') {
        responded.add(id);
        channels.handleMessage(
            _frame([ChannelClient.resPromiseSuccess, id], {}));
      } else if (method == 'subscribeSessionsIndexV4') {
        responded.add(id);
        channels.handleMessage(_frame([
          ChannelClient.resPromiseSuccess,
          id,
        ], {
          'ack': {'subscriptionId': subId},
        }));
      }
    }
    await Future<void>.delayed(Duration.zero);
    if (responded.length >= 3) break;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('BackgroundPrefs', () {
    test('默认值：保活开、息屏在线开、三类通知全开', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = BackgroundPrefs.instance;
      prefs.resetForTest();
      expect(prefs.keepAliveEnabled, isTrue);
      expect(prefs.wakeLock, isTrue);
      expect(prefs.notifyApprovals, isTrue);
      expect(prefs.notifyCompletions, isTrue);
      expect(prefs.notifyFailures, isTrue);
    });

    test('修改落盘并可恢复', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = BackgroundPrefs.instance;
      prefs.resetForTest();
      await prefs.setKeepAliveEnabled(false);
      await prefs.setNotifyFailures(false);
      expect(prefs.keepAliveEnabled, isFalse);
      expect(prefs.notifyFailures, isFalse);
      final stored = SharedPreferences.getInstance()
          .then((p) => p.getBool('notify.failures'));
      expect(await stored, isFalse);
    });

    test('keepAliveDecision：开关且有机才跑', () {
      expect(
          keepAliveDecision(enabled: true, hasDevices: true),
          KeepAliveDecision.run);
      expect(
          keepAliveDecision(enabled: true, hasDevices: false),
          KeepAliveDecision.stop);
      expect(
          keepAliveDecision(enabled: false, hasDevices: true),
          KeepAliveDecision.stop);
    });
  });

  group('UnreadEvents', () {
    test('按任务计数、打开会话清对应项', () {
      final unread = UnreadEvents.instance..resetForTest();
      unread.add('a');
      unread.add('a');
      unread.add('b');
      expect(unread.total, 3);
      unread.clearTask('a');
      expect(unread.total, 1);
      unread.clearAll();
      expect(unread.total, 0);
    });
  });

  group('TaskNotifier 三重门控与类型路由', () {
    test('前台正看的会话不推，其余推；失败走失败开关', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = BackgroundPrefs.instance;
      prefs.resetForTest();
      final unread = UnreadEvents.instance..resetForTest();

      final sent = <Uint8List>[];
      final channels = ChannelClient(sendBody: sent.add);
      final bridge = BridgeSession.detached(
        {'workspaceKey': '/ws'},
        channels: channels,
      );
      addTearDown(bridge.dispose);
      channels.handleMessage(_frame(const [ChannelClient.resInitialize, 0]));

      final notifications = _RecordingNotifications();
      const subId = 'gate-sub';
      final notifier = TaskNotifier(
        bridge: bridge,
        scope: const {'workspacePath': '/ws'},
        notifications: notifications,
        visibleSessionId: () => 's2',
        prefs: prefs,
        unread: unread,
        onOpenTask: (taskId, title) async {},
      );
      final start = notifier.start();
      await Future<void>.delayed(Duration.zero);
      await _handshake(channels, sent, subId);
      await start;
      expect(notifier.isActive, isTrue);

      // 第一拍：三个任务都在运行。
      _pushSnapshot(channels, sent, subId, 1, [
        _entry('s1', 'running'),
        _entry('s2', 'running'),
        _entry('s3', 'running'),
      ]);
      await Future<void>.delayed(Duration.zero);
      expect(notifications.events, isEmpty,
          reason: 'running 快照本身不产生事件通知');

      // 第二拍：s1 完成、s2 失败、s3 挂起审批。
      // 前台正看 s2 → s2 的失败被门控抑制；s1/s3 照推。
      _pushSnapshot(channels, sent, subId, 2, [
        _entry('s1', 'completed'),
        _entry('s2', 'failed'),
        _entry('s3', 'running', pendingInteraction: {
          'interactionId': 'i1',
          'kind': 'permission',
          'toolName': 'bash',
        }),
      ]);
      await Future<void>.delayed(Duration.zero);

      expect(notifications.events, hasLength(2));
      expect(notifications.events[0].channel, 'completion');
      expect(notifications.events[0].taskId, 's1');
      expect(notifications.events[1].channel, 'approval');
      expect(notifications.events[1].taskId, 's3');
      expect(unread.total, 2);

      final disposeFuture = notifier.dispose();
      await Future<void>.delayed(Duration.zero);
      for (final body in sent) {
        final reader = ValueReader(body);
        final header = decodeValue(reader) as List;
        if (header[0] == ChannelClient.reqPromise &&
            header[3] == 'unsubscribeSessionsIndexV4') {
          channels.handleMessage(
              _frame([ChannelClient.resPromiseSuccess, header[1] as int], {}));
        }
      }
      await disposeFuture;
    });

    test('失败开关关闭时不推失败通知', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = BackgroundPrefs.instance;
      prefs.resetForTest();
      await prefs.setNotifyFailures(false);
      final unread = UnreadEvents.instance..resetForTest();

      final sent = <Uint8List>[];
      final channels = ChannelClient(sendBody: sent.add);
      final bridge = BridgeSession.detached(
        {'workspaceKey': '/ws'},
        channels: channels,
      );
      addTearDown(bridge.dispose);
      channels.handleMessage(_frame(const [ChannelClient.resInitialize, 0]));

      final notifications = _RecordingNotifications();
      const subId = 'gate-sub-2';
      final notifier = TaskNotifier(
        bridge: bridge,
        scope: const {'workspacePath': '/ws'},
        notifications: notifications,
        visibleSessionId: () => null,
        prefs: prefs,
        unread: unread,
        onOpenTask: (taskId, title) async {},
      );
      final start = notifier.start();
      await Future<void>.delayed(Duration.zero);
      await _handshake(channels, sent, subId);
      await start;

      _pushSnapshot(channels, sent, subId, 1, [_entry('s2', 'running')]);
      await Future<void>.delayed(Duration.zero);
      _pushSnapshot(channels, sent, subId, 2, [_entry('s2', 'failed')]);
      await Future<void>.delayed(Duration.zero);

      expect(notifications.events, isEmpty,
          reason: '失败通知被偏好关闭且无其它事件');
      expect(unread.total, 0);

      final disposeFuture = notifier.dispose();
      await Future<void>.delayed(Duration.zero);
      for (final body in sent) {
        final reader = ValueReader(body);
        final header = decodeValue(reader) as List;
        if (header[0] == ChannelClient.reqPromise &&
            header[3] == 'unsubscribeSessionsIndexV4') {
          channels.handleMessage(
              _frame([ChannelClient.resPromiseSuccess, header[1] as int], {}));
        }
      }
      await disposeFuture;
    });
  });
}
