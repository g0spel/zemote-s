import 'package:flutter/material.dart';

/// 按压缩放反馈(spec §5 动效):按下缩至 0.98,150ms easeOut 回弹。
/// 用 [Listener] 读原始指针事件,不参与手势竞技场——子树的
/// InkWell/GestureDetector(点击、涟漪、长按)行为不受影响,纯呈现。
class EmberPressable extends StatefulWidget {
  final Widget child;

  const EmberPressable({super.key, required this.child});

  @override
  State<EmberPressable> createState() => _EmberPressableState();
}

class _EmberPressableState extends State<EmberPressable> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: (_) => setState(() => _pressed = true),
      onPointerUp: (_) => setState(() => _pressed = false),
      onPointerCancel: (_) => setState(() => _pressed = false),
      child: AnimatedScale(
        scale: _pressed ? 0.98 : 1.0,
        duration: const Duration(milliseconds: 150),
        curve: Curves.easeOut,
        child: widget.child,
      ),
    );
  }
}
