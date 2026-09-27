import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supplier_app/app/app_state.dart';
import 'package:supplier_app/features/exchange/import_flow.dart';
import 'package:supplier_core/supplier_core.dart';

Map<String, Object?> _supplier(String name) => {
  for (final field in Supplier.fields) field: null,
  'name': name,
  'aliases': <String>[],
  'categories': <String>[],
};

Future<void> _pendingWrite(Store store) async {
  await Future<void>.delayed(const Duration(milliseconds: 300));
  store.save('supplier', _supplier('恢复前在途记录'));
}

void main() {
  testWidgets(
    'full restore requires two confirmations and saves current data',
    (tester) async {
      final dir = Directory.systemTemp.createTempSync('restore_flow');
      addTearDown(() => dir.deleteSync(recursive: true));
      final source = Store.open('${dir.path}/source.db', device: '来源');
      final sourceId = source.save('supplier', _supplier('旧供应商'));
      final snapshot = '${dir.path}/snapshot.siq';
      source.exportTo(snapshot);
      source.close();

      final state = AppState.test(
        Store.open('${dir.path}/current.db', device: '本机'),
        dir,
      );
      addTearDown(state.store.close);
      final currentId = state.store.save('supplier', _supplier('新供应商'));
      state.saveSetting('sync_dir', '${dir.path}/shared');
      ({bool done, String? message})? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () async {
                  result = await reviewAndRestore(context, state, snapshot);
                },
                child: const Text('开始恢复'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('开始恢复'));
      for (var i = 0; i < 40 && find.text('整库恢复预览').evaluate().isEmpty; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pump();
      }
      expect(find.text('整库恢复预览'), findsOneWidget);
      expect(find.text('供应商：1'), findsOneWidget);
      expect(state.store.get('supplier', currentId), isNotNull);
      await tester.tap(find.text('继续'));
      await tester.pumpAndSettle();
      expect(find.text('确认替换整个资料库？'), findsOneWidget);
      expect(state.store.get('supplier', currentId), isNotNull);
      final pending = state.writeInBackground(_pendingWrite);
      await tester.tap(find.text('确认整库恢复'));
      await tester.pump();
      expect(find.text('正在恢复资料库'), findsOneWidget);
      for (var i = 0; i < 80 && result == null; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pump();
      }
      expect(
        result?.done,
        isTrue,
        reason:
            'progress=${find.text('正在恢复资料库').evaluate().length}, '
            'restored=${state.store.get('supplier', sourceId) != null}, '
            'backup=${Directory(state.backupDir).existsSync()}',
      );
      expect(result?.message, contains('整库恢复完成'));
      expect(await pending, isNull);
      expect(state.store.get('supplier', sourceId), isNotNull);
      expect(state.store.get('supplier', currentId), isNull);
      expect(state.syncDir, isNull);
      final backups = Directory(state.backupDir)
          .listSync()
          .whereType<File>()
          .where((file) => file.path.endsWith('.siq'))
          .toList();
      expect(backups, hasLength(1));
      final undo = Store.open(backups.single.path, device: '检查');
      expect(undo.get('supplier', currentId), isNotNull);
      expect(
        undo.db.select('SELECT count(*) AS n FROM supplier').first['n'],
        2,
      );
      undo.close();
    },
  );
}
