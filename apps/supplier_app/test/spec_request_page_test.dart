import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supplier_app/app/app_state.dart';
import 'package:supplier_app/app/theme.dart';
import 'package:supplier_app/features/spec/spec_import.dart';
import 'package:supplier_core/supplier_core.dart';

import 'spec_match_page_test.dart' show seedSensors;

void main() {
  testWidgets('paste a requirement, review, match, choose and answer', (
    tester,
  ) async {
    final dir = Directory.systemTemp.createTempSync('spec_request');
    addTearDown(() => dir.deleteSync(recursive: true));
    final s = Store.open('${dir.path}/r.db', device: '测试机');
    addTearDown(s.close);
    seedSensors(s);
    final state = AppState.test(s, dir);
    tester.view.physicalSize = const Size(1500, 2600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showSpecImport(context, state),
              child: const Text('开始'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('开始'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, '或粘贴文字'),
      '温湿度传感器\n（1）测量范围，温度-20℃~+80℃\n（2）防护等级不低于IP65\n（3）与采集器适配',
    );
    await tester.pump();
    expect(find.textContaining('识别出 1 项设备、3 条条款'), findsOneWidget);
    expect(find.textContaining('1 条为文字条款'), findsOneWidget);
    await tester.tap(find.text('导入并核对'));
    await tester.pumpAndSettle();

    // ② review
    expect(find.text('1. 温湿度传感器'), findsWidgets);
    expect(find.text('3 条待核对'), findsOneWidget);
    expect(find.text('温度测量范围 覆盖 -20～80 ℃'), findsWidgets);
    expect(find.text('文字条款，需人工判断'), findsOneWidget);
    await tester.tap(find.text('全部确认'));
    await tester.pumpAndSettle();
    expect(find.text('全部已核对'), findsOneWidget);

    // ③ match: TH-10 cannot cover -20 ℃; IP67 does not prove jets (IP65).
    expect(find.text('完全满足 1 · 基本满足 0 · 不满足 2'), findsOneWidget);

    // ④ choose the first candidate, then answer the text clause.
    await tester.tap(find.widgetWithText(OutlinedButton, '定选').first);
    await tester.pumpAndSettle();
    expect(find.text('已定选'), findsWidgets);
    final item = s.specItemsOf(s.specRequests().single.id).single;
    expect(snapshotRows(item)![0]['outcome'], 'better');
    await tester.enterText(
      find.widgetWithText(TextField, '响应（写具体内容，不写"满足"）'),
      'RS485 输出，与采集器适配',
    );
    await tester.tap(find.text('保存响应'));
    await tester.pumpAndSettle();
    final rows = snapshotRows(s.get('spec_item', item.id)!)!;
    expect(rows[2]['response'], 'RS485 输出，与采集器适配');

    // Editing a clause after the choice re-judges the chosen material.
    await tester.tap(find.widgetWithText(InputChip, '防护等级 不低于 IP65'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, '要求值'), 'IP68');
    await tester.pumpAndSettle();
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    final after = snapshotRows(s.get('spec_item', item.id)!)!;
    expect(after[1]['outcome'], 'worse');
    expect(after[2]['response'], 'RS485 输出，与采集器适配');
  });
}
