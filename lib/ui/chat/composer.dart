// 此文件是 chat_page.dart 的一部分(part):同库共享导入与私有类可见。
part of '../chat_page.dart';

/// "+"面板(U2):先出分类入口(Skills/斜杠命令/附件/添加上下文),
/// 点进分类再列明细,避免一打开就是一整面列表。
class _PlusSheet extends StatefulWidget {
  final List<_SlashItem> slashItems;
  final bool loading;
  final void Function(String insert) onSelect;
  final VoidCallback onAttach;
  final Future<void> Function() onRefresh;

  const _PlusSheet({
    required this.slashItems,
    required this.loading,
    required this.onSelect,
    required this.onAttach,
    required this.onRefresh,
  });

  @override
  State<_PlusSheet> createState() => _PlusSheetState();
}

class _PlusSheetState extends State<_PlusSheet> {
  /// null = 分类首页;'skills' / 'commands' = 对应明细列表。
  String? _section;

  @override
  Widget build(BuildContext context) {
    final colors = EmberColors.of(context);
    final commands =
        widget.slashItems.where((i) => !i.isSkill).toList(growable: false);
    final skills =
        widget.slashItems.where((i) => i.isSkill).toList(growable: false);

    Widget section(String title, List<_SlashItem> items) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (items.isEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 6),
                child: Text('无',
                    style: TextStyle(
                        fontSize: 12, color: colors.textFaint)),
              )
            else
              for (final item in items)
                ListTile(
                  dense: true,
                  leading: Text(item.isSkill ? r'$' : '/',
                      style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          fontFamily: EmberFonts.term,
                          color: colors.primary)),
                  title: Text(item.name,
                      style: const TextStyle(fontSize: 13)),
                  subtitle: item.description.isNotEmpty
                      ? Text(item.description,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 11, color: colors.textFaint))
                      : null,
                  onTap: () => widget.onSelect(item.insert),
                ),
          ],
        );

    Widget body;
    if (_section == 'skills' || _section == 'commands') {
      body = section(_section == 'skills' ? 'Skills' : '斜杠命令',
          _section == 'skills' ? skills : commands);
    } else {
      body = Column(children: [
        _plusCategory(context, Icons.auto_awesome_outlined, 'Skills',
            '${skills.length} 项', () => setState(() => _section = 'skills')),
        _plusCategory(
            context,
            Icons.terminal,
            '斜杠命令',
            '${commands.length} 项',
            () => setState(() => _section = 'commands')),
        _plusCategory(context, Icons.attach_file, '附件', '选择文件上传',
            () => widget.onAttach()),
        _plusCategory(context, Icons.data_object_outlined, '添加上下文',
            '选择文件并插入引用', () => widget.onAttach()),
      ]);
    }

    return SafeArea(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Row(children: [
              if (_section != null)
                IconButton(
                  icon: const Icon(Icons.arrow_back, size: 18),
                  tooltip: '返回',
                  onPressed: () => setState(() => _section = null),
                )
              else
                const SizedBox(width: 40),
              Text(
                  _section == 'skills'
                      ? 'Skills'
                      : _section == 'commands'
                          ? '斜杠命令'
                          : '插入',
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w600)),
              const Spacer(),
              if (widget.loading)
                const SizedBox(
                    width: 16,
                    height: 16,
                    child:
                        CircularProgressIndicator(strokeWidth: 2))
              else
                IconButton(
                  icon: Icon(Icons.refresh,
                      size: 18, color: colors.textMuted),
                  tooltip: '刷新',
                  onPressed: widget.onRefresh,
                ),
            ]),
          ),
        ),
        Flexible(
          child: SingleChildScrollView(child: body),
        ),
        const SizedBox(height: 8),
      ]),
    );
  }

  Widget _plusCategory(BuildContext context, IconData icon, String title,
      String subtitle, VoidCallback onTap) {
    final colors = EmberColors.of(context);
    return ListTile(
      leading: Container(
        width: 34,
        height: 34,
        decoration: BoxDecoration(
          color: colors.primary.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(EmberRadius.control),
        ),
        child: Icon(icon, size: 18, color: colors.primary),
      ),
      title: Text(title, style: const TextStyle(fontSize: 14)),
      subtitle: Text(subtitle,
          style: TextStyle(fontSize: 11, color: colors.textFaint)),
      trailing: Icon(Icons.chevron_right,
          size: 18, color: colors.textFaint),
      onTap: onTap,
    );
  }
}

/// 会话设置面板图标行(桌面同款布局)。按钮全部压缩密度,整行高度约为
/// 常规 IconButton 行的一半。
class _InputBar extends StatelessWidget {
  final TextEditingController controller;
  final bool sending;

  /// 会话运行中:占位文案切「排队」语义,输入为空时发送键变停止。
  final bool running;

  /// 排队中的乐观消息数(桌面 √N 徽标)。
  final int queueCount;

  /// 当前协作模式 value(空则不渲染模式按钮)与菜单回调。
  final String? modeValue;
  final VoidCallback? onPickMode;

  final VoidCallback onSend;
  final VoidCallback onStop;
  final VoidCallback onPlusMenu;
  final VoidCallback? onPickModel;
  final VoidCallback? onPickThought;
  final VoidCallback? onPickUsage;

