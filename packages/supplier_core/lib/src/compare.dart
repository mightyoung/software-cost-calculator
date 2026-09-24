import 'dart:convert';

import 'budget.dart';
import 'store.dart';

/// Why a quotation does not count toward "lowest valid price".
enum QuoteIssue {
  expired, // valid_until before today
  future, // quoted_on after today
  undated, // no quoted_on
  stale, // no valid_until and quoted more than 90 days ago
  taxUnknown,
  supplierDeleted,
}

class CompareRow {
  CompareRow(this.id, this.data, this.issues, {this.lowest = false});
  final String id;
  final Map<String, Object?> data;
  final List<QuoteIssue> issues;
  final bool lowest;
  bool get valid => issues.isEmpty;
  String get price => data['price']! as String;
}

/// Quotes are only comparable within the same currency, tax mode and unit.
class CompareGroup {
  CompareGroup(this.currency, this.taxMode, this.unit, this.rows);
  final String currency, taxMode, unit;
  final List<CompareRow> rows;
}

extension Compare on Store {
  /// Every quotation of a product, grouped by comparable basis. Within a
  /// group valid quotes come first by price and the cheapest is marked.
  List<CompareGroup> compareQuotes(String productId, {DateTime? asOf}) {
    final now = asOf ?? clock();
    final today = now.toIso8601String().substring(0, 10);
    final staleBefore = now
        .subtract(const Duration(days: undatedValidityDays))
        .toIso8601String()
        .substring(0, 10);
    final groups = <String, List<CompareRow>>{};
    for (final r in db.select(
      "SELECT q.id, q.data, coalesce(s.deleted, 1) AS supplier_deleted "
      "FROM quotation q LEFT JOIN supplier s "
      "ON s.id = json_extract(q.data,'\$.supplier_id') "
      "WHERE q.deleted = 0 AND json_extract(q.data,'\$.product_id') = ?",
      [productId],
    )) {
      final d = jsonDecode(r['data'] as String) as Map<String, Object?>;
      final quoted = d['quoted_on'] as String?;
      final until = d['valid_until'] as String?;
      final issues = [
        if (r['supplier_deleted'] == 1) QuoteIssue.supplierDeleted,
        if (d['tax_mode'] == 'unknown') QuoteIssue.taxUnknown,
        if (quoted == null) QuoteIssue.undated,
        if (quoted != null && quoted.compareTo(today) > 0) QuoteIssue.future,
        if (until != null && until.compareTo(today) < 0) QuoteIssue.expired,
        if (until == null &&
            quoted != null &&
            quoted.compareTo(staleBefore) < 0)
          QuoteIssue.stale,
      ];
      final key = '${d['currency']}|${d['tax_mode']}|${d['unit_snapshot']}';
      (groups[key] ??= []).add(CompareRow(r['id'] as String, d, issues));
    }
    int byPrice(CompareRow a, CompareRow b) {
      if (a.valid != b.valid) return a.valid ? -1 : 1;
      return micros(a.price).compareTo(micros(b.price));
    }

    final result = [
      for (final MapEntry(:key, value: rows) in groups.entries)
        () {
          rows.sort(byPrice);
          final parts = key.split('|');
          return CompareGroup(parts[0], parts[1], parts[2], [
            for (var i = 0; i < rows.length; i++)
              CompareRow(
                rows[i].id,
                rows[i].data,
                rows[i].issues,
                lowest: i == 0 && rows[i].valid,
              ),
          ]);
        }(),
    ];
    // Groups with a valid lowest price first, then by size.
    result.sort((a, b) {
      final av = a.rows.first.valid, bv = b.rows.first.valid;
      if (av != bv) return av ? -1 : 1;
      return b.rows.length.compareTo(a.rows.length);
    });
    return result;
  }
}
