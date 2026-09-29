import 'pricing.dart';
import 'values.dart';

/// A unit of one quantity kind: base = (value + pre) × mul ÷ div.
/// Units of the same kind convert when they share a [group]; a different
/// group (e.g. %LEL next to ppm) never converts, the answer is "unknown".
class UnitDef {
  const UnitDef(
    this.code,
    this.label, {
    this.aliases = const [],
    this.mul = 1,
    this.div = 1,
    this.pre = '0',
    this.group = '',
  });
  final String code, label;
  final List<String> aliases;
  final int mul, div;

  /// Added before scaling (affine units: K, ℉), as signed decimal text.
  final String pre;
  final String group;
}

/// A measurable quantity and the units it can be written in (Akeneo
/// measurement family / ECLASS quantity). The first unit is the base.
class QuantityKind {
  const QuantityKind(this.code, this.label, this.units);
  final String code, label;
  final List<UnitDef> units;
  UnitDef get base => units.first;

  UnitDef? unit(String code) {
    for (final u in units) {
      if (u.code == code) return u;
    }
    return null;
  }

  /// The unit whose longest spelling starts [text] ("GHz及以上" → GHz), with
  /// the length consumed; null when none does.
  (UnitDef, int)? prefix(String text) {
    (UnitDef, int)? best;
    for (final u in units) {
      for (final s in [u.code, u.label, ...u.aliases]) {
        if (s.isEmpty || s.length > text.length) continue;
        if (_unitKey(text.substring(0, s.length)) == _unitKey(s) &&
            (best == null || s.length > best.$2)) {
          best = (u, s.length);
        }
      }
    }
    return best;
  }

  /// Unit written as [text] (code, label or alias, case-insensitive).
  UnitDef? find(String text) {
    final t = _unitKey(text);
    if (t.isEmpty) return null;
    for (final u in units) {
      if (_unitKey(u.code) == t ||
          _unitKey(u.label) == t ||
          u.aliases.any((a) => _unitKey(a) == t)) {
        return u;
      }
    }
    return null;
  }
}

String _unitKey(String s) => s
    .replaceAll(RegExp(r'\s'), '')
    .replaceAll('°', '')
    .replaceAll('／', '/')
    .toLowerCase();

const _gb = 1024;

