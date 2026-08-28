# Ember 设计基建(Phase 1)实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 建立 Ember 设计语言的代码地基——theme.dart 的完整 token 体系(暖炭色板/文字阶/圆角/间距)与更纱黑体的子集化接入,供后续所有界面重构使用。

**Architecture:** theme.dart 从"零散 ZInk 方法"升级为"Ember token 单一来源":`EmberColors`(暗/浅两套完整色板)、`EmberRadius`(双轨圆角)、`EmberSpacing`(4px 网格)、`EmberType`(六档字阶);ZInk 现有 API 保留为 Ember 之上的兼容层(本阶段不改任何界面代码,零视觉回归风险),字体经 pubspec 声明 + CI 子集化接入。

**Tech Stack:** Flutter/Dart;fonttools(pyftsubset,CI 内 uvx 运行,无项目依赖);Sarasa UI SC / Sarasa Term SC(GitHub 上游 releases 下载,不入库原始字体)。

**Spec:** `docs/superpowers/specs/2026-08-28-ui-redesign-design.md`

## Global Constraints

- 色值逐字取自 spec §2:暗 bg `#1B1917` / card `#262320` / raise `#35302B` / hairline `#3A342E`;主色 `#D97757`;语义 ok `#7FB069` / err `#E5484D` / warn `#D4A72C` / run `#6A9BD8`;文字 `#EEE7DC/#C9BFAF/#8A8074/#5C554B`;浅 bg `#F7F3EC` / card `#FFFFFF` / raise `#EFE9DF` / 主色 `#C25E3A` / 文字 `#2A241E/#4A4238/#786D5E/#A69B8C`。
- 内容区圆角 16(气泡尾角 4、sheet 顶 20),控制区圆角 10,头像/缩略图 8(spec §4)。
- 字阶六档 22/17/15/13/12/11,行高 1.5(spec §3)。
- 本阶段**不修改任何 lib/ui/ 界面文件**(除 theme.dart 自身)——纯增量,现有 200 测试必须保持全绿。
- 字体子集范围:GB2312 全集 + ASCII + 中英标点;原始字体不入库,CI 下载生成。

---

### Task 1: EmberColors token 体系

**Files:**
- Modify: `lib/ui/theme.dart`
- Test: `test/ember_theme_test.dart`(新建)

**Interfaces:**
- Produces: `class EmberColors { const EmberColors.dark(); const EmberColors.light(); bool get isDark; Color bg/card/raise/hairline/primary/ok/err/warn/run/textSolid/textSoft/textMuted/textFaint; }` —— 后续所有界面任务只经此类取色。
- Produces: `EmberColors.of(BuildContext context)` 便捷构造(按 Theme.brightness)。

- [ ] **Step 1: 写失败测试**

```dart
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
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `flutter test test/ember_theme_test.dart`
Expected: FAIL(EmberColors 未定义)

- [ ] **Step 3: 实现 EmberColors(theme.dart 顶层新增,不动现有类)**

```dart
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
```

- [ ] **Step 4: 跑测试确认通过**

Run: `flutter test test/ember_theme_test.dart`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/ui/theme.dart test/ember_theme_test.dart
git commit -m "feat(ui): EmberColors token palette (dark base + warm-paper light)"
```

---

### Task 2: EmberRadius / EmberSpacing / EmberType

**Files:**
- Modify: `lib/ui/theme.dart`
- Test: `test/ember_theme_test.dart`

**Interfaces:**
- Produces: `abstract final class EmberRadius { static const content=16.0; static const bubbleTail=4.0; static const sheet=20.0; static const control=10.0; static const avatar=8.0; }`
- Produces: `abstract final class EmberSpacing { static const page=16.0; static const cardPad=12.0; static const listItemV=8.0; static const listItemH=12.0; static const gapS=8.0; static const gapM=12.0; }`
- Produces: `abstract final class EmberType { static const title=22.0; section=17.0; emphasis=15.0; body=13.0; secondary=12.0; caption=11.0; static const lineHeight=1.5; }`

- [ ] **Step 1: 追加失败测试**

```dart
// test/ember_theme_test.dart 追加
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
```

- [ ] **Step 2: 跑测试确认失败**

Run: `flutter test test/ember_theme_test.dart`
Expected: FAIL(EmberRadius 未定义)

- [ ] **Step 3: 实现 token 类(theme.dart 追加)**

