import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supplier_app/app/app_state.dart';
import 'package:supplier_app/app/shell.dart';
import 'package:supplier_app/app/theme.dart';
import 'package:supplier_app/widgets/data_grid.dart';
import 'package:supplier_core/supplier_core.dart';

void main() {
  testWidgets('table rows open with keyboard; checkbox only selects', (
    t,
  ) async {
    String? opened;
    await t.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: Scaffold(
          body: DataGrid<String>(
            rows: const ['泵', '阀'],
            columns: [GridColumn('物料', value: (row) => row)],
            id: (row) => row,
            onOpen: (row) => opened = row,
            bulkActions: (rows, clear) => [Text('选中 ${rows.length}')],
          ),
        ),
      ),
    );
    await t.tap(find.byType(Checkbox).at(1));
    await t.pump();
    expect(opened, isNull);
    expect(find.text('选中 1'), findsOneWidget);
    final row = find.ancestor(
      of: find.text('阀'),
      matching: find.byType(InkWell),
    );
    Focus.of(t.element(find.text('阀'))).requestFocus();
    await t.pump();
    expect(row, findsOneWidget);
    await t.sendKeyEvent(LogicalKeyboardKey.enter);
    await t.pump();
    expect(opened, '阀');
  });

  for (final size in [const Size(1100, 420), const Size(390, 600)]) {
    testWidgets('navigation stays usable at $size with enlarged text', (
      t,
    ) async {
      final dir = Directory.systemTemp.createTempSync('ui_workspace');
      final state = AppState.test(
        Store.open('${dir.path}/test.db', device: '测试'),
        dir,
      );
      addTearDown(() {
        state.store.close();
        dir.deleteSync(recursive: true);
      });
      t.view.physicalSize = size;
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await t.pumpWidget(
        MaterialApp(
          theme: buildTheme(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(1.3)),
            child: child!,
          ),
          home: Shell(state: state),
        ),
      );
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      if (size.width < 720) {
        await t.tap(find.text('更多'));
        await t.pumpAndSettle();
        await t.ensureVisible(find.text('设置'));
        await t.tap(find.text('设置'));
      } else {
        await t.tap(find.text('设置'));
      }
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      expect(find.text('外观'), findsWidgets);
    });
  }
}
