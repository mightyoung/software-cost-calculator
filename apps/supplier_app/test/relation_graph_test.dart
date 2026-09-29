import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supplier_core/supplier_core.dart';
import 'package:supplier_app/features/data_center/relation_graph.dart';

void main() {
  Future<void> mount(
    WidgetTester tester, {
    double width = 1200,
    Brightness brightness = Brightness.light,
    bool quiet = false,
    ValueChanged<String>? onSelect,
  }) async {
    tester.view.physicalSize = Size(width, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(brightness: brightness),
        home: MediaQuery(
          data: MediaQueryData(disableAnimations: quiet),
          child: Scaffold(
            body: RelationGraph(
              counts: const {},
              selected: 'quotation',
              onSelect: onSelect ?? (_) {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'search matches Chinese and English and has a recoverable empty state',
    (tester) async {
      String? selected;
      await mount(tester, onSelect: (value) => selected = value);
      await tester.enterText(find.byType(TextField), 'no-such-type');
      await tester.pumpAndSettle();
      expect(find.textContaining('没有匹配对象'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'supplier');
      await tester.pumpAndSettle();
      await tester.tap(find.text('供应商 · supplier'));
      await tester.pumpAndSettle();
      expect(selected, 'supplier');
      await tester.enterText(find.byType(TextField), '报价');
      await tester.pumpAndSettle();
      expect(find.text('报价 · quotation'), findsOneWidget);
    },
  );

  testWidgets(
    'all mode retains every field, parallel references, and merge self links',
    (tester) async {
      await mount(tester);
      for (final l in links.where(
        (l) => l.from == 'quotation' || l.to == 'quotation',
      )) {
        expect(find.byKey(ValueKey('link-${l.name}')), findsOneWidget);
      }
      expect(
        find.byKey(const ValueKey('link-supplier.merged_into')),
        findsNothing,
      );
      await tester.tap(find.text('全部关系'));
      await tester.pumpAndSettle();
      for (final l in links) {
        expect(find.byKey(ValueKey('link-${l.name}')), findsOneWidget);
      }
      final merge = find.byKey(const ValueKey('link-supplier.merged_into'));
      await tester.ensureVisible(merge);
      await tester.tap(merge);
      await tester.pumpAndSettle();
      expect(tester.widget<ChoiceChip>(merge).selected, isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'zoom, fit and focus change viewport and reduced motion is immediate',
    (tester) async {
      await mount(tester, quiet: true);
      final controller = tester
          .widget<InteractiveViewer>(find.byType(InteractiveViewer))
          .transformationController!;
      final initial = controller.value.clone();
      await tester.tap(find.byTooltip('放大'));
      await tester.pump();
      expect(
        controller.value.getMaxScaleOnAxis(),
        greaterThan(initial.getMaxScaleOnAxis()),
      );
      await tester.tap(find.byTooltip('适应画布'));
      await tester.pump();
      expect(
        controller.value.getMaxScaleOnAxis(),
        lessThanOrEqualTo(initial.getMaxScaleOnAxis()),
      );
      await tester.tap(find.byTooltip('聚焦选中对象'));
      await tester.pump();
      expect(controller.value.getMaxScaleOnAxis(), greaterThanOrEqualTo(.85));
      final focused = controller.value.clone();
      await tester.pump(const Duration(milliseconds: 130));
      expect(controller.value, focused);
      await tester.tap(find.text('减少动效'));
      await tester.pump();
      expect(
        tester
            .widget<FilterChip>(find.widgetWithText(FilterChip, '减少动效'))
            .selected,
        isTrue,
      );
    },
  );

  testWidgets(
    'theme changes invalidate edge painter colours without changing selection',
    (tester) async {
      await mount(tester);
      final painterFinder = find.byWidgetPredicate(
        (w) => w is CustomPaint && w.painter.runtimeType.toString() == '_Links',
      );
      final before = tester.widget<CustomPaint>(painterFinder).painter!;
      await mount(tester, brightness: Brightness.dark);
      final after = tester.widget<CustomPaint>(painterFinder).painter!;
      expect(after.shouldRepaint(before), isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('narrow canvas preserves fixed non-overlapping node geometry', (
    tester,
  ) async {
    await mount(tester, width: 620);
    final viewer = tester.widget<InteractiveViewer>(
      find.byType(InteractiveViewer),
    );
    expect(viewer.constrained, isFalse);
    for (final a in ontology.values) {
      final ra = tester.getRect(find.byKey(ValueKey('node-${a.name}')));
      for (final b in ontology.values.where((b) => a.name != b.name)) {
        expect(
          ra.overlaps(tester.getRect(find.byKey(ValueKey('node-${b.name}')))),
          isFalse,
        );
      }
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('keyboard can focus and activate nodes', (tester) async {
    String? selected;
    await mount(tester, onSelect: (value) => selected = value, quiet: true);
    for (var i = 0; i < 16; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      final context = FocusManager.instance.primaryFocus?.context;
      if (context != null &&
          context.findAncestorWidgetOfExactType<InkWell>()?.key ==
              const ValueKey('node-supplier')) {
        break;
      }
    }
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(selected, 'supplier');
    final r = tester.getRect(find.byKey(const ValueKey('node-supplier')));
    final viewport = tester.getRect(find.byType(InteractiveViewer));
    expect(viewport.contains(r.center), isTrue);
  });
  testWidgets(
    'all schema types retain counts and selection only calls callback',
    (tester) async {
      tester.view.resetPhysicalSize();
      tester.view.physicalSize = const Size(1500, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final counts = {for (final t in ontology.values) t.name: 17};
      String? picked;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: RelationGraph(
              counts: counts,
              selected: 'quotation',
              onSelect: (value) => picked = value,
            ),
          ),
        ),
      );
      for (final t in ontology.values) {
        expect(find.text(t.label), findsWidgets);
      }
      expect(find.text('17 条'), findsNWidgets(11));
      await tester.tap(find.text('供应商').first);
      expect(picked, 'supplier');
      expect(counts.values, everyElement(17));
    },
  );
}
