import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// One protocol log entry. Lines prefixed with `[诊断]` are human-readable
/// failure explanations (actionable causes, suspected protocol drift); the
/// log page highlights them so they stand out among raw protocol frames.
class LogEntry {
  final DateTime time;
  final String message;

  const LogEntry(this.time, this.message);

  bool get isDiagnostic => message.startsWith('[诊断]');

  /// `[HH:mm:ss.SSS] message` — used for copy / export.
  String get plain =>
      '[${time.hour.toString().padLeft(2, '0')}'
      ':${time.minute.toString().padLeft(2, '0')}'
      ':${time.second.toString().padLeft(2, '0')}'
      '.${time.millisecond.toString().padLeft(3, '0')}] $message';
}

/// Global in-memory protocol log.
///
/// Two safeguards keep the log page responsive while relay frames stream in:
/// entries are truncated to [maxLineChars] (a single raw frame can be tens
/// of KB — laying that out as one text line janks the UI thread into ANR),
/// and listener notifications are coalesced to at most one per
/// [flushInterval] regardless of how many entries arrive.
class LogStore extends ChangeNotifier {
  static final LogStore instance = LogStore();

  LogStore();

  static const maxEntries = 2000;
  static const maxLineChars = 1500;
  static const flushInterval = Duration(milliseconds: 250);

  final ListQueue<LogEntry> _entries = ListQueue();
  Timer? _flushTimer;
  bool _dirty = false;

  List<LogEntry> get entries => List.unmodifiable(_entries);

  void add(String line) {
    _entries.addLast(LogEntry(DateTime.now(), _truncate(line)));
    while (_entries.length > maxEntries) {
      _entries.removeFirst();
    }
    _dirty = true;
    _flushTimer ??= Timer(flushInterval, _flush);
  }

  void _flush() {
    _flushTimer = null;
    if (!_dirty || _disposed) return;
    _dirty = false;
    notifyListeners();
  }

  void clear() {
    _entries.clear();
    _dirty = false;
    _flushTimer?.cancel();
    _flushTimer = null;
    notifyListeners();
  }

  static String _truncate(String line) {
    if (line.length <= maxLineChars) return line;
    return '${line.substring(0, maxLineChars)}'
        '…(+${line.length - maxLineChars} 字符已截断)';
  }

  bool _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    _flushTimer?.cancel();
    super.dispose();
  }
}

void log(String line) => LogStore.instance.add(line);

/// 诊断日志开关(设置页):开 = [wire]/[chat]/[zflow] 探针同时写
/// logcat(release 真机取证:桥降级-恢复循环只在 wire 层可见);关 =
/// 仅应用内协议日志页。SharedPreferences 持久化,main 启动时加载。
const _diagLogKey = 'zflow_diag_log';
final ValueNotifier<bool> diagLogEnabled = ValueNotifier<bool>(false);

Future<void> loadDiagLogPref() async {
  final prefs = await SharedPreferences.getInstance();
  diagLogEnabled.value = prefs.getBool(_diagLogKey) ?? false;
}

Future<void> setDiagLogEnabled(bool value) async {
  diagLogEnabled.value = value;
  final prefs = await SharedPreferences.getInstance();
  await prefs.setBool(_diagLogKey, value);
}
