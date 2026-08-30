import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';

import 'theme.dart';

/// Diff view for tool calls (Edit/Write/MultiEdit), replicating the web
/// client's extraction logic (`Gfe`/`Jfe`/`Qfe`):
/// old/new text pairs are searched in input/output/raw with alias keys,
/// or taken from `structuredPatch`.
class DiffData {
  final String? filePath;
  final List<DiffLine> lines;

  DiffData({this.filePath, required this.lines});
}

enum DiffLineType { context, added, removed }

class DiffLine {
  final DiffLineType type;
  final String text;

  const DiffLine(this.type, this.text);
}

const _oldKeys = [
  'oldText',
  'old_string',
  'oldString',
  'before',
  'old_content',
  'oldContent',
];
const _newKeys = [
  'newText',
  'new_string',
  'newString',
  'after',
  'new_content',
  'newContent',
  'content',
];
const _pathKeys = ['filePath', 'file_path', 'path', 'file'];

Object? _firstKey(Map<String, dynamic> map, List<String> keys) {
  for (final k in keys) {
    if (map[k] != null) return map[k];
  }
  return null;
}

class _ToolRenderCache<T> {
  final int maxEntries;
  final LinkedHashMap<String, T> _values = LinkedHashMap();

  _ToolRenderCache(this.maxEntries);

  bool containsKey(String key) => _values.containsKey(key);

  T operator [](String key) {
    final value = _values.remove(key) as T;
    _values[key] = value;
    return value;
  }

  T? removeOldest() {
    if (_values.isEmpty) return null;
    return _values.remove(_values.keys.first);
  }

  T? put(String key, T value) {
    _values.remove(key);
    T? evicted;
    while (_values.length >= maxEntries) {
      evicted = removeOldest();
    }
    _values[key] = value;
    return evicted;
  }

  void operator []=(String key, T value) {
    put(key, value);
  }

  void clear() => _values.clear();
}

final _diffCache = _ToolRenderCache<DiffData?>(64);
final _prettyToolValueCache = _ToolRenderCache<String>(64);
final _inlineToolImageCache = _ToolRenderCache<Uint8List>(16);
var _inlineToolImageCacheBytes = 0;

const _maxInlineToolImageCacheBytes = 8 * 1024 * 1024;
const _maxInlineToolImageCacheEntryBytes = 2 * 1024 * 1024;

String _contentDigest(Object? value) {
  final encoded = value is String
      ? value
      : jsonEncode(_stableCacheValue(value));
  return sha256.convert(utf8.encode(encoded)).toString();
}

Object? _stableCacheValue(Object? value) {
  if (value is Map) {
    final entries = value.entries
        .map((entry) => MapEntry('${entry.key}', _stableCacheValue(entry.value)))
        .toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    return <String, Object?>{
      for (final entry in entries) entry.key: entry.value,
    };
  }
  if (value is Iterable) return value.map(_stableCacheValue).toList();
  if (value == null || value is String || value is bool) return value;
  if (value is num) return value.isFinite ? value : '$value';
  return '$value';
}

List<Object?> _diffCacheProjection(Map<String, dynamic> row) {
  final display = row['display'];
  return [
    row['input'],
    row['output'],
    if (row['raw'] is Map) (row['raw'] as Map)['rawOutput'],
    row['raw'],
    if (display is Map && display['kind'] == 'file_diff') display,
    row['structuredPatch'],
  ];
}

void clearToolRenderCaches() {
  _diffCache.clear();
  _prettyToolValueCache.clear();
  _inlineToolImageCache.clear();
  _inlineToolImageCacheBytes = 0;
}

String formatToolValue(String value) {
  final key = _contentDigest(value);
  if (_prettyToolValueCache.containsKey(key)) {
    return _prettyToolValueCache[key];
  }

  var display = value;
  try {
    final decoded = jsonDecode(value);
    display = const JsonEncoder.withIndent('  ').convert(decoded);
  } catch (_) {}
  if (display.length > 4000) display = '${display.substring(0, 4000)}…';

  _prettyToolValueCache[key] = display;
  return display;
}

