import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Design tokens + theme controller (dark / light / system, persisted).
class ThemeController extends ChangeNotifier {
  static const _prefsKey = 'zflow_theme_mode';

  ThemeMode _mode = ThemeMode.dark;
  ThemeMode get mode => _mode;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_prefsKey);
    _mode = switch (saved) {
      'light' => ThemeMode.light,
      'system' => ThemeMode.system,
      _ => ThemeMode.dark,
    };
    notifyListeners();
  }

  Future<void> setMode(ThemeMode mode) async {
    _mode = mode;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _prefsKey,
      switch (mode) {
        ThemeMode.light => 'light',
        ThemeMode.system => 'system',
        _ => 'dark',
      },
    );
  }
}

/// 全局主题接线 Ember 色板(spec §2):ColorScheme 直构、组件主题取同一
/// 色板,页面无需再做局部覆盖。slot → token 映射:
///   primary / onPrimary              = Ember primary / 白字
///   secondary 三槽                   = primary / raise / textSolid
///     (SegmentedButton、ChoiceChip、FilledButton.tonal 选中态取用)
///   surface、surfaceContainerHighest = card(浮层、卡片、输入框同一面)
///   onSurface / onSurfaceVariant     = textSolid / textMuted
///   outline                          = hairline;scaffold 底色 = bg
ThemeData buildDarkTheme() {
  const c = EmberColors.dark();
  final scheme = ColorScheme.dark(
    primary: c.primary,
    onPrimary: Colors.white,
    secondary: c.primary,
    secondaryContainer: c.raise,
    onSecondaryContainer: c.textSolid,
    error: c.err,
    surface: c.card,
    surfaceContainerHighest: c.card,
    onSurface: c.textSolid,
    onSurfaceVariant: c.textMuted,
    outline: c.hairline,
  );
  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    fontFamily: EmberFonts.ui,
    colorScheme: scheme,
    scaffoldBackgroundColor: c.bg,
    appBarTheme: AppBarTheme(
      backgroundColor: c.bg,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(
        fontSize: 17,
        fontWeight: FontWeight.w600,
        fontFamily: EmberFonts.ui,
        color: c.textSolid,
      ),
      iconTheme: IconThemeData(color: c.textSoft),
    ),
    cardTheme: CardThemeData(
      color: c.card,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: c.hairline),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: c.card,
      contentPadding:
          const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: c.hairline),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: c.hairline),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: c.primary, width: 1.5),
      ),
      hintStyle: TextStyle(
          color: c.textFaint, fontSize: 14, fontFamily: EmberFonts.ui),
    ),
    dividerTheme: DividerThemeData(
      color: c.hairline,
      thickness: 1,
      space: 1,
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: c.raise,
      contentTextStyle:
          TextStyle(color: c.textSolid, fontFamily: EmberFonts.ui),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: c.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: c.card,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),
    tabBarTheme: TabBarThemeData(
      labelColor: c.primary,
      unselectedLabelColor: c.textFaint,
      indicatorColor: c.primary,
      dividerColor: c.hairline,
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: c.card,
      indicatorColor: c.primary.withValues(alpha: 0.18),
      iconTheme: WidgetStateProperty.resolveWith(
        (states) => IconThemeData(
          size: 22,
          color: states.contains(WidgetState.selected)
              ? c.primary
              : c.textMuted,
        ),
      ),
      labelTextStyle: WidgetStateProperty.resolveWith(
        (states) => TextStyle(
          fontSize: EmberType.caption,
          fontFamily: EmberFonts.ui,
          fontWeight: states.contains(WidgetState.selected)
              ? FontWeight.w600
              : FontWeight.w400,
          color: states.contains(WidgetState.selected)
              ? c.primary
              : c.textMuted,
        ),
      ),
    ),
    textTheme: TextTheme(
      bodyMedium: TextStyle(color: c.textSolid, fontSize: 14, height: 1.5),
      bodySmall: TextStyle(color: c.textMuted, fontSize: 12, height: 1.4),
      titleMedium: TextStyle(
          color: c.textSolid, fontSize: 15, fontWeight: FontWeight.w600),
      labelSmall: TextStyle(color: c.textFaint, fontSize: 11),
    ),
  );
}

