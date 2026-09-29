import 'dart:math';

import 'sheet_offers.dart';
import 'spec_compound.dart';
import 'spec_constraint.dart';
import 'spec_dictionary.dart';
import 'spec_migration.dart';
import 'spec_request.dart';
import 'spec_units.dart';
import 'spec_values.dart';
import 'xlsx.dart';

// Rule-based reading of technical requirements (design §7.3). Values are
// found first (IP codes, Ex markings, choices, numbers with units), then
// matched to a parameter of the item's class by type, unit and the words
// around them. Anything uncertain leaves a hint instead of a guess: a clause
// is either parsed, flagged for checking, or kept as text.

/// One requirement row before it is saved: "温湿度传感器 ×25 个" and its
/// clauses.
class SpecItemDraft {
  SpecItemDraft(
    this.name,
    this.text, {
    this.qty,
    this.unit,
    this.specClass,
    this.clauses = const [],
    this.projectItemId,
  });
  final String name, text;
  final String? qty, unit, specClass;

  /// The budget line the item came from, if any.
  final String? projectItemId;
  final List<SpecClause> clauses;
}

/// Reads [name] and [text] into a draft: class from the name (then the
/// text), clauses split and parsed.
SpecItemDraft draftItem(
  String name,
  String text, {
  String? qty,
  String? unit,
  String? specClass,
  String? projectItemId,
}) {
  final cls = specClass ?? guessSpecClass([name]) ?? guessSpecClass([text]);
  return SpecItemDraft(
    name,
    text,
    qty: qty,
    unit: unit,
    specClass: cls,
    projectItemId: projectItemId,
    clauses: [
      for (final (i, c) in splitClauses(text).indexed)
        parseClause(cls, i + 1, c),
    ],
  );
}

/// Requirement rows of a workbook (name + requirement columns), or null.
List<SpecItemDraft>? specItemsFromWorkbook(XWorkbook book) => [
  for (final r in requirementRows(book) ?? const <Map<String, String?>>[])
    draftItem(
      r['name']!,
      r['specification'] ?? '',
      qty: r['qty'],
      unit: r['unit'],
    ),
].nullIfEmpty;

/// Pasted text: a table copied from Excel, or paragraphs separated by blank
/// lines whose short first line names the equipment.
List<SpecItemDraft> specItemsFromText(String text) {
  if (tableFromText(text) case final book?) {
    if (specItemsFromWorkbook(book) case final items?) return items;
  }
  return [
    for (final para in text.split(RegExp(r'\n\s*\n')))
      if (para.trim().isNotEmpty) _paragraph(para.trim()),
  ];
}

SpecItemDraft _paragraph(String para) {
  final lines = para.split(RegExp(r'\r?\n'));
  final first = lines.first.trim().replaceFirst(RegExp(r'[:：]$'), '');
  final named =
      lines.length > 1 &&
      first.length <= 30 &&
      !_numbering.hasMatch(first) &&
      !RegExp(r'\d').hasMatch(first);
  return named
      ? draftItem(first, lines.skip(1).join('\n'))
      : draftItem('', para);
}

extension on List<SpecItemDraft> {
  List<SpecItemDraft>? get nullIfEmpty => isEmpty ? null : this;
}

// ------------------------------------------------------------ splitting --

final _numbering = RegExp(
  r'^\s*(?:[(（]\s*\d{1,2}\s*[)）]|\d{1,2}\s*[)）、．](?!\d)|\d{1,2}\.(?!\d)'
  r'|[①-⑳]|[一二三四五六七八九十]{1,3}\s*[、．.])\s*',
);
final _inlineNumber = RegExp(
  r'(?=[(（]\d{1,2}[)）])|(?<![\dA-Za-z.(（])(?=\d{1,2}[)）])|(?=[①-⑳])',
);
const _markChars = {
  '★': ClauseMark.star,
  '☆': ClauseMark.star,
  '※': ClauseMark.star,
  '▲': ClauseMark.triangle,
  '△': ClauseMark.triangle,
  '#': ClauseMark.triangle,
  '＃': ClauseMark.triangle,
};

bool _heading(String l) =>
    RegExp(r'[:：]$').hasMatch(l) &&
    !RegExp(r'\d').hasMatch(l) &&
    l.length <= 30;

