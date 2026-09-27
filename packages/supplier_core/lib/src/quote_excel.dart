import 'dart:convert';
import 'dart:typed_data';

import 'quotation.dart';
import 'search.dart';
import 'store.dart';
import 'values.dart';
import 'xlsx.dart';

/// Template columns. The record ID and version make edits round-trip: a row
/// with an ID updates that record; blank cells keep the current value.
const quoteColumns = [
  '记录ID',
  '版本',
  '项目编号',
  '供应商',
  '物料名称',
  '品牌',
  '型号',
  '规格',
  '单位',
  '单价',
  '币种',
  '税制',
  '税率(%)',
  '起订量',
  '报价日期',
  '有效期至',
  '交期(天)',
  '询价人',
  '询价日期',
  '询价地点',
  '备注',
];

const _taxLabels = {'included': '含税', 'excluded': '不含税', 'unknown': '未知'};

enum RowAction { create, update, unchanged, duplicate, error }

class QuoteRowPlan {
  QuoteRowPlan(
    this.row,
    this.action, {
    this.id,
    this.payload,
    this.changedFields = const [],
    this.changedSinceExport = false,
    this.error,
  });
  final int row; // 1-based Excel row number
  final RowAction action;
  final String? id, error;
  final Map<String, Object?>? payload;
  final List<String> changedFields;

  /// The local record was edited after this file was exported.
  final bool changedSinceExport;
}

extension QuoteExcel on Store {
  Uint8List exportQuotations({
    String? projectId,
    String? productId,
    String? supplierId,
  }) {
    final rows = <List<Object?>>[quoteColumns];
    for (final h in listQuotations(
      projectId: projectId,
      productId: productId,
      supplierId: supplierId,
      limit: 1000000,
    )) {
      final q = h.data;
      final p = get('product', q['product_id']! as String)!.data;
      rows.add([
        h.id,
        '${get('quotation', h.id)!.version}',
        q['project_id'] == null
            ? null
            : get('project', q['project_id']! as String)?.data['code'],
        get('supplier', q['supplier_id']! as String)?.data['name'],
        p['name'],
        p['brand'],
        p['model'],
        p['specification'],
        q['unit_snapshot'],
        Num(q['price']! as String),
        q['currency'],
        _taxLabels[q['tax_mode']],
        q['tax_rate'] == null ? null : Num(q['tax_rate']! as String),
        Num(q['min_qty']! as String),
        q['quoted_on'],
        q['valid_until'],
        q['lead_time_days'] == null ? null : Num('${q['lead_time_days']}'),
        q['inquirer_name'],
        q['inquiry_date'],
        q['inquiry_location'],
        q['notes'],
      ]);
    }
    return writeXlsx([
      SheetData(
        '报价',
        rows,
        widths: [
          38,
          6,
          16,
          20,
          20,
          12,
          16,
          24,
          6,
          12,
          6,
          8,
          8,
          8,
          12,
          12,
          8,
          10,
          12,
          16,
          24,
        ],
        boldRows: {0},
      ),
    ]);
  }

  /// Reads a template workbook and plans every row. Writes nothing.
  List<QuoteRowPlan> planQuotationImport(Uint8List bytes) {
    final book = readXlsx(bytes);
    for (final sheet in book.sheets) {
      for (var h = 0; h < sheet.rows.length && h < 10; h++) {
        final names = [for (final c in sheet.rows[h]) c.display.trim()];
        if (!names.contains('物料名称') || !names.contains('单价')) continue;
        final col = {for (var i = 0; i < names.length; i++) names[i]: i};
        return [
          for (var r = h + 1; r < sheet.rows.length; r++)
            if (sheet.rows[r].any((c) => !c.isBlank))
              _planRow(r + 1, sheet.rows[r], col, book.date1904),
        ];
      }
    }
    invalid('file', '没有找到报价模板表头（需要“物料名称”“单价”等列）');
  }

  /// Saves create/update rows in one transaction; returns how many were saved.
  int applyQuotationImport(List<QuoteRowPlan> plans) => transaction(() {
    var saved = 0;
    for (final p in plans) {
      if (p.action == RowAction.create) {
        save('quotation', p.payload!);
      } else if (p.action == RowAction.update) {
        save('quotation', p.payload!, id: p.id);
      } else {
        continue;
      }
      saved++;
    }
    return saved;
  });

