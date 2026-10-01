import 'dart:convert';

import 'budget.dart';
import 'spec_compare.dart';
import 'spec_constraint.dart';
import 'spec_dictionary.dart';
import 'store.dart';
import 'values.dart';

/// One constraint judged for one material.
class ClauseResult {
  ClauseResult(
    this.constraint,
    this.verdict, {
    this.have,
    this.unconfirmed = false,
    this.derived = false,
  });
  final SpecConstraint constraint;
  final Verdict verdict;

  /// The material's value as stored (null when missing).
  final Map<String, Object?>? have;

  /// The value has not been checked by a person yet.
  final bool unconfirmed;

  /// Computed from other parameters (e.g. total memory).
  final bool derived;
}

enum MatchGroup {
  full, // 完全满足: everything satisfied
  partial, // 基本满足: no hard clause fails; soft fails or unknowns remain
  failed, // 不满足: a hard clause fails
}

const matchGroupLabels = {
  MatchGroup.full: '完全满足',
  MatchGroup.partial: '基本满足',
  MatchGroup.failed: '不满足',
};

class Candidate {
  Candidate(
    this.id,
    this.data,
    this.results,
    this.group, {
    this.price,
    this.priceUnit,
  });
  final String id;
  final Map<String, Object?> data;
  final List<ClauseResult> results;
  final MatchGroup group;

  /// Lowest valid quoted unit price (CNY, tax included), if any.
  final String? price;
  final String? priceUnit;

  int count(Outcome o) => results.where((r) => r.verdict.outcome == o).length;
  int get satisfied => results.where((r) => r.verdict.satisfied).length;
}

class MatchResult {
  MatchResult(this.candidates, this.relaxGain, {required this.allHard});

  /// Ranked best first.
  final List<Candidate> candidates;

  /// Per constraint index: how many more materials would fully satisfy
  /// the requirement if that one constraint were dropped.
  final Map<int, int> relaxGain;

  /// No clause carried ★ or ▲, so every clause was treated as hard.
  final bool allHard;

  int size(MatchGroup g) => candidates.where((c) => c.group == g).length;
}

/// [classCode] and every class inheriting from it.
Set<String> classFamily(String classCode) {
  final out = {classCode};
  var grew = true;
  while (grew) {
    grew = false;
    for (final c in specClasses) {
      if (c.parent != null && out.contains(c.parent) && out.add(c.code))
        grew = true;
    }
  }
  return out;
}

/// The range parameter that a %FS tolerance refers to: the first range in
/// the same group of the same quantity ("gas.accuracy" → "gas.range").
String? spanProperty(SpecProperty p) {
  final prefix = p.code.split('.').first;
  for (final q in specProperties) {
    if (q.type == ParamType.range &&
        q.kind == p.kind &&
        q.code.startsWith('$prefix.')) {
      return q.code;
    }
  }
  return null;
}

extension SpecMatch on Store {
  /// Live materials of [classCode] and its sub-classes, by name.
  List<Record> productsOfClass(String classCode) => [
    for (final r in db.select(
      'SELECT id FROM product WHERE deleted = 0 '
      "AND json_extract(data,'\$.merged_into') IS NULL "
      "AND json_extract(data,'\$.spec_class') IN (SELECT value FROM json_each(?)) "
      "ORDER BY json_extract(data,'\$.name')",
      [jsonEncode(classFamily(classCode).toList())],
    ))
      get('product', r['id'] as String)!,
  ];

