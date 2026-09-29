import 'dart:convert';

import 'package:cryptography/dart.dart';

import 'entities.dart';
import 'quotation.dart';
import 'spec_dictionary.dart';
import 'spec_values.dart';
import 'store.dart';
import 'values.dart';

/// Where a parameter value came from.
const paramSources = ['manual', 'rule', 'ai', 'import', 'decoder'];

final _code = RegExp(r'^(x\.)?[a-z][a-z0-9_]*(\.[a-z0-9_]+)+$');

/// Dictionary code of a property or class, built-in or team-defined ("x.").
String requireSpecCode(Object? value, String field) {
  if (value is! String || value.length > 60 || !_code.hasMatch(value)) {
    invalid(field, 'expected a dictionary code');
  }
  return value;
}

/// One typed parameter value of one material. Stored as its own record so
/// two devices editing different parameters of the same material merge
/// field by field instead of conflicting.
final class ProductParam extends EntityPayload {
  ProductParam._(super.payload);
  static const fields = [
    'product_id',
    'property',
    'value',
    'cond',
    'source',
    'evidence',
    'attachment_id',
    'confirmed',
    'dict_version',
  ];
  factory ProductParam.fromJson(Map<String, Object?> value) {
    exactKeys(value, fields);
    final property = requireSpecCode(value['property'], 'property');
    final spec = specProperty(property);
    final raw = value['value'];
    final Map<String, Object?> normalized;
    if (spec != null) {
      normalized = normalizeParamValue(spec, raw);
    } else {
      // A code this build does not know (newer dictionary, team-defined):
      // kept as it is, so nothing is lost on its way through.
      if (raw is! Map || jsonEncode(raw).length > 2000) {
        invalid('value', 'expected object');
      }
      normalized = raw.cast<String, Object?>();
    }
    final source = value['source'];
    if (!paramSources.contains(source)) invalid('source', 'unknown value');
    if (value['confirmed'] is! bool)
      invalid('confirmed', 'expected true or false');
    return ProductParam._({
      'product_id': requireUuid(value['product_id'], 'product_id'),
      'property': property,
      'value': normalized,
      'cond': normalizeText(value['cond'], 'cond', 200),
      'source': source,
      'evidence': normalizeText(value['evidence'], 'evidence', 500),
      'attachment_id': value['attachment_id'] == null
          ? null
          : requireUuid(value['attachment_id'], 'attachment_id'),
      'confirmed': value['confirmed'],
      'dict_version': requireSafeInteger(
        value['dict_version'],
        'dict_version',
        min: 1,
        max: 9999,
      ),
    });
  }
}

/// The record id of [property] on [productId]: derived, so the same
/// parameter created on two devices is one record after exchange.
String paramRecordId(String productId, String property) =>
    derivedUuid('product_param:$productId:$property');

/// A record id computed from [seed], shaped like a version 4 UUID so every
/// id check accepts it.
String derivedUuid(String seed) {
  final b = const DartSha256().hashSync(utf8.encode(seed)).bytes.sublist(0, 16);
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  final hex = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

/// Counts key parameters from already-loaded property codes. Shared by the
/// individual material view and the catalogue-wide data-quality check.
({int filled, int total}) completenessForParams(
  String? specClass,
  Iterable<String> properties,
) {
  if (specClass == null) return (filled: 0, total: 0);
  final keys = [
    for (final p in classParams(specClass))
      if (p.key) p.property,
  ];
  final have = properties.toSet();
  return (filled: keys.where(have.contains).length, total: keys.length);
}

extension ProductParams on Store {
  /// Live parameters of a material, by property code.
  Map<String, Record> paramsOf(String productId) => {
    for (final r in db.select(
      "SELECT id FROM product_param WHERE deleted = 0 "
      "AND json_extract(data,'\$.product_id') = ?",
      [productId],
    ))
      if (get('product_param', r['id'] as String) case final rec?)
        rec.data['property']! as String: rec,
  };

  /// Sets one parameter (creating, restoring or editing its record).
  String setParam(
    String productId,
    String property,
    Map<String, Object?> value, {
    String source = 'manual',
    bool confirmed = true,
    String? evidence,
    String? cond,
    String? attachmentId,
  }) => transaction(() {
    final id = paramRecordId(productId, property);
    final payload = {
      'product_id': productId,
      'property': property,
      'value': value,
      'cond': cond,
      'source': source,
      'evidence': evidence,
      'attachment_id': attachmentId,
      'confirmed': confirmed,
      'dict_version': specDictionaryVersion,
    };
    final existing = get('product_param', id);
    if (existing == null) return save('product_param', payload, newId: id);
    if (existing.deleted) restore('product_param', id);
    if (jsonEncode(existing.data) ==
        jsonEncode(validatePayload('product_param', payload))) {
      return id;
    }
    return save('product_param', payload, id: id, allowClear: true);
  });

  /// Removes one parameter (soft delete, restorable).
  void clearParam(String productId, String property) {
    final id = paramRecordId(productId, property);
    final existing = get('product_param', id);
    if (existing != null && !existing.deleted) delete('product_param', id);
  }

  /// Marks the given parameters (all when null) as checked by a person.
  int confirmParams(String productId, [Iterable<String>? properties]) =>
      transaction(() {
        var n = 0;
        for (final MapEntry(key: code, value: r) in paramsOf(
          productId,
        ).entries) {
          if (properties != null && !properties.contains(code)) continue;
          if (r.data['confirmed'] == true) continue;
          save('product_param', {...r.data, 'confirmed': true}, id: r.id);
          n++;
        }
        return n;
      });

  /// Key parameters filled for the material's class (ISO 22745 style
  /// completeness); total 0 when the material has no class.
  ({int filled, int total}) paramCompleteness(String productId) {
    final cls = get('product', productId)?.data['spec_class'] as String?;
    if (cls == null) return (filled: 0, total: 0);
    return completenessForParams(cls, paramsOf(productId).keys);
  }
}
