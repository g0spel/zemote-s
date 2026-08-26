import 'dart:async';

import 'package:flutter/material.dart';

import '../protocol/channel_client.dart';
import '../protocol/zemote_client.dart';
import 'theme.dart';

/// Typed wrapper over the `zcode-agent` automation RPCs (arg shapes
/// verified live against the desktop):
///   listAutomations / listAutomationRuns / createAutomation /
///   updateAutomation / setAutomationEnabled / deleteAutomation
///   runAutomationNow / restartAutomation
/// (the last two + the lifecycleStatus/scheduleRule fields were adopted
/// from an upstream discovery; schemas verified in the host bundle).
/// plus the `off-peak-task` queue `list`.
/// Human-readable schedule: prefers the structured `scheduleRule`
/// ({unit: minute|hour|day|week, interval, hour, minute, weekday}) and
/// falls back to the raw cron expression. Pure for tests.
String scheduleLabel(Map<String, dynamic> automation) {
  final rule = automation['scheduleRule'];
  final cron = '${automation['cronExpr'] ?? ''}';
  if (rule is! Map) return cron.isEmpty ? '—' : cron;
  final unit = '${rule['unit'] ?? ''}';
  final interval = (rule['interval'] as num?)?.toInt() ?? 1;
  String two(int v) => v.toString().padLeft(2, '0');
  switch (unit) {
    case 'minute':
      return interval == 1 ? '每分钟' : '每 $interval 分钟';
    case 'hour':
      return interval == 1 ? '每小时' : '每 $interval 小时';
    case 'day':
      final h = (rule['hour'] as num?)?.toInt() ?? 0;
      final m = (rule['minute'] as num?)?.toInt() ?? 0;
      return interval == 1 ? '每天 ${two(h)}:${two(m)}' : '每 $interval 天 ${two(h)}:${two(m)}';
    case 'week':
      const names = ['周日', '周一', '周二', '周三', '周四', '周五', '周六'];
      final dow = rule['weekday'] ?? rule['dayOfWeek'];
      final idx = dow is num ? dow.toInt() : -1;
      final h = (rule['hour'] as num?)?.toInt() ?? 0;
      final m = (rule['minute'] as num?)?.toInt() ?? 0;
      final day = idx >= 0 && idx < 7 ? names[idx] : '每周';
      return '$day ${two(h)}:${two(m)}';
    default:
      return cron.isEmpty ? '—' : cron;
  }
}

/// Chinese label for the automation lifecycle (host enum:
/// active|completed|failed|paused). Null for active — the default needs
/// no badge.
String? lifecycleLabel(String status) => switch (status) {
      'completed' => '已完成',
      'failed' => '失败',
      'paused' => '已暂停',
      _ => null,
    };

class AutomationApi {
  final BridgeSession bridge;
  final Map<String, dynamic> scope;

  AutomationApi({required this.bridge, required this.scope});

  Future<dynamic> _agent(String method, Map<String, dynamic> extra) =>
      bridge.channels.call(Channels.zcodeAgent, method, [
        {...scope, ...extra},
      ]);

  Future<List<Map<String, dynamic>>> listAutomations() async =>
      _asMaps(await _agent('listAutomations', {}));

  Future<List<Map<String, dynamic>>> listRuns(String automationId) async =>
      _asMaps(await _agent('listAutomationRuns', {'automationId': automationId}));

  Future<void> setEnabled(String automationId, bool enabled) =>
      _agent('setAutomationEnabled', {
        'automationId': automationId,
        'enabled': enabled,
      });

  Future<void> delete(String automationId) =>
      _agent('deleteAutomation', {'automationId': automationId});

  /// Queues an immediate run. Returns 'queued' | 'duplicate' | 'failed'.
  Future<String> runNow(String automationId) async {
    try {
      final res = await _agent(
          'runAutomationNow', {'automationId': automationId});
      return res is Map ? '${res['status'] ?? 'queued'}' : 'queued';
    } on ChannelRpcError {
      return 'failed';
    }
  }

  /// Restarts a completed/errored automation back to active scheduling.
  Future<void> restart(String automationId) =>
      _agent('restartAutomation', {'automationId': automationId});

  Future<void> create({
    required String title,
    required String cronExpr,
    required String prompt,
  }) =>
      _agent('createAutomation', {
        'title': title,
        'cronExpr': cronExpr,
        'prompt': prompt,
      });

  Future<void> update({
    required String automationId,
    String? title,
    String? cronExpr,
    String? prompt,
  }) =>
      _agent('updateAutomation', {
        'automationId': automationId,
        if (title != null) 'title': title,
        if (cronExpr != null) 'cronExpr': cronExpr,
        if (prompt != null) 'prompt': prompt,
      });

