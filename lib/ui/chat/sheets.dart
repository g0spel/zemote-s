// 此文件是 chat_page.dart 的一部分(part):同库共享导入与私有类可见。
part of '../chat_page.dart';

// ---------------------------------------------------------------- sheets

/// 会话设置面板的分区:模型列表 / 思考档(按所选模型实际支持的档位)。
enum _SheetSection { model, thought }

class _ModelModeSheet extends StatefulWidget {
  final ConversationState? state;
  final ConversationTransport transport;
  final WorkspacePrep? prep;
  final String? sessionId;
  final Map<String, String>? draftConfig;
  final bool Function() isSourceCurrent;

  /// 本次面板展示的分区(模型按钮/思考按钮分别打开对应分区)。
  final _SheetSection section;

  /// 打开时的实时取数(新鲜度窗内不发请求);null 退回 [prep] 缓存。
  final Future<WorkspacePrep?> Function()? onRefreshPrep;
  final void Function(String key, String value)? onDraftChange;

  const _ModelModeSheet({
    required this.state,
    required this.transport,
    required this.isSourceCurrent,
    required this.section,
    this.prep,
    this.sessionId,
    this.draftConfig,
    this.onRefreshPrep,
    this.onDraftChange,
  });

  @override
  State<_ModelModeSheet> createState() => _ModelModeSheetState();
}

/// Stateful 的原因:面板内点选必须立即反映(此前 StatelessWidget 只在
/// 重开面板时才看到新值);草稿选择镜像在 [_draft],会话态变化经
/// AnimatedBuilder 跟进。prep 取数也在此层:打开先用缓存,后台拉到
/// 新数据后原地替换(模型列表增删即时可见)。
class _ModelModeSheetState extends State<_ModelModeSheet> {
  late final Map<String, String> _draft =
      Map.of(widget.draftConfig ?? const {});

  WorkspacePrep? _freshPrep;
  bool _refreshing = false;
  int _refreshGeneration = 0;
  Future<void> _applyQueue = Future.value();
  int _applyGeneration = 0;
  String? _desiredProvider;
  String? _desiredModel;
  String? _desiredThought;

  void _primeDesiredConfig(
    String modelValue,
    String thoughtValue,
    Map<String, dynamic> config,
  ) {
    if (_desiredProvider != null &&
        _desiredModel != null &&
        _desiredThought != null) {
      return;
    }
    final (provider, model) = modelValue.isNotEmpty
        ? providerModelOf(_prep, modelValue)
        : ('${config['provider'] ?? ''}', '${config['model'] ?? ''}');
    _desiredProvider ??= provider;
    _desiredModel ??= model;
    _desiredThought ??= thoughtValue;
  }

  void _setDesiredModel(
    String modelValue,
    String thoughtValue,
    Map<String, dynamic> config,
  ) {
    _primeDesiredConfig(modelValue, thoughtValue, config);
    final (provider, model) = providerModelOf(_prep, modelValue);
    _desiredProvider = provider;
    _desiredModel = model;
    _desiredThought = thoughtValue;
  }

  void _setDesiredThought(
    String modelValue,
    String thoughtValue,
    Map<String, dynamic> config,
  ) {
    _primeDesiredConfig(modelValue, thoughtValue, config);
    _desiredThought = thoughtValue;
  }

  Future<dynamic> _switchConfig(
    String sid,
    Map<String, dynamic> patch,
  ) {
    return widget.transport.switchModelConfig(
      sid,
      provider: '${patch['provider'] ?? ''}',
      model: '${patch['model'] ?? ''}',
      thought: '${patch['thought'] ?? ''}',
    );
  }

