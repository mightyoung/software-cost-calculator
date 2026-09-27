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
}
