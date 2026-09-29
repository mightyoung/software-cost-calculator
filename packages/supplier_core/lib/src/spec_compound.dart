import 'package:unorm_dart/unorm_dart.dart' as unicode;

/// Full-width to half-width, ℃ to °C, unicode minus to "-".
String specText(String s) =>
    unicode.nfkc(s).replaceAll(RegExp('[−–—]'), '-').replaceAll('～', '~');

// ------------------------------------------------------------ IP codes --

/// "IP66" → (solid 6, liquid "6"); X means not tested (null).
class IpCode {
  const IpCode(this.solid, this.liquid);
  final int? solid;

  /// "0".."9" or "9K"; null for X.
  final String? liquid;

  int? get liquidDigit => liquid == null ? null : int.parse(liquid![0]);

  @override
  String toString() => 'IP${solid ?? 'X'}${liquid ?? 'X'}';
}

final _ipOne = RegExp(r'^IP([0-6X])([0-9X]K?)$');

IpCode? parseIpCode(String code) {
  final m = _ipOne.firstMatch(code.toUpperCase().replaceAll(' ', ''));
  if (m == null) return null;
  final liquid = m[2]!;
  if (liquid.startsWith('X') && liquid.length > 1) return null;
  return IpCode(
    m[1] == 'X' ? null : int.parse(m[1]!),
    liquid == 'X' ? null : liquid,
  );
}

/// Every IP code in [text]; "IP66/67" and "IP66/IP67" give both (dual
/// coding under IEC 60529).
List<String> parseIpCodes(String text) {
  final t = specText(text).toUpperCase().replaceAll(' ', '');
  final codes = <String>[];
  for (final m in RegExp(
    r'IP([0-6X][0-9X]K?)((?:/(?:IP)?[0-6X][0-9X]K?)*)',
  ).allMatches(t)) {
    for (final part in [
      m[1]!,
      ...m[2]!.split('/').where((s) => s.isNotEmpty),
    ]) {
      final code = 'IP${part.replaceFirst('IP', '')}';
      if (parseIpCode(code) != null && !codes.contains(code)) codes.add(code);
    }
  }
  return codes;
}

// --------------------------------------------------------- Ex markings --

/// One explosion-protection marking, e.g. Ex db IIB T4 Gb (IEC 60079-0 /
/// GB/T 3836.1).
class ExMark {
  const ExMark({this.types = const [], this.group, this.temp, this.epl});
  final List<String> types;

  /// I, IIA, IIB, IIC, II, IIIA, IIIB, IIIC, III.
  final String? group;

  /// T1..T6, or a surface temperature such as "135℃".
  final String? temp;

  /// Ga, Gb, Gc, Da, Db, Dc, Ma, Mb.
  final String? epl;

  Map<String, Object?> toJson() => {
    'types': types,
    'group': group,
    'temp': temp,
    'epl': epl,
  };

  static ExMark fromJson(Map<String, Object?> m) => ExMark(
    types: validatedExTypes(m['types']),
    group: m['group'] as String?,
    temp: m['temp'] as String?,
    epl: m['epl'] as String?,
  );

  @override
  String toString() => [
    'Ex',
    if (types.isNotEmpty) types.join(' '),
    ?group,
    ?temp,
    ?epl,
  ].join(' ');
}

/// Types of protection, longest first so "db" wins over "d".
const _exTypes = [
  'pxb', 'pyb', 'pzc', 'opis', 'oppr', 'opsh', //
  'da', 'db', 'dc', 'eb', 'ec', 'ia', 'ib', 'ic', 'ma', 'mb', 'mc', //
  'na', 'nc', 'nr', 'ob', 'oc', 'px', 'py', 'pz', 'qb', 'ta', 'tb', 'tc', //
  'op', 'd', 'e', 'i', 'm', 'n', 'o', 'p', 'q', 's', 't',
];

/// Keep absent concepts (group-only markings) but never coerce unknown values.
List<String> validatedExTypes(Object? raw) {
  if (raw == null) return const [];
  if (raw is! List ||
      raw.length > 12 ||
      raw.any((t) => t is! String || !_exTypes.contains(t))) {
    throw const FormatException('value.marks.types: invalid protection types');
  }
  return raw.cast<String>();
}

List<String>? _splitTypes(String s) {
  final out = <String>[];
  var rest = s.toLowerCase().replaceAll(RegExp(r'[^a-z]'), '');
  while (rest.isNotEmpty) {
    final t = _exTypes.where(rest.startsWith).firstOrNull;
    if (t == null) return null;
    out.add(t);
    rest = rest.substring(t.length);
  }
  return out;
}

