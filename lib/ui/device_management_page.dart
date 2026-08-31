import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../protocol/connection_params.dart';
import '../protocol/relay_client.dart';
import '../state/account_store.dart';
import '../state/app_session.dart';
import 'qr_scan_page.dart';
import 'theme.dart';

/// 设备管理页(设备列表新家):增删改查 + 导入导出。连接由壳自动化,
/// 此页只管理设备档案,不再提供"点击连接"手势。
class DeviceManagementPage extends StatefulWidget {
  final AccountStore store;
  final AppSession session;

  /// 当前活跃设备已打开的工作区标题(壳层取自 activeWorkspace 传入)。
  /// null/空 = 无已知工作区,设备卡不显示该行。
  final String? activeWorkspaceTitle;

  const DeviceManagementPage({
    super.key,
    required this.store,
    required this.session,
    this.activeWorkspaceTitle,
  });

  @override
  State<DeviceManagementPage> createState() => _DeviceManagementPageState();
}

class _DeviceManagementPageState extends State<DeviceManagementPage> {
  @override
  void initState() {
    super.initState();
    if (!widget.store.loaded) {
      widget.store.load().then((_) {
        if (mounted) setState(() {});
      });
    }
  }

  /// Exports all devices to a JSON file (backup / transfer). The connection
  /// URLs contain credentials — warn the user before sharing.
  Future<void> _exportDevices(BuildContext context) async {
    final json = widget.store.exportJson();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('导出设备'),
        content: const Text(
            '将导出全部设备及连接 URL。\n⚠️ URL 包含设备凭据，相当于密码，请妥善保管，勿分享给他人。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('导出'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    try {
      final path = await FilePicker.saveFile(
        dialogTitle: '导出设备',
        fileName: 'zflow-devices.json',
        bytes: utf8.encode(json),
      );
      if (path == null) return; // cancelled
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content:
                Text('已导出 ${widget.store.accounts.length} 台设备')));
      }
    } catch (e) {
      // Fallback: hand the JSON to the user via clipboard.
      await Clipboard.setData(ClipboardData(text: json));
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('保存文件失败，已将导出内容复制到剪贴板')));
      }
    }
  }

  /// Imports devices from a JSON export file.
  Future<void> _importDevices(BuildContext context) async {
    try {
      final files = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json'],
      );
      if (files.isEmpty) return;
      final bytes = await files.first.readAsBytes();
      final count = await widget.store.importJson(utf8.decode(bytes));
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(
              count > 0 ? '导入 $count 台设备' : '没有可导入的新设备')));
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('导入失败: $e')));
      }
    }
  }

  /// Devices on a non-official relay host receive every message the user
  /// sends. Confirm before saving so a swapped QR code can't silently
  /// redirect conversations to an attacker's server.
  Future<bool> _confirmUnofficialUrl(String url) async {
    final params = ZflowConnectionParams.parse(url);
    if (params == null || params.isOfficialHost) return true;
    if (!mounted) return false;
    final go = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('非官方服务器'),
        content: Text(
          '该链接指向 ${params.source.host}，不是官方地址 zcode.z.ai。\n'
          '连接后，你发送的所有对话内容都会经过这台服务器。'
          '仅在你确信来源可靠时继续。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('仍要添加'),
          ),
        ],
      ),
    );
    return go ?? false;
  }

  Future<void> _addByUrl() async {
    final controller = TextEditingController();
    final url = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('粘贴远程控制 URL'),
        content: TextField(
          controller: controller,
          maxLines: 4,
          style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
          decoration: const InputDecoration(
            hintText: 'https://zcode.z.ai/remote/v4?sid=...&hash=...&t=...',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(context, controller.text.trim()),
            child: const Text('添加'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (url == null || url.isEmpty) return;
    if (ZflowConnectionParams.parse(url) == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('无法解析该链接：需为 https 且包含 sid、hash、t 参数')),
        );
      }
      return;
    }
    if (!await _confirmUnofficialUrl(url)) return;
    await widget.store.addUrl(url);
  }

  Future<void> _addByScan() async {
    final url = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const QrScanPage()),
    );
    if (url == null || url.isEmpty) return;
    if (ZflowConnectionParams.parse(url) == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('二维码内容不是有效链接：需为 https 且包含 sid、hash、t 参数')),
        );
      }
      return;
    }
    if (!await _confirmUnofficialUrl(url)) return;
    await widget.store.addUrl(url);
  }

  void _showAddSheet() {
    showModalBottomSheet(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.qr_code_scanner),
              title: const Text('扫码添加'),
              subtitle: const Text('扫描桌面端远程控制二维码'),
              onTap: () {
                Navigator.pop(context);
                _addByScan();
              },
            ),
            ListTile(
              leading: const Icon(Icons.link),
              title: const Text('粘贴链接添加'),
              subtitle: const Text('输入 https://zcode.z.ai/remote/v4?... 链接'),
              onTap: () {
                Navigator.pop(context);
                _addByUrl();
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _rename(Account account) async {
    final controller = TextEditingController(text: account.label);
    final label = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('重命名设备'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (label != null) await widget.store.rename(account.id, label);
  }

  Future<void> _delete(Account account) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除设备？'),
        content: Text('将移除「${account.label}」的连接信息'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      if (widget.session.isConnected(account.id)) {
        await widget.session.disconnect(account.id);
      }
      await widget.store.remove(account.id);
    }
  }

  String _stateText(RelayState state) {
    switch (state) {
      case RelayState.connecting:
        return '连接中转服务…';
      case RelayState.authenticating:
        return '认证设备…';
      case RelayState.waiting:
        return '等待桌面端配对…';
      case RelayState.paired:
        return '已连接';
      case RelayState.reconnecting:
        return '重连中…';
      case RelayState.error:
        return '连接失败';
      case RelayState.kicked:
        return '已被踢下线';
      default:
        return '';
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = EmberColors.of(context);
    return AnimatedBuilder(
      animation: Listenable.merge([widget.store, widget.session]),
      builder: (context, _) {
        final accounts = widget.store.accounts;
        final session = widget.session;
        return Scaffold(
          backgroundColor: colors.bg,
          appBar: AppBar(
            title: const Text('设备管理',
                style: TextStyle(fontSize: EmberType.section)),
            actions: [
              PopupMenuButton<String>(
                tooltip: '更多',
                onSelected: (v) {
                  if (v == 'import') _importDevices(context);
                  if (v == 'export') _exportDevices(context);
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'import', child: Text('导入设备')),
                  PopupMenuItem(value: 'export', child: Text('导出设备')),
                ],
              ),
            ],
          ),
          body: ListView(
            padding: const EdgeInsets.all(EmberSpacing.page),
            children: [
              for (var i = 0; i < accounts.length; i++) ...[
                if (i > 0) const SizedBox(height: EmberSpacing.gapS),
                _DeviceCard(
                  account: accounts[i],
                  isCurrent: session.current?.id == accounts[i].id,
                  session: session,
                  activeWorkspaceTitle: widget.activeWorkspaceTitle,
                  stateText: _stateText,
                  onRename: () => _rename(accounts[i]),
                  onDelete: () => _delete(accounts[i]),
                ),
              ],
              const SizedBox(height: EmberSpacing.gapS),
              _DashedAddButton(onTap: _showAddSheet),
            ],
          ),
        );
      },
    );
  }
}

/// 单台设备卡:头像 + 名称 + 在线态 + 当前工作区(仅活跃设备有本地已知
/// 数据,其余设备不显示该行);操作仅重命名/删除(连接自动化,无连接手势)。
class _DeviceCard extends StatelessWidget {
  final Account account;
  final bool isCurrent;
  final AppSession session;
  final String? activeWorkspaceTitle;
  final String Function(RelayState) stateText;
  final VoidCallback onRename;
  final VoidCallback onDelete;

  const _DeviceCard({
    required this.account,
    required this.isCurrent,
    required this.session,
    required this.activeWorkspaceTitle,
    required this.stateText,
    required this.onRename,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final colors = EmberColors.of(context);
    final client = session.clientOf(account.id);
    final connecting = session.connecting(account.id);
    final error = session.errorOf(account.id);
    final host = account.params?.source.host ?? '';
    final label = account.label;
    return Container(
      decoration: BoxDecoration(
        color: colors.card,
        borderRadius: BorderRadius.circular(EmberRadius.control),
        border: Border.all(color: colors.hairline),
      ),
      padding:
          const EdgeInsets.symmetric(horizontal: EmberSpacing.cardPad, vertical: EmberSpacing.listItemV),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: colors.primary.withValues(alpha: isCurrent ? 0.22 : 0.12),
              borderRadius: BorderRadius.circular(EmberRadius.avatar),
            ),
            child: Text(
              label.isEmpty ? '?' : label[0],
              style: TextStyle(
                fontSize: EmberType.emphasis,
                fontWeight: FontWeight.w700,
                color: colors.primary,
              ),
            ),
          ),
          const SizedBox(width: EmberSpacing.gapM),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label,
                    style: TextStyle(
                        fontSize: EmberType.emphasis,
                        fontWeight: FontWeight.w600,
                        color: colors.textSolid)),
                const SizedBox(height: 2),
                Text(host,
                    style: TextStyle(
                        fontSize: EmberType.caption,
                        color: colors.textFaint)),
                if (isCurrent &&
                    (activeWorkspaceTitle ?? '').isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text('当前工作区:$activeWorkspaceTitle',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: EmberType.caption,
                          color: colors.textMuted)),
                ],
                if (client != null)
                  ValueListenableBuilder<RelayState>(
                    valueListenable: client.relay.stateListenable,
                    builder: (context, state, _) {
                      if (connecting &&
                          state != RelayState.paired &&
                          state != RelayState.error) {
                        return _PairSteps(state: state, colors: colors);
                      }
                      final text = stateText(state);
                      if (text.isEmpty) return const SizedBox.shrink();
                      return Text(
                        text,
                        style: TextStyle(
                          fontSize: EmberType.caption,
                          color: state == RelayState.paired
                              ? colors.ok
                              : state == RelayState.error ||
                                      state == RelayState.kicked
                                  ? colors.err
                                  : colors.warn,
                        ),
                      );
                    },
                  )
                else if (error != null)
                  Text(error,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style:
                          TextStyle(fontSize: EmberType.caption, color: colors.err))
                else if (connecting)
                  Text('正在连接…',
                      style: TextStyle(
                          fontSize: EmberType.caption, color: colors.warn))
                else
                  Text('未连接',
                      style: TextStyle(
                          fontSize: EmberType.caption, color: colors.textFaint)),
              ],
            ),
          ),
          // 手动重连(zremote 吸收):有凭据但未在连接时允许一键重连,
          // 配合自动恢复兜底。
          if (account.params != null && !connecting)
            IconButton(
              icon: Icon(Icons.refresh,
                  size: 18, color: colors.textMuted),
              tooltip: session.isConnected(account.id) ? '重连' : '连接',
              onPressed: () async {
                try {
                  await session.connect(account);
                } catch (_) {
                  // 失败详情已在卡片状态与 errorOf 里展示。
                }
              },
            ),
          IconButton(
            icon: Icon(Icons.edit_outlined,
                size: 18, color: colors.textMuted),
            tooltip: '重命名',
            onPressed: onRename,
          ),
          IconButton(
            icon: Icon(Icons.delete_outline, size: 18, color: colors.err),
            tooltip: '删除',
            onPressed: onDelete,
          ),
        ],
      ),
    );
  }
}

