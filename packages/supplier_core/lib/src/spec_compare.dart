import 'pricing.dart';
import 'spec_compound.dart';
import 'spec_dictionary.dart';
import 'spec_units.dart';

/// How a material's value relates to a requirement (the three kinds of
/// deviation in a 技术偏离表, plus "cannot tell").
enum Outcome {
  exact, // 无偏离
  better, // 正偏离
  worse, // 负偏离
  unknown, // 待确认
}

/// An outcome and why, in Chinese, for the explanation cell.
class Verdict {
  const Verdict(this.outcome, [this.note]);
  final Outcome outcome;
  final String? note;
  bool get satisfied => outcome == Outcome.exact || outcome == Outcome.better;

  @override
  String toString() => '${outcome.name}${note == null ? '' : ': $note'}';
}

const _unknownUnit = Verdict(Outcome.unknown, '单位无法换算');

/// Base-unit millionths of a num value; null when the unit is unknown.
BigInt? _base(SpecProperty p, Object? value, Object? unit) {
  if (value is! String) return null;
  if (p.kind == null) return micros(value);
  return toBase(quantityKinds[p.kind]!, value, '${unit ?? p.unit}');
}

bool _sameGroup(SpecProperty p, Object? a, Object? b) =>
    p.kind == null ||
    convertible(quantityKinds[p.kind]!, '${a ?? p.unit}', '${b ?? p.unit}');

// One millionth of slack absorbs rounding in ℉ and similar conversions.
int _cmp(BigInt a, BigInt b) =>
    (a - b).abs() <= BigInt.one ? 0 : a.compareTo(b);

Verdict _directed(SpecProperty p, int cmp) {
  if (cmp == 0) return const Verdict(Outcome.exact);
  final better = p.order == Order.lower ? cmp < 0 : cmp > 0;
  return Verdict(better ? Outcome.better : Outcome.worse);
}

/// "Not worse than" for num (by the property's direction), e.g. cores ≥ 8
/// or response time ≤ 30 s.
Verdict atLeastAsGood(
  SpecProperty p,
  Map<String, Object?> have,
  Map<String, Object?> want,
) {
  if (!_sameGroup(p, have['u'], want['u'])) return _unknownUnit;
  final a = _base(p, have['v'], have['u']), b = _base(p, want['v'], want['u']);
  if (a == null || b == null) return _unknownUnit;
  return _directed(p, _cmp(a, b));
}

/// Accuracy "优于 ±x": smaller tolerance is better. Tolerances written on
/// different bases (absolute, %FS, %RD) compare only after conversion; a
/// %FS tolerance converts to absolute with the material's [span].
Verdict toleranceWithin(
  SpecProperty p,
  Map<String, Object?> have,
  Map<String, Object?> want, {
  Map<String, Object?>? span,
}) {
  final hb = have['basis'] ?? 'abs', wb = want['basis'] ?? 'abs';
  if (hb == wb) {
    if (hb != 'abs') {
      return _directed(
        SpecProperty(p.code, p.label, p.type, order: Order.lower),
        _cmp(micros('${have['v']}'), micros('${want['v']}')),
      );
    }
    final v = atLeastAsGood(
      SpecProperty(
        p.code,
        p.label,
        ParamType.num,
        kind: p.kind,
        unit: p.unit,
        order: Order.lower,
      ),
      have,
      want,
    );
    return v;
  }
  if (hb == 'FS' && wb == 'abs' && span != null) {
    final range = _rangeBase(p, span);
    if (range == null || range.$1 == null || range.$2 == null) {
      return const Verdict(Outcome.unknown, '缺少量程，无法换算 %FS');
    }
    final abs = roundedDivide(
      (range.$2! - range.$1!) * micros('${have['v']}'),
      BigInt.from(100) * BigInt.from(1000000),
    );
    final want0 = _base(p, want['v'], want['u']);
    if (want0 == null) return _unknownUnit;
    return Verdict(
      _directed(
        SpecProperty(p.code, p.label, p.type, order: Order.lower),
        _cmp(abs, want0),
      ).outcome,
      '按量程换算为 ±${fromMicros(abs)}',
    );
  }
  return const Verdict(Outcome.unknown, '精度写法不同（绝对值、%FS、%RD），无法直接比较');
}

(BigInt?, BigInt?)? _rangeBase(SpecProperty p, Map<String, Object?> r) {
  final u = r['u'];
  BigInt? end(Object? x) => x == null ? null : _base(p, x, u);
  if (r['min'] != null && end(r['min']) == null) return null;
  if (r['max'] != null && end(r['max']) == null) return null;
  return (end(r['min']), end(r['max']));
}

