import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Per-workspace session-list cache (SharedPreferences, JSON). Serves the
/// task list instantly on open while the live channel RPC + sessions-index
/// refresh; entries are keyed by a hash of the workspace identity/path.
/// Cache is write-through from successful loads only — failures never
/// overwrite a good list.
class SessionListCache {
  static const _prefix = 'zemote_session_list_v1_';
  static const _maxEntries = 100;

  const SessionListCache();

  String keyFor(Map<String, dynamic> workspace) {
    final identity = '${workspace['workspaceIdentity'] ?? ''}'.trim();
    final path = '${workspace['workspacePath'] ?? ''}'.trim();
    final source = identity.isNotEmpty ? identity : path;
    return '$_prefix${sha256.convert(utf8.encode(source))}';
  }

  /// Cached task maps for [workspace], or an empty list.
  Future<List<Map<String, dynamic>>> read(
      Map<String, dynamic> workspace) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(keyFor(workspace));
      if (raw == null) return const [];
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return decoded
          .whereType<Map>()
          .map((e) => e.cast<String, dynamic>())
          .toList();
    } catch (_) {
      return const [];
    }
  }

  /// Persists [tasks] (successful loads only) and prunes stale entries.
  Future<void> write(
      Map<String, dynamic> workspace, List<Map<String, dynamic>> tasks) async {
    if (tasks.isEmpty) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(keyFor(workspace), jsonEncode(tasks));
      await _prune(prefs);
    } catch (_) {}
  }

  Future<void> _prune(SharedPreferences prefs) async {
    final keys =
        prefs.getKeys().where((k) => k.startsWith(_prefix)).toList();
    if (keys.length <= _maxEntries) return;
    // Entries carry no timestamps of their own; dropping the oldest keys
    // alphabetically is arbitrary but bounded — this is a cache.
    for (final k in keys.take(keys.length - _maxEntries)) {
      await prefs.remove(k);
    }
  }
}
