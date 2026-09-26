import 'dart:convert';

import 'store.dart';
import 'values.dart';

/// Thresholds from the budget design (section six of the review).
const contractWarnPercent = 90;
const cheaperWarnPercent = 10;
const undatedValidityDays = 90;

final _micro = BigInt.from(1000000);

/// Decimal text (<= 6 fraction digits) to integer millionths.
BigInt micros(String decimal) {
  final parts = decimal.split('.');
  final fraction = (parts.length > 1 ? parts[1] : '').padRight(6, '0');
  return BigInt.parse(parts[0]) * _micro + BigInt.parse(fraction);
}

String fromMicros(BigInt value) {
  final sign = value.isNegative ? '-' : '';
  final abs = value.abs();
  final fraction = (abs % _micro)
      .toString()
      .padLeft(6, '0')
      .replaceFirst(RegExp(r'0+$'), '');
  return '$sign${abs ~/ _micro}${fraction.isEmpty ? '' : '.$fraction'}';
}

/// Product of two non-negative millionth values, rounded half-up.
BigInt multiply(BigInt a, BigInt b) => (a * b + _micro ~/ BigInt.two) ~/ _micro;

class QuoteOption {
  QuoteOption(
    this.id,
    this.data,
    this.dateValid,
    this.validityPending, {
    this.meetsMinQty = true,
    String? effectivePrice,
  }) : effectivePrice = effectivePrice ?? priceOf(data);
  final String id;
  final Map<String, Object?> data;

  /// Quoted on or before today and not expired.
  final bool dateValid;
  final bool validityPending;

  /// The needed quantity reaches the quote's minimum order (true when the
  /// quantity is unknown).
  final bool meetsMinQty;
  bool get valid => dateValid && meetsMinQty;

  /// Unit price to budget with: the agreed price once awarded.
  String get price => priceOf(data);

  /// [price] plus the quote's extra cost spread over the needed quantity
  /// (equal to [price] when there is no extra cost or no quantity).
  final String effectivePrice;
  bool get awarded => data['awarded_on'] != null;
}

/// A quotation's unit price: the agreed deal price once awarded.
String priceOf(Map<String, Object?> q) =>
    (q['deal_price'] ?? q['price'])! as String;

/// [priceOf] plus extra_cost / [qty], rounded half-up to millionths.
String effectivePriceOf(Map<String, Object?> q, String? qty) {
  final extra = q['extra_cost'] as String?;
  if (extra == null || qty == null) return priceOf(q);
  final n = micros(qty);
  if (n == BigInt.zero) return priceOf(q);
  final share = (micros(extra) * _micro * BigInt.two + n) ~/ (n * BigInt.two);
  return fromMicros(micros(priceOf(q)) + share);
}

class BudgetLine {
  BudgetLine(
    this.id,
    this.data,
    this.unitPrice,
    this.cost,
    this.price,
    this.warnings,
  );
  final String id;
  final Map<String, Object?> data;
  final String unitPrice, cost, price;
  final List<String> warnings;
}

class Budget {
  Budget(
    this.lines,
    this.costByCategory,
    this.cost,
    this.price,
    this.margin,
    this.contractWarning,
  );
  final List<BudgetLine> lines;
  final Map<String, String> costByCategory;
  final String cost, price, margin;
  final bool contractWarning;
}

String _date(DateTime d) => d.toIso8601String().substring(0, 10);

extension Budgets on Store {
  /// Quotations usable for a budget line: same product and unit, in the
  /// project's currency and tax mode. Valid ones first, then by price.
  List<QuoteOption> quoteOptions(
    String projectId,
    String productId, {
    DateTime? asOf,
    String? qty,
  }) {
    final project = get('project', projectId);
    if (project == null) invalid('project_id', 'unknown project');
    return quoteOptionsFor(
      productId,
      currency: project.data['currency']! as String,
      taxMode: project.data['tax_mode']! as String,
      asOf: asOf,
      qty: qty,
      projectId: projectId,
    );
  }

  /// Quotations usable for a budget line: same product and unit, in the
  /// given currency and tax mode. Valid ones first: an award for
  /// [projectId], then awards elsewhere, then by effective price. With
  /// [qty], a quote whose minimum order exceeds it is not valid.
  List<QuoteOption> quoteOptionsFor(
    String productId, {
    required String currency,
    required String taxMode,
    DateTime? asOf,
    String? qty,
    String? projectId,
  }) {
    final product = get('product', productId);
    if (product == null) invalid('product_id', 'unknown product');
    final today = _date(asOf ?? clock());
    final undatedFrom = _date(
      (asOf ?? clock()).subtract(const Duration(days: undatedValidityDays)),
    );
    final options = [
      for (final r in db.select(
        "SELECT q.id, q.data FROM quotation q "
        "JOIN supplier s ON s.id = json_extract(q.data,'\$.supplier_id') "
        "WHERE q.deleted = 0 AND s.deleted = 0 "
        "AND json_extract(q.data,'\$.product_id') = ? "
        "AND json_extract(q.data,'\$.currency') = ? "
        "AND json_extract(q.data,'\$.tax_mode') = ? "
        "AND json_extract(q.data,'\$.unit_snapshot') = ?",
        [productId, currency, taxMode, product.data['unit']],
      ))
        _option(
          r['id'] as String,
          r['data'] as String,
          today,
          undatedFrom,
          qty == null ? null : micros(qty),
        ),
    ];
    int rank(QuoteOption o) => !o.valid
        ? 3
        : !o.awarded
        ? 2
        : o.data['project_id'] == projectId
        ? 0
        : 1;
    options.sort((a, b) {
      final r = rank(a).compareTo(rank(b));
      if (r != 0) return r;
      return micros(a.effectivePrice).compareTo(micros(b.effectivePrice));
    });
    return options;
  }

