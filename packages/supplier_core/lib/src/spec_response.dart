import 'dart:convert';
import 'dart:typed_data';

import 'entities.dart';
import 'list_import.dart' show clipText;
import 'product_params.dart';
import 'spec_compare.dart';
import 'spec_constraint.dart';
import 'spec_dictionary.dart';
import 'spec_extract.dart';
import 'spec_match.dart';
import 'spec_request.dart';
import 'spec_values.dart';
import 'store.dart';
import 'values.dart';
import 'xlsx.dart';

// Supplier clause-by-clause responses (design §11, phase 5): the inquiry
// sheet carries a 技术响应 sheet; what the supplier guarantees per clause
// comes back, is judged against the clause, and forms the supplier
// deviation table. A stated "无偏离" that the value contradicts is flagged.

/// Columns of the 技术响应 sheet sent with an inquiry.
const responseSheetColumns = [
  '行号',
  '设备',
  '条款号',
  '条款',
  '技术要求',
  '保证值（请填具体值）',
  '偏离（无偏离/正偏离/负偏离）',
  '说明',
  '需求项ID',
];

/// What one supplier answered for one requirement item.
final class SpecResponse extends EntityPayload {
  SpecResponse._(super.payload);
  static const fields = [
    'item_id',
    'supplier_id',
    'inquiry_id',
    'rows',
    'received_on',
    'notes',
  ];
  factory SpecResponse.fromJson(Map<String, Object?> value) {
    exactKeys(value, fields);
    final rows = value['rows'];
    if (rows is! List || rows.length > 300) {
      invalid('rows', 'expected at most 300 clauses');
    }
    return SpecResponse._({
      'item_id': requireUuid(value['item_id'], 'item_id'),
      'supplier_id': requireUuid(value['supplier_id'], 'supplier_id'),
      'inquiry_id': value['inquiry_id'] == null
          ? null
          : requireUuid(value['inquiry_id'], 'inquiry_id'),
      'rows': [
        for (final r in rows)
          if (r is Map)
            {
              'n': requireSafeInteger(r['n'], 'rows.n', min: 1, max: 9999),
              'response': normalizeText(r['response'], 'rows.response', 500),
              'stated': r['stated'] == null
                  ? null
                  : Outcome.values.asNameMap().containsKey(r['stated'])
                  ? r['stated']
                  : invalid('rows.stated', 'unknown value'),
              'note': normalizeText(r['note'], 'rows.note', 500),
            }
          else
            invalid('rows', 'expected objects'),
      ],
      'received_on': value['received_on'] == null
          ? null
          : requireDate(value['received_on'], 'received_on'),
      'notes': normalizeText(value['notes'], 'notes', 2000),
    });
  }
}

/// One supplier row judged against its clause.
class ResponseCheck {
  ResponseCheck(
    this.clause,
    this.response,
    this.stated,
    this.checked, {
    this.note,
    this.why,
  });
  final SpecClause clause;
  final String? response, note;

  /// The supplier's own word, and the software's reading of the value (the
  /// stated one for text clauses).
  final Outcome? stated;
  final Outcome checked;

  /// Why the software disagrees or cannot tell ("上限不够", "未填写").
  final String? why;

  /// Claimed to meet the clause while the value does not.
  bool get contradicted =>
      stated != null &&
      (stated == Outcome.exact || stated == Outcome.better) &&
      checked == Outcome.worse;
}

/// "无偏离" → exact, "正偏离" → better, "负偏离" / "不满足" → worse.
Outcome? statedOutcome(String? text) {
  final t = text?.replaceAll(RegExp(r'\s'), '') ?? '';
  if (t.isEmpty) return null;
  if (t.contains('负偏离') || t.contains('不满足') || t.contains('不符合')) {
    return Outcome.worse;
  }
  if (t.contains('正偏离') || t.contains('优于')) return Outcome.better;
  if (t.contains('无偏离') || t == '无' || t.contains('满足') || t.contains('符合')) {
    return Outcome.exact;
  }
  return null;
}

String responseRecordId(String itemId, String supplierId) =>
    derivedUuid('spec_response:$itemId:$supplierId');

