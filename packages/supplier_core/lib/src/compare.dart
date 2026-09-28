import 'dart:convert';

import 'budget.dart';
import 'storage_codec.dart';
import 'store.dart';

/// Why a quotation does not count toward "lowest valid price".
enum QuoteIssue {
  expired, // valid_until before today
  future, // quoted_on after today
  undated, // no quoted_on
  stale, // no valid_until and quoted more than 90 days ago
  taxUnknown,
  supplierDeleted,
  supplierDisabled, // the supplier is rated 停用
  informal, // verbal or reference price
}

/// Why [d] (a quotation payload) is not usable today; empty when it is.
List<QuoteIssue> quoteIssues(
  Map<String, Object?> d, {
  required String today,
  required String staleBefore,
  bool supplierDeleted = false,
  bool supplierDisabled = false,
}) {
  final quoted = d['quoted_on'] as String?;
  final until = d['valid_until'] as String?;
  return [
    if (d['price_basis'] != null) QuoteIssue.informal,
    if (supplierDeleted) QuoteIssue.supplierDeleted,
    if (supplierDisabled) QuoteIssue.supplierDisabled,
    if (d['tax_mode'] == 'unknown') QuoteIssue.taxUnknown,
    if (quoted == null) QuoteIssue.undated,
    if (quoted != null && quoted.compareTo(today) > 0) QuoteIssue.future,
    if (until != null && until.compareTo(today) < 0) QuoteIssue.expired,
    if (until == null && quoted != null && quoted.compareTo(staleBefore) < 0)
      QuoteIssue.stale,
  ];
}

class CompareRow {
  CompareRow(
    this.id,
    this.data,
    this.issues, {
    this.lowest = false,
    String? comparisonPrice,
    this.converted = false,
  }) : comparisonPrice = comparisonPrice ?? priceOf(data);
  final String id;
  final Map<String, Object?> data;
  final List<QuoteIssue> issues;
  final bool lowest;
  bool get valid => issues.isEmpty;

  /// The agreed price once awarded, else the quoted price.
  String get price => priceOf(data);
  final String comparisonPrice;
  final bool converted;
  bool get awarded => data['awarded_on'] != null;
}

/// Quotes share a currency and unit. Known rates normalize excluded prices
/// to included; excluded prices without a rate remain in a separate group.
class CompareGroup {
  CompareGroup(this.currency, this.taxMode, this.unit, this.rows);
  final String currency, taxMode, unit;
  final List<CompareRow> rows;
}