  /// Off-peak (闲时算力) queue — separate channel, read-only.
  Future<List<Map<String, dynamic>>> offPeakQueue() async {
    final res = await bridge.channels.call(
        Channels.offPeakTask, 'list', [scope],
        timeout: const Duration(seconds: 8));
    return _asMaps(res);
  }

  static List<Map<String, dynamic>> _asMaps(dynamic res) {
    if (res is! List) return const [];
    return [
      for (final e in res)
        if (e is Map) e.cast<String, dynamic>(),
    ];
  }
}

String _fmtMs(num? v) {
  if (v == null) return '';
  final d = DateTime.fromMillisecondsSinceEpoch(v.toInt());
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
}

class AutomationPage extends StatefulWidget {
  final BridgeSession bridge;
  final Map<String, dynamic> workspace;

  /// Opens a task chat by sessionId (from a run's history entry).
  final void Function(String taskId, String title) onOpenTask;

  const AutomationPage({
    super.key,
    required this.bridge,
    required this.workspace,
    required this.onOpenTask,
  });

  @override
  State<AutomationPage> createState() => _AutomationPageState();
}

class _AutomationPageState extends State<AutomationPage> {
  late final AutomationApi _api;

  List<Map<String, dynamic>> _automations = const [];
  Map<String, List<Map<String, dynamic>>> _runs = {};
  List<Map<String, dynamic>> _queue = const [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _api = AutomationApi(
      bridge: widget.bridge,
      scope: {
        'workspacePath': widget.workspace['workspacePath'],
        if (widget.workspace['workspaceIdentity'] != null)
          'workspaceIdentity': widget.workspace['workspaceIdentity'],
      },
    );
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final autos = await _api.listAutomations();
      final runs = <String, List<Map<String, dynamic>>>{};
      await Future.wait(autos.map((a) async {
        final id = '${a['automationId']}';
        try {
          runs[id] = await _api.listRuns(id);
        } catch (_) {
          runs[id] = const [];
        }
      }));
      List<Map<String, dynamic>> queue = const [];
      try {
        queue = await _api.offPeakQueue();
      } catch (_) {}
      if (!mounted) return;
      setState(() {
        _automations = autos;
        _runs = runs;
        _queue = queue;
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

  Future<void> _toggle(String id, bool enabled) async {
    try {
      await _api.setEnabled(id, enabled);
      await _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('操作失败: $e')));
      }
    }
  }

