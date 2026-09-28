import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supplier_app/app/app_state.dart';
import 'package:supplier_app/app/theme.dart';
import 'package:supplier_app/features/ai/material_import_page.dart';
import 'package:supplier_app/features/ai/material_review.dart';
import 'package:supplier_core/supplier_core.dart';

void main() {
  for (final sample in [
    (source: '单价31800元', value: '3180', highlight: null),
    (source: '单价3,200元', value: '3200', highlight: '3,200'),
    (source: '单价3,200.00元', value: '3200', highlight: '3,200.00'),
    (source: '原价31800元，现价3180元', value: '3180', highlight: '3180'),
    (source: '单价3201元', value: '3200', highlight: null),
    (source: '单价3180.5元', value: '3180', highlight: null),
    (source: '单价3,20元', value: '320', highlight: null),
    (source: '型号IS3200，单价32000元', value: '3200', highlight: null),
  ]) {
    testWidgets('numeric source lookup: ${sample.source}', (tester) async {
      final dir = Directory.systemTemp.createTempSync('material_numeric');
      addTearDown(() => dir.deleteSync(recursive: true));
      final store = Store.open('${dir.path}/m.db', device: '测试机');
      addTearDown(store.close);
      tester.view.physicalSize = const Size(1280, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(),
          home: Scaffold(
            body: MaterialReview(
              state: AppState.test(store, dir),
              plans: [
                store.planOffer(
                  cleanOffer({
                    'supplier': '甲泵业',
                    'name': '泵',
                    'unit': '台',
                    'price': sample.value,
                  }),
                ),
              ],
              onBack: () {},
              source: (name: '报价.txt', bytes: utf8.encode(sample.source)),
            ),
          ),
        ),
      );
      await tester.tap(find.text('核对字段原文'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('查看单价的原文'));
      await tester.pumpAndSettle();
      final rendered = tester.widget<SelectableText>(
        find.byType(SelectableText),
      );
      if (sample.highlight == null) {
        expect(find.textContaining('未找到完全相同的原文'), findsOneWidget);
        expect(rendered.data, sample.source);
      } else {
        expect(
          rendered.textSpan!.toPlainText(),
          sample.source,
          reason:
              'numeric normalization must preserve original characters and offsets',
        );
        expect(
          rendered.textSpan!.children!
              .whereType<TextSpan>()
              .singleWhere(
                (span) => span.style?.backgroundColor == Tokens.amberBg,
              )
              .text,
          sample.highlight,
        );
      }
      expect(tester.takeException(), isNull);
    });
  }
  for (final readable in [true, false]) {
    testWidgets('source attachment preview: readable=$readable', (
      tester,
    ) async {
      final dir = Directory.systemTemp.createTempSync('material_attachment');
      addTearDown(() => dir.deleteSync(recursive: true));
      final store = Store.open('${dir.path}/m.db', device: '测试机');
      addTearDown(store.close);
      tester.view.physicalSize = const Size(1280, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(),
          home: Scaffold(
            body: MaterialReview(
              state: AppState.test(store, dir),
              plans: [
                store.planOffer(
                  cleanOffer({'supplier': '甲泵业', 'name': '离心泵', 'unit': '台'}),
                ),
              ],
              onBack: () {},
              source: (
                name: '报价.xlsx',
                bytes: readable
                    ? writeXlsx([
                        SheetData('报价', [
                          ['甲泵业', '离心泵', '台'],
                        ]),
                      ])
                    : [0, 1, 2],
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('核对字段原文'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('查看产品名称的原文'));
      await tester.pumpAndSettle();
      if (readable) {
        final rendered = tester.widget<SelectableText>(
          find.byType(SelectableText),
        );
        expect(rendered.textSpan!.toPlainText(), contains('甲泵业 | 离心泵 | 台'));
        expect(
          rendered.textSpan!.children!
              .whereType<TextSpan>()
              .singleWhere(
                (span) => span.style?.backgroundColor == Tokens.amberBg,
              )
              .text,
          '离心泵',
        );
      } else {
        expect(find.textContaining('无法显示这份附件的原文'), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'field source lookup highlights exact text and explains missing matches',
    (tester) async {
      final dir = Directory.systemTemp.createTempSync('material_source');
      addTearDown(() => dir.deleteSync(recursive: true));
      final store = Store.open('${dir.path}/m.db', device: '测试机');
      addTearDown(store.close);
      const original = '甲泵业：离心泵，单位台，含税价 3,200 元。';
      final offer = cleanOffer({
        'supplier': '甲泵业',
        'name': '离心泵',
        'unit': '台',
        'price': '3201',
        'tax_mode': 'included',
      });
      tester.view.physicalSize = const Size(1280, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(),
          home: Scaffold(
            body: MaterialReview(
              state: AppState.test(store, dir),
              plans: [store.planOffer(offer, source: original)],
              onBack: () {},
              source: (name: '报价.txt', bytes: utf8.encode(original)),
            ),
          ),
        ),
      );
      await tester.tap(find.text('核对字段原文'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('查看产品名称的原文'));
      await tester.pumpAndSettle();
      final rendered = tester.widget<SelectableText>(
        find.byType(SelectableText),
      );
      expect(rendered.textSpan!.toPlainText(), original);
      final highlight = rendered.textSpan!.children!
          .whereType<TextSpan>()
          .singleWhere((span) => span.style?.backgroundColor == Tokens.amberBg);
      expect(highlight.text, '离心泵');
      expect(find.text('报价.txt'), findsOneWidget);
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('查看单价的原文'));
      await tester.pumpAndSettle();
      expect(find.textContaining('未找到完全相同的原文'), findsOneWidget);
      expect(find.text(original), findsOneWidget);
      expect(
        store.listQuotations(),
        isEmpty,
        reason: 'source inspection never imports',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('smart import review: blocked rows, inquirer, import', (
    tester,
  ) async {
    final dir = Directory.systemTemp.createTempSync('material_review');
    addTearDown(() => dir.deleteSync(recursive: true));
    final store = Store.open('${dir.path}/m.db', device: '测试机');
    addTearDown(store.close);
    final state = AppState.test(store, dir);
    final known = store.save('supplier', {
      for (final f in Supplier.fields) f: null,
      'name': '甲泵业',
      'aliases': <String>[],
      'categories': <String>[],
    });
    final project = store.save('project', {
      for (final f in Project.fields) f: null,
      'code': 'P1',
      'name': '泵房',
      'status': 'active',
      'currency': 'CNY',
      'tax_mode': 'included',
      'markup_rate': '0',
    });
    final plans = [
      for (final raw in [
        {
          'supplier': '甲泵业',
          'phone': '13800000000',
          'name': '离心泵',
          'model': 'IS80',
          'unit': '台',
          'price': '3200',
          'tax_mode': 'included',
        },
        {'supplier': '丙公司', 'name': '配件'},
      ])
        store.planOffer(cleanOffer(raw)),
    ];
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: Scaffold(
          body: MaterialReview(state: state, plans: plans, onBack: () {}),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('缺少单位'), findsOneWidget);
    expect(find.text('已有：甲泵业'), findsOneWidget, reason: 'matched supplier');

    await tester.tap(find.text('确认导入（1 条）'));
    await tester.pump();
    expect(find.text('填写询价人'), findsOneWidget);
    expect(store.listQuotations(), isEmpty);

    await tester.enterText(find.widgetWithText(TextField, '询价人'), '王五');
    await tester.tap(find.text('确认导入（1 条）'));
    await tester.pumpAndSettle();
    final quotes = store.listQuotations(projectId: project);
    expect(quotes, hasLength(1));
    expect(quotes.single.data['supplier_id'], known);
    expect(quotes.single.data['price'], '3200');
    expect(store.budget(project).lines, hasLength(1));
    expect(state.setting('inquirer'), '王五');
  });

  testWidgets('an Excel table opens at review and creates what is missing', (
    tester,
  ) async {
    final dir = Directory.systemTemp.createTempSync('material_table');
    addTearDown(() => dir.deleteSync(recursive: true));
    final store = Store.open('${dir.path}/m.db', device: '测试机');
    addTearDown(store.close);
    final state = AppState.test(store, dir);
    final project = store.save('project', {
      for (final f in Project.fields) f: null,
      'code': 'P1',
      'name': '监控',
      'status': 'active',
      'currency': 'CNY',
      'tax_mode': 'included',
      'markup_rate': '0',
    });
    final bytes = writeXlsx([
      SheetData('Sheet1', [
        ['设备名称', '品牌', '型号', '单位', '数量', '单价'],
        ['网关', '巨控', 'NET422-CS', '个', Num('4'), Num('3190')],
        ['工控机', null, null, '台', Num('5'), Num('15000')],
      ]),
    ]);
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: MaterialImportPage(
          state: state,
          projectId: project,
          table: (
            name: '选型.xlsx',
            bytes: bytes,
            offers: offersFromWorkbook(readXlsx(bytes))!,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('没有供应商，只登记物料'), findsOneWidget);
    expect(find.textContaining('新建供应商：巨控'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextField, '询价人'), '王五');
    await tester.tap(find.text('确认导入（2 条）'));
    await tester.pumpAndSettle();
    expect(store.listQuotations(projectId: project), hasLength(1));
    expect(store.searchByName('supplier', '巨控'), hasLength(1));
    expect(store.searchByName('product', '工控机'), hasLength(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('rows pasted from Excel go to review without an AI key', (
    tester,
  ) async {
    final dir = Directory.systemTemp.createTempSync('material_paste');
    addTearDown(() => dir.deleteSync(recursive: true));
    final store = Store.open('${dir.path}/m.db', device: '测试机');
    addTearDown(store.close);
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: MaterialImportPage(state: AppState.test(store, dir)),
      ),
    );
    await tester.enterText(
      find.byType(TextField),
      '设备名称\t品牌\t型号\t单位\t单价\n网关\t巨控\tNET422-CS\t个\t3190\n',
    );
    await tester.tap(find.text('开始分析'));
    await tester.pumpAndSettle();
    expect(find.textContaining('新建供应商：巨控'), findsOneWidget);
    expect(find.textContaining('还没有配置 AI 服务'), findsNothing);
  });
}
