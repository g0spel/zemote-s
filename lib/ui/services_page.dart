import 'dart:convert';

import 'package:flutter/material.dart';

import '../protocol/channel_client.dart';
import '../protocol/zflow_client.dart';

import 'theme.dart';

/// Read-only overview of managed services (plugins / cron automations).
/// MCP & Skills are desktop-config-driven; use the Channel RPC explorer
/// for those (a hint card is shown).
class ServicesPage extends StatefulWidget {
  final BridgeSession session;
  final Map<String, dynamic> scope;

  const ServicesPage({
    super.key,
    required this.session,
    required this.scope,
  });

  @override
  State<ServicesPage> createState() => _ServicesPageState();
}

class _ServicesPageState extends State<ServicesPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('服务管理'),
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(text: '插件'),
            Tab(text: '技能 / 命令'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _ServiceList(
            loader: () => widget.session.channels.call(
              Channels.zcodeAgent,
              'listPlugins',
              [widget.scope],
            ),
            enabledOf: (item) => item['enabled'] == true,
            titleOf: (item) =>
                '${item['name'] ?? item['id'] ?? item['pluginId'] ?? ''}',
            subtitleOf: (item) => [
              '${item['version'] ?? ''}',
              '${item['source'] ?? ''}',
            ].where((s) => s.isNotEmpty && s != 'null').join(' · '),
          ),
          _SkillsTab(session: widget.session, scope: widget.scope),
        ],
      ),
    );
  }
}

/// Skills & commands (live data via `skills.list` / `commands.list`) plus an
/// honest note on MCP: the remote protocol exposes NO MCP inventory reads
/// (verified live — 15 candidate methods all "Method not found"); the
/// desktop manages servers locally and only accepts sync writes.
class _SkillsTab extends StatefulWidget {
  final BridgeSession session;
  final Map<String, dynamic> scope;

  const _SkillsTab({required this.session, required this.scope});

  @override
  State<_SkillsTab> createState() => _SkillsTabState();
}

class _SkillsTabState extends State<_SkillsTab>
    with AutomaticKeepAliveClientMixin {
  List<Map<String, dynamic>> _skills = const [];
  List<Map<String, dynamic>> _commands = const [];
  bool _loading = true;
  String? _error;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  static List<Map<String, dynamic>> _mapsOf(dynamic res, String key) {
    if (res is Map && res[key] is List) {
      return [
        for (final e in res[key] as List)
          if (e is Map) e.cast<String, dynamic>(),
      ];
    }
    return const [];
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final results = await Future.wait([
        widget.session.channels
            .call('skills', 'list', [widget.scope])
            .timeout(const Duration(seconds: 15))
            .catchError((Object _) => null),
        widget.session.channels
            .call('commands', 'list', [widget.scope])
            .timeout(const Duration(seconds: 15))
            .catchError((Object _) => null),
      ]);
      if (!mounted) return;
      setState(() {
        _skills = _mapsOf(results[0], 'skills');
        _commands = _mapsOf(results[1], 'commands');
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
    super.build(context);
    final colors = EmberColors.of(context);
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('加载失败: $_error',
                style: TextStyle(color: colors.err, fontSize: 12)),
            const SizedBox(height: 8),
            OutlinedButton(onPressed: _load, child: const Text('重试')),
          ],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _sectionHeader('MCP 服务器'),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: colors.raise,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                Icon(Icons.extension_outlined,
                    size: 16, color: colors.textFaint),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '远程协议未提供 MCP 服务器读取接口（仅支持同步写入），请在桌面端 设置 → MCP 管理。',
                    style:
                        TextStyle(fontSize: 11.5, color: colors.textSoft),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          _sectionHeader(
              '技能 (${_skills.length} · 已启用 ${_skills.where((s) => s['enabled'] == true).length})'),
          if (_skills.isEmpty)
            Text('暂无技能',
                style:
                    TextStyle(fontSize: 11.5, color: colors.textFaint))
          else
            for (final s in _skills)
              Card(
                margin: const EdgeInsets.only(bottom: 6),
                child: ExpansionTile(
                  tilePadding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
                  dense: true,
                  title: Row(
                    children: [
                      Expanded(
                        child: Text('${s['name'] ?? s['id'] ?? '?'}',
                            style: const TextStyle(
                                fontSize: 13, fontWeight: FontWeight.w600)),
                      ),
                      _StatusPill(enabled: s['enabled'] == true),
                    ],
                  ),
                  subtitle: Text(
                    '${s['description'] ?? ''}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style:
                        TextStyle(fontSize: 11, color: colors.textFaint),
                  ),
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SelectableText(
                            '${s['description'] ?? ''}',
                            style:
                                const TextStyle(fontSize: 11.5, height: 1.5),
                          ),
                          const SizedBox(height: 6),
                          SelectableText(
                            const JsonEncoder.withIndent('  ').convert(s),
                            style: const TextStyle(
                                fontFamily: 'monospace', fontSize: 9.5),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
          const SizedBox(height: 14),
          _sectionHeader('命令 (${_commands.length})'),
          if (_commands.isEmpty)
            Text('暂无自定义命令',
                style:
                    TextStyle(fontSize: 11.5, color: colors.textFaint))
          else
            for (final c in _commands)
              Card(
                margin: const EdgeInsets.only(bottom: 6),
                child: ExpansionTile(
                  tilePadding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
                  dense: true,
                  title: Text('${c['name'] ?? '?'}',
                      style: const TextStyle(
                          fontSize: 13, fontWeight: FontWeight.w600)),
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                      child: SelectableText(
                        '${c['prompt'] ?? ''}',
                        style: const TextStyle(fontSize: 11, height: 1.5),
                      ),
                    ),
                  ],
                ),
              ),
        ],
      ),
    );
  }

  Widget _sectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(title,
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
    );
  }
}