  Map<String, dynamic> _desiredConfigPatch() => {
        'provider': _desiredProvider,
        'model': _desiredModel,
        'thought': _desiredThought,
      };

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void didUpdateWidget(covariant _ModelModeSheet oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.transport != widget.transport ||
        oldWidget.sessionId != widget.sessionId ||
        oldWidget.onRefreshPrep != widget.onRefreshPrep) {
      _applyGeneration++;
      _refreshGeneration++;
      _freshPrep = null;
      _desiredProvider = null;
      _desiredModel = null;
      _desiredThought = null;
      _refresh();
    }
  }

  @override
  void dispose() {
    _applyGeneration++;
    _refreshGeneration++;
    super.dispose();
  }

  Future<void> _refresh() async {
    final refresh = widget.onRefreshPrep;
    if (refresh == null) return;
    final generation = ++_refreshGeneration;
    if (mounted && widget.isSourceCurrent()) {
      setState(() => _refreshing = true);
    }
    try {
      final fresh = await refresh();
      if (!mounted ||
          generation != _refreshGeneration ||
          !widget.isSourceCurrent()) {
        return;
      }
      setState(() {
        _refreshing = false;
        if (fresh != null) _freshPrep = fresh;
      });
    } catch (_) {
      if (mounted &&
          generation == _refreshGeneration &&
          widget.isSourceCurrent()) {
        setState(() => _refreshing = false);
      }
    }
  }

  WorkspacePrep? get _prep => _freshPrep ?? widget.prep;

  bool get _isDraft => widget.sessionId == null || widget.sessionId!.isEmpty;

  void _setDraft(String key, String value) {
    if (!widget.isSourceCurrent()) return;
    setState(() => _draft[key] = value);
    widget.onDraftChange?.call(key, value);
  }

  /// Config options beyond the model/mode/thought selects (e.g. max output
  /// length, search enhancement) surfaced read-only from prepareWorkspace.
  List<ConfigOption> get _otherOptions {
    const known = {'model', 'mode', 'thought_level'};
    final options = _prep?.configOptions;
    if (options == null) return const [];
    return options.where((o) => !known.contains(o.id)).toList();
  }

  @override
  Widget build(BuildContext context) {
    // 会话态驱动(乐观补丁/宿主确认)时整面板跟随重建;draft 态由
    // _setDraft 的 setState 驱动。
    final state = widget.state;
    if (state != null) {
      return AnimatedBuilder(
          animation: Listenable.merge([
            state.configListenable,
            state.controlListenable,
          ]),
          builder: (context, _) => _content(context));
    }
    return _content(context);
  }

  Widget _content(BuildContext context) {
    final config = widget.state?.config ?? const {};
    final modelOption = _prep?.option('model');
    final thoughtOption = _prep?.option('thought_level');

    // Current selection: prefer the LIVE session config (updates after a
    // switch), fall back to prepareWorkspace's currentValue / draft.
    final liveModelValue =
        '${config['provider'] ?? ''}/${config['model'] ?? ''}';
    final currentModelValue =
        _isDraft || config['model'] == null || '${config['model']}'.isEmpty
            ? (_draft['model'] ?? '${modelOption?.currentValue ?? ''}')
            : liveModelValue;
    final currentThoughtValue = _isDraft
        ? (_draft['thought'] ?? '${thoughtOption?.currentValue ?? ''}')
        : (widget.state?.currentThought.isNotEmpty == true
            ? widget.state!.currentThought
            : '${thoughtOption?.currentValue ?? ''}');
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
                widget.section == _SheetSection.thought
                    ? '思考等级'
                    : (_isDraft ? '新会话 · 模型' : '模型'),
                style:
                    const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            if (_refreshing)
              const Padding(
                padding: EdgeInsets.only(top: 6),
                child: SizedBox(
                  height: 2,
                  child: LinearProgressIndicator(minHeight: 2),
                ),
              ),
            const SizedBox(height: 16),
            if (widget.section == _SheetSection.thought)
              ..._thoughtSection(
                  context, currentModelValue, currentThoughtValue, config)
            else
              ..._modelSection(context, currentModelValue, config),
          ],
        ),
      ),
    );
  }

  /// 思考档可选项:按当前所选模型实际支持的档位
  /// ([ConfigOptionValue.modelThoughtLevels])过滤;模型未声明档位时回退
  /// 全部档位。返回 (value, 显示名) 对。
  List<(String, String)> _thoughtChoices(String currentModelValue) {
    final thoughtOption = _prep?.option('thought_level');
    final all = thoughtOption?.options ?? const <ConfigOptionValue>[];
    ConfigOptionValue? entry;
    for (final o in _prep?.option('model')?.options ??
        const <ConfigOptionValue>[]) {
      if (o.value == currentModelValue) entry = o;
    }
    final levels = entry?.modelThoughtLevels ?? const [];
    if (levels.isEmpty) {
      return [for (final o in all) (o.value, o.name)];
    }
    final choices = <(String, String)>[];
    for (final level in levels) {
      (String, String)? match;
      for (final o in all) {
        if (o.value == level) match = (o.value, o.name);
      }
      if (match == null) {
        for (final o in all) {
          if (o.name == level) match = (o.value, o.name);
        }
      }
      choices.add(match ?? (level, level));
    }
    return choices;
  }

  List<Widget> _thoughtSection(
    BuildContext context,
    String currentModelValue,
    String currentThoughtValue,
    Map<String, dynamic> config,
  ) {
    final choices = _thoughtChoices(currentModelValue);
    final liveThought = widget.state?.currentThought;
    return [
      if (choices.isEmpty)
        Text('当前模型未提供思考档位',
            style: TextStyle(
                fontSize: 12,
                color: EmberColors.of(context).textMuted))
      else
        Wrap(
          spacing: 8,
          children: [
            for (final (value, name) in choices)
              ChoiceChip(
                label: Text(name),
                selected: currentThoughtValue == value ||
                    widget.state?.currentThought == value,
                onSelected: (_) {
                  if (_isDraft) {
                    _setDraft('thought', value);
                  } else {
                    _setDesiredThought(currentModelValue, value, config);
                    final configPatch = _desiredConfigPatch();
                    _apply(
                      context,
                      () => _switchConfig(widget.sessionId!, configPatch),
                      onAccepted: () => widget.state?.optimisticPatch({
                        'config': {
                          ...?widget.state!.config,
                          ...configPatch,
                        },
                      }),
                    );
                  }
                },
              ),
          ],
        ),
      if (liveThought != null && liveThought.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 10),
          child: Text('当前: $liveThought',
              style: TextStyle(
                  fontSize: 11.5, color: EmberColors.of(context).textMuted)),
        ),
    ];
  }

  List<Widget> _modelSection(
    BuildContext context,
    String currentModelValue,
    Map<String, dynamic> config,
  ) {
    final modelOption = _prep?.option('model');
    return [
      if (modelOption != null && modelOption.options.isNotEmpty) ...[
        Text(modelOption.name, style: const TextStyle(fontSize: 13)),
        const SizedBox(height: 8),
        for (final v in modelOption.options)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(
              currentModelValue == v.value
                  ? Icons.radio_button_checked
                  : Icons.radio_button_off,
              size: 18,
              color: currentModelValue == v.value
                  ? EmberColors.of(context).primary
                  : EmberColors.of(context).textFaint,
            ),
            title: Text(v.name, style: const TextStyle(fontSize: 13)),
            subtitle: v.modelProviderName != null
                ? Text(v.modelProviderName!,
                    style: TextStyle(
                        fontSize: 11,
                        color: EmberColors.of(context).textFaint))
                : null,
            onTap: () {
              if (_isDraft) {
                _setDraft('model', v.value);
              } else {
                // thought must be valid for the target model:
                // keep current if supported, else fall back to the
                // thought option's currentValue (Turbo: enabled/off)
                final currentThought = widget.state?.currentThought ?? '';
                final thoughtOpt = _prep?.option('thought_level');
                final thought = currentThought.isNotEmpty &&
                        (thoughtOpt?.options
                                .any((o) => o.value == currentThought) ??
                            false)
                    ? currentThought
                    : '${thoughtOpt?.currentValue ?? (currentThought.isNotEmpty ? currentThought : 'enabled')}';
                _setDesiredModel(v.value, thought, config);
                final configPatch = _desiredConfigPatch();
                _apply(
                  context,
                  () => _switchConfig(widget.sessionId!, configPatch),
                  onAccepted: () => widget.state?.optimisticPatch({
                    'config': {
                      ...?widget.state!.config,
                      ...configPatch,
                    },
                  }),
                );
              }
            },
          ),
      ] else
        Text('当前模型: ${widget.state?.currentModel ?? ''}',
            style: TextStyle(
                fontSize: 12, color: EmberColors.of(context).textMuted)),
      if (_otherOptions.isNotEmpty) ...[
        const SizedBox(height: 16),
        const Text('其他配置', style: TextStyle(fontSize: 13)),
        const SizedBox(height: 8),
        for (final o in _otherOptions)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(o.name, style: const TextStyle(fontSize: 13)),
                ),
                const SizedBox(width: 8),
                Text('${o.currentValue}',
                    style: TextStyle(
                        fontSize: 12,
                        color: EmberColors.of(context).textMuted)),
              ],
            ),
          ),
      ],
    ];
  }

  Future<void> _apply(
    BuildContext context,
    Future<dynamic> Function() run, {
    void Function()? onAccepted,
  }) async {
    final transport = widget.transport;
    final applyGeneration = ++_applyGeneration;
    if (!widget.isSourceCurrent()) return;
    Future<dynamic> runIfCurrent() {
      if (!mounted ||
          transport != widget.transport ||
          !widget.isSourceCurrent()) {
        return Future<dynamic>.value(null);
      }
      return run();
    }
    final queued = _applyQueue.then<dynamic>(
      (_) => runIfCurrent(),
      onError: (_, _) => runIfCurrent(),
    );
    _applyQueue = queued.then<void>(
      (_) {},
      onError: (_, _) {},
    );
    try {
      final res = await queued;
      if (!mounted ||
          applyGeneration != _applyGeneration ||
          transport != widget.transport ||
          !widget.isSourceCurrent() ||
          !context.mounted) {
        return;
      }
      if (isRpcRejected(res)) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('被拒绝: ${rpcFailureReason(res)}')));
      } else {
        onAccepted?.call();
        if (context.mounted && widget.isSourceCurrent()) Navigator.pop(context);
      }
    } catch (e) {
      if (mounted &&
          applyGeneration == _applyGeneration &&
          transport == widget.transport &&
          widget.isSourceCurrent() &&
          context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('失败: $e')));
      }
    }
  }
}

