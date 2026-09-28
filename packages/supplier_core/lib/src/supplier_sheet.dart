import 'duplicates.dart';
import 'entities.dart';
import 'search.dart';
import 'store.dart';
import 'xlsx.dart';

const _headers = {
  'name': ['供应商', '供应商名称', '公司名称', '单位名称', '名称', '厂家', '厂商'],
  'aliases': ['简称', '别名'],
  'categories': ['类别', '主营', '主营类别', '供货类别', '分类'],
  'address': ['地址', '公司地址'],
  'contact_name': ['联系人'],
  'phone': ['电话', '联系电话', '手机', '手机号', '联系方式'],
  'wechat': ['微信'],
  'email': ['邮箱', '电子邮箱'],
  'notes': ['备注', '说明'],
};

/// One row of a supplier list: a new supplier, or an existing one that may
/// get a new contact.
class SupplierRowPlan {
  SupplierRowPlan(
    this.row,
    this.name, {
    this.existingId,
    this.supplier,
    this.contact,
    this.error,
  });
  final int row;
  final String? name, existingId, error;

  /// Payload for a new supplier; null when [existingId] is used.
  final Map<String, Object?>? supplier;

  /// Contact to add unless the supplier already has one with the same
  /// phone, WeChat or email.
  final Map<String, Object?>? contact;
}

List<String> _split(String? s) => [
  for (final p in (s ?? '').split(RegExp(r'[，,、;；/\s]+')))
    if (p.trim().isNotEmpty) p.trim(),
];

extension SupplierSheet on Store {
  /// Reads a supplier list (name column required). Writes nothing; null
  /// when no sheet has a supplier-name header.
  List<SupplierRowPlan>? planSupplierSheet(XWorkbook book) {
    for (final sheet in book.sheets) {
      for (var h = 0; h < sheet.rows.length && h < 10; h++) {
        final col = <String, int>{};
        for (final (i, c) in sheet.rows[h].indexed) {
          final n = c.display.replaceAll(RegExp(r'\s'), '');
          for (final MapEntry(:key, :value) in _headers.entries) {
            if (value.contains(n) && !col.containsKey(key)) col[key] = i;
          }
        }
        if (!col.containsKey('name')) continue;
        final seen = <String>{};
        return [
          for (var r = h + 1; r < sheet.rows.length; r++)
            if (sheet.rows[r].any((c) => !c.isBlank))
              _planSupplier(r + 1, sheet.rows[r], col, seen),
        ];
      }
    }
    return null;
  }

  SupplierRowPlan _planSupplier(
    int row,
    List<XCell> cells,
    Map<String, int> col,
    Set<String> seen,
  ) {
    String? at(String key) {
      final i = col[key];
      if (i == null || i >= cells.length || cells[i].isBlank) return null;
      return cells[i].display.trim();
    }

    final name = at('name');
    if (name == null) return SupplierRowPlan(row, null, error: '缺少供应商名称');
    final key = companyKey(name);
    final phone = at('phone');
    final isPhone =
        phone != null && RegExp(r'^[+0-9][0-9 \-()]{6,}$').hasMatch(phone);
    final contact = {
      'name': at('contact_name') ?? '未留姓名',
      'phone': isPhone ? phone : null,
      'wechat': at('wechat'),
      'email': at('email'),
      'notes': phone != null && !isPhone ? '联系方式：$phone' : null,
    };
    final hasContact = [
      'phone',
      'wechat',
      'email',
    ].any((k) => contact[k] != null);
    final same = [
      for (final d in similarSuppliers(name))
        if (d.level == Similarity.same) d.hit.id,
    ];
    if (same.length > 1) {
      return SupplierRowPlan(row, name, error: '本机有多个同名供应商，请先合并');
    }
    final supplier = {
      for (final f in Supplier.fields) f: null,
      'name': name,
      'aliases': _split(at('aliases')),
      'categories': _split(at('categories')),
      'address': at('address'),
      'notes': at('notes'),
    };
    try {
      Supplier.fromJson(supplier);
      if (hasContact) {
        Contact.fromJson({
          ...contact,
          'supplier_id': '00000000-0000-4000-8000-000000000000',
        });
      }
    } on FormatException catch (e) {
      return SupplierRowPlan(row, name, error: e.message);
    }
    return SupplierRowPlan(
      row,
      name,
      existingId: same.isEmpty ? null : same.single,
      // A name repeated in the file creates the supplier once.
      supplier: same.isEmpty && seen.add(key) ? supplier : null,
      contact: hasContact ? contact : null,
    );
  }

  /// Creates suppliers and contacts in one transaction; returns the counts.
  ({int suppliers, int contacts}) applySupplierSheet(
    List<SupplierRowPlan> plans,
  ) => transaction(() {
    final created = <String, String>{};
    var suppliers = 0, contacts = 0;
    for (final p in plans) {
      if (p.error != null) continue;
      final key = companyKey(p.name!);
      final id =
          p.existingId ??
          (p.supplier != null
              ? created[key] = save('supplier', p.supplier!)
              : created[key]);
      if (p.supplier != null) suppliers++;
      final c = p.contact;
      if (id == null || c == null) continue;
      final known = contactsOf(id).any(
        (h) => [
          'phone',
          'wechat',
          'email',
        ].any((k) => c[k] != null && h.data[k] == c[k]),
      );
      if (!known) {
        save('contact', {...c, 'supplier_id': id});
        contacts++;
      }
    }
    return (suppliers: suppliers, contacts: contacts);
  });
}
