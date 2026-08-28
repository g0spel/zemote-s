import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Design tokens + theme controller (dark / light / system, persisted).
class ThemeController extends ChangeNotifier {
  static const _prefsKey = 'zemote_theme_mode';

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

class ZColors {
  static const primary = Color(0xFF3B82F6);
  static const primaryDim = Color(0xFF2563EB);
  static const darkBg = Color(0xFF0B1220);
  static const darkSurface = Color(0xFF111A2E);
  static const darkCard = Color(0xFF16203A);
  static const darkBorder = Color(0x1FFFFFFF);
  static const success = Color(0xFF22C55E);
  static const warning = Color(0xFFF59E0B);
  static const danger = Color(0xFFEF4444);
  static const running = Color(0xFF38BDF8);

  static const lightBg = Color(0xFFF6F8FC);
  static const lightSurface = Color(0xFFFFFFFF);
  static const lightCard = Color(0xFFFFFFFF);
  static const lightBorder = Color(0x14000000);
}

/// Theme-aware ink colors. Replaces hardcoded `Colors.white*` (dark-theme
/// ink) which become illegible on the light surfaces. The dark theme keeps
/// the existing white ramp; the light theme maps it onto a slate ramp so
/// text/icons stay readable on white backgrounds.
class ZInk {
  static bool _isLight(BuildContext context) =>
      Theme.of(context).brightness == Brightness.light;

  static const _slate = Color(0xFF0F172A);
  static const _slate700 = Color(0xFF334155);
  static const _slate600 = Color(0xFF475569);
  static const _slate500 = Color(0xFF64748B);
  static const _slate400 = Color(0xFF94A3B8);
  static const _slate300 = Color(0xFFCBD5E1);

  /// Primary text/ink (dark: `Colors.white`, light: slate-900).
  static Color solid(BuildContext context) =>
      _isLight(context) ? _slate : Colors.white;

  /// Secondary ink (dark: `Colors.white70`, light: slate-700).
  static Color soft(BuildContext context) =>
      _isLight(context) ? _slate700 : Colors.white70;

  /// Muted ink (dark: `Colors.white54`, light: slate-600).
  static Color muted(BuildContext context) =>
      _isLight(context) ? _slate600 : Colors.white54;

  /// Faint ink (dark: `Colors.white38`, light: slate-500).
  static Color faint(BuildContext context) =>
      _isLight(context) ? _slate500 : Colors.white38;

  /// Ghost ink (dark: `Colors.white24`, light: slate-400).
  static Color ghost(BuildContext context) =>
      _isLight(context) ? _slate400 : Colors.white24;

  /// Hairline ink (dark: `Colors.white12`, light: slate-300).
  static Color hairline(BuildContext context) =>
      _isLight(context) ? _slate300 : Colors.white12;

  /// Subtle tile fill (dark: white@4%, light: black@4%).
  static Color tile(BuildContext context) =>
      _isLight(context)
          ? const Color(0x0A0F172A)
          : Colors.white.withValues(alpha: 0.04);

  /// Tile hairline border (dark: white@6%, light: black@6%).
  static Color tileBorder(BuildContext context) =>
      _isLight(context)
          ? const Color(0x0F0F172A)
          : Colors.white.withValues(alpha: 0.06);

  /// Code block background (light: slate-100 so code stays readable).
  static Color codeBlockBg(BuildContext context) =>
      _isLight(context)
          ? const Color(0xFFF1F5F9)
          : Colors.black.withValues(alpha: 0.35);

  /// Inline code background.
  static Color codeInlineBg(BuildContext context) =>
      _isLight(context)
          ? const Color(0x140F172A)
          : Colors.white.withValues(alpha: 0.08);

  /// Code text (light: dark blue for contrast on the light block).
  static Color codeText(BuildContext context) =>
      _isLight(context)
          ? const Color(0xFF1E3A8A)
          : const Color(0xFF93C5FD);

  /// Diff container background (follows the code block, so diffs and code
  /// read as the same "code surface" in both themes).
  static Color diffBg(BuildContext context) => codeBlockBg(context);

  /// Diff header strip (a step above [diffBg]).
  static Color diffHeaderBg(BuildContext context) =>
      _isLight(context)
          ? const Color(0xFFE2E8F0)
          : Colors.white.withValues(alpha: 0.06);

  /// Diff line fills — tinted enough to read as +/- bands in BOTH themes
  /// (the old constant greens/reds were tuned for dark only).
  static Color diffAddedBg(BuildContext context) => _isLight(context)
      ? const Color(0x16B7EB8F)
      : const Color(0xFF22C55E).withValues(alpha: 0.12);
  static Color diffRemovedBg(BuildContext context) => _isLight(context)
      ? const Color(0x16FCA5A5)
      : const Color(0xFFEF4444).withValues(alpha: 0.12);

