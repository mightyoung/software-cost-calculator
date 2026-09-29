import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supplier_app/app/motion.dart';

void main() {
  testWidgets('page changes interrupt and only current page remains mounted', (
    tester,
  ) async {
    var builds = 0;
    Widget page(int id, {bool reduced = false}) => MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: reduced),
        child: PageArrival(
          identity: id,
          child: Builder(
            builder: (_) {
              builds++;
              return Text('page $id');
            },
          ),
        ),
      ),
    );
    await tester.pumpWidget(page(1));
    await tester.pumpWidget(page(2));
    final atStart = builds;
    await tester.pump(const Duration(milliseconds: 60));
    expect(
      builds,
      atStart,
      reason: 'Animation ticks must not rebuild business pages',
    );
    expect(find.text('page 1'), findsNothing);
    await tester.pumpWidget(page(3));
    expect(find.text('page 2'), findsNothing);
    await tester.pumpAndSettle();
    expect(find.text('page 3'), findsOneWidget);
    expect(tester.binding.transientCallbackCount, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('reduce motion immediately ends an active page transition', (
    tester,
  ) async {
    Widget page(int id, bool reduced) => MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: reduced),
        child: PageArrival(identity: id, child: Text('$id')),
      ),
    );
    await tester.pumpWidget(page(1, false));
    await tester.pumpWidget(page(2, false));
    await tester.pump(const Duration(milliseconds: 20));
    await tester.pumpWidget(page(2, true));
    await tester.pump();
    expect(tester.binding.transientCallbackCount, 0);
    final transform = tester.widget<Transform>(
      find
          .descendant(
            of: find.byType(PageArrival),
            matching: find.byType(Transform),
          )
          .first,
    );
    expect(transform.transform.getTranslation().y, 0);
  });

  testWidgets('quiet long tasks have status without infinite animation', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(disableAnimations: true),
          child: Column(
            children: [TaskProgress(), TaskProgress(compact: true)],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('正在处理…'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets('dialog retains non-dismissible contract and result', (
    tester,
  ) async {
    String? result;
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                result = await showAppDialog<String>(
                  context: context,
                  barrierDismissible: false,
                  builder: (context) => AlertDialog(
                    content: TextButton(
                      onPressed: () => Navigator.pop(context, 'saved'),
                      child: const Text('确认'),
                    ),
                  ),
                );
              },
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    expect(find.text('确认'), findsOneWidget);
    await tester.tap(find.text('确认'));
    await tester.pumpAndSettle();
    expect(result, 'saved');
  });
}
