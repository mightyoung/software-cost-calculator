import 'entities.dart';
import 'values.dart';

Map<String, Object?> validatePayload(
  String entityType,
  Map<String, Object?> value,
) => switch (entityType) {
  'supplier' => Supplier.fromJson(value).toJson(),
  'contact' => Contact.fromJson(value).toJson(),
  'product' => Product.fromJson(value).toJson(),
  'quotation' => Quotation.fromJson(value).toJson(),
  _ => invalid('entity_type', 'unknown entity type'),
};
Map<String, Object?> normalizeQuotation(Map<String, Object?> value) =>
    Quotation.fromJson(value).toJson();

final class Quotation extends EntityPayload {
  Quotation._(super.payload);
  static const fields = [
    'supplier_id',
    'product_id',
    'price',
    'currency',
    'tax_mode',
    'unit_snapshot',
    'min_qty',
    'quoted_on',
    'contact_id',
    'contact_snapshot',
    'tax_rate',
    'lead_time_days',
    'valid_until',
    'notes',
    'project_name',
    'project_number',
    'inquiry_location',
    'inquirer_name',
    'inquiry_precision',
    'inquiry_date',
    'inquired_at',
    'inquiry_utc_offset_minutes',
    'capture_mode',
  ];
  factory Quotation.fromJson(Map<String, Object?> value) {
    exactKeys(value, fields);
    final mode = value['capture_mode'];
    if (mode != 'standard' && mode != 'historical') {
      invalid('capture_mode', 'unknown mode');
    }
    final price = value['price'];
    final quantity = value['min_qty'];
    final taxRate = value['tax_rate'];
    if (price is! String) invalid('price', 'decimal text required');
    if (quantity is! String) invalid('min_qty', 'decimal text required');
    final currency = value['currency'];
    if (currency is! String || !RegExp(r'^[A-Z]{3}$').hasMatch(currency)) {
      invalid('currency', 'expected three uppercase letters');
    }
    final taxMode = value['tax_mode'];
    if (!['included', 'excluded', 'unknown'].contains(taxMode)) {
      invalid('tax_mode', 'invalid tax mode');
    }
    String? rate;
    if (taxRate != null) {
      if (taxRate is! String) invalid('tax_rate', 'decimal text required');
      final decimal = ExactDecimal.parse(
        taxRate,
        maxIntegerDigits: 3,
        maxFractionDigits: 4,
      );
      if (decimal.compareTo(ExactDecimal.parse('100')) > 0) {
        invalid('tax_rate', 'must be at most 100');
      }
      rate = decimal.canonical;
    }
    final quoted = value['quoted_on'] == null
        ? null
        : requireDate(value['quoted_on'], 'quoted_on');
    final valid = value['valid_until'] == null
        ? null
        : requireDate(value['valid_until'], 'valid_until');
    if (valid != null && (quoted == null || valid.compareTo(quoted) < 0)) {
      invalid('valid_until', 'requires quoted_on no later than valid_until');
    }
    final lead = value['lead_time_days'] == null
        ? null
        : requireSafeInteger(
            value['lead_time_days'],
            'lead_time_days',
            min: 0,
            max: 36500,
          );
    final contactId = value['contact_id'] == null
        ? null
        : requireUuid(value['contact_id'], 'contact_id');
    final rawSnapshot = value['contact_snapshot'];
    Map<String, Object?>? snapshot;
    if (rawSnapshot != null) {
      if (rawSnapshot is! Map<String, Object?>) {
        invalid('contact_snapshot', 'expected object');
      }
      snapshot = normalizeContactSnapshot(rawSnapshot);
    }
    if (contactId != null && snapshot == null) {
      invalid('contact_snapshot', 'required when contact is bound');
    }
    final result = Quotation._({
      'supplier_id': requireUuid(value['supplier_id'], 'supplier_id'),
      'product_id': requireUuid(value['product_id'], 'product_id'),
      'price': ExactDecimal.parse(price).canonical,
      'currency': currency,
      'tax_mode': taxMode,
      'unit_snapshot': normalizeText(
        value['unit_snapshot'],
        'unit_snapshot',
        50,
        required: true,
      ),
      'min_qty': ExactDecimal.parse(quantity, positive: true).canonical,
      'quoted_on': quoted,
      'contact_id': contactId,
      'contact_snapshot': snapshot,
      'tax_rate': rate,
      'lead_time_days': lead,
      'valid_until': valid,
      'notes': normalizeText(value['notes'], 'notes', 2000),
      'project_name': normalizeText(value['project_name'], 'project_name', 200),
      'project_number': normalizeText(
        value['project_number'],
        'project_number',
        100,
      ),
      'inquiry_location': normalizeText(
        value['inquiry_location'],
        'inquiry_location',
        500,
      ),
      'inquirer_name': normalizeText(
        value['inquirer_name'],
        'inquirer_name',
        200,
      ),
      ...InquiryTime.fromJson(value, historical: mode == 'historical').toJson(),
      'capture_mode': mode,
    });
    if (mode == 'standard' && result.missingContext.isNotEmpty) {
      invalid(result.missingContext.first, 'required for standard capture');
    }
    return result;
  }
  List<String> get missingContext {
    final value = toJson();
    return List.unmodifiable([
      if (value['project_name'] == null && value['project_number'] == null)
        'project',
      if (value['inquirer_name'] == null) 'inquirer_name',
      if (value['inquiry_date'] == null) 'inquiry_date',
      if (value['quoted_on'] == null) 'quoted_on',
    ]);
  }

  String get priceKey =>
      ExactDecimal.parse(toJson()['price']! as String).sortKey;
  Quotation copyAsNewInquiry([Map<String, Object?> changes = const {}]) =>
      Quotation.fromJson({...toJson(), ...changes, 'capture_mode': 'standard'});
  void validateEditFrom(Quotation previous, {bool allowExplicitClear = false}) {
    if (previous.toJson()['capture_mode'] == 'standard' &&
        toJson()['capture_mode'] != 'standard') {
      invalid('capture_mode', 'standard cannot be downgraded');
    }
    if (!allowExplicitClear) {
      for (final key in fields) {
        if (previous.toJson()[key] != null && toJson()[key] == null) {
          invalid(
            key,
            'clearing existing information requires explicit confirmation',
          );
        }
      }
      final before = previous.toJson()['contact_snapshot'];
      final after = toJson()['contact_snapshot'];
      if (before is Map<String, Object?> && after is Map<String, Object?>) {
        for (final key in before.keys) {
          if (before[key] != null && after[key] == null) {
            invalid(
              'contact_snapshot.$key',
              'clearing existing information requires explicit confirmation',
            );
          }
        }
      }
    }
  }

  void validateContact(String contactId, Contact contact) {
    if (toJson()['contact_id'] != requireUuid(contactId, 'contact_id') ||
        toJson()['supplier_id'] != contact.supplierId) {
      invalid('contact_id', 'contact or supplier does not match');
    }
    final snapshot = toJson()['contact_snapshot']! as Map<String, Object?>;
    for (final key in contact.snapshot.keys) {
      if (snapshot[key] != contact.snapshot[key]) {
        invalid(
          'contact_snapshot',
          'must copy selected contact at capture time',
        );
      }
    }
  }
}