  /// Materials of [classCode] (and its sub-classes) judged against
  /// [constraints], ranked: fewest hard failures, then least failed and
  /// unknown weight, most positive deviations, a valid quote, lowest price.
  /// Without any ★/▲ mark every clause is hard.
  MatchResult matchSpec(
    String classCode,
    List<SpecConstraint> constraints, {
    DateTime? asOf,
    List<String>? productIds,
  }) {
    final today = localDay(asOf ?? clock());
    final allHard = constraints.every((c) => c.mark == ClauseMark.none);
    bool hard(SpecConstraint c) => allHard || c.mark == ClauseMark.star;

    // productIds: judge exactly these materials, whatever their class.
    final products = productIds != null
        ? db.select(
            'SELECT id, data FROM product WHERE id IN '
            '(SELECT value FROM json_each(?))',
            [jsonEncode(productIds)],
          )
        : db.select(
            'SELECT id, data FROM product WHERE deleted = 0 '
            "AND json_extract(data,'\$.merged_into') IS NULL "
            "AND json_extract(data,'\$.spec_class') IN "
            '(SELECT value FROM json_each(?))',
            [jsonEncode(classFamily(classCode).toList())],
          );
    final ids = [for (final r in products) r['id'] as String];
    final params = <String, Map<String, Map<String, Object?>>>{};
    for (final r in db.select(
      'SELECT data FROM product_param WHERE deleted = 0 '
      "AND json_extract(data,'\$.product_id') IN (SELECT value FROM json_each(?))",
      [jsonEncode(ids)],
    )) {
      final d = jsonDecode(r['data'] as String) as Map<String, Object?>;
      (params[d['product_id']! as String] ??= {})[d['property']! as String] = d;
    }

    final candidates = <Candidate>[];
    for (final r in products) {
      final id = r['id'] as String;
      final data = jsonDecode(r['data'] as String) as Map<String, Object?>;
      final mine = params[id] ?? const {};
      Map<String, Object?>? value(String code) =>
          (mine[code]?['value'] as Map?)?.cast<String, Object?>();
      final results = [
        for (final c in constraints)
          () {
            final p = specProperty(c.property);
            if (p == null) {
              return ClauseResult(
                c,
                const Verdict(Outcome.unknown, '本机字典中没有这个参数'),
              );
            }
            var have = value(c.property);
            var derived = false;
            if (have == null) {
              have = _derived(c.property, value);
              derived = have != null;
            }
            final spanCode = p.type == ParamType.tol ? spanProperty(p) : null;
            return ClauseResult(
              c,
              evaluateConstraint(
                p,
                have,
                c,
                span: spanCode == null ? null : value(spanCode),
                today: today,
              ),
              have: have,
              unconfirmed:
                  [
                    if (!derived) c.property,
                    if (derived && c.property == 'mem.total') ...[
                      'mem.dimm_size',
                      'mem.dimm_count',
                    ],
                    if (spanCode != null && have?['basis'] == 'FS') spanCode,
                  ].any(
                    (code) =>
                        mine[code] != null && mine[code]!['confirmed'] != true,
                  ),
              derived: derived,
            );
          }(),
      ];
      final group =
          results.any(
            (x) => hard(x.constraint) && x.verdict.outcome == Outcome.worse,
          )
          ? MatchGroup.failed
          : results.isNotEmpty &&
                results.every((x) => x.verdict.satisfied && !x.unconfirmed)
          ? MatchGroup.full
          : MatchGroup.partial;
      final quote = quoteOptionsFor(
        id,
        currency: 'CNY',
        taxMode: 'included',
        asOf: asOf,
      ).where((o) => o.valid).firstOrNull;
      candidates.add(
        Candidate(
          id,
          data,
          results,
          group,
          price: quote?.price,
          priceUnit: data['unit'] as String?,
        ),
      );
    }

    int weightOf(Candidate c, Outcome o, {bool hardOnly = false}) => [
      for (final x in c.results)
        if (x.verdict.outcome == o && (!hardOnly || hard(x.constraint)))
          hard(x.constraint) ? 1000 : x.constraint.weight,
    ].fold(0, (a, b) => a + b);
    int rank(Candidate c) => c.group.index;
    candidates.sort((a, b) {
      for (final (x, y) in [
        (rank(a), rank(b)),
        (
          weightOf(a, Outcome.worse, hardOnly: true),
          weightOf(b, Outcome.worse, hardOnly: true),
        ),
        (weightOf(a, Outcome.worse), weightOf(b, Outcome.worse)),
        (weightOf(a, Outcome.unknown), weightOf(b, Outcome.unknown)),
        (b.count(Outcome.better), a.count(Outcome.better)),
        (a.price == null ? 1 : 0, b.price == null ? 1 : 0),
      ]) {
        if (x != y) return x.compareTo(y);
      }
      if (a.price != null && b.price != null) {
        final c = micros(a.price!).compareTo(micros(b.price!));
        if (c != 0) return c;
      }
      return '${a.data['name']}'.compareTo('${b.data['name']}');
    });

    // Dropping constraint i: materials whose only unsatisfied clause is i.
    final gain = <int, int>{};
    for (final c in candidates) {
      if (c.group == MatchGroup.full) continue;
      final open = [
        for (final (i, x) in c.results.indexed)
          if (!x.verdict.satisfied || x.unconfirmed) i,
      ];
      if (open.length == 1 && c.results.length > 1) {
        gain[open.single] = (gain[open.single] ?? 0) + 1;
      }
    }
    return MatchResult(candidates, gain, allHard: allHard);
  }

  /// Total memory from DIMM size × count when not given.
  Map<String, Object?>? _derived(
    String code,
    Map<String, Object?>? Function(String) value,
  ) {
    if (code != 'mem.total') return null;
    final size = value('mem.dimm_size'), count = value('mem.dimm_count');
    if (size == null || count == null) return null;
    return {
      'v': fromMicros(
        multiply(micros('${size['v']}'), micros('${count['v']}')),
      ),
      'u': size['u'],
    };
  }
}
