import 'dart:convert';

import 'product_params.dart';
import 'spec_decode.dart';
import 'spec_dictionary.dart';
import 'spec_migration.dart';
import 'spec_parse.dart';
import 'spec_values.dart';
import 'store.dart';

/// One parameter read from a material's own words (design §9.3).
class ParamGuess {
  ParamGuess(this.property, this.value, this.evidence, this.source);
  final String property;
  final Map<String, Object?> value;
  final String evidence;

  /// 'rule' (text), 'decoder' (model code) or 'ai'.
  final String source;
}

/// What filling one material would do; writes nothing.
class ParamFill {
  ParamFill(
    this.productId,
    this.name,
    this.classCode,
    this.guesses, {
    required this.newClass,
  });
  final String productId, name, classCode;

  /// The class was guessed from the name and will be set too.
  final bool newClass;
  final List<ParamGuess> guesses;
}

/// Parameters of [classCode] written in [text], read with the requirement
/// parser: a material's "测量范围 -40~85℃" reads like a requirement's.
/// The first reading of each parameter wins.
List<ParamGuess> extractParams(String classCode, String text) {
  final out = <String, ParamGuess>{};
  for (final (i, clause) in splitClauses(text).indexed) {
    for (final c in parseClause(classCode, i + 1, clause).constraints) {
      out.putIfAbsent(
        c.property,
        () => ParamGuess(c.property, c.value, c.text ?? clause, 'rule'),
      );
    }
  }
  return out.values.toList();
}

/// Decoded model parameters for classes with a code system (cables).
List<ParamGuess> decodeModel(String classCode, String? model) {
  if (model == null || classCode != 'cable') return const [];
  return [
    for (final MapEntry(:key, :value) in decodeCableModel(model).entries)
      if (specProperty(key) case final p?)
        ParamGuess(key, normalizeParamValue(p, value), model, 'decoder'),
  ];
}

extension ParamExtraction on Store {
  /// Materials whose model, specification or notes give parameters they do
  /// not have yet. Materials without a class get one guessed from the name.
  List<ParamFill> planParamFill({Iterable<String>? productIds}) {
    final out = <ParamFill>[];
    final rows = db.select(
      "SELECT id, data FROM product WHERE deleted = 0 "
      "AND json_extract(data,'\$.merged_into') IS NULL ORDER BY id",
    );
    final only = productIds?.toSet();
    for (final r in rows) {
      final id = r['id'] as String;
      if (only != null && !only.contains(id)) continue;
      final d = jsonDecode(r['data'] as String) as Map<String, Object?>;
      final given = d['spec_class'] as String?;
      final cls =
          given ??
          guessSpecClass([d['name'] as String?, d['category'] as String?]);
      if (cls == null || specClass(cls) == null) continue;
      final have = paramsOf(id).keys.toSet();
      final found = <String, ParamGuess>{};
      for (final g in [
        ...decodeModel(cls, d['model'] as String?),
        ...extractParams(
          cls,
          [d['specification'], d['notes']].whereType<String>().join('\n'),
        ),
      ]) {
        if (!have.contains(g.property)) found.putIfAbsent(g.property, () => g);
      }
      if (found.isEmpty && given != null) continue;
      out.add(
        ParamFill(
          id,
          '${d['name']}',
          cls,
          found.values.toList(),
          newClass: given == null,
        ),
      );
    }
    return out;
  }

  /// Writes the plans: unconfirmed values with their evidence, and guessed
  /// classes. Returns how many values were written.
  int applyParamFill(List<ParamFill> plans) => transaction(() {
    var n = 0;
    for (final plan in plans) {
      if (plan.newClass) {
        final p = get('product', plan.productId)!;
        save('product', {...p.data, 'spec_class': plan.classCode}, id: p.id);
      }
      for (final g in plan.guesses) {
        setParam(
          plan.productId,
          g.property,
          g.value,
          source: g.source,
          confirmed: false,
          evidence: g.evidence.length > 500
              ? g.evidence.substring(0, 500)
              : g.evidence,
        );
        n++;
      }
    }
    return n;
  });
}
