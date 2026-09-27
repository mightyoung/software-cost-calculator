import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supplier_app/app/app_state.dart';
import 'package:supplier_app/app/theme.dart';
import 'package:supplier_app/features/ai/material_review.dart';
import 'package:supplier_core/supplier_core.dart';

void main() {
  testWidgets('smart import review: blocked rows, inquirer, import', (
    tester,
  ) async {
    final dir = Directory.systemTemp.createTempSync('material_review');
    addTearDown(() => dir.deleteSync(recursive: true));
    final store = Store.open('${dir.path}/m.db', device: '测试机');
    addTearDown(store.close);
    final state = AppState.test(store, dir);
    final known = store.save('supplier', {
      for (final f in Supplier.fields) f: null,
      'name': '甲泵业',
      'aliases': <String>[],
      'categories': <String>[],
    });
    final project = store.save('project', {
      for (final f in Project.fields) f: null,
      'code': 'P1',
      'name': '泵房',
      'status': 'active',
      'currency': 'CNY',
      'tax_mode': 'included',
      'markup_rate': '0',
    });
    final plans = [
      for (final raw in [
        {
          'supplier': '甲泵业',
          'phone': '13800000000',
          'name': '离心泵',
          'model': 'IS80',
          'unit': '台',
          'price': '3200',
          'tax_mode': 'included',
        },
        {'supplier': '丙公司', 'name': '配件'},
      ])
        store.planOffer(cleanOffer(raw)),
    ];
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: Scaffold(
          body: MaterialReview(state: state, plans: plans, onBack: () {}),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('缺少单位'), findsOneWidget);
    expect(find.text('已有：甲泵业'), findsOneWidget, reason: 'matched supplier');

    await tester.tap(find.text('确认导入（1 条）'));
    await tester.pump();
    expect(find.text('填写询价人'), findsOneWidget);
    expect(store.listQuotations(), isEmpty);

    await tester.enterText(find.widgetWithText(TextField, '询价人'), '王五');
    await tester.tap(find.text('确认导入（1 条）'));
    await tester.pumpAndSettle();
    final quotes = store.listQuotations(projectId: project);
    expect(quotes, hasLength(1));
    expect(quotes.single.data['supplier_id'], known);
    expect(quotes.single.data['price'], '3200');
    expect(store.budget(project).lines, hasLength(1));
    expect(state.setting('inquirer'), '王五');
  });
}
