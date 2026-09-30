import 'material_import.dart';
import 'xlsx.dart';

/// Common Chinese column titles of quote and selection sheets, normalized
/// (no spaces, no bracketed suffix such as "（元）").
const _headers = {
  'name': ['物料名称', '产品名称', '设备名称', '名称', '品名', '材料名称', '货物名称', '商品名称'],
  'brand': ['品牌', '厂牌'],
  'model': ['型号', '规格型号'],
  'specification': [
    '规格',
    '技术参数',
    '参数',
    '主要参数',
    '技术要求',
    '技术指标',
    '主要指标要求',
    '指标要求',
    '主要技术参数',
    '配置',
  ],
  'category': ['类别', '设备类别', '物料类别', '分类', '类型', '物料类型', '设备类型'],
  'unit': ['单位', '计量单位'],
  'price': ['单价', '含税单价', '不含税单价', '报价', '参考单价'],
  'qty': ['数量', '采购数量', '需求数量'],
  'supplier': [
    '供应商',
    '供应商名称',
    '供货商',
    '厂家',
    '厂商',
    '生产厂家',
    '报价公司',
    '报价单位',
    '报价方',
  ],
  'contact_name': ['联系人', '报价人', '报价联系人'],
  'phone': ['联系方式', '电话', '联系电话', '手机', '手机号', '报价人联系方式', '报价人电话', '联系人电话'],
  'wechat': ['微信'],
  'email': ['邮箱', '电子邮箱'],
  'currency': ['币种'],
  'tax_rate': ['税率'],
  'quoted_on': ['报价日期', '报价时间', '取价日期', '价格日期'],
  'valid_until': ['有效期至', '有效期'],
  'lead_time_days': ['交期', '交货期'],
  'notes': ['备注', '说明'],
};

const _maxTableChars = 1024 * 1024;
const _maxFieldChars = 65536;

// Count references, not unique shared strings, before trimming or copying.
void _checkTableText(XWorkbook book) {
  var chars = 0, rows = 0, cells = 0;
  for (final sheet in book.sheets) {
    for (final row in sheet.rows) {
      if (++rows > maxWorkbookRows) {
        throw const FormatException('工作簿行数过多，请拆分后导入');
      }
      for (final cell in row) {
        if (++cells > maxWorkbookCells ||
            cell.lexical.length > _maxFieldChars ||
            (chars += cell.lexical.length) > _maxTableChars) {
          throw const FormatException('工作簿文本过大，请拆分后导入');
        }
      }
    }
  }
}

String _norm(String s) {
  final text = s.replaceAll(RegExp(r'\s'), '');
  if (text.isEmpty || !(text.endsWith(')') || text.endsWith('）'))) {
    return text;
  }
  // Find the final bracket suffix in linear time, including mixed brackets.
  final stop = text.length - 2;
  final a = stop < 0 ? -1 : text.lastIndexOf(')', stop);
  final b = stop < 0 ? -1 : text.lastIndexOf('）', stop);
  final start = (a > b ? a : b) + 1;
  final left = text.indexOf('(', start);
  final right = text.indexOf('（', start);
  final at = left < 0
      ? right
      : right < 0
      ? left
      : left < right
      ? left
      : right;
  return at < 0 ? text : text.substring(0, at);
}

class _ContinuationText {
  _ContinuationText(String? initial) {
    if (initial != null) _text.write(initial);
  }

  final _text = StringBuffer();

  void add(String more) {
    final separator = _text.isEmpty ? 0 : 1;
    if (more.length + separator > _maxFieldChars - _text.length) {
      throw const FormatException('合并行文本过长，请拆分后导入');
    }
    if (separator != 0) _text.write('\n');
    _text.write(more);
  }

  @override
  String toString() => _text.toString();
}

void _continueText(Map<String, Object?> row, String key, String more) {
  final previous = row[key];
  final text = previous is _ContinuationText
      ? previous
      : _ContinuationText(previous as String?);
  text.add(more);
  row[key] = text;
}

Map<String, String?> _finishText(Map<String, Object?> row) => {
  for (final entry in row.entries)
    entry.key: entry.value is _ContinuationText
        ? entry.value.toString()
        : entry.value as String?,
};

/// Reads offers straight from a table with a recognizable header (a name
/// column plus a price, brand or model column), without AI. Rows whose name
/// is blank continue the row above (merged cells: extra requirement lines).
/// Without a supplier column the brand stands in as the supplier. Returns
/// null when no sheet has such a header. A [materials] list (no prices)
/// needs only a name plus a category, brand, model or specification column.
List<Offer>? offersFromWorkbook(XWorkbook book, {bool materials = false}) {
  _checkTableText(book);
  final second = materials
      ? const ['category', 'brand', 'model', 'specification']
      : const ['price', 'brand', 'model'];
  for (final sheet in book.sheets) {
    for (var h = 0; h < sheet.rows.length && h < 10; h++) {
      final col = <String, int>{};
      final taxOf = <int, String>{};
      for (final (i, c) in sheet.rows[h].indexed) {
        final title = c.display.trim();
        final n = _norm(title);
        for (final MapEntry(:key, :value) in _headers.entries) {
          if (value.contains(n) && !col.containsKey(key)) col[key] = i;
        }
        if (title.contains('不含税')) {
          taxOf[i] = 'excluded';
        } else if (title.contains('含税')) {
          taxOf[i] = 'included';
        }
      }
      if (!col.containsKey('name') || !second.any(col.containsKey)) {
        continue;
      }
      return _offers(sheet.rows.skip(h + 1), col, taxOf, book.date1904);
    }
  }
  return null;
}