/// Judges [response] (what a supplier guarantees) against clause [c] of an
/// item of [classCode]: values are read like material parameters and
/// compared like a material's.
ResponseCheck checkClauseResponse(
  String? classCode,
  SpecClause c,
  String? response,
  Outcome? stated, {
  String? note,
  required String today,
}) {
  final text = response?.trim() ?? '';
  if (c.isText || classCode == null) {
    return ResponseCheck(
      c,
      response,
      stated,
      stated ?? Outcome.unknown,
      note: note,
    );
  }
  if (text.isEmpty) {
    return ResponseCheck(
      c,
      response,
      stated,
      Outcome.unknown,
      note: note,
      why: '未填写保证值',
    );
  }
  final read = {
    for (final g in extractParams(classCode, text)) g.property: g.value,
  };
  // A single-condition clause answered with a bare value ("IP66").
  if (c.constraints.length == 1 && read.isEmpty) {
    final p = specProperty(c.constraints.single.property);
    final v = p == null ? null : parseParamText(p, text);
    if (p != null && v != null) {
      try {
        read[p.code] = normalizeParamValue(p, v);
      } on FormatException {
        // stays unread
      }
    }
  }
  final verdicts = [
    for (final k in c.constraints)
      if (specProperty(k.property) case final p?)
        evaluateConstraint(
          p,
          read[k.property],
          k,
          span: p.type == ParamType.tol ? read[spanProperty(p)] : null,
          today: today,
        )
      else
        const Verdict(Outcome.unknown, '本机字典中没有这个参数'),
  ];
  final outcome = clauseOutcome([for (final v in verdicts) v.outcome]);
  final why = {
    for (final v in verdicts)
      if (!v.satisfied && v.note != null)
        v.note == '缺少参数' ? '保证值里没读出这一项' : v.note!,
  }.join('；');
  return ResponseCheck(
    c,
    response,
    stated,
    outcome,
    note: note,
    why: why.isEmpty ? null : why,
  );
}

/// Rows of a returned 技术响应 sheet for one item; writes nothing.
class ResponsePlan {
  ResponsePlan(this.itemId, this.itemName, this.rows);
  final String itemId, itemName;
  final List<Map<String, Object?>> rows;
}

extension SpecResponses on Store {
  /// Requirement items linked to budget lines of [inquiryId].
  List<Record> specItemsOfInquiry(String inquiryId) {
    final lines = get('inquiry', inquiryId)!.data['item_ids']! as List;
    return [
      for (final r in db.select(
        'SELECT id FROM spec_item WHERE deleted = 0 '
        "AND json_extract(data,'\$.project_item_id') IN (SELECT value FROM json_each(?)) "
        "ORDER BY json_extract(data,'\$.request_id'), json_extract(data,'\$.seq')",
        [jsonEncode(lines)],
      ))
        get('spec_item', r['id'] as String)!,
    ];
  }

  /// The 技术响应 sheet for an inquiry, or null when no line carries a
  /// technical requirement. 行号 follows the price sheet.
  SheetData? responseSheet(String inquiryId) {
    final lines = (get('inquiry', inquiryId)!.data['item_ids']! as List)
        .cast<String>()
        .where((id) => get('project_item', id)?.deleted == false)
        .toList();
    final items = specItemsOfInquiry(inquiryId);
    if (items.isEmpty) return null;
    const marks = {
      ClauseMark.star: '★',
      ClauseMark.triangle: '▲',
      ClauseMark.none: '',
    };
    final rows = <List<Object?>>[
      ['技术响应', '请逐条填写保证值（具体数值或型号参数，不写"满足"）和偏离；★ 为实质性条款'],
      [],
      responseSheetColumns,
    ];
    for (final item in items) {
      final line = lines.indexOf(item.data['project_item_id']! as String);
      for (final c in clausesOf(item)) {
        rows.add([
          Num('${line + 1}'),
          item.data['name'],
          Num('${c.n}'),
          marks[c.mark],
          c.text,
          null,
          null,
          null,
          item.id,
        ]);
      }
    }
    return SheetData(
      '技术响应',
      rows,
      widths: const [6, 16, 6, 5, 50, 30, 14, 20, 38],
      boldRows: const {2},
    );
  }