/// 用量数字的「万 tokens」单位显示:≥1 万以 x.x 万呈现,小值原样。
/// (553000 → 55.3 万)
String formatTokenCount(num v) =>
    v >= 10000 ? '${(v / 10000).toStringAsFixed(1)} 万' : '$v';

class _UsageSheet extends StatefulWidget {
  final ConversationState state;
  final BridgeSession session;
  final Map<String, dynamic> scope;
  final String sessionId;
  final bool Function() isSourceCurrent;

  const _UsageSheet({
    required this.state,
    required this.session,
    required this.scope,
    required this.sessionId,
    required this.isSourceCurrent,
  });

  @override
  State<_UsageSheet> createState() => _UsageSheetState();
}

class _UsageSheetState extends State<_UsageSheet> {
  bool _querying = false;
  int _queryGeneration = 0;

  /// 上下文容量头(桌面 ○ 面板同款):用量/上限 + 百分比 + 进度条。
  Widget _contextCapacityHeader(Map<dynamic, dynamic> contextWindow) {
    final used = (contextWindow['usedTokens'] as num?) ?? 0;
    final max = (contextWindow['maxTokens'] as num?) ?? 0;
    final percent = max > 0 ? (used / max * 100) : 0.0;
    final colors = EmberColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text('上下文容量',
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: colors.textSolid)),
            const Spacer(),
            Text(
              '${formatTokenCount(used)} / ${formatTokenCount(max)}'
              '${max > 0 ? ' (${percent.toStringAsFixed(1)}%)' : ''}',
              style: TextStyle(fontSize: 11, color: colors.textMuted),
            ),
          ],
        ),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: SizedBox(
            height: 6,
            child: LinearProgressIndicator(
              value: max > 0 ? (used / max).clamp(0.0, 1.0) : 0,
              backgroundColor: colors.hairline,
              color: percent >= 90 ? colors.err : colors.primary,
            ),
          ),
        ),
        const SizedBox(height: 14),
      ],
    );
  }

  @override
  void dispose() {
    _queryGeneration++;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final usage = widget.state.usage ?? const {};
    final cumulative = usage['cumulative'];
    final contextWindow = usage['contextWindow'];
    // 缓存命中率 = 命中读取 / (命中读取 + 未命中净输入):输入侧有多大
    // 比例直接走了缓存。无输入时不显示(除零无意义)。
    final cacheRead = (cumulative?['cacheReadTokens'] as num?) ?? 0;
    final netInput = (cumulative?['inputTokens'] as num?) ?? 0;
    final cacheDenom = cacheRead + netInput;
    final cacheHitRate = cacheDenom > 0
        ? '${(cacheRead / cacheDenom * 100).toStringAsFixed(1)}%'
        : null;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('用量统计',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            const SizedBox(height: 16),
            if (contextWindow is Map) ...[
              _contextCapacityHeader(contextWindow),
            ],
            if (cumulative is Map) ...[
              _UsageRow('累计输入', '${formatTokenCount(netInput)} tokens'),
              _UsageRow('累计输出',
                  '${formatTokenCount((cumulative['outputTokens'] as num?) ?? 0)} tokens'),
              _UsageRow('缓存读取', '${formatTokenCount(cacheRead)} tokens'),
              _UsageRow('缓存写入',
                  '${formatTokenCount((cumulative['cacheWriteTokens'] as num?) ?? 0)} tokens'),
              if (cacheHitRate != null) _UsageRow('缓存命中率', cacheHitRate),
            ],
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                icon: const Icon(Icons.query_stats, size: 16),
                label: const Text('查询任务级用量 (getTaskTokenUsage)'),
                onPressed: _querying ? null : _queryTaskUsage,
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                icon: const Icon(Icons.savings_outlined, size: 16),
                label: const Text('剩余额度(5小时/每周/工具调用/MCP)'),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(
                      builder: (_) => UsagePage(session: widget.session)),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _queryTaskUsage() async {
    if (!mounted || _querying || !widget.isSourceCurrent()) return;
    final generation = ++_queryGeneration;
    setState(() => _querying = true);
    try {
      final res = await widget.session.channels.call(
        Channels.zcodeTask,
        'getTaskTokenUsage',
        [
          {...widget.scope, 'taskId': widget.sessionId},
        ],
      );
      if (!mounted ||
          generation != _queryGeneration ||
          !widget.isSourceCurrent()) {
        return;
      }
      showModalBottomSheet(
        context: context,
        builder: (context) => _JsonSheet(title: '任务用量', data: res),
      );
    } catch (e) {
      if (mounted &&
          generation == _queryGeneration &&
          widget.isSourceCurrent()) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('查询失败: $e')));
      }
    } finally {
      if (mounted &&
          generation == _queryGeneration &&
          widget.isSourceCurrent()) {
        setState(() => _querying = false);
      }
    }
  }
}

