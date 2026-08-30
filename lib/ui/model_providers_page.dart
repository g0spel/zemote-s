import 'dart:async';

import 'package:flutter/material.dart';

import '../protocol/channel_client.dart';
import '../protocol/conversation.dart';
import '../protocol/id.dart';
import '../protocol/zflow_client.dart';
import 'theme.dart';

/// Provider status, aligned with the desktop client (verified live):
/// custom providers carry NO `enabled` field and the official client still
/// shows them as 已启用 — so only an explicit `enabled == false` or a
/// `systemDisabledReason` means 已停用; a required-but-empty API key means
/// 未配置; everything else (including enabled-absent customs) is 已启用.
enum ProviderStatus { enabled, unconfigured, disabled }

ProviderStatus providerStatusOf(Map<String, dynamic> p) {
  if (p['systemDisabledReason'] is String) return ProviderStatus.disabled;
  if (p['enabled'] == false) return ProviderStatus.disabled;
  final apiKey = p['apiKey'];
  if (p['apiKeyRequired'] == true &&
      apiKey is String &&
      apiKey.isEmpty) {
    return ProviderStatus.unconfigured;
  }
  return ProviderStatus.enabled;
}

String providerDisabledReasonText(String raw) => switch (raw) {
      'oauth_provider_inactive' => '登录已失效',
      'coding_plan_not_entitled' => '无订阅资格',
      'api_key_missing' => '未配置 API Key',
      _ => raw,
    };

/// 主供应商判别(spec §7.4:主供应商默认展开模型明细,其余折叠)。
/// 依据是 wire 协议里可验证的 `source` 字段:服务端下发的内置供应商
/// 不带 `source: 'custom'`(见 providerStatusOf 的对齐注释),仅用户
/// 自建项在本页保存时固定写入 `source: 'custom'`,故非 custom 即主。
bool isPrimaryProvider(Map<String, dynamic> p) => p['source'] != 'custom';

/// Model providers management (model-provider channel: getAll/save/delete).
class ModelProvidersPage extends StatefulWidget {
  final BridgeSession session;
  final Map<String, dynamic> scope;

  const ModelProvidersPage({
    super.key,
    required this.session,
    required this.scope,
  });

  @override
  State<ModelProvidersPage> createState() => _ModelProvidersPageState();
}

class _ModelProvidersPageState extends State<ModelProvidersPage> {
  late final ConversationTransport _transport;
  List<Map<String, dynamic>> _providers = const [];
  bool _loading = true;
  String? _error;
  int _loadGeneration = 0;
  int _liveModelsGeneration = 0;

  /// 实时可用模型集(provider 注册表 id → 模型 id 集),取自
  /// prepareWorkspace 的 model 选项(宿主按当前订阅/注册表实时下发)。
  /// getAll 的 models 是配置存量,已下线模型仍会留在里面——用它对照
  /// 标注。拿不到(自建供应商/调用失败)时保持静态展示。
  Map<String, Set<String>> _liveModelsByProvider = const {};

  @override
  void initState() {
    super.initState();
    _transport = widget.session.conversation(widget.scope);
    _load();
  }

  @override
  void dispose() {
    _loadGeneration++;
    _liveModelsGeneration++;
    super.dispose();
  }