final _exGroup = RegExp(r'III[ABC]|II[ABC]|III|II|I(?![A-Z])');
final _exTemp = RegExp(r'T([1-6])(?![0-9])|T?([0-9]{2,3})(?:°C|C)');
final _exEpl = RegExp(r'([GDM])([ABC])(?![A-Z])');

/// Parses "Ex d IIB T4 Gb", "EX d IIBT4 Gb", "ExdIIBT4", "Ex tb IIIC T85℃
/// Db"; null when no gas/dust group is found.
ExMark? parseExMark(String text) {
  var t = specText(text).replaceAll(' ', '');
  t = t.replaceFirst(RegExp(r'^[Ee][Xx]'), '');
  final upper = t.toUpperCase();
  final g = _exGroup.firstMatch(upper);
  if (g == null) return null;
  final types = _splitTypes(t.substring(0, g.start)) ?? const <String>[];
  final after = upper.substring(g.end);
  final temp = _exTemp.firstMatch(after);
  final epl = _exEpl.firstMatch(after);
  return ExMark(
    types: types,
    group: g[0],
    temp: temp == null
        ? null
        : temp[1] != null
        ? 'T${temp[1]}'
        : '${temp[2]}℃',
    epl: epl == null ? null : '${epl[1]}${epl[2]!.toLowerCase()}',
  );
}

/// Every marking in [text] (a device may carry gas and dust markings).
List<ExMark> parseExMarks(String text) {
  final t = specText(text);
  final starts = [
    for (final m in RegExp('(?<![A-Za-z])[Ee][Xx]').allMatches(t)) m.start,
  ];
  final pieces = starts.isEmpty
      ? [t]
      : [
          for (var i = 0; i < starts.length; i++)
            t.substring(
              starts[i],
              i + 1 < starts.length ? starts[i + 1] : t.length,
            ),
        ];
  return [for (final p in pieces) ?parseExMark(p)];
}

/// Group rank within its category (I, II gas, III dust); an undivided II
/// or III is suitable for every subdivision.
(String, int)? exGroupRank(String group) => switch (group) {
  'I' => ('I', 1),
  'IIA' => ('II', 1),
  'IIB' => ('II', 2),
  'IIC' || 'II' => ('II', 3),
  'IIIA' => ('III', 1),
  'IIIB' => ('III', 2),
  'IIIC' || 'III' => ('III', 3),
  _ => null,
};

/// Maximum surface temperature in ℃ (T1 450 … T6 85).
int? exMaxTemp(String temp) {
  const classes = {
    'T1': 450,
    'T2': 300,
    'T3': 200,
    'T4': 135,
    'T5': 100,
    'T6': 85,
  };
  return classes[temp] ?? int.tryParse(temp.replaceAll('℃', ''));
}

/// EPL as (letter, rank): Ga 3 > Gb 2 > Gc 1.
(String, int)? exEplRank(String epl) {
  final m = RegExp(r'^([GDM])([abc])$').firstMatch(epl);
  if (m == null) return null;
  return (m[1]!, 3 - 'abc'.indexOf(m[2]!));
}

/// EPL implied by the type of protection when a marking omits it.
String? exImpliedEpl(List<String> types) {
  const implied = {
    'da': 'Ga',
    'db': 'Gb',
    'd': 'Gb',
    'dc': 'Gc',
    'eb': 'Gb',
    'e': 'Gb',
    'ec': 'Gc',
    'ia': 'Ga',
    'ib': 'Gb',
    'ic': 'Gc',
    'ma': 'Ga',
    'mb': 'Gb',
    'm': 'Gb',
    'mc': 'Gc',
    'nA': 'Gc',
    'na': 'Gc',
    'nc': 'Gc',
    'nr': 'Gc',
    'ob': 'Gb',
    'o': 'Gb',
    'px': 'Gb',
    'pxb': 'Gb',
    'py': 'Gb',
    'pyb': 'Gb',
    'pz': 'Gc',
    'pzc': 'Gc',
    'qb': 'Gb',
    'q': 'Gb',
    'ta': 'Da',
    'tb': 'Db',
    'tc': 'Dc',
  };
  String? best;
  for (final t in types) {
    final e = implied[t];
    if (e != null && (best == null || exEplRank(e)!.$2 > exEplRank(best)!.$2)) {
      best = e;
    }
  }
  return best;
}

/// Protection concept regardless of level: d / db / dc → d; ia / ib → i.
String exFamily(String type) => type.startsWith('op')
    ? 'op'
    : type.isEmpty
    ? ''
    : type[0];
