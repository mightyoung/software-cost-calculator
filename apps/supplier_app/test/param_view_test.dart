import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supplier_app/app/app_state.dart';
import 'package:supplier_app/app/theme.dart';
import 'package:supplier_app/features/data_center/param_migration.dart';
import 'package:supplier_app/features/spec/param_view.dart';
import 'package:supplier_core/supplier_core.dart';

import 'spec_match_page_test.dart' show seedSensors;

void main() {
  late Directory dir;
  late Store s;
  late AppState state;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('param_view');
    s = Store.open('${dir.path}/p.db', device: '测试机');
    state = AppState.test(s, dir);
  });
  tearDown(() {
    s.close();
    dir.deleteSync(recursive: true);
  });

  Future<void> open(WidgetTester tester, Widget home) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(theme: buildTheme(), home: home));
    await tester.pumpAndSettle();
  }

  testWidgets('filter like a requirement, confirm a row, edit a cell', (
    tester,
  ) async {
    seedSensors(s);
    final extra = s.save('product', {
      for (final f in Product.fields) f: null,
      'name': '新到探头',
      'unit': '个',
      'spec_class': 'sensor.th',
    });
    s.setParam(
      extra,
      'prot.ip',
      {
        'codes': ['IP54'],
      },
      confirmed: false,
      evidence: '外壳 IP54',
    );
    await open(tester, ParamViewPage(state: state));
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('温湿度传感器').last);
    await tester.pumpAndSettle();
    expect(find.text('4 / 4 个物料'), findsOneWidget);

    // IP67 does not prove jets: only IP65 and better stay.
    await tester.enterText(find.widgetWithText(TextField, '防护等级'), 'IP65');
    await tester.pumpAndSettle();
    expect(find.text('2 / 4 个物料'), findsOneWidget);
    expect(find.text('防爆温湿度传感器'), findsNothing);
    await tester.enterText(find.widgetWithText(TextField, '防护等级'), '');
    await tester.pumpAndSettle();

    await tester.tap(find.byType(FilterChip));
    await tester.pumpAndSettle();
    expect(find.text('1 / 4 个物料'), findsOneWidget);
    await tester.tap(find.text('确认本行'));
    await tester.pumpAndSettle();
    expect(s.paramsOf(extra)['prot.ip']!.data['confirmed'], isTrue);
    expect(find.text('0 / 4 个物料'), findsOneWidget);

    await tester.tap(find.byType(FilterChip));
    await tester.pumpAndSettle();
    await tester.tap(find.text('IP54'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'IP66');
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存并确认'));
    await tester.pumpAndSettle();
    expect(s.paramsOf(extra)['prot.ip']!.data['value'], {
      'codes': ['IP66'],
    });
    expect(s.paramsOf(extra)['prot.ip']!.data['evidence'], '外壳 IP54');
  });

  testWidgets('fill parameters from model codes and text after a preview', (
    tester,
  ) async {
    final cable = s.save('product', {
      for (final f in Product.fields) f: null,
      'name': '控制电缆',
      'unit': '米',
      'model': 'ZR-KVVP-4×1.5',
    });
    await open(
      tester,
      Scaffold(
        body: Builder(
          builder: (c) => TextButton(
            onPressed: () => showParamFill(c, state),
            child: const Text('开始'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('开始'));
    await tester.pumpAndSettle();
    expect(find.text('控制电缆 · 电缆（按名称识别）'), findsOneWidget);
    expect(find.textContaining('截面 1.5 mm²'), findsOneWidget);
    await tester.tap(find.text('写入'));
    await tester.pumpAndSettle();
    expect(s.get('product', cable)!.data['spec_class'], 'cable');
    final p = s.paramsOf(cable);
    expect(p['cable.csa']!.data['source'], 'decoder');
    expect(p['cable.csa']!.data['confirmed'], isFalse);
  });
}