/// 浅色主题:同一套 Ember 映射(见 [buildDarkTheme] 注释),仅取浅色分支。
ThemeData buildLightTheme() {
  const c = EmberColors.light();
  final scheme = ColorScheme.light(
    primary: c.primary,
    onPrimary: Colors.white,
    secondary: c.primary,
    secondaryContainer: c.raise,
    onSecondaryContainer: c.textSolid,
    error: c.err,
    surface: c.card,
    surfaceContainerHighest: c.card,
    onSurface: c.textSolid,
    onSurfaceVariant: c.textMuted,
    outline: c.hairline,
  );
  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.light,
    fontFamily: EmberFonts.ui,
    colorScheme: scheme,
    scaffoldBackgroundColor: c.bg,
    appBarTheme: AppBarTheme(
      backgroundColor: c.bg,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(
        fontSize: 17,
        fontWeight: FontWeight.w600,
        fontFamily: EmberFonts.ui,
        color: c.textSolid,
      ),
      iconTheme: IconThemeData(color: c.textMuted),
    ),
    cardTheme: CardThemeData(
      color: c.card,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: c.hairline),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: c.card,
      contentPadding:
          const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: c.hairline),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: c.hairline),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: c.primary, width: 1.5),
      ),
      hintStyle: TextStyle(
          color: c.textFaint, fontSize: 14, fontFamily: EmberFonts.ui),
    ),
    dividerTheme: DividerThemeData(
      color: c.hairline,
      thickness: 1,
      space: 1,
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: c.raise,
      contentTextStyle:
          TextStyle(color: c.textSolid, fontFamily: EmberFonts.ui),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: c.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: c.card,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),
    tabBarTheme: TabBarThemeData(
      labelColor: c.primary,
      unselectedLabelColor: c.textFaint,
      indicatorColor: c.primary,
      dividerColor: c.hairline,
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: c.card,
      indicatorColor: c.primary.withValues(alpha: 0.18),
      iconTheme: WidgetStateProperty.resolveWith(
        (states) => IconThemeData(
          size: 22,
          color: states.contains(WidgetState.selected)
              ? c.primary
              : c.textMuted,
        ),
      ),
      labelTextStyle: WidgetStateProperty.resolveWith(
        (states) => TextStyle(
          fontSize: EmberType.caption,
          fontFamily: EmberFonts.ui,
          fontWeight: states.contains(WidgetState.selected)
              ? FontWeight.w600
              : FontWeight.w400,
          color: states.contains(WidgetState.selected)
              ? c.primary
              : c.textMuted,
        ),
      ),
    ),
  );
}

/// Provides the app-wide [ThemeController] down the tree.
class ThemeControllerProvider extends InheritedWidget {
  final ThemeController controller;

  const ThemeControllerProvider({
    super.key,
    required this.controller,
    required super.child,
  });

  static ThemeController? of(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<ThemeControllerProvider>()
      ?.controller;

  @override
  bool updateShouldNotify(ThemeControllerProvider oldWidget) =>
      controller != oldWidget.controller;
}

/// Ember 设计语言色板单一来源(spec §2)。全部界面统一经此类取色。
class EmberColors {
  final bool isDark;
  const EmberColors._(this.isDark);
  const EmberColors.dark() : this._(true);
  const EmberColors.light() : this._(false);

  static EmberColors of(BuildContext context) =>
      Theme.of(context).brightness == Brightness.light
          ? const EmberColors.light()
          : const EmberColors.dark();