  Future<void> _delete(Map<String, dynamic> a) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除自动化'),
        content: Text('确定删除「${a['title']}」？执行历史将一并删除。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('删除')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await _api.delete('${a['automationId']}');
      await _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('删除失败: $e')));
      }
    }
  }

  Future<void> _showEditor({Map<String, dynamic>? existing}) async {
    final saved = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => _AutomationEditor(api: _api, existing: existing),
    );
    if (saved == true) await _load();
  }

  Future<void> _runNow(Map<String, dynamic> a) async {
    final status = await _api.runNow('${a['automationId']}');
    if (!mounted) return;
    final message = switch (status) {
      'queued' => '已加入执行队列',
      'duplicate' => '该自动化已有执行在进行',
      _ => '触发失败',
    };
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
    if (status == 'queued') _load();
  }

  Future<void> _restart(Map<String, dynamic> a) async {
    try {
      await _api.restart('${a['automationId']}');
      await _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('重启失败: $e')));
      }
    }
  }

  void _showDetail(Map<String, dynamic> a) {
    final id = '${a['automationId']}';
    final runs = _runs[id] ?? const [];
    final lifecycle = lifecycleLabel('${a['lifecycleStatus'] ?? ''}');
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        builder: (context, scrollController) => ListView(
          controller: scrollController,
          padding: const EdgeInsets.all(16),
          children: [
            Row(
              children: [
                Expanded(
                    child: Text('${a['title']}',
                        style: const TextStyle(
                            fontSize: 16, fontWeight: FontWeight.w600))),
                IconButton(
                  icon: const Icon(Icons.play_arrow, size: 22),
                  tooltip: '立即运行',
                  onPressed: () => _runNow(a),
                ),
                if (lifecycle != null)
                  IconButton(
                    icon: const Icon(Icons.restart_alt, size: 20),
                    tooltip: '重新启动排程',
                    onPressed: () => _restart(a),
                  ),
                IconButton(
                  icon: const Icon(Icons.edit_outlined, size: 20),
                  tooltip: '编辑',
                  onPressed: () {
                    Navigator.pop(context);
                    _showEditor(existing: a);
                  },
                ),
                IconButton(
                  icon: Icon(Icons.delete_outline,
                      size: 20, color: ZColors.danger),
                  tooltip: '删除',
                  onPressed: () {
                    Navigator.pop(context);
                    _delete(a);
                  },
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '${scheduleLabel(a)} · 模式 ${a['mode'] ?? '-'} · '
              '${a['provider'] ?? '-'} · ${a['model'] ?? '-'}'
              '${lifecycle != null ? ' · $lifecycle' : ''}',
              style: TextStyle(fontSize: 11, color: ZInk.faint(context)),
            ),
            const SizedBox(height: 8),
            Text(
              '已运行 ${a['runCount'] ?? 0} 次 · '
              '下次 ${_fmtMs(a['nextRunAt'] as num?)} · '
              '上次 ${_fmtMs(a['lastRunAt'] as num?)}',
              style: TextStyle(fontSize: 11, color: ZInk.faint(context)),
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: ZInk.tile(context),
                borderRadius: BorderRadius.circular(10),
              ),
              child: SelectableText(
                '${a['prompt'] ?? ''}',
                style: const TextStyle(fontSize: 11.5, height: 1.5),
              ),
            ),
            const SizedBox(height: 14),
            const Text('执行历史',
                style:
                    TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            if (runs.isEmpty)
              Text('暂无执行记录',
                  style: TextStyle(fontSize: 11.5, color: ZInk.faint(context)))
            else
              for (final r in runs)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  leading: Icon(
                    '${r['outcome']}' == 'succeeded'
                        ? Icons.check_circle
                        : Icons.error_outline,
                    size: 16,
                    color: '${r['outcome']}' == 'succeeded'
                        ? ZColors.success
                        : ZColors.danger,
                  ),
                  title: Text(
                    '${r['outcome'] ?? r['dispatchStatus'] ?? ''}'
                    ' · ${r['trigger'] ?? ''}',
                    style: const TextStyle(fontSize: 12),
                  ),
                  subtitle: Text(
                    _fmtMs(r['scheduledAt'] as num?),
                    style: TextStyle(fontSize: 10.5, color: ZInk.faint(context)),
                  ),
                  trailing: r['sessionId'] is String
                      ? const Icon(Icons.chevron_right, size: 18)
                      : null,
                  onTap: () {
                    final sid = r['sessionId'];
                    if (sid is! String) return;
                    Navigator.pop(context);
                    widget.onOpenTask(sid, '${a['title']}');
                  },
                ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('加载失败: $_error',
                style: TextStyle(color: ZColors.danger, fontSize: 12)),
            const SizedBox(height: 8),
            FilledButton(onPressed: _load, child: const Text('重试')),
          ],
        ),
      );
    }
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 12, 6),
          child: Row(
            children: [
              Text('自动化',
                  style: const TextStyle(
                      fontSize: 22, fontWeight: FontWeight.w700)),
              const SizedBox(width: 8),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(
                  color: ZColors.primary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text('Beta',
                    style: TextStyle(
                        fontSize: 10, color: ZColors.primary)),
              ),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.add),
                tooltip: '新建自动化',
                onPressed: () => _showEditor(),
              ),
              IconButton(
                icon: const Icon(Icons.refresh),
                tooltip: '刷新',
                onPressed: _load,
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
            children: [
              if (_automations.isEmpty && _queue.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 40),
                  child: Center(
                    child: Text('暂无自动化，点右上角 + 新建',
                        style: TextStyle(
                            fontSize: 12, color: ZInk.faint(context))),
                  ),
                ),
              for (final a in _automations)
                _automationTile(context, a),
              if (_queue.isNotEmpty) ...[
                Padding(
                  padding: const EdgeInsets.only(top: 16, bottom: 6),
                  child: Text('闲时任务队列',
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: ZInk.faint(context))),
                ),
                for (final q in _queue)
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.schedule, size: 18),
                    title: Text('${q['title'] ?? q['offPeakTaskId'] ?? '闲时任务'}',
                        style: const TextStyle(fontSize: 12)),
                    subtitle: Text(
                      '${q['status'] ?? ''}'
                      '${q['queuePosition'] != null ? ' · 队列位置 ${q['queuePosition']}' : ''}',
                      style:
                          TextStyle(fontSize: 10.5, color: ZInk.faint(context)),
                    ),
                  ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _automationTile(BuildContext context, Map<String, dynamic> a) {
    final id = '${a['automationId']}';
    final enabled = a['enabled'] == true;
    final runs = _runs[id] ?? const [];
    final lastOutcome = runs.isEmpty ? null : '${runs.first['outcome']}';
    final lifecycle = lifecycleLabel('${a['lifecycleStatus'] ?? ''}');
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: ZInk.tile(context),
        borderRadius: BorderRadius.circular(12),
      ),
      child: ListTile(
        onTap: () => _showDetail(a),
        title: Row(
          children: [
            Flexible(
              child: Text('${a['title']}',
                  style:
                      const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis),
            ),
            if (lifecycle != null) ...[
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 5, vertical: 1),
                decoration: BoxDecoration(
                  color: ('${a['lifecycleStatus']}' == 'failed'
                          ? ZColors.danger
                          : ZInk.faint(context))
                      .withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(5),
                ),
                child: Text(lifecycle,
                    style: TextStyle(
                        fontSize: 9.5,
                        color: '${a['lifecycleStatus']}' == 'failed'
                            ? ZColors.danger
                            : ZInk.faint(context))),
              ),
            ],
          ],
        ),
        subtitle: Text(
          [
            scheduleLabel(a),
            '下次 ${_fmtMs(a['nextRunAt'] as num?)}',
            '已运行 ${a['runCount'] ?? 0} 次',
            if (lastOutcome != null)
              lastOutcome == 'succeeded' ? '上次成功' : '上次失败',
            if (!enabled) '已停用',
          ].join(' · '),
          style: TextStyle(fontSize: 10.5, color: ZInk.faint(context)),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: Switch(
          value: enabled,
          onChanged: (v) => _toggle(id, v),
        ),
      ),
    );
  }
}