Uint8List? decodeInlineToolImage(String encoded) {
  final key = _contentDigest(encoded);
  if (_inlineToolImageCache.containsKey(key)) {
    return _inlineToolImageCache[key];
  }

  late final Uint8List bytes;
  try {
    bytes = base64Decode(encoded);
  } on FormatException {
    return null;
  }
  if (bytes.length <= _maxInlineToolImageCacheEntryBytes) {
    while (_inlineToolImageCacheBytes + bytes.length >
        _maxInlineToolImageCacheBytes) {
      final evicted = _inlineToolImageCache.removeOldest();
      if (evicted == null) break;
      _inlineToolImageCacheBytes -= evicted.length;
    }
    if (_inlineToolImageCacheBytes + bytes.length <=
        _maxInlineToolImageCacheBytes) {
      final evicted = _inlineToolImageCache.put(key, bytes);
      if (evicted != null) _inlineToolImageCacheBytes -= evicted.length;
      _inlineToolImageCacheBytes += bytes.length;
    }
  }
  return bytes;
}

/// Tries to extract a diff from a toolCall row. Returns null when the row
/// is not a file edit. The key includes every candidate used by the fallback
/// order, while ignoring unrelated status/progress fields.
DiffData? extractDiff(Map<String, dynamic> row) {
  final key = _contentDigest(_diffCacheProjection(row));
  if (_diffCache.containsKey(key)) return _diffCache[key];
  final result = _extractDiffUncached(row);
  _diffCache[key] = result;
  return result;
}

DiffData? _extractDiffUncached(Map<String, dynamic> row) {
  // display.kind === 'file_diff' with patch info
  final display = row['display'];
  final candidates = <Object?>[
    row['input'],
    row['output'],
    if (row['raw'] is Map) (row['raw'] as Map)['rawOutput'],
    row['raw'],
    if (display is Map && display['kind'] == 'file_diff') display,
  ];

  for (final c in candidates) {
    if (c is! Map) continue;
    final map = c.cast<String, dynamic>();
    final oldText = _firstKey(map, _oldKeys);
    final newText = _firstKey(map, _newKeys);
    if (oldText is String && newText is String) {
      return DiffData(
        filePath: _firstKey(map, _pathKeys) as String?,
        lines: _buildLines(oldText, newText),
      );
    }
  }

  // structuredPatch: [{oldStart, oldLines, newStart, lines:[...]}]
  final patch = row['structuredPatch'];
  if (patch is List) {
    final lines = <DiffLine>[];
    String? filePath;
    for (final hunk in patch) {
      if (hunk is! Map) continue;
      final hunkMap = hunk.cast<String, dynamic>();
      filePath ??= _firstKey(hunkMap, _pathKeys) as String?;
      final hunkLines = hunk['lines'];
      if (hunkLines is! List) continue;
      for (final line in hunkLines) {
        if (line is String) {
          lines.add(_classify(line));
        } else if (line is Map) {
          final type = '${line['type'] ?? ''}';
          final text = '${line['content'] ?? line['text'] ?? ''}';
          lines.add(DiffLine(
            type == 'add' || type == 'added' || type == '+'
                ? DiffLineType.added
                : type == 'remove' ||
                        type == 'removed' ||
                        type == 'del' ||
                        type == '-'
                    ? DiffLineType.removed
                    : DiffLineType.context,
            text,
          ));
        }
      }
    }
    if (lines.isNotEmpty) {
      return DiffData(filePath: filePath, lines: lines);
    }
  }
  return null;
}

DiffLine _classify(String line) {
  if (line.startsWith('+')) return DiffLine(DiffLineType.added, line);
  if (line.startsWith('-')) return DiffLine(DiffLineType.removed, line);
  return DiffLine(DiffLineType.context, line);
}