/// The material's range contains the required one (measuring range,
/// operating temperature). Wider is a positive deviation.
Verdict covers(
  SpecProperty p,
  Map<String, Object?> have,
  Map<String, Object?> want,
) {
  if (!_sameGroup(p, have['u'], want['u'])) return _unknownUnit;
  final h = _rangeBase(p, have), w = _rangeBase(p, want);
  if (h == null || w == null) return _unknownUnit;
  var wider = false;
  if (w.$1 != null) {
    if (h.$1 == null) return const Verdict(Outcome.unknown, '缺少下限');
    final c = _cmp(h.$1!, w.$1!);
    if (c > 0) return const Verdict(Outcome.worse, '下限不够');
    wider |= c < 0;
  }
  if (w.$2 != null) {
    if (h.$2 == null) return const Verdict(Outcome.unknown, '缺少上限');
    final c = _cmp(h.$2!, w.$2!);
    if (c < 0) return const Verdict(Outcome.worse, '上限不够');
    wider |= c > 0;
  }
  return Verdict(wider ? Outcome.better : Outcome.exact);
}

/// A single value falls inside the required range.
Verdict within(
  SpecProperty p,
  Map<String, Object?> have,
  Map<String, Object?> want,
) {
  if (!_sameGroup(p, have['u'], want['u'])) return _unknownUnit;
  final v = _base(p, have['v'], have['u']);
  final w = _rangeBase(p, want);
  if (v == null || w == null) return _unknownUnit;
  if ((w.$1 != null && _cmp(v, w.$1!) < 0) ||
      (w.$2 != null && _cmp(v, w.$2!) > 0)) {
    return const Verdict(Outcome.worse, '不在要求范围内');
  }
  return const Verdict(Outcome.exact);
}

/// Ordered choice (DDR4, FHD, ZB): lower rank is worse; a higher rank is
/// not automatically compatible, so it is "unknown" with a note.
Verdict rankAtLeast(SpecProperty p, String have, String want) {
  final a = p.value(have)?.rank, b = p.value(want)?.rank;
  if (have == want) return const Verdict(Outcome.exact);
  if (a == null || b == null) return const Verdict(Outcome.unknown, '无法比较等级');
  if (a < b) return const Verdict(Outcome.worse);
  if (a == b) return const Verdict(Outcome.exact);
  return const Verdict(Outcome.unknown, '代际或规格不同，需确认兼容');
}

/// The material offers at least one of [want] (e.g. 4-20mA 或 RS485).
Verdict offersAny(List<String> have, List<String> want) =>
    have.any(want.contains)
    ? Verdict(
        have.toSet().containsAll(want) && want.length > 1
            ? Outcome.better
            : Outcome.exact,
      )
    : Verdict(Outcome.worse, '不具备：${want.join('、')}');

/// The material offers all of [want] (protocols, ports).
Verdict offersAll(List<String> have, List<String> want) {
  final missing = [
    for (final w in want)
      if (!have.contains(w)) w,
  ];
  if (missing.isNotEmpty)
    return Verdict(Outcome.worse, '缺少：${missing.join('、')}');
  return Verdict(
    have.toSet().length > want.toSet().length ? Outcome.better : Outcome.exact,
  );
}

/// "不低于 IPab" per IEC 60529: water numerals 0-6 are cumulative, 7 and 8
/// are immersion only and do not prove jet protection unless dual-coded.
Verdict ipAtLeast(List<String> haveCodes, String wantCode) {
  final want = parseIpCode(wantCode);
  if (want == null) return const Verdict(Outcome.unknown, '要求的 IP 代码无法识别');
  final have = [for (final c in haveCodes) ?parseIpCode(c)];
  if (have.isEmpty) return const Verdict(Outcome.unknown, '缺少 IP 等级');

  var better = false;
  if (want.solid != null) {
    final best = have.map((c) => c.solid ?? -1).reduce((a, b) => a > b ? a : b);
    if (best < want.solid!) return const Verdict(Outcome.worse, '防尘等级不够');
    better |= best > want.solid!;
  }
  if (want.liquid != null) {
    final w = want.liquidDigit!;
    final digits = [for (final c in have) ?c.liquidDigit];
    final bool ok;
    if (want.liquid == '9K' || w == 9) {
      ok = have.any((c) => c.liquid == '9K' || c.liquidDigit == 9);
    } else if (w <= 6) {
      ok = digits.any((d) => d >= w && d <= 6);
      better |= digits.any((d) => d > w);
      if (!ok && digits.any((d) => d >= 7 && d <= 8)) {
        return Verdict(
          Outcome.worse,
          '${haveCodes.join('/')} 只证明浸水防护，不代表满足 IPX$w 喷水，'
          '需双标记（如 IP${want.solid ?? 6}$w/IP67）或喷水试验报告',
        );
      }
    } else {
      ok = digits.any((d) => (d == 7 || d == 8) && d >= w);
      better |= digits.contains(8) && w == 7;
    }
    if (!ok) return const Verdict(Outcome.worse, '防水等级不够');
  }
  return Verdict(better ? Outcome.better : Outcome.exact);
}

