import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supplier_app/app/app_state.dart';
import 'package:supplier_app/app/motion.dart';
import 'package:supplier_app/app/theme.dart';
import 'package:supplier_app/features/catalog/catalog_form.dart';
import 'package:supplier_app/features/hub/hub_page.dart';
import 'package:supplier_app/widgets/ledger.dart';
import 'package:supplier_core/supplier_core.dart';

void main() {
  late Directory dir;
  late Store store;
  late AppState state;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('ui_conformance');
    store = Store.open('${dir.path}/test.db', device: 'test');
    state = AppState.test(store, dir);
  });
  tearDown(() {
    store.close();
    dir.deleteSync(recursive: true);
  });

  Widget app(Widget child, {double scale = 1}) => MaterialApp(
    theme: buildTheme(),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: TextScaler.linear(scale), disableAnimations: true),
      child: child!,
    ),
    home: Scaffold(body: child),
  );

  for (final scenario in [
    (390.0, 1.4, true),
    (900.0, 1.4, true),
    (900.0, 1.0, false),
  ]) {
    testWidgets(
      'catalog field pairs reflow at ${scenario.$1} / ${scenario.$2}',
      (tester) async {
        tester.view.physicalSize = Size(scenario.$1, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          app(
            Builder(
              builder: (context) => TextButton(
                onPressed: () => showCatalogForm(context, state, 'supplier'),
                child: const Text('新建'),
              ),
            ),
            scale: scenario.$2,
          ),
        );
        await tester.tap(find.text('新建'));
        await tester.pumpAndSettle();
        final aliases = tester.getTopLeft(find.widgetWithText(TextField, '别名'));
        final categories = tester.getTopLeft(
          find.widgetWithText(TextField, '主营类别'),
        );
        if (scenario.$3) {
          expect(categories.dy, greaterThan(aliases.dy));
          expect(categories.dx, aliases.dx);
        } else {
          expect(categories.dy, aliases.dy);
          expect(categories.dx, greaterThan(aliases.dx));
        }
        await tester.enterText(
          find.widgetWithText(TextField, '供应商名称'),
          '布局验证供应商',
        );
        await tester.ensureVisible(find.text('保存'));
        await tester.tap(find.text('保存'));
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsNothing);
        expect(store.similarSuppliers('布局验证供应商'), hasLength(1));
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets('material unit conversion reflows and remains editable', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      app(
        Builder(
          builder: (context) => TextButton(
            onPressed: () => showCatalogForm(context, state, 'product'),
            child: const Text('新建'),
          ),
        ),
        scale: 1.4,
      ),
    );
    await tester.tap(find.text('新建'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('添加单位'));
    await tester.tap(find.text('添加单位'));
    await tester.pumpAndSettle();
    final unit = find.widgetWithText(TextField, '报价单位');
    final factor = find.widgetWithText(TextField, '等于多少基准单位');
    await tester.ensureVisible(factor);
    expect(
      tester.getTopLeft(factor).dy,
      greaterThan(tester.getTopLeft(unit).dy),
    );
    await tester.enterText(unit, '箱');
    await tester.enterText(factor, '10');
    await tester.ensureVisible(find.byTooltip('删除单位换算'));
    await tester.tap(find.byTooltip('删除单位换算'));
    await tester.pumpAndSettle();
    expect(unit, findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('load more wraps and remains actionable with large text', (
    tester,
  ) async {
    var more = 0;
    await tester.pumpWidget(
      app(
        Center(
          child: SizedBox(
            width: 260,
            child: MoreRow(shown: 123456, onMore: () => more++),
          ),
        ),
        scale: 2,
      ),
    );
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('再显示 200 条'));
    expect(more, 1);
  });

  testWidgets(
    'hub detail offers retry and uses static reduced-motion progress',
    (tester) async {
      await tester.pumpWidget(
        app(
          HubDetail(
            state: state,
            row: HubSummary.fromJson({
              'origin': 'test',
              'publication_id': 'test',
              'revision': 1,
              'kind': 'supplier',
              'title': '供应商',
              'root_id': 'test',
            }),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('还没有连接公司资料中心'), findsOneWidget);
      expect(find.text('重试'), findsOneWidget);
      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();
      expect(find.text('还没有连接公司资料中心'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(app(const TaskProgress()));
      await tester.pumpAndSettle();
      expect(find.text('正在处理…'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(tester.binding.transientCallbackCount, 0);
    },
  );
}
