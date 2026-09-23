import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:supplier_app/app/core_supplier_workspace.dart';
import 'package:supplier_app/app/supplier_app.dart';
import 'package:supplier_app/platform/native_file_ports.dart';
import 'package:supplier_app/platform/workspace_factory_native.dart';
import 'package:supplier_core/supplier_core.dart';

/// Runs against native SQLite and application-owned files in a fresh directory.
/// Without a macOS runner, `-d flutter-tester` exercises the host-side Flutter
/// UI and native adapters; it does not verify a packaged desktop application.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'native workspace UI survives reopen and publishes readable Excel and backup',
    (tester) async {
      final directory = await Directory.systemTemp.createTemp(
        'supplier-local-workflow-',
      );
      CoreSupplierWorkspace? workspace;
      tester.view.physicalSize = const Size(1280, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      try {
        workspace = await openNativeSupplierWorkspace(directory);
        await tester.pumpWidget(SupplierApp(workspace: workspace));
        await _waitFor(tester, find.text('没有符合条件的记录'));

        // Create both related entities through their real production forms.
        await tester.tap(find.byIcon(Icons.store_outlined));
        await _waitFor(tester, find.text('新增供应商'));
        await tester.tap(find.text('新增供应商'));
        await tester.pumpAndSettle();
        await _fill(tester, 'name', '沪申机电供应');
        await _fill(tester, 'address', '上海市徐汇区');
        await tester.tap(find.text('保存'));
        await _waitFor(tester, find.text('沪申机电供应'));

        await tester.tap(find.byIcon(Icons.inventory_2_outlined));
        await _waitFor(tester, find.text('新增产品'));
        await tester.tap(find.text('新增产品'));
        await tester.pumpAndSettle();
        await _fill(tester, 'name', '不锈钢紧固件');
        await _fill(tester, 'unit', '件');
        await _fill(tester, 'brand', '沪申');
        await _fill(tester, 'model', 'M8-A');
        await tester.tap(find.text('保存'));
        await _waitFor(tester, find.text('不锈钢紧固件'));

        await tester.tap(find.text('新增报价'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('选择供应商 *'));
        await _waitFor(tester, find.text('沪申机电供应'));
        await tester.tap(find.text('沪申机电供应'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('选择产品 *'));
        await _waitFor(tester, find.text('不锈钢紧固件'));
        await tester.tap(find.text('不锈钢紧固件'));
        await tester.pumpAndSettle();
        await _fill(tester, 'price', '12.340001');
        await _fill(tester, 'quoted_on', '2026-09-21');
        await _fill(tester, 'project_number', '000123-A');
        await _fill(tester, 'inquirer_name', '周工');
        await _fill(tester, 'inquiry_date', '2026-09-20');
        await tester.tap(find.text('保存'));
        await _waitFor(tester, find.byIcon(Icons.manage_search));

        final saved = (await workspace.list('quotation')).records.single;
        expect(saved.payload['capture_mode'], 'standard');
        expect(saved.payload['price'], '12.340001');
        expect(saved.payload['project_number'], '000123-A');
        expect(saved.payload['inquiry_precision'], 'date');
        expect(saved.payload['inquired_at'], isNull);
        expect(saved.missingContext, isEmpty);
        expect(saved.heads, hasLength(1));
        final before = await workspace.coordinator.readActiveVersion();

        // Dispose the entire UI and connection, then reopen the same durable
        // installation. No in-memory fixture or fake-success adapter is used.
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        await workspace.close();
        workspace = null;
        workspace = await openNativeSupplierWorkspace(directory);
        final after = await workspace.coordinator.readActiveVersion();
        expect(_version(after), _version(before));
        await tester.pumpWidget(SupplierApp(workspace: workspace));
        await _waitFor(tester, find.text('不锈钢紧固件'));

        await tester.enterText(find.byType(TextField), '紧固件');
        await tester.tap(find.byTooltip('搜索'));
        await _waitFor(tester, find.text('不锈钢紧固件'));
        await tester.tap(find.text('组合筛选'));
        await tester.pumpAndSettle();
        final projectFilter = find.widgetWithText(TextField, '项目编号');
        await tester.ensureVisible(projectFilter);
        await tester.enterText(projectFilter, '000123-A');
        await tester.tap(find.text('应用筛选'));
        await _waitFor(tester, find.text('不锈钢紧固件'));
        final matched = await workspace.list(
          'quotation',
          search: '紧固件',
          filters: {
            'project_number': '000123-A',
            'inquiry_from': '2026-09-20',
            'inquiry_to': '2026-09-20',
            'price_min': '12.340001',
            'price_max': '12.340001',
          },
        );
        expect(matched.records.single.id, saved.id);
        expect(matched.records.single.heads, saved.heads);
        expect(
          (await workspace.list('quotation', search: '完全不匹配')).records,
          isEmpty,
        );

        await tester.tap(find.byIcon(Icons.import_export));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(OutlinedButton, '导出业务 Excel'));
        await _waitFor(tester, find.textContaining('业务表已生成并回读校验'));
        final exported = await _singleFile(directory, 'exports', '.xlsx');
        final staging = XlsxStaging(NativeDatabase.memory());
        try {
          final profile = await const BoundedXlsxReader().readVolume(
            NativeInputSource(exported, displayName: '业务报价.xlsx'),
            staging,
          );
          expect(
            profile.rows,
            2,
          ); // Header plus the actual persisted quotation.
          final headers = await staging.cellsPage(1, limit: 200);
          final cells = await staging.cellsPage(2, limit: 200);
          final names = {
            for (final cell in headers) cell.column: cell.cell.lexical,
          };
          final values = {
            for (final cell in cells) names[cell.column]!: cell.cell.lexical,
          };
          expect(values['记录ID'], saved.id);
          expect(values['导出时修订ID'], saved.heads.single);
          expect(values['价格'], '12.340001');
          expect(values['项目编号'], '000123-A');
          expect(values['询价时间精度'], 'date');
          expect(values['询价日期'], '2026-09-20');
          expect(values['询价时间（UTC）'], isEmpty);
          expect(values['供应商名称'], '沪申机电供应');
        } finally {
          await staging.close();
        }

        await tester.scrollUntilVisible(
          find.widgetWithText(OutlinedButton, '生成完整备份'),
          180,
        );
        await tester.tap(find.widgetWithText(OutlinedButton, '生成完整备份'));
        await _waitFor(tester, find.textContaining('完整备份已生成并校验'));
        final backup = await _singleFile(directory, 'backups', '.backup');
        final revisions = <BackupEntry>[];
        final summary = await decodeBackup(
          NativeInputSource(backup, displayName: '完整备份'),
          onEntry: (entry) async {
            if (entry.table == 'revision') revisions.add(entry);
          },
        );
        expect(summary.header.counts['revision'], 3);
        expect(revisions, hasLength(3));
        final quoteRevision = revisions.singleWhere(
          (entry) => entry.row['entity_id'] == saved.id,
        );
        expect(quoteRevision.row['revision_id'], saved.heads.single);
        final envelope =
            jsonDecode(quoteRevision.row['canonical']! as String) as Map;
        final payload = envelope['payload'] as Map;
        expect(payload['price'], '12.340001');
        expect(payload['project_number'], '000123-A');
        expect(payload['inquired_at'], isNull);
        expect(find.textContaining(summary.digest), findsOneWidget);
        expect(
          _version(await workspace.coordinator.readActiveVersion()),
          _version(after),
          reason: 'Export and backup must not modify the business generation.',
        );
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        await workspace?.close();
        await directory.delete(recursive: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}

Future<void> _waitFor(WidgetTester tester, Finder finder) async {
  for (var attempt = 0; attempt < 200; attempt++) {
    await tester.pump(const Duration(milliseconds: 50));
    if (finder.evaluate().isNotEmpty) {
      await tester.pumpAndSettle();
      return;
    }
  }
  fail('The real workflow did not reach $finder within 10 seconds.');
}

Future<void> _fill(WidgetTester tester, String field, String value) async {
  final finder = find.byKey(ValueKey('field-$field'));
  if (finder.evaluate().isEmpty) {
    await tester.scrollUntilVisible(finder, 180);
  } else {
    await tester.ensureVisible(finder);
  }
  await tester.enterText(finder, value);
}

Future<File> _singleFile(
  Directory directory,
  String folder,
  String suffix,
) async {
  final entries = await Directory('${directory.path}/$folder')
      .list(recursive: true)
      .where((entry) => entry is File && entry.path.endsWith(suffix))
      .toList();
  expect(entries, hasLength(1));
  return entries.single as File;
}

(String, int, int) _version(DatabaseVersion version) =>
    (version.instanceId, version.activeEpoch, version.generation);