```dart
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
```

- [ ] **Step 4: 跑测试确认通过**

Run: `flutter test test/ember_theme_test.dart`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/ui/theme.dart test/ember_theme_test.dart
git commit -m "feat(ui): EmberRadius/Spacing/Type tokens"
```

---

### Task 3: 字体接入(资产 + 声明 + 子集化脚本)

**Files:**
- Create: `assets/fonts/README.md`(说明字体来源与再生成方式)
- Create: `tool/subset_fonts.py`
- Create: `.github/workflows/rename-check.yml` 不需要——子集化在本地跑一次、产物入库;CI 不重复做(原始 25MB 字体不入库,子集产物约 8MB 入库)
- Modify: `pubspec.yaml`(fonts 声明)

**Interfaces:**
- Produces: 全局 fontFamily `Sarasa UI SC`(Regular/Bold)、`Sarasa Term SC`(Regular,代码场景)——后续任务在主题与代码块直接引用此名。

- [ ] **Step 1: 下载原始字体并子集化(tool/subset_fonts.py)**

```python
#!/usr/bin/env python3
"""下载 Sarasa Ui/Term SC 并子集化为应用内字体。

产物:assets/fonts/ZemoteS-{UI-Regular,UI-Bold,Term-Regular}.ttf
子集范围:GB2312 全集 + ASCII + 中英标点(spec §3 方案 A)。
字体许可:SIL OFL 1.1(更纱黑体),README 需附许可声明。
版本:v1.0.41(2026-08 核实;执行时若过时,更新 FONT_TAG 即可)。
"""
import subprocess, sys, pathlib, shutil

FONT_TAG = "v1.0.41"
FONT_BASE = ("https://github.com/be5invis/Sarasa-Gothic/releases/"
             f"download/{FONT_TAG}")
# 7z 包(Unhinted:子集化反正丢弃 hinting,包更小)
PACKAGES = {
    "SarasaUiSC-TTF-Unhinted-1.0.41.7z": [
        ("sarasa-ui-sc-regular.ttf", "ZemoteS-UI-Regular.ttf"),
        ("sarasa-ui-sc-bold.ttf", "ZemoteS-UI-Bold.ttf"),
    ],
    "SarasaTermSC-TTF-Unhinted-1.0.41.7z": [
        ("sarasa-term-sc-regular.ttf", "ZemoteS-Term-Regular.ttf"),
    ],
}
OUT = pathlib.Path("assets/fonts")
TMP = pathlib.Path("build/_fonts")
OUT.mkdir(parents=True, exist_ok=True)

# GB2312 全集
def gb2312_chars() -> str:
    chars = []
    for hi in range(0xA1, 0xF8):
        for lo in range(0xA1, 0xFF):
            try:
                chars.append(bytes([hi, lo]).decode("gb2312"))
            except UnicodeDecodeError:
                pass
    return "".join(chars)

UNICODE_RANGES = (
    "U+0020-007E,U+00A0-00FF,U+2000-206F,"
    "U+3000-303F,U+FF00-FFEF,U+2460-24FF"
)

def main():
    if shutil.which("7z") is None:
        sys.exit("需要 7z(pacman -S p7zip)")
    textfile = OUT / "subset-chars.txt"
    textfile.write_text(gb2312_chars(), encoding="utf-8")
    for pkg, picks in PACKAGES.items():
        archive = TMP / pkg
        if not archive.exists():
            print(f"downloading {pkg} …")
            archive.parent.mkdir(parents=True, exist_ok=True)
            urllib.request.urlretrieve(f"{FONT_BASE}/{pkg}", archive)
        extract_dir = TMP / pkg.removesuffix(".7z")
        if not extract_dir.exists():
            subprocess.run(["7z", "x", str(archive), f"-o{extract_dir}"],
                           check=True, capture_output=True)
        for src_name, dst_name in picks:
            found = list(extract_dir.rglob(src_name))
            assert found, f"{src_name} 不在包内"
            out = OUT / dst_name
            subprocess.run([
                sys.executable, "-m", "fonttools", "subset", str(found[0]),
                f"--text-file={textfile}",
                f"--unicodes={UNICODE_RANGES}",
                "--layout-features=*", f"--output-file={out}",
            ], check=True)
            print(f"{out} : {out.stat().st_size/1e6:.1f} MB")