/// Clauses of a requirement text: one per numbered item; unnumbered lines
/// split at "；" and "。". Headings such as "主要技术指标：" are dropped.
List<String> splitClauses(String text) {
  final out = <String>[];
  for (final raw in text.split(RegExp(r'\r?\n'))) {
    final line = raw.trim();
    if (line.isEmpty || _heading(line)) continue;
    final bare = line.replaceFirst(RegExp(r'^[★☆※▲△#＃]\s*'), '');
    final parts = _numbering.hasMatch(bare)
        ? line.split(_inlineNumber)
        : line.split(RegExp(r'[；;]|。(?=\S)'));
    for (final p in parts) {
      final c = p.trim().replaceFirst(RegExp(r'[；;。，,、\s]+$'), '');
      if (c.isNotEmpty && !_heading(c)) out.add(c);
    }
  }
  return out;
}

(ClauseMark, String) _head(String raw) {
  var t = raw.trim();
  var mark = ClauseMark.none;
  while (t.isNotEmpty) {
    if (_markChars[t[0]] case final m?) {
      mark = m;
      t = t.substring(1).trimLeft();
    } else if (_numbering.firstMatch(t) case final m? when m.end > 0) {
      t = t.substring(m.end);
    } else {
      break;
    }
  }
  if (mark == ClauseMark.none) {
    if (RegExp(r'[(（]\s*实质性').hasMatch(t)) mark = ClauseMark.star;
    if (RegExp(r'[(（]\s*重要').hasMatch(t)) mark = ClauseMark.triangle;
  }
  return (mark, t);
}

// -------------------------------------------------------------- parsing --

/// Comparison words, longer spellings first (附录 A). "better" means "no
/// worse than": ≥ or ≤ by the parameter's direction.
const _before = [
  ('大于或等于', 'ge'), ('大于等于', 'ge'), ('不小于', 'ge'), ('不少于', 'ge'), //
  ('至少', 'ge'), ('≥', 'ge'), ('>=', 'ge'),
  ('小于或等于', 'le'), ('小于等于', 'le'), ('不大于', 'le'), ('不超过', 'le'),
  ('不高于', 'le'), ('不多于', 'le'), ('最多', 'le'), ('≤', 'le'), ('<=', 'le'),
  ('不低于', 'better'), ('不劣于', 'better'), ('不差于', 'better'),
  ('优于', 'better'), ('好于', 'better'), ('达到', 'better'),
  ('大于', 'gt'), ('高于', 'gt'), ('超过', 'gt'), ('>', 'gt'),
  ('小于', 'lt'), ('低于', 'lt'), ('<', 'lt'),
];
const _after = [
  ('及以上', 'ge'),
  ('以上', 'ge'),
  ('起', 'ge'),
  ('及以下', 'le'),
  ('以下', 'le'),
  ('以内', 'le'),
];
const _cmpLabels = {'ge': '不小于', 'le': '不大于', 'gt': '大于', 'lt': '小于'};

/// Model codes, class names and words that are not requirement values.
const _plainWords = {
  'cpu', 'gpu', 'plc', 'io', 'ai', 'ao', 'di', 'do', 'pc', 'ipc', 'os', //
  'led', 'usb', 'lan', 'wifi',
};
const _envCue = '工作|环境|使用|运行|储存|存储';

class _Hit {
  _Hit(this.start, this.end, this.kind, this.options, [this.value]);
  final int start, end;

  /// 'mention' (a parameter's name), 'choice' (an enum value) or 'fixed'
  /// (IP, Ex, catalog: the value is complete).
  final String kind;

  /// Parameters (and the value code for a choice) this spelling can mean.
  final List<(SpecProperty, String?)> options;
  final Map<String, Object?>? value;
  int get length => end - start;
  bool overlaps(_Hit o) => start < o.end && o.start < end;
}

class _Number {
  _Number(
    this.start,
    this.end,
    this.shape,
    this.v,
    this.units, {
    this.max,
    this.basis,
  });
  final int start, end;
  final String shape; // num, range, tol
  final String v;
  final String? max, basis;

  /// (quantity kind, unit code) readings; (null, "核") for counted words,
  /// (null, null) when no unit is written.
  final List<(String?, String?)> units;
}

