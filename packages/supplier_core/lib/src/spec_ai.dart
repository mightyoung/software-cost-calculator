import 'llm.dart';
import 'spec_compound.dart';
import 'spec_constraint.dart';
import 'spec_dictionary.dart';
import 'spec_extract.dart';
import 'spec_parse.dart';
import 'spec_request.dart';
import 'spec_units.dart';
import 'spec_values.dart';

// Optional AI reading (design §7.4): only clause text and the class's
// parameter list leave the device, never local data. Every constraint the
// model returns is checked against the clause before it is kept; the
// person still reviews what is kept.

const _system = '''
你是设备技术要求的解析器，把条款读成可比较的条件。
规则：
1. property 只能用参数清单里的代码；op 只能用该参数列出的比较方式。
2. value 按原文写法给出要求值，带单位，例如：-20~80℃、±0.3℃、±1%FS、8、2.3GHz、IP65、Ex d IIB T4 Gb、4-20mA、RS485、是。
3. evidence 必须是条款原文中连续的一段（逐字摘抄），能看出这个条件。
4. "不低于""优于"对越小越好的参数（精度、响应时间、分辨率）表示不高于（le）。
5. 没把握的条件不要输出；纯文字要求（如"与现有系统适配"）不输出条件。
只输出 JSON：{"clauses":[{"n":条款号,"constraints":[{"property":"","op":"","value":"","evidence":""}]}]}''';

String _typeWords(SpecProperty p) => switch (p.type) {
  ParamType.num =>
    '数值${p.order == Order.lower
        ? '（越小越好）'
        : p.order == Order.higher
        ? '（越大越好）'
        : ''}',
  ParamType.range => '范围',
  ParamType.tol => '精度（±）',
  ParamType.enumOne => '单选',
  ParamType.enumMany => '多选',
  ParamType.bool => '是否',
  ParamType.ip => 'IP 等级',
  ParamType.ex => '防爆标志',
  ParamType.catalog => '目录名称',
  ParamType.text => '文字',
};

/// The parameter list sent with the clauses.
String dictionaryCard(String classCode) => [
  for (final cp in classParams(classCode))
    if (specProperty(cp.property) case final p? when opsFor(p).isNotEmpty)
      [
        p.code,
        [p.label, ...p.aliases].join('/'),
        _typeWords(p),
        if (p.kind != null)
          '单位 ${quantityKinds[p.kind]!.units.map((u) => u.label).join('/')}',
        if (p.unitLabel != null) '单位 ${p.unitLabel}',
        'op ${opsFor(p).join('/')}',
        if (p.values.isNotEmpty) '可选 ${p.values.map((v) => v.label).join('/')}',
      ].join(' | '),
].join('\n');

class AiReading {
  AiReading(this.clauses, {required this.added, required this.dropped});
  final List<SpecClause> clauses;
  final int added, dropped;
}

/// Asks the model about the clauses the rules left open (text clauses and
/// flagged ones, not yet reviewed) and keeps what passes [verifyAiConstraint].
Future<AiReading> aiReadClauses(
  LlmClient llm,
  String classCode,
  List<SpecClause> clauses, {
  AiCancellation? cancellation,
}) async {
  final open = [
    for (final c in clauses)
      if (!c.reviewed && (c.isText || c.hint != null)) c,
  ];
  if (open.isEmpty) return AiReading(clauses, added: 0, dropped: 0);
  AiRun.validateInput(open.map((c) => c.text).join('\n'));
  llm = llm.forTask(AiTask.clauseReading, cancellation: cancellation);
  final rows = await llm.records(
    _system,
    '设备类别：${specClass(classCode)?.label ?? classCode}\n'
    '参数清单（代码 | 名称 | 类型 | 单位 | 比较方式 | 可选值）：\n${dictionaryCard(classCode)}\n\n'
    '条款：\n${[for (final c in open) '[${c.n}] ${c.text}'].join('\n')}',
    key: 'clauses',
    validate: (row) => row['n'] is int && row['constraints'] is List,
  );
  final byN = <int, List<Object?>>{};
  for (final x in rows) {
    if (x['n'] is int && x['constraints'] is List) {
      byN[x['n']! as int] = x['constraints']! as List;
    }
  }
  // A parameter the rules already read in another clause of the same item is
  // not asked again: a second, looser reading of it is a duplicate at best.
  final elsewhere = <int, Set<String>>{
    for (final c in clauses)
      c.n: {
        for (final o in clauses)
          if (o.n != c.n) ...o.constraints.map((k) => k.property),
      },
  };
  var added = 0, dropped = 0;
  final out = [
    for (final c in clauses)
      () {
        final raw = open.contains(c) ? byN[c.n] : null;
        if (raw == null) return c;
        final have = {
          for (final k in c.constraints) k.property,
          ...?elsewhere[c.n],
        };
        final kept = <SpecConstraint>[];
        var bad = 0;
        for (final r in raw) {
          final k = r is Map
              ? verifyAiConstraint(classCode, c, r.cast<String, Object?>())
              : null;
          if (k == null) {
            bad++;
          } else if (have.add(k.property)) {
            kept.add(k);
          }
        }
        added += kept.length;
        dropped += bad;
        if (kept.isEmpty && bad == 0) return c;
        return c.copyWith(
          constraints: [...c.constraints, ...kept],
          by: kept.isEmpty ? c.by : 'ai',
          hint: () => [
            if (kept.isNotEmpty) 'AI 补充了 ${kept.length} 个条件，请对照原文核对',
            if (bad > 0) 'AI 另有 $bad 个结果与原文对不上，已丢弃',
            ?c.hint,
          ].join('；'),
        );
      }(),
  ];
  return AiReading(out, added: added, dropped: dropped);
}

