import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;

import 'theme.dart';
import 'ui_settings.dart';

/// Markdown renderer matching the official client look:
/// selectable body text + code blocks with language tag and copy button.
class ZflowMarkdown extends StatelessWidget {
  final String data;
  final bool selectable;
  final double fontSize;

  const ZflowMarkdown(
    this.data, {
    super.key,
    this.selectable = true,
    this.fontSize = 14,
  });

  @override
  Widget build(BuildContext context) {
    final codeFont =
        UiSettingsProvider.of(context)?.codeFontSize ?? fontSize - 1.5;
    final styleSheet =
        _StyleSheetCache.of(EmberColors.of(context), fontSize, codeFont);

    final body = MarkdownBody(
      data: data,
      selectable: selectable,
      styleSheet: styleSheet,
      builders: {
        'code': _CodeBlockBuilder(codeFontSize: codeFont),
      },
      softLineBreak: true,
    );
    return body;
  }
}

/// styleSheet 实例复用缓存。包内守卫(MarkdownWidget.didUpdateWidget):
/// data 与 styleSheet 都未变时跳过重解析——此前每次 build 都 new 一个
/// styleSheet,守卫恒失效,流式期间(100ms 一次全列表重建)所有未变的
/// markdown 行都会整篇重解析。EmberColors.of 返回 const 实例,键稳定;
/// 上限 16(字号 × 主题组合有限),超限整体清空即可。
class _StyleSheetCache {
  static final _cache = <Object, MarkdownStyleSheet>{};
  static const _max = 16;

  static MarkdownStyleSheet of(
      EmberColors c, double fontSize, double codeFont) {
    if (_cache.length >= _max) _cache.clear();
    final key = Object.hash(c, fontSize, codeFont);
    return _cache.putIfAbsent(key, () => _build(c, fontSize, codeFont));
  }

  static MarkdownStyleSheet _build(
      EmberColors colors, double fontSize, double codeFont) {
    return MarkdownStyleSheet(
      p: TextStyle(
          fontSize: fontSize,
          height: 1.6,
          color: colors.textSolid),
      h1: const TextStyle(
          fontSize: 20, fontWeight: FontWeight.w700, height: 1.6),
      h2: const TextStyle(
          fontSize: 18, fontWeight: FontWeight.w700, height: 1.6),
      h3: const TextStyle(
          fontSize: 16, fontWeight: FontWeight.w600, height: 1.6),
      h4: const TextStyle(
          fontSize: 15, fontWeight: FontWeight.w600, height: 1.6),
      code: TextStyle(
        fontFamily: EmberFonts.term,
        fontSize: codeFont,
        backgroundColor: colors.codeInlineBg,
        color: colors.codeText,
      ),
      codeblockDecoration: const BoxDecoration(),
      blockquote: TextStyle(
          fontSize: fontSize, color: colors.textSoft, height: 1.6),
      blockquoteDecoration: BoxDecoration(
        border: Border(
          left: BorderSide(
              color: colors.primary.withValues(alpha: 0.5),
              width: 3),
        ),
      ),
      blockquotePadding: const EdgeInsets.only(left: 12),
      listBullet: TextStyle(fontSize: fontSize, height: 1.6),
      tableBody: TextStyle(fontSize: fontSize - 1),
      tableHead: TextStyle(
          fontSize: fontSize - 1, fontWeight: FontWeight.w600),
      tableBorder: TableBorder.all(
          color: colors.hairline, width: 1),
      tableCellsPadding: const EdgeInsets.symmetric(
          horizontal: 8, vertical: 4),
      horizontalRuleDecoration: BoxDecoration(
        border: Border(
            top: BorderSide(color: colors.hairline)),
      ),
      a: TextStyle(
          color: colors.primary,
          decoration: TextDecoration.underline),
    );
  }
}

class _CodeBlockBuilder extends MarkdownElementBuilder {
  final double codeFontSize;

  _CodeBlockBuilder({required this.codeFontSize});

  @override
  Widget? visitElementAfter(md.Element element, TextStyle? preferredStyle) {
    // Language is encoded in the class attribute: `language-dart`.
    var language = '';
    final classAttr = element.attributes['class'];
    if (classAttr != null) {
      final match = RegExp(r'language-(\S+)').firstMatch(classAttr);
      if (match != null) language = match.group(1) ?? '';
    }
    final code = element.textContent;
    if (!code.contains('\n') && language.isEmpty) {
      // inline code: default styling
      return null;
    }
    return _CodeBlock(code: code, language: language, fontSize: codeFontSize);
  }
}

class _CodeBlock extends StatelessWidget {
  final String code;
  final String language;
  final double fontSize;

  const _CodeBlock({
    required this.code,
    required this.language,
    required this.fontSize,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(
        color: EmberColors.of(context).codeBlockBg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: EmberColors.of(context).hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: EmberColors.of(context).raise,
              borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(10)),
            ),
            child: Row(
              children: [
                Text(
                  language.isEmpty ? 'code' : language,
                  style: TextStyle(
                      fontSize: 10.5,
                      color: EmberColors.of(context).textFaint,
                      fontFamily: EmberFonts.term),
                ),
                const Spacer(),
                InkWell(
                  onTap: () {
                    Clipboard.setData(ClipboardData(text: code));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('已复制'),
                        duration: Duration(seconds: 1),
                      ),
                    );
                  },
                  child: Padding(
                    padding: const EdgeInsets.all(2),
                    child: Icon(Icons.copy_outlined,
                        size: 13, color: EmberColors.of(context).textFaint),
                  ),
                ),
              ],
            ),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.all(10),
            child: SelectableText(
              code.endsWith('\n')
                  ? code.substring(0, code.length - 1)
                  : code,
              style: TextStyle(
                fontFamily: EmberFonts.term,
                fontSize: fontSize - 1.5,
                height: 1.5,
                color: EmberColors.of(context).codeText,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
