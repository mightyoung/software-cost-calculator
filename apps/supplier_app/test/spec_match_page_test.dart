import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supplier_app/app/app_state.dart';
import 'package:supplier_app/app/theme.dart';
import 'package:supplier_app/features/spec/spec_match_page.dart';
import 'package:supplier_core/supplier_core.dart';

/// Three temperature/humidity sensors with typed parameters.
void seedSensors(Store s) {
  void sensor(String name, String model, Map<String, String> params) {
    final id = s.save('product', {
      for (final f in Product.fields) f: null,
      'name': name,
      'unit': '个',
      'model': model,
      'spec_class': 'sensor.th',
    });
    for (final e in params.entries) {
      final p = specProperty(e.key)!;
      s.setParam(
        id,
        e.key,
        normalizeParamValue(p, parseParamText(p, e.value)!),
      );
    }
  }

  sensor('温湿度变送器', 'YAWS-200', {
    'th.temp_range': '-40~85℃',
    'th.temp_accuracy': '±0.2℃',
    'io.output': 'RS485',
    'prot.ip': 'IP66',
    'prot.ex': 'Ex db IIC T6 Gb',
  });
  sensor('防爆温湿度传感器', 'RS-WS-EX', {
    'th.temp_range': '-40~80℃',
    'io.output': '4-20mA',
    'prot.ip': 'IP67',
    'prot.ex': 'Ex ia IIC T4 Ga',
  });
  sensor('温湿度探头', 'TH-10', {
    'th.temp_range': '-10~60℃',
    'th.temp_accuracy': '±0.5℃',
    'io.output': 'RS485',
    'prot.ip': 'IP65',
  });
}

void main() {
  testWidgets(
    'conditions typed as usual list matching materials clause by clause',
    (tester) async {
      final dir = Directory.systemTemp.createTempSync('spec_match');
      addTearDown(() => dir.deleteSync(recursive: true));
      final s = Store.open('${dir.path}/m.db', device: '测试机');
      addTearDown(s.close);
      seedSensors(s);
      tester.view.physicalSize = const Size(1400, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(),
          home: SpecMatchPage(state: AppState.test(s, dir)),
        ),
      );
      await tester.tap(find.byType(DropdownButtonFormField<String?>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('温湿度传感器').last);
      await tester.pumpAndSettle();
      final values = find.widgetWithText(TextField, '要求值');
      expect(values, findsNWidgets(5), reason: 'key parameters prefilled');
      await tester.enterText(values.at(0), '-20~80℃');
      await tester.enterText(values.at(2), '±0.3℃');
      await tester.pumpAndSettle();
      expect(find.text('完全满足 1 · 基本满足 1 · 不满足 1'), findsOneWidget);
      expect(find.textContaining('全部按必须满足处理'), findsOneWidget);
      expect(find.text('显示不满足的 1 个物料'), findsOneWidget);
      // A value that cannot be read is named and left out.
      await tester.enterText(values.at(1), '很湿');
      await tester.pumpAndSettle();
      expect(find.textContaining('无法识别'), findsOneWidget);
      expect(find.text('完全满足 1 · 基本满足 1 · 不满足 1'), findsOneWidget);
    },
  );
}
