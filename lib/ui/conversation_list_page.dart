import 'dart:async';

import 'package:flutter/material.dart';

import '../protocol/conversation.dart';
import '../protocol/zemote_client.dart';
import '../state/log_store.dart';
import 'chat_page.dart';
import 'theme.dart';

/// Conversation list for one workspace (Ember shell Tab content, no
/// Scaffold/AppBar — the RootShell provides the title area). Single source:
/// the live `sessions-index` subscription, no channel-list merge.
class ConversationListPage extends StatefulWidget {
  final BridgeSession bridge;
  final Map<String, dynamic> scope;
  final String workspaceKey;

  const ConversationListPage({
    super.key,
    required this.bridge,
    required this.scope,
    required this.workspaceKey,
  });

  @override
  State<ConversationListPage> createState() => _ConversationListPageState();
}

/// Newest first, by last activity.
List<SessionEntry> sortSessions(List<SessionEntry> entries) {
  final list = [...entries]
    ..sort((a, b) => b.lastActivityAt.compareTo(a.lastActivityAt));
  return list;
}

/// Status dot color: running/prewarming → run blue, waiting → warn yellow,
/// anything else renders no dot. Locked to the dark palette (the Ember
/// design baseline), independent of theme.
Color? statusDotColor(String phase) => switch (phase) {
      'running' || 'prewarming' => EmberColors.dark().run,
      'waiting' => EmberColors.dark().warn,
      _ => null,
    };

const _weekdays = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];

/// Today → `HH:mm`, yesterday → `昨天`, within the last week → `周X`,
/// else `M月d日` (with year when it differs from today's).
String _relativeDayLabel(int millis) {
  if (millis <= 0) return '';
  final time = DateTime.fromMillisecondsSinceEpoch(millis);
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(time.year, time.month, time.day);
  final hhmm =
      '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
  final daysAgo = today.difference(day).inDays;
  if (daysAgo <= 0) return hhmm;
  if (daysAgo == 1) return '昨天';
  if (daysAgo < 7) return _weekdays[time.weekday - 1];
  if (time.year == now.year) return '${time.month}月${time.day}日';
  return '${time.year}年${time.month}月${time.day}日';
}

class _ConversationListPageState extends State<ConversationListPage> {
  late final ConversationTransport _transport;
  SessionsIndexSubscription? _sub;
  List<SessionEntry> _entries = const [];
  bool _ready = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _transport = widget.bridge.conversation(widget.scope, onLog: log);
    _subscribe();
  }

  @override
  void dispose() {
    final sub = _sub;
    _sub = null;
    if (sub != null) {
      sub.state.removeListener(_onState);
      sub.dispose();
    }
    super.dispose();
  }

  Future<void> _subscribe() async {
    setState(() => _error = null);
    try {
      final sub = await _transport.subscribeSessionsIndex();
      if (!mounted) {
        await sub.dispose();
        return;
      }
      _sub = sub;
      sub.state.addListener(_onState);
      _onState();
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  void _onState() {
    final sub = _sub;
    if (sub == null || !mounted) return;
    setState(() {
      _entries = sortSessions(sub.state.list);
      _ready = sub.state.ready;
    });
  }

  void _open(SessionEntry entry) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ChatPage(
          session: widget.bridge,
          scope: widget.scope,
          workspaceKey: widget.workspaceKey,
          sessionId: entry.sessionId,
          title: entry.title.isEmpty ? entry.sessionId : entry.title,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = EmberColors.of(context);
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('会话列表加载失败: $_error',
                style: TextStyle(fontSize: EmberType.caption, color: colors.textMuted)),
            const SizedBox(height: EmberSpacing.gapS),
            TextButton(
              onPressed: _subscribe,
              style: TextButton.styleFrom(foregroundColor: colors.primary),
              child: const Text('重试'),
            ),
          ],
        ),
      );
    }
    if (!_ready) {
      return const Center(
        child: SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    if (_entries.isEmpty) {
      return Center(
        child: Text('暂无会话，下拉输入框开始新的对话',
            style: TextStyle(fontSize: EmberType.caption, color: colors.textFaint)),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.symmetric(
          horizontal: EmberSpacing.page, vertical: EmberSpacing.gapS),
      itemCount: _entries.length,
      separatorBuilder: (_, __) => const SizedBox(height: 2),
      itemBuilder: (context, index) => _buildRow(context, _entries[index]),
    );
  }

  Widget _buildRow(BuildContext context, SessionEntry entry) {
    final colors = EmberColors.of(context);
    final dot = statusDotColor(entry.phase);
    final preview = entry.lastAssistantPreview ?? '';
    return InkWell(
      onTap: () => _open(entry),
      child: Padding(
        padding: const EdgeInsets.symmetric(
            horizontal: EmberSpacing.cardPad, vertical: 10),
        child: Row(
          children: [
            SizedBox(
              width: 8,
              height: 8,
              child: dot == null
                  ? null
                  : DecoratedBox(
                      decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
                    ),
            ),
            const SizedBox(width: EmberSpacing.gapM),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    entry.title.isEmpty ? entry.sessionId : entry.title,
                    style: TextStyle(
                        fontSize: EmberType.body, color: colors.textSolid),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    preview,
                    style: TextStyle(
                        fontSize: EmberType.caption, color: colors.textMuted),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            const SizedBox(width: EmberSpacing.gapS),
            Text(
              _relativeDayLabel(entry.lastActivityAt),
              style:
                  TextStyle(fontSize: 10, color: colors.textFaint),
            ),
          ],
        ),
      ),
    );
  }
}