/// "不低于 Ex d IIB T4 Gb" per IEC 60079-0: a higher gas group, cooler
/// temperature class and higher EPL may replace lower ones; the type of
/// protection has no order and must match (d = db).
Verdict exAtLeast(List<ExMark> have, ExMark want) {
  if (have.isEmpty) return const Verdict(Outcome.unknown, '缺少防爆标志');
  Verdict? best;
  for (final m in have) {
    final v = _exOne(m, want);
    if (best == null || _preference(v.outcome) < _preference(best.outcome)) {
      best = v;
    }
  }
  return best!;
}

int _preference(Outcome o) => switch (o) {
  Outcome.exact || Outcome.better => 0,
  Outcome.unknown => 1,
  Outcome.worse => 2,
};

Verdict _exOne(ExMark have, ExMark want) {
  var better = false;
  final notes = <String>[];
  if (want.group != null) {
    final w = exGroupRank(want.group!),
        h = have.group == null ? null : exGroupRank(have.group!);
    if (w == null) return const Verdict(Outcome.unknown, '要求的组别无法识别');
    if (h == null) return const Verdict(Outcome.unknown, '缺少组别');
    if (h.$1 != w.$1) return Verdict(Outcome.worse, '组别不同（${have.group}）');
    if (h.$2 < w.$2)
      return Verdict(Outcome.worse, '组别 ${have.group} 低于 ${want.group}');
    if (h.$2 > w.$2) {
      better = true;
      notes.add('组别 ${have.group}');
    }
  }
  if (want.temp != null) {
    final w = exMaxTemp(want.temp!),
        h = have.temp == null ? null : exMaxTemp(have.temp!);
    if (w == null) return const Verdict(Outcome.unknown, '要求的温度组别无法识别');
    if (h == null) return const Verdict(Outcome.unknown, '缺少温度组别');
    if (h > w)
      return Verdict(Outcome.worse, '温度组别 ${have.temp} 不满足 ${want.temp}');
    if (h < w) {
      better = true;
      notes.add('温度组别 ${have.temp}');
    }
  }
  if (want.epl != null) {
    final w = exEplRank(want.epl!);
    final hEpl = have.epl ?? exImpliedEpl(have.types);
    final h = hEpl == null ? null : exEplRank(hEpl);
    if (w == null) return const Verdict(Outcome.unknown, '要求的保护级别无法识别');
    if (h == null) return const Verdict(Outcome.unknown, '缺少设备保护级别');
    if (h.$1 != w.$1)
      return Verdict(Outcome.worse, '保护级别 $hEpl 不适用于 ${want.epl}');
    if (h.$2 < w.$2) return Verdict(Outcome.worse, '保护级别 $hEpl 低于 ${want.epl}');
    if (h.$2 > w.$2) {
      better = true;
      notes.add('保护级别 $hEpl');
    }
  }
  if (want.types.isNotEmpty) {
    final hf = {for (final t in have.types) exFamily(t)};
    final wf = {for (final t in want.types) exFamily(t)};
    if (hf.isEmpty) return const Verdict(Outcome.unknown, '缺少防爆型式');
    if (!hf.containsAll(wf)) {
      return Verdict(
        Outcome.unknown,
        '防爆型式不同（${have.types.join(' ')} 与 ${want.types.join(' ')}），是否接受由人决定',
      );
    }
  }
  return Verdict(
    better ? Outcome.better : Outcome.exact,
    notes.isEmpty ? null : '${notes.join('、')}更高',
  );
}

/// Listed in the named catalog, optionally at [level] or above and still
/// valid on [on] (YYYY-MM-DD). Different catalogs never stand in for each
/// other.
Verdict listedIn(
  List<Map<String, Object?>> entries,
  String name, {
  String? level,
  required String on,
}) {
  String key(String s) => s.replaceAll(RegExp(r'[《》（）()\s]|最新版'), '');
  final same = [
    for (final e in entries)
      if (key('${e['name']}').contains(key(name)) ||
          key(name).contains(key('${e['name']}')))
        e,
  ];
  if (same.isEmpty) {
    return Verdict(
      Outcome.unknown,
      entries.isEmpty
          ? '缺少目录信息'
          : '收录的是其他目录（${entries.map((e) => e['name']).join('、')}）',
    );
  }
  final current = [
    for (final e in same)
      if (e['valid_until'] == null || '${e['valid_until']}'.compareTo(on) >= 0)
        e,
  ];
  if (current.isEmpty) return const Verdict(Outcome.worse, '收录已过有效期');
  if (level == null) return const Verdict(Outcome.exact);
  const roman = {
    'Ⅰ': 1,
    'Ⅱ': 2,
    'Ⅲ': 3,
    'I': 1,
    'II': 2,
    'III': 3,
    '1': 1,
    '2': 2,
    '3': 3,
  };
  final w = roman[level.replaceAll('级', '')];
  final hs = [
    for (final e in current) ?roman['${e['level']}'.replaceAll('级', '')],
  ];
  if (w == null || hs.isEmpty) return const Verdict(Outcome.unknown, '等级无法比较');
  final h = hs.reduce((a, b) => a > b ? a : b);
  return Verdict(
    h < w ? Outcome.worse : (h > w ? Outcome.better : Outcome.exact),
  );
}
