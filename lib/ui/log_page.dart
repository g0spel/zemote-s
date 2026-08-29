import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../state/log_store.dart';
import 'theme.dart';

class LogPage extends StatefulWidget {
  /// Filter mode: true shows ONLY `[诊断]` entries (the diagnostics log
  /// page), false shows everything EXCEPT them (the protocol log page) —
  /// the two pages complement each other with no overlap.
  final bool diagnosticsOnly;

  const LogPage({super.key, this.diagnosticsOnly = false});

  @override
  State<LogPage> createState() => _LogPageState();
}

class _LogPageState extends State<LogPage> {
  final _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    LogStore.instance.addListener(_scrollToBottom);
  }

  @override
  void dispose() {
    LogStore.instance.removeListener(_scrollToBottom);
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    if (_scrollController.hasClients) {
      _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
    }
  }

  List<LogEntry> get _visibleEntries => LogStore.instance.entries
      .where((e) => e.isDiagnostic == widget.diagnosticsOnly)
      .toList();

  Future<void> _copyAll() async {
    final entries = _visibleEntries;
    final text = entries.map((e) => e.plain).join('\n');
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已复制 ${entries.length} 条日志')));
    }
  }

  Future<void> _export() async {
    final text = _visibleEntries.map((e) => e.plain).join('\n');
    try {
      final path = await FilePicker.saveFile(
        dialogTitle: '导出协议日志',
        fileName: 'zflow-logs.txt',
        bytes: utf8.encode(text),
      );
      if (path == null) return; // cancelled
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('日志已导出。注意：日志含设备凭据片段，请妥善保管')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('导出失败: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final diag = widget.diagnosticsOnly;
    return Scaffold(
      appBar: AppBar(
        title: Text(diag ? '诊断日志' : '协议日志'),
        actions: [
          IconButton(
            icon: const Icon(Icons.copy_all_outlined),
            tooltip: '复制全部',
            onPressed: _copyAll,
          ),
          IconButton(
            icon: const Icon(Icons.save_outlined),
            tooltip: '导出为文件',
            onPressed: _export,
          ),
          if (!diag)
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: '清空',
              onPressed: () => LogStore.instance.clear(),
            ),
        ],
      ),
      body: AnimatedBuilder(
        animation: LogStore.instance,
        builder: (context, _) {
          final entries = _visibleEntries;
          if (entries.isEmpty) {
            return Center(
                child: Text(diag ? '暂无诊断条目' : '暂无日志'));
          }
          final colors = EmberColors.of(context);
          return ListView.builder(
            controller: _scrollController,
            padding: const EdgeInsets.symmetric(vertical: 6),
            itemCount: entries.length,
            itemBuilder: (context, index) {
              final e = entries[index];
              return Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${e.time.hour.toString().padLeft(2, '0')}'
                      ':${e.time.minute.toString().padLeft(2, '0')}'
                      ':${e.time.second.toString().padLeft(2, '0')}'
                      '.${e.time.millisecond.toString().padLeft(3, '0')}',
                      style: TextStyle(
                        fontFamily: EmberFonts.term,
                        fontSize: EmberType.caption,
                        color: colors.textFaint,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      e.message,
                      style: TextStyle(
                        fontFamily: EmberFonts.term,
                        fontSize: EmberType.caption,
                        height: 1.4,
                        color: e.isDiagnostic
                            ? colors.err
                            : colors.textSolid,
                        fontWeight:
                            e.isDiagnostic ? FontWeight.w600 : FontWeight.w400,
                      ),
                    ),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }
}
