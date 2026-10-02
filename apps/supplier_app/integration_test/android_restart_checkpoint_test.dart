import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:supplier_app/app/core_supplier_workspace.dart';
import 'package:supplier_app/app/supplier_app.dart';
import 'package:supplier_app/main.dart';
import 'package:supplier_app/platform/workspace_factory_native.dart';
import 'package:supplier_core/supplier_core.dart';

/// Intentionally creates labelled test records in Android's real support folder.
/// Reinstall the normal APK and force-stop/relaunch it to verify the checkpoint.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('Android production directory retains a restart checkpoint', (
    tester,
  ) async {
    expect(Platform.isAndroid, isTrue);
    final workspace = await openSupplierWorkspace() as CoreSupplierWorkspace;
    const marker = 'ANDROID-E2E-20260930';
    final supplier = await _seedOnce(workspace, 'supplier', {
      'name': '$marker supplier',
      'aliases': <String>[],
      'categories': <String>[],
      'address': 'Android emulator test',
    });
    final product = await _seedOnce(workspace, 'product', {
      'name': '$marker product',
      'unit': '件',
      'brand': 'Android E2E',
      'model': marker,
    });
    final quote = await _seedOnce(workspace, 'quotation', {
      'supplier_id': supplier,
      'product_id': product,
      'price': '12.340001',
      'currency': 'CNY',
      'tax_mode': 'unknown',
      'unit_snapshot': '件',
      'min_qty': '1',
      'quoted_on': '2026-09-30',
      'project_name': 'Android emulator verification',
      'project_number': '000123-ANDROID-E2E',
      'inquiry_location': 'Android emulator',
      'inquirer_name': 'Android test',
      'inquiry_precision': 'date',
      'inquiry_date': '2026-09-30',
      'capture_mode': 'standard',
    });
    final directory = await resolveNativeDataDirectory();
    await File('${directory.path}/android-e2e-checkpoint-20260930.json')
        .writeAsString(
          jsonEncode({
            'marker': marker,
            'directory': directory.path,
            'supplier': supplier,
            'product': product,
            'quotation': quote,
            'price': '12.340001',
            'project_number': '000123-ANDROID-E2E',
          }),
          flush: true,
        );
    await workspace.close();

    // Exercise the normal production startup and its actual path_provider dir.
    await tester.pumpWidget(const SupplierStartup());
    for (var attempt = 0; attempt < 400; attempt++) {
      await tester.pump(const Duration(milliseconds: 50));
      if (find.byType(SupplierApp).evaluate().isNotEmpty) break;
    }
    await tester.pumpAndSettle();
    expect(find.text('$marker product'), findsOneWidget);
    final reopened =
        tester.widget<SupplierApp>(find.byType(SupplierApp)).workspace
            as CoreSupplierWorkspace;
    final saved = await reopened.read('quotation', quote);
    expect(saved.payload['price'], '12.340001');
    expect(saved.payload['project_number'], '000123-ANDROID-E2E');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    await reopened.close();
  }, timeout: const Timeout(Duration(minutes: 2)));
}

Future<String> _seedOnce(
  CoreSupplierWorkspace workspace,
  String type,
  Map<String, Object?> payload,
) async {
  final isQuotation = type == 'quotation';
  final key = isQuotation ? 'project_number' : 'name';
  final page = await workspace.list(
    type,
    search: isQuotation ? '' : payload[key]! as String,
    filters: isQuotation ? {key: payload[key]} : const {},
  );
  final existing = page.records
      .where((record) => record.payload[key] == payload[key])
      .toList();
  expect(existing.length, lessThanOrEqualTo(1));
  final fields = switch (type) {
    'supplier' => Supplier.fields,
    'product' => Product.fields,
    'quotation' => Quotation.fields,
    _ => throw StateError('Unexpected checkpoint entity: $type'),
  };
  return existing.isEmpty
      ? workspace.save(type, {
          for (final field in fields) field: payload[field],
        })
      : existing.single.id;
}
