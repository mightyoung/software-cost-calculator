import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import 'budget.dart';
import 'project_export.dart';
import 'spec_deviation.dart';
import 'store.dart';
import 'values.dart';

/// A TrueType font the PDF can embed, from a .ttf or the first face of a
/// .ttc collection (Windows 微软雅黑, macOS 苹方 ship as collections).
/// Null for anything else, e.g. CFF-outline OpenType the writer cannot
/// subset.
Uint8List? embeddableFont(Uint8List file) {
  if (file.length < 12) return null;
  final data = ByteData.sublistView(file);
  final tag = String.fromCharCodes(file.sublist(0, 4));
  final start = tag == 'ttcf' ? data.getUint32(12) : 0;
  if (start + 12 > file.length) return null;
  final version = data.getUint32(start);
  if (version != 0x00010000 && version != 0x74727565) return null; // true
  final count = data.getUint16(start + 4);
  if (start + 12 + count * 16 > file.length) return null;
  final tables = [
    for (var i = 0; i < count; i++)
      (
        tag: data.getUint32(start + 12 + i * 16),
        checksum: data.getUint32(start + 16 + i * 16),
        offset: data.getUint32(start + 20 + i * 16),
        length: data.getUint32(start + 24 + i * 16),
      ),
  ];
  const glyf = 0x676C7966;
  if (!tables.any((t) => t.tag == glyf)) return null;
  if (tables.any((t) => t.offset + t.length > file.length)) return null;
  if (tag != 'ttcf') return file;
  // Rebuild a standalone font: same directory, tables copied behind it.
  var size = 12 + count * 16;
  final offsets = <int>[];
  for (final t in tables) {
    offsets.add(size);
    size += (t.length + 3) & ~3;
  }
  final out = Uint8List(size);
  final w = ByteData.sublistView(out);
  out.setRange(0, 12, file, start);
  for (final (i, t) in tables.indexed) {
    w
      ..setUint32(12 + i * 16, t.tag)
      ..setUint32(16 + i * 16, t.checksum)
      ..setUint32(20 + i * 16, offsets[i])
      ..setUint32(24 + i * 16, t.length);
    out.setRange(offsets[i], offsets[i] + t.length, file, t.offset);
  }
  return out;
}

/// 1234567.5 → 1,234,567.50 (at least two decimals, exact).
String pdfMoney(String decimal) {
  final negative = decimal.startsWith('-');
  final parts = (negative ? decimal.substring(1) : decimal).split('.');
  final whole = parts[0].replaceAllMapped(
    RegExp(r'\B(?=(\d{3})+(?!\d))'),
    (_) => ',',
  );
  final fraction = (parts.length > 1 ? parts[1] : '').padRight(2, '0');
  return '${negative ? '-' : ''}$whole.$fraction';
}

String _qty(String decimal) => decimal.replaceAllMapped(
  RegExp(r'^\d+'),
  (m) => m[0]!.replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => ','),
);

extension ProjectPdf on Store {
  /// The customer quote as PDF: prices only, no cost, supplier or margin.
  Future<Uint8List> quoteSheetPdf(
    String projectId,
    Uint8List font, {
    DateTime? asOf,
  }) {
    final project = _projectData(projectId);
    final b = budget(projectId, asOf: asOf);
    final rows = [
      for (final (i, l) in b.lines.indexed)
        () {
          final p = _productData(l.data);
          return [
            '${i + 1}',
            (p?['name'] ?? l.data['name'] ?? '') as String,
            [p?['brand'], p?['model']].whereType<String>().join(' '),
            (p?['specification'] ?? '') as String,
            l.data['unit']! as String,
            _qty(l.data['qty']! as String),
            pdfMoney(l.unitPrice),
            pdfMoney(l.price),
          ];
        }(),
    ];
    return _document(
      font,
      title: '项目报价单',
      landscape: false,
      meta: [
        '项目：${project['name']}（${project['code']}）',
        if (project['customer'] case final String c) '客户：$c',
        '币种：${project['currency']} ${project['tax_mode'] == 'included' ? '含税' : '不含税'}',
        '日期：${localDay(asOf ?? clock())}',
      ],
      header: const ['序号', '名称', '品牌 / 型号', '规格', '单位', '数量', '单价', '金额'],
      widths: const [0.5, 2, 1.6, 2.6, 0.6, 0.9, 1.2, 1.4],
      numeric: const {0, 5, 6, 7},
      rows: rows,
      totals: [('合计', pdfMoney(b.price))],
    );
  }

