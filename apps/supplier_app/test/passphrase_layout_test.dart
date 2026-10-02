import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supplier_app/app/app_state.dart';
import 'package:supplier_app/app/theme.dart';
import 'package:supplier_app/features/exchange/passphrase.dart';
import 'package:supplier_core/supplier_core.dart';

void main() {
  for (final width in [320.0, 390.0]) {
    for (final isSet in [false, true]) {
      testWidgets('passphrase stays readable at $width with set=$isSet', (
        tester,
      ) async {
        FlutterSecureStorage.setMockInitialValues({});
        final dir = Directory.systemTemp.createTempSync('passphrase_layout');
        addTearDown(() => dir.deleteSync(recursive: true));
        final store = Store.open('${dir.path}/test.db', device: 'test');
        addTearDown(store.close);
        final state = AppState.test(store, dir);
        if (isSet) await state.saveExchangePassphrase('existing-passphrase');
        tester.view.physicalSize = Size(width, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          MaterialApp(
            theme: buildTheme(),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: const TextScaler.linear(1.5)),
              child: child!,
            ),
            home: Scaffold(
              body: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: PassphraseRow(state: state),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final description = find.textContaining('设置后，导出的交换文件');
        final action = find.widgetWithText(TextButton, isSet ? '更改' : '设置口令');
        expect(tester.getSize(description).width, greaterThan(200));
        expect(
          tester.getTopLeft(action).dy,
          greaterThanOrEqualTo(tester.getBottomLeft(description).dy),
        );
        expect(action.hitTestable(), findsOneWidget);
        await tester.tap(action);
        await tester.pumpAndSettle();
        expect(find.byType(TextField), findsNWidgets(2));
        await tester.tap(find.text('取消'));
        await tester.pumpAndSettle();
        expect(
          await state.exchangePassphrase(),
          isSet ? 'existing-passphrase' : isNull,
        );
        expect(tester.takeException(), isNull);
      });
    }
  }
}
