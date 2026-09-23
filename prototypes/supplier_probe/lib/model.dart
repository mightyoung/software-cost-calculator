import 'dart:convert';
import 'package:unorm_dart/unorm_dart.dart' as unicode;

typedef Row = Map<String, Object?>;
typedef Snapshot = Map<String, List<Row>>;

const contextFields = [
  'project_name',
  'project_number',
  'inquired_at',
  'inquiry_utc_offset_minutes',
  'inquiry_location',
  'inquirer_name',
];
const columns = <String, List<String>>{
  'suppliers': ['id', 'name', 'aliases', 'address', 'categories', 'notes'],
  'contacts': [
    'id',
    'supplier_id',
    'name',
    'phone',
    'wechat',
    'email',
    'notes',
  ],
  'products': [
    'id',
    'name',
    'unit',
    'brand',
    'model',
    'specification',
    'category',
    'notes',
  ],
  'quotations': [
    'id',
    'supplier_id',
    'product_id',
    'price',
    'currency',
    'tax_mode',
    'quoted_on',
    'unit_snapshot',
    'min_qty',
    'contact_id',
    'contact_snapshot',
    'tax_rate',
    'lead_time_days',
    'valid_until',
    'notes',
    ...contextFields,
  ],
};
const integerFields = {'lead_time_days', 'inquiry_utc_offset_minutes'};
const jsonFields = {'aliases', 'categories', 'contact_snapshot'};

Never invalid(String field, String reason) =>
    throw FormatException('$field: $reason');

String? textValue(Object? value, String key, int max, {bool required = false}) {
  if (value == null) {
    if (required) invalid(key, 'required');
    return null;
  }
  if (value is! String) invalid(key, 'text required');
  if (value.runes.any(
    (r) => (r >= 0xD800 && r <= 0xDFFF) || r == 0xFFFE || r == 0xFFFF,
  )) {
    invalid(key, 'invalid Unicode scalar or XML character');
  }
  final result = unicode.nfc(value.trim());
  if (RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]').hasMatch(result)) {
    invalid(key, 'control character');
  }
  if (result.runes.length > max) {
    invalid(key, 'maximum $max Unicode code points');
  }
  if (result.isEmpty) {
    if (required) invalid(key, 'required');
    return null;
  }
  return result;
}

String decimal(
  Object? input,
  String key, {
  int scale = 6,
  bool positive = false,
}) {
  if (input is! String ||
      !RegExp('^[0-9]{1,12}(\\.[0-9]{1,$scale})?\$').hasMatch(input)) {
    invalid(key, 'exact decimal text required');
  }
  final parts = input.split('.');
  final whole = parts.first.replaceFirst(RegExp(r'^0+(?=\d)'), '');
  final fraction = parts.length == 1
      ? ''
      : parts[1].replaceFirst(RegExp(r'0+$'), '');
  final result = fraction.isEmpty ? whole : '$whole.$fraction';
  if (positive && result == '0') invalid(key, 'must be positive');
  return result;
}

String priceKey(String value) {
  final parts = value.split('.');
  return parts[0].padLeft(12, '0') +
      (parts.length == 2 ? parts[1] : '').padRight(6, '0');
}

DateTime calendar(String value, String field) {
  if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value)) {
    invalid(field, 'YYYY-MM-DD required');
  }
  final p = value.split('-').map(int.parse).toList();
  final date = DateTime.utc(p[0], p[1], p[2]);
  if (p[0] < 1 || date.year != p[0] || date.month != p[1] || date.day != p[2]) {
    invalid(field, 'invalid calendar date');
  }
  return date;
}

({String utc, int offset}) parseInquiryTime(String value) {
  final match = RegExp(
    r'^(\d{4}-\d{2}-\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.(\d{1,3}))?(Z|[+-]\d{2}:\d{2})$',
  ).firstMatch(value);
  if (match == null) {
    invalid(
      'inquired_at',
      'timezone and at most millisecond precision required',
    );
  }
  final date = calendar(match[1]!, 'inquired_at');
  final hour = int.parse(match[2]!);
  final minute = int.parse(match[3]!);
  final second = int.parse(match[4]!);
  if (hour > 23 || minute > 59 || second > 59) {
    invalid('inquired_at', 'invalid time');
  }
  final zone = match[6]!;
  var offset = 0;
  if (zone != 'Z') {
    final hours = int.parse(zone.substring(1, 3));
    final minutes = int.parse(zone.substring(4));
    if (minutes > 59 || hours * 60 + minutes > 840) {
      invalid('inquired_at', 'invalid offset');
    }
    offset = (hours * 60 + minutes) * (zone[0] == '-' ? -1 : 1);
  }
  final local = DateTime.utc(
    date.year,
    date.month,
    date.day,
    hour,
    minute,
    second,
    int.parse((match[5] ?? '').padRight(3, '0')),
  );
  final utc = local.subtract(Duration(minutes: offset));
  if (utc.year < 1 || utc.year > 9999) {
    invalid('inquired_at', 'UTC outside supported calendar');
  }
  return (utc: utc.toIso8601String(), offset: offset);
}