  QuoteOption _option(
    String id,
    String raw,
    String today,
    String undatedFrom,
    BigInt? qty,
  ) {
    final data = jsonDecode(raw) as Map<String, Object?>;
    final quoted = data['quoted_on'] as String?;
    final until = data['valid_until'] as String?;
    final current = quoted == null || quoted.compareTo(today) <= 0;
    final valid = until != null
        ? current && until.compareTo(today) >= 0
        : quoted != null && current && quoted.compareTo(undatedFrom) >= 0;
    return QuoteOption(
      id,
      data,
      valid,
      until == null,
      meetsMinQty: qty == null || micros(data['min_qty']! as String) <= qty,
      effectivePrice: effectivePriceOf(
        data,
        qty == null ? null : fromMicros(qty),
      ),
    );
  }

  /// [withWarnings] false skips per-line quote lookups (list screens only
  /// need totals).
  Budget budget(String projectId, {DateTime? asOf, bool withWarnings = true}) {
    final project = get('project', projectId);
    if (project == null) invalid('project_id', 'unknown project');
    final factor =
        BigInt.from(100) * _micro +
        micros(project.data['markup_rate']! as String);
    final lines = <BudgetLine>[];
    final byCategory = <String, BigInt>{};
    var cost = BigInt.zero, price = BigInt.zero;
    for (final r in db.select(
      "SELECT id, data FROM project_item WHERE deleted = 0 "
      "AND json_extract(data,'\$.project_id') = ? ORDER BY rowid",
      [projectId],
    )) {
      final data = jsonDecode(r['data'] as String) as Map<String, Object?>;
      final qty = micros(data['qty']! as String);
      final unitCost = micros(data['unit_cost']! as String);
      final unitPrice = data['unit_price'] == null
          ? (unitCost * factor + BigInt.from(50) * _micro) ~/
                (BigInt.from(100) * _micro)
          : micros(data['unit_price']! as String);
      final lineCost = multiply(qty, unitCost);
      final linePrice = multiply(qty, unitPrice);
      cost += lineCost;
      price += linePrice;
      final category = data['category']! as String;
      byCategory[category] = (byCategory[category] ?? BigInt.zero) + lineCost;
      lines.add(
        BudgetLine(
          r['id'] as String,
          data,
          fromMicros(unitPrice),
          fromMicros(lineCost),
          fromMicros(linePrice),
          withWarnings ? _warnings(projectId, data, unitCost, asOf) : const [],
        ),
      );
    }
    final contract = project.data['contract_amount'] as String?;
    return Budget(
      lines,
      {for (final e in byCategory.entries) e.key: fromMicros(e.value)},
      fromMicros(cost),
      fromMicros(price),
      fromMicros(price - cost),
      contract != null &&
          cost * BigInt.from(100) >=
              micros(contract) * BigInt.from(contractWarnPercent),
    );
  }

  /// New project seeded with a copy of another project's budget lines.
  String copyProject(String sourceId, Map<String, Object?> project) =>
      transaction(() {
        final id = save('project', project);
        for (final r in db.select(
          "SELECT data FROM project_item WHERE deleted = 0 "
          "AND json_extract(data,'\$.project_id') = ? ORDER BY rowid",
          [sourceId],
        )) {
          final item = jsonDecode(r['data'] as String) as Map<String, Object?>;
          save('project_item', {...item, 'project_id': id});
        }
        return id;
      });

  List<String> _warnings(
    String projectId,
    Map<String, Object?> item,
    BigInt unitCost,
    DateTime? asOf,
  ) {
    final productId = item['product_id'] as String?;
    if (productId == null) {
      return item['category'] == 'material'
          ? const ['needs_inquiry']
          : const [];
    }
    final options = quoteOptions(
      projectId,
      productId,
      asOf: asOf,
      qty: item['qty']! as String,
    );
    final chosen = item['quotation_id'] as String?;
    final picked = options.where((o) => o.id == chosen).firstOrNull;
    final cheapest = options
        .where((o) => o.valid)
        .map((o) => micros(o.effectivePrice))
        .fold<BigInt?>(null, (m, p) => m == null || p < m ? p : m);
    return [
      if (cheapest != null &&
          cheapest * BigInt.from(100) <
              unitCost * BigInt.from(100 - cheaperWarnPercent))
        'cheaper_available',
      if (chosen != null && !(picked?.dateValid ?? false)) 'quote_not_valid',
      if (picked != null && !picked.meetsMinQty) 'below_min_qty',
    ];
  }
}
