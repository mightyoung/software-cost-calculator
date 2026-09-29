import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supplier_app/app/app_state.dart';
import 'package:supplier_app/app/theme.dart';
import 'package:supplier_app/features/data_center/data_center_page.dart';
import 'package:supplier_core/supplier_core.dart';

void main() {
  testWidgets(
    'model selection preserves live schema descriptions and records',
    (tester) async {
      final dir = Directory.systemTemp.createTempSync('data_model');
      final store = Store.open('${dir.path}/test.db', device: '测试');
      final state = AppState.test(store, dir);
      addTearDown(() {
        store.close();
        dir.deleteSync(recursive: true);
      });
      tester.view.physicalSize = const Size(1440, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final before = store.recordCounts();
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(),
          home: Scaffold(body: DataCenterPage(state: state)),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text(ontology['quotation']!.description), findsOneWidget);
      await tester.tap(find.text('联系人').first);
      await tester.pumpAndSettle();
      expect(find.text(ontology['contact']!.description), findsOneWidget);
      expect(store.recordCounts(), before);
      expect(tester.takeException(), isNull);
    },
  );

  for (final configuration in [
    (const Size(1440, 900), 1.0, false),
    (const Size(900, 720), 1.4, true),
    (const Size(390, 844), 1.4, false),
  ]) {
    testWidgets('model workspace adapts to $configuration without overflow', (
      tester,
    ) async {
      final (size, scale, dark) = configuration;
      final dir = Directory.systemTemp.createTempSync('model_layout');
      final store = Store.open('${dir.path}/test.db', device: '测试');
      final state = AppState.test(store, dir);
      addTearDown(() {
        store.close();
        dir.deleteSync(recursive: true);
        Tokens.dark = false;
      });
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      Tokens.dark = dark;
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: TextScaler.linear(scale),
              disableAnimations: true,
            ),
            child: child!,
          ),
          home: Scaffold(body: DataCenterPage(state: state)),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(
        find.byKey(const ValueKey('ontology-inspector')),
        size.width >= 1060 && scale == 1 ? findsOneWidget : findsNothing,
      );
      if (size.width < 680) {
        final chip = find.widgetWithText(ChoiceChip, '供应商 0');
        await tester.tap(chip);
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('同类引用'));
        expect(find.text('同类引用'), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
    });
  }
}
