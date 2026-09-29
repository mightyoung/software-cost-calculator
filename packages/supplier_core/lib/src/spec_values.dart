import 'pricing.dart';
import 'spec_compound.dart';
import 'spec_dictionary.dart';
import 'spec_units.dart';
import 'values.dart';

/// Validated, canonical value JSON for [p] (shapes in the design doc §4.4).
Map<String, Object?> normalizeParamValue(SpecProperty p, Object? raw) {
  if (raw is! Map) invalid('value', 'expected object');
  final v = raw.cast<String, Object?>();
  String dec(Object? x, String field, {bool unsigned = false}) {
    final d = x is String
        ? (unsigned ? tryDecimal(x) : signedDecimal(x))
        : x is num
        ? (unsigned ? tryDecimal('$x') : signedDecimal('$x'))
        : null;
    if (d == null) invalid('value.$field', 'expected a number');
    return d;
  }

  String? unit() {
    if (p.kind == null) return null;
    final u = (v['u'] as String?) ?? p.unit!;
    if (quantityKinds[p.kind]!.unit(u) == null) {
      invalid('value.u', 'unit does not fit the parameter');
    }
    return u;
  }

  String code(Object? x) {
    if (x is! String || x.trim().isEmpty) invalid('value', 'expected text');
    final c = x.trim();
    if (p.restrictive && p.value(c) == null) {
      invalid('value', 'not one of the allowed values');
    }
    if (c.length > 100) invalid('value', 'too long');
    return c;
  }

  switch (p.type) {
    case ParamType.num:
      return {'v': dec(v['v'], 'v'), if (p.kind != null) 'u': unit()};
    case ParamType.range:
      final min = v['min'] == null ? null : dec(v['min'], 'min');
      final max = v['max'] == null ? null : dec(v['max'], 'max');
      if (min == null && max == null) invalid('value', 'range needs an end');
      if (min != null && max != null && micros(min) > micros(max)) {
        invalid('value', 'range minimum above maximum');
      }
      return {'min': min, 'max': max, if (p.kind != null) 'u': unit()};
    case ParamType.tol:
      final basis = v['basis'] ?? 'abs';
      if (basis != 'abs' && basis != 'FS' && basis != 'RD') {
        invalid('value.basis', 'unknown value');
      }
      return {
        'v': dec(v['v'], 'v', unsigned: true),
        if (basis == 'abs' && p.kind != null) 'u': unit(),
        if (basis != 'abs') 'basis': basis,
      };
    case ParamType.enumOne:
      return {'v': code(v['v'])};
    case ParamType.enumMany:
      final list = v['vs'];
      if (list is! List || list.isEmpty || list.length > 30) {
        invalid('value.vs', 'expected 1 to 30 values');
      }
      return {
        'vs': [
          ...{for (final x in list) code(x)},
        ],
      };
    case ParamType.bool:
      if (v['v'] is! bool) invalid('value.v', 'expected true or false');
      return {'v': v['v']};
    case ParamType.text:
      return {'v': normalizeText(v['v'], 'value.v', 500, required: true)};
    case ParamType.ip:
      final codes = v['codes'];
      if (codes is! List || codes.isEmpty || codes.length > 3) {
        invalid('value.codes', 'expected 1 to 3 IP codes');
      }
      return {
        'codes': [
          for (final c in codes)
            if (c is String && parseIpCode(c) != null)
              '${parseIpCode(c)}'
            else
              invalid('value.codes', 'not an IP code'),
        ],
      };
    case ParamType.ex:
      final marks = v['marks'];
      if (marks is! List || marks.isEmpty || marks.length > 4) {
        invalid('value.marks', 'expected 1 to 4 markings');
      }
      return {
        'marks': [
          for (final m in marks)
            if (m is Map &&
                m['group'] is String &&
                exGroupRank(m['group'] as String) != null &&
                (m['temp'] == null ||
                    (m['temp'] is String &&
                        exMaxTemp(m['temp'] as String) != null)) &&
                (m['epl'] == null ||
                    (m['epl'] is String &&
                        exEplRank(m['epl'] as String) != null)))
              ExMark.fromJson(m.cast<String, Object?>()).toJson()
            else
              invalid('value.marks', 'not an explosion-protection marking'),
        ],
      };
    case ParamType.catalog:
      final entries = v['entries'];
      if (entries is! List || entries.isEmpty || entries.length > 10) {
        invalid('value.entries', 'expected 1 to 10 entries');
      }
      return {
        'entries': [
          for (final e in entries)
            if (e is Map)
              {
                'name': normalizeText(
                  e['name'],
                  'value.name',
                  100,
                  required: true,
                ),
                'batch': normalizeText(e['batch'], 'value.batch', 50),
                'level': normalizeText(e['level'], 'value.level', 20),
                'valid_until': e['valid_until'] == null
                    ? null
                    : requireDate(e['valid_until'], 'value.valid_until'),
              }
            else
              invalid('value.entries', 'expected objects'),
        ],
      };
  }
}