  /// Reads a returned 技术响应 sheet; empty rows are skipped. Null when the
  /// file has no such sheet.
  List<ResponsePlan>? planSpecResponses(Uint8List bytes, String inquiryId) {
    final items = {for (final i in specItemsOfInquiry(inquiryId)) i.id: i};
    final book = readXlsx(bytes);
    for (final sheet in book.sheets) {
      final h = sheet.rows.indexWhere(
        (r) => r.any((c) => c.display.trim().startsWith('保证值')),
      );
      if (h < 0) continue;
      int? col(String prefix) {
        final i = sheet.rows[h].indexWhere(
          (c) => c.display.trim().startsWith(prefix),
        );
        return i < 0 ? null : i;
      }

      final (id, n, value, dev, note) = (
        col('需求项ID'),
        col('条款号'),
        col('保证值'),
        col('偏离'),
        col('说明'),
      );
      if (id == null || n == null || value == null) continue;
      final byItem = <String, List<Map<String, Object?>>>{};
      for (final row in sheet.rows.skip(h + 1)) {
        String? at(int? i) => i == null || i >= row.length || row[i].isBlank
            ? null
            : row[i].display.trim();
        final item = at(id), number = int.tryParse(at(n) ?? '');
        if (item == null || number == null || !items.containsKey(item))
          continue;
        final response = at(value), stated = at(dev), remark = at(note);
        if (response == null && stated == null && remark == null) continue;
        (byItem[item] ??= []).add({
          'n': number,
          'response': response,
          'stated': statedOutcome(stated)?.name,
          'note': remark,
        });
      }
      return [
        for (final MapEntry(:key, :value) in byItem.entries)
          ResponsePlan(key, '${items[key]!.data['name']}', value),
      ];
    }
    return null;
  }

  /// Saves the plans as [supplierId]'s responses; a clause answered again
  /// replaces the earlier answer. Returns how many clauses were recorded.
  int applySpecResponses(
    List<ResponsePlan> plans,
    String supplierId, {
    String? inquiryId,
    String? receivedOn,
  }) => transaction(() {
    var n = 0;
    for (final plan in plans) {
      final id = responseRecordId(plan.itemId, supplierId);
      final old = get('spec_response', id);
      final rows = {
        for (final r
            in (old?.deleted == false ? old!.data['rows']! as List : const []))
          (r as Map)['n']: r,
        for (final r in plan.rows) r['n']: r,
      };
      final payload = {
        'item_id': plan.itemId,
        'supplier_id': supplierId,
        'inquiry_id': inquiryId,
        'rows': rows.values.toList(),
        'received_on': receivedOn ?? localDay(clock()),
        'notes': old?.data['notes'],
      };
      if (old == null) {
        save('spec_response', payload, newId: id);
      } else {
        if (old.deleted) restore('spec_response', id);
        save('spec_response', payload, id: id, allowClear: true);
      }
      n += plan.rows.length;
    }
    return n;
  });

  /// Live responses to an item, by supplier.
  List<Record> responsesOf(String itemId) => [
    for (final r in db.select(
      'SELECT id FROM spec_response WHERE deleted = 0 '
      "AND json_extract(data,'\$.item_id') = ?",
      [itemId],
    ))
      get('spec_response', r['id'] as String)!,
  ];

  /// A supplier's response judged clause by clause (every clause, answered
  /// or not).
  List<ResponseCheck> checkResponse(
    Record item,
    Record response, {
    DateTime? asOf,
  }) {
    final today = localDay(asOf ?? clock());
    final rows = {
      for (final r in response.data['rows']! as List) (r as Map)['n']: r,
    };
    return [
      for (final c in clausesOf(item))
        checkClauseResponse(
          item.data['spec_class'] as String?,
          c,
          rows[c.n]?['response'] as String?,
          rows[c.n]?['stated'] == null
              ? null
              : Outcome.values.byName(rows[c.n]!['stated']! as String),
          note: rows[c.n]?['note'] as String?,
          today: today,
        ),
    ];
  }

