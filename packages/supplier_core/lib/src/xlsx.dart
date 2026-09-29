import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

import 'bounded_zip.dart';
import 'values.dart';

/// Size guards against hostile or accidental giant files (zip bombs).
const maxXlsxBytes = 20 * 1024 * 1024;
const maxExpandedBytes = 100 * 1024 * 1024;
const maxZipEntries = 2048;
// Budgets cover all sheets, including implied blank positions.
const maxWorkbookRows = 200000, maxWorkbookCells = 2000000;

enum CellKind { blank, text, number, boolean, error }

/// A cell exactly as stored: [lexical] is the raw XML text, so numbers never
/// pass through a double.
class XCell {
  const XCell(this.coordinate, this.kind, this.lexical, {this.formula = false});
  final String coordinate;
  final CellKind kind;
  final String lexical;
  final bool formula;

  bool get isBlank => kind == CellKind.blank || lexical.trim().isEmpty;

  /// Text for display or AI input; formula cells show their cached result.
  /// Never throws, so any readable sheet can be turned into AI input.
  String get display {
    if (kind != CellKind.number) return lexical;
    try {
      return _expand(lexical, coordinate);
    } on FormatException {
      return lexical;
    }
  }

  void _literal() {
    if (formula) invalid(coordinate, '公式单元格请先转换为数值');
    if (kind == CellKind.error) invalid(coordinate, '单元格含错误值 $lexical');
  }

  String? text() {
    if (isBlank && !formula) return null;
    _literal();
    return display.trim();
  }

  /// Non-negative decimal; thousands separators in text cells are accepted.
  String? decimal({bool positive = false}) {
    if (isBlank && !formula) return null;
    _literal();
    final raw = kind == CellKind.number
        ? _expand(lexical, coordinate)
        : lexical.trim().replaceAll(',', '');
    try {
      return ExactDecimal.parse(raw, positive: positive).canonical;
    } on FormatException {
      invalid(coordinate, '不是有效的数值（最多 12 位整数、6 位小数）：$lexical');
    }
  }

  /// Calendar date from an Excel serial or YYYY-MM-DD / YYYY/M/D text.
  String? date({required bool date1904}) {
    if (isBlank && !formula) return null;
    _literal();
    if (kind == CellKind.number)
      return _serialDate(lexical, coordinate, date1904);
    final m = RegExp(
      r'^(\d{4})[-/.](\d{1,2})[-/.](\d{1,2})$',
    ).firstMatch(lexical.trim());
    if (m == null) invalid(coordinate, '日期格式应为 YYYY-MM-DD：$lexical');
    return requireDate(
      '${m[1]}-${m[2]!.padLeft(2, '0')}-${m[3]!.padLeft(2, '0')}',
      coordinate,
    );
  }
}

class XSheet {
  XSheet(this.name, this.rows);
  final String name;

  /// Dense rows; missing cells are blank.
  final List<List<XCell>> rows;
}

class XWorkbook {
  XWorkbook(this.sheets, {required this.date1904});
  final List<XSheet> sheets;
  final bool date1904;
}

/// A value written as a numeric cell while keeping the exact decimal text.
class Num {
  const Num(this.decimal);
  final String decimal;
}

class SheetData {
  SheetData(
    this.name,
    this.rows, {
    this.widths = const [],
    this.boldRows = const {},
  });
  final String name;

  /// Cells are String (text), Num (number) or null (blank).
  final List<List<Object?>> rows;
  final List<int> widths;
  final Set<int> boldRows;
}

// ponytail: whole-sheet DOM parse; fine for business files within the 20 MB
// limit. Switch to xml_events streaming if much larger sheets are needed.
XWorkbook readXlsx(Uint8List bytes) {
  if (bytes.length > maxXlsxBytes) invalid('file', '文件超过 20 MB');
  final Map<String, Uint8List> archive;
  try {
    archive = readBoundedZip(
      bytes,
      maxEntries: maxZipEntries,
      maxExpandedBytes: maxExpandedBytes,
    );
  } catch (_) {
    invalid('file', '不是有效的 xlsx 文件，或文件解压后过大');
  }
  String? part(String name) {
    final content = archive[name];
    if (content == null) return null;
    return utf8.decode(content);
  }

  XmlDocument doc(String name) {
    final text = part(name);
    if (text == null) invalid('file', '缺少 $name，不是有效的 xlsx 文件');
    try {
      return XmlDocument.parse(text);
    } on XmlException {
      invalid('file', '$name 内容损坏');
    }
  }

  final workbook = doc('xl/workbook.xml');
  final date1904 =
      workbook
          .findAllElements('workbookPr')
          .firstOrNull
          ?.getAttribute('date1904') ==
      '1';
  final targets = {
    for (final r in doc(
      'xl/_rels/workbook.xml.rels',
    ).findAllElements('Relationship'))
      r.getAttribute('Id'): r.getAttribute('Target'),
  };
  final shared = !archive.containsKey('xl/sharedStrings.xml')
      ? const <String>[]
      : [
          for (final si in doc('xl/sharedStrings.xml').findAllElements('si'))
            _runText(si),
        ];
  final sheets = <XSheet>[];
  final budget = _WorkbookBudget();
  for (final s in workbook.findAllElements('sheet')) {
    final rel = s.attributes
        .firstWhere(
          (a) => a.name.local == 'id',
          orElse: () => XmlAttribute(XmlName('id'), ''),
        )
        .value;
    var target = targets[rel] ?? '';
    target = target.startsWith('/') ? target.substring(1) : 'xl/$target';
    sheets.add(
      XSheet(s.getAttribute('name') ?? '', _rows(doc(target), shared, budget)),
    );
  }
  return XWorkbook(sheets, date1904: date1904);
}