/// Parses one clause of an item of [classCode]. Never guesses: when a value
/// has no single fitting parameter, or text is left over that looks like a
/// requirement, the clause carries a [SpecClause.hint].
SpecClause parseClause(String? classCode, int n, String raw) {
  final (mark, body) = _head(raw);
  final cls = classCode == null ? null : specClass(classCode);
  if (cls == null) return SpecClause(n, raw, mark: mark);
  return _ClauseReader(classCode!, body, mark).read(n, raw);
}

class _ClauseReader {
  _ClauseReader(String classCode, String body, this.mark)
    : t = specText(body),
      lower = specText(body).toLowerCase() {
    all = [
      for (final cp in classParams(classCode))
        if (specProperty(cp.property) case final p?
            when p.type != ParamType.text)
          p,
    ];
    final env = RegExp(_envCue).hasMatch(t);
    props = [
      for (final p in all)
        if (env || !p.code.startsWith('env.')) p,
    ];
  }
  final String t, lower;
  final ClauseMark mark;
  late final List<SpecProperty> all, props;
  final hints = <String>[];
  final made = <String, SpecConstraint>{};
  final used = <(int, int)>[];

  SpecClause read(int n, String raw) {
    final hits = _resolve([..._fixed(), ..._choices(), ..._mentions()]);
    final masked = _mask(hits);
    final numbers = _numbers(masked);
    _assignChoices(hits, masked);
    for (final (i, x) in numbers.indexed) {
      _assignNumber(x, masked, i == 0 ? null : numbers[i - 1].end);
    }
    _bools(hits);
    _unparsedMentions(hits);
    _leftovers(masked, numbers);
    if (t.contains('优先')) hints.add('含「优先」，可能不是硬性要求');
    return SpecClause(
      n,
      raw,
      mark: mark,
      constraints: made.values.toList(),
      hint: hints.isEmpty ? null : hints.join('；'),
    );
  }

  // ---------------------------------------------------- named things --

  Iterable<_Hit> _fixed() sync* {
    for (final p in props) {
      switch (p.type) {
        case ParamType.ip:
          for (final m in RegExp(
            r'(?<![A-Za-z])IP\s*[0-9X]{2}K?(?:\s*/\s*(?:IP)?\s*[0-9X]{2}K?)*',
            caseSensitive: false,
          ).allMatches(t)) {
            final codes = parseIpCodes(m[0]!);
            if (codes.isEmpty) continue;
            yield _Hit(
              m.start,
              m.end,
              'fixed',
              [(p, null)],
              {
                'codes': [codes.first],
              },
            );
          }
        case ParamType.ex:
          for (final m in RegExp(
            r'(?<![A-Za-z])ex(?=[\s\[a-z])',
            caseSensitive: false,
          ).allMatches(t)) {
            final stop = t.indexOf(RegExp(r'[,;。，；]'), m.start);
            final end = stop < 0 ? t.length : stop;
            final marks = parseExMarks(t.substring(m.start, end));
            if (marks.isEmpty) continue;
            yield _Hit(
              m.start,
              end,
              'fixed',
              [(p, null)],
              {
                'marks': [marks.first.toJson()],
              },
            );
          }
        case ParamType.catalog:
          for (final m in RegExp('《([^》]+)》').allMatches(t)) {
            yield _Hit(
              m.start,
              m.end,
              'fixed',
              [(p, null)],
              {
                'entries': [
                  {
                    'name': m[1]!.trim(),
                    'batch': null,
                    'level': null,
                    'valid_until': null,
                  },
                ],
              },
            );
          }
        default:
      }
    }
  }

  Iterable<_Hit> _choices() {
    final bySpan = <(int, int), List<(SpecProperty, String?)>>{};
    for (final p in all) {
      if (p.type != ParamType.enumOne && p.type != ParamType.enumMany) continue;
      for (final v in p.values) {
        for (final s in {v.code, v.label, ...v.aliases}) {
          for (final at in _find(s)) {
            final list = bySpan[at] ??= [];
            if (!list.any((o) => o.$1 == p)) list.add((p, v.code));
          }
        }
      }
    }
    return [
      for (final MapEntry(:key, :value) in bySpan.entries)
        _Hit(key.$1, key.$2, 'choice', value),
    ];
  }