  /// 供应商偏离表: per item and clause, each supplier's guarantee and the
  /// deviation as judged (a contradicted claim is marked).
  Uint8List supplierDeviationXlsx(String requestId, {DateTime? asOf}) {
    final req = get('spec_request', requestId)!.data;
    final sheets = <SheetData>[];
    final summary = <List<Object?>>[
      ['供应商偏离表', '${req['title']}'],
      [],
      ['设备', '供应商', '负偏离', '待确认', '声明与数值不符'],
    ];
    for (final item in specItemsOf(requestId)) {
      final responses = responsesOf(item.id);
      if (responses.isEmpty) continue;
      final checks = {
        for (final r in responses)
          '${get('supplier', r.data['supplier_id']! as String)?.data['name'] ?? '?'}':
              checkResponse(item, r, asOf: asOf),
      };
      final rows = <List<Object?>>[
        ['${item.data['seq']}. ${item.data['name']}'],
        [
          '条款号',
          '技术要求',
          for (final s in checks.keys) ...['$s 保证值', '$s 偏离'],
        ],
      ];
      for (final (i, c) in clausesOf(item).indexed) {
        rows.add([
          Num('${c.n}'),
          '${c.mark == ClauseMark.star
              ? '★'
              : c.mark == ClauseMark.triangle
              ? '▲'
              : ''}${c.text}',
          for (final list in checks.values) ...[
            list[i].response ?? '',
            [
              deviationLabels[list[i].checked],
              if (list[i].contradicted)
                '（声明${deviationLabels[list[i].stated]}，与数值不符）',
              if (list[i].why case final w?
                  when list[i].checked != Outcome.exact)
                '：$w',
            ].join(),
          ],
        ]);
      }
      for (final MapEntry(key: s, value: list) in checks.entries) {
        summary.add([
          '${item.data['name']}',
          s,
          Num('${list.where((x) => x.checked == Outcome.worse).length}'),
          Num('${list.where((x) => x.checked == Outcome.unknown).length}'),
          Num('${list.where((x) => x.contradicted).length}'),
        ]);
      }
      sheets.add(
        SheetData(
          '${item.data['seq']}',
          rows,
          widths: [
            6,
            48,
            for (final _ in checks.keys) ...[26, 22],
          ],
          boldRows: const {0, 1},
        ),
      );
    }
    return writeXlsx([
      SheetData(
        '汇总',
        summary,
        widths: const [24, 24, 10, 10, 16],
        boldRows: const {0, 2},
      ),
      ...sheets,
    ]);
  }

  /// 加入预算: items of a project's requirement without a budget line get a
  /// material line still to be inquired (name, quantity, requirement text).
  /// Returns how many lines were added.
  int addItemsToBudget(String requestId) => transaction(() {
    final req = get('spec_request', requestId)!.data;
    final projectId = req['project_id'] as String?;
    if (projectId == null) invalid('project_id', 'required');
    var n = 0;
    for (final item in specItemsOf(requestId)) {
      final d = item.data;
      if (d['project_item_id'] != null) continue;
      final text = (d['text'] as String?)?.replaceAll(RegExp(r'\s*\n\s*'), '；');
      final line = save('project_item', {
        'project_id': projectId,
        'category': 'material',
        'product_id': d['chosen_product_id'],
        'name': d['name'],
        'qty': d['qty'] ?? '1',
        'unit': d['unit'] ?? '项',
        'quotation_id': null,
        'unit_cost': '0',
        'unit_price': null,
        'requirement': text == null ? null : clipText(text, 2000),
        'notes': null,
      });
      save('spec_item', {...d, 'project_item_id': line}, id: item.id);
      n++;
    }
    return n;
  });

  /// How often each material was chosen for requirements of [classCode]
  /// (the selection library: past choices for this kind of equipment).
  Map<String, int> chosenCounts(String classCode) {
    final out = <String, int>{};
    for (final r in db.select(
      "SELECT json_extract(data,'\$.chosen_product_id') AS p FROM spec_item "
      "WHERE deleted = 0 AND json_extract(data,'\$.chosen_product_id') IS NOT NULL "
      "AND json_extract(data,'\$.spec_class') IN (SELECT value FROM json_each(?))",
      [jsonEncode(classFamily(classCode).toList())],
    )) {
      final p = r['p'] as String;
      out[p] = (out[p] ?? 0) + 1;
    }
    return out;
  }
}