// ---------------------------------------------------------- text parsing --

const _cnDigits = {
  '零': 0, '一': 1, '二': 2, '两': 2, '三': 3, '四': 4, '五': 5, //
  '六': 6, '七': 7, '八': 8, '九': 9,
};

/// "八" 8, "十六" 16, "三十二" 32, "一百二十八" 128; null otherwise.
int? chineseNumber(String s) {
  if (s.isEmpty) return null;
  var total = 0, current = 0;
  for (final ch in s.split('')) {
    if (_cnDigits.containsKey(ch)) {
      current = _cnDigits[ch]!;
    } else if (ch == '十') {
      total += (current == 0 ? 1 : current) * 10;
      current = 0;
    } else if (ch == '百') {
      total += (current == 0 ? 1 : current) * 100;
      current = 0;
    } else {
      return null;
    }
  }
  return total + current;
}

final _number = RegExp(r'[-+]?\d+(?:\.\d+)?');
final _cnNumber = RegExp('[零一二两三四五六七八九十百]+');

/// First number in [t] (Arabic or Chinese) and where it ends.
(String, int)? _firstNumber(String t) {
  final m = _number.firstMatch(t);
  final c = _cnNumber.firstMatch(t);
  if (m != null && (c == null || m.start <= c.start)) {
    final d = signedDecimal(m[0]!);
    return d == null ? null : (d, m.end);
  }
  if (c != null) {
    final n = chineseNumber(c[0]!);
    return n == null ? null : ('$n', c.end);
  }
  return null;
}

/// Unit right after a number, skipping spaces; default unit when none.
String? _unitAfter(SpecProperty p, String t, int at) {
  if (p.kind == null) return null;
  final kind = quantityKinds[p.kind]!;
  final hit = kind.prefix(t.substring(at).trimLeft());
  return hit?.$1.code ?? p.unit;
}

/// Reads a value for [p] from how people write it: "2.3GHz及以上", "八核",
/// "-20℃~+80℃", "±1%FS", "IP66/67", "Ex d IIB T4 Gb", "RS485、4-20mA".
/// Null when nothing usable is found.
Map<String, Object?>? parseParamText(SpecProperty p, String text) {
  final t = specText(text).trim();
  if (t.isEmpty) return null;
  switch (p.type) {
    case ParamType.num:
      final n = _firstNumber(t);
      if (n == null) return null;
      return {'v': n.$1, if (p.kind != null) 'u': _unitAfter(p, t, n.$2)};
    case ParamType.range:
      final m = RegExp(
        r'([-+]?\d+(?:\.\d+)?)\s*([^\d~\-+至到]*?)\s*(?:~|至|到|-)\s*([-+]?\d+(?:\.\d+)?)',
      ).firstMatch(t);
      if (m == null) return null;
      final unit =
          _unitAfter(p, t, m.end) ??
          (p.kind == null
              ? null
              : quantityKinds[p.kind]!.prefix(m[2]!.trim())?.$1.code ?? p.unit);
      return {
        'min': signedDecimal(m[1]!),
        'max': signedDecimal(m[3]!),
        if (p.kind != null) 'u': unit,
      };
    case ParamType.tol:
      final n = _number.firstMatch(t.replaceAll('±', ''));
      if (n == null) return null;
      final v = tryDecimal(n[0]!.replaceFirst(RegExp('^[-+]'), ''));
      if (v == null) return null;
      final rest = t.replaceAll('±', '').substring(n.end).toUpperCase();
      if (RegExp(r'^\s*%?\s*(F\.?S|满量程|满度)').hasMatch(rest)) {
        return {'v': v, 'basis': 'FS'};
      }
      if (RegExp(r'^\s*%?\s*(RD|读数|示值)').hasMatch(rest)) {
        return {'v': v, 'basis': 'RD'};
      }
      return {
        'v': v,
        if (p.kind != null) 'u': _unitAfter(p, t.replaceAll('±', ''), n.end),
      };
    case ParamType.enumOne:
      final hits = matchEnumValues(p, t);
      if (hits.isNotEmpty) return {'v': hits.first};
      return p.restrictive || t.length > 100 ? null : {'v': t};
    case ParamType.enumMany:
      final hits = matchEnumValues(p, t);
      if (hits.isNotEmpty) return {'vs': hits};
      if (p.restrictive) return null;
      final parts = [
        for (final s in t.split(RegExp('[、,，;；/和及]')))
          if (s.trim().isNotEmpty && s.trim().length <= 100) s.trim(),
      ];
      return parts.isEmpty ? null : {'vs': parts};
    case ParamType.bool:
      if (RegExp(
        '^(否|无|不|没有|N|NO|FALSE|×)',
        caseSensitive: false,
      ).hasMatch(t)) {
        return {'v': false};
      }
      if (RegExp(
        '^(是|有|支持|具备|带|含|配|√|✓|Y|YES|TRUE)',
        caseSensitive: false,
      ).hasMatch(t)) {
        return {'v': true};
      }
      return null;
    case ParamType.text:
      return {'v': t.length > 500 ? t.substring(0, 500) : t};
    case ParamType.ip:
      final codes = parseIpCodes(t);
      return codes.isEmpty ? null : {'codes': codes.take(3).toList()};
    case ParamType.ex:
      final marks = parseExMarks(t);
      return marks.isEmpty
          ? null
          : {
              'marks': [for (final m in marks.take(4)) m.toJson()],
            };
    case ParamType.catalog:
      final name = t.replaceAll(RegExp('[《》]'), '').trim();
      if (name.isEmpty) return null;
      return {
        'entries': [
          {
            'name': name.length > 100 ? name.substring(0, 100) : name,
            'batch': null,
            'level': null,
            'valid_until': null,
          },
        ],
      };
  }
}

