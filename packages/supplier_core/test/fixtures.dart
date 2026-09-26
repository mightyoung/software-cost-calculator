import 'dart:convert';
import 'dart:io';

import 'package:supplier_core/supplier_core.dart';

late Directory tmp;
var tick = 0;

/// Each device gets its own clock so updated_at ordering is deterministic.
Store device(String name, {DateTime? start}) {
  var now = start ?? DateTime.utc(2026, 9, 1);
  return Store.open(
    '${tmp.path}/$name-${tick++}.db',
    device: name,
    clock: () => now = now.add(const Duration(seconds: 1)),
  );
}

Map<String, Object?> supplier(String name) => {
  'name': name,
  'aliases': <String>[],
  'address': null,
  'categories': <String>[],
  'notes': null,
  'merged_into': null,
};

Map<String, Object?> product(String name, {String unit = '件'}) => {
  'name': name,
  'unit': unit,
  'brand': null,
  'model': null,
  'specification': null,
  'category': null,
  'notes': null,
  'merged_into': null,
};

Map<String, Object?> project(
  String code, {
  String? contract,
  String markup = '0',
  String currency = 'CNY',
}) => {
  'code': code,
  'name': '项目$code',
  'status': 'active',
  'type': 'market',
  'level': 'A',
  'customer': null,
  'contract_no': null,
  'contract_amount': contract,
  'department': null,
  'leader': null,
  'start_date': null,
  'end_date': null,
  'currency': currency,
  'tax_mode': 'included',
  'markup_rate': markup,
  'notes': null,
};

Map<String, Object?> quotation(
  String supplierId,
  String productId,
  String? projectId,
  String price, {
  String quotedOn = '2026-09-01',
  String? validUntil,
  String currency = 'CNY',
}) => {
  'supplier_id': supplierId,
  'product_id': productId,
  'price': price,
  'currency': currency,
  'tax_mode': 'included',
  'unit_snapshot': '件',
  'min_qty': '1',
  'quoted_on': quotedOn,
  'contact_id': null,
  'contact_snapshot': null,
  'tax_rate': '13',
  'lead_time_days': null,
  'valid_until': validUntil,
  'notes': null,
  'project_id': projectId,
  'inquiry_location': null,
  'inquirer_name': '张三',
  'inquiry_precision': 'date',
  'inquiry_date': '2026-09-01',
  'inquired_at': null,
  'inquiry_utc_offset_minutes': null,
  'capture_mode': 'standard',
};

Map<String, Object?> item(
  String projectId,
  String category, {
  String? productId,
  String? quotationId,
  String? name,
  String qty = '1',
  String cost = '0',
  String? price,
}) => {
  'project_id': projectId,
  'category': category,
  'product_id': productId,
  'name': name,
  'qty': qty,
  'unit': '件',
  'quotation_id': quotationId,
  'unit_cost': cost,
  'unit_price': price,
  'notes': null,
};

/// Business content of every table, independent of device and file.
List<List<Object?>> content(Store s) => [
  for (final type in entityTypes)
    for (final r in s.db.select(
      'SELECT id, version, updated_at, updated_by, deleted, data '
      'FROM $type ORDER BY id',
    ))
      [type, ...r.values],
  for (final r in s.db.select('SELECT * FROM change_log ORDER BY id')) r.values,
];

String exported(Store s) {
  final path = '${tmp.path}/export-${tick++}.siq';
  s.exportTo(path);
  return path;
}

/// Replays scripted assistant messages and records every request body.
class FakeModel {
  FakeModel(this.replies);
  final List<Map<String, Object?>> replies;
  final requests = <Map<String, Object?>>[];
  LlmClient get client => LlmClient(
    const LlmConfig(apiKey: 'test'),
    transport: (body) async {
      requests.add(jsonDecode(jsonEncode(body)) as Map<String, Object?>);
      return {
        'choices': [
          {'message': replies.removeAt(0)},
        ],
      };
    },
  );
}

Map<String, Object?> jsonReply(Object value) => {
  'role': 'assistant',
  'content': jsonEncode(value),
};