/// Create / edit form. Templates mirror the desktop's official preset
/// library (weekly review / morning brief / risk scan).
class _AutomationEditor extends StatefulWidget {
  final AutomationApi api;
  final Map<String, dynamic>? existing;

  const _AutomationEditor({required this.api, this.existing});

  @override
  State<_AutomationEditor> createState() => _AutomationEditorState();
}

class _AutomationTemplate {
  final String label;
  final String cron;
  final String prompt;
  const _AutomationTemplate(this.label, this.cron, this.prompt);
}

const _templates = [
  _AutomationTemplate('每周回顾', '0 16 * * 5',
      '基于当前项目中可验证的活动生成精简周五回顾，汇总本周变更和待跟进事项；无法获取的信息明确标注，不修改代码或外部状态。'),
  _AutomationTemplate('晨会动态', '0 9 * * 1-5',
      '汇总上一个工作日以来的提交、模块变化、CI 状态和待跟进事项，生成不超过 5 条的晨会口述摘要。只读分析，只使用可验证的仓库事实。'),
  _AutomationTemplate('风险扫描', '0 10 * * *',
      '检查最近 24 小时的代码变更，识别运行错误、数据丢失、权限绕过、资源泄漏等高置信风险，并附代码和 commit/diff 证据。只读分析。'),
];

class _AutomationEditorState extends State<_AutomationEditor> {
  late final TextEditingController _title;
  late final TextEditingController _cron;
  late final TextEditingController _prompt;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _title = TextEditingController(text: '${e?['title'] ?? ''}');
    _cron = TextEditingController(text: '${e?['cronExpr'] ?? ''}');
    _prompt = TextEditingController(text: '${e?['prompt'] ?? ''}');
  }

  @override
  void dispose() {
    _title.dispose();
    _cron.dispose();
    _prompt.dispose();
    super.dispose();
  }

  Future<void> _save(AutomationApi api) async {
    final title = _title.text.trim();
    final cron = _cron.text.trim();
    final prompt = _prompt.text.trim();
    if (title.isEmpty || cron.isEmpty || prompt.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('标题、Cron 表达式和提示词都必填')));
      return;
    }
    setState(() => _saving = true);
    try {
      final e = widget.existing;
      if (e == null) {
        await api.create(title: title, cronExpr: cron, prompt: prompt);
      } else {
        await api.update(
          automationId: '${e['automationId']}',
          title: title,
          cronExpr: cron,
          prompt: prompt,
        );
      }
      if (mounted) Navigator.pop(context, true);
    } catch (err) {
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('保存失败: $err')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final editing = widget.existing != null;
    return AlertDialog(
      title: Text(editing ? '编辑自动化' : '新建自动化'),
      content: SizedBox(
        width: double.maxFinite,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (!editing)
                Wrap(
                  spacing: 6,
                  children: [
                    for (final t in _templates)
                      ActionChip(
                        label: Text(t.label, style: const TextStyle(fontSize: 11)),
                        onPressed: () {
                          _cron.text = t.cron;
                          _prompt.text = t.prompt;
                          if (_title.text.trim().isEmpty) _title.text = t.label;
                        },
                      ),
                  ],
                ),
              if (!editing) const SizedBox(height: 10),
              TextField(
                controller: _title,
                decoration: const InputDecoration(
                    labelText: '标题', isDense: true),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _cron,
                decoration: const InputDecoration(
                  labelText: 'Cron 表达式',
                  hintText: '0 9 * * *（每天 9 点）',
                  isDense: true,
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _prompt,
                maxLines: 6,
                decoration: const InputDecoration(
                  labelText: '提示词（每次运行发给智能体的任务）',
                  alignLabelWithHint: true,
                  isDense: true,
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消')),
        FilledButton(
          onPressed: _saving ? null : () => _save(widget.api),
          child: _saving
              ? const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('保存'),
        ),
      ],
    );
  }
}