if __name__ == "__main__":
    import urllib.request
    main()
```

Run:
```bash
pip install fonttools
python tool/subset_fonts.py
```
Expected: assets/fonts/ 下三个 ttf,合计 ≤ 12MB;超限则收紧到 GB2312 一级字库再跑。

- [ ] **Step 2: pubspec.yaml 声明字体**

```yaml
# pubspec.yaml 的 flutter: 段追加
  fonts:
    - family: Sarasa UI SC
      fonts:
        - asset: assets/fonts/ZemoteS-UI-Regular.ttf
        - asset: assets/fonts/ZemoteS-UI-Bold.ttf
          weight: 700
    - family: Sarasa Term SC
      fonts:
        - asset: assets/fonts/ZemoteS-Term-Regular.ttf
```

- [ ] **Step 3: assets/fonts/README.md(许可与再生成)**

```markdown
# 字体

更纱黑体(Sarasa Gothic SC)子集,来源 https://github.com/be5invis/Sarasa-Gothic,
许可 SIL Open Font License 1.1(全文 https://scripts.sil.org/OFL)。
- ZemoteS-UI-Regular.ttf / -Bold.ttf → family "Sarasa UI SC"(界面)
- ZemoteS-Term-Regular.ttf → family "Sarasa Term SC"(代码/diff/终端)
子集范围:GB2312 + ASCII + 中英标点;未覆盖字符回退系统字体。
再生成:`pip install fonttools && python tool/subset_fonts.py`
```

- [ ] **Step 4: 验证构建与全量测试**

Run: `flutter analyze && flutter test && flutter build web --release`
Expected: analyze 无告警;200+ 测试全绿;web 构建成功(字体资产打包无错)

- [ ] **Step 5: Commit**

```bash
git add assets/fonts tool/subset_fonts.py pubspec.yaml pubspec.lock
git commit -m "feat(ui): Sarasa UI/Term SC subset fonts (GB2312+ASCII, OFL)"
```

---

### Task 4: 主题接线(标题字体族与 ThemeController 默认)

**Files:**
- Modify: `lib/ui/theme.dart`(buildDarkTheme/buildLightTheme 的 fontFamily、`ZemoteMarkdown` 代码块族、`_kv`/diff 的等宽族统一常量)
- Test: `test/ember_theme_test.dart` 追加

**Interfaces:**
- Produces: `abstract final class EmberFonts { static const ui='Sarasa UI SC'; static const term='Sarasa Term SC'; }` —— 全应用唯一字体族引用点(替代散落的 `'monospace'` 字面量,本阶段只替换 theme.dart 与 markdown_view.dart 内部,其余界面文件在各自阶段替换)。

- [ ] **Step 1: 追加失败测试**

```dart
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
```

- [ ] **Step 2: 跑测试确认失败**

Run: `flutter test test/ember_theme_test.dart`
Expected: FAIL(fontFamily 为 null/系统默认)

- [ ] **Step 3: 实现(theme.dart)**

```dart
abstract final class EmberFonts {
  static const ui = 'Sarasa UI SC';
  static const term = 'Sarasa Term SC';
}
```

在 `buildDarkTheme()`/`buildLightTheme()` 的 `TextTheme` 处统一注入(或
`ThemeData(fontFamily: EmberFonts.ui, ...)`),`ZemoteMarkdown` 的 code 样式与
`EmberCodeText` 相关处替换 `'monospace'` → `EmberFonts.term`(本任务只改
theme.dart 与 markdown_view.dart 两处文件内的字面量)。

- [ ] **Step 4: 跑测试确认通过 + 全量回归**

Run: `flutter test test/ember_theme_test.dart && flutter analyze && flutter test`
Expected: PASS;全量测试全绿

- [ ] **Step 5: Commit**

```bash
git add lib/ui/theme.dart lib/ui/markdown_view.dart test/ember_theme_test.dart
git commit -m "feat(ui): wire Sarasa families into app theme + code styles"
```

---

## 后续阶段(另行出 plan,不在本文档)

- Phase 2:导航重组(三 Tab 壳/启动路径/设备切换器)+ 对话页重构(消息流/抽屉/洞察 sheet)
- Phase 3:自动化页 + 设置页(含设备管理新家)
- Phase 4:二级页 + 全量浅色校验 + 清理 ZInk 兼容层
