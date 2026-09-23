import 'package:unorm_dart/unorm_dart.dart' as unicode;

Never invalid(String field, String reason) =>
    throw FormatException('$field: $reason');

void exactKeys(Map<String, Object?> value, Iterable<String> keys) {
  final expected = keys.toSet();
  if (value.length != expected.length || !expected.containsAll(value.keys)) {
    invalid('payload', 'missing or unknown keys');
  }
}

/// Dart JavaScript represents ints and doubles with the same Number type.
/// Accept integer values, not runtime numeric subtype differences.
int requireSafeInteger(
  Object? value,
  String field, {
  int min = -9007199254740991,
  int max = 9007199254740991,
}) {
  if (value is! num ||
      !value.isFinite ||
      value < -9007199254740991 ||
      value > 9007199254740991 ||
      value < min ||
      value > max ||
      value != value.truncateToDouble()) {
    invalid(field, 'expected finite safe integer from $min to $max');
  }
  return value.toInt();
}

String requireUuid(Object? value, String field) {
  if (value is! String ||
      !RegExp(
        r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
      ).hasMatch(value)) {
    invalid(field, 'expected lowercase UUID v4');
  }
  return value;
}

String? normalizeText(
  Object? value,
  String field,
  int limit, {
  bool required = false,
}) {
  if (value == null && !required) return null;
  if (value is! String) invalid(field, 'expected text');
  // Check before trimming so forbidden control characters cannot disappear.
  for (final point in value.runes) {
    if (!(point == 9 ||
        point == 10 ||
        point == 13 ||
        (point >= 0x20 && point <= 0xd7ff) ||
        (point >= 0xe000 && point <= 0xfffd) ||
        (point >= 0x10000 && point <= 0x10ffff))) {
      invalid(field, 'invalid XML character or isolated surrogate');
    }
  }
  final result = unicode.nfc(value.trim());
  if (result.isEmpty) {
    if (required) invalid(field, 'required');
    return null;
  }
  if (result.runes.length > limit) invalid(field, 'exceeds $limit codepoints');
  return result;
}

int compareCodepoints(String a, String b) {
  final left = a.runes.iterator;
  final right = b.runes.iterator;
  while (left.moveNext()) {
    if (!right.moveNext()) return 1;
    final order = left.current.compareTo(right.current);
    if (order != 0) return order;
  }
  return right.moveNext() ? -1 : 0;
}

List<String> normalizeTextList(
  Object? value,
  String field,
  int count,
  int limit,
) {
  if (value is! List) invalid(field, 'expected array');
  if (value.length > count) invalid(field, 'too many items');
  final result =
      value
          .map((item) => normalizeText(item, field, limit, required: true)!)
          .toSet()
          .toList()
        ..sort(compareCodepoints);
  return List.unmodifiable(result);
}

final class ExactDecimal implements Comparable<ExactDecimal> {
  ExactDecimal._(
    this.canonical,
    this._integer,
    this._fraction,
    this.maxIntegerDigits,
    this.maxFractionDigits,
  );
  factory ExactDecimal.parse(
    String value, {
    bool positive = false,
    int maxIntegerDigits = 12,
    int maxFractionDigits = 6,
  }) {
    if (!RegExp(r'^[0-9]+(?:\.[0-9]+)?$').hasMatch(value)) {
      invalid('decimal', 'expected unsigned decimal text');
    }
    final parts = value.split('.');
    final integer = parts.first.replaceFirst(RegExp(r'^0+(?=\d)'), '');
    final fraction = parts.length == 2 ? parts.last : '';
    if (integer.length > maxIntegerDigits ||
        fraction.length > maxFractionDigits) {
      invalid('decimal', 'precision exceeded');
    }
    final trimmed = fraction.replaceFirst(RegExp(r'0+$'), '');
    if (positive && integer == '0' && trimmed.isEmpty) {
      invalid('decimal', 'must be positive');
    }
    return ExactDecimal._(
      trimmed.isEmpty ? integer : '$integer.$trimmed',
      integer,
      trimmed,
      maxIntegerDigits,
      maxFractionDigits,
    );
  }
  final String canonical;
  final String _integer;
  final String _fraction;
  final int maxIntegerDigits;
  final int maxFractionDigits;
  String get sortKey =>
      _integer.padLeft(maxIntegerDigits, '0') +
      _fraction.padRight(maxFractionDigits, '0');
  @override
  int compareTo(ExactDecimal other) {
    final length = _integer.length.compareTo(other._integer.length);
    if (length != 0) return length;
    final integer = _integer.compareTo(other._integer);
    if (integer != 0) return integer;
    final width = _fraction.length > other._fraction.length
        ? _fraction.length
        : other._fraction.length;
    return _fraction
        .padRight(width, '0')
        .compareTo(other._fraction.padRight(width, '0'));
  }
}

