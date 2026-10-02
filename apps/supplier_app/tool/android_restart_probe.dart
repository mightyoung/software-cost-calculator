import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:supplier_app/app/core_supplier_workspace.dart';
import 'package:supplier_app/main.dart';
import 'package:supplier_app/platform/workspace_factory_native.dart';
import 'package:supplier_core/supplier_core.dart';

/// Android-only diagnostic entrypoint. Leaves three labelled test records.
/// Build/install explicitly; the normal application never seeds these records.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (!Platform.isAndroid) throw StateError('Android probe only');
  final workspace = await openSupplierWorkspace() as CoreSupplierWorkspace;
  try {
    const marker = 'ANDROID-E2E-20260930';
    final supplier = await _seed(workspace, 'supplier', {
      'name': '$marker supplier',
      'aliases': <String>[],
      'categories': <String>[],
      'address': 'Android emulator test',
    });
    final product = await _seed(workspace, 'product', {
      'name': '$marker product',
      'unit': '件',
      'brand': 'Android E2E',
      'model': marker,
    });
    final quotation = await _seed(workspace, 'quotation', {
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
    final record = await workspace.read('quotation', quotation);
    if (record.payload['price'] != '12.340001' ||
        record.payload['project_number'] != '000123-ANDROID-E2E') {
      throw StateError('Checkpoint payload changed');
    }
    final directory = await resolveNativeDataDirectory();
    await File('${directory.path}/android-e2e-checkpoint-20260930.json')
        .writeAsString(
          jsonEncode({
            'marker': marker,
            'directory': directory.path,
            'supplier': supplier,
            'product': product,
            'quotation': quotation,
            'price': record.payload['price'],
            'project_number': record.payload['project_number'],
            'heads': record.heads.toList(),
          }),
          flush: true,
        );
  } finally {
    await workspace.close();
  }
  runApp(const SupplierStartup());
}

Future<String> _seed(
  CoreSupplierWorkspace workspace,
  String type,
  Map<String, Object?> payload,
) async {
  final key = type == 'quotation' ? 'project_number' : 'name';
  final page = await workspace.list(
    type,
    search: type == 'quotation' ? '' : payload[key]! as String,
    filters: type == 'quotation' ? {key: payload[key]} : const {},
  );
  final existing = page.records
      .where((record) => record.payload[key] == payload[key])
      .toList();
  if (existing.length > 1) throw StateError('Duplicate checkpoint: $type');
  if (existing.isNotEmpty) return existing.single.id;
  final fields = switch (type) {
    'supplier' => Supplier.fields,
    'product' => Product.fields,
    'quotation' => Quotation.fields,
    _ => throw StateError('Unexpected checkpoint entity: $type'),
  };
  return workspace.save(type, {
    for (final field in fields) field: payload[field],
  });
}
