// 此文件是 chat_page.dart 的一部分(part):同库共享导入与私有类可见。
part of '../chat_page.dart';

/// 输入框左侧的协作模式按钮(U2):上图标下简称的紧凑两行,点击弹出
/// 模式菜单。宿主模式名往往很长(如 "Ask before changes"),此处用
/// 简称映射;未知模式回退 value 前 4 字符。modeValue 为空不渲染。
class _ModeButton extends StatelessWidget {
  final String? modeValue;
  final VoidCallback? onTap;

  const _ModeButton({this.modeValue, this.onTap});

  static const _abbr = {
    'build': ('构建', Icons.build),
    'edit': ('编辑', Icons.edit_note),
    'plan': ('计划', Icons.checklist),
    'yolo': ('自主', Icons.bolt),
  };

  @override
  Widget build(BuildContext context) {
    final v = modeValue;
    if (v == null || v.isEmpty) return const SizedBox.shrink();
    final colors = EmberColors.of(context);
    final (name, icon) = _abbr[v] ??
        (v.length > 4 ? v.substring(0, 4) : v, Icons.tune);
    return InkWell(
      borderRadius: BorderRadius.circular(EmberRadius.control),
      onTap: onTap,
      child: Container(
        width: 44,
        height: 40,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(EmberRadius.control),
          border: Border.all(color: colors.hairline),
        ),
        child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 15, color: colors.primary),
              Text(name,
                  style: TextStyle(
                      fontSize: 9,
                      fontWeight: FontWeight.w600,
                      color: colors.textMuted)),
            ]),
      ),
    );
  }
}

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

class _InputBar extends StatelessWidget {
  final TextEditingController controller;
  final bool sending;
  final VoidCallback onSend;
  final VoidCallback onPlusMenu;

  /// 当前协作模式 value(空则不渲染模式按钮)与菜单回调(U2)。
  final String? modeLabel;
  final VoidCallback? onPickMode;

  const _InputBar({
    required this.controller,
    required this.sending,
    required this.onSend,
    this.modeLabel,
    this.onPickMode,
    required this.onPlusMenu,
  });

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 6, 14, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            _ModeButton(
              modeValue: modeLabel,
              onTap: sending ? null : onPickMode,
            ),
            IconButton(
              icon: Icon(Icons.add_circle_outline,
                  size: 22, color: EmberColors.of(context).textMuted),
              tooltip: 'Skills / 命令 / 附件',
              onPressed: sending ? null : onPlusMenu,
            ),
            Expanded(
              child: TextField(
                controller: controller,
                minLines: 1,
                maxLines: 5,
                style: const TextStyle(fontSize: 14),
                decoration: const InputDecoration(
                  hintText: '向 ZCode 发送消息…',
                ),
                textInputAction: TextInputAction.newline,
              ),
            ),
            const SizedBox(width: 10),
            Container(
              decoration: BoxDecoration(
                color: EmberColors.of(context).primary,
                shape: BoxShape.circle,
              ),
              child: IconButton(
                onPressed: sending ? null : onSend,
                icon: sending
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white),
                      )
                    : const Icon(Icons.arrow_upward,
                        color: Colors.white, size: 20),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