/// Parameters the model reads from a material's text the rules missed.
Future<List<ParamGuess>> aiExtractParams(
  LlmClient llm,
  String classCode,
  String text, {
  AiCancellation? cancellation,
}) async {
  AiRun.validateInput(text);
  llm = llm.forTask(AiTask.parameterExtraction, cancellation: cancellation);
  final clauses = [
    for (final (i, c) in splitClauses(text).indexed)
      SpecClause(i + 1, c, hint: '待读'),
  ];
  final r = await aiReadClauses(llm, classCode, clauses);
  return [
    for (final c in r.clauses)
      for (final k in c.constraints)
        ParamGuess(k.property, k.value, k.text ?? c.text, 'ai'),
  ];
}

String _flat(String s) =>
    specText(s).toLowerCase().replaceAll(RegExp(r'\s'), '');

Set<String> _numbers(String s) => {
  for (final m in RegExp(r'\d+(?:\.\d+)?').allMatches(specText(s)))
    ?signedDecimal(m[0]!),
  for (final m in RegExp('[零一二两三四五六七八九十百]+').allMatches(s))
    if (chineseNumber(m[0]!) case final n?) '$n',
};

/// A model's constraint, kept only when it can be traced to the clause:
/// known parameter and operator, evidence copied from the clause, every
/// number, unit and choice of the value present in the evidence.
SpecConstraint? verifyAiConstraint(
  String classCode,
  SpecClause clause,
  Map<String, Object?> raw,
) {
  final code = raw['property'], op = raw['op'];
  final value = raw['value'], evidence = raw['evidence'];
  if (code is! String ||
      op is! String ||
      value is! String ||
      evidence is! String) {
    return null;
  }
  if (!classParams(classCode).any((c) => c.property == code)) return null;
  final p = specProperty(code);
  if (p == null || !opsFor(p).contains(op)) return null;
  final ev = _flat(evidence);
  if (ev.isEmpty || !_flat(clause.text).contains(ev)) return null;
  // Evidence containing the right number is insufficient if the model reverses
  // the comparison. Deterministic readings take precedence over AI additions.
  final known = parseClause(classCode, clause.n, evidence).constraints;
  if (known.any((k) => k.property == code && k.op != op)) return null;
  final parsed = parseParamText(p, value);
  if (parsed == null) return null;
  final Map<String, Object?> v;
  try {
    v = normalizeParamValue(p, parsed);
  } on FormatException {
    return null;
  }
  if (!_numbers(evidence).containsAll(_numbers(value))) return null;
  if (p.kind != null && v['u'] != null) {
    final u = quantityKinds[p.kind]!.unit('${v['u']}')!;
    if (![u.code, u.label, ...u.aliases].any((s) => ev.contains(_flat(s))))
      return null;
  }
  if (p.unitLabel != null && !ev.contains(p.unitLabel!)) return null;
  final shown = switch (p.type) {
    ParamType.enumOne => [v['v']],
    ParamType.enumMany => v['vs']! as List,
    _ => const [],
  };
  final named = matchEnumValues(p, evidence);
  if (!shown.every(named.contains)) return null;
  if (p.type == ParamType.bool &&
      ![p.label, ...p.aliases].any((a) => ev.contains(_flat(a)))) {
    return null;
  }
  if (p.type == ParamType.catalog &&
      !ev.contains(
        _flat('${((v['entries']! as List).first as Map)['name']}'),
      )) {
    return null;
  }
  if (p.type == ParamType.ip || p.type == ParamType.ex) {
    if ('${parseParamText(p, evidence)}' != '$parsed') return null;
  }
  return SpecConstraint(code, op, v, mark: clause.mark, text: evidence.trim());
}