  /// Diff line text — saturated base colors on light (pastels wash out
  /// on white), the readable pastels on dark.
  static Color diffAddedText(BuildContext context) =>
      _isLight(context) ? const Color(0xFF15803D) : const Color(0xFF86EFAC);
  static Color diffRemovedText(BuildContext context) =>
      _isLight(context) ? const Color(0xFFB91C1C) : const Color(0xFFFCA5A5);
}

ThemeData buildDarkTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: ZColors.primary,
    brightness: Brightness.dark,
  ).copyWith(
    primary: ZColors.primary,
    surface: ZColors.darkSurface,
    surfaceContainerHighest: ZColors.darkCard,
    outline: ZColors.darkBorder,
  );
  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    fontFamily: EmberFonts.ui,
    colorScheme: scheme,
    scaffoldBackgroundColor: ZColors.darkBg,
    appBarTheme: const AppBarTheme(
      backgroundColor: ZColors.darkBg,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(
        fontSize: 17,
        fontWeight: FontWeight.w600,
        color: Colors.white,
      ),
      iconTheme: IconThemeData(color: Colors.white70),
    ),
    cardTheme: CardThemeData(
      color: ZColors.darkCard,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: const BorderSide(color: ZColors.darkBorder),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: ZColors.darkSurface,
      contentPadding:
          const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: ZColors.darkBorder),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: ZColors.darkBorder),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: ZColors.primary, width: 1.5),
      ),
      hintStyle: const TextStyle(color: Colors.white30, fontSize: 14),
    ),
    dividerTheme: const DividerThemeData(
      color: ZColors.darkBorder,
      thickness: 1,
      space: 1,
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: ZColors.darkCard,
      contentTextStyle: const TextStyle(color: Colors.white),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: ZColors.darkSurface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: ZColors.darkSurface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),
    tabBarTheme: const TabBarThemeData(
      labelColor: ZColors.primary,
      unselectedLabelColor: Colors.white38,
      indicatorColor: ZColors.primary,
      dividerColor: ZColors.darkBorder,
    ),
    textTheme: const TextTheme(
      bodyMedium: TextStyle(color: Colors.white, fontSize: 14, height: 1.5),
      bodySmall: TextStyle(color: Colors.white54, fontSize: 12, height: 1.4),
      titleMedium: TextStyle(
          color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600),
      labelSmall: TextStyle(color: Colors.white38, fontSize: 11),
    ),
  );
}

ThemeData buildLightTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: ZColors.primary,
    brightness: Brightness.light,
  ).copyWith(
    primary: ZColors.primaryDim,
    surface: ZColors.lightSurface,
    outline: ZColors.lightBorder,
  );
  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.light,
    fontFamily: EmberFonts.ui,
    colorScheme: scheme,
    scaffoldBackgroundColor: ZColors.lightBg,
    appBarTheme: const AppBarTheme(
      backgroundColor: ZColors.lightBg,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(
        fontSize: 17,
        fontWeight: FontWeight.w600,
        color: Color(0xFF0F172A),
      ),
      iconTheme: IconThemeData(color: Color(0xFF475569)),
    ),
    cardTheme: CardThemeData(
      color: ZColors.lightCard,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: const BorderSide(color: ZColors.lightBorder),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: ZColors.lightSurface,
      contentPadding:
          const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: ZColors.lightBorder),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: ZColors.lightBorder),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: ZColors.primary, width: 1.5),
      ),
      hintStyle: const TextStyle(color: Colors.black26, fontSize: 14),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: ZColors.lightSurface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: ZColors.lightSurface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),
    tabBarTheme: const TabBarThemeData(
      labelColor: ZColors.primaryDim,
      unselectedLabelColor: Colors.black38,
      indicatorColor: ZColors.primaryDim,
      dividerColor: ZColors.lightBorder,
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

/// Status color mapping shared by task/chat UIs. The unknown-status fallback
/// is theme-aware so it stays visible on light surfaces too.
Color statusColor(String status, BuildContext context) {
  switch (status) {
    case 'running':
    case 'prewarming':
      return ZColors.running;
    case 'error':
    case 'failed':
      return ZColors.danger;
    case 'completed':
    case 'completedSuccess':
      return ZColors.success;
    case 'completedInterrupted':
    case 'cancelled':
      return ZColors.warning;
    default:
      return ZInk.faint(context);
  }
}

/// Human relative time, e.g. `刚刚` / `5分钟前` / `昨天` / `3天前`.
String relativeTime(int? millis) {
  if (millis == null || millis <= 0) return '';
  final time = DateTime.fromMillisecondsSinceEpoch(millis);
  final diff = DateTime.now().difference(time);
  if (diff.inMinutes < 1) return '刚刚';
  if (diff.inMinutes < 60) return '${diff.inMinutes}分钟前';
  if (diff.inHours < 24) return '${diff.inHours}小时前';
  if (diff.inDays == 1) return '昨天';
  if (diff.inDays < 30) return '${diff.inDays}天前';
  return '${time.year}-${time.month.toString().padLeft(2, '0')}-'
      '${time.day.toString().padLeft(2, '0')}';
}

/// Ember 设计语言色板单一来源(spec §2)。后续界面统一经此类取色;
/// ZInk 保留为兼容层,逐步迁移后移除。
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
  static const _dFaint = Color(0xFF5C554B);

  // 浅色(暖纸白)
  static const _lBg = Color(0xFFF7F3EC);
  static const _lCard = Color(0xFFFFFFFF);
  static const _lRaise = Color(0xFFEFE9DF);
  static const _lPrimary = Color(0xFFC25E3A);
  static const _lSolid = Color(0xFF2A241E);
  static const _lSoft = Color(0xFF4A4238);
  static const _lMuted = Color(0xFF786D5E);
  static const _lFaint = Color(0xFFA69B8C);

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
