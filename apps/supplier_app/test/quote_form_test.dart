import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supplier_app/app/app_state.dart';
import 'package:supplier_app/app/theme.dart';
import 'package:supplier_app/features/quotes/quote_form.dart';
import 'package:supplier_core/supplier_core.dart';

Map<String, Object?> _b(List<String> fields, Map<String, Object?> v) => {
  for (final f in fields) f: null,
  ...v,
};

void main() {
  testWidgets('price tiers are entered and saved with the quote', (
    tester,
  ) async {
    final dir = Directory.systemTemp.createTempSync('quote_form');
    addTearDown(() => dir.deleteSync(recursive: true));
    final s = Store.open('${dir.path}/q.db', device: '测试机');
    addTearDown(s.close);
    final sup = s.save(
      'supplier',
      _b(Supplier.fields, {
        'name': '国优电缆',
        'aliases': <String>[],
        'categories': <String>[],
      }),
    );
    final prod = s.save(
      'product',
      _b(Product.fields, {'name': '控制电缆', 'unit': '米'}),
    );
    final pro = s.save(
      'project',
      _b(Project.fields, {
        'code': 'P1',
        'name': '监控',
        'status': 'active',
        'currency': 'CNY',
        'tax_mode': 'included',
        'markup_rate': '0',
      }),
    );
    final q = s.save(
      'quotation',
      _b(Quotation.fields, {
        'supplier_id': sup,
        'product_id': prod,
        'project_id': pro,
        'price': '3.5',
        'currency': 'CNY',
        'tax_mode': 'included',
        'unit_snapshot': '米',
        'min_qty': '1',
        'quoted_on': '2026-09-20',
        'inquirer_name': '王工',
        'inquiry_precision': 'date',
        'inquiry_date': '2026-09-20',
        'capture_mode': 'standard',
      }),
    );
    final state = AppState.test(s, dir);
    tester.view.physicalSize = const Size(1280, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showQuoteForm(context, state, id: q),
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('添加一档'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, '数量达到（米）'), '1,000');
    await tester.tap(find.text('保存报价'));
    await tester.pumpAndSettle();
    expect(find.textContaining('数量和单价都要填写'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextField, '单价').last, '3.2');
    await tester.tap(find.text('保存报价'));
    await tester.pumpAndSettle();
    expect(s.get('quotation', q)!.data['price_tiers'], [
      {'min_qty': '1000', 'price': '3.2'},
    ]);
  });
}
