import 'dart:convert';

import 'duplicates.dart';
import 'product_params.dart';
import 'spec_dictionary.dart';
import 'spec_values.dart';
import 'store.dart';

/// The class whose name or synonym appears in [texts] (material name first,
/// then category), preferring the longest match: "温湿度变送器" →
/// sensor.th, "工控机" → computer.ipc. Null when nothing fits.
String? guessSpecClass(List<String?> texts) {
  for (final text in texts) {
    if (text == null) continue;
    final hay = normalizeKey(text);
    (String, int)? best;
    for (final c in specClasses) {
      for (final a in [c.label, ...c.aliases]) {
        final k = normalizeKey(a);
        if (k.isNotEmpty &&
            hay.contains(k) &&
            (best == null || k.length > best.$2)) {
          best = (c.code, k.length);
        }
      }
    }
    if (best != null) return best.$1;
  }
  return null;
}

/// The class parameter a free-form attribute name refers to ("温度范围" →
/// th.temp_range); exact names win over partial ones.
SpecProperty? propertyForName(String classCode, String name) {
  final key = normalizeKey(name);
  if (key.isEmpty) return null;
  final props = [
    for (final cp in classParams(classCode)) ?specProperty(cp.property),
  ];
  for (final p in props) {
    if ([p.label, ...p.aliases].any((a) => normalizeKey(a) == key)) return p;
  }
  for (final p in props) {
    if ([p.label, ...p.aliases].any((a) {
      final k = normalizeKey(a);
      return k.length >= 2 && (key.contains(k) || k.contains(key));
    })) {
      return p;
    }
  }
  return null;
}

/// What converting one material's free attributes would do. Writes nothing.
class ParamMigration {
  ParamMigration(
    this.productId,
    this.name,
    this.classCode, {
    required this.newClass,
    required this.params,
    required this.kept,
  });
  final String productId, name, classCode;

  /// The class is a guess to be set on the material.
  final bool newClass;

  /// Attribute name, its text, the property and the parsed value.
  final List<
    ({
      String attribute,
      String text,
      SpecProperty property,
      Map<String, Object?> value,
    })
  >
  params;

  /// Attributes that stay free-form (no matching parameter or unreadable).
  final List<String> kept;
}

extension SpecMigration on Store {
  /// Plans typed parameters for materials that have free attributes: the
  /// class is kept or guessed from the name and category; attributes that
  /// name a class parameter and parse become parameters.
  List<ParamMigration> planAttributeMigration() {
    final plans = <ParamMigration>[];
    for (final r in db.select(
      'SELECT id, data FROM product WHERE deleted = 0 '
      "AND json_extract(data,'\$.merged_into') IS NULL "
      "AND json_extract(data,'\$.attributes') IS NOT NULL ORDER BY rowid",
    )) {
      final id = r['id'] as String;
      final d = jsonDecode(r['data'] as String) as Map<String, Object?>;
      final existing = d['spec_class'] as String?;
      final cls =
          existing ??
          guessSpecClass([d['name'] as String?, d['category'] as String?]);
      if (cls == null || specClass(cls) == null) continue;
      final have = paramsOf(id).keys.toSet();
      final params =
          <
            ({
              String attribute,
              String text,
              SpecProperty property,
              Map<String, Object?> value,
            })
          >[];
      final kept = <String>[];
      for (final MapEntry(:key, :value) in (d['attributes']! as Map).entries) {
        final prop = propertyForName(cls, key as String);
        final parsed = prop == null ? null : parseParamText(prop, '$value');
        Map<String, Object?>? valid;
        try {
          valid = prop == null || parsed == null
              ? null
              : normalizeParamValue(prop, parsed);
        } on FormatException {
          valid = null;
        }
        if (prop == null ||
            valid == null ||
            have.contains(prop.code) ||
            params.any((p) => p.property.code == prop.code)) {
          kept.add(key);
        } else {
          params.add((
            attribute: key,
            text: '$value',
            property: prop,
            value: valid,
          ));
        }
      }
      if (params.isEmpty && existing != null) continue;
      plans.add(
        ParamMigration(
          id,
          d['name']! as String,
          cls,
          newClass: existing == null,
          params: params,
          kept: kept,
        ),
      );
    }
    return plans;
  }

  /// Applies [plans] in one transaction: sets guessed classes, writes the
  /// parameters as unconfirmed imports (the original text as evidence) and
  /// removes the converted attributes. Returns how many parameters.
  int applyAttributeMigration(List<ParamMigration> plans) => transaction(() {
    var n = 0;
    for (final plan in plans) {
      final product = get('product', plan.productId);
      if (product == null || product.deleted) continue;
      final converted = {for (final p in plan.params) p.attribute};
      final attrs = {
        for (final MapEntry(:key, :value)
            in ((product.data['attributes'] as Map?) ?? const {}).entries)
          if (!converted.contains(key)) key: value,
      };
      save('product', {
        ...product.data,
        if (plan.newClass) 'spec_class': plan.classCode,
        'attributes': attrs.isEmpty ? null : attrs,
      }, id: plan.productId);
      for (final p in plan.params) {
        setParam(
          plan.productId,
          p.property.code,
          p.value,
          source: 'import',
          confirmed: false,
          evidence: '关键属性 ${p.attribute}：${p.text}',
        );
        n++;
      }
    }
    return n;
  });
}
