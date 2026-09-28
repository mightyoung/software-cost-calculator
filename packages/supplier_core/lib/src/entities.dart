import 'values.dart';

abstract base class EntityPayload {
  EntityPayload(Map<String, Object?> payload)
    : _payload = Map.unmodifiable(payload);
  final Map<String, Object?> _payload;
  Map<String, Object?> toJson() => _payload;
}

final class Supplier extends EntityPayload {
  Supplier._(super.payload);
  static const fields = [
    'name',
    'aliases',
    'address',
    'categories',
    'notes',
    'merged_into',
    // Schema 7: the buyer's own judgement.
    'rating',
    'rating_note',
  ];
  factory Supplier.fromJson(Map<String, Object?> input) {
    // Fields added later may be left out; they mean "not set".
    final value = {'rating': null, 'rating_note': null, ...input};
    final rating = value['rating'];
    if (rating != null && !supplierRatings.containsKey(rating)) {
      invalid('rating', 'unknown value');
    }
    exactKeys(value, fields);
    return Supplier._({
      'name': normalizeText(value['name'], 'name', 200, required: true),
      'aliases': normalizeTextList(value['aliases'], 'aliases', 20, 200),
      'address': normalizeText(value['address'], 'address', 500),
      'categories': normalizeTextList(
        value['categories'],
        'categories',
        20,
        100,
      ),
      'notes': normalizeText(value['notes'], 'notes', 2000),
      'merged_into': _mergedInto(value),
      'rating': rating,
      'rating_note': normalizeText(value['rating_note'], 'rating_note', 500),
    });
  }
}

/// 停用 suppliers' quotes never count as usable or lowest; 慎用 is shown
/// as a warning.
const supplierRatings = {'preferred': '推荐', 'caution': '慎用', 'disabled': '停用'};

/// A duplicate that was merged keeps its row and points at the record it
/// was merged into, so references arriving from other devices can follow.
String? _mergedInto(Map<String, Object?> value) => value['merged_into'] == null
    ? null
    : requireUuid(value['merged_into'], 'merged_into');

/// Key attributes of a material ("流量": "50m³/h"), in the order given;
/// empty becomes null.
Map<String, String>? _attributes(Object? value) {
  if (value == null) return null;
  if (value is! Map) invalid('attributes', 'expected object');
  if (value.length > 12) invalid('attributes', 'too many items');
  final result = <String, String>{
    for (final MapEntry(:key, :value) in value.entries)
      normalizeText(key, 'attributes', 30, required: true)!: normalizeText(
        value,
        'attributes',
        100,
        required: true,
      )!,
  };
  return result.isEmpty ? null : Map.unmodifiable(result);
}

Map<String, Object?> normalizeContactSnapshot(Map<String, Object?> value) {
  exactKeys(value, ['name', 'phone', 'wechat', 'email']);
  final result = <String, Object?>{
    'name': normalizeText(value['name'], 'name', 200, required: true),
    'phone': normalizeText(value['phone'], 'phone', 100),
    'wechat': normalizeText(value['wechat'], 'wechat', 100),
    'email': normalizeText(value['email'], 'email', 254),
  };
  if (result['phone'] == null &&
      result['wechat'] == null &&
      result['email'] == null) {
    invalid('contact_snapshot', 'at least one contact method required');
  }
  return Map.unmodifiable(result);
}

final class Contact extends EntityPayload {
  Contact._(super.payload);
  static const fields = [
    'supplier_id',
    'name',
    'phone',
    'wechat',
    'email',
    'notes',
  ];
  factory Contact.fromJson(Map<String, Object?> value) {
    exactKeys(value, fields);
    return Contact._({
      'supplier_id': requireUuid(value['supplier_id'], 'supplier_id'),
      ...normalizeContactSnapshot({
        for (final key in ['name', 'phone', 'wechat', 'email']) key: value[key],
      }),
      'notes': normalizeText(value['notes'], 'notes', 2000),
    });
  }
  String get supplierId => toJson()['supplier_id']! as String;
  Map<String, Object?> get snapshot => Map.unmodifiable({
    for (final key in ['name', 'phone', 'wechat', 'email']) key: toJson()[key],
  });
}

final class Product extends EntityPayload {
  Product._(super.payload);
  static const fields = [
    'name',
    'unit',
    'brand',
    'model',
    'specification',
    'category',
    'notes',
    'merged_into',
    'attributes',
    'unit_conversions',
  ];
  factory Product.fromJson(Map<String, Object?> value) {
    exactKeys(value, fields);
    return Product._({
      'name': normalizeText(value['name'], 'name', 200, required: true),
      'unit': normalizeText(value['unit'], 'unit', 50, required: true),
      'brand': normalizeText(value['brand'], 'brand', 200),
      'model': normalizeText(value['model'], 'model', 200),
      'specification': normalizeText(
        value['specification'],
        'specification',
        1000,
      ),
      'category': normalizeText(value['category'], 'category', 100),
      'notes': normalizeText(value['notes'], 'notes', 2000),
      'merged_into': _mergedInto(value),
      'attributes': _attributes(value['attributes']),
      'unit_conversions': _unitConversions(
        value['unit_conversions'],
        normalizeText(value['unit'], 'unit', 50, required: true),
      ),
    });
  }
}

Map<String, String>? _unitConversions(Object? value, Object? base) {
  if (value == null) return null;
  if (value is! Map || value.length > 50)
    invalid('unit_conversions', 'expected at most 50 conversions');
  final result = <String, String>{};
  for (final entry in value.entries) {
    final unit = normalizeText(
      entry.key,
      'unit_conversions.unit',
      50,
      required: true,
    )!;
    if (unit == base || result.containsKey(unit) || entry.value is! String) {
      invalid('unit_conversions', 'duplicate or base unit, or invalid factor');
    }
    result[unit] = ExactDecimal.parse(
      entry.value as String,
      positive: true,
    ).canonical;
  }
  final units = result.keys.toList()..sort(compareCodepoints);
  return result.isEmpty
      ? null
      : {for (final unit in units) unit: result[unit]!};
}