  Iterable<_Hit> _mentions() {
    final bySpan = <(int, int), List<(SpecProperty, String?)>>{};
    for (final p in all) {
      for (final s in {p.label, ...p.aliases}) {
        if (s.length < 2) continue;
        for (final at in _find(s)) {
          final list = bySpan[at] ??= [];
          if (!list.any((o) => o.$1 == p)) list.add((p, null));
        }
      }
    }
    return [
      for (final MapEntry(:key, :value) in bySpan.entries)
        _Hit(key.$1, key.$2, 'mention', value),
    ];
  }

  /// Where [spelling] occurs; short Latin spellings only as whole tokens
  /// ("DP" not in "HDMI-DP2", "O2" not in "%O2").
  List<(int, int)> _find(String spelling) {
    final s = specText(spelling).toLowerCase();
    if (s.isEmpty) return const [];
    final latin = RegExp(r'^[a-z0-9]').hasMatch(s);
    bool edge(int at) =>
        at < 0 ||
        at >= lower.length ||
        !RegExp(r'[a-z0-9%]').hasMatch(lower[at]);
    final out = <(int, int)>[];
    for (var i = lower.indexOf(s); i >= 0; i = lower.indexOf(s, i + 1)) {
      if (latin && (!edge(i - 1) || !edge(i + s.length))) continue;
      out.add((i, i + s.length));
    }
    return out;
  }

  /// Longest spelling wins an overlap; complete values before choices
  /// before names.
  List<_Hit> _resolve(List<_Hit> hits) {
    const rank = {'fixed': 0, 'choice': 1, 'mention': 2};
    hits.sort((a, b) {
      final c = b.length.compareTo(a.length);
      return c != 0 ? c : rank[a.kind]!.compareTo(rank[b.kind]!);
    });
    final taken = <_Hit>[];
    for (final h in hits) {
      if (!taken.any(h.overlaps)) taken.add(h);
    }
    return taken..sort((a, b) => a.start.compareTo(b.start));
  }

  String _mask(List<_Hit> hits) {
    final chars = t.split('');
    for (final h in hits) {
      for (var i = h.start; i < h.end; i++) {
        chars[i] = '\u0000';
      }
    }
    return chars.join();
  }

  // ---------------------------------------------------------- numbers --

  Set<String> get _labels => {
    for (final p in props)
      if (p.unitLabel != null) p.unitLabel!,
  };

  /// Unit readings right after [at] and how many characters they take.
  (List<(String?, String?)>, int) _unitsAt(String s, int at) {
    final rest = s.substring(at);
    final r = rest.trimLeft();
    final skip = rest.length - r.length;
    var best = 0;
    var out = <(String?, String?)>[];
    void offer(String? kind, String unit, int len) {
      if (len < best) return;
      if (len > best) out = [];
      best = len;
      out.add((kind, unit));
    }

    for (final MapEntry(:key, :value) in quantityKinds.entries) {
      if (value.prefix(r) case (final u, final len)) offer(key, u.code, len);
    }
    for (final l in _labels) {
      if (r.startsWith(l)) offer(null, l, l.length);
    }
    if (best == 0) return (const [(null, null)], 0);
    // "2Kbps" is not 2 K: a unit must not run into more Latin letters.
    final next = skip + best;
    if (next < s.length - at && RegExp('[A-Za-z]').hasMatch(rest[next])) {
      return (const [], next);
    }
    return (out, next);
  }