/// Side-by-side-ish stacked diff: old text lines removed, new added,
/// with a small shared-prefix context (simple LCS-free heuristic).
List<DiffLine> _buildLines(String oldText, String newText) {
  final oldLines = oldText.split('\n');
  final newLines = newText.split('\n');

  // common prefix / suffix
  var prefix = 0;
  while (prefix < oldLines.length &&
      prefix < newLines.length &&
      oldLines[prefix] == newLines[prefix]) {
    prefix++;
  }
  var suffix = 0;
  while (suffix < oldLines.length - prefix &&
      suffix < newLines.length - prefix &&
      oldLines[oldLines.length - 1 - suffix] ==
          newLines[newLines.length - 1 - suffix]) {
    suffix++;
  }

  final lines = <DiffLine>[];
  const contextKeep = 2;
  void addContext(List<String> src, int from, int to) {
    if (to - from > contextKeep * 2 + 1) {
      for (var i = from; i < from + contextKeep; i++) {
        lines.add(DiffLine(DiffLineType.context, ' ${src[i]}'));
      }
      lines.add(const DiffLine(
          DiffLineType.context, ' ⋯'));
      for (var i = to - contextKeep; i < to; i++) {
        lines.add(DiffLine(DiffLineType.context, ' ${src[i]}'));
      }
    } else {
      for (var i = from; i < to; i++) {
        lines.add(DiffLine(DiffLineType.context, ' ${src[i]}'));
      }
    }
  }

  addContext(oldLines, 0, prefix > contextKeep ? contextKeep : prefix);
  for (var i = prefix; i < oldLines.length - suffix; i++) {
    lines.add(DiffLine(DiffLineType.removed, '-${oldLines[i]}'));
  }
  for (var i = prefix; i < newLines.length - suffix; i++) {
    lines.add(DiffLine(DiffLineType.added, '+${newLines[i]}'));
  }
  if (suffix > 0) {
    addContext(oldLines, oldLines.length - suffix, oldLines.length);
  }
  return lines;
}

class DiffView extends StatelessWidget {
  final DiffData diff;

  const DiffView({super.key, required this.diff});

  @override
  Widget build(BuildContext context) {
    final ember = EmberColors.of(context);
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      decoration: BoxDecoration(
        color: ember.codeBlockBg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: ember.hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (diff.filePath != null)
            Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: ember.headerBg,
                borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(10)),
              ),
              child: Text(
                diff.filePath!,
                style: TextStyle(
                    fontSize: 10.5,
                    fontFamily: 'monospace',
                    color: ember.textMuted),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final line in diff.lines.take(400))
                  Container(
                    color: switch (line.type) {
                      DiffLineType.added => ember.addedBg,
                      DiffLineType.removed => ember.removedBg,
                      DiffLineType.context => Colors.transparent,
                    },
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 1),
                    child: Text(
                      line.text.isEmpty ? ' ' : line.text,
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 11,
                        height: 1.45,
                        color: switch (line.type) {
                          DiffLineType.added =>
                            ember.addedText,
                          DiffLineType.removed =>
                            ember.removedText,
                          DiffLineType.context => ember.textSoft,
                        },
                      ),
                    ),
                  ),
                if (diff.lines.length > 400)
                  Padding(
                    padding: const EdgeInsets.all(8),
                    child: Text('…（diff 过长已截断）',
                        style: TextStyle(
                            fontSize: 10, color: ember.textFaint)),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Diff 专属明暗配色(仅 [DiffView] 使用):容器与正文文字取
/// [EmberColors] 的代码面,+/- 色带与行文字两主题各取一套——浅色用
/// 饱和基色(粉彩在白底上发灰),暗色用粉彩(饱和色过亮刺眼)。
extension _DiffColors on EmberColors {
  /// 头部条:代码面之上的一档。
  Color get headerBg =>
      isDark ? Colors.white.withValues(alpha: 0.06) : const Color(0xFFE2E8F0);
  Color get addedBg => isDark
      ? const Color(0xFF22C55E).withValues(alpha: 0.12)
      : const Color(0x16B7EB8F);
  Color get removedBg => isDark
      ? const Color(0xFFEF4444).withValues(alpha: 0.12)
      : const Color(0x16FCA5A5);
  Color get addedText =>
      isDark ? const Color(0xFF86EFAC) : const Color(0xFF15803D);
  Color get removedText =>
      isDark ? const Color(0xFFFCA5A5) : const Color(0xFFB91C1C);
}