  Future<void> _load() async {
    final generation = ++_loadGeneration;
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final res = await widget.session.channels
          .call('model-provider', 'getAll', []);
      if (mounted && generation == _loadGeneration) {
        setState(() {
          _providers = res is List
              ? res
                  .whereType<Map>()
                  .map((e) => e.cast<String, dynamic>())
                  .toList()
              : const [];
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted && generation == _loadGeneration) {
        setState(() {
          _error = '$e';
          _loading = false;
        });
      }
    }
    if (mounted && generation == _loadGeneration) {
      unawaited(_loadLiveModels());
    }
  }

  /// 实时可用模型:与聊天模型选择面板同源(prepareWorkspace 的 model
  /// 选项,含 modelProviderId)。按 provider 归组,供卡片对照标注。
  Future<void> _loadLiveModels() async {
    final generation = ++_liveModelsGeneration;
    final transportGeneration = _transport.prepGeneration;
    try {
      final prep = await _transport.prepareWorkspace(refresh: true);
      if (!mounted ||
          generation != _liveModelsGeneration ||
          transportGeneration != _transport.prepGeneration) {
        return;
      }
      final modelOption = prep.option('model');
      if (modelOption == null) return;
      final sets = <String, Set<String>>{};
      for (final value in modelOption.options) {
        final pid = value.modelProviderId;
        final modelId = value.value.contains('/')
            ? value.value.substring(value.value.lastIndexOf('/') + 1)
            : value.value;
        if (pid == null || pid.isEmpty || modelId.isEmpty) {
          continue;
        }
        sets.putIfAbsent(pid, () => {}).add(modelId);
      }
      if (mounted && generation == _liveModelsGeneration) {
        setState(() => _liveModelsByProvider = sets);
      }
    } catch (_) {
      // 实时集不可得(如自建供应商场景):保持静态展示,不打扰。
    }
  }

  Future<void> _save(Map<String, dynamic> provider) async {
    await widget.session.channels.call('model-provider', 'save', [
      {
        ...provider,
        'updatedAt': DateTime.now().millisecondsSinceEpoch,
      },
    ]);
  }

  Future<void> _toggle(Map<String, dynamic> provider, bool enabled) async {
    try {
      await _save({...provider, 'enabled': enabled});
      await _load();
    } catch (e) {
      _toast('切换失败: $e');
    }
  }

  Future<void> _delete(Map<String, dynamic> provider) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除模型供应商？'),
        content: Text('将删除「${provider['name']}」'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: EmberColors.of(context).err),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await widget.session.channels.call('model-provider', 'delete', [
        {'id': provider['id']},
      ]);
    } on ChannelRpcError {
      // Fallback: try alternate parameter shape
      try {
        await widget.session.channels
            .call('model-provider', 'delete', [provider['id']]);
      } catch (e2) {
        _toast('删除失败: $e2');
        return;
      }
    } catch (e) {
      _toast('删除失败: $e');
      return;
    }
    await _load();
  }

  void _toast(String message) {
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    }
  }

  Future<void> _showAddSheet() async {
    final added = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      builder: (context) => const _AddProviderSheet(),
    );
    if (added == null) return;
    try {
      await _save(added);
      await _load();
      _toast('已添加供应商');
    } catch (e) {
      _toast('添加失败: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = EmberColors.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('模型供应商'),
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: _load),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _showAddSheet,
        icon: const Icon(Icons.add),
        label: const Text('添加'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(child: Text('加载失败: $_error'))
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView.separated(
                    padding: const EdgeInsets.all(16),
                    itemCount: _providers.length,
                    separatorBuilder: (_, __) =>
                        const SizedBox(height: 8),
                    itemBuilder: (context, index) {
                      final p = _providers[index];
                      final status = providerStatusOf(p);
                      final active = status != ProviderStatus.disabled;
                      final endpoints = p['endpoints'];
                      final baseUrl = endpoints is Map
                          ? '${endpoints['baseURL'] ?? ''}'
                          : '';
                      final models =
                          p['models'] is List ? p['models'] as List : [];
                      final modelIds = models
                          .whereType<Map>()
                          .map((m) => '${m['id'] ?? m['name'] ?? ''}')
                          .where((s) => s.isNotEmpty)
                          .toSet();
                      final liveModels = _liveModelsByProvider['${p['id']}'];
                      final availableCount = liveModels?.intersection(modelIds).length;
                      final disabledReason =
                          p['systemDisabledReason'] as String?;
                      // 状态徽三色(spec §7.4):已启用绿 / 未配置黄 / 已停用灰。
                      final (statusLabel, statusColor) = switch (status) {
                        ProviderStatus.enabled => ('已启用', colors.ok),
                        ProviderStatus.unconfigured => (
                            '未配置',
                            colors.warn
                          ),
                        ProviderStatus.disabled =>
                          ('已停用', colors.textFaint),
                      };
                      // 主供应商(spec §7.4)——判别依据见 [isPrimaryProvider]。
                      final isMain = isPrimaryProvider(p);
                      return Card(
                        child: ExpansionTile(
                          initiallyExpanded: isMain,
                          tilePadding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 4),
                          title: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  '${p['name'] ?? p['id']}',
                                  style: TextStyle(
                                      fontSize: EmberType.emphasis,
                                      fontWeight: FontWeight.w600,
                                      color: colors.textSolid),
                                ),
                              ),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 6, vertical: 1),
                                decoration: BoxDecoration(
                                  color: statusColor.withValues(alpha: 0.14),
                                  borderRadius: BorderRadius.circular(5),
                                ),
                                child: Text(statusLabel,
                                    style: TextStyle(
                                        fontSize: EmberType.caption,
                                        color: statusColor)),
                              ),
                            ],
                          ),
                          subtitle: Text(
                            [
                              '${p['apiFormat'] ?? ''}',
                              if (models.isNotEmpty) ...[
                              if (availableCount != null)
                                '$availableCount / ${models.length} 个模型可用'
                              else
                                '${models.length} 个模型',
                              ],
                              if (baseUrl.isNotEmpty) baseUrl,
                              if (status == ProviderStatus.disabled &&
                                  disabledReason != null)
                                providerDisabledReasonText(disabledReason),
                            ]
                                .where((s) => s.isNotEmpty)
                                .join(' · '),
                            style: TextStyle(
                                fontSize: EmberType.caption,
                                color: colors.textFaint),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          children: [
                            if (models.isEmpty)
                              Padding(
                                padding: const EdgeInsets.all(12),
                                child: Text('（无模型）',
                                    style: TextStyle(
                                        fontSize: EmberType.caption,
                                        color: colors.textFaint)),
                              )
                            else
                              Padding(
                                padding: const EdgeInsets.fromLTRB(
                                    16, 0, 16, 10),
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.start,
                                  children: [
                                    for (final m
                                        in models.whereType<Map>())
                                      _modelLine(context, m,
                                          live: _liveModelsByProvider[
                                              '${p['id']}']),
                                  ],
                                ),
                              ),
                            Padding(
                              padding:
                                  const EdgeInsets.fromLTRB(8, 0, 8, 8),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.end,
                                children: [
                                  Switch(
                                    value: active,
                                    onChanged: (v) => _toggle(p, v),
                                  ),
                                  IconButton(
                                    icon: Icon(Icons.delete_outline,
                                        size: 18,
                                        color: colors.textFaint),
                                    onPressed: () => _delete(p),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
    );
  }
}

class _AddProviderSheet extends StatefulWidget {
  const _AddProviderSheet();

  @override
  State<_AddProviderSheet> createState() => _AddProviderSheetState();
}

class _AddProviderSheetState extends State<_AddProviderSheet> {
  final _nameController = TextEditingController();
  final _baseUrlController = TextEditingController();
  final _apiKeyController = TextEditingController();
  final _modelsController = TextEditingController();
  String _apiFormat = 'anthropic-messages';

  static const _formats = [
    'anthropic-messages',
    'openai-chat',
    'gemini',
  ];

  @override
  void dispose() {
    _nameController.dispose();
    _baseUrlController.dispose();
    _apiKeyController.dispose();
    _modelsController.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _nameController.text.trim();
    final baseUrl = _baseUrlController.text.trim();
    if (name.isEmpty || baseUrl.isEmpty) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final modelIds = _modelsController.text
        .split(RegExp(r'[,\n]'))
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    final kind = _apiFormat.startsWith('anthropic')
        ? 'anthropic'
        : _apiFormat.startsWith('openai')
            ? 'openai'
            : 'gemini';
    Navigator.pop(context, {
      'id': 'custom:${generateUuid()}',
      'name': name,
      'enabled': true,
      'endpoints': {
        'baseURL': baseUrl,
        'paths': {kind: '/v1/messages'},
      },
      'apiFormat': _apiFormat,
      'source': 'custom',
      if (_apiKeyController.text.trim().isNotEmpty)
        'apiKey': _apiKeyController.text.trim(),
      'defaultKind': kind,
      'models': [
        for (var i = 0; i < modelIds.length; i++)
          {
            'id': modelIds[i],
            'kinds': [kind],
            'defaultKind': kind,
            'modalities': {
              'input': ['text'],
              'output': ['text'],
            },
            'priority': 100 + i,
          },
      ],
      'createdAt': now,
      'updatedAt': now,
    });
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
          20, 20, 20, 20 + MediaQuery.of(context).viewInsets.bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('添加模型供应商',
              style:
                  TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
          const SizedBox(height: 16),
          TextField(
            controller: _nameController,
            decoration: const InputDecoration(
                labelText: '名称', hintText: '例如 My Provider'),
          ),
          const SizedBox(height: 10),
          DropdownButtonFormField<String>(
            initialValue: _apiFormat,
            decoration: const InputDecoration(labelText: 'API 格式'),
            items: [
              for (final f in _formats)
                DropdownMenuItem(value: f, child: Text(f)),
            ],
            onChanged: (v) =>
                setState(() => _apiFormat = v ?? _apiFormat),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _baseUrlController,
            decoration: const InputDecoration(
                labelText: 'Base URL',
                hintText: 'https://api.example.com/api/anthropic'),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _apiKeyController,
            obscureText: true,
            decoration: const InputDecoration(
                labelText: 'API Key（可选）'),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _modelsController,
            maxLines: 2,
            decoration: const InputDecoration(
                labelText: '模型 ID（逗号分隔）',
                hintText: 'GLM-5.2, GLM-5-Turbo'),
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: _submit,
              child: const Text('保存'),
            ),
          ),
        ],
      ),
    );
  }
}

