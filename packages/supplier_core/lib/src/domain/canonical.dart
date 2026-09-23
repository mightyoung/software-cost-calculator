import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// RFC 8785 encoding for the persisted domain: null, bool, valid Unicode,
/// arrays, string-keyed objects, and integral numbers in the JavaScript safe range.
/// Decimal business values must be strings. Integral numeric inputs normalize
/// to integer tokens; this also matches Dart JS number representation.
String canonicalJson(Object? value) {
  if (value == null || value is bool) return '$value';
  if (value is num) {
    if (!value.isFinite ||
        value != value.truncateToDouble() ||
        value < -9007199254740991 ||
        value > 9007199254740991) {
      throw const FormatException('Integer outside interoperable safe range');
    }
    return value.toInt().toString();
  }
  if (value is String) {
    for (var i = 0; i < value.length; i++) {
      final unit = value.codeUnitAt(i);
      if (unit >= 0xd800 && unit <= 0xdbff) {
        if (++i >= value.length ||
            value.codeUnitAt(i) < 0xdc00 ||
            value.codeUnitAt(i) > 0xdfff) {
          throw const FormatException('Unpaired UTF-16 surrogate');
        }
      } else if (unit >= 0xdc00 && unit <= 0xdfff) {
        throw const FormatException('Unpaired UTF-16 surrogate');
      }
    }
    return jsonEncode(value);
  }
  if (value is List) return '[${value.map(canonicalJson).join(',')}]';
  if (value is Map) {
    if (value.keys.any((key) => key is! String)) {
      throw const FormatException('JSON object keys must be strings');
    }
    // Dart String comparison is lexicographic UTF-16, as required by JCS.
    final keys = value.keys.cast<String>().toList()..sort();
    return '{${keys.map((key) => '${canonicalJson(key)}:${canonicalJson(value[key])}').join(',')}}';
  }
  throw FormatException(
    'Unsupported canonical JSON value: ${value.runtimeType}',
  );
}

Uint8List canonicalUtf8(Object? value) =>
    Uint8List.fromList(utf8.encode(canonicalJson(value)));
String canonicalSha256(Object? value) =>
    sha256.convert(canonicalUtf8(value)).toString();