  /// The internal cost budget as PDF, by category, with suppliers.
  Future<Uint8List> costBudgetPdf(
    String projectId,
    Uint8List font, {
    DateTime? asOf,
  }) {
    final project = _projectData(projectId);
    final b = budget(projectId, asOf: asOf);
    final rows = <List<String>>[];
    final bold = <int>{};
    for (final MapEntry(key: category, value: label)
        in categoryLabels.entries) {
      final lines = b.lines.where((l) => l.data['category'] == category);
      if (lines.isEmpty) continue;
      for (final l in lines) {
        final p = _productData(l.data);
        final q = l.data['quotation_id'] == null
            ? null
            : get('quotation', l.data['quotation_id']! as String)?.data;
        rows.add([
          label,
          (p?['name'] ?? l.data['name'] ?? '') as String,
          [p?['brand'], p?['model']].whereType<String>().join(' '),
          l.data['unit']! as String,
          _qty(l.data['qty']! as String),
          pdfMoney(l.data['unit_cost']! as String),
          pdfMoney(l.cost),
          q == null
              ? ''
              : get('supplier', q['supplier_id']! as String)?.data['name']
                        as String? ??
                    '',
          pdfMoney(l.price),
          l.warnings.map((w) => warningLabels[w] ?? w).join('、'),
        ]);
      }
      bold.add(rows.length);
      rows.add([
        '$label小计',
        '',
        '',
        '',
        '',
        '',
        pdfMoney(b.costByCategory[category]!),
        '',
        '',
        '',
      ]);
    }
    return _document(
      font,
      title: '成本预算表',
      landscape: true,
      meta: [
        '项目：${project['name']}（${project['code']}）',
        if (project['contract_amount'] case final String a)
          '合同金额：${pdfMoney(a)}',
        '加价率：${project['markup_rate']}%',
        '日期：${localDay(asOf ?? clock())}',
      ],
      header: const [
        '类别',
        '名称',
        '品牌 / 型号',
        '单位',
        '数量',
        '成本单价',
        '成本金额',
        '供应商',
        '对外金额',
        '提示',
      ],
      widths: const [1, 2.2, 1.8, 0.6, 0.9, 1.2, 1.3, 1.8, 1.3, 1.5],
      numeric: const {4, 5, 6, 8},
      rows: rows,
      boldRows: bold,
      totals: [
        ('成本合计', pdfMoney(b.cost)),
        ('对外报价合计', pdfMoney(b.price)),
        ('毛利', pdfMoney(b.margin)),
        if (b.contractWarning) ('提示', '成本已达合同金额 90%'),
      ],
    );
  }

  /// The technical deviation table of a requirement as PDF.
  Future<Uint8List> deviationPdf(
    String requestId,
    Uint8List font, {
    DateTime? asOf,
  }) {
    final req = get('spec_request', requestId)!.data;
    final project = req['project_id'] == null
        ? null
        : get('project', req['project_id']! as String)?.data;
    final t = deviationTable(this, requestId);
    return _document(
      font,
      title: '技术偏离表',
      landscape: true,
      meta: [
        '技术要求：${req['title']}',
        if (project != null) '项目：${project['name']}（${project['code']}）',
        '日期：${localDay(asOf ?? clock())}',
      ],
      header: deviationHeader,
      widths: const [0.7, 0.5, 4, 3, 0.8, 2.4],
      numeric: const {},
      rows: t.rows,
      boldRows: t.headings,
      totals: const [],
    );
  }