/// One model line inside a provider's expansion: id · context window ·
/// max output · reasoning levels.
/// [live] 为 null 表示没有该供应商的实时数据(自建供应商),原样展示;
/// 非 null 时模型不在集合内 = 已下线,弱化并标注。
Widget _modelLine(BuildContext context, Map<dynamic, dynamic> m,
    {Set<String>? live}) {
  final id = '${m['id'] ?? m['name'] ?? '?'}';
  final offline = live != null && !live.contains(id);
  final ctx = (m['contextWindow'] as num?)?.toInt();
  final maxOut = (m['maxOutputTokens'] as num?)?.toInt();
  final reasoning = m['reasoning'];
  final levels = reasoning is Map ? reasoning['levels'] : null;
  final levelNames = levels is Map ? levels.keys.toList().join('/') : '';
  String k(int? v) => v == null ? '' : v >= 1000000 ? '${v ~/ 1000000}M' : '${(v / 1000).round()}k';
  return Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Text(
      [
        id,
        if (offline) '已下线',
        if (!offline && ctx != null) '上下文 ${k(ctx)}',
        if (!offline && maxOut != null) '输出 ${k(maxOut)}',
        if (!offline && levelNames.isNotEmpty) '推理 $levelNames',
      ].join(' · '),
      style: TextStyle(
          fontSize: EmberType.caption,
          color: offline
              ? EmberColors.of(context).textFaint
              : EmberColors.of(context).textSoft,
          decoration: offline ? TextDecoration.lineThrough : null),
    ),
  );
}