  List<_Number> _numbers(String s) {
    final out = <_Number>[];
    final number = RegExp(r'(?<![A-Za-z0-9.])[-+]?\d+(?:\.\d+)?');
    final chinese = RegExp('[零一二两三四五六七八九十百]+');
    var at = 0;
    while (at < s.length) {
      final m = number.matchAsPrefix(s, at);
      final c = m == null ? chinese.matchAsPrefix(s, at) : null;
      if (m == null && c == null) {
        at++;
        continue;
      }
      if (c != null) {
        // Chinese numerals only before a counted word: "八核", "三路".
        final (units, len) = _unitsAt(s, c.end);
        final v = chineseNumber(c[0]!);
        if (v != null && len > 0 && units.every((u) => u.$1 == null)) {
          out.add(_Number(c.start, c.end + len, 'num', '$v', units));
          at = c.end + len;
        } else {
          at = c.end;
        }
        continue;
      }
      final tol = at > 0 && s.substring(0, at).trimRight().endsWith('±');
      final start = tol ? s.substring(0, at).lastIndexOf('±') : m!.start;
      final v = signedDecimal(m![0]!.replaceFirst('+', ''))!;
      if (tol) {
        final rest = s.substring(m.end).toUpperCase();
        final fs = RegExp(r'^\s*%?\s*(F\.?S|满量程|满度)').firstMatch(rest);
        final rd = RegExp(r'^\s*%?\s*(RD|读数|示值)').firstMatch(rest);
        if (fs != null || rd != null) {
          final e = m.end + (fs ?? rd)!.end;
          out.add(
            _Number(start, e, 'tol', v.replaceFirst('-', ''), const [
              (null, null),
            ], basis: fs != null ? 'FS' : 'RD'),
          );
          at = e;
          continue;
        }
        final (units, len) = _unitsAt(s, m.end);
        out.add(
          _Number(start, m.end + len, 'tol', v.replaceFirst('-', ''), units),
        );
        at = m.end + len;
        continue;
      }
      final (u1, len1) = _unitsAt(s, m.end);
      final sep = RegExp(r'\s*(?:~|-|至|到)\s*').matchAsPrefix(s, m.end + len1);
      final m2 = sep == null ? null : number.matchAsPrefix(s, sep.end);
      if (m2 != null) {
        final (u2, len2) = _unitsAt(s, m2.end);
        final written = [
          u1,
          u2,
        ].where((u) => u.isEmpty || u.first != (null, null));
        out.add(
          _Number(
            m.start,
            m2.end + len2,
            'range',
            v,
            written.isEmpty ? u1 : written.last,
            max: signedDecimal(m2[0]!.replaceFirst('+', '')),
          ),
        );
        at = m2.end + len2;
        continue;
      }
      out.add(_Number(m.start, m.end + len1, 'num', v, u1));
      at = m.end + len1;
    }
    return out;
  }

  // ---------------------------------------------------------- scoring --

  (int, int) _segment(int at) {
    final sep = RegExp(r'[,;。，；]');
    var s = at;
    while (s > 0 && !sep.hasMatch(t[s - 1])) {
      s--;
    }
    var e = at;
    while (e < t.length && !sep.hasMatch(t[e])) {
      e++;
    }
    return (s, e);
  }

  /// How strongly the clause names [p]: its name in the value's segment,
  /// elsewhere in the clause, or shared two-character pieces of it.
  int _cue(SpecProperty p, String seg) {
    var best = 0;
    for (final raw in {p.label, ...p.aliases}) {
      final k = specText(raw).toLowerCase();
      if (k.length < 2) continue;
      if (seg.contains(k)) {
        best = max(best, 1000 + k.length);
      } else if (lower.contains(k)) {
        best = max(best, 500 + k.length);
      } else {
        var s = 0;
        for (var i = 0; i + 2 <= k.length; i++) {
          final b = k.substring(i, i + 2);
          s += seg.contains(b) ? 2 : (lower.contains(b) ? 1 : 0);
        }
        best = max(best, s);
      }
    }
    return best;
  }

  SpecProperty? _choose(List<SpecProperty> candidates, int at) {
    if (candidates.length == 1) return candidates.single;
    if (candidates.isEmpty) return null;
    final (s, e) = _segment(at);
    final seg = lower.substring(s, e);
    final scored = [for (final p in candidates) (p, _cue(p, seg))]
      ..sort((a, b) => b.$2.compareTo(a.$2));
    if (scored[0].$2 == 0 || scored[0].$2 == scored[1].$2) return null;
    return scored[0].$1;
  }

  String _names(Iterable<SpecProperty> ps) =>
      ps.map((p) => p.label).toSet().join('/');

  // -------------------------------------------------------- assigning --

  String? _comparator(String masked, int start, int end, int? prevEnd) {
    final (s, e) = _segment(start);
    final before = masked.substring(max(s, prevEnd ?? s), start);
    String? op;
    var bestEnd = -1;
    for (final (w, o) in _before) {
      final i = before.lastIndexOf(w);
      if (i >= 0 && i + w.length > bestEnd) {
        bestEnd = i + w.length;
        op = o;
      }
    }
    if (op != null) return op;
    final after = masked.substring(end, min(e, end + 6)).trimLeft();
    for (final (w, o) in _after) {
      if (after.startsWith(w)) return o;
    }
    return null;
  }

