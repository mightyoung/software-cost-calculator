import 'spec_compare.dart';
import 'spec_compound.dart';
import 'spec_dictionary.dart';
import 'spec_values.dart';

/// ★ knock-out, ▲ important, or an ordinary clause (政府采购 marks).
enum ClauseMark { star, triangle, none }

const markLabels = {
  ClauseMark.star: '★ 实质性',
  ClauseMark.triangle: '▲ 重要',
  ClauseMark.none: '一般',
};

/// Default weight of a soft clause by its mark.
int markWeight(ClauseMark m) => m == ClauseMark.triangle ? 3 : 1;

/// Comparison operators; the value is shaped like a parameter value of the
/// property (§4.5 of the design).
const opLabels = {
  'ge': '不低于',
  'le': '不高于',
  'gt': '高于',
  'lt': '低于',
  'eq': '等于',
  'covers': '覆盖',
  'within': '在范围内',
  'any': '具备其一',
  'all': '全部具备',
  'is': '为',
  'ip_ge': '不低于',
  'ex_ge': '不低于',
  'listed': '收录于',
};

/// Operators that make sense for [p], the usual one first.
List<String> opsFor(SpecProperty p) => switch (p.type) {
  ParamType.num =>
    p.order == Order.lower
        ? ['le', 'ge', 'eq', 'lt', 'gt', 'within']
        : ['ge', 'le', 'eq', 'gt', 'lt', 'within'],
  ParamType.tol => ['le'],
  ParamType.range => ['covers', 'within'],
  ParamType.enumOne => p.ordered ? ['ge', 'eq'] : ['eq'],
  ParamType.enumMany => ['any', 'all'],
  ParamType.bool => ['is'],
  ParamType.ip => ['ip_ge'],
  ParamType.ex => ['ex_ge'],
  ParamType.catalog => ['listed'],
  ParamType.text => const [],
};

/// One requirement on one parameter: "物理核数 不低于 8".
class SpecConstraint {
  const SpecConstraint(
    this.property,
    this.op,
    this.value, {
    this.mark = ClauseMark.none,
    int? weight,
    this.text,
  }) : weight = weight ?? (mark == ClauseMark.triangle ? 3 : 1);
  final String property, op;
  final Map<String, Object?> value;
  final ClauseMark mark;
  final int weight;

  /// The clause as written, when it came from a document.
  final String? text;

  Map<String, Object?> toJson() => {
    'p': property,
    'op': op,
    'value': value,
    'mark': mark.name,
    'weight': weight,
    'text': text,
  };

  static SpecConstraint fromJson(Map<String, Object?> m) => SpecConstraint(
    m['p']! as String,
    m['op']! as String,
    (m['value']! as Map).cast<String, Object?>(),
    mark: ClauseMark.values.byName('${m['mark'] ?? 'none'}'),
    weight: m['weight'] as int?,
    text: m['text'] as String?,
  );

  /// "物理核数 不低于 8 核".
  String describe() {
    final p = specProperty(property);
    if (p == null) return '$property $op';
    return '${p.label} ${opLabels[op] ?? op} ${formatParamValue(p, value)}';
  }
}

/// Judges one material value against one constraint. A missing value, an
/// unknown property or a unit that does not convert is "unknown".
Verdict evaluateConstraint(
  SpecProperty p,
  Map<String, Object?>? have,
  SpecConstraint c, {
  Map<String, Object?>? span,
  required String today,
}) {
  if (have == null) return const Verdict(Outcome.unknown, '缺少参数');
  final want = c.value;
  SpecProperty directed(Order o) => SpecProperty(
    p.code,
    p.label,
    ParamType.num,
    kind: p.kind,
    unit: p.unit,
    order: o,
  );
  Verdict strict(Verdict v) => v.outcome == Outcome.exact
      ? const Verdict(Outcome.worse, '需严格高于或低于要求值')
      : v;

  switch ((p.type, c.op)) {
    case (ParamType.num, 'ge'):
      return atLeastAsGood(directed(Order.higher), have, want);
    case (ParamType.num, 'le'):
      return atLeastAsGood(directed(Order.lower), have, want);
    case (ParamType.num, 'gt'):
      return strict(atLeastAsGood(directed(Order.higher), have, want));
    case (ParamType.num, 'lt'):
      return strict(atLeastAsGood(directed(Order.lower), have, want));
    case (ParamType.num, 'eq'):
      final v = atLeastAsGood(directed(Order.higher), have, want);
      return v.outcome == Outcome.better ? const Verdict(Outcome.worse) : v;
    case (ParamType.num, 'within'):
      return within(p, have, want);
    case (ParamType.tol, 'le'):
      return toleranceWithin(p, have, want, span: span);
    case (ParamType.range, 'covers'):
      return covers(p, have, want);
    case (ParamType.range, 'within'):
      // The material's whole range lies inside the required one.
      final lo = within(p, {'v': have['min'], 'u': have['u']}, want);
      final hi = within(p, {'v': have['max'], 'u': have['u']}, want);
      if (have['min'] == null || have['max'] == null) {
        return const Verdict(Outcome.unknown, '范围不完整');
      }
      return lo.satisfied && hi.satisfied
          ? const Verdict(Outcome.exact)
          : lo.satisfied
          ? hi
          : lo;
    case (ParamType.enumOne, 'ge'):
      return rankAtLeast(p, '${have['v']}', '${want['v']}');
    case (ParamType.enumOne, 'eq'):
      return have['v'] == want['v']
          ? const Verdict(Outcome.exact)
          : Verdict(Outcome.worse, '为 ${formatParamValue(p, have)}');
    case (ParamType.enumMany, 'any'):
      return offersAny(_strings(have['vs']), _strings(want['vs']));
    case (ParamType.enumMany, 'all'):
      return offersAll(_strings(have['vs']), _strings(want['vs']));
    case (ParamType.bool, 'is'):
      return have['v'] == want['v']
          ? const Verdict(Outcome.exact)
          : const Verdict(Outcome.worse);
    case (ParamType.ip, 'ip_ge'):
      return ipAtLeast(_strings(have['codes']), _strings(want['codes']).first);
    case (ParamType.ex, 'ex_ge'):
      return exAtLeast(
        [
          for (final m in (have['marks'] as List? ?? const []))
            ExMark.fromJson((m as Map).cast<String, Object?>()),
        ],
        ExMark.fromJson(
          ((want['marks']! as List).first as Map).cast<String, Object?>(),
        ),
      );
    case (ParamType.catalog, 'listed'):
      final w = ((want['entries']! as List).first as Map)
          .cast<String, Object?>();
      return listedIn(
        [
          for (final e in (have['entries'] as List? ?? const []))
            (e as Map).cast<String, Object?>(),
        ],
        '${w['name']}',
        level: w['level'] as String?,
        on: today,
      );
    default:
      return Verdict(
        Outcome.unknown,
        '${opLabels[c.op] ?? c.op} 不适用于${p.label}',
      );
  }
}

List<String> _strings(Object? v) => [
  for (final x in (v as List? ?? const [])) '$x',
];