  QuoteRowPlan _planRow(
    int row,
    List<XCell> cells,
    Map<String, int> col,
    bool date1904,
  ) {
    XCell cell(String name) {
      final i = col[name];
      return i == null || i >= cells.length
          ? XCell('', CellKind.blank, '')
          : cells[i];
    }

    try {
      final id = cell('记录ID').text();
      final existing = id == null
          ? null
          : get('quotation', requireUuid(id, '记录ID'));
      if (id != null && (existing == null || existing.deleted)) {
        invalid('记录ID', '本机没有这条报价');
      }
      final base = existing?.data ?? _newQuotation();
      final data = Map<String, Object?>.of(base);
      void set(String key, Object? value) {
        if (value != null) data[key] = value;
      }

      final supplier = cell('供应商').text();
      if (supplier != null) set('supplier_id', _supplierId(supplier));
      final product = _productId(cell, existing == null);
      set('product_id', product);
      final code = cell('项目编号').text();
      if (code != null) set('project_id', _projectId(code));
      set('unit_snapshot', cell('单位').text());
      set('price', cell('单价').decimal());
      set('currency', cell('币种').text()?.toUpperCase());
      final tax = cell('税制').text();
      if (tax != null) {
        set(
          'tax_mode',
          _taxLabels.entries
              .firstWhere(
                (e) => e.value == tax,
                orElse: () => invalid('税制', '应为 含税/不含税/未知'),
              )
              .key,
        );
      }
      set('tax_rate', cell('税率(%)').decimal());
      set('min_qty', cell('起订量').decimal(positive: true));
      set('quoted_on', cell('报价日期').date(date1904: date1904));
      set('valid_until', cell('有效期至').date(date1904: date1904));
      final lead = cell('交期(天)').decimal();
      if (lead != null)
        set(
          'lead_time_days',
          requireSafeInteger(num.parse(lead), '交期(天)', min: 0, max: 36500),
        );
      set('inquirer_name', cell('询价人').text());
      final inquiry = cell('询价日期').date(date1904: date1904);
      if (inquiry != null && inquiry != base['inquiry_date']) {
        data.addAll({
          'inquiry_precision': 'date',
          'inquiry_date': inquiry,
          'inquired_at': null,
          'inquiry_utc_offset_minutes': null,
        });
      }
      set('inquiry_location', cell('询价地点').text());
      set('notes', cell('备注').text());
      if (data['unit_snapshot'] == null && data['product_id'] != null) {
        data['unit_snapshot'] = get(
          'product',
          data['product_id']! as String,
        )?.data['unit'];
      }
      final payload = validatePayload('quotation', data);

      if (existing == null) {
        return QuoteRowPlan(
          row,
          _isDuplicate(payload) ? RowAction.duplicate : RowAction.create,
          payload: payload,
        );
      }
      final changed = [
        for (final k in payload.keys)
          if (jsonEncode(payload[k]) != jsonEncode(existing.data[k])) k,
      ];
      final version = cell('版本').text();
      return QuoteRowPlan(
        row,
        changed.isEmpty ? RowAction.unchanged : RowAction.update,
        id: existing.id,
        payload: payload,
        changedFields: changed,
        changedSinceExport: version != null && version != '${existing.version}',
      );
    } on FormatException catch (e) {
      return QuoteRowPlan(row, RowAction.error, error: e.message);
    }
  }

  Map<String, Object?> _newQuotation() => {
    for (final f in Quotation.fields) f: null,
    'currency': 'CNY',
    'tax_mode': 'unknown',
    'min_qty': '1',
    'inquiry_precision': 'date',
    'capture_mode': 'standard',
  };

  String _supplierId(String name) {
    final hits = searchByName('supplier', name, limit: 50)
        .where(
          (h) =>
              h.data['name'] == name ||
              (h.data['aliases']! as List).contains(name),
        )
        .toList();
    if (hits.isEmpty) invalid('供应商', '本机没有供应商“$name”');
    if (hits.length > 1) invalid('供应商', '有多个供应商叫“$name”');
    return hits.single.id;
  }

  String _projectId(String code) {
    final hits = searchByName(
      'project',
      code,
      limit: 50,
    ).where((h) => h.data['code'] == code).toList();
    if (hits.isEmpty) invalid('项目编号', '本机没有项目“$code”');
    if (hits.length > 1) invalid('项目编号', '有多个项目编号为“$code”');
    return hits.single.id;
  }

  /// Product identity is name + brand + model + specification. For an update
  /// with all four blank, the current product is kept (returns null).
  String? _productId(XCell Function(String) cell, bool required) {
    final key = {
      for (final (label, field) in [
        ('物料名称', 'name'),
        ('品牌', 'brand'),
        ('型号', 'model'),
        ('规格', 'specification'),
      ])
        field: cell(label).text(),
    };
    if (key.values.every((v) => v == null) && !required) return null;
    final name = key['name'];
    if (name == null) invalid('物料名称', '必填');
    final hits = searchProducts(
      [name],
      limit: 200,
    ).where((h) => key.entries.every((e) => h.data[e.key] == e.value)).toList();
    if (hits.isEmpty) invalid('物料名称', '本机没有物料“$name”（品牌/型号/规格需一致）');
    if (hits.length > 1) invalid('物料名称', '物料“$name”有重复记录');
    return hits.single.id;
  }

  bool _isDuplicate(Map<String, Object?> q) =>
      listQuotations(
        productId: q['product_id'] as String?,
        supplierId: q['supplier_id'] as String?,
        projectId: q['project_id'] as String?,
        limit: 1000,
      ).any(
        (h) =>
            h.data['price'] == q['price'] &&
            h.data['quoted_on'] == q['quoted_on'],
      );
}
