import '../domain/canonical.dart';

/// Full price comparison scope. Null included-tax rate is its own group.
String comparisonGroup(Map<String, Object?> row) => canonicalJson([
  row['canonical_product_id'],
  row['unit_snapshot'],
  row['currency'],
  row['tax_mode'],
  row['min_qty'],
  row['tax_mode'] == 'included' ? row['tax_rate'] : null,
]);
List<String> comparisonIssues(Map<String, Object?> row, String asOf) => [
  if (row['relation_status'] != 'active' || row['payload'] == null)
    'quotation_not_active',
  if (row['supplier_status'] != 'active') 'supplier_not_active',
  if (row['product_status'] != 'active') 'product_not_active',
  if (row['tax_mode'] == 'unknown' || row['tax_mode'] == null) 'tax_unknown',
  if (row['quoted_on'] == null)
    'quoted_on_unknown'
  else if ((row['quoted_on']! as String).compareTo(asOf) > 0)
    'quoted_on_future',
  if (row['valid_until'] == null)
    'validity_pending'
  else if ((row['valid_until']! as String).compareTo(asOf) < 0)
    'expired',
];
const comparisonPartition =
    'canonical_product_id,unit_snapshot,currency,tax_mode,min_qty,CASE WHEN tax_mode=\'included\' THEN tax_rate ELSE NULL END';