/// 虚线描边添加按钮(spec §7.3:扫码添加虚线按钮)。
class _DashedAddButton extends StatelessWidget {
  final VoidCallback onTap;

  const _DashedAddButton({required this.onTap});

  @override
  Widget build(BuildContext context) {
    final colors = EmberColors.of(context);
    final line = colors.primary.withValues(alpha: 0.55);
    return InkWell(
      borderRadius: BorderRadius.circular(EmberRadius.control),
      onTap: onTap,
      child: CustomPaint(
        painter: _DashedRectPainter(color: line),
        child: Container(
          height: 52,
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: EmberSpacing.page),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.add, size: 18, color: line),
              const SizedBox(width: EmberSpacing.gapS),
              Text('添加设备',
                  style: TextStyle(
                      fontSize: EmberType.emphasis,
                      fontWeight: FontWeight.w600,
                      color: line)),
            ],
          ),
        ),
      ),
    );
  }
}

class _DashedRectPainter extends CustomPainter {
  final Color color;

  _DashedRectPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    const dashWidth = 5.0;
    const dashGap = 4.0;
    final rect = Offset.zero & size;
    final rrect = RRect.fromRectAndRadius(
        rect, const Radius.circular(EmberRadius.control));
    final path = Path()..addRRect(rrect);
    final dashed = Path();
    for (final metric in path.computeMetrics()) {
      var distance = 0.0;
      while (distance < metric.length) {
        final next = distance + dashWidth;
        dashed.addPath(
          metric.extractPath(distance, next.clamp(0.0, metric.length)),
          Offset.zero,
        );
        distance = next + dashGap;
      }
    }
    canvas.drawPath(
        dashed, Paint()..style = PaintingStyle.stroke..color = color);
  }

  @override
  bool shouldRepaint(_DashedRectPainter old) => old.color != color;
}

/// 4-step pairing progress (mirrors the web bootstrap steps).
class _PairSteps extends StatelessWidget {
  final RelayState state;
  final EmberColors colors;

  const _PairSteps({required this.state, required this.colors});

  static const _steps = ['连接中转', '设备认证', '等待配对', '完成'];

  @override
  Widget build(BuildContext context) {
    final current = switch (state) {
      RelayState.connecting => 0,
      RelayState.authenticating => 1,
      RelayState.waiting => 2,
      _ => 3,
    };
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < _steps.length; i++) ...[
            if (i > 0)
              Container(
                width: 10,
                height: 1,
                color: i <= current ? colors.ok : colors.textFaint,
              ),
            Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: i < current
                    ? colors.ok
                    : i == current
                        ? colors.warn
                        : colors.textFaint,
              ),
            ),
            const SizedBox(width: 3),
            Text(
              _steps[i],
              style: TextStyle(
                fontSize: 9,
                color: i <= current ? colors.textSoft : colors.textFaint,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
