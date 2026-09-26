import 'dart:convert';
import 'dart:typed_data';

import 'budget.dart';
import 'compare.dart';
import 'entities.dart';
import 'inquiry.dart';
import 'quotation.dart';
import 'store.dart';
import 'values.dart';
import 'xlsx.dart';

/// Who records quotations and on which day (defaults to the store clock).
typedef QuoteContext = ({String inquirer, DateTime? asOf});

class InquiryCell {
  InquiryCell(
    this.quotationId,
    this.data,
    this.effectivePrice, {
    required this.valid,
    required this.comparable,
    this.lowest = false,
    this.deviation,
  });
  final String quotationId;
  final Map<String, Object?> data;
  final String effectivePrice;

  /// In date and meets the minimum order.
  final bool valid;

  /// Same currency, tax mode and unit as the project and the material.
  final bool comparable;
  final bool lowest;

  /// Percent from the material's historical average, when there is enough
  /// history (at least three prices).
  final int? deviation;
  bool get awarded => data['awarded_on'] != null;

  InquiryCell _asLowest() => InquiryCell(
    quotationId,
    data,
    effectivePrice,
    valid: valid,
    comparable: comparable,
    lowest: true,
    deviation: deviation,
  );
}

class InquiryRow {
  InquiryRow(this.itemId, this.item, this.cells);
  final String itemId;
  final Map<String, Object?> item;

  /// One per supplier of the inquiry, in the same order; null = no quote.
  final List<InquiryCell?> cells;
}

class InquiryMatrix {
  InquiryMatrix(this.inquiry, this.suppliers, this.rows, this.answered);
  final Map<String, Object?> inquiry;
  final List<String> suppliers;
  final List<InquiryRow> rows;

  /// How many lines each supplier has quoted.
  final Map<String, int> answered;
}

class InquiryRowPlan {
  InquiryRowPlan(this.row, this.itemId, this.price, this.fields, {this.error});
  final int row;
  final String? itemId, price, error;

  /// Optional quotation fields read from the sheet.
  final Map<String, Object?> fields;
}

/// Sheet columns sent to suppliers. The last column carries the line id so
/// a returned sheet maps back even if lines were reordered.
const inquirySheetColumns = [
  '行号',
  '名称',
  '品牌型号',
  '规格要求',
  '数量',
  '单位',
  '单价',
  '含税',
  '税率(%)',
  '附加费用',
  '交期(天)',
  '有效期至',
  '包含项',
  '质保(月)',
  '备注',
  '行ID',
];

const _includeWords = {
  'freight': ['运输', '运费', '送货', '物流'],
  'installation': ['安装'],
  'commissioning': ['调试'],
  'training': ['培训'],
};

/// "含运输、安装，不含调试" -> [freight, installation]; blank -> null.
List<String>? parseIncludes(String? text) {
  if (text == null || text.trim().isEmpty) return null;
  final found = <String>{};
  for (final token in text.split(RegExp(r'[，,、;；/\s]+'))) {
    if (token.startsWith('不') || token.startsWith('无')) continue;
    for (final MapEntry(key: code, value: words) in _includeWords.entries) {
      if (words.any(token.contains)) found.add(code);
    }
  }
  return [
    for (final c in quoteIncludes)
      if (found.contains(c)) c,
  ];
}

extension Inquiries on Store {
  /// A project's live inquiries, newest first.
  List<({String id, Map<String, Object?> data})> inquiriesOf(
    String projectId,
  ) => [
    for (final r in db.select(
      "SELECT id, data FROM inquiry WHERE deleted = 0 "
      "AND json_extract(data,'\$.project_id') = ? ORDER BY rowid DESC",
      [projectId],
    ))
      (
        id: r['id'] as String,
        data: jsonDecode(r['data'] as String) as Map<String, Object?>,
      ),
  ];

  String createInquiry(
    String projectId,
    String title, {
    required List<String> itemIds,
    required List<String> supplierIds,
    String? dueDate,
    String? notes,
  }) => save('inquiry', {
    'project_id': projectId,
    'title': title,
    'item_ids': itemIds,
    'supplier_ids': supplierIds,
    'due_date': dueDate,
    'status': 'open',
    'notes': notes,
  });

