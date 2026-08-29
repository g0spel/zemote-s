import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../protocol/connection_params.dart';
import '../protocol/id.dart';
import 'credential_storage.dart';

class Account {
  final String id;
  String label;
  final String url;
  final int addedAt;
  int? lastUsedAt;

  Account({
    required this.id,
    required this.label,
    required this.url,
    required this.addedAt,
    this.lastUsedAt,
  });

  factory Account.fromUrl(String url) {
    final params = ZflowConnectionParams.parse(url);
    final label = params?.deviceName ??
        (params != null ? params.source.host : '未命名设备');
    return Account(
      id: generateUuid(),
      label: label,
      url: url,
      addedAt: DateTime.now().millisecondsSinceEpoch,
    );
  }

  ZflowConnectionParams? get params => ZflowConnectionParams.parse(url);

  Map<String, dynamic> toJson() => {
        'id': id,
        'label': label,
        'url': url,
        'addedAt': addedAt,
        if (lastUsedAt != null) 'lastUsedAt': lastUsedAt,
      };

  factory Account.fromJson(Map<String, dynamic> json) => Account(
        id: json['id'] as String? ?? generateUuid(),
        label: json['label'] as String? ?? '未命名设备',
        url: json['url'] as String? ?? '',
        addedAt: (json['addedAt'] as num?)?.toInt() ?? 0,
        lastUsedAt: (json['lastUsedAt'] as num?)?.toInt(),
      );
}

/// Multi-account store. Credentials are persisted encrypted at rest via
/// [CredentialStorage] (Keystore/keychain — see `credential_storage.dart`),
/// never in plain SharedPreferences.
class AccountStore extends ChangeNotifier {
  final CredentialStorage _storage;

  AccountStore({CredentialStorage storage = const SecureCredentialStorage()})
      : _storage = storage;

  final List<Account> _accounts = [];
  /// 最近使用的设备在前(autoConnect 据此连"上一次连接的设备")。
  List<Account> get accounts {
    final list = [..._accounts]..sort((a, b) {
        final ua = a.lastUsedAt ?? 0;
        final ub = b.lastUsedAt ?? 0;
        return ub.compareTo(ua);
      });
    return List.unmodifiable(list);
  }

  bool _loaded = false;
  bool get loaded => _loaded;

  Future<void> load() async {
    final raw = await _storage.read();
    _accounts.clear();
    if (raw != null) {
      try {
        final list = jsonDecode(raw);
        if (list is List) {
          for (final item in list) {
            if (item is Map) {
              final account =
                  Account.fromJson(item.cast<String, dynamic>());
              if (account.url.isNotEmpty) _accounts.add(account);
            }
          }
        }
      } catch (_) {}
    }
    _loaded = true;
    notifyListeners();
  }

  Future<void> _save() async {
    await _storage.write(
      jsonEncode(_accounts.map((a) => a.toJson()).toList()),
    );
  }

  Future<Account> addUrl(String url, {String? label}) async {
    final account = Account.fromUrl(url);
    if (label != null && label.trim().isNotEmpty) {
      account.label = label.trim();
    }
    _accounts.add(account);
    await _save();
    notifyListeners();
    return account;
  }

  Future<void> remove(String id) async {
    _accounts.removeWhere((a) => a.id == id);
    await _save();
    notifyListeners();
  }

  Future<void> rename(String id, String label) async {
    final account = _accounts.where((a) => a.id == id).firstOrNull;
    if (account == null) return;
    account.label = label.trim().isEmpty ? account.label : label.trim();
    await _save();
    notifyListeners();
  }

  Future<void> touch(String id) async {
    final account = _accounts.where((a) => a.id == id).firstOrNull;
    if (account == null) return;
    account.lastUsedAt = DateTime.now().millisecondsSinceEpoch;
    await _save();
    notifyListeners();
  }

  /// Serializes all devices (including their connection URLs) to JSON for
  /// backup / transfer. Note: URLs contain credentials — treat the export
  /// like a password file.
  String exportJson() => jsonEncode({
        'app': 'zflow',
        'format': 'devices',
        'version': 1,
        'exportedAt': DateTime.now().toIso8601String(),
        'accounts': _accounts.map((a) => a.toJson()).toList(),
      });

  /// Restores devices from an export. Skips invalid URLs and duplicates
  /// (matched by connection URL). Returns how many were imported.
  Future<int> importJson(String raw) async {
    final decoded = jsonDecode(raw);
    final list = decoded is Map ? decoded['accounts'] : decoded;
    if (list is! List) {
      throw const FormatException('不是有效的设备导出文件');
    }
    var added = 0;
    for (final item in list) {
      if (item is! Map) continue;
      final account = Account.fromJson(item.cast<String, dynamic>());
      if (account.url.isEmpty) continue;
      if (ZflowConnectionParams.parse(account.url) == null) continue;
      if (_accounts.any((a) => a.url == account.url)) continue;
      _accounts.add(account);
      added++;
    }
    if (added > 0) {
      await _save();
      notifyListeners();
    }
    return added;
  }
}
