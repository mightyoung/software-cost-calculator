import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supplier_app/app/app_state.dart';
import 'package:supplier_app/app/format.dart';
import 'package:supplier_app/app/shell.dart';
import 'package:supplier_app/app/theme.dart';
import 'package:supplier_core/supplier_core.dart';

Map<String, Object?> _blank(List<String> fields, Map<String, Object?> v) => {
  for (final f in fields) f: null,
  ...v,
};

void main() {
  late Directory dir;
  late AppState state;
  late String project, pumpLine;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('supplier_app_test');
    final store = Store.open('${dir.path}/t.db', device: '测试机');
    final sup = store.save(
      'supplier',
      _blank(Supplier.fields, {
        'name': '甲泵业',
        'aliases': <String>[],
        'categories': <String>[],
      }),
    );
    final pump = store.save(
      'product',
      _blank(Product.fields, {
        'name': '离心水泵',
        'unit': '台',
        'model': 'IS80-65-160',
      }),
    );
    project = store.save(
      'project',
      _blank(Project.fields, {
        'code': '2026-TEST-001',
        'name': '泵房改造工程',
        'status': 'active',
        'currency': 'CNY',
        'tax_mode': 'included',
        'markup_rate': '15',
        'contract_amount': '70000',
        'customer': '华东水务',
      }),
    );
    final today = DateTime.now().toIso8601String().substring(0, 10);
    final quote = store.save(
      'quotation',
      _blank(Quotation.fields, {
        'supplier_id': sup,
        'product_id': pump,
        'project_id': project,
        'price': '32500',
        'currency': 'CNY',
        'tax_mode': 'included',
        'unit_snapshot': '台',
        'min_qty': '1',
        'quoted_on': today,
        'inquirer_name': '王工',
        'inquiry_precision': 'date',
        'inquiry_date': today,
        'capture_mode': 'standard',
      }),
    );
    pumpLine = store.save(
      'project_item',
      _blank(ProjectItem.fields, {
        'project_id': project,
        'category': 'material',
        'product_id': pump,
        'quotation_id': quote,
        'qty': '2',
        'unit': '台',
        'unit_cost': '32500',
      }),
    );
    store.save(
      'project_item',
      _blank(ProjectItem.fields, {
        'project_id': project,
        'category': 'material',
        'name': '电磁流量计',
        'qty': '1',
        'unit': '台',
        'unit_cost': '0',
      }),
    );
    state = AppState.test(store, dir);
  });

  tearDown(() {
    state.store.close();
    dir.deleteSync(recursive: true);
  });

  Future<void> pumpApp(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: Shell(state: state),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'project budget shows groups, totals, warnings and unpriced lines',
    (tester) async {
      await pumpApp(tester);
      expect(find.text('泵房改造工程'), findsWidgets);
      expect(find.text('材料费'), findsOneWidget);
      expect(
        find.text('¥65,000.00'),
        findsWidgets,
        reason: 'group subtotal and cost total',
      );
      expect(find.text('待询价'), findsOneWidget);
      expect(find.text('含 1 项待询价，未计入'), findsOneWidget);
      // 65,000 / 70,000 = 92.9% of contract -> warning in the ledger strip.
      expect(find.textContaining('已达合同金额 92.9%'), findsOneWidget);
      expect(find.textContaining('IS80-65-160 · 甲泵业'), findsOneWidget);
    },
  );

  testWidgets('editing a line quantity updates totals', (tester) async {
    await pumpApp(tester);
    await tester.tap(find.text('离心水泵').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, '数量'), '3');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(state.store.get('project_item', pumpLine)!.data['qty'], '3');
    expect(find.text('¥97,500.00'), findsWidgets);
  });

  test('money formatting is exact', () {
    expect(money('1234567.5', prefix: '¥'), '¥1,234,567.50');
    expect(money('0.000001'), '0.000001');
    expect(money('-3.5'), '-3.50');
    expect(yuan('28023.5'), '¥28,024');
    expect(percent('65000', '70000'), '92.9%');
    expect(percent('1', '0'), isNull);
  });
}
