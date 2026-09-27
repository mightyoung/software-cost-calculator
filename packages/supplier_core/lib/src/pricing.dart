final _micro = BigInt.from(1000000);

/// Decimal text (<= 6 fraction digits) to integer millionths.
BigInt micros(String decimal) {
  final negative = decimal.startsWith('-');
  final parts = (negative ? decimal.substring(1) : decimal).split('.');
  final fraction = (parts.length > 1 ? parts[1] : '').padRight(6, '0');
  final value = BigInt.parse(parts[0]) * _micro + BigInt.parse(fraction);
  return negative ? -value : value;
}

String fromMicros(BigInt value) {
  final sign = value.isNegative ? '-' : '';
  final abs = value.abs();
  final fraction = (abs % _micro)
      .toString()
      .padLeft(6, '0')
      .replaceFirst(RegExp(r'0+$'), '');
  return '$sign${abs ~/ _micro}${fraction.isEmpty ? '' : '.$fraction'}';
}

/// Exact division rounded to nearest integer, ties away from zero.
BigInt roundedDivide(BigInt numerator, BigInt denominator) {
  final value =
      (numerator.abs() * BigInt.two + denominator) ~/
      (denominator * BigInt.two);
  return numerator.isNegative ? -value : value;
}

BigInt multiply(BigInt a, BigInt b) => roundedDivide(a * b, _micro);

/// Number of base units per unit, in millionths. Unknown units stay separate.
BigInt? unitFactor(Map<String, Object?> product, String unit) {
  if (unit == product['unit']) return _micro;
  final factors = product['unit_conversions'] as Map?;
  final factor = factors?[unit] as String?;
  return factor == null ? null : micros(factor);
}

String? priceInUnit(
  Map<String, Object?> quote, {
  required Map<String, Object?> product,
  required String unit,
  required String currency,
  required String taxMode,
}) {
  final sourceUnit = quote['unit_snapshot'];
  final source = sourceUnit == unit
      ? _micro
      : unitFactor(product, sourceUnit! as String);
  final target = sourceUnit == unit ? _micro : unitFactor(product, unit);
  if (source == null || target == null) return null;
  return _convertedPrice(
    quote,
    currency: currency,
    taxMode: taxMode,
    numerator: target,
    denominator: source,
  );
}

bool meetsMinimumQuantity(
  Map<String, Object?> quote,
  Map<String, Object?> product,
  String unit,
  BigInt quantity,
) {
  if (quote['unit_snapshot'] == unit)
    return quantity >= micros(quote['min_qty']! as String);
  final source = unitFactor(product, quote['unit_snapshot']! as String);
  final target = unitFactor(product, unit);
  return source != null &&
      target != null &&
      quantity * target >= micros(quote['min_qty']! as String) * source;
}

/// Normalize a source price without modifying its quotation. A missing tax
/// rate is acceptable only when no conversion is needed; FX is unsupported.
String? priceInTaxMode(
  Map<String, Object?> quote, {
  required String currency,
  required String taxMode,
}) {
  return _convertedPrice(
    quote,
    currency: currency,
    taxMode: taxMode,
    numerator: BigInt.one,
    denominator: BigInt.one,
  );
}

String? _convertedPrice(
  Map<String, Object?> quote, {
  required String currency,
  required String taxMode,
  required BigInt numerator,
  required BigInt denominator,
}) {
  final sourceMode = quote['tax_mode'];
  if (quote['currency'] != currency ||
      !const ['included', 'excluded'].contains(taxMode) ||
      !const ['included', 'excluded'].contains(sourceMode))
    return null;
  final price = (quote['deal_price'] ?? quote['price'])! as String;
  if (sourceMode == taxMode)
    return fromMicros(roundedDivide(micros(price) * numerator, denominator));
  final rate = quote['tax_rate'] as String?;
  if (rate == null) return null;
  final hundred = BigInt.from(100) * _micro;
  final factor = hundred + micros(rate);
  return fromMicros(
    sourceMode == 'excluded'
        ? roundedDivide(
            micros(price) * factor * numerator,
            hundred * denominator,
          )
        : roundedDivide(
            micros(price) * hundred * numerator,
            factor * denominator,
          ),
  );
}