  void _add(
    SpecProperty p,
    String op,
    Map<String, Object?> value,
    int start,
    int end,
  ) {
    final evidence = t.substring(start, end).trim();
    final Map<String, Object?> v;
    try {
      v = normalizeParamValue(p, value);
    } on FormatException {
      hints.add('「$evidence」的数值无效');
      return;
    }
    if (made.containsKey(p.code)) {
      if ('${made[p.code]!.value}' != '$v') {
        hints.add('「${p.label}」出现了不止一次');
      }
      used.add((start, end));
      return;
    }
    made[p.code] = SpecConstraint(p.code, op, v, mark: mark, text: evidence);
    used.add((start, end));
  }

  void _assignChoices(List<_Hit> hits, String masked) {
    final byProp = <SpecProperty, List<(_Hit, String)>>{};
    for (final h in hits) {
      if (h.kind == 'fixed') {
        final p = h.options.single.$1;
        final op = opsFor(p).first;
        _add(p, op, h.value!, h.start, h.end);
        continue;
      }
      if (h.kind != 'choice') continue;
      final candidates = [
        for (final (p, _) in h.options)
          if (props.contains(p)) p,
      ];
      final p = _choose(candidates, h.start);
      if (p == null) {
        if (candidates.isNotEmpty) {
          hints.add(
            '「${t.substring(h.start, h.end)}」可能是${_names(candidates)}，请指定',
          );
        }
        continue;
      }
      final code = h.options.firstWhere((o) => o.$1 == p).$2!;
      (byProp[p] ??= []).add((h, code));
    }
    for (final MapEntry(key: p, value: list) in byProp.entries) {
      final codes = {for (final (_, c) in list) c}.toList();
      final start = list.first.$1.start, end = list.last.$1.end;
      if (p.type == ParamType.enumOne) {
        if (codes.length > 1) {
          hints.add('「${p.label}」写了多个值，请确认');
          continue;
        }
        // Ordered choices read as "at least": a higher rank is judged
        // "待确认" by the comparison, never silently accepted.
        _add(p, opsFor(p).first, {'v': codes.single}, start, end);
      } else {
        final between = t.substring(start, end);
        final any = RegExp('或|任一|之一').hasMatch(between);
        _add(p, any ? 'any' : 'all', {'vs': codes}, start, end);
        // Each value is read; what lies between them ("OPC DA/UA") is not.
        used
          ..remove((start, end))
          ..addAll([for (final (h, _) in list) (h.start, h.end)]);
      }
    }
  }

