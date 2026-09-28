import 'dart:convert';

import 'storage_codec.dart';
import 'store.dart';
import 'values.dart';
import 'pricing.dart';
export 'pricing.dart';

/// Thresholds from the budget design (section six of the review).
const contractWarnPercent = 90;
const cheaperWarnPercent = 10;
const undatedValidityDays = 90;

final _micro = BigInt.from(1000000);

class QuoteOption {
  QuoteOption(
    this.id,
    this.data,
    this.dateValid,
    this.validityPending, {
    this.meetsMinQty = true,
    String? effectivePrice,
    String? price,
    this.converted = false,
    this.tiered = false,
  }) : price = price ?? priceOf(data),
       effectivePrice = effectivePrice ?? price ?? priceOf(data);
  final String id;
  final Map<String, Object?> data;

  /// Quoted on or before today and not expired.
  final bool dateValid;
  final bool validityPending;

  /// The needed quantity reaches the quote's minimum order (true when the
  /// quantity is unknown).
  final bool meetsMinQty;

  /// A formal written quote; verbal and reference prices never price a
  /// budget line.
  bool get formal => data['price_basis'] == null;
  bool get valid => dateValid && meetsMinQty && formal;

  /// Unit price in the target tax basis; the agreed price once awarded.
  final String price;
  String get sourcePrice => priceOf(data);
  final bool converted;

  /// [price] comes from a quantity tier, not the base unit price.
  final bool tiered;

  /// [price] plus tax-normalized extra cost spread over the needed quantity
  /// (equal to [price] when there is no extra cost or no quantity).
  final String effectivePrice;
  bool get awarded => data['awarded_on'] != null;
}

/// A quotation's unit price: the agreed deal price once awarded.
String priceOf(Map<String, Object?> q) =>
    (q['deal_price'] ?? q['price'])! as String;

/// [priceOf] plus extra_cost / [qty], rounded half-up to millionths.
String effectivePriceOf(
  Map<String, Object?> q,
  String? qty, {
  String? price,
  String? extraCost,
}) {
  final unitPrice = price ?? priceOf(q);
  final extra = extraCost ?? q['extra_cost'] as String?;
  if (extra == null || qty == null) return unitPrice;
  final n = micros(qty);
  if (n == BigInt.zero) return unitPrice;
  final share = roundedDivide(micros(extra) * _micro, n);
  return fromMicros(micros(unitPrice) + share);
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
  /// project's currency, normalized to its tax mode. Valid ones first.
  List<QuoteOption> quoteOptions(
    String projectId,
    String productId, {
    DateTime? asOf,
    String? qty,
    String? unit,
  }) {
    final project = get('project', projectId);
    if (project == null) invalid('project_id', 'unknown project');
    return quoteOptionsFor(
      productId,
      currency: project.data['currency']! as String,
      taxMode: project.data['tax_mode']! as String,
      asOf: asOf,
      qty: qty,
      unit: unit,
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
    String? unit,
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
        "AND coalesce(json_extract(s.data,'\$.rating'), '') <> 'disabled' "
        "AND json_extract(q.data,'\$.product_id') = ? "
        "AND json_extract(q.data,'\$.currency') = ?",
        [productId, currency],
      ))
        if (_option(
              r['id'] as String,
              r['data'] as String,
              today,
              undatedFrom,
              qty == null ? null : micros(qty),
              currency,
              taxMode,
              product.data,
              unit ?? product.data['unit']! as String,
            )
            case final option?)
          option,
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

  QuoteOption? _option(
    String id,
    String raw,
    String today,
    String undatedFrom,
    BigInt? qty,
    String currency,
    String taxMode,
    Map<String, Object?> product,
    String unit,
  ) {
    final data = decodeStoredPayload('quotation', raw);
    final priced = qty == null ? data : atQuantity(data, product, unit, qty);
    final price = priceInUnit(
      priced,
      product: product,
      unit: unit,
      currency: currency,
      taxMode: taxMode,
    );
    if (price == null) return null;
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
      price: price,
      converted: data['tax_mode'] != taxMode || data['unit_snapshot'] != unit,
      tiered: !identical(priced, data),
      meetsMinQty:
          qty == null || meetsMinimumQuantity(data, product, unit, qty),
      effectivePrice: effectivePriceOf(
        data,
        qty == null ? null : fromMicros(qty),
        price: price,
        extraCost: data['extra_cost'] == null
            ? null
            : priceInTaxMode(
                {...data, 'price': data['extra_cost'], 'deal_price': null},
                currency: currency,
                taxMode: taxMode,
              ),
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
        final source = get('project', sourceId);
        final target = get('project', id)!;
        if (source == null ||
            source.deleted ||
            source.data['currency'] != target.data['currency'] ||
            source.data['tax_mode'] != target.data['tax_mode']) {
          invalid(
            'project',
            'budget snapshot currency and tax mode must match',
          );
        }
        for (final r in db.select(
          "SELECT id, data FROM project_item WHERE deleted = 0 "
          "AND json_extract(data,'\$.project_id') = ? ORDER BY rowid",
          [sourceId],
        )) {
          final item = jsonDecode(r['data'] as String) as Map<String, Object?>;
          save('project_item', {
            ...item,
            'project_id': id,
          }, snapshotSourceItemId: r['id'] as String);
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
      unit: item['unit']! as String,
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

/// A budget line whose best usable quotation differs from what it uses now.
class RefreshLine {
  RefreshLine(this.itemId, this.item, this.currentCost, this.option);
  final String itemId;
  final Map<String, Object?> item;
  final String currentCost;
  final QuoteOption option;

  /// The deal price once awarded, else the quoted price.
  String get newCost => option.price;

  /// The line holds a hand-entered estimate (no quotation linked).
  bool get manual =>
      item['quotation_id'] == null && micros(currentCost) != BigInt.zero;
}

extension Refresh on Store {
  /// Material lines where the first valid option (awards first, then the
  /// lowest effective price) is not what the line uses. Writes nothing.
  List<RefreshLine> refreshPlan(String projectId, {DateTime? asOf}) => [
    for (final l in budget(projectId, withWarnings: false).lines)
      if (l.data['product_id'] case final String productId)
        if (quoteOptions(
              projectId,
              productId,
              asOf: asOf,
              qty: l.data['qty']! as String,
              unit: l.data['unit']! as String,
            ).where((o) => o.valid).firstOrNull
            case final best?
            when best.id != l.data['quotation_id'] ||
                best.price != l.data['unit_cost'])
          RefreshLine(l.id, l.data, l.data['unit_cost']! as String, best),
  ];

  /// Prices the given lines with their new option in one transaction. An
  /// extra cost is noted on the line; it is not folded into the unit cost.
  void applyRefresh(List<RefreshLine> lines) => transaction(() {
    for (final l in lines) {
      final extra = l.option.data['extra_cost'] as String?;
      final note = extra == null ? null : '另有附加费用 $extra（未计入单价）';
      final notes = [
        for (final n in (l.item['notes'] as String? ?? '').split('；'))
          if (n.isNotEmpty && !n.startsWith('另有附加费用')) n,
        ?note,
      ].join('；');
      save('project_item', {
        ...l.item,
        'quotation_id': l.option.id,
        'unit_cost': l.newCost,
        'notes': notes.isEmpty ? null : notes,
      }, id: l.itemId);
    }
  });
}
