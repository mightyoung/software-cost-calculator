import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supplier_app/app/app_state.dart';
import 'package:supplier_app/app/theme.dart';
import 'package:supplier_app/features/ai/material_import_page.dart';
import 'package:supplier_app/features/spec/spec_import.dart';
import 'package:supplier_core/supplier_core.dart';

void main() {
  final oversized =
      '名称\t技术参数\t品牌\n泵\t${'x' * 32767}\t甲\n'
      '\t${'x' * 32767}\t\n\tmore\t';

  testWidgets('material paste reports text limit without applying records', (
    tester,
  ) async {
    final dir = Directory.systemTemp.createTempSync('material_text_limit');
    addTearDown(() => dir.deleteSync(recursive: true));
    final store = Store.open('${dir.path}/m.db', device: '测试机');
    addTearDown(store.close);
    tester.view.physicalSize = const Size(1280, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: MaterialImportPage(state: AppState.test(store, dir)),
      ),
    );
    await tester.enterText(find.byType(TextField), oversized);
    await tester.tap(find.text('开始分析'));
    await tester.pumpAndSettle();
    expect(find.textContaining('合并行文本过长'), findsOneWidget);
    expect(store.productRows(), isEmpty);
    expect(tester.takeException(), isNull);

    await tester.enterText(
      find.byType(TextField),
      '设备名称\t品牌\t型号\t单位\t单价\n网关\t巨控\tNET422-CS\t个\t3190\n',
    );
    await tester.tap(find.text('开始分析'));
    await tester.pumpAndSettle();
    expect(find.textContaining('合并行文本过长'), findsNothing);
    expect(find.textContaining('新建供应商：巨控'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('requirement paste clears drafts after a rejected table', (
    tester,
  ) async {
    final dir = Directory.systemTemp.createTempSync('spec_text_limit');
    addTearDown(() => dir.deleteSync(recursive: true));
    final store = Store.open('${dir.path}/m.db', device: '测试机');
    addTearDown(store.close);
    tester.view.physicalSize = const Size(1280, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final state = AppState.test(store, dir);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showSpecImport(context, state),
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    final field = find.widgetWithText(TextField, '或粘贴文字');
    await tester.enterText(field, '名称\t技术参数\n泵\t流量10');
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '导入并核对'))
          .onPressed,
      isNotNull,
    );
    await tester.enterText(field, oversized);
    await tester.pumpAndSettle();
    expect(find.textContaining('合并行文本过长'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '导入并核对'))
          .onPressed,
      isNull,
    );
    expect(tester.takeException(), isNull);
  });
}
