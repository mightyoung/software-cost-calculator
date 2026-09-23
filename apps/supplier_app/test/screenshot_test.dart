// Local visual check: renders key screens with a real CJK font into
// test/screens/*.png. Skipped where the macOS system font is unavailable.
//   flutter test test/screenshot_test.dart --update-goldens
@Tags(['screenshot'])
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supplier_app/app/app_state.dart';
import 'package:supplier_app/app/shell.dart';
import 'package:supplier_app/app/theme.dart';
import 'package:supplier_core/supplier_core.dart';

const _font = '/System/Library/Fonts/Supplemental/Arial Unicode.ttf';

Map<String, Object?> _b(List<String> f, Map<String, Object?> v) => {
  for (final k in f) k: null,
  ...v,
};

void _seed(Store s) {
  final today = DateTime.now().toIso8601String().substring(0, 10);
  String sup(String n) => s.save(
    'supplier',
    _b(Supplier.fields, {
      'name': n,
      'aliases': <String>[],
      'categories': <String>[],
    }),
  );
  String prod(String n, String unit, String model, [String? spec]) => s.save(
    'product',
    _b(Product.fields, {
      'name': n,
      'unit': unit,
      'model': model,
      'specification': spec,
    }),
  );
  final p = s.save(
    'project',
    _b(Project.fields, {
      'code': '2026-WH01-015',
      'name': '泵房改造工程',
      'status': 'active',
      'type': 'market',
      'level': 'A',
      'customer': '华东水务',
      'leader': '王工',
      'contract_no': 'HD-2026-0412',
      'contract_amount': '205000',
      'currency': 'CNY',
      'tax_mode': 'included',
      'markup_rate': '15',
    }),
  );
  s.save(
    'project',
    _b(Project.fields, {
      'code': '2026-WH01-014',
      'name': '二期配电柜更换',
      'status': 'active',
      'customer': '江南化工',
      'currency': 'CNY',
      'tax_mode': 'included',
      'markup_rate': '10',
    }),
  );
  String quote(
    String supplier,
    String product,
    String price, {
    String? until,
    String? quoted,
  }) => s.save(
    'quotation',
    _b(Quotation.fields, {
      'supplier_id': supplier,
      'product_id': product,
      'project_id': p,
      'price': price,
      'currency': 'CNY',
      'tax_mode': 'included',
      'unit_snapshot': s.get('product', product)!.data['unit'],
      'min_qty': '1',
      'quoted_on': quoted ?? today,
      'valid_until': until,
      'inquirer_name': '王工',
      'inquiry_precision': 'date',
      'inquiry_date': today,
      'capture_mode': 'standard',
    }),
  );
  void line(Map<String, Object?> v) => s.save(
    'project_item',
    _b(ProjectItem.fields, {'project_id': p, 'qty': '1', ...v}),
  );
  final pump = prod('不锈钢离心泵', '台', 'IS80-65-160', '304');
  final cab = prod('变频控制柜', '面', '15kW 一拖二');
  final valve = prod('闸阀', '个', 'Z41H-16C DN100');
  final cable = prod('动力电缆', '米', 'YJV-4×25');
  final q1 = quote(sup('甲泵业'), pump, '32500');
  quote(sup('乙机电'), pump, '29800');
  final q2 = quote(sup('申江电气'), cab, '48600');
  final q3 = quote(sup('永泰阀门'), valve, '1205');
  final q4 = quote(
    sup('宝胜电缆'),
    cable,
    '135',
    quoted: '2026-01-05',
    until: '2026-01-31',
  );
  line({
    'category': 'material',
    'product_id': pump,
    'quotation_id': q1,
    'qty': '2',
    'unit': '台',
    'unit_cost': '32500',
  });
  line({
    'category': 'material',
    'product_id': cab,
    'quotation_id': q2,
    'unit': '面',
    'unit_cost': '48600',
  });
  line({
    'category': 'material',
    'product_id': valve,
    'quotation_id': q3,
    'qty': '4',
    'unit': '个',
    'unit_cost': '1205',
  });
  line({
    'category': 'material',
    'name': '电磁流量计',
    'unit': '台',
    'unit_cost': '0',
    'notes': '要求：DN100，远传 4–20mA',
  });
  line({
    'category': 'material',
    'product_id': cable,
    'quotation_id': q4,
    'qty': '300',
    'unit': '米',
    'unit_cost': '135',
  });
  line({
    'category': 'labor',
    'name': '设备安装调试',
    'unit': '项',
    'unit_cost': '18000',
  });
  line({
    'category': 'labor',
    'name': '电缆敷设',
    'qty': '300',
    'unit': '米',
    'unit_cost': '13',
  });
  line({
    'category': 'other',
    'name': '运输及吊装',
    'unit': '项',
    'unit_cost': '6000',
  });
}

void main() {
  final hasFont = File(_font).existsSync();

  setUpAll(() async {
    if (!hasFont) return;
    final bytes = File(_font).readAsBytesSync();
    for (final family in ['Roboto', ...fontFallback, 'monospace']) {
      final loader = FontLoader(family)
        ..addFont(Future.value(ByteData.sublistView(bytes)));
      await loader.load();
    }
    final icons = File(
      '${Platform.environment['FLUTTER_ROOT']}/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
    );
    if (icons.existsSync()) {
      final loader = FontLoader('MaterialIcons')
        ..addFont(Future.value(ByteData.sublistView(icons.readAsBytesSync())));
      await loader.load();
    }
  });

  Future<void> shoot(
    WidgetTester tester,
    Size size,
    String name, [
    Future<void> Function()? act,
  ]) async {
    final dir = Directory.systemTemp.createTempSync('shot');
    final store = Store.open('${dir.path}/s.db', device: '采购部-01');
    _seed(store);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildTheme(),
        home: Shell(state: AppState.test(store, dir)),
      ),
    );
    await tester.pumpAndSettle();
    if (act != null) await act();
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('screens/$name.png'),
    );
    store.close();
  }

  testWidgets(
    'desktop project budget',
    (t) => shoot(t, const Size(1280, 800), 'desktop_budget', () async {
      await t.tap(find.text('泵房改造工程'));
      await t.pumpAndSettle();
    }),
    skip: !hasFont,
  );

  testWidgets(
    'desktop add material panel',
    (t) => shoot(t, const Size(1280, 800), 'desktop_add', () async {
      await t.tap(find.text('泵房改造工程'));
      await t.pumpAndSettle();
      await t.tap(find.text('添加物料').first);
      await t.pumpAndSettle();
    }),
    skip: !hasFont,
  );

  testWidgets(
    'phone project list',
    (t) => shoot(t, const Size(390, 844), 'phone_projects'),
    skip: !hasFont,
  );

  testWidgets(
    'phone project budget',
    (t) => shoot(t, const Size(390, 844), 'phone_budget', () async {
      await t.tap(find.text('泵房改造工程'));
      await t.pumpAndSettle();
    }),
    skip: !hasFont,
  );
}