class _UsageRow extends StatelessWidget {
  final String label;
  final String value;

  const _UsageRow(this.label, this.value);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label,
              style: TextStyle(
                  fontSize: 13, color: EmberColors.of(context).textMuted)),
          Text(value,
              style: const TextStyle(fontSize: 13, fontFamily: 'monospace')),
        ],
      ),
    );
  }
}

class _JsonSheet extends StatelessWidget {
  final String title;
  final Object? data;

  const _JsonSheet({required this.title, required this.data});

  @override
  Widget build(BuildContext context) {
    const encoder = JsonEncoder.withIndent('  ');
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title,
                style:
                    const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            const SizedBox(height: 12),
            Flexible(
              child: SingleChildScrollView(
                child: SelectableText(
                  data == null ? '（无数据）' : encoder.convert(data),
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- input

/// One entry in the slash popup: a builtin/custom command or a skill.
class _SlashItem {
  final String name;
  final String description;
  final String insert;
  final bool isSkill;

  const _SlashItem({
    required this.name,
    required this.description,
    required this.insert,
    this.isSkill = false,
  });
}

class _SlashCommandBar extends StatelessWidget {
  final String query;
  final List<_SlashItem> items;
  final void Function(_SlashItem item) onSelect;

  const _SlashCommandBar({
    required this.query,
    required this.items,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    final q = query.startsWith('/') || query.startsWith('\$')
        ? query.substring(1)
        : query;
    final filtered = q.isEmpty
        ? items
        : items
            .where((c) => c.name.toLowerCase().startsWith(q.toLowerCase()))
            .toList();
    if (filtered.isEmpty) {
      return Container(
        margin: const EdgeInsets.fromLTRB(14, 4, 14, 0),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text('没有匹配的命令',
            style: TextStyle(
                fontSize: 12, color: EmberColors.of(context).textFaint)),
      );
    }
    return Container(
      margin: const EdgeInsets.fromLTRB(14, 4, 14, 0),
      constraints: const BoxConstraints(maxHeight: 260),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
      ),
      child: ListView(
        shrinkWrap: true,
        children: [
          for (final command in filtered)
            ListTile(
              dense: true,
              leading: Icon(
                command.isSkill
                    ? Icons.auto_awesome_outlined
                    : (command.name == 'compact' ? Icons.compress : Icons.bolt),
                size: 16,
                color: command.isSkill
                    ? EmberColors.of(context).warn
                    : EmberColors.of(context).primary,
              ),
              title: Text(
                  command.isSkill ? '\$${command.name}' : '/${command.name}',
                  style:
                      const TextStyle(fontSize: 13, fontFamily: 'monospace')),
              subtitle: Text(
                command.description,
                style: TextStyle(
                    fontSize: 11, color: EmberColors.of(context).textFaint),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              onTap: () => onSelect(command),
            ),
        ],
      ),
    );
  }
}
