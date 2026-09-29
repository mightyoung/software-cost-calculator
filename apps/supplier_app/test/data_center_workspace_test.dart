import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supplier_app/app/app_state.dart';
import 'package:supplier_app/app/theme.dart';
import 'package:supplier_app/features/data_center/data_center_page.dart';
import 'package:supplier_core/supplier_core.dart';

void main() {
  for (final width in [1440.0, 390.0]) {
    testWidgets('quality units, filtering and searchable tools at $width', (
      tester,
    ) async {
      final dir = Directory.systemTemp.createTempSync('center_actions');
      final store = Store.open('${dir.path}/test.db', device: 'test');
      final state = AppState.test(store, dir);
      for (var i = 0; i < 2; i++) {
        store.save('supplier', {
          for (final f in Supplier.fields) f: null,
          'name': '测试供应商',
          'aliases': <String>[],
          'categories': <String>[],
        });
      }
      final counts = store.recordCounts();
      addTearDown(() {
        store.close();
        dir.deleteSync(recursive: true);
      });
      tester.view.physicalSize = Size(width, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final previousDark = Tokens.dark;
      Tokens.dark = width < 600;
      addTearDown(() => Tokens.dark = previousDark);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: TextScaler.linear(width < 600 ? 1.4 : 1),
              disableAnimations: true,
            ),
            child: child!,
          ),
          home: Scaffold(body: DataCenterPage(state: state)),
        ),
      );
      await tester.tap(find.text('数据质量'));
      await tester.pumpAndSettle();
      expect(find.text('1 组'), findsOneWidget);
      expect(find.text('待确认的修改冲突'), findsNothing);
      await tester.tap(find.text('全部 ${store.dataQuality().length}'));
      await tester.pumpAndSettle();
      // Findings are grouped by area; data consistency comes last.
      expect(find.text('项目与技术要求'), findsOneWidget);
      await tester.dragUntilVisible(
        find.text('0 项冲突'),
        find.byType(ListView).first,
        const Offset(0, -300),
      );
      expect(find.text('0 项冲突'), findsOneWidget);
      await tester.dragUntilVisible(
        find.text('待处理 2'),
        find.byType(ListView).first,
        const Offset(0, 300),
      );
      await tester.tap(find.text('待处理 2'));
      await tester.pumpAndSettle();
      if (width >= 600) {
        await tester.tap(find.text('打开完整列表').first);
        await tester.pumpAndSettle();
        expect(find.text('完整列表 · 请按问题提示检查'), findsOneWidget);
        Navigator.of(tester.element(find.text('完整列表 · 请按问题提示检查'))).pop();
        await tester.pumpAndSettle();
      }
      await tester.tap(find.text('AI 接入'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const ValueKey('ai-tool-search')));
      await tester.enterText(
        find.byKey(const ValueKey('ai-tool-search')),
        'nonexistent-tool',
      );
      await tester.pumpAndSettle();
      expect(find.text('没有匹配的只读工具'), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('ai-tool-search')),
        'describe',
      );
      await tester.pumpAndSettle();
      expect(
        find.byWidgetPredicate(
          (widget) => widget is Text && widget.data == 'describe',
        ),
        findsOneWidget,
      );
      expect(find.text('没有匹配的只读工具'), findsNothing);
      await tester.scrollUntilVisible(
        find.text('AI 需要遵守的规则'),
        200,
        scrollable: find
            .descendant(
              of: find.byType(ListView).last,
              matching: find.byType(Scrollable),
            )
            .first,
      );
      final rulesTile = find.ancestor(
        of: find.text('AI 需要遵守的规则'),
        matching: find.byType(ExpansionTile),
      );
      final arrow = find.descendant(
        of: rulesTile,
        matching: find.byType(AnimatedRotation),
      );
      expect(tester.widget<AnimatedRotation>(arrow).turns, 0);
      expect(tester.widget<AnimatedRotation>(arrow).duration, Duration.zero);
      await tester.tap(find.text('AI 需要遵守的规则'));
      await tester.pumpAndSettle();
      expect(tester.widget<AnimatedRotation>(arrow).turns, .25);
      expect(store.recordCounts(), counts);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
  testWidgets('quality and AI views preserve source checks and tools', (
    tester,
  ) async {
    final dir = Directory.systemTemp.createTempSync('center_workspace');
    final store = Store.open('${dir.path}/test.db', device: 'test');
    final state = AppState.test(store, dir);
    addTearDown(() {
      store.close();
      dir.deleteSync(recursive: true);
    });
    tester.view.physicalSize = const Size(1440, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: Scaffold(body: DataCenterPage(state: state)),
      ),
    );
    await tester.tap(find.text('数据质量'));
    await tester.pumpAndSettle();
    expect(find.text('没有发现需要处理的问题。'), findsOneWidget);
    expect(store.dataQuality().every((check) => check.count == 0), isTrue);
    await tester.tap(find.text('AI 接入'));
    await tester.pumpAndSettle();
    expect(find.text('复制数据说明'), findsOneWidget);
    expect(find.text('describe'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