extension Compare on Store {
  /// Every quotation of a product, grouped by comparable basis. Within a
  /// group valid quotes come first by price and the cheapest is marked.
  List<CompareGroup> compareQuotes(String productId, {DateTime? asOf}) {
    final product = get('product', productId)?.data;
    final now = asOf ?? clock();
    final today = now.toIso8601String().substring(0, 10);
    final staleBefore = now
        .subtract(const Duration(days: undatedValidityDays))
        .toIso8601String()
        .substring(0, 10);
    final groups = <String, List<CompareRow>>{};
    for (final r in db.select(
      "SELECT q.id, q.data, coalesce(s.deleted, 1) AS supplier_deleted, "
      "json_extract(s.data,'\$.rating') AS rating "
      "FROM quotation q LEFT JOIN supplier s "
      "ON s.id = json_extract(q.data,'\$.supplier_id') "
      "WHERE q.deleted = 0 AND json_extract(q.data,'\$.product_id') = ?",
      [productId],
    )) {
      final d = decodeStoredPayload('quotation', r['data'] as String);
      final issues = quoteIssues(
        d,
        today: today,
        staleBefore: staleBefore,
        supplierDeleted: r['supplier_deleted'] == 1,
        supplierDisabled: r['rating'] == 'disabled',
      );
      final targetUnit =
          product != null &&
              unitFactor(product, d['unit_snapshot']! as String) != null
          ? product['unit']! as String
          : d['unit_snapshot']! as String;
      final taxPrice = priceInTaxMode(
        d,
        currency: d['currency']! as String,
        taxMode: 'included',
      );
      final targetBasis = taxPrice == null
          ? d['tax_mode']! as String
          : 'included';
      final normalized = priceInUnit(
        d,
        product: product ?? {},
        unit: targetUnit,
        currency: d['currency']! as String,
        taxMode: targetBasis,
      );
      // A rejected conversion must retain the source price's own labels.
      final unit = normalized == null
          ? d['unit_snapshot']! as String
          : targetUnit;
      final basis = normalized == null ? d['tax_mode']! as String : targetBasis;
      final key = '${d['currency']}|$basis|$unit';
      (groups[key] ??= []).add(
        CompareRow(
          r['id'] as String,
          d,
          issues,
          comparisonPrice: normalized,
          converted:
              normalized != null &&
              (basis != d['tax_mode'] || unit != d['unit_snapshot']),
        ),
      );
    }
    int byPrice(CompareRow a, CompareRow b) {
      if (a.valid != b.valid) return a.valid ? -1 : 1;
      return micros(a.comparisonPrice).compareTo(micros(b.comparisonPrice));
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
                comparisonPrice: rows[i].comparisonPrice,
                converted: rows[i].converted,
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

/// Price summary of one product in one comparable basis (currency, tax
/// mode, unit). Awarded quotations count at their deal price.
class PriceHistory {
  PriceHistory(this.count, this.min, this.max, this.average, this.lastDeal);
  final int count;
  final String min, max, average;
  final String? lastDeal;

  /// How far [price] is from [average], in whole percent (half away from
  /// zero).
  int deviationPercent(String price) {
    final avg = micros(average);
    if (avg == BigInt.zero) return 0;
    final diff = (micros(price) - avg) * BigInt.from(200);
    final q = (diff.abs() + avg) ~/ (avg * BigInt.two);
    return (diff.isNegative ? -q : q).toInt();
  }
}

/// Deviation from the average at which a price is called out.
const historyWarnPercent = 20;

extension History on Store {
  PriceHistory? priceHistory(
    String productId, {
    required String currency,
    required String taxMode,
    required String unit,
    bool forCompareGroup = false,
  }) {
    final product = get('product', productId)?.data ?? <String, Object?>{};
    final prices = <BigInt>[];
    String? lastDeal, lastDealOn;
    for (final r in db.select(
      "SELECT data FROM quotation WHERE deleted = 0 "
      "AND json_extract(data,'\$.product_id') = ? "
      "AND json_extract(data,'\$.currency') = ?",
      [productId, currency],
    )) {
      final d = jsonDecode(r['data'] as String) as Map<String, Object?>;
      // Comparison groups normalize to included whenever possible; a separate
      // excluded group contains only quotations lacking a conversion rate.
      if (forCompareGroup) {
        final included = priceInTaxMode(
          d,
          currency: currency,
          taxMode: 'included',
        );
        final groupMode = included == null ? d['tax_mode'] : 'included';
        if (groupMode != taxMode) continue;
      }
      final normalized = priceInUnit(
        d,
        product: product,
        unit: unit,
        currency: currency,
        taxMode: taxMode,
      );
      if (normalized == null) continue;
      prices.add(micros(normalized));
      final on = d['awarded_on'] as String?;
      if (on != null && (lastDealOn == null || on.compareTo(lastDealOn) > 0)) {
        lastDealOn = on;
        lastDeal = normalized;
      }
    }
    if (prices.isEmpty) return null;
    prices.sort();
    final n = BigInt.from(prices.length);
    final sum = prices.fold(BigInt.zero, (a, b) => a + b);
    return PriceHistory(
      prices.length,
      fromMicros(prices.first),
      fromMicros(prices.last),
      fromMicros(roundedDivide(sum, n)),
      lastDeal,
    );
  }
}
