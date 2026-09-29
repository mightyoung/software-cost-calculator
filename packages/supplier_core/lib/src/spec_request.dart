import 'dart:convert';

import 'entities.dart';
import 'product_params.dart';
import 'spec_compare.dart';
import 'spec_constraint.dart';
import 'spec_dictionary.dart';
import 'spec_match.dart';
import 'spec_parse.dart';
import 'spec_values.dart';
import 'store.dart';
import 'values.dart';

/// Who read a clause into constraints.
const clauseSources = ['rule', 'ai', 'manual'];

/// One clause of a requirement ("（5）防护等级不低于IP65。") and the
/// constraints read from it. No constraints: a text clause a person judges.
class SpecClause {
  const SpecClause(
    this.n,
    this.text, {
    this.mark = ClauseMark.none,
    this.constraints = const [],
    this.by = 'rule',
    this.reviewed = false,
    this.hint,
  });
  final int n;
  final String text;
  final ClauseMark mark;
  final List<SpecConstraint> constraints;
  final String by;

  /// A person checked the reading.
  final bool reviewed;

  /// Why the reading needs checking ("未识别：2K"); null when clean.
  final String? hint;

  bool get isText => constraints.isEmpty;

  SpecClause copyWith({
    ClauseMark? mark,
    List<SpecConstraint>? constraints,
    String? by,
    bool? reviewed,
    String? Function()? hint,
  }) {
    final m = mark ?? this.mark;
    return SpecClause(
      n,
      text,
      mark: m,
      constraints: [
        for (final c in constraints ?? this.constraints)
          SpecConstraint(c.property, c.op, c.value, mark: m, text: c.text),
      ],
      by: by ?? this.by,
      reviewed: reviewed ?? this.reviewed,
      hint: hint == null ? this.hint : hint(),
    );
  }

  Map<String, Object?> toJson() => {
    'n': n,
    'text': text,
    'mark': mark.name,
    'cs': [for (final c in constraints) c.toJson()],
    'by': by,
    'reviewed': reviewed,
    'hint': hint,
  };

  /// Validated clause; constraints on known parameters are normalized.
  static SpecClause fromJson(Object? raw) {
    if (raw is! Map) invalid('clauses', 'expected objects');
    final m = raw.cast<String, Object?>();
    exactKeys(m, const ['n', 'text', 'mark', 'cs', 'by', 'reviewed', 'hint']);
    final mark = ClauseMark.values.asNameMap()[m['mark']];
    if (mark == null) invalid('clauses.mark', 'unknown value');
    if (!clauseSources.contains(m['by']))
      invalid('clauses.by', 'unknown value');
    if (m['reviewed'] is! bool)
      invalid('clauses.reviewed', 'expected true or false');
    final cs = m['cs'];
    if (cs is! List || cs.length > 20)
      invalid('clauses.cs', 'expected at most 20 constraints');
    return SpecClause(
      requireSafeInteger(m['n'], 'clauses.n', min: 1, max: 9999),
      normalizeText(m['text'], 'clauses.text', 2000, required: true)!,
      mark: mark,
      constraints: [for (final c in cs) _constraint(c, mark)],
      by: m['by']! as String,
      reviewed: m['reviewed']! as bool,
      hint: normalizeText(m['hint'], 'clauses.hint', 500),
    );
  }

  static SpecConstraint _constraint(Object? raw, ClauseMark mark) {
    if (raw is! Map) invalid('clauses.cs', 'expected objects');
    final m = raw.cast<String, Object?>();
    exactKeys(m, const ['p', 'op', 'value', 'mark', 'weight', 'text']);
    final code = requireSpecCode(m['p'], 'clauses.cs.p');
    final op = m['op'];
    if (op is! String || !opLabels.containsKey(op))
      invalid('clauses.cs.op', 'unknown value');
    final p = specProperty(code);
    final value = m['value'];
    if (value is! Map || jsonEncode(value).length > 2000)
      invalid('clauses.cs.value', 'expected object');
    if (p != null && !opsFor(p).contains(op))
      invalid('clauses.cs.op', 'does not fit the parameter');
    final weight = m['weight'] == null
        ? null
        : requireSafeInteger(
            m['weight'],
            'clauses.cs.weight',
            min: 1,
            max: 100,
          );
    return SpecConstraint(
      code,
      op,
      p == null ? value.cast<String, Object?>() : normalizeParamValue(p, value),
      mark: mark,
      weight: weight,
      text: normalizeText(m['text'], 'clauses.cs.text', 500),
    );
  }
}

