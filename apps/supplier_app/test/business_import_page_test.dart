import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supplier_app/features/exchange/business_import_page.dart';
import 'package:supplier_core/supplier_core.dart';

import 'support/business_import_rig.dart';

void main() {
  testWidgets(
    'real workbook UI previews, confirms a row, then commits only after final confirmation',
    (tester) async {
      final rig = await tester.runAsync(BusinessImportRig.open);
      addTearDown(() => rig!.dispose());
      await tester.binding.setSurfaceSize(const Size(1100, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(home: BusinessImportPage(adapter: rig!.adapter)),
      );
      Finder field(String label) => find.byWidgetPredicate(
        (w) => w is TextField && w.decoration?.labelText == label,
      );
      Future<void> click(String label) async {
        if (find.text(label).evaluate().isEmpty) {
          await tester.scrollUntilVisible(
            find.text(label),
            500,
            scrollable: find.byType(Scrollable).first,
            maxScrolls: 30,
          );
        }
        final button = find.text(label).last;
        await tester.ensureVisible(button);
        await tester.pumpAndSettle();
        await tester.runAsync(() async {
          await tester.tap(button);
          await Future<void>.delayed(const Duration(milliseconds: 350));
        });
        await tester.pumpAndSettle();
      }

      await tester.enterText(field('Excel 文件完整路径'), rig.filePath);
      await click('读取文件工作表');
      await click('解析选中工作表');
      expect(find.text('选择列映射'), findsOneWidget);
      await click('确认映射并查看转换预览');
      expect(find.text('第 2 行'), findsOneWidget);
      await click('核对并选择操作');
      expect(find.text('核对第 2 行'), findsOneWidget);
      await click('确认本行决定');
      expect(find.textContaining('已确认：应用'), findsOneWidget);
      final before = await tester.runAsync(
        () => QueryRepository(rig.host.database).quotations({}),
      );
      expect(before!.items, isEmpty);
      await click('查看最终汇总');
      expect(find.textContaining('应用 1 行'), findsOneWidget);
      await click('确认汇总并提交导入');
      expect(find.textContaining('导入已提交。成功回执'), findsOneWidget);
      final after = await tester.runAsync(
        () => QueryRepository(rig.host.database).quotations({}),
      );
      expect(after!.items, hasLength(1));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
    },
  );
  testWidgets('invalid file reports failure and never a success message', (
    tester,
  ) async {
    final rig = await tester.runAsync(BusinessImportRig.open);
    addTearDown(() => rig!.dispose());
    await tester.pumpWidget(
      MaterialApp(home: BusinessImportPage(adapter: rig!.adapter)),
    );
    await tester.enterText(
      find.byType(TextField).first,
      '/missing-supplier-quotation.xlsx',
    );
    await tester.runAsync(() async {
      await tester.tap(find.text('读取文件工作表'));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();
    expect(find.textContaining('操作未完成'), findsOneWidget);
    expect(find.textContaining('导入已提交'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