  // 暗色(设计基准)
  static const _dBg = Color(0xFF1B1917);
  static const _dCard = Color(0xFF262320);
  static const _dRaise = Color(0xFF35302B);
  static const _dHairline = Color(0xFF3A342E);
  static const _dSolid = Color(0xFFEEE7DC);
  static const _dSoft = Color(0xFFC9BFAF);
  static const _dMuted = Color(0xFF8A8074);
  // AA:on bg(#1B1917) ≥ 4.5:1(实测 4.53)。旧值 #5C554B 仅 2.38。
  static const _dFaint = Color(0xFF868179);

  // 浅色(暖纸白)
  static const _lBg = Color(0xFFF7F3EC);
  static const _lCard = Color(0xFFFFFFFF);
  static const _lRaise = Color(0xFFEFE9DF);
  // AA:主色 onPrimary 白字 ≥ 4.5:1(实测 4.56);旧值 #C25E3A 实测 4.24(原记录 3.55 系笔误)。
  static const _lPrimary = Color(0xFFBA5A37);
  static const _lSolid = Color(0xFF2A241E);
  static const _lSoft = Color(0xFF4A4238);
  static const _lMuted = Color(0xFF786D5E);
  // AA:on bg(#F7F3EC) ≥ 4.5:1(实测 4.54)。旧值 #A69B8C 仅 2.47。
  static const _lFaint = Color(0xFF766E64);

  Color get bg => isDark ? _dBg : _lBg;
  Color get card => isDark ? _dCard : _lCard;
  Color get raise => isDark ? _dRaise : _lRaise;
  Color get hairline => isDark ? _dHairline : const Color(0xFFE2D9CC);
  Color get primary => isDark ? const Color(0xFFD97757) : _lPrimary;
  Color get ok => isDark ? const Color(0xFF7FB069) : const Color(0xFF5A8C46);
  Color get err => isDark ? const Color(0xFFE5484D) : const Color(0xFFC53035);
  Color get warn => isDark ? const Color(0xFFD4A72C) : const Color(0xFFA8851F);
  Color get run => isDark ? const Color(0xFF6A9BD8) : const Color(0xFF4A7BB5);
  Color get textSolid => isDark ? _dSolid : _lSolid;
  Color get textSoft => isDark ? _dSoft : _lSoft;
  Color get textMuted => isDark ? _dMuted : _lMuted;
  Color get textFaint => isDark ? _dFaint : _lFaint;

  // 代码面:markdown 代码块、diff 容器、工具输出共用同一“代码表面”
  // (spec §7.1),与主色无关、仅随明暗切换。
  Color get codeBlockBg =>
      isDark ? Colors.black.withValues(alpha: 0.35) : const Color(0xFFF1F5F9);
  Color get codeInlineBg =>
      isDark ? Colors.white.withValues(alpha: 0.08) : const Color(0x140F172A);
  Color get codeText =>
      isDark ? const Color(0xFF93C5FD) : const Color(0xFF1E3A8A);
}

/// 圆角双轨(spec §4):内容区大圆角、控制区小圆角。
abstract final class EmberRadius {
  static const content = 16.0;   // 气泡/卡片
  static const bubbleTail = 4.0; // 气泡尾角
  static const sheet = 20.0;     // sheet 顶部
  static const control = 10.0;   // 任务卡/设置行组/按钮
  static const avatar = 8.0;     // 缩略图/头像
}

/// 4px 网格间距(spec §4)。
abstract final class EmberSpacing {
  static const page = 16.0;
  static const cardPad = 12.0;
  static const listItemH = 12.0;
  static const listItemV = 8.0;
  static const gapS = 8.0;
  static const gapM = 12.0;
}

/// 六档字阶 + 行高(spec §3)。
abstract final class EmberType {
  static const title = 22.0;
  static const section = 17.0;
  static const emphasis = 15.0;
  static const body = 13.0;
  static const secondary = 12.0;
  static const caption = 11.0;
  static const lineHeight = 1.5;
}

/// 字体族单一来源:UI 正文用 Sarasa UI,等宽/代码用 Sarasa Term。
abstract final class EmberFonts {
  static const ui = 'Sarasa UI SC';
  static const term = 'Sarasa Term SC';
}
