import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:supplier_app/app/core_supplier_workspace.dart';
import 'package:supplier_app/features/exchange/exchange_page.dart';
import 'package:supplier_app/platform/workspace_factory_native.dart';

import 'local_workflows_test.dart' as local;

/// Run on Android: all business writes are confined to a fresh temp workspace.
/// The real application support directory is resolved, never opened as a DB.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Android resolves its real persistent application directory', (
    tester,
  ) async {
    expect(Platform.isAndroid, isTrue, reason: 'Run this suite on Android.');
    final resolved = await resolveNativeDataDirectory();
    final native = await getApplicationSupportDirectory();
    expect(resolved.isAbsolute, isTrue);
    expect(
      await resolved.resolveSymbolicLinks(),
      await native.resolveSymbolicLinks(),
    );
    expect(resolved.path, isNot(Directory.systemTemp.path));
  });

  local.registerLocalWorkflow(mobile: true, afterBackup: _restoreAndSync);
}

Future<CoreSupplierWorkspace> _restoreAndSync(
  WidgetTester tester,
  CoreSupplierWorkspace original,
  Directory directory,
  File backup,
) async {
  var current = original;
  try {
    final saved = (await original.list('quotation')).records.single;
    // Change the real saved quotation so restoring cannot pass as a no-op.
    await tester.tap(find.byIcon(Icons.manage_search));
    await _wait(tester, find.text('不锈钢紧固件'));
    await tester.tap(find.text('不锈钢紧固件'));
    await _wait(tester, find.text('编辑记录'));
    await _tap(tester, find.text('编辑记录'));
    expect(find.text('第 1 步，共 3 步'), findsOneWidget);
    final price = find.byKey(const ValueKey('field-price'));
    await _visible(tester, price);
    await tester.enterText(price, '98.765432');
    await _tap(tester, find.text('下一步'));
    await _tap(tester, find.text('下一步'));
    await _tap(tester, find.text('保存'));
    await _wait(tester, find.text('编辑记录'));
    expect(
      (await original.read('quotation', saved.id)).payload['price'],
      '98.765432',
    );
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.import_export));
    await tester.pumpAndSettle();

    await _tap(tester, find.widgetWithText(OutlinedButton, '恢复备份'));
    await tester.enterText(
      find.widgetWithText(TextField, '备份文件路径'),
      backup.path,
    );
    await _tap(tester, find.text('读取并验证'));
    await _wait(tester, find.text('确认恢复完整备份'));
    await _tap(tester, find.widgetWithText(FilledButton, '确认恢复'));
    await _wait(tester, find.text('完整备份已验证、切换并重新打开。'));
    current =
        tester.widget<ExchangePage>(find.byType(ExchangePage)).workspace
            as CoreSupplierWorkspace;
    expect(identical(current, original), isFalse);
    final restored = (await current.list('quotation')).records.single;
    expect(restored.id, saved.id);
    expect(restored.heads, saved.heads);
    expect(restored.payload['price'], '12.340001');
    expect(restored.payload['project_number'], '000123-A');
    expect((await current.list('supplier')).records.single.title, '沪申机电供应');
    expect((await current.list('product')).records.single.title, '不锈钢紧固件');

    await _tap(tester, find.text('打开完整同步'));
    await _tap(tester, find.text('生成同步包'));
    await _wait(tester, find.textContaining('完整同步包已生成并自验'));
    final bundles = await Directory('${directory.path}/exports')
        .list(recursive: true)
        .where((entry) => entry is File && entry.path.endsWith('.zip'))
        .toList();
    expect(bundles, hasLength(1));
    // Import the same real archive twice through preview and confirmation.
    // Check business identities and revision heads, not just success messages.
    for (var repeat = 0; repeat < 2; repeat++) {
      await _tap(tester, find.text('选择并预览'));
      await tester.enterText(
        find.widgetWithText(TextField, '同步包完整路径'),
        bundles.single.path,
      );
      await _tap(tester, find.text('读取并验证'));
      await _wait(tester, find.text('确认完整同步'));
      await _tap(tester, find.text('备份并提交'));
      await _wait(tester, find.textContaining('完整同步已一次提交'));
      final synced = (await current.list('quotation')).records.single;
      expect(synced.id, restored.id);
      expect(synced.heads, restored.heads);
      expect(synced.payload, restored.payload);
      expect((await current.list('supplier')).records, hasLength(1));
      expect((await current.list('product')).records, hasLength(1));
    }
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.manage_search));
    await _wait(tester, find.text('不锈钢紧固件'));
    expect(tester.takeException(), isNull);
    return current;
  } catch (_) {
    // The shell owns the replacement after restore; the shared runner still
    // holds the original until this callback returns, so close it on failure.
    if (!identical(current, original)) {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      await current.close();
    }
    rethrow;
  }
}

Future<void> _visible(WidgetTester tester, Finder finder) async {
  if (finder.evaluate().isEmpty) {
    await tester.scrollUntilVisible(finder, 180);
  } else {
    await tester.ensureVisible(finder);
  }
  await tester.pump(const Duration(milliseconds: 100));
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await _visible(tester, finder);
  await tester.tap(finder);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
}

Future<void> _wait(WidgetTester tester, Finder finder) async {
  for (var attempt = 0; attempt < 400; attempt++) {
    await tester.pump(const Duration(milliseconds: 50));
    if (finder.evaluate().isNotEmpty) {
      await tester.pump(const Duration(milliseconds: 100));
      return;
    }
  }
  fail('Android workflow did not reach $finder within 20 seconds.');
}