String requireDate(Object? value, String field) {
  if (value is! String || !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value)) {
    invalid(field, 'expected YYYY-MM-DD');
  }
  final y = int.parse(value.substring(0, 4));
  final m = int.parse(value.substring(5, 7));
  final d = int.parse(value.substring(8, 10));
  final date = DateTime.utc(y, m, d);
  if (y < 1 || date.year != y || date.month != m || date.day != d) {
    invalid(field, 'invalid calendar date');
  }
  return value;
}

String normalizeInstant(String value) =>
    InquiryTime.parseInput(value)._instantRequired;

final class InquiryTime {
  InquiryTime._(this.precision, this.date, this.instant, this.offsetMinutes);
  factory InquiryTime.parseInput(String input) {
    if (RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(input)) {
      return InquiryTime._(
        'date',
        requireDate(input, 'inquiry_date'),
        null,
        null,
      );
    }
    final match = RegExp(
      r'^(\d{4}-\d{2}-\d{2})T(\d{2}):(\d{2})(?::(\d{2})(?:\.(\d{1,3}))?)?(Z|[+-]\d{2}:\d{2})$',
    ).firstMatch(input);
    if (match == null) {
      invalid(
        'inquired_at',
        'expected explicit timezone and at most milliseconds',
      );
    }
    final date = requireDate(match[1], 'inquired_at');
    final hour = int.parse(match[2]!);
    final minute = int.parse(match[3]!);
    final second = int.parse(match[4] ?? '0');
    if (hour > 23 || minute > 59 || second > 59) {
      invalid('inquired_at', 'invalid time');
    }
    final zone = match[6]!;
    var offset = 0;
    if (zone != 'Z') {
      final hours = int.parse(zone.substring(1, 3));
      final minutes = int.parse(zone.substring(4));
      if (minutes > 59 || hours > 14 || (hours == 14 && minutes != 0)) {
        invalid('inquired_at', 'invalid offset');
      }
      offset = (hours * 60 + minutes) * (zone[0] == '-' ? -1 : 1);
    }
    final local = DateTime.utc(
      int.parse(date.substring(0, 4)),
      int.parse(date.substring(5, 7)),
      int.parse(date.substring(8)),
      hour,
      minute,
      second,
      int.parse((match[5] ?? '').padRight(3, '0')),
    );
    final utc = local.subtract(Duration(minutes: offset));
    if (utc.year < 1 || utc.year > 9999) {
      invalid('inquired_at', 'UTC year out of range');
    }
    return InquiryTime._('instant', date, utc.toIso8601String(), offset);
  }
  factory InquiryTime.fromJson(
    Map<String, Object?> value, {
    required bool historical,
  }) {
    final precision = value['inquiry_precision'];
    final date = value['inquiry_date'];
    final instant = value['inquired_at'];
    final offset = value['inquiry_utc_offset_minutes'];
    if (precision == 'unknown' &&
        historical &&
        date == null &&
        instant == null &&
        offset == null) {
      return InquiryTime._('unknown', null, null, null);
    }
    if (precision == 'date' && instant == null && offset == null) {
      return InquiryTime._(
        'date',
        requireDate(date, 'inquiry_date'),
        null,
        null,
      );
    }
    if (precision == 'instant' && instant is String) {
      final offsetValue = requireSafeInteger(
        offset,
        'inquiry_utc_offset_minutes',
        min: -840,
        max: 840,
      );
      final normalized = normalizeInstant(instant);
      if (normalized != instant) {
        invalid('inquired_at', 'payload requires canonical UTC milliseconds');
      }
      final local = DateTime.parse(
        normalized,
      ).add(Duration(minutes: offsetValue));
      if (local.year < 1 || local.year > 9999) {
        invalid('inquiry_date', 'local year out of range');
      }
      if (requireDate(date, 'inquiry_date') !=
          local.toIso8601String().substring(0, 10)) {
        invalid('inquiry_date', 'does not match instant and offset');
      }
      return InquiryTime._('instant', date as String, normalized, offsetValue);
    }
    invalid('inquiry_precision', 'invalid precision or incompatible fields');
  }
  final String precision;
  final String? date;
  final String? instant;
  final int? offsetMinutes;
  String get _instantRequired =>
      instant ?? invalid('inquired_at', 'instant required');
  Map<String, Object?> toJson() => Map.unmodifiable({
    'inquiry_precision': precision,
    'inquiry_date': date,
    'inquired_at': instant,
    'inquiry_utc_offset_minutes': offsetMinutes,
  });
}
