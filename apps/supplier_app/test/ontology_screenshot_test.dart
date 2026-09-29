// Local review renders. These use explicitly named review fonts, not aliases
// pretending to be production PingFang / Segoe / Microsoft YaHei.
@Tags(['screenshot'])
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supplier_app/app/app_state.dart';
import 'package:supplier_app/app/theme.dart';
import 'package:supplier_app/features/data_center/data_center_page.dart';
import 'package:supplier_core/supplier_core.dart';

void main() {
  const font = '/System/Library/Fonts/STHeiti Light.ttc';
  final available = File(font).existsSync();
  setUpAll(() async {
    if (!available) return;
    final loader = FontLoader('OntologyReviewSans')
      ..addFont(
        Future.value(ByteData.sublistView(File(font).readAsBytesSync())),
      );
    await loader.load();
  });

  for (final (name, size, dark, tab) in [
    ('light', const Size(1600, 1000), false, '数据模型'),
    ('dark', const Size(1600, 1000), true, '数据模型'),
    ('compact', const Size(900, 900), false, '数据模型'),
    ('quality', const Size(1600, 1000), false, '数据质量'),
    ('ai-mobile', const Size(390, 844), true, 'AI 接入'),
  ]) {
    testWidgets('ontology review $name', (tester) async {
      final dir = Directory.systemTemp.createTempSync('ontology_review');
      final store = Store.open('${dir.path}/test.db', device: '示例');
      final state = AppState.test(store, dir);
      addTearDown(() {
        store.close();
        dir.deleteSync(recursive: true);
        Tokens.dark = false;
      });
      store.save('supplier', {
        for (final field in Supplier.fields) field: null,
        'name': '示例供应商',
        'aliases': <String>[],
        'categories': <String>[],
      });
      for (final (name, category) in [
        ('离心水泵', '水泵'),
        ('控制柜', '控制柜'),
        ('动力电缆', '电缆'),
      ]) {
        store.save('product', {
          for (final field in Product.fields) field: null,
          'name': name,
          'unit': '件',
          'category': category,
        });
      }
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      Tokens.dark = dark;
      final base = buildTheme();
      await tester.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: base.copyWith(
            textTheme: base.textTheme.apply(fontFamily: 'OntologyReviewSans'),
          ),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: true),
            child: child!,
          ),
          home: Scaffold(body: DataCenterPage(state: state)),
        ),
      );
      await tester.pumpAndSettle();
      if (tab != '数据模型') {
        await tester.tap(find.text(tab));
        await tester.pumpAndSettle();
      }
      expect(tester.takeException(), isNull);
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('../../../docs/design/ontology-$name.png'),
      );
    }, skip: !available);
  }
}
