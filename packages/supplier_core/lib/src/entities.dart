import 'values.dart';

abstract base class EntityPayload {
  EntityPayload(Map<String, Object?> payload)
    : _payload = Map.unmodifiable(payload);
  final Map<String, Object?> _payload;
  Map<String, Object?> toJson() => _payload;
}

final class Supplier extends EntityPayload {
  Supplier._(super.payload);
  static const fields = ['name', 'aliases', 'address', 'categories', 'notes'];
  factory Supplier.fromJson(Map<String, Object?> value) {
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
    });
  }
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
    });
  }
}