String _runText(XmlElement si) => [
  for (final t in si.findAllElements('t'))
    if (t.parentElement?.name.local != 'rPh') t.innerText,
].join();

class _WorkbookBudget {
  var rows = 0, cells = 0;
}

List<List<XCell>> _rows(
  XmlDocument sheet,
  List<String> shared,
  _WorkbookBudget budget,
) {
  final rows = <int, Map<int, XCell>>{};
  final widths = <int, int>{};
  var height = 0;
  for (final c in sheet.findAllElements('c')) {
    final ref = c.getAttribute('r') ?? '';
    final m = RegExp(r'^([A-Z]{1,3})(\d{1,7})$').firstMatch(ref);
    if (m == null) invalid('file', '单元格坐标无效：$ref');
    final col = m[1]!.codeUnits.fold(0, (n, u) => n * 26 + u - 64) - 1;
    final row = int.parse(m[2]!) - 1;
    if (row < 0 || row >= 1048576 || col >= 16384) {
      invalid('file', '单元格坐标超出 Excel 范围：$ref');
    }
    final newHeight = row + 1 > height ? row + 1 : height;
    budget.rows += newHeight - height;
    height = newHeight;
    final previous = widths[row] ?? 0;
    if (col + 1 > previous) {
      budget.cells += col + 1 - previous;
      widths[row] = col + 1;
    }
    if (budget.rows > maxWorkbookRows || budget.cells > maxWorkbookCells) {
      invalid('file', '工作簿行数或单元格数量过多，请拆分后导入');
    }
    final type = c.getAttribute('t');
    final value = c.getElement('v')?.innerText;
    final formula = c.getElement('f') != null;
    final XCell cell = switch (type) {
      's' => XCell(
        ref,
        CellKind.text,
        _shared(shared, value, ref),
        formula: formula,
      ),
      'inlineStr' => XCell(
        ref,
        CellKind.text,
        _runText(c.getElement('is') ?? c),
        formula: formula,
      ),
      'str' => XCell(ref, CellKind.text, value ?? '', formula: formula),
      'b' => XCell(
        ref,
        CellKind.boolean,
        value == '1' ? 'TRUE' : 'FALSE',
        formula: formula,
      ),
      'e' => XCell(ref, CellKind.error, value ?? '#ERROR', formula: formula),
      _ when value == null || value.isEmpty => XCell(
        ref,
        CellKind.blank,
        '',
        formula: formula,
      ),
      _ => XCell(ref, CellKind.number, value, formula: formula),
    };
    (rows[row] ??= {})[col] = cell;
  }
  if (rows.isEmpty) return [];
  final last = rows.keys.reduce((a, b) => a > b ? a : b);
  return [
    for (var r = 0; r <= last; r++)
      if (rows[r] case final cells?)
        [
          for (var col = 0; col < widths[r]!; col++)
            cells[col] ?? XCell(_ref(col, r), CellKind.blank, ''),
        ]
      else
        <XCell>[],
  ];
}

String _shared(List<String> shared, String? index, String ref) {
  final i = int.tryParse(index ?? '');
  if (i == null || i < 0 || i >= shared.length) invalid(ref, '共享字符串索引无效');
  return shared[i];
}

String _ref(int col, int row) {
  var n = col + 1, letters = '';
  while (n > 0) {
    letters = String.fromCharCode(65 + (n - 1) % 26) + letters;
    n = (n - 1) ~/ 26;
  }
  return '$letters${row + 1}';
}

/// Scientific or plain numeric lexeme to plain decimal text, without doubles.
String _expand(String lexical, String coordinate) {
  if (lexical.length > 128) invalid(coordinate, '数值过长');
  final m = RegExp(
    r'^\+?(\d+(?:\.\d*)?|\.\d+)(?:[eE]([+-]?\d{1,3}))?$',
  ).firstMatch(lexical);
  if (m == null) invalid(coordinate, '不是有效的非负数值：$lexical');
  final mantissa = m[1]!;
  final exponent = int.parse(m[2] ?? '0');
  final dot = mantissa.indexOf('.');
  final digits = mantissa.replaceAll('.', '');
  final point = (dot == -1 ? mantissa.length : dot) + exponent;
  if (exponent != 0 && !digits.contains(RegExp('[1-9]'))) return '0';
  if (point.abs() > 128) invalid(coordinate, '数值量级过大');
  final text = point <= 0
      ? '0.${'0' * -point}$digits'
      : point >= digits.length
      ? digits + '0' * (point - digits.length)
      : '${digits.substring(0, point)}.${digits.substring(point)}';
  final trimmed = text.contains('.')
      ? text.replaceFirst(RegExp(r'\.?0+$'), '')
      : text;
  return trimmed.replaceFirst(RegExp(r'^0+(?=\d)'), '');
}

