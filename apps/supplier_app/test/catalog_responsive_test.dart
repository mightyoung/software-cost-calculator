import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supplier_app/app/app_state.dart';
import 'package:supplier_app/app/theme.dart';
import 'package:supplier_app/features/data_center/data_center_page.dart';
import 'package:supplier_app/widgets/data_grid.dart';
import 'package:supplier_core/supplier_core.dart';

void main() {
  for (final type in ['supplier', 'product']) {
    testWidgets('quality opens $type at 390px with large text', (tester) async {
      final dir = Directory.systemTemp.createTempSync('catalog_responsive');
      final store = Store.open('${dir.path}/test.db', device: 'test');
      final state = AppState.test(store, dir);
      for (var i = 0; i < 2; i++) {
        store.save(
          type,
          type == 'supplier'
              ? {
                  for (final f in Supplier.fields) f: null,
                  'name': '同名供应商',
                  'aliases': <String>[],
                  'categories': <String>[],
                }
              : {
                  for (final f in Product.fields) f: null,
                  'name': '测试物料',
                  'unit': '件',
                  'model': 'ABC',
                  'brand': '示例',
                  'category': '用于检验窄屏的较长物料类别',
                },
        );
      }
      addTearDown(() {
        store.close();
        dir.deleteSync(recursive: true);
      });
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: const TextScaler.linear(1.4),
              disableAnimations: true,
            ),
            child: child!,
          ),
          home: Scaffold(body: DataCenterPage(state: state)),
        ),
      );
      await tester.tap(find.text('数据质量'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('打开完整列表').first);
      await tester.pumpAndSettle();
      expect(find.text('完整列表 · 请按问题提示检查'), findsOneWidget);
      expect(find.text(type == 'supplier' ? '新建供应商' : '新建物料'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byType(Checkbox).at(1));
      await tester.pumpAndSettle();
      expect(find.text('已选 1 项'), findsOneWidget);
      expect(tester.takeException(), isNull);
      final horizontal = find.byWidgetPredicate(
        (w) =>
            w is SingleChildScrollView && w.scrollDirection == Axis.horizontal,
      );
      expect(horizontal, findsOneWidget);
      await tester.drag(horizontal, const Offset(-180, 0));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('wide grid keeps rows virtualized on a narrow viewport', (
    tester,
  ) async {
    var built = 0;
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DataGrid<int>(
            rows: List.generate(1000, (i) => i),
            id: (row) => '$row',
            columns: [
              GridColumn(
                '编号',
                width: 600,
                value: (r) => r,
                cell: (r) {
                  built++;
                  return Text('$r');
                },
              ),
            ],
          ),
        ),
      ),
    );
    expect(built, lessThan(100));
    expect(tester.takeException(), isNull);
  });
}
