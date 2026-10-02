import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supplier_app/app/theme.dart';
import 'package:supplier_app/features/catalog/attributes_editor.dart';
import 'package:supplier_app/features/catalog/params_editor.dart';
import 'package:supplier_core/supplier_core.dart';

void main() {
  testWidgets('narrow material attributes keep both inputs usable', (
    tester,
  ) async {
    final name = TextEditingController(text: '流量');
    final value = TextEditingController(text: '50m³/h');
    int? removed;
    addTearDown(name.dispose);
    addTearDown(value.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 220,
              child: AttributesEditor(
                rows: [(name, value)],
                suggestions: const [],
                onAdd: (_) {},
                onRemove: (index) => removed = index,
                onChanged: () {},
              ),
            ),
          ),
        ),
      ),
    );
    expect(tester.getSize(find.byType(TextField).last).width, greaterThan(150));
    await tester.enterText(find.byType(TextField).last, '80m³/h');
    expect(value.text, '80m³/h');
    await tester.tap(find.byTooltip('删除'));
    expect(removed, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('parameter heading wraps at narrow width with large text', (
    tester,
  ) async {
    final dir = Directory.systemTemp.createTempSync('params_layout');
    final store = Store.open('${dir.path}/test.db', device: 'test');
    final product = store.save('product', {
      for (final field in Product.fields) field: null,
      'name': '控制电缆',
      'unit': '米',
      'spec_class': 'cable',
    });
    store.setParam(product, 'cable.cores', {'v': '4'}, confirmed: false);
    final draft = ParamsDraft(store, product, classCode: 'cable');
    addTearDown(() {
      draft.dispose();
      store.close();
      dir.deleteSync(recursive: true);
    });
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(1.6)),
          child: child!,
        ),
        home: Scaffold(
          body: SingleChildScrollView(
            child: Center(
              child: SizedBox(
                width: 220,
                child: ParamsEditor(
                  draft: draft,
                  suggestion: specClasses.last.code,
                  onChanged: () {},
                ),
              ),
            ),
          ),
        ),
      ),
    );
    expect(find.text('物料参数'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('全部确认'));
    expect(draft.confirmAll, isTrue);
    // Confirmation changes the draft only until the surrounding form saves.
    expect(store.paramsOf(product)['cable.cores']!.data['confirmed'], isFalse);
  });
}
