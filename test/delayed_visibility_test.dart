import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zflow/ui/delayed_banner.dart';

void main() {
  testWidgets('DelayedVisibility stays hidden before the delay elapses',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: DelayedVisibility(
        visible: true,
        delay: const Duration(seconds: 5),
        builder: (_) => const Text('BANNER'),
      ),
    ));
    expect(find.text('BANNER'), findsNothing);

    await tester.pump(const Duration(seconds: 4));
    expect(find.text('BANNER'), findsNothing);

    await tester.pump(const Duration(seconds: 2));
    expect(find.text('BANNER'), findsOneWidget);
  });

  testWidgets('a condition that clears within the delay never shows',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: DelayedVisibility(
        visible: true,
        delay: const Duration(seconds: 5),
        builder: (_) => const Text('BANNER'),
      ),
    ));
    await tester.pump(const Duration(seconds: 3));
    // Condition heals before the delay elapses.
    await tester.pumpWidget(MaterialApp(
      home: DelayedVisibility(
        visible: false,
        delay: const Duration(seconds: 5),
        builder: (_) => const Text('BANNER'),
      ),
    ));
    await tester.pump(const Duration(seconds: 30));
    expect(find.text('BANNER'), findsNothing);
  });

  testWidgets('re-arming after a shown condition works',
      (tester) async {
    late StateSetter setOuter;
    var visible = true;
    await tester.pumpWidget(MaterialApp(
      home: StatefulBuilder(
        builder: (context, setState) {
          setOuter = setState;
          return DelayedVisibility(
            visible: visible,
            delay: const Duration(seconds: 5),
            builder: (_) => const Text('BANNER'),
          );
        },
      ),
    ));
    await tester.pump(const Duration(seconds: 6));
    expect(find.text('BANNER'), findsOneWidget);

    setOuter(() => visible = false);
    await tester.pump();
    expect(find.text('BANNER'), findsNothing);

    setOuter(() => visible = true);
    await tester.pump();
    await tester.pump(const Duration(seconds: 4));
    expect(find.text('BANNER'), findsNothing);
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('BANNER'), findsOneWidget);
  });
}
