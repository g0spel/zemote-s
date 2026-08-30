import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import 'package:zflow/ui/chat_page.dart';
import 'package:zflow/ui/theme.dart';

void main() {
  Widget host({required String text, required bool streaming}) {
    return MaterialApp(
      theme: buildDarkTheme(),
      home: streamingMarkdownForTest(
        key: const ValueKey('streaming-markdown'),
        text: text,
        streaming: streaming,
      ),
    );
  }

  String renderedData(WidgetTester tester) =>
      tester.widget<MarkdownBody>(find.byType(MarkdownBody)).data;

  testWidgets('streaming updates are coalesced and use the latest text',
      (tester) async {
    await tester.pumpWidget(host(text: 'a', streaming: true));
    expect(renderedData(tester), 'a');

    await tester.pumpWidget(host(text: 'ab', streaming: true));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpWidget(host(text: 'abc', streaming: true));
    await tester.pump(const Duration(milliseconds: 149));
    expect(renderedData(tester), 'a');

    await tester.pump(const Duration(milliseconds: 1));
    expect(renderedData(tester), 'abc');
  });

  testWidgets('terminal text commits immediately before throttle deadline',
      (tester) async {
    await tester.pumpWidget(host(text: 'partial', streaming: true));
    await tester.pumpWidget(host(text: 'partial answer', streaming: true));
    await tester.pump(const Duration(milliseconds: 100));
    expect(renderedData(tester), 'partial');

    await tester.pumpWidget(host(text: 'final answer', streaming: false));
    expect(renderedData(tester), 'final answer');
  });

  testWidgets('disposing a streaming bubble cancels its timer', (tester) async {
    await tester.pumpWidget(host(text: 'a', streaming: true));
    await tester.pumpWidget(host(text: 'ab', streaming: true));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 300));
  });
}