String inquiryTimeForExcel(Row row) {
  final offset = row['inquiry_utc_offset_minutes'] as int;
  final local = DateTime.parse(
    row['inquired_at'] as String,
  ).add(Duration(minutes: offset)).toIso8601String();
  final abs = offset.abs();
  return '${local.substring(0, local.length - 1)}${offset < 0 ? '-' : '+'}${(abs ~/ 60).toString().padLeft(2, '0')}:${(abs % 60).toString().padLeft(2, '0')}';
}

Snapshot normalizeSnapshot(Snapshot input) {
  if (input.keys.toSet().difference(columns.keys.toSet()).isNotEmpty ||
      columns.keys.any((k) => !input.containsKey(k))) {
    invalid('snapshot', 'exact four tables required');
  }
  final result = <String, List<Row>>{};
  for (final table in columns.keys) {
    final rows = <Row>[];
    final ids = <String>{};
    for (final raw in input[table]!) {
      final keys = columns[table]!;
      if (raw.length != keys.length || keys.any((k) => !raw.containsKey(k))) {
        invalid(table, 'missing or unknown fields');
      }
      final row = <String, Object?>{};
      for (final key in keys) {
        final value = raw[key];
        if (integerFields.contains(key)) {
          if (value != null && value is! int) invalid(key, 'integer required');
          if (value is int &&
              (key == 'lead_time_days'
                  ? value < 0 || value > 36500
                  : value < -840 || value > 840)) {
            invalid(key, 'out of range');
          }
          row[key] = value;
        } else if (jsonFields.contains(key)) {
          if (key == 'contact_snapshot') {
            if (value == null) {
              row[key] = null;
              continue;
            }
            if (value is! Map ||
                value.length != 4 ||
                ![
                  'name',
                  'phone',
                  'wechat',
                  'email',
                ].every(value.containsKey)) {
              invalid(key, 'name/phone/wechat/email object required');
            }
            final contact = <String, Object?>{};
            for (final k in ['name', 'phone', 'wechat', 'email']) {
              contact[k] = textValue(
                value[k],
                k,
                k == 'email'
                    ? 254
                    : k == 'name'
                    ? 200
                    : 100,
                required: k == 'name',
              );
            }
            if (['phone', 'wechat', 'email'].every((k) => contact[k] == null)) {
              invalid(key, 'contact method required');
            }
            row[key] = contact;
          } else {
            if (value is! List || value.length > 20) {
              invalid(key, 'list of at most 20 text entries required');
            }
            row[key] = value
                .map(
                  (v) => textValue(
                    v,
                    key,
                    key == 'aliases' ? 200 : 100,
                    required: true,
                  ),
                )
                .toList();
          }
        } else {
          final max = switch (key) {
            'notes' => 2000,
            'specification' => 1000,
            'address' || 'inquiry_location' => 500,
            'email' => 254,
            'phone' || 'wechat' || 'category' || 'project_number' => 100,
            'unit' || 'unit_snapshot' => 50,
            _ => 200,
          };
          final required = [
            'id',
            'name',
            'supplier_id',
            'product_id',
            'price',
            'currency',
            'tax_mode',
            'quoted_on',
            'unit',
            'unit_snapshot',
            'min_qty',
          ].contains(key);
          row[key] = textValue(value, key, max, required: required);
        }
      }
      final id = row['id'] as String;
      if (!RegExp(
            r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
          ).hasMatch(id) ||
          !ids.add(id)) {
        invalid('$table.id', 'invalid or duplicate UUID v4');
      }
      if (table == 'contacts' &&
          ['phone', 'wechat', 'email'].every((k) => row[k] == null)) {
        invalid('contacts', 'contact method required');
      }
      if (table == 'quotations') {
        row['price'] = decimal(row['price'], 'price');
        row['min_qty'] = decimal(row['min_qty'], 'min_qty', positive: true);
        if (row['tax_rate'] != null) {
          row['tax_rate'] = decimal(row['tax_rate'], 'tax_rate', scale: 4);
          if (BigInt.parse(priceKey(row['tax_rate'] as String)) >
              BigInt.parse(priceKey('100'))) {
            invalid('tax_rate', 'maximum 100');
          }
        }
        if (!RegExp(r'^[A-Z]{3}$').hasMatch(row['currency'] as String)) {
          invalid('currency', 'three uppercase letters required');
        }
        if (!['included', 'excluded', 'unknown'].contains(row['tax_mode'])) {
          invalid('tax_mode', 'unknown enum');
        }
        final quoted = calendar(row['quoted_on'] as String, 'quoted_on');
        if (row['valid_until'] != null &&
            calendar(
              row['valid_until'] as String,
              'valid_until',
            ).isBefore(quoted)) {
          invalid('valid_until', 'before quoted_on');
        }
        if ((row['inquired_at'] == null) !=
            (row['inquiry_utc_offset_minutes'] == null)) {
          invalid('inquired_at', 'time and offset must both be set or null');
        }
        if (row['inquired_at'] != null) {
          final parsed = parseInquiryTime(row['inquired_at'] as String);
          if (!(row['inquired_at'] as String).endsWith('Z')) {
            invalid('inquired_at', 'stored value must be UTC Z');
          }
          row['inquired_at'] = parsed.utc;
          final localYear = DateTime.parse(parsed.utc)
              .add(Duration(minutes: row['inquiry_utc_offset_minutes'] as int))
              .year;
          if (localYear < 1 || localYear > 9999) {
            invalid('inquired_at', 'local time outside supported calendar');
          }
        }
      }
      rows.add(row);
    }
    rows.sort((a, b) => (a['id'] as String).compareTo(b['id'] as String));
    result[table] = rows;
  }
  final suppliers = result['suppliers']!.map((r) => r['id']).toSet();
  final products = result['products']!.map((r) => r['id']).toSet();
  final contacts = {for (final r in result['contacts']!) r['id']: r};
  for (final row in [...result['contacts']!, ...result['quotations']!]) {
    if (!suppliers.contains(row['supplier_id'])) {
      invalid('supplier_id', 'missing supplier');
    }
  }
  for (final row in result['quotations']!) {
    if (!products.contains(row['product_id'])) {
      invalid('product_id', 'missing product');
    }
    if (row['contact_id'] != null && row['contact_snapshot'] == null) {
      invalid('contact_snapshot', 'required when contact selected');
    }
    if (row['contact_id'] != null &&
        contacts[row['contact_id']]?['supplier_id'] != row['supplier_id']) {
      invalid('contact_id', 'missing contact or different supplier');
    }
  }
  return result;
}

