import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supplier_app/app/app_state.dart';
import 'package:supplier_app/app/theme.dart';
import 'package:supplier_app/features/catalog/catalog_page.dart';
import 'package:supplier_core/supplier_core.dart';

void main() {
  late Directory dir;
  late AppState state;
  late String existing;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('catalog_test');
    final store = Store.open('${dir.path}/c.db', device: '测试机');
    existing = store.save('supplier', {
      for (final f in Supplier.fields) f: null,
      'name': '永泰阀门',
      'aliases': <String>[],
      'categories': <String>[],
    });
    state = AppState.test(store, dir);
  });

  tearDown(() {
    state.store.close();
    dir.deleteSync(recursive: true);
  });

  Future<void> open(
    WidgetTester tester, {
    String type = 'supplier',
    String? id,
  }) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showCatalogForm(context, state, type, id: id),
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
  }

  testWidgets('creating a same-named supplier asks first', (tester) async {
    await open(tester);
    await tester.enterText(find.widgetWithText(TextField, '供应商名称'), '永泰阀门有限公司');
    await tester.pump();
    expect(find.text('可能已经存在'), findsOneWidget);
    expect(find.text('相同'), findsOneWidget);

    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.text('已有相同的供应商'), findsOneWidget);
    await tester.tap(find.text('仍然新建'));
    await tester.pumpAndSettle();
    expect(state.store.searchByName('supplier', '永泰'), hasLength(2));
  });

  testWidgets('editing a duplicate offers to merge it', (tester) async {
    final dup = state.store.save('supplier', {
      for (final f in Supplier.fields) f: null,
      'name': '永泰阀门有限公司',
      'aliases': <String>[],
      'categories': <String>[],
    });
    await open(tester, id: dup);
    await tester.tap(find.text('合并到这条'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('合并'));
    await tester.pumpAndSettle();
    expect(state.store.get('supplier', dup)!.data['merged_into'], existing);
    expect(state.store.searchByName('supplier', '永泰').single.id, existing);
  });

  testWidgets('a supplier can be rated with a reason', (tester) async {
    await open(tester, id: existing);
    await tester.tap(find.text('停用'));
    await tester.pumpAndSettle();
    expect(find.textContaining('不参与最低价'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextField, '评价说明'), '交货屡次延期');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    final d = state.store.get('supplier', existing)!.data;
    expect((d['rating'], d['rating_note']), ('disabled', '交货屡次延期'));
  });

  testWidgets('a material gets typed parameters from a template', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 2400);
    await open(tester, type: 'product');
    await tester.enterText(find.widgetWithText(TextField, '物料名称'), '温湿度变送器');
    await tester.enterText(find.widgetWithText(TextField, '单位'), '个');
    await tester.pumpAndSettle();
    // The template is recognized from the name and offered.
    await tester.tap(find.text('用「温湿度传感器」'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, '温度测量范围 ·关键'),
      '-40~85℃',
    );
    await tester.enterText(find.widgetWithText(TextField, '温度精度 ·关键'), '±0.2');
    await tester.enterText(find.widgetWithText(TextField, '防护等级'), 'IP6');
    await tester.pumpAndSettle();
    expect(find.textContaining('无法识别'), findsOneWidget);
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.textContaining('「防护等级」无法识别'), findsOneWidget);

    await tester.enterText(find.widgetWithText(TextField, '防护等级'), 'IP66/67');
    await tester.ensureVisible(find.text('RS485'));
    await tester.tap(find.text('RS485'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    final id = state.store.searchByName('product', '温湿度变送器').single.id;
    expect(state.store.get('product', id)!.data['spec_class'], 'sensor.th');
    final params = {
      for (final e in state.store.paramsOf(id).entries)
        e.key: e.value.data['value'],
    };
    expect(params, {
      'th.temp_range': {'min': '-40', 'max': '85', 'u': 'Cel'},
      'th.temp_accuracy': {'v': '0.2', 'u': 'Cel'},
      'prot.ip': {
        'codes': ['IP66', 'IP67'],
      },
      'io.output': {
        'vs': ['RS485'],
      },
    });
    expect(state.store.paramCompleteness(id), (filled: 3, total: 5));
  });

  testWidgets('product form saves a configurable quote unit', (tester) async {
    await open(tester, type: 'product');
    await tester.enterText(find.widgetWithText(TextField, '物料名称'), '动力电缆');
    await tester.enterText(find.widgetWithText(TextField, '单位'), '米');
    await tester.ensureVisible(find.text('添加单位'));
    await tester.tap(find.text('添加单位'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.widgetWithText(TextField, '报价单位'));
    await tester.enterText(find.widgetWithText(TextField, '报价单位'), '千米');
    await tester.enterText(find.widgetWithText(TextField, '等于多少米'), '1000');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    final product = state.store.searchByName('product', '动力电缆').single;
    expect(product.data['unit_conversions'], {'千米': '1000'});
  });

  testWidgets('deleting asks, can be undone, and waits in the bin', (
    tester,
  ) async {
    final pump = state.store.save('product', {
      for (final f in Product.fields) f: null,
      'name': '离心泵',
      'unit': '台',
    });
    final pro = state.store.save('project', {
      for (final f in Project.fields) f: null,
      'code': 'P1',
      'name': '泵房',
      'status': 'active',
      'currency': 'CNY',
      'tax_mode': 'included',
      'markup_rate': '0',
    });
    state.store.save('quotation', {
      for (final f in Quotation.fields) f: null,
      'supplier_id': existing,
      'product_id': pump,
      'price': '10',
      'currency': 'CNY',
      'tax_mode': 'included',
      'unit_snapshot': '台',
      'min_qty': '1',
      'quoted_on': '2026-09-01',
      'project_id': pro,
      'inquirer_name': '王工',
      'inquiry_precision': 'date',
      'inquiry_date': '2026-09-01',
      'capture_mode': 'standard',
    });
    await open(tester, id: existing);
    await tester.tap(find.text('删除供应商'));
    await tester.pumpAndSettle();
    expect(find.text('删除供应商「永泰阀门」？'), findsOneWidget);
    expect(find.textContaining('还有 1 条报价引用了它'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, '删除供应商'));
    await tester.pumpAndSettle();
    expect(state.store.get('supplier', existing)!.deleted, isTrue);
    expect(find.text('已删除供应商「永泰阀门」'), findsOneWidget);

    await tester.tap(find.text('撤销'));
    await tester.pumpAndSettle();
    expect(state.store.get('supplier', existing)!.deleted, isFalse);

    state.store.delete('supplier', existing);
    expect(state.store.deletedRecords().single.id, existing);
  });

  testWidgets('the supplier table shows every row, sorts and exports', (
    tester,
  ) async {
    state.store.transaction(() {
      for (var i = 0; i < 204; i++) {
        state.store.save('supplier', {
          for (final f in Supplier.fields) f: null,
          'name': '供应商$i',
          'aliases': <String>[],
          'categories': <String>[],
        });
      }
    });
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: Scaffold(
          body: CatalogPage(state: state, type: 'supplier'),
        ),
      ),
    );
    expect(find.text('共 205 个'), findsOneWidget);
    // Sorting by name ascending puts 永泰阀门 (U+6C38) after 供应商… (U+4F9B).
    await tester.tap(find.text('名称'));
    await tester.pumpAndSettle();
    expect(find.text('供应商0'), findsOneWidget);
    final list = find.descendant(
      of: find.byType(ListView),
      matching: find.byType(Scrollable),
    );
    await tester.scrollUntilVisible(find.text('永泰阀门'), 800, scrollable: list);
    expect(find.text('永泰阀门'), findsOneWidget, reason: 'nothing cut off');
    await tester.enterText(find.byType(TextField), '永泰');
    await tester.pumpAndSettle();
    expect(find.text('找到 1 个'), findsOneWidget);
  });
}