String _serialDate(String lexical, String coordinate, bool date1904) {
  final value = _expand(lexical, coordinate);
  final parts = value.split('.');
  if (parts.length == 2) invalid(coordinate, '日期单元格带有时间，请只保留日期');
  final day = int.parse(parts.first);
  if (!date1904 && day == 60) invalid(coordinate, 'Excel 虚构日期 1900-02-29');
  if (day < (date1904 ? 0 : 1) || day > 2958465) invalid(coordinate, '日期超出范围');
  final base = date1904
      ? DateTime.utc(1904)
      : DateTime.utc(1899, 12, day > 60 ? 30 : 31);
  return base.add(Duration(days: day)).toIso8601String().substring(0, 10);
}

const _contentTypes =
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
    '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
    '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
    '<Default Extension="xml" ContentType="application/xml"/>'
    '<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>'
    '<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>'
    '%SHEETS%</Types>';

/// Style 1: text format (keeps leading zeros), 2: number with 2-6 decimals,
/// 3: bold text, 4: bold number.
const _styles =
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
    '<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
    '<numFmts count="1"><numFmt numFmtId="164" formatCode="#,##0.00####"/></numFmts>'
    '<fonts count="2"><font><sz val="11"/><name val="等线"/></font>'
    '<font><b/><sz val="11"/><name val="等线"/></font></fonts>'
    '<fills count="2"><fill><patternFill patternType="none"/></fill>'
    '<fill><patternFill patternType="gray125"/></fill></fills>'
    '<borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>'
    '<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>'
    '<cellXfs count="5"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>'
    '<xf numFmtId="49" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>'
    '<xf numFmtId="164" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>'
    '<xf numFmtId="49" fontId="1" fillId="0" borderId="0" xfId="0" applyNumberFormat="1" applyFont="1"/>'
    '<xf numFmtId="164" fontId="1" fillId="0" borderId="0" xfId="0" applyNumberFormat="1" applyFont="1"/></cellXfs>'
    '<cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles></styleSheet>';

String _xml(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');

Uint8List writeXlsx(List<SheetData> sheets) {
  final archive = Archive();
  void add(String name, String text) {
    final bytes = utf8.encode(text);
    archive.addFile(ArchiveFile(name, bytes.length, bytes));
  }

  add(
    '[Content_Types].xml',
    _contentTypes.replaceFirst(
      '%SHEETS%',
      [
        for (var i = 1; i <= sheets.length; i++)
          '<Override PartName="/xl/worksheets/sheet$i.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>',
      ].join(),
    ),
  );
  add(
    '_rels/.rels',
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>'
        '</Relationships>',
  );
  add(
    'xl/workbook.xml',
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" '
        'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets>'
        '${[for (var i = 0; i < sheets.length; i++) '<sheet name="${_xml(sheets[i].name)}" sheetId="${i + 1}" r:id="rId${i + 1}"/>'].join()}'
        '</sheets></workbook>',
  );
  add(
    'xl/_rels/workbook.xml.rels',
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '${[for (var i = 1; i <= sheets.length; i++) '<Relationship Id="rId$i" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet$i.xml"/>'].join()}'
        '<Relationship Id="rId${sheets.length + 1}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>'
        '</Relationships>',
  );
  add('xl/styles.xml', _styles);
  for (var i = 0; i < sheets.length; i++) {
    add('xl/worksheets/sheet${i + 1}.xml', _sheetXml(sheets[i]));
  }
  return Uint8List.fromList(ZipEncoder().encode(archive)!);
}

String _sheetXml(SheetData sheet) {
  final out = StringBuffer(
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
    '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">',
  );
  if (sheet.widths.isNotEmpty) {
    out.write('<cols>');
    for (var i = 0; i < sheet.widths.length; i++) {
      out.write(
        '<col min="${i + 1}" max="${i + 1}" width="${sheet.widths[i]}" customWidth="1"/>',
      );
    }
    out.write('</cols>');
  }
  out.write('<sheetData>');
  for (var r = 0; r < sheet.rows.length; r++) {
    final bold = sheet.boldRows.contains(r);
    out.write('<row r="${r + 1}">');
    for (var c = 0; c < sheet.rows[r].length; c++) {
      final ref = _ref(c, r);
      switch (sheet.rows[r][c]) {
        case null:
          break;
        case Num(:final decimal):
          ExactDecimal.parse(decimal.replaceFirst('-', ''));
          out.write('<c r="$ref" s="${bold ? 4 : 2}"><v>$decimal</v></c>');
        case final String text:
          out.write(
            '<c r="$ref" t="inlineStr" s="${bold ? 3 : 1}"><is><t xml:space="preserve">${_xml(text)}</t></is></c>',
          );
        case final other:
          throw ArgumentError('Unsupported cell value $other');
      }
    }
    out.write('</row>');
  }
  return (out..write('</sheetData></worksheet>')).toString();
}