String? cellText(Row row, String key) {
  final value = row[key];
  if (value == null) return null;
  if (key == 'inquired_at') return inquiryTimeForExcel(row);
  return jsonFields.contains(key) ? jsonEncode(value) : value.toString();
}

Snapshot sampleSnapshot() {
  Row row(String table, Map<String, Object?> values) => {
    for (final key in columns[table]!) key: values[key],
  };
  const supplier = '11111111-1111-4111-8111-111111111111';
  const product = '22222222-2222-4222-8222-222222222222';
  const contact = '44444444-4444-4444-8444-444444444444';
  return normalizeSnapshot({
    'suppliers': [
      row('suppliers', {
        'id': supplier,
        'name': '供货商一',
        'aliases': <String>[],
        'categories': ['阀门'],
      }),
    ],
    'contacts': [
      row('contacts', {
        'id': contact,
        'supplier_id': supplier,
        'name': '李四',
        'phone': '0013800000000',
      }),
    ],
    'products': [
      row('products', {
        'id': product,
        'name': 'Valve',
        'unit': '件',
        'brand': 'Acme',
        'model': '001-A',
      }),
    ],
    'quotations': [
      row('quotations', {
        'id': '33333333-3333-4333-8333-333333333333',
        'supplier_id': supplier,
        'product_id': product,
        'price': '12.340001',
        'currency': 'CNY',
        'tax_mode': 'included',
        'quoted_on': '2026-09-01',
        'unit_snapshot': '件',
        'min_qty': '1',
        'contact_id': contact,
        'contact_snapshot': {
          'name': '李四',
          'phone': '0013800000000',
          'wechat': null,
          'email': null,
        },
        'tax_rate': '13',
        'valid_until': '2026-09-30',
        'project_name': '配电改造一期',
        'project_number': '000123-A',
        'inquired_at': '2026-09-16T06:30:00.123Z',
        'inquiry_utc_offset_minutes': 480,
        'inquiry_location': '上海展会 A-01',
        'inquirer_name': '张三',
      }),
    ],
  });
}
