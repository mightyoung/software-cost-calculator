import 'dart:typed_data';

import 'budget.dart';
import 'store.dart';
import 'values.dart';
import 'xlsx.dart';

const categoryLabels = {
  'material': '材料费',
  'outsourcing': '外协费',
  'labor': '人工费',
  'overhead': '制造费用',
  'other': '其他',
};

const warningLabels = {
  'cheaper_available': '有更低报价',
  'quote_not_valid': '所选报价已失效',
  'needs_inquiry': '待询价',
};

/// Converts any readable workbook into plain lines for the AI list flow.
String workbookText(XWorkbook book) => [
  for (final sheet in book.sheets) ...[
    '【${sheet.name}】',
    for (final row in sheet.rows)
      if (row.any((c) => !c.isBlank))
        [for (final c in row) c.display.trim()].join(' | '),
  ],
].join('\n');

extension ProjectExport on Store {
  /// Customer-facing quote: prices only, no cost, supplier or margin.
  Uint8List exportQuoteSheet(String projectId) {
    final project = _project(projectId);
    final b = budget(projectId);
    final rows = <List<Object?>>[
      ['项目报价单'],
      ['项目', '${project['name']}（${project['code']}）'],
      ['客户', project['customer'] as String? ?? ''],
      [
        '币种',
        '${project['currency']} ${project['tax_mode'] == 'included' ? '含税' : '不含税'}',
      ],
      [],
      ['序号', '类别', '名称', '品牌', '型号', '规格', '单位', '数量', '单价', '金额', '备注'],
    ];
    final header = rows.length - 1;
    var n = 0;
    for (final l in b.lines) {
      final p = _product(l.data);
      rows.add([
        '${++n}',
        categoryLabels[l.data['category']],
        _name(l.data, p),
        p?['brand'],
        p?['model'],
        p?['specification'],
        l.data['unit'],
        Num(l.data['qty']! as String),
        Num(l.unitPrice),
        Num(l.price),
        null,
      ]);
    }
    rows.add([
      null,
      null,
      '合计',
      null,
      null,
      null,
      null,
      null,
      null,
      Num(b.price),
    ]);
    return writeXlsx([
      SheetData(
        '报价单',
        rows,
        widths: [6, 10, 24, 12, 16, 28, 6, 10, 14, 16, 20],
        boldRows: {0, header, rows.length - 1},
      ),
    ]);
  }

  /// Internal cost budget grouped by category, with suppliers and warnings.
  Uint8List exportCostBudget(String projectId, {DateTime? asOf}) {
    final project = _project(projectId);
    final b = budget(projectId, asOf: asOf);
    final rows = <List<Object?>>[
      ['成本预算表'],
      ['项目', '${project['name']}（${project['code']}）'],
      [
        '合同金额',
        project['contract_amount'] == null
            ? '未填'
            : Num(project['contract_amount']! as String),
      ],
      ['加价率(%)', Num(project['markup_rate']! as String)],
      [],
    ];
    final bold = <int>{0};
    const header = [
      '类别',
      '名称',
      '品牌',
      '型号',
      '规格',
      '单位',
      '数量',
      '成本单价',
      '成本金额',
      '供应商',
      '报价日期',
      '有效期至',
      '对外单价',
      '对外金额',
      '提示',
      '备注',
    ];
    for (final category in categoryLabels.keys) {
      final lines = b.lines
          .where((l) => l.data['category'] == category)
          .toList();
      if (lines.isEmpty) continue;
      bold.add(rows.length);
      rows.add(header);
      for (final l in lines) {
        final p = _product(l.data);
        final q = l.data['quotation_id'] == null
            ? null
            : get('quotation', l.data['quotation_id']! as String)?.data;
        final supplier = q == null
            ? null
            : get('supplier', q['supplier_id']! as String)?.data;
        rows.add([
          categoryLabels[category],
          _name(l.data, p),
          p?['brand'],
          p?['model'],
          p?['specification'],
          l.data['unit'],
          Num(l.data['qty']! as String),
          Num(l.data['unit_cost']! as String),
          Num(l.cost),
          supplier?['name'],
          q?['quoted_on'],
          q?['valid_until'],
          Num(l.unitPrice),
          Num(l.price),
          l.warnings.map((w) => warningLabels[w] ?? w).join('、'),
          l.data['notes'],
        ]);
      }
      bold.add(rows.length);
      rows.add([
        '${categoryLabels[category]}小计',
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        Num(b.costByCategory[category]!),
      ]);
      rows.add([]);
    }
    bold.addAll([rows.length, rows.length + 1, rows.length + 2]);
    rows
      ..add(['成本合计', null, null, null, null, null, null, null, Num(b.cost)])
      ..add([
        '对外报价合计',
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        Num(b.price),
      ])
      ..add(['毛利', Num(b.margin), b.contractWarning ? '成本已达合同金额 90%' : null]);
    return writeXlsx([
      SheetData(
        '成本预算',
        rows,
        widths: [12, 24, 12, 16, 28, 6, 10, 12, 14, 20, 12, 12, 12, 14, 16, 30],
        boldRows: bold,
      ),
    ]);
  }

  /// Unmatched material lines, with blank columns for suppliers to fill in.
  Uint8List exportInquiryList(String projectId) {
    final project = _project(projectId);
    final rows = <List<Object?>>[
      ['询价清单'],
      ['项目', '${project['name']}（${project['code']}）'],
      [],
      [
        '序号',
        '名称',
        '要求/备注',
        '数量',
        '单位',
        '品牌',
        '型号',
        '单价',
        '交期(天)',
        '报价有效期至',
        '供应商备注',
      ],
    ];
    var n = 0;
    for (final l in budget(projectId).lines) {
      if (!l.warnings.contains('needs_inquiry')) continue;
      rows.add([
        '${++n}',
        l.data['name'],
        l.data['notes'],
        Num(l.data['qty']! as String),
        l.data['unit'],
      ]);
    }
    return writeXlsx([
      SheetData(
        '询价清单',
        rows,
        widths: [6, 24, 36, 10, 6, 12, 16, 12, 10, 14, 24],
        boldRows: {0, 3},
      ),
    ]);
  }

  Map<String, Object?> _project(String id) {
    final p = get('project', id);
    if (p == null || p.deleted) invalid('project_id', 'unknown project');
    return p.data;
  }

  Map<String, Object?>? _product(Map<String, Object?> line) =>
      line['product_id'] == null
      ? null
      : get('product', line['product_id']! as String)?.data;

  String? _name(Map<String, Object?> line, Map<String, Object?>? product) =>
      (product?['name'] ?? line['name']) as String?;
}