  const _InputBar({
    required this.controller,
    required this.sending,
    required this.running,
    required this.queueCount,
    this.modeValue,
    this.onPickMode,
    required this.onSend,
    required this.onStop,
    required this.onPlusMenu,
    this.onPickModel,
    this.onPickThought,
    this.onPickUsage,
  });

  /// 模式 → 图标(随模式变化,plan/yolo 高亮警示色)。
  static const _modeIcons = {
    'build': Icons.build,
    'edit': Icons.edit_note,
    'plan': Icons.checklist,
    'yolo': Icons.bolt,
  };

  @override
  Widget build(BuildContext context) {
    final colors = EmberColors.of(context);
    final mode = modeValue;
    final modeHot = mode == 'plan' || mode == 'yolo';
    final modeIcon = _modeIcons[mode] ?? Icons.tune;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 6, 14, 12),
        child: Container(
          padding: const EdgeInsets.fromLTRB(8, 2, 2, 2),
          decoration: BoxDecoration(
            color: colors.card,
            borderRadius: BorderRadius.circular(EmberRadius.control + 4),
            border: Border.all(color: colors.hairline),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: controller,
                minLines: 1,
                maxLines: 5,
                style: const TextStyle(fontSize: 14),
                decoration: InputDecoration(
                  hintText: running ? '继续输入以排队后续修改' : '向 ZCode 提问…',
                  border: InputBorder.none,
                  isDense: true,
                ),
                textInputAction: TextInputAction.newline,
              ),
              Row(
                children: [
                  _barButton(
                    context,
                    icon: Icons.add,
                    tooltip: 'Skills / 命令 / 附件',
                    onPressed: sending ? null : onPlusMenu,
                  ),
                  if (mode != null)
                    _barButton(
                      context,
                      icon: modeIcon,
                      tooltip: '协作模式 · $mode',
                      color: modeHot ? colors.warn : colors.textMuted,
                      onPressed: sending ? null : onPickMode,
                    ),
                  if (queueCount > 0)
                    Padding(
                      padding: const EdgeInsets.only(left: 2),
                      child: Text('√$queueCount',
                          style: TextStyle(
                              fontSize: 10.5,
                              fontWeight: FontWeight.w600,
                              color: colors.textMuted)),
                    ),
                  const Spacer(),
                  if (onPickUsage != null)
                    _barButton(
                      context,
                      icon: Icons.donut_small,
                      tooltip: '上下文与用量',
                      onPressed: onPickUsage,
                    ),
                  if (onPickModel != null)
                    _barButton(
                      context,
                      icon: Icons.view_in_ar,
                      tooltip: '模型',
                      onPressed: onPickModel,
                    ),
                  if (onPickThought != null)
                    _barButton(
                      context,
                      icon: Icons.psychology,
                      tooltip: '思考档',
                      onPressed: onPickThought,
                    ),
                  _SendOrStop(
                    controller: controller,
                    sending: sending,
                    running: running,
                    onSend: onSend,
                    onStop: onStop,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 图标行按钮:常规紧凑尺寸。
  Widget _barButton(
    BuildContext context, {
    required IconData icon,
    required String tooltip,
    required VoidCallback? onPressed,
    Color? color,
  }) {
    return IconButton(
      onPressed: onPressed,
      tooltip: tooltip,
      visualDensity: VisualDensity.compact,
      icon: Icon(icon, size: 22, color: color ?? EmberColors.of(context).textMuted),
    );
  }
}

/// 发送/停止键:会话运行中且输入为空 → 停止方块(桌面同款);其余状态
/// 为发送箭头(发送在途显转圈)。与图标行同高。
class _SendOrStop extends StatelessWidget {
  final TextEditingController controller;
  final bool sending;
  final bool running;
  final VoidCallback onSend;
  final VoidCallback onStop;

  const _SendOrStop({
    required this.controller,
    required this.sending,
    required this.running,
    required this.onSend,
    required this.onStop,
  });

  @override
  Widget build(BuildContext context) {
    final colors = EmberColors.of(context);
    const size = 40.0;
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: controller,
      builder: (context, value, _) {
        final empty = value.text.trim().isEmpty;
        if (running && empty) {
          return Tooltip(
            message: '停止',
            child: InkWell(
              onTap: onStop,
              borderRadius: BorderRadius.circular(EmberRadius.control),
              child: Container(
                width: size,
                height: size,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: colors.raise,
                  borderRadius: BorderRadius.circular(EmberRadius.control),
                ),
                child: Icon(Icons.stop, size: 24, color: colors.textSolid),
              ),
            ),
          );
        }
        return Tooltip(
          message: '发送',
          child: InkWell(
            onTap: sending ? null : onSend,
            customBorder: const CircleBorder(),
            child: Container(
              width: size,
              height: size,
              alignment: Alignment.center,
              decoration:
                  BoxDecoration(color: colors.primary, shape: BoxShape.circle),
              child: sending
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white),
                    )
                  : const Icon(Icons.arrow_upward,
                      color: Colors.white, size: 24),
            ),
          ),
        );
      },
    );
  }
}
