import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supplier_app/app/app_state.dart';
import 'package:supplier_app/app/theme.dart';
import 'package:supplier_app/features/inquiries/inquiry_page.dart';
import 'package:supplier_core/supplier_core.dart';

Map<String, Object?> _b(List<String> fields, Map<String, Object?> v) => {
  for (final f in fields) f: null,
  ...v,
};

void main() {
  testWidgets('award a row from the matrix prices the budget line', (
    tester,
  ) async {
    final dir = Directory.systemTemp.createTempSync('inquiry_page');
    addTearDown(() => dir.deleteSync(recursive: true));
    final s = Store.open('${dir.path}/i.db', device: '测试机');
    addTearDown(s.close);
    String sup(String n) => s.save(
      'supplier',
      _b(Supplier.fields, {
        'name': n,
        'aliases': <String>[],
        'categories': <String>[],
      }),
    );
    final jia = sup('甲泵业'), yi = sup('乙机电');
    final pro = s.save(
      'project',
      _b(Project.fields, {
        'code': 'P1',
        'name': '泵房',
        'status': 'active',
        'currency': 'CNY',
        'tax_mode': 'included',
        'markup_rate': '0',
      }),
    );
    final line = s.save(
      'project_item',
      _b(ProjectItem.fields, {
        'project_id': pro,
        'category': 'material',
        'name': '离心泵 IS80',
        'qty': '2',
        'unit': '台',
        'unit_cost': '0',
      }),
    );
    final inq = s.createInquiry(
      pro,
      '泵询价',
      itemIds: [line],
      supplierIds: [jia, yi],
    );
    const ctx = (inquirer: '王工', asOf: null);
    s.quoteForInquiry(inq, line, jia, price: '3200', context: ctx);
    s.quoteForInquiry(
      inq,
      line,
      yi,
      price: '3000',
      extraCost: '800',
      context: ctx,
    );
    final state = AppState.test(s, dir);

    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: InquiryPage(state: state, id: inq),
      ),
    );
    expect(find.text('最低'), findsOneWidget);
    expect(find.text('¥3,400.00'), findsOneWidget, reason: '3000 + 800 / 2');

    await tester.tap(find.widgetWithText(OutlinedButton, '定标'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, '成交单价'), '3150');
    await tester.tap(find.text('确认定标'));
    await tester.pumpAndSettle();

    final item = s.get('project_item', line)!.data;
    expect(item['unit_cost'], '3150');
    expect(
      s.get('quotation', item['quotation_id']! as String)!.data['supplier_id'],
      jia,
    );
    expect(find.text('撤销定标'), findsOneWidget);
    expect(find.text('已定标'), findsOneWidget);
  });
}