  /// The material of a budget line; a line known only by name gets a new
  /// material (its name and unit) so quotations can refer to it.
  String _productFor(String itemId) {
    final item = get('project_item', itemId);
    if (item == null || item.deleted) invalid('item_ids', 'unknown line');
    final existing = item.data['product_id'] as String?;
    if (existing != null) return existing;
    final product = save('product', {
      for (final f in Product.fields) f: null,
      'name': item.data['name'],
      'unit': item.data['unit'],
    });
    save('project_item', {
      ...item.data,
      'product_id': product,
      'name': null,
    }, id: itemId);
    return product;
  }

  Map<String, Object?>? _cellQuote(
    String inquiryId,
    String supplierId,
    String productId,
  ) {
    final rows = db.select(
      "SELECT id, data FROM quotation WHERE deleted = 0 "
      "AND json_extract(data,'\$.inquiry_id') = ? "
      "AND json_extract(data,'\$.supplier_id') = ? "
      "AND json_extract(data,'\$.product_id') = ? "
      "ORDER BY json_extract(data,'\$.quoted_on') DESC, rowid DESC LIMIT 1",
      [inquiryId, supplierId, productId],
    );
    if (rows.isEmpty) return null;
    return {
      'id': rows.first['id'],
      ...jsonDecode(rows.first['data'] as String) as Map<String, Object?>,
    };
  }

  /// Records (or revises) [supplierId]'s quotation for one line of the
  /// inquiry. Returns the quotation id.
  String quoteForInquiry(
    String inquiryId,
    String itemId,
    String supplierId, {
    required String price,
    required QuoteContext context,
    String taxMode = 'included',
    String? taxRate,
    String? extraCost,
    List<String>? includes,
    int? leadTimeDays,
    String? validUntil,
    int? warrantyMonths,
    String? notes,
    List<String>? attachmentIds,
  }) => transaction(() {
    final inquiry = get('inquiry', inquiryId)?.data;
    if (inquiry == null) invalid('inquiry_id', 'unknown inquiry');
    if (!(inquiry['item_ids']! as List).contains(itemId)) {
      invalid('item_ids', 'line is not part of this inquiry');
    }
    if (!(inquiry['supplier_ids']! as List).contains(supplierId)) {
      invalid('supplier_ids', 'supplier is not invited');
    }
    final project = get('project', inquiry['project_id']! as String)!.data;
    final productId = _productFor(itemId);
    final unit = get('product', productId)!.data['unit'];
    final today = localDay(context.asOf ?? clock());
    final previous = _cellQuote(inquiryId, supplierId, productId);
    final fields = {
      'price': price,
      'tax_mode': taxMode,
      'tax_rate': taxRate,
      'extra_cost': extraCost,
      'includes': includes,
      'lead_time_days': leadTimeDays,
      'valid_until': validUntil,
      'warranty_months': warrantyMonths,
      'notes': notes,
      'attachment_ids': attachmentIds,
    };
    if (previous != null) {
      final id = previous.remove('id')! as String;
      return save(
        'quotation',
        {...previous, ...fields, 'quoted_on': today},
        id: id,
        allowClear: true,
      );
    }
    return save('quotation', {
      for (final f in Quotation.fields) f: null,
      ...fields,
      'supplier_id': supplierId,
      'product_id': productId,
      'currency': project['currency'],
      'unit_snapshot': unit,
      'min_qty': '1',
      'quoted_on': today,
      'project_id': inquiry['project_id'],
      'inquiry_id': inquiryId,
      'inquirer_name': context.inquirer,
      'inquiry_precision': 'date',
      'inquiry_date': today,
      'capture_mode': 'standard',
    });
  });