  Future<Uint8List> _document(
    Uint8List fontFile, {
    required String title,
    required bool landscape,
    required List<String> meta,
    required List<String> header,
    required List<double> widths,
    required Set<int> numeric,
    required List<List<String>> rows,
    required List<(String, String)> totals,
    Set<int> boldRows = const {},
  }) {
    final font = pw.Font.ttf(ByteData.sublistView(fontFile));
    final doc = pw.Document(title: title, creator: '询价台账');
    const ink = PdfColor.fromInt(0xFF111827);
    const muted = PdfColor.fromInt(0xFF636C7E);
    const rule = PdfColor.fromInt(0xFFDCE1E8);
    const band = PdfColor.fromInt(0xFFEDF0F4);
    final base = pw.TextStyle(font: font, fontSize: 9, color: ink);
    pw.Widget cell(String text, int col, {bool head = false}) => pw.Padding(
      padding: const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      child: pw.Text(
        text,
        textAlign: numeric.contains(col)
            ? pw.TextAlign.right
            : pw.TextAlign.left,
        style: base.copyWith(
          fontSize: head ? 8.5 : 9,
          color: head ? muted : ink,
        ),
      ),
    );
    doc.addPage(
      pw.MultiPage(
        pageFormat: landscape ? PdfPageFormat.a4.landscape : PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(32),
        theme: pw.ThemeData.withFont(base: font, bold: font),
        footer: (context) => pw.Align(
          alignment: pw.Alignment.centerRight,
          child: pw.Text(
            '第 ${context.pageNumber} / ${context.pagesCount} 页',
            style: base.copyWith(fontSize: 8, color: muted),
          ),
        ),
        build: (context) => [
          pw.Text(title, style: base.copyWith(fontSize: 18)),
          pw.SizedBox(height: 6),
          pw.Wrap(
            spacing: 18,
            runSpacing: 2,
            children: [
              for (final m in meta)
                pw.Text(m, style: base.copyWith(color: muted)),
            ],
          ),
          pw.SizedBox(height: 12),
          pw.Table(
            columnWidths: {
              for (final (i, w) in widths.indexed) i: pw.FlexColumnWidth(w),
            },
            border: const pw.TableBorder(
              horizontalInside: pw.BorderSide(color: rule, width: 0.5),
              bottom: pw.BorderSide(color: rule, width: 0.5),
            ),
            children: [
              pw.TableRow(
                repeat: true,
                decoration: const pw.BoxDecoration(color: band),
                children: [
                  for (final (i, h) in header.indexed) cell(h, i, head: true),
                ],
              ),
              for (final (r, row) in rows.indexed)
                pw.TableRow(
                  // CJK system fonts have no bold face: subtotals get a band.
                  decoration: boldRows.contains(r)
                      ? const pw.BoxDecoration(color: band)
                      : null,
                  children: [for (final (i, v) in row.indexed) cell(v, i)],
                ),
            ],
          ),
          pw.SizedBox(height: 12),
          for (final (label, value) in totals)
            pw.Row(
              mainAxisAlignment: pw.MainAxisAlignment.end,
              children: [
                pw.Text(label, style: base.copyWith(color: muted)),
                pw.SizedBox(width: 12),
                pw.SizedBox(
                  width: 110,
                  child: pw.Text(
                    value,
                    textAlign: pw.TextAlign.right,
                    style: base.copyWith(fontSize: 12),
                  ),
                ),
              ],
            ),
        ],
      ),
    );
    return doc.save();
  }

  Map<String, Object?> _projectData(String id) {
    final p = get('project', id);
    if (p == null || p.deleted) invalid('project_id', 'unknown project');
    return p.data;
  }

  Map<String, Object?>? _productData(Map<String, Object?> line) =>
      line['product_id'] == null
      ? null
      : get('product', line['product_id']! as String)?.data;
}
