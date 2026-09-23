/// Exact decimal text to display text: thousands separators, 2 to 6
/// fraction digits, never through a double.
String money(String? decimal, {String prefix = ''}) {
  if (decimal == null) return '—';
  final negative = decimal.startsWith('-');
  final parts = (negative ? decimal.substring(1) : decimal).split('.');
  final grouped = parts.first.replaceAllMapped(
    RegExp(r'\B(?=(\d{3})+(?!\d))'),
    (_) => ',',
  );
  final fraction = (parts.length > 1 ? parts[1] : '').padRight(2, '0');
  return '${negative ? '-' : ''}$prefix$grouped.$fraction';
}

/// Quantities keep their exact digits but lose the forced ".00".
String qty(String decimal) {
  final parts = decimal.split('.');
  final grouped = parts.first.replaceAllMapped(
    RegExp(r'\B(?=(\d{3})+(?!\d))'),
    (_) => ',',
  );
  return parts.length > 1 ? '$grouped.${parts[1]}' : grouped;
}

/// Whole-yuan summary figure for ledger strips (rounded half-up).
String yuan(String decimal) {
  final negative = decimal.startsWith('-');
  final parts = (negative ? decimal.substring(1) : decimal).split('.');
  var whole = BigInt.parse(parts.first);
  if (parts.length > 1 && int.parse(parts[1][0]) >= 5) whole += BigInt.one;
  return money('${negative ? '-' : ''}$whole', prefix: '¥').split('.').first;
}

/// Percentage with one decimal from two exact decimals; null when base is 0.
String? percent(String part, String whole) {
  BigInt micros(String d) {
    final negative = d.startsWith('-');
    final p = (negative ? d.substring(1) : d).split('.');
    final v =
        BigInt.parse(p.first) * BigInt.from(1000000) +
        BigInt.parse((p.length > 1 ? p[1] : '').padRight(6, '0'));
    return negative ? -v : v;
  }

  final base = micros(whole);
  if (base == BigInt.zero) return null;
  final tenths =
      (micros(part) * BigInt.from(1000) + base ~/ BigInt.two) ~/ base;
  final sign = tenths.isNegative ? '-' : '';
  final abs = tenths.abs();
  return '$sign${abs ~/ BigInt.from(10)}.${abs % BigInt.from(10)}%';
}

const statusLabels = {
  'planning': '策划中',
  'active': '进行中',
  'done': '已完成',
  'cancelled': '已取消',
};