  InquiryMatrix inquiryMatrix(String inquiryId, {DateTime? asOf}) {
    final inquiry = get('inquiry', inquiryId)?.data;
    if (inquiry == null) invalid('inquiry_id', 'unknown inquiry');
    final project = get('project', inquiry['project_id']! as String)!.data;
    final suppliers = (inquiry['supplier_ids']! as List).cast<String>();
    final answered = {for (final s in suppliers) s: 0};
    final rows = <InquiryRow>[];
    for (final itemId in (inquiry['item_ids']! as List).cast<String>()) {
      final item = get('project_item', itemId);
      if (item == null || item.deleted) continue;
      final productId = item.data['product_id'] as String?;
      final qty = item.data['qty']! as String;
      final options = productId == null
          ? const <QuoteOption>[]
          : quoteOptionsFor(
              productId,
              currency: project['currency']! as String,
              taxMode: project['tax_mode']! as String,
              asOf: asOf,
              qty: qty,
              projectId: inquiry['project_id'] as String,
            );
      final history = productId == null
          ? null
          : priceHistory(
              productId,
              currency: project['currency']! as String,
              taxMode: project['tax_mode']! as String,
              unit: get('product', productId)!.data['unit']! as String,
            );
      final cells = <InquiryCell?>[
        for (final supplierId in suppliers)
          if (productId == null)
            null
          else if (_cellQuote(inquiryId, supplierId, productId) case final q?)
            () {
              answered[supplierId] = answered[supplierId]! + 1;
              final id = q['id']! as String;
              final option = options.where((o) => o.id == id).firstOrNull;
              return InquiryCell(
                id,
                q,
                option?.effectivePrice ?? effectivePriceOf(q, qty),
                valid: option?.valid ?? false,
                comparable: option != null,
                deviation: history != null && history.count >= 3
                    ? history.deviationPercent(priceOf(q))
                    : null,
              );
            }()
          else
            null,
      ];
      final best = cells
          .whereType<InquiryCell>()
          .where((c) => c.valid)
          .fold<InquiryCell?>(
            null,
            (m, c) =>
                m == null || micros(c.effectivePrice) < micros(m.effectivePrice)
                ? c
                : m,
          );
      rows.add(
        InquiryRow(itemId, item.data, [
          for (final c in cells) c != null && c == best ? c._asLowest() : c,
        ]),
      );
    }
    return InquiryMatrix(inquiry, suppliers, rows, answered);
  }

  /// Awards [quotationId] at [dealPrice] (default: its quoted price). With
  /// [itemId], that budget line is priced with the award.
  void award(
    String quotationId, {
    String? itemId,
    String? dealPrice,
    String? note,
    DateTime? on,
  }) => transaction(() {
    final quote = get('quotation', quotationId);
    if (quote == null || quote.deleted) invalid('id', 'record does not exist');
    final deal = dealPrice ?? quote.data['price']! as String;
    save('quotation', {
      ...quote.data,
      'deal_price': deal,
      'awarded_on': localDay(on ?? clock()),
      'award_note': note,
    }, id: quotationId);
    if (itemId == null) return;
    final item = get('project_item', itemId);
    if (item == null || item.deleted) invalid('id', 'record does not exist');
    save('project_item', {
      ...item.data,
      'product_id': quote.data['product_id'],
      'name': null,
      'quotation_id': quotationId,
      'unit_cost': get('quotation', quotationId)!.data['deal_price'],
    }, id: itemId);
  });

  void withdrawAward(String quotationId) => transaction(() {
    final quote = get('quotation', quotationId);
    if (quote == null || quote.deleted) invalid('id', 'record does not exist');
    save(
      'quotation',
      {
        ...quote.data,
        'deal_price': null,
        'awarded_on': null,
        'award_note': null,
      },
      id: quotationId,
      allowClear: true,
    );
  });

  /// The sheet one supplier fills in: the inquiry's lines, blank price
  /// columns, and the line id for mapping the returned file back.
  Uint8List exportInquirySheet(String inquiryId, String supplierId) {
    final inquiry = get('inquiry', inquiryId)!.data;
    final project = get('project', inquiry['project_id']! as String)!.data;
    final rows = <List<Object?>>[
      ['询价单', inquiry['title']],
      ['项目', '${project['name']}（${project['code']}）'],
      ['供应商', get('supplier', supplierId)?.data['name']],
      ['报价截止', inquiry['due_date'] ?? '尽快'],
      ['说明', '请填写"单价"及以后各列；"含税"填 含税 或 不含税；"包含项"如：运输、安装、调试'],
      [],
      inquirySheetColumns,
    ];
    var n = 0;
    for (final itemId in (inquiry['item_ids']! as List).cast<String>()) {
      final item = get('project_item', itemId);
      if (item == null || item.deleted) continue;
      final p = item.data['product_id'] == null
          ? null
          : get('product', item.data['product_id']! as String)?.data;
      final notes = item.data['notes'] as String?;
      rows.add([
        Num('${++n}'),
        p?['name'] ?? item.data['name'],
        [p?['brand'], p?['model']].whereType<String>().join(' '),
        [
          p?['specification'],
          if (notes != null && notes.startsWith('要求：')) notes.substring(3),
        ].whereType<String>().join('；'),
        Num(item.data['qty']! as String),
        item.data['unit'],
        for (var i = 0; i < 9; i++) null,
        itemId,
      ]);
    }
    return writeXlsx([
      SheetData(
        '询价',
        rows,
        widths: [6, 22, 18, 30, 8, 6, 12, 8, 8, 10, 8, 12, 16, 8, 20, 38],
        boldRows: {6},
      ),
    ]);
  }