class _ServiceList extends StatefulWidget {
  final Future<dynamic> Function() loader;
  final String Function(Map<String, dynamic>) titleOf;
  final String Function(Map<String, dynamic>) subtitleOf;

  /// When set, each row shows a prominent 已启用/未启用 pill.
  final bool Function(Map<String, dynamic>)? enabledOf;

  const _ServiceList({
    required this.loader,
    required this.titleOf,
    required this.subtitleOf,
    this.enabledOf,
  });

  @override
  State<_ServiceList> createState() => _ServiceListState();
}

class _ServiceListState extends State<_ServiceList>
    with AutomaticKeepAliveClientMixin {
  Object? _data;
  String? _error;
  bool _loading = true;

  @override
  bool get wantKeepAlive => true;

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
      final res = await widget.loader();
      if (mounted) {
        setState(() {
          _data = res;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = '$e';
          _loading = false;
        });
      }
    }
  }

  List<Map<String, dynamic>> get _items {
    final data = _data;
    List? list;
    if (data is List) {
      list = data;
    } else if (data is Map) {
      for (final key in const [
        'items',
        'plugins',
        'automations',
        'installedPlugins',
        'availablePlugins',
      ]) {
        if (data[key] is List) {
          list = data[key] as List;
          break;
        }
      }
    }
    if (list == null) return const [];
    return list
        .whereType<Map>()
        .map((e) => e.cast<String, dynamic>())
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final colors = EmberColors.of(context);
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('加载失败: $_error',
                  style: TextStyle(color: Colors.red.shade200),
                  textAlign: TextAlign.center),
              const SizedBox(height: 12),
              OutlinedButton(
                  onPressed: _load, child: const Text('重试')),
            ],
          ),
        ),
      );
    }
    final items = _items;
    if (items.isEmpty) {
      return RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          children: [
            const SizedBox(height: 80),
            Center(
              child: SelectableText(
                _data == null
                    ? '（空）'
                    : const JsonEncoder.withIndent('  ').convert(_data),
                style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 11,
                    color: colors.textMuted),
              ),
            ),
          ],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        padding: const EdgeInsets.all(16),
        itemCount: items.length,
        separatorBuilder: (_, __) => const SizedBox(height: 8),
        itemBuilder: (context, index) {
          final item = items[index];
          final enabledOf = widget.enabledOf;
          return Card(
            child: ExpansionTile(
              title: Row(
                children: [
                  Expanded(
                    child: Text(widget.titleOf(item),
                        style: const TextStyle(fontSize: 14)),
                  ),
                  if (enabledOf != null)
                    _StatusPill(enabled: enabledOf(item)),
                ],
              ),
              subtitle: Text(widget.subtitleOf(item),
                  style: TextStyle(
                      fontSize: 11, color: colors.textFaint)),
              children: [
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: SelectableText(
                    const JsonEncoder.withIndent('  ').convert(item),
                    style: const TextStyle(
                        fontFamily: 'monospace', fontSize: 10.5),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// Prominent enabled/disabled pill (same visual language as the provider
/// page badges).
class _StatusPill extends StatelessWidget {
  final bool enabled;

  const _StatusPill({required this.enabled});

  @override
  Widget build(BuildContext context) {
    final colors = EmberColors.of(context);
    final color = enabled ? colors.ok : colors.textFaint;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(7),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Text(
        enabled ? '已启用' : '未启用',
        style: TextStyle(
            fontSize: 10, color: color, fontWeight: FontWeight.w600),
      ),
    );
  }
}
