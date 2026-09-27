import 'entities.dart';
import 'values.dart';

const projectStatuses = ['planning', 'active', 'done', 'cancelled'];
const projectTypes = ['market', 'internal'];
const projectLevels = ['A', 'B', 'C'];
const costCategories = [
  'material',
  'outsourcing',
  'labor',
  'overhead',
  'other',
];

String? _decimal(Object? value, String field, {int fraction = 6}) {
  if (value == null) return null;
  if (value is! String) invalid(field, 'decimal text required');
  return ExactDecimal.parse(value, maxFractionDigits: fraction).canonical;
}

Object? _oneOf(Object? value, String field, List<String> allowed) {
  if (value != null && !allowed.contains(value))
    invalid(field, 'unknown value');
  return value;
}

final class Project extends EntityPayload {
  Project._(super.payload);
  static const fields = [
    'code',
    'name',
    'status',
    'type',
    'level',
    'customer',
    'contract_no',
    'contract_amount',
    'department',
    'leader',
    'start_date',
    'end_date',
    'currency',
    'tax_mode',
    'markup_rate',
    'notes',
  ];
  factory Project.fromJson(Map<String, Object?> value) {
    exactKeys(value, fields);
    final currency = value['currency'];
    if (currency is! String || !RegExp(r'^[A-Z]{3}$').hasMatch(currency)) {
      invalid('currency', 'expected three uppercase letters');
    }
    final start = value['start_date'] == null
        ? null
        : requireDate(value['start_date'], 'start_date');
    final end = value['end_date'] == null
        ? null
        : requireDate(value['end_date'], 'end_date');
    if (start != null && end != null && end.compareTo(start) < 0) {
      invalid('end_date', 'must not be earlier than start_date');
    }
    final markup = _decimal(value['markup_rate'], 'markup_rate', fraction: 4);
    if (markup == null) invalid('markup_rate', 'required');
    if (ExactDecimal.parse(markup).compareTo(ExactDecimal.parse('1000')) > 0) {
      invalid('markup_rate', 'must be at most 1000 percent');
    }
    if (value['status'] == null) invalid('status', 'required');
    if (value['tax_mode'] == null) invalid('tax_mode', 'required');
    return Project._({
      'code': normalizeText(value['code'], 'code', 50, required: true),
      'name': normalizeText(value['name'], 'name', 200, required: true),
      'status': _oneOf(value['status'], 'status', projectStatuses),
      'type': _oneOf(value['type'], 'type', projectTypes),
      'level': _oneOf(value['level'], 'level', projectLevels),
      'customer': normalizeText(value['customer'], 'customer', 200),
      'contract_no': normalizeText(value['contract_no'], 'contract_no', 100),
      'contract_amount': _decimal(value['contract_amount'], 'contract_amount'),
      'department': normalizeText(value['department'], 'department', 100),
      'leader': normalizeText(value['leader'], 'leader', 100),
      'start_date': start,
      'end_date': end,
      'currency': currency,
      'tax_mode': _oneOf(value['tax_mode'], 'tax_mode', [
        'included',
        'excluded',
      ]),
      'markup_rate': markup,
      'notes': normalizeText(value['notes'], 'notes', 2000),
    });
  }
}

/// One budget line. Material lines reference a product and optionally the
/// quotation whose price was snapshotted into [unit_cost]; a material line
/// with only a name is still to be inquired. Other categories are free-named.
final class ProjectItem extends EntityPayload {
  ProjectItem._(super.payload);
  static const fields = [
    'project_id',
    'category',
    'product_id',
    'name',
    'qty',
    'unit',
    'quotation_id',
    'unit_cost',
    'unit_price',
    'notes',
  ];
  factory ProjectItem.fromJson(Map<String, Object?> value) {
    exactKeys(value, fields);
    final category = value['category'];
    if (!costCategories.contains(category)) {
      invalid('category', 'unknown cost category');
    }
    final material = category == 'material';
    final productId = value['product_id'] == null
        ? null
        : requireUuid(value['product_id'], 'product_id');
    final quotationId = value['quotation_id'] == null
        ? null
        : requireUuid(value['quotation_id'], 'quotation_id');
    final name = normalizeText(value['name'], 'name', 200);
    if (!material && productId != null) {
      invalid('product_id', 'only material lines reference products');
    }
    if (quotationId != null && productId == null) {
      invalid('quotation_id', 'requires product_id');
    }
    // A material line without a product is an item still to be inquired.
    if (productId == null && name == null) invalid('name', 'required');
    final qty = value['qty'];
    if (qty is! String) invalid('qty', 'decimal text required');
    final cost = _decimal(value['unit_cost'], 'unit_cost');
    if (cost == null) invalid('unit_cost', 'required');
    return ProjectItem._({
      'project_id': requireUuid(value['project_id'], 'project_id'),
      'category': category,
      'product_id': productId,
      'name': name,
      'qty': ExactDecimal.parse(qty, positive: true).canonical,
      'unit': normalizeText(value['unit'], 'unit', 50, required: true),
      'quotation_id': quotationId,
      'unit_cost': cost,
      'unit_price': _decimal(value['unit_price'], 'unit_price'),
      'notes': normalizeText(value['notes'], 'notes', 2000),
    });
  }
}
