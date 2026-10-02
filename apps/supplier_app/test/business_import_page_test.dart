import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supplier_app/app/core_supplier_workspace.dart';
import 'package:supplier_app/features/exchange/business_import_page.dart';
import 'package:supplier_core/supplier_core.dart';

import 'support/business_import_rig.dart';

void main() {
  testWidgets(
    'merged supplier reimport skips local edits until explicit reprocess',
    (tester) async {
      final rig = (await tester.runAsync(BusinessImportRig.open))!;
      addTearDown(rig.dispose);
      await tester.binding.setSurfaceSize(const Size(1100, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final workspace = CoreSupplierWorkspace(
        coordinator: rig.host.coordinator,
        records: rig.host.records,
        runTask: (_) => throw UnimplementedError(),
        close: () async {},
        restoreNeedsPath: true,
        createRestoreWorkflow: (_) => throw UnimplementedError(),
      );
      Future<void> click(String label) async {
        var target = find.text(label);
        if (target.evaluate().isEmpty) {
          await tester.scrollUntilVisible(
            target,
            400,
            scrollable: find.byType(Scrollable).first,
            maxScrolls: 50,
          );
        }
        target = target.last;
        await tester.ensureVisible(target);
        await tester.pump(const Duration(milliseconds: 300));
        await tester.runAsync(() async {
          await tester.tap(target);
          await tester.pump();
          await Future<void>.delayed(const Duration(milliseconds: 700));
        });
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pump(const Duration(milliseconds: 300));
      }

      Future<void> preview() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pumpWidget(
          MaterialApp(home: BusinessImportPage(adapter: rig.adapter)),
        );
        await tester.enterText(
          find.byWidgetPredicate(
            (w) => w is TextField && w.decoration?.labelText == 'Excel 文件完整路径',
          ),
          rig.filePath,
        );
        for (final label in ['读取文件工作表', '解析选中工作表', '确认映射并查看转换预览']) {
          await click(label);
        }
      }

      Future<void> commit() async {
        await click('确认本行决定');
        expect(
          find.byType(AlertDialog),
          findsNothing,
          reason: 'Row decision must succeed before final confirmation',
        );
        await click('查看最终汇总');
        await click('确认汇总并提交导入');
        expect(find.textContaining('导入已提交。成功回执'), findsOneWidget);
      }

      Future<List<Map<String, Object?>>> receipts() async => [
        for (final row in await rig.host.database.rows(
          'SELECT event_id,source_fingerprint,operation_fingerprint,original_target_id,result_revision_id '
          'FROM import_row_receipt ORDER BY event_id,operation_fingerprint',
        ))
          row.data,
      ];

      await preview();
      await click('核对并选择操作');
      await commit();
      final original = (await tester.runAsync(receipts))!.single;
      final quotationId = (await tester.runAsync(
        () => workspace.list('quotation'),
      ))!.records.single.id;
      late String targetId;
      await tester.runAsync(() async {
        targetId = await workspace.save('supplier', {
          'name': '合并后的供应商',
          'aliases': <String>[],
          'categories': <String>[],
          'address': null,
          'notes': null,
        });
        final target = await workspace.read('supplier', targetId);
        await workspace.mergeEntities(
          type: 'supplier',
          source: await workspace.read('supplier', rig.supplier),
          target: target,
          targetPayload: target.payload,
        );
        final quotation = await workspace.read('quotation', quotationId);
        await workspace.save(
          'quotation',
          {...quotation.payload, 'notes': '本机核对后备注'},
          id: quotationId,
          expectedHeads: quotation.heads,
        );
      });
      await preview();
      expect(find.text('已导入，建议跳过'), findsOneWidget);
      await click('原值、转换与匹配依据');
      expect(
        find.textContaining(
          '原目标：${original['original_target_id']} · 事件：${original['event_id']}',
        ),
        findsOneWidget,
      );
      await click('分页查看原结果');
      expect(
        find.text(original['result_revision_id']! as String),
        findsOneWidget,
      );
      await click('关闭');
      await click('核对并选择操作');
      expect(
        tester
            .widget<DropdownButtonFormField<BusinessRowChoice>>(
              find.byType(DropdownButtonFormField<BusinessRowChoice>),
            )
            .initialValue,
        BusinessRowChoice.skip,
      );
      await commit();
      expect(await tester.runAsync(receipts), [original]);
      final preserved = await tester.runAsync(
        () => workspace.read('quotation', quotationId),
      );
      expect(preserved!.payload['notes'], '本机核对后备注');

      await preview();
      await click('核对并选择操作');
      await tester.tap(find.byType(DropdownButtonFormField<BusinessRowChoice>));
      await tester.pumpAndSettle();
      await click('新增标准询价');
      await tester.enterText(
        find.byWidgetPredicate(
          (w) => w is TextField && w.decoration?.labelText == '明确选择供应商编号',
        ),
        targetId,
      );
      await click('已查看旧回执，明确重新处理此次来件');
      await commit();
      final repeated = (await tester.runAsync(receipts))!;
      expect(repeated, hasLength(2));
      expect(repeated, contains(equals(original)));
      final second = repeated.singleWhere(
        (r) => r['event_id'] != original['event_id'],
      );
      expect(second['source_fingerprint'], original['source_fingerprint']);
      expect(
        second['result_revision_id'],
        isNot(original['result_revision_id']),
      );
      await click('分页查看提交结果（1 个修订）');
      expect(
        find.text(second['result_revision_id']! as String),
        findsOneWidget,
      );
      expect(
        (await tester.runAsync(() => workspace.read('quotation', quotationId)))!
            .payload['notes'],
        '本机核对后备注',
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
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

  testWidgets('source receipt history can load beyond the first page', (
    tester,
  ) async {
    final rig = await tester.runAsync(BusinessImportRig.open);
    addTearDown(() => rig!.dispose());
    await tester.binding.setSurfaceSize(const Size(1100, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    Future<void> click(String label) async {
      if (find.text(label).evaluate().isEmpty) {
        await tester.scrollUntilVisible(
          find.text(label),
          500,
          scrollable: find.byType(Scrollable).first,
          maxScrolls: 150,
        );
      }
      final target = find.text(label).last;
      await tester.ensureVisible(target);
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await tester.tap(target);
        await Future<void>.delayed(const Duration(milliseconds: 350));
      });
      await tester.pumpAndSettle();
    }

    await tester.pumpWidget(
      MaterialApp(home: BusinessImportPage(adapter: rig!.adapter)),
    );
    await tester.enterText(
      find.byWidgetPredicate(
        (w) => w is TextField && w.decoration?.labelText == 'Excel 文件完整路径',
      ),
      rig.filePath,
    );
    for (final label in [
      '读取文件工作表',
      '解析选中工作表',
      '确认映射并查看转换预览',
      '核对并选择操作',
      '确认本行决定',
      '查看最终汇总',
      '确认汇总并提交导入',
    ]) {
      await click(label);
    }
    final receiptCount = await tester.runAsync(() async {
      final row = (await rig.host.database.rows(
        'SELECT event_id,source_fingerprint,original_target_id,result_revision_id '
        'FROM import_row_receipt LIMIT 1',
      )).single;
      for (var i = 0; i < 50; i++) {
        await rig.host.database.customStatement(
          'INSERT INTO import_row_receipt VALUES(?,?,?,?,?,?)',
          [
            row.read<String>('event_id'),
            1,
            row.read<String>('source_fingerprint'),
            'extra-${i.toString().padLeft(3, '0')}',
            row.read<String>('original_target_id'),
            row.read<String>('result_revision_id'),
          ],
        );
      }
      return (await rig.host.database.rows(
        'SELECT COUNT(*) AS n FROM import_row_receipt',
      )).single.read<int>('n');
    });
    expect(receiptCount, 51);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpWidget(
      MaterialApp(home: BusinessImportPage(adapter: rig.adapter)),
    );
    await tester.enterText(
      find.byWidgetPredicate(
        (w) => w is TextField && w.decoration?.labelText == 'Excel 文件完整路径',
      ),
      rig.filePath,
    );
    for (final label in ['读取文件工作表', '解析选中工作表', '确认映射并查看转换预览']) {
      await click(label);
    }
    await click('原值、转换与匹配依据');
    expect(find.text('加载更多原成功选择'), findsOneWidget);
    await click('加载更多原成功选择');
    expect(find.text('加载更多原成功选择'), findsNothing);
    expect(find.text('分页查看原结果', skipOffstage: false), findsNWidgets(51));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
