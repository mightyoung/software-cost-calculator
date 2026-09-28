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
  'category': ['类别', '设备类别', '物料类别', '分类'],
  'unit': ['单位', '计量单位'],
  'price': ['单价', '含税单价', '不含税单价', '报价', '参考单价'],
  'qty': ['数量'],
  'supplier': ['供应商', '供应商名称', '供货商', '厂家', '厂商', '生产厂家'],
  'contact_name': ['联系人'],
  'phone': ['联系方式', '电话', '联系电话', '手机', '手机号'],
  'wechat': ['微信'],
  'email': ['邮箱', '电子邮箱'],
  'currency': ['币种'],
  'tax_rate': ['税率'],
  'quoted_on': ['报价日期'],
  'valid_until': ['有效期至', '有效期'],
  'lead_time_days': ['交期', '交货期'],
  'notes': ['备注', '说明'],
};

String _norm(String s) =>
    s.replaceAll(RegExp(r'\s'), '').replaceAll(RegExp(r'[（(][^）)]*[）)]$'), '');

/// Reads offers straight from a table with a recognizable header (a name
/// column plus a price, brand or model column), without AI. Rows whose name
/// is blank continue the row above (merged cells: extra requirement lines).
/// Without a supplier column the brand stands in as the supplier. Returns
/// null when no sheet has such a header.
List<Offer>? offersFromWorkbook(XWorkbook book) {
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
      if (!col.containsKey('name') ||
          !['price', 'brand', 'model'].any(col.containsKey)) {
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
          raws.last[k] = [?raws.last[k] as String?, more].join('\n');
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
  return [for (final r in raws) cleanOffer(r)];
}
