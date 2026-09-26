import 'entities.dart';
import 'values.dart';

const inquiryStatuses = ['open', 'closed'];

/// What a quotation's price covers besides the goods themselves.
const quoteIncludes = ['freight', 'installation', 'commissioning', 'training'];

/// Sorted, de-duplicated UUID list of at most [max] entries.
List<String> uuidList(Object? value, String field, int max) {
  if (value is! List) invalid(field, 'expected array');
  if (value.length > max) invalid(field, 'too many items');
  return List.unmodifiable(
    {for (final v in value) requireUuid(v, field)}.toList()..sort(),
  );
}

/// A request for quotations: some budget lines of one project, sent to some
/// suppliers, answered by quotations that carry this inquiry's id.
final class Inquiry extends EntityPayload {
  Inquiry._(super.payload);
  static const fields = [
    'project_id',
    'title',
    'item_ids',
    'supplier_ids',
    'due_date',
    'status',
    'notes',
  ];
  factory Inquiry.fromJson(Map<String, Object?> value) {
    exactKeys(value, fields);
    final status = value['status'];
    if (!inquiryStatuses.contains(status)) invalid('status', 'unknown value');
    return Inquiry._({
      'project_id': requireUuid(value['project_id'], 'project_id'),
      'title': normalizeText(value['title'], 'title', 200, required: true),
      'item_ids': uuidList(value['item_ids'], 'item_ids', 500),
      'supplier_ids': uuidList(value['supplier_ids'], 'supplier_ids', 50),
      'due_date': value['due_date'] == null
          ? null
          : requireDate(value['due_date'], 'due_date'),
      'status': status,
      'notes': normalizeText(value['notes'], 'notes', 2000),
    });
  }
}
