import 'dart:convert';
import 'dart:typed_data';

import 'duplicates.dart';
import 'entities.dart';
import 'material_import.dart';
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
  // Who quoted and how to reach them; the material's type. A supplier or
  // material not yet on file is created on import (a material needs 单位).
  '报价人',
  '联系电话',
  '类型',
];

/// Stands in for a supplier or material created only when the plan is
/// applied, so the row validates as a quotation beforehand.
const _pendingId = '00000000-0000-4000-8000-000000000001';

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
    this.newSupplier,
    this.newProduct,
    this.contact,
  });
  final int row; // 1-based Excel row number
  final RowAction action;
  final String? id, error;
  final Map<String, Object?>? payload;
  final List<String> changedFields;

  /// The local record was edited after this file was exported.
  final bool changedSinceExport;

  /// Supplier name / material payload to create on apply (not on file yet).
  final String? newSupplier;
  final Map<String, Object?>? newProduct;

  /// Quoting person to find or add among the supplier's contacts on apply.
  final Offer? contact;
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
        (q['contact_snapshot'] as Map?)?['name'],
        (q['contact_snapshot'] as Map?)?['phone'],
        p['category'],
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
          10,
          14,
          10,
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

  /// Saves create/update rows in one transaction, first creating the
  /// suppliers, materials and contacts they need (once each per file);
  /// returns how many quotations were saved.
  int applyQuotationImport(List<QuoteRowPlan> plans) => transaction(() {
    final suppliers = <String, String>{};
    final products = <String, String>{};
    final contacts = <String, String>{};
    var saved = 0;
    for (final p in plans) {
      if (p.action != RowAction.create && p.action != RowAction.update) {
        continue;
      }
      final data = Map<String, Object?>.of(p.payload!);
      if (p.newSupplier case final name?) {
        data['supplier_id'] = suppliers.putIfAbsent(
          companyKey(name),
          () => save('supplier', {
            for (final f in Supplier.fields) f: null,
            'name': name,
            'aliases': <String>[],
            'categories': <String>[],
          }),
        );
      }
      if (p.newProduct case final product?) {
        data['product_id'] = products.putIfAbsent(
          [
            for (final k in ['name', 'brand', 'model', 'specification'])
              normalizeKey(product[k] as String?),
          ].join('|'),
          () => save('product', product),
        );
      }
      if (p.contact case final c?) {
        final id = matchOrCreateContact(
          c,
          data['supplier_id']! as String,
          contacts,
        );
        if (id != null) {
          data['contact_id'] = id;
          data['contact_snapshot'] = Contact.fromJson(
            get('contact', id)!.data,
          ).snapshot;
        }
      }
      save(
        'quotation',
        data,
        id: p.action == RowAction.update ? p.id : null,
        imported: true,
      );
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
      final supplierId = supplier == null ? null : _supplierId(supplier);
      if (supplier != null) set('supplier_id', supplierId ?? _pendingId);
      final product = _productId(cell, existing == null);
      final newProduct = product == _pendingId ? _newProduct(cell) : null;
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
      // "数量" in a supplier's sheet is the minimum order.
      set(
        'min_qty',
        (cell('起订量').isBlank ? cell('数量') : cell('起订量')).decimal(
          positive: true,
        ),
      );
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
      // The quoting person: an existing contact of a known supplier now,
      // otherwise found or added on apply (a contact needs a phone).
      final person = cell('报价人').text(), phone = cell('联系电话').text();
      Offer? contact;
      if (person != null || phone != null) {
        final known =
            supplierId ??
            (supplier == null ? data['supplier_id'] as String? : null);
        final match = known == null
            ? null
            : contactsOf(known)
                  .where(
                    (h) => phone != null
                        ? h.data['phone'] == phone
                        : h.data['name'] == person,
                  )
                  .firstOrNull;
        if (match != null) {
          data['contact_id'] = match.id;
          data['contact_snapshot'] = Contact.fromJson(match.data).snapshot;
        } else if (phone != null) {
          contact = {
            'contact_name': person,
            'phone': phone,
            'wechat': null,
            'email': null,
          };
        } else if (existing == null) {
          data['notes'] = [?data['notes'] as String?, '报价人：$person'].join('；');
        }
      }
      if (data['unit_snapshot'] == null && newProduct != null) {
        data['unit_snapshot'] = newProduct['unit'];
      }
      if (data['unit_snapshot'] == null && data['product_id'] != null) {
        data['unit_snapshot'] = get(
          'product',
          data['product_id']! as String,
        )?.data['unit'];
      }
      // A price sheet row without project, inquirer or dates is kept as a
      // historical record rather than refused.
      if (existing == null &&
          [
            'project_id',
            'inquirer_name',
            'inquiry_date',
            'quoted_on',
          ].any((k) => data[k] == null)) {
        data['capture_mode'] = 'historical';
        if (data['inquiry_date'] == null) data['inquiry_precision'] = 'unknown';
      }
      final payload = validatePayload('quotation', data);
      final newSupplier = supplier != null && supplierId == null
          ? supplier
          : null;
      final pending = newSupplier != null || newProduct != null;

      if (existing == null) {
        return QuoteRowPlan(
          row,
          !pending && _isDuplicate(payload)
              ? RowAction.duplicate
              : RowAction.create,
          payload: payload,
          newSupplier: newSupplier,
          newProduct: newProduct,
          contact: contact,
        );
      }
      final changed = [
        for (final k in payload.keys)
          if (jsonEncode(payload[k]) != jsonEncode(existing.data[k])) k,
      ];
      final version = cell('版本').text();
      return QuoteRowPlan(
        row,
        changed.isEmpty && !pending && contact == null
            ? RowAction.unchanged
            : RowAction.update,
        id: existing.id,
        payload: payload,
        changedFields: changed,
        changedSinceExport: version != null && version != '${existing.version}',
        newSupplier: newSupplier,
        newProduct: newProduct,
        contact: contact,
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

  /// The supplier by exact name or alias, else the one supplier that is
  /// the same company ("有限公司" etc. ignored); null means "create it".
  String? _supplierId(String name) {
    final hits = searchByName('supplier', name, limit: 50)
        .where(
          (h) =>
              h.data['name'] == name ||
              (h.data['aliases']! as List).contains(name),
        )
        .toList();
    if (hits.length > 1) invalid('供应商', '有多个供应商叫“$name”');
    if (hits.length == 1) return hits.single.id;
    final same = [
      for (final d in similarSuppliers(name))
        if (d.level == Similarity.same) d.hit.id,
    ];
    if (same.length > 1) invalid('供应商', '有多个供应商与“$name”同名');
    return same.firstOrNull;
  }

  /// A material not on file, from the row's own columns; needs 单位.
  Map<String, Object?> _newProduct(XCell Function(String) cell) {
    final name = cell('物料名称').text()!;
    final unit = cell('单位').text();
    if (unit == null) {
      invalid('单位', '本机没有物料“$name”，填写单位后可以自动新建');
    }
    return validatePayload('product', {
      for (final f in Product.fields) f: null,
      'name': name,
      'unit': unit,
      'brand': cell('品牌').text(),
      'model': cell('型号').text(),
      'specification': cell('规格').text(),
      'category': cell('类型').text(),
    });
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
    if (hits.isEmpty) return _pendingId;
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