  void _assignNumber(_Number x, String masked, int? prevEnd) {
    if (x.units.isEmpty) return; // unknown unit: reported as leftover
    final cmp = _comparator(masked, x.start, x.end, prevEnd);
    final unitless =
        x.basis == null &&
        x.units.length == 1 &&
        x.units.single == (null, null);
    bool fits(SpecProperty p) => x.units.any(
      (u) =>
          u.$1 == null ? p.kind == null && p.unitLabel == u.$2 : p.kind == u.$1,
    );
    List<SpecProperty> of(ParamType type) => [
      for (final p in props)
        if (p.type == type && (x.basis != null || fits(p))) p,
    ];
    var candidates = switch (x.shape) {
      'tol' => of(ParamType.tol),
      'range' => of(ParamType.range),
      _ => of(ParamType.num),
    };
    var oneSided = false;
    if (x.shape == 'num' && candidates.isEmpty && cmp != null && !unitless) {
      candidates = of(ParamType.range);
      oneSided = true;
    }
    String? assumed;
    if (unitless) {
      // No unit written: only a parameter named right there.
      final (s, e) = _segment(x.start);
      final seg = lower.substring(s, e);
      candidates = [
        for (final p in props)
          if (p.type ==
                  (x.shape == 'num'
                      ? ParamType.num
                      : x.shape == 'tol'
                      ? ParamType.tol
                      : ParamType.range) &&
              _cue(p, seg) >= 1000)
            p,
      ];
    }
    final p = _choose(candidates, x.start);
    if (p == null) {
      if (candidates.length > 1) {
        hints.add(
          '「${t.substring(x.start, x.end).trim()}」可能是${_names(candidates)}，请指定',
        );
        used.add((x.start, x.end));
      }
      return;
    }
    String? unit() {
      if (p.kind == null) return null;
      for (final u in x.units) {
        if (u.$1 == p.kind) return u.$2;
      }
      assumed = quantityKinds[p.kind]!.unit(p.unit!)!.label;
      return p.unit;
    }

    final u = unit();
    if (assumed != null)
      hints.add('「${t.substring(x.start, x.end).trim()}」没写单位，按 $assumed 理解');
    final (op, value) = switch (x.shape) {
      'tol' => (
        'le',
        {'v': x.v, if (x.basis != null) 'basis': x.basis else 'u': u},
      ),
      'range' => ('covers', {'min': x.v, 'max': x.max, 'u': u}),
      _ when oneSided => (
        'covers',
        cmp == 'ge' || cmp == 'gt'
            ? {'min': x.v, 'max': null, 'u': u}
            : {'min': null, 'max': x.v, 'u': u},
      ),
      _ => (_numOp(p, cmp), {'v': x.v, 'u': u}),
    };
    if (x.shape == 'tol' && (cmp == 'ge' || cmp == 'gt')) {
      hints.add('「${_cmpLabels[cmp]}」用于精度，请核对');
    }
    if (oneSided && cmp == 'better') {
      hints.add('「${p.label}」的范围方向不明确，请核对');
    }
    if (x.shape == 'num' && !oneSided && cmp != null && cmp != 'better') {
      final against =
          (p.order == Order.lower && (cmp == 'ge' || cmp == 'gt')) ||
          (p.order == Order.higher && (cmp == 'le' || cmp == 'lt'));
      if (against) {
        hints.add(
          '「${_cmpLabels[cmp]}」与「${p.label}」${p.order == Order.lower ? '越小越好' : '越大越好'}的方向相反，请核对',
        );
      }
    }
    _add(p, op, value, x.start, x.end);
  }

  String _numOp(SpecProperty p, String? cmp) => switch (cmp) {
    'better' => p.order == Order.lower ? 'le' : 'ge',
    null => opsFor(p).first,
    _ => cmp,
  };

  void _bools(List<_Hit> hits) {
    for (final h in hits) {
      if (h.kind != 'mention') continue;
      final bools = [
        for (final (p, _) in h.options)
          if (p.type == ParamType.bool && props.contains(p)) p,
      ];
      if (bools.length != 1) continue;
      final before = h.start == 0 ? '' : t[h.start - 1];
      if ('不无非免未'.contains(before) && before.isNotEmpty) {
        hints.add('「${t.substring(h.start - 1, h.end)}」是否定说法，请核对');
        continue;
      }
      _add(bools.single, 'is', {'v': true}, h.start, h.end);
    }
  }

  /// A parameter named without a value the rules could read.
  void _unparsedMentions(List<_Hit> hits) {
    final kinds = {
      for (final c in made.values) ?specProperty(c.property)?.kind,
    };
    for (final h in hits) {
      if (h.kind != 'mention') continue;
      final ps = [for (final (p, _) in h.options) p];
      if (ps.any((p) => made.containsKey(p.code) || kinds.contains(p.kind))) {
        continue;
      }
      hints.add('提到「${t.substring(h.start, h.end)}」但没读出要求值');
    }
  }

  /// Numbers and Latin words no constraint accounts for.
  void _leftovers(String masked, List<_Number> numbers) {
    bool covered(int s, int e) => used.any((u) => u.$1 <= s && e <= u.$2);
    final rest = <String>[];
    for (final x in numbers) {
      if (!covered(x.start, x.end))
        rest.add(t.substring(x.start, x.end).trim());
    }
    for (final m in RegExp(
      r'[A-Za-z][A-Za-z0-9]*|\d+(?:\.\d+)?',
    ).allMatches(masked)) {
      if (covered(m.start, m.end)) continue;
      if (numbers.any((x) => x.start <= m.start && m.end <= x.end)) continue;
      if (_plainWords.contains(m[0]!.toLowerCase())) continue;
      rest.add(m[0]!);
    }
    if (rest.isNotEmpty) hints.add('未识别：${rest.toSet().join('、')}');
  }
}