List<Offer> _offers(
  Iterable<List<XCell>> rows,
  Map<String, int> col,
  Map<int, String> taxOf,
  bool date1904,
) {
  final raws = <Map<String, Object?>>[];
  for (final row in rows) {
    String? at(String key) {
      final i = col[key];
      if (i == null || i >= row.length || row[i].isBlank) return null;
      final c = row[i];
      if (key == 'quoted_on' || key == 'valid_until') {
        try {
          return c.date(date1904: date1904);
        } on FormatException {
          return null;
        }
      }
      return c.display.trim();
    }

    final name = at('name');
    if (name == null) {
      // Continuation of a merged row: more requirement or note lines.
      if (raws.isEmpty) continue;
      for (final k in ['specification', 'notes']) {
        if (at(k) case final more?) {
          _continueText(raws.last, k, more);
        }
      }
      continue;
    }
    if (RegExp(r'^(合计|小计|总计|总价)').hasMatch(name)) continue;
    final raw = <String, Object?>{
      for (final k in _headers.keys) k: at(k),
      if (col['price'] case final p? when taxOf[p] != null)
        'tax_mode': taxOf[p],
    };
    // One "contact" column may hold a phone, an email or a word like 微信.
    if (raw['phone'] case final String p
        when !RegExp(r'^[+0-9][0-9 \-()]{6,}$').hasMatch(p)) {
      raw['phone'] = null;
      if (p.contains('@')) {
        raw['email'] ??= p;
      } else {
        raw['notes'] = [?raw['notes'] as String?, '联系方式：$p'].join('；');
      }
    }
    raw['supplier'] ??= raw['brand'];
    raws.add(raw);
  }
  return [for (final r in raws) cleanOffer(_finishText(r))];
}

/// Rows of a requirement sheet: name, qty, unit and requirement text
/// (merged continuation rows joined). Needs a name and a requirement
/// column; null otherwise.
List<Map<String, String?>>? requirementRows(XWorkbook book) {
  _checkTableText(book);
  for (final sheet in book.sheets) {
    for (var h = 0; h < sheet.rows.length && h < 10; h++) {
      final col = <String, int>{};
      for (final (i, c) in sheet.rows[h].indexed) {
        final n = _norm(c.display.trim());
        for (final k in ['name', 'specification', 'qty', 'unit']) {
          if (_headers[k]!.contains(n) && !col.containsKey(k)) col[k] = i;
        }
      }
      if (!col.containsKey('name') || !col.containsKey('specification')) {
        continue;
      }
      final out = <Map<String, Object?>>[];
      for (final row in sheet.rows.skip(h + 1)) {
        String? at(String key) {
          final i = col[key];
          if (i == null || i >= row.length || row[i].isBlank) return null;
          return row[i].display.trim();
        }

        final name = at('name');
        if (name == null) {
          final more = at('specification');
          if (out.isNotEmpty && more != null) {
            _continueText(out.last, 'specification', more);
          }
          continue;
        }
        if (RegExp(r'^(合计|小计|总计)').hasMatch(name)) continue;
        out.add({
          'name': name,
          'specification': at('specification'),
          'qty': at('qty'),
          'unit': at('unit'),
        });
      }
      return [for (final row in out) _finishText(row)];
    }
  }
  return null;
}

/// Cells copied from Excel arrive as tab-separated lines; a cell holding
/// line breaks or tabs is quoted with doubled inner quotes. Returns null
/// for text without tabs.
XWorkbook? tableFromText(String text) {
  if (!text.contains('\t')) return null;
  if (text.length > _maxTableChars) {
    throw const FormatException('表格文本过大，请拆分后导入');
  }
  final rows = <List<XCell>>[];
  var row = <XCell>[];
  final cell = StringBuffer();
  var quoted = false;
  void endCell() {
    final v = cell.toString();
    row.add(
      XCell(
        'R${rows.length + 1}C${row.length + 1}',
        v.trim().isEmpty ? CellKind.blank : CellKind.text,
        v,
      ),
    );
    cell.clear();
  }

  for (var i = 0; i < text.length; i++) {
    final ch = text[i];
    if (quoted) {
      if (ch == '"' && i + 1 < text.length && text[i + 1] == '"') {
        cell.write('"');
        i++;
      } else if (ch == '"') {
        quoted = false;
      } else {
        cell.write(ch);
      }
    } else if (ch == '"' && cell.isEmpty) {
      quoted = true;
    } else if (ch == '\t') {
      endCell();
    } else if (ch == '\n' || ch == '\r') {
      if (ch == '\r' && i + 1 < text.length && text[i + 1] == '\n') i++;
      endCell();
      rows.add(row);
      row = <XCell>[];
    } else {
      cell.write(ch);
    }
  }
  if (cell.isNotEmpty || row.isNotEmpty) {
    endCell();
    rows.add(row);
  }
  return XWorkbook([XSheet('粘贴', rows)], date1904: false);
}
