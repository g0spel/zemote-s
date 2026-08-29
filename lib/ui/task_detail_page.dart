import 'dart:convert';

import 'package:flutter/material.dart';

import '../protocol/channel_client.dart';
import '../protocol/zflow_client.dart';
import 'theme.dart';

/// 任务原始快照页:`getTaskSnapshotWithEtag`(zcode-task 通道)的 JSON
/// 视图,供排查任务元数据;UI 大改前的 task_detail 同源恢复。
class TaskDetailPage extends StatefulWidget {
  final String taskId;
  final String title;
  final Map<String, dynamic> scope;
  final BridgeSession session;

  const TaskDetailPage({
    super.key,
    required this.taskId,
    required this.title,
    required this.scope,
    required this.session,
  });

  @override
  State<TaskDetailPage> createState() => _TaskDetailPageState();
}

class _TaskDetailPageState extends State<TaskDetailPage> {
  Object? _snapshot;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await widget.session.channels.call(
        Channels.zcodeTask,
        'getTaskSnapshotWithEtag',
        [
          {...widget.scope, 'taskId': widget.taskId},
        ],
      );
      if (!mounted) return;
      setState(() {
        _snapshot = result is Map ? (result['snapshot'] ?? result) : result;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    const encoder = JsonEncoder.withIndent('  ');
    final colors = EmberColors.of(context);
    return Scaffold(
      backgroundColor: colors.bg,
      appBar: AppBar(
        backgroundColor: colors.bg,
        title: Text(widget.title,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 15)),
        actions: [
          IconButton(
              icon: const Icon(Icons.refresh), tooltip: '刷新', onPressed: _load),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (_error != null)
                    Text('加载失败: $_error',
                        style: TextStyle(color: colors.err)),
                  SelectableText(
                    _snapshot == null
                        ? '（无快照数据）'
                        : encoder.convert(_snapshot),
                    style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 11,
                        color: colors.textSolid),
                  ),
                ],
              ),
            ),
    );
  }
}