/// A technical requirement document, usually under a project.
final class SpecRequest extends EntityPayload {
  SpecRequest._(super.payload);
  static const fields = [
    'project_id',
    'title',
    'source_name',
    'dict_version',
    'notes',
  ];
  factory SpecRequest.fromJson(Map<String, Object?> value) {
    exactKeys(value, fields);
    return SpecRequest._({
      'project_id': value['project_id'] == null
          ? null
          : requireUuid(value['project_id'], 'project_id'),
      'title': normalizeText(value['title'], 'title', 200, required: true),
      'source_name': normalizeText(value['source_name'], 'source_name', 200),
      'dict_version': requireSafeInteger(
        value['dict_version'],
        'dict_version',
        min: 1,
        max: 9999,
      ),
      'notes': normalizeText(value['notes'], 'notes', 2000),
    });
  }
}

/// One piece of equipment in a requirement and its clauses; the chosen
/// material and a snapshot of how it was judged.
final class SpecItem extends EntityPayload {
  SpecItem._(super.payload);
  static const fields = [
    'request_id',
    'seq',
    'name',
    'spec_class',
    'qty',
    'unit',
    'text',
    'project_item_id',
    'clauses',
    'chosen_product_id',
    'chosen_snapshot',
    'notes',
  ];
  factory SpecItem.fromJson(Map<String, Object?> value) {
    final v = {'chosen_snapshot': null, ...value};
    exactKeys(v, fields);
    final clauses = v['clauses'];
    if (clauses is! List || clauses.length > 300) {
      invalid('clauses', 'expected at most 300 clauses');
    }
    final qty = v['qty'];
    final snapshot = v['chosen_snapshot'];
    if (snapshot != null &&
        (snapshot is! Map || jsonEncode(snapshot).length > 100000)) {
      invalid('chosen_snapshot', 'expected object');
    }
    if (snapshot is Map) _validateSnapshot(snapshot);
    return SpecItem._({
      'request_id': requireUuid(v['request_id'], 'request_id'),
      'seq': requireSafeInteger(v['seq'], 'seq', min: 1, max: 9999),
      'name': normalizeText(v['name'], 'name', 200, required: true),
      'spec_class': v['spec_class'] == null
          ? null
          : requireSpecCode(v['spec_class'], 'spec_class'),
      'qty': qty == null
          ? null
          : tryDecimal('$qty', positive: true) ??
                invalid('qty', 'expected a positive number'),
      'unit': normalizeText(v['unit'], 'unit', 50),
      'text': normalizeText(v['text'], 'text', 20000),
      'project_item_id': v['project_item_id'] == null
          ? null
          : requireUuid(v['project_item_id'], 'project_item_id'),
      'clauses': [for (final c in clauses) SpecClause.fromJson(c).toJson()],
      'chosen_product_id': v['chosen_product_id'] == null
          ? null
          : requireUuid(v['chosen_product_id'], 'chosen_product_id'),
      'chosen_snapshot': snapshot,
      'notes': normalizeText(v['notes'], 'notes', 2000),
    });
  }
}

/// A chosen snapshot is historical evidence, not a live recomputation. Check
/// its shape without rewriting text, timestamps, outcomes or product identity.
void _validateSnapshot(Map raw) {
  final m = raw.cast<String, Object?>();
  exactKeys(m, const [
    'product_id',
    'name',
    'brand',
    'model',
    'at',
    'dict_version',
    'rows',
  ]);
  requireUuid(m['product_id'], 'chosen_snapshot.product_id');
  for (final field in ['name', 'brand', 'model']) {
    if (m[field] != null && m[field] is! String) {
      invalid('chosen_snapshot.$field', 'expected text');
    }
  }
  final at = m['at'];
  if (at is! String || DateTime.tryParse(at) == null) {
    invalid('chosen_snapshot.at', 'expected timestamp');
  }
  requireSafeInteger(
    m['dict_version'],
    'chosen_snapshot.dict_version',
    min: 1,
    max: 9999,
  );
  final rows = m['rows'];
  if (rows is! List || rows.length > 300) {
    invalid('chosen_snapshot.rows', 'expected at most 300 rows');
  }
  final seen = <int>{};
  for (final row in rows) {
    if (row is! Map) invalid('chosen_snapshot.rows', 'expected objects');
    final r = row.cast<String, Object?>();
    exactKeys(r, const ['n', 'response', 'outcome', 'note', 'manual']);
    final n = requireSafeInteger(
      r['n'],
      'chosen_snapshot.rows.n',
      min: 1,
      max: 9999,
    );
    if (!seen.add(n)) invalid('chosen_snapshot.rows.n', 'duplicate clause');
    for (final field in ['response', 'note']) {
      if (r[field] != null && r[field] is! String) {
        invalid('chosen_snapshot.rows.$field', 'expected text');
      }
    }
    if (r['outcome'] != null &&
        (r['outcome'] is! String ||
            !Outcome.values.asNameMap().containsKey(r['outcome']))) {
      invalid('chosen_snapshot.rows.outcome', 'unknown outcome');
    }
    if (r['manual'] is! bool)
      invalid('chosen_snapshot.rows.manual', 'expected boolean');
  }
}

