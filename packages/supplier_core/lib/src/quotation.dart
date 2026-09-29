import 'entities.dart';
import 'inquiry.dart';
import 'product_params.dart';
import 'pricing.dart';
import 'project.dart';
import 'values.dart';

Map<String, Object?> validatePayload(
  String entityType,
  Map<String, Object?> value,
) => switch (entityType) {
  'supplier' => Supplier.fromJson(value).toJson(),
  'contact' => Contact.fromJson(value).toJson(),
  'product' => Product.fromJson(value).toJson(),
  'quotation' => Quotation.fromJson(value).toJson(),
  'project' => Project.fromJson(value).toJson(),
  'project_item' => ProjectItem.fromJson(value).toJson(),
  'inquiry' => Inquiry.fromJson(value).toJson(),
  'product_param' => ProductParam.fromJson(value).toJson(),
  _ => invalid('entity_type', 'unknown entity type'),
};

/// Field names of each entity type, in canonical order.
List<String> payloadFields(String entityType) => switch (entityType) {
  'supplier' => Supplier.fields,
  'contact' => Contact.fields,
  'product' => Product.fields,
  'quotation' => Quotation.fields,
  'project' => Project.fields,
  'project_item' => ProjectItem.fields,
  'inquiry' => Inquiry.fields,
  'product_param' => ProductParam.fields,
  _ => invalid('entity_type', 'unknown entity type'),
};

/// Prices that are shown but never used for budgets (null = formal quote).
const priceBases = ['verbal', 'reference'];

String? _optionalDecimal(Object? value, String field) {
  if (value == null) return null;
  if (value is! String) invalid(field, 'decimal text required');
  return ExactDecimal.parse(value).canonical;
}

/// includes: null means "not stated"; [] means "none of them".
/// An award (awarded_on) always carries the agreed unit price (deal_price).
Map<String, Object?> _scopeAndAward(Map<String, Object?> value) {
  final includes = value['includes'];
  List<String>? scope;
  if (includes != null) {
    if (includes is! List) invalid('includes', 'expected array');
    for (final i in includes) {
      if (!quoteIncludes.contains(i)) invalid('includes', 'unknown value');
    }
    scope = List.unmodifiable([
      for (final i in quoteIncludes)
        if (includes.contains(i)) i,
    ]);
  }
  final deal = _optionalDecimal(value['deal_price'], 'deal_price');
  final awarded = value['awarded_on'] == null
      ? null
      : requireDate(value['awarded_on'], 'awarded_on');
  if (awarded != null && deal == null) invalid('deal_price', 'required');
  final attachments = value['attachment_ids'] == null
      ? const <String>[]
      : uuidList(value['attachment_ids'], 'attachment_ids', 20);
  return {
    'includes': scope,
    'warranty_months': value['warranty_months'] == null
        ? null
        : requireSafeInteger(
            value['warranty_months'],
            'warranty_months',
            min: 0,
            max: 600,
          ),
    'extra_cost': _optionalDecimal(value['extra_cost'], 'extra_cost'),
    'deal_price': deal,
    'awarded_on': awarded,
    'award_note': normalizeText(value['award_note'], 'award_note', 500),
    'inquiry_id': value['inquiry_id'] == null
        ? null
        : requireUuid(value['inquiry_id'], 'inquiry_id'),
    'attachment_ids': attachments.isEmpty ? null : attachments,
    'price_basis': value['price_basis'] == null
        ? null
        : priceBases.contains(value['price_basis'])
        ? value['price_basis']
        : invalid('price_basis', 'unknown value'),
    'price_tiers': _tiers(value['price_tiers'], value['min_qty']),
  };
}

/// Up to 10 steps of "from this quantity, this unit price", in the quote's
/// unit, each above the minimum order and above the step before.
List<Map<String, Object?>>? _tiers(Object? raw, Object? minQty) {
  if (raw == null) return null;
  if (raw is! List || raw.isEmpty || raw.length > 10) {
    invalid('price_tiers', 'expected 1 to 10 tiers');
  }
  var floor = minQty is String
      ? micros(ExactDecimal.parse(minQty, positive: true).canonical)
      : BigInt.zero;
  return List.unmodifiable([
    for (final t in raw)
      () {
        if (t is! Map) invalid('price_tiers', 'expected objects');
        exactKeys(t.cast<String, Object?>(), const ['min_qty', 'price']);
        final q = t['min_qty'], p = t['price'];
        if (q is! String || p is! String) {
          invalid('price_tiers', 'decimal text required');
        }
        final qty = ExactDecimal.parse(q, positive: true).canonical;
        if (micros(qty) <= floor) {
          invalid(
            'price_tiers',
            'quantities must rise above the minimum order',
          );
        }
        floor = micros(qty);
        return Map<String, Object?>.unmodifiable({
          'min_qty': qty,
          'price': ExactDecimal.parse(p).canonical,
        });
      }(),
  ]);
}

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
    'project_id',
    'inquiry_location',
    'inquirer_name',
    'inquiry_precision',
    'inquiry_date',
    'inquired_at',
    'inquiry_utc_offset_minutes',
    'capture_mode',
    // Schema 3: scope, extra cost, award and provenance.
    'includes',
    'warranty_months',
    'extra_cost',
    'deal_price',
    'awarded_on',
    'award_note',
    'inquiry_id',
    'attachment_ids',
    // Schema 4: null = formal written quote.
    'price_basis',
    // Schema 7: lower unit prices from a larger quantity.
    'price_tiers',
  ];
  factory Quotation.fromJson(Map<String, Object?> input) {
    // Fields added later may be left out; they mean "not set".
    final value = {'price_tiers': null, ...input};
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
      'project_id': value['project_id'] == null
          ? null
          : requireUuid(value['project_id'], 'project_id'),
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
      ..._scopeAndAward(value),
    });
    if (mode == 'standard' && result.missingContext.isNotEmpty) {
      invalid(result.missingContext.first, 'required for standard capture');
    }
    return result;
  }
  List<String> get missingContext {
    final value = toJson();
    return List.unmodifiable([
      if (value['project_id'] == null) 'project_id',
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
