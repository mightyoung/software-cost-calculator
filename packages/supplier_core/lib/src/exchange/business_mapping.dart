import '../domain/revision.dart';
import '../domain/values.dart';

enum BusinessCellKind { blank, text, number, boolean, error, date }

/// Values supplied by the bounded XLSX reader, before any numeric conversion.
/// Formula presence is independent of a cached value's type (including text).
final class RawBusinessCell {
  RawBusinessCell({
    required this.coordinate,
    required this.kind,
    required this.lexical,
    this.formula,
  }) {
    if (lexical.length > 32767) {
      invalid(coordinate, 'cell exceeds UTF-16 limit');
    }
    // Validate before blank detection so trim cannot erase illegal XML controls.
    normalizeText(lexical, coordinate, 32767);
    if (kind == BusinessCellKind.blank && lexical.isNotEmpty) {
      invalid(coordinate, 'blank cell unexpectedly contains a value');
    }
  }
  final String coordinate;
  final BusinessCellKind kind;
  final String lexical;
  final String? formula;

  void _literal() {
    if (formula != null) {
      invalid(coordinate, 'convert formula to a literal value');
    }
    if (kind == BusinessCellKind.boolean ||
        kind == BusinessCellKind.error ||
        kind == BusinessCellKind.date) {
      invalid(coordinate, 'cell type needs an explicit supported conversion');
    }
  }

  SourcePresence get sourcePresence {
    _literal();
    return kind == BusinessCellKind.blank ||
            (kind == BusinessCellKind.text && lexical.trim().isEmpty)
        ? SourcePresence.blank
        : SourcePresence.value;
  }

  String? text({int limit = 32767}) {
    _literal();
    if (sourcePresence == SourcePresence.blank) return null;
    if (kind != BusinessCellKind.text) {
      invalid(
        coordinate,
        'text required; numeric identifiers cannot be repaired',
      );
    }
    return normalizeText(lexical, coordinate, limit);
  }

  String? decimal({bool positive = false}) {
    _literal();
    if (sourcePresence == SourcePresence.blank) return null;
    final expanded = kind == BusinessCellKind.number
        ? _expandNumber(lexical, coordinate)
        : lexical.trim();
    try {
      return ExactDecimal.parse(expanded, positive: positive).canonical;
    } on FormatException catch (error) {
      invalid(coordinate, error.message.toString());
    }
  }

  /// Mapping explicitly chooses date or instant. Integer serials do not infer
  /// midnight. Any sub-millisecond rounding is returned for conversion preview.
  ExcelDateConversion excelDate({
    bool date1904 = false,
    bool instant = false,
    int? offsetMinutes,
  }) {
    _literal();
    if (kind != BusinessCellKind.number) {
      invalid(coordinate, 'Excel serial conversion requires a numeric cell');
    }
    final expanded = _expandNumber(lexical, coordinate);
    final parts = expanded.split('.');
    final day = int.tryParse(parts.first);
    if (day == null ||
        day < (date1904 ? 0 : 1) ||
        day > 2958465 ||
        (!date1904 && day == 60)) {
      invalid(coordinate, 'unsupported Excel date or fictional 1900-02-29');
    }
    final fraction = parts.length == 1 ? '' : parts.last;
    final numerator = fraction.isEmpty ? BigInt.zero : BigInt.parse(fraction);
    final denominator = BigInt.from(10).pow(fraction.length);
    if (!instant && numerator != BigInt.zero) {
      invalid(coordinate, 'date-only mapping cannot discard a time fraction');
    }
    final base = date1904 ? DateTime.utc(1904) : DateTime.utc(1899, 12, 31);
    final date = base.add(
      Duration(days: day - (!date1904 && day > 60 ? 1 : 0)),
    );
    if (date.year > 9999) invalid(coordinate, 'date exceeds year 9999');
    final dateText = date.toIso8601String().substring(0, 10);
    if (!instant) {
      return ExcelDateConversion(InquiryTime.parseInput(dateText), false);
    }
    if (offsetMinutes == null || offsetMinutes < -840 || offsetMinutes > 840) {
      invalid(coordinate, 'instant requires an explicit batch UTC offset');
    }
    final scaled = numerator * BigInt.from(86400000);
    final milliseconds =
        ((scaled * BigInt.two + denominator) ~/ (denominator * BigInt.two))
            .toInt();
    if (milliseconds >= 86400000) {
      invalid(coordinate, 'millisecond rounding crosses date boundary');
    }
    final local = date.add(Duration(milliseconds: milliseconds));
    final offset = offsetMinutes.abs();
    final zone =
        '${offsetMinutes < 0 ? '-' : '+'}'
        '${(offset ~/ 60).toString().padLeft(2, '0')}:'
        '${(offset % 60).toString().padLeft(2, '0')}';
    try {
      return ExcelDateConversion(
        InquiryTime.parseInput(
          '${local.toIso8601String().replaceFirst('Z', '')}$zone',
        ),
        scaled.remainder(denominator) != BigInt.zero,
      );
    } on FormatException catch (error) {
      invalid(coordinate, error.message.toString());
    }
  }
}

final class ExcelDateConversion {
  const ExcelDateConversion(this.time, this.millisecondsRounded);
  final InquiryTime time;
  final bool millisecondsRounded;
}

/// A missing mapped column is not an empty cell; normalization never erases the
/// incoming presence state used by the source fingerprint.
SourceCell businessSourceCell(
  RawBusinessCell? cell,
  Object? Function(RawBusinessCell cell) convert,
) {
  if (cell == null) return const SourceCell.missing();
  if (cell.sourcePresence == SourcePresence.blank) {
    return const SourceCell.blank();
  }
  final value = convert(cell);
  if (value == null) {
    invalid(cell.coordinate, 'nonblank source normalized to null');
  }
  return SourceCell.value(value);
}

String _expandNumber(String lexical, String coordinate) {
  // A bounded lexeme/exponent prevents hostile scientific notation from
  // allocating a giant decimal string. No business value passes through double.
  if (lexical.length > 128) invalid(coordinate, 'numeric lexeme exceeds limit');
  final match = RegExp(
    r'^\+?(\d+(?:\.\d*)?|\.\d+)(?:[eE]([+-]?\d{1,3}))?$',
  ).firstMatch(lexical);
  if (match == null) invalid(coordinate, 'invalid unsigned numeric lexeme');
  final mantissa = match[1]!;
  final exponent = int.parse(match[2] ?? '0');
  final dot = mantissa.indexOf('.');
  final digits = mantissa.replaceAll('.', '');
  final point = (dot == -1 ? mantissa.length : dot) + exponent;
  if (exponent != 0 && !digits.contains(RegExp('[1-9]'))) return '0';
  if (point.abs() > 128) invalid(coordinate, 'numeric magnitude exceeds limit');
  if (point <= 0) return '0.${'0' * -point}$digits';
  if (point >= digits.length) return digits + '0' * (point - digits.length);
  return '${digits.substring(0, point)}.${digits.substring(point)}';
}
