import 'package:flutter_test/flutter_test.dart';

import 'package:zflow/ui/chat_page.dart';
import 'package:zflow/ui/theme.dart';

/// 模型 pill 的模式徽段映射(spec §7.1:build 默认不显示;
/// 计划橙/编辑蓝/YOLO 红;桌面端自定义模式原样透传)。
void main() {
  group('modeBadge', () {
    test('build → null:默认模式不显示徽段', () {
      expect(modeBadge('build'), isNull);
    });

    test('plan/edit/yolo → 定案徽标文案', () {
      expect(modeBadge('plan'), '计划');
      expect(modeBadge('edit'), '编辑');
      expect(modeBadge('yolo'), 'YOLO');
    });

    test('未知模式 → 原值透传(桌面端新增模式不丢信息)', () {
      expect(modeBadge('custom'), 'custom');
    });
  });

  group('modeBadgeColor', () {
    final c = EmberColors.dark();

    test('plan → primary(Ember 橙)、edit → run(蓝)、yolo → err(红)', () {
      expect(modeBadgeColor('plan', c), c.primary);
      expect(modeBadgeColor('edit', c), c.run);
      expect(modeBadgeColor('yolo', c), c.err);
    });

    test('其余(build/未知)→ muted', () {
      expect(modeBadgeColor('build', c), c.textMuted);
      expect(modeBadgeColor('custom', c), c.textMuted);
    });
  });
}
