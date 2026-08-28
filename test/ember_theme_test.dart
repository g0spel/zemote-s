// test/ember_theme_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zemote/ui/theme.dart';

void main() {
  group('EmberColors', () {
    test('dark palette matches spec', () {
      final c = EmberColors.dark();
      expect(c.bg, const Color(0xFF1B1917));
      expect(c.card, const Color(0xFF262320));
      expect(c.raise, const Color(0xFF35302B));
      expect(c.hairline, const Color(0xFF3A342E));
      expect(c.primary, const Color(0xFFD97757));
      expect(c.ok, const Color(0xFF7FB069));
      expect(c.err, const Color(0xFFE5484D));
      expect(c.warn, const Color(0xFFD4A72C));
      expect(c.run, const Color(0xFF6A9BD8));
      expect(c.textSolid, const Color(0xFFEEE7DC));
      expect(c.textSoft, const Color(0xFFC9BFAF));
      expect(c.textMuted, const Color(0xFF8A8074));
      expect(c.textFaint, const Color(0xFF5C554B));
      expect(c.isDark, isTrue);
    });

    test('light palette matches spec', () {
      final c = EmberColors.light();
      expect(c.bg, const Color(0xFFF7F3EC));
      expect(c.card, const Color(0xFFFFFFFF));
      expect(c.raise, const Color(0xFFEFE9DF));
      expect(c.primary, const Color(0xFFC25E3A));
      expect(c.textSolid, const Color(0xFF2A241E));
      expect(c.textSoft, const Color(0xFF4A4238));
      expect(c.textMuted, const Color(0xFF786D5E));
      expect(c.textFaint, const Color(0xFFA69B8C));
      expect(c.isDark, isFalse);
    });

    testWidgets('EmberColors.of follows theme brightness', (tester) async {
      late EmberColors captured;
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(brightness: Brightness.light),
          home: Builder(
            builder: (context) {
              captured = EmberColors.of(context);
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      expect(captured.bg, const Color(0xFFF7F3EC));
    });
  });

  group('Ember tokens', () {
    test('radius dual-track matches spec', () {
      expect(EmberRadius.content, 16.0);
      expect(EmberRadius.bubbleTail, 4.0);
      expect(EmberRadius.sheet, 20.0);
      expect(EmberRadius.control, 10.0);
      expect(EmberRadius.avatar, 8.0);
    });

    test('spacing grid is 4px-aligned', () {
      expect(EmberSpacing.page, 16.0);
      expect(EmberSpacing.cardPad, 12.0);
      expect(EmberSpacing.gapS, 8.0);
      expect(EmberSpacing.gapM, 12.0);
      for (final v in [EmberSpacing.page, EmberSpacing.cardPad,
        EmberSpacing.listItemV, EmberSpacing.listItemH,
        EmberSpacing.gapS, EmberSpacing.gapM]) {
        expect(v % 4, 0, reason: '4px 网格对齐');
      }
    });

    test('type scale matches spec', () {
      expect(EmberType.title, 22.0);
      expect(EmberType.section, 17.0);
      expect(EmberType.emphasis, 15.0);
      expect(EmberType.body, 13.0);
      expect(EmberType.secondary, 12.0);
      expect(EmberType.caption, 11.0);
    });
  });

  testWidgets('app theme uses Sarasa UI family', (tester) async {
    late ThemeData theme;
    await tester.pumpWidget(MaterialApp(
      theme: buildDarkTheme(),
      home: Builder(builder: (context) {
        theme = Theme.of(context);
        return const SizedBox.shrink();
      }),
    ));
    expect(theme.textTheme.bodyMedium!.fontFamily, 'Sarasa UI SC');
  });
}