/// Deviation words of a technical deviation table (技术偏离表).
const deviationLabels = {
  Outcome.exact: '无偏离',
  Outcome.better: '正偏离',
  Outcome.worse: '负偏离',
  Outcome.unknown: '待确认',
};

/// The worst outcome of a clause's constraints decides its deviation.
Outcome clauseOutcome(Iterable<Outcome> outcomes) {
  final all = outcomes.toSet();
  if (all.contains(Outcome.worse)) return Outcome.worse;
  if (all.isEmpty || all.contains(Outcome.unknown)) return Outcome.unknown;
  return all.contains(Outcome.better) ? Outcome.better : Outcome.exact;
}

List<SpecClause> clausesOf(Record item) => [
  for (final c in item.data['clauses']! as List) SpecClause.fromJson(c),
];

List<SpecConstraint> constraintsOf(Iterable<SpecClause> clauses) => [
  for (final c in clauses) ...c.constraints,
];

extension SpecRequests on Store {
  /// Saves a requirement with its parsed items in one transaction.
  String createSpecRequest(
    String title,
    List<SpecItemDraft> items, {
    String? projectId,
    String? sourceName,
    String? notes,
  }) => transaction(() {
    final id = save('spec_request', {
      'project_id': projectId,
      'title': title,
      'source_name': sourceName,
      'dict_version': specDictionaryVersion,
      'notes': notes,
    });
    for (final (i, d) in items.indexed) {
      save('spec_item', {
        'request_id': id,
        'seq': i + 1,
        'name': d.name.trim().isEmpty ? '第 ${i + 1} 项' : d.name.trim(),
        'spec_class': d.specClass,
        'qty': d.qty == null ? null : tryDecimal(d.qty!, positive: true),
        'unit': d.unit,
        'text': d.text.trim().isEmpty ? null : d.text,
        'project_item_id': d.projectItemId,
        'clauses': [for (final c in d.clauses) c.toJson()],
        'chosen_product_id': null,
        'notes': null,
      });
    }
    return id;
  });

  /// Drafts for a project's material lines still to be inquired (no
  /// material yet), read from each line's technical requirement.
  List<SpecItemDraft> draftsFromProject(String projectId) => [
    for (final r in db.select(
      "SELECT id FROM project_item WHERE deleted = 0 "
      "AND json_extract(data,'\$.project_id') = ? "
      "AND json_extract(data,'\$.category') = 'material' "
      "AND json_extract(data,'\$.product_id') IS NULL",
      [projectId],
    ))
      if (get('project_item', r['id'] as String) case final line?)
        draftItem(
          line.data['name']! as String,
          (line.data['requirement'] as String?) ?? '',
          qty: line.data['qty'] as String?,
          unit: line.data['unit'] as String?,
          projectItemId: line.id,
        ),
  ];

  /// Live items of a requirement in their order.
  List<Record> specItemsOf(String requestId) => [
    for (final r in db.select(
      "SELECT id FROM spec_item WHERE deleted = 0 "
      "AND json_extract(data,'\$.request_id') = ? "
      "ORDER BY json_extract(data,'\$.seq')",
      [requestId],
    ))
      get('spec_item', r['id'] as String)!,
  ];

  /// Live requirements, newest first, optionally of one project.
  List<Record> specRequests({String? projectId}) => [
    for (final r in db.select(
      'SELECT id FROM spec_request WHERE deleted = 0 '
      "AND (? IS NULL OR json_extract(data,'\$.project_id') = ?) "
      'ORDER BY updated_at DESC',
      [projectId, projectId],
    ))
      get('spec_request', r['id'] as String)!,
  ];

  /// Deletes a requirement and its items (restorable from the trash).
  void deleteSpecRequest(String id) => transaction(() {
    for (final item in specItemsOf(id)) {
      delete('spec_item', item.id);
    }
    delete('spec_request', id);
  });