  /// Reads a returned sheet; rows without a price are skipped. Writes
  /// nothing.
  List<InquiryRowPlan> planInquirySheet(
    Uint8List bytes,
    String inquiryId,
    String supplierId,
  ) {
    final inquiry = get('inquiry', inquiryId)!.data;
    final lines = (inquiry['item_ids']! as List).cast<String>();
    final book = readXlsx(bytes);
    for (final sheet in book.sheets) {
      final h = sheet.rows.indexWhere(
        (r) => r.any((c) => c.display.trim() == '单价'),
      );
      if (h < 0) continue;
      final col = {
        for (var i = 0; i < sheet.rows[h].length; i++)
          sheet.rows[h][i].display.trim(): i,
      };
      final plans = <InquiryRowPlan>[];
      for (var r = h + 1; r < sheet.rows.length; r++) {
        final cells = sheet.rows[r];
        XCell cell(String name) {
          final i = col[name];
          return i == null || i >= cells.length
              ? const XCell('', CellKind.blank, '')
              : cells[i];
        }

        if (cell('单价').isBlank) continue;
        final lineId = cell('行ID').text();
        final itemId = lineId != null && lines.contains(lineId) ? lineId : null;
        try {
          if (itemId == null) invalid('行ID', '不是这张询价单的行');
          final tax = cell('含税').text();
          final lead = cell('交期(天)').decimal();
          final warranty = cell('质保(月)').decimal();
          plans.add(
            InquiryRowPlan(r + 1, itemId, cell('单价').decimal(), {
              'tax_mode': tax == null
                  ? 'unknown'
                  : tax.startsWith('不')
                  ? 'excluded'
                  : 'included',
              'tax_rate': cell('税率(%)').decimal(),
              'extra_cost': cell('附加费用').decimal(),
              'lead_time_days': lead == null ? null : num.parse(lead).toInt(),
              'valid_until': cell('有效期至').date(date1904: book.date1904),
              'includes': parseIncludes(cell('包含项').text()),
              'warranty_months': warranty == null
                  ? null
                  : num.parse(warranty).toInt(),
              'notes': cell('备注').text(),
            }),
          );
        } on FormatException catch (e) {
          plans.add(InquiryRowPlan(r + 1, itemId, null, {}, error: e.message));
        }
      }
      return plans;
    }
    invalid('file', '没有找到询价单表头（需要"单价"列）');
  }

  /// Records every error-free planned row; returns how many.
  int applyInquirySheet(
    String inquiryId,
    String supplierId,
    List<InquiryRowPlan> plans, {
    required String inquirer,
    List<String>? attachmentIds,
  }) => transaction(() {
    var n = 0;
    for (final p in plans) {
      if (p.error != null || p.itemId == null || p.price == null) continue;
      final f = p.fields;
      quoteForInquiry(
        inquiryId,
        p.itemId!,
        supplierId,
        price: p.price!,
        context: (inquirer: inquirer, asOf: null),
        taxMode: f['tax_mode']! as String,
        taxRate: f['tax_rate'] as String?,
        extraCost: f['extra_cost'] as String?,
        includes: (f['includes'] as List?)?.cast<String>(),
        leadTimeDays: f['lead_time_days'] as int?,
        validUntil: f['valid_until'] as String?,
        warrantyMonths: f['warranty_months'] as int?,
        notes: f['notes'] as String?,
        attachmentIds: attachmentIds,
      );
      n++;
    }
    return n;
  });
}