/// Codes of [p]'s values named in [text], longest spelling first so
/// "Modbus TCP" is not also read as "TCP".
List<String> matchEnumValues(SpecProperty p, String text) {
  final hay = text.toLowerCase();
  final spellings = [
    for (final v in p.values)
      for (final s in {v.code, v.label, ...v.aliases})
        if (s.isNotEmpty) (v.code, s.toLowerCase()),
  ]..sort((a, b) => b.$2.length.compareTo(a.$2.length));
  final taken = List<bool>.filled(hay.length, false);
  final found = <(int, String)>[];
  for (final (code, s) in spellings) {
    var from = 0;
    while (true) {
      final i = hay.indexOf(s, from);
      if (i < 0) break;
      from = i + 1;
      // Whole tokens only for short Latin spellings ("DP" in "DDP").
      final latin = RegExp(r'^[a-z0-9]').hasMatch(s);
      bool boundary(int at) =>
          at < 0 || at >= hay.length || !RegExp(r'[a-z0-9]').hasMatch(hay[at]);
      if (latin && (!boundary(i - 1) || !boundary(i + s.length))) continue;
      if (taken.sublist(i, i + s.length).any((x) => x)) continue;
      for (var k = i; k < i + s.length; k++) {
        taken[k] = true;
      }
      if (!found.any((f) => f.$2 == code)) found.add((i, code));
    }
  }
  found.sort((a, b) => a.$1.compareTo(b.$1));
  return [for (final f in found) f.$2];
}

// ------------------------------------------------------------- display --

String _unitLabel(SpecProperty p, Object? unit) {
  if (p.kind == null) return p.unitLabel ?? '';
  return quantityKinds[p.kind]!.unit('$unit')?.label ?? '$unit';
}

/// A value as people read it: "2.3 GHz", "-40～85 ℃", "±1 %FS".
String formatParamValue(SpecProperty p, Map<String, Object?> v) {
  String join(String n, String u) => u.isEmpty ? n : '$n $u';
  String label(Object? code) => p.value('$code')?.label ?? '$code';
  return switch (p.type) {
    ParamType.num => join('${v['v']}', _unitLabel(p, v['u'])),
    ParamType.range => join(
      '${v['min'] ?? ''}～${v['max'] ?? ''}',
      _unitLabel(p, v['u']),
    ),
    ParamType.tol =>
      v['basis'] == null
          ? join('±${v['v']}', _unitLabel(p, v['u']))
          : '±${v['v']} %${v['basis']}',
    ParamType.enumOne => label(v['v']),
    ParamType.enumMany => [
      for (final c in v['vs']! as List) label(c),
    ].join('、'),
    ParamType.bool => v['v'] == true ? '是' : '否',
    ParamType.text => '${v['v']}',
    ParamType.ip => (v['codes']! as List).join('/'),
    ParamType.ex => [
      for (final m in v['marks']! as List)
        '${ExMark.fromJson((m as Map).cast<String, Object?>())}',
    ].join('；'),
    ParamType.catalog => [
      for (final e in v['entries']! as List)
        [
          (e as Map)['name'],
          e['batch'],
          if (e['level'] != null) '${e['level']}级',
          if (e['valid_until'] != null) '有效至 ${e['valid_until']}',
        ].whereType<String>().join(' '),
    ].join('；'),
  };
}

/// What to type into the parameter's field ("例如 2.3 GHz").
String paramHint(SpecProperty p) => switch (p.type) {
  ParamType.num =>
    '例如 ${p.kind == null ? 8 : 2} ${_unitLabel(p, p.unit)}'.trim(),
  ParamType.range => '例如 -20～80 ${_unitLabel(p, p.unit)}'.trim(),
  ParamType.tol => '例如 ±0.5 ${_unitLabel(p, p.unit)} 或 ±1%FS',
  ParamType.enumOne ||
  ParamType.enumMany => p.values.take(4).map((v) => v.label).join(' / '),
  ParamType.bool => '是 / 否',
  ParamType.text => '',
  ParamType.ip => '例如 IP65 或 IP66/IP67',
  ParamType.ex => '例如 Ex db IIC T6 Gb',
  ParamType.catalog => '目录名称，例如 安全可靠测评结果',
};