  /// Rewrites an item's clauses (and class, which re-reads unreviewed
  /// clauses when it changes).
  void saveClauses(
    String itemId,
    List<SpecClause> clauses, {
    String? specClass,
  }) {
    final item = get('spec_item', itemId)!;
    final cls = specClass ?? item.data['spec_class'] as String?;
    final reread = cls != item.data['spec_class'];
    save(
      'spec_item',
      {
        ...item.data,
        'spec_class': cls,
        'clauses': [
          for (final c in clauses)
            (reread && !c.reviewed ? parseClause(cls, c.n, c.text) : c)
                .toJson(),
        ],
      },
      id: itemId,
      allowClear: true,
    );
  }

  /// Chooses [productId] for the item and records, clause by clause, what
  /// the material offers and how it deviates, for the deviation table.
  /// Text clauses keep the response a person gave earlier.
  /// A linked budget line still without a material gets this one.
  void chooseProduct(String itemId, String productId, {DateTime? asOf}) =>
      transaction(() => _choose(itemId, productId, asOf));

  void _choose(String itemId, String productId, DateTime? asOf) {
    final item = get('spec_item', itemId)!;
    final product = get('product', productId)!;
    final clauses = clausesOf(item);
    final result = matchSpec(
      product.data['spec_class'] as String? ?? '',
      constraintsOf(clauses),
      asOf: asOf,
      productIds: [productId],
    );
    final judged = result.candidates.single.results;
    final before = {
      for (final r in (snapshotRows(item) ?? const []))
        if (r['manual'] == true) r['n']: r,
    };
    var k = 0;
    final rows = <Map<String, Object?>>[];
    for (final c in clauses) {
      final mine = judged.sublist(k, k + c.constraints.length);
      k += c.constraints.length;
      if (c.isText) {
        rows.add(
          before[c.n] ??
              {
                'n': c.n,
                'response': null,
                'outcome': null,
                'note': null,
                'manual': true,
              },
        );
        continue;
      }
      rows.add({
        'n': c.n,
        'response': [
          for (final r in mine)
            if (specProperty(r.constraint.property) case final p?)
              r.have == null
                  ? '${p.label}：未提供'
                  : '${p.label} ${formatParamValue(p, r.have!)}',
        ].join('；'),
        'outcome': clauseOutcome([
          for (final r in mine) r.verdict.outcome,
        ]).name,
        'note': [
          for (final r in mine) ?r.verdict.note,
          if (mine.any((r) => r.unconfirmed)) '参数未确认',
          if (mine.any((r) => r.derived)) '推算值',
        ].join('；').nullIfEmpty,
        'manual': false,
      });
    }
    save(
      'spec_item',
      {
        ...item.data,
        'chosen_product_id': productId,
        'chosen_snapshot': {
          'product_id': productId,
          'name': product.data['name'],
          'brand': product.data['brand'],
          'model': product.data['model'],
          'at': (asOf ?? clock()).toUtc().toIso8601String(),
          'dict_version': specDictionaryVersion,
          'rows': rows,
        },
      },
      id: itemId,
      allowClear: true,
    );
    final lineId = item.data['project_item_id'] as String?;
    final line = lineId == null ? null : get('project_item', lineId);
    if (line != null && !line.deleted && line.data['product_id'] == null) {
      save('project_item', {
        ...line.data,
        'product_id': productId,
      }, id: line.id);
    }
  }

  /// Sets a person's response to a text clause in the snapshot.
  void setClauseResponse(
    String itemId,
    int n,
    String? response,
    Outcome? outcome,
  ) {
    final item = get('spec_item', itemId)!;
    final snap = (item.data['chosen_snapshot'] as Map?)
        ?.cast<String, Object?>();
    if (snap == null) invalid('chosen_snapshot', 'no material chosen');
    save(
      'spec_item',
      {
        ...item.data,
        'chosen_snapshot': {
          ...snap,
          'rows': [
            for (final r in snapshotRows(item)!)
              r['n'] == n
                  ? {
                      ...r,
                      'response': response?.trim().isEmpty ?? true
                          ? null
                          : response!.trim(),
                      'outcome': outcome?.name,
                      'manual': true,
                    }
                  : r,
          ],
        },
      },
      id: itemId,
      allowClear: true,
    );
  }

  void clearChoice(String itemId) {
    final item = get('spec_item', itemId)!;
    save(
      'spec_item',
      {...item.data, 'chosen_product_id': null, 'chosen_snapshot': null},
      id: itemId,
      allowClear: true,
    );
  }
}

List<Map<String, Object?>>? snapshotRows(Record item) => [
  for (final r
      in ((item.data['chosen_snapshot'] as Map?)?['rows'] as List? ?? const []))
    (r as Map).cast<String, Object?>(),
].nullIfEmpty;

extension<T> on List<T> {
  List<T>? get nullIfEmpty => isEmpty ? null : this;
}

extension on String {
  String? get nullIfEmpty => isEmpty ? null : this;
}
