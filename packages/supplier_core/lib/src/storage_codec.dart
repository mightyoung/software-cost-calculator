import 'dart:convert';

import 'quotation.dart';
import 'values.dart';

/// Storage may omit quotation fields whose value is null. Domain payloads
/// retain every field, including nulls; nested objects are never made sparse.
Map<String, Object?> decodeStoredPayload(String type, String json) {
  final value = jsonDecode(json);
  if (value is! Map<String, Object?>) {
    invalid('$type.data', 'expected object');
  }
  final fields = payloadFields(type);
  if (value.keys.any((key) => !fields.contains(key))) {
    invalid('$type.data', 'unknown field');
  }
  if (type != 'quotation') {
    exactKeys(value, fields);
    return value;
  }
  // These are non-null even for historical quotations. Other fields may
  // legitimately be null; mode-dependent rules remain domain validation.
  for (final field in const [
    'supplier_id',
    'product_id',
    'price',
    'currency',
    'tax_mode',
    'unit_snapshot',
    'min_qty',
    'capture_mode',
  ]) {
    if (!value.containsKey(field)) {
      invalid('$type.$field', 'required storage field');
    }
  }
  return {for (final field in fields) field: value[field]};
}

/// Validates the dense public payload and writes canonical field order.
String encodeStoredPayload(String type, Map<String, Object?> dense) {
  final canonical = validatePayload(type, dense);
  return jsonEncode({
    for (final field in payloadFields(type))
      if (type != 'quotation' || canonical[field] != null)
        field: canonical[field],
  });
}