const quantityKinds = <String, QuantityKind>{
  'temperature': QuantityKind('temperature', '温度', [
    UnitDef('Cel', '℃', aliases: ['°C', 'C', '摄氏度', '度']),
    UnitDef('K', 'K', aliases: ['开', '开尔文'], pre: '-273.15'),
    UnitDef(
      '[degF]',
      '℉',
      aliases: ['°F', 'F', '华氏度'],
      mul: 5,
      div: 9,
      pre: '-32',
    ),
  ]),
  // Accuracy and resolution are temperature differences: no offset.
  'temp_diff': QuantityKind('temp_diff', '温差', [
    UnitDef('Cel', '℃', aliases: ['°C', 'C', '摄氏度', '度']),
    UnitDef('K', 'K', aliases: ['开']),
    UnitDef('[degF]', '℉', aliases: ['°F', 'F'], mul: 5, div: 9),
  ]),
  'humidity': QuantityKind('humidity', '相对湿度', [
    UnitDef('%RH', '%RH', aliases: ['RH', '%rh', 'RH%', '%']),
  ]),
  'frequency': QuantityKind('frequency', '频率', [
    UnitDef('Hz', 'Hz', aliases: ['赫兹', '赫']),
    UnitDef('kHz', 'kHz', aliases: ['KHz', '千赫'], mul: 1000),
    UnitDef('MHz', 'MHz', aliases: ['兆赫', 'M'], mul: 1000000),
    UnitDef('GHz', 'GHz', aliases: ['G', 'G赫兹', '吉赫'], mul: 1000000000),
  ]),
  // Memory is counted in powers of 1024 but written GB, as everyone does.
  'mem_capacity': QuantityKind('mem_capacity', '内存容量', [
    UnitDef('GiB', 'GB', aliases: ['G', 'GiB', 'GB']),
    UnitDef('MiB', 'MB', aliases: ['M', 'MiB', 'MB'], div: _gb),
    UnitDef('TiB', 'TB', aliases: ['T', 'TiB', 'TB'], mul: _gb),
  ]),
  'disk_capacity': QuantityKind('disk_capacity', '存储容量', [
    UnitDef('GB', 'GB', aliases: ['G']),
    UnitDef('MB', 'MB', aliases: ['M'], div: 1000),
    UnitDef('TB', 'TB', aliases: ['T'], mul: 1000),
    UnitDef('PB', 'PB', aliases: ['P'], mul: 1000000),
  ]),
  'data_rate': QuantityKind('data_rate', '数据速率', [
    UnitDef('bit/s', 'bit/s', aliases: ['bps', 'b/s', '波特', 'baud']),
    UnitDef(
      'kbit/s',
      'kbit/s',
      aliases: ['kbps', 'Kbps', 'kb/s', 'k'],
      mul: 1000,
    ),
    UnitDef(
      'Mbit/s',
      'Mbit/s',
      aliases: ['Mbps', 'Mb/s', 'M', '兆'],
      mul: 1000000,
    ),
    UnitDef(
      'Gbit/s',
      'Gbit/s',
      aliases: ['Gbps', 'Gb/s', 'G', '千兆'],
      mul: 1000000000,
    ),
  ]),
  // Memory speed: MT/s, commonly written MHz.
  'transfer_rate': QuantityKind('transfer_rate', '传输速率', [
    UnitDef('MT/s', 'MT/s', aliases: ['MHz', 'M', 'MTS']),
  ]),
  'length': QuantityKind('length', '长度', [
    UnitDef('m', 'm', aliases: ['米']),
    UnitDef('mm', 'mm', aliases: ['毫米'], div: 1000),
    UnitDef('cm', 'cm', aliases: ['厘米'], div: 100),
    UnitDef('km', 'km', aliases: ['千米', '公里'], mul: 1000),
  ]),
  'cross_section': QuantityKind('cross_section', '截面积', [
    UnitDef('mm2', 'mm²', aliases: ['mm²', '平方毫米', '平方', 'mm^2']),
  ]),
  'voltage': QuantityKind('voltage', '电压', [
    UnitDef('V', 'V', aliases: ['伏', 'VAC', 'VDC']),
    UnitDef('mV', 'mV', aliases: ['毫伏'], div: 1000),
    UnitDef('kV', 'kV', aliases: ['千伏'], mul: 1000),
  ]),
  'current': QuantityKind('current', '电流', [
    UnitDef('A', 'A', aliases: ['安']),
    UnitDef('mA', 'mA', aliases: ['毫安'], div: 1000),
  ]),
  'power': QuantityKind('power', '功率', [
    UnitDef('W', 'W', aliases: ['瓦']),
    UnitDef('kW', 'kW', aliases: ['千瓦'], mul: 1000),
  ]),
  'time': QuantityKind('time', '时间', [
    UnitDef('s', 's', aliases: ['秒', 'S', 'sec']),
    UnitDef('ms', 'ms', aliases: ['毫秒'], div: 1000),
    UnitDef('min', 'min', aliases: ['分钟', '分'], mul: 60),
    UnitDef('h', 'h', aliases: ['小时', '时'], mul: 3600),
  ]),
  'sound_level': QuantityKind('sound_level', '声压级', [
    UnitDef('dB(A)', 'dB(A)', aliases: ['dB', 'dBA', '分贝']),
  ]),
  // ppm and %VOL are both volume fractions; %LEL depends on the gas and
  // mg/m³ on molar mass and conditions, so neither converts to ppm.
  'gas_concentration': QuantityKind('gas_concentration', '气体浓度', [
    UnitDef('ppm', 'ppm', aliases: ['PPM', '百万分之']),
    UnitDef('ppb', 'ppb', aliases: ['PPB'], div: 1000),
    UnitDef(
      '%VOL',
      '%VOL',
      aliases: ['%vol', 'VOL%', '%V/V', '%O2', '%'],
      mul: 10000,
    ),
    UnitDef('%LEL', '%LEL', aliases: ['LEL', 'LEL%', '%lel'], group: 'lel'),
    UnitDef('mg/m3', 'mg/m³', aliases: ['mg/m³', 'mg/立方米'], group: 'mass'),
  ]),
  'display_size': QuantityKind('display_size', '显示尺寸', [
    UnitDef('[in_i]', '英寸', aliases: ['寸', 'inch', 'in', '"', '″']),
  ]),
};

/// Signed decimal text in canonical form ("-20", "2.3"); null when not a
/// number or beyond 12 integer / 6 fraction digits.
String? signedDecimal(String? s) {
  if (s == null) return null;
  final t = s.trim().replaceFirst('+', '');
  final negative = t.startsWith('-');
  final v = tryDecimal(negative ? t.substring(1) : t);
  if (v == null) return null;
  return negative && v != '0' ? '-$v' : v;
}

/// [value] (decimal text) in [unit] expressed in the kind's base unit, in
/// millionths; null when the unit is unknown.
BigInt? toBase(QuantityKind kind, String value, String unit) {
  final u = kind.unit(unit);
  if (u == null) return null;
  return roundedDivide(
    (micros(value) + micros(u.pre)) * BigInt.from(u.mul),
    BigInt.from(u.div),
  );
}

/// Whether two units of [kind] can be compared at all.
bool convertible(QuantityKind kind, String a, String b) {
  final x = kind.unit(a), y = kind.unit(b);
  return x != null && y != null && x.group == y.group;
}
