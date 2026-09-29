import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supplier_app/app/app_state.dart';
import 'package:supplier_app/app/theme.dart';
import 'package:supplier_app/features/ai/material_review.dart';
import 'package:supplier_core/supplier_core.dart';

void main() {
  testWidgets('review destination reflects target project and budget choice', (
    tester,
  ) async {
    final dir = Directory.systemTemp.createTempSync('review_destination');
    addTearDown(() => dir.deleteSync(recursive: true));
    final store = Store.open('${dir.path}/test.db', device: '测试机');
    addTearDown(store.close);
    final state = AppState.test(store, dir);
    state.saveSetting('inquirer', '张工');
    final projects = [
      for (final entry in [('P-001', '一号泵房'), ('P-002', '二号控制室')])
        store.save('project', {
          for (final field in Project.fields) field: null,
          'code': entry.$1,
          'name': entry.$2,
          'status': 'active',
          'currency': 'CNY',
          'tax_mode': 'included',
          'markup_rate': '0',
        }),
    ];
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: Scaffold(
          body: MaterialReview(
            state: state,
            projectId: projects.last,
            plans: [
              store.planOffer(
                cleanOffer({
                  'name': '控制柜',
                  'supplier': '设备供应商',
                  'unit': '台',
                  'price': '3200',
                }),
              ),
            ],
            onBack: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final destination = find.byKey(const ValueKey('review-destination'));
    expect(find.text('项目：二号控制室\n同时加入预算').hitTestable(), findsOneWidget);
    expect(find.widgetWithText(TextField, '询价人'), findsNothing);
    await tester.tap(destination);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(find.widgetWithText(TextField, '询价人'))
          .controller!
          .text,
      '张工',
    );
    expect(
      tester
          .widget<DropdownButtonFormField<String>>(
            find.widgetWithText(DropdownButtonFormField<String>, '报价所属项目'),
          )
          .initialValue,
      projects.last,
    );
    final budgetRow = find
        .ancestor(of: find.text('同时加入项目成本预算'), matching: find.byType(Row))
        .first;
    await tester.tap(
      find.descendant(of: budgetRow, matching: find.byType(Checkbox)),
    );
    await tester.pumpAndSettle();
    expect(find.text('项目：二号控制室\n仅登记报价').hitTestable(), findsOneWidget);
    expect(store.listQuotations(), isEmpty);
    expect(store.searchByName('supplier', ''), isEmpty);
    expect(store.searchByName('product', ''), isEmpty);
    expect(store.budget(projects.first).lines, isEmpty);
    expect(store.budget(projects.last).lines, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'master data review states no quotations are saved on first view',
    (tester) async {
      final dir = Directory.systemTemp.createTempSync('review_master_data');
      addTearDown(() => dir.deleteSync(recursive: true));
      final store = Store.open('${dir.path}/test.db', device: '测试机');
      addTearDown(store.close);
      tester.view.physicalSize = const Size(320, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(),
          home: Scaffold(
            body: MaterialReview(
              state: AppState.test(store, dir),
              masterData: true,
              plans: [
                for (var i = 0; i < 4; i++)
                  store.planOffer(
                    cleanOffer({
                      'name': '控制柜 $i',
                      'supplier': '设备供应商 $i',
                      'unit': '台',
                      'price': '3200',
                    }),
                  ),
              ],
              onBack: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final confirmation = find.byKey(const ValueKey('review-confirmation'));
      expect(
        find
            .descendant(
              of: confirmation,
              matching: find.textContaining('不保存报价'),
            )
            .hitTestable(),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('review-destination')), findsNothing);
      expect(find.text('调整'), findsNothing);
      expect(find.widgetWithText(TextField, '询价人'), findsNothing);
      expect(find.text('报价所属项目'), findsNothing);
      expect(store.listQuotations(), isEmpty);
      expect(store.searchByName('project', ''), isEmpty);
      expect(store.searchByName('supplier', ''), isEmpty);
      expect(store.searchByName('product', ''), isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  for (final width in [320.0, 390.0]) {
    for (final existingProject in [false, true]) {
      testWidgets('review scrolls with 130% text and keyboard: '
          '$width, existing project=$existingProject', (tester) async {
        final dir = Directory.systemTemp.createTempSync('review_layout');
        addTearDown(() => dir.deleteSync(recursive: true));
        final store = Store.open('${dir.path}/test.db', device: '测试机');
        addTearDown(store.close);
        if (existingProject) {
          store.save('project', {
            for (final field in Project.fields) field: null,
            'code': 'P-2026-001',
            'name': '泵房设备与自动化控制系统升级改造项目',
            'status': 'active',
            'currency': 'CNY',
            'tax_mode': 'included',
            'markup_rate': '0',
          });
        }
        final plans = [
          for (var i = 0; i < 4; i++)
            store.planOffer(
              cleanOffer({
                'name': '待核对离心泵 $i',
                'supplier': '设备供应商 $i',
                'unit': '台',
                'price': '3200',
                'tax_mode': 'included',
              }),
              source: '待核对原始资料',
            ),
        ];
        tester.view.physicalSize = Size(width, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          MaterialApp(
            theme: buildTheme(),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: const TextScaler.linear(1.3)),
              child: child!,
            ),
            home: Scaffold(
              appBar: AppBar(title: const Text('智能导入报价 · 核对')),
              body: MaterialReview(
                state: AppState.test(store, dir),
                plans: plans,
                onBack: () {},
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final warning = tester.widget<Text>(
          find.textContaining('原文中找不到：').first,
        );
        expect(warning.maxLines, isNull);
        expect(warning.overflow, isNot(TextOverflow.ellipsis));

        // Selection must survive the row being scrolled off screen.
        await tester.tap(find.byType(Checkbox).first);
        await tester.pumpAndSettle();
        expect(find.text('确认导入（3 条）'), findsOneWidget);
        final destination = find.byKey(const ValueKey('review-destination'));
        expect(destination.hitTestable(), findsOneWidget);
        expect(
          find.textContaining(existingProject ? '泵房设备' : '请填写新项目'),
          findsOneWidget,
        );
        expect(find.textContaining('同时加入预算'), findsOneWidget);
        await tester.tap(destination);
        await tester.pumpAndSettle();
        final scrollable = find
            .descendant(
              of: find.byKey(const ValueKey('review-content')),
              matching: find.byType(Scrollable),
            )
            .first;
        final inquirer = find.widgetWithText(TextField, '询价人');
        await tester.scrollUntilVisible(
          inquirer,
          300,
          scrollable: scrollable,
          maxScrolls: 30,
        );
        await tester.enterText(inquirer, '王五');
        tester.view.viewInsets = const FakeViewPadding(bottom: 300);
        await tester.pumpAndSettle();
        await tester.ensureVisible(inquirer);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final confirmation = find.byKey(const ValueKey('review-confirmation'));
        expect(tester.getBottomRight(confirmation).dy, lessThanOrEqualTo(544));
        expect(tester.getTopLeft(confirmation).dy, greaterThan(100));
        expect(find.text('确认导入（3 条）').hitTestable(), findsOneWidget);
        expect(find.text('同时加入项目成本预算'), findsOneWidget);
        expect(store.listQuotations(), isEmpty);
        expect(store.searchByName('supplier', ''), isEmpty);
        expect(store.searchByName('product', ''), isEmpty);
      });
    }
  }
}
