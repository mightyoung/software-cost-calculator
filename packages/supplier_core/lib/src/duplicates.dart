import 'dart:convert';

import 'package:unorm_dart/unorm_dart.dart' as unicode;

import 'search.dart';
import 'store.dart';

/// How strongly an existing record resembles the one being entered.
/// [same]: after normalizing it is the same record; creating another one
/// needs explicit confirmation. [possible]: worth a look.
enum Similarity { same, possible }

class Duplicate {
  Duplicate(this.hit, this.level);
  final Hit hit;
  final Similarity level;
}

/// Comparison key: NFKC (full-width to half-width), lower case, without
/// whitespace and common punctuation. "CR 10－5" and "cr10-5" both give
/// "cr105".
String normalizeKey(String? s) => unicode
    .nfkc(s ?? '')
    .toLowerCase()
    .replaceAll(RegExp(r'[\s\-_/\\.·・,，、:：;；()（）\[\]【】]'), '');

const _companySuffixes = ['股份有限公司', '有限责任公司', '有限公司', '集团公司', '集团', '公司'];

/// Supplier name key without company-form suffixes:
/// "永泰阀门（集团）股份有限公司" and "永泰阀门" give the same key.
String companyKey(String name) {
  var key = normalizeKey(name);
  var stripped = true;
  while (stripped) {
    stripped = false;
    for (final suffix in _companySuffixes) {
      if (key.endsWith(suffix) && key.length - suffix.length >= 2) {
        key = key.substring(0, key.length - suffix.length);
        stripped = true;
      }
    }
  }
  return key;
}

bool _contains(String a, String b) =>
    a.length >= 2 && b.length >= 2 && (a.contains(b) || b.contains(a));

extension Duplicates on Store {
  /// Live suppliers resembling [name], "same" first.
  // ponytail: scans every live supplier in Dart (fine for thousands); add a
  // stored key column if suppliers ever reach six figures.
  List<Duplicate> similarSuppliers(String name, {String? excludeId}) {
    final key = companyKey(name);
    if (key.isEmpty) return const [];
    final result = <Duplicate>[];
    for (final r in db.select(
      "SELECT id, data FROM supplier WHERE deleted = 0 "
      "AND json_extract(data,'\$.merged_into') IS NULL",
    )) {
      if (r['id'] == excludeId) continue;
      final data = jsonDecode(r['data'] as String) as Map<String, Object?>;
      final keys = [
        companyKey(data['name']! as String),
        for (final a in data['aliases']! as List) companyKey(a as String),
      ];
      final level = keys.contains(key)
          ? Similarity.same
          : keys.any((k) => _contains(k, key))
          ? Similarity.possible
          : null;
      if (level != null) {
        result.add(Duplicate(Hit(r['id'] as String, data, 1), level));
      }
    }
    return result..sort((a, b) => a.level.index.compareTo(b.level.index));
  }

  /// Live products resembling [p] (name, brand, model, specification).
  /// Same model means the same material unless both brands are set and
  /// differ; without a model, name, brand and specification must all agree.
  List<Duplicate> similarProducts(Map<String, Object?> p, {String? excludeId}) {
    final name = normalizeKey(p['name'] as String?);
    final model = normalizeKey(p['model'] as String?);
    final brand = normalizeKey(p['brand'] as String?);
    final spec = normalizeKey(p['specification'] as String?);
    if (name.isEmpty && model.isEmpty) return const [];
    // Coarse SQL prefilter on the raw text; exact rules run on the keys.
    const modelSql =
        "replace(replace(replace(replace(replace(lower(coalesce("
        "json_extract(data,'\$.model'),'')),' ',''),'-',''),'_',''),'/',''),'.','')";
    final raw = (p['name'] as String? ?? '').trim().toLowerCase();
    final result = <Duplicate>[];
    for (final r in db.select(
      "SELECT id, data FROM product WHERE deleted = 0 "
      "AND json_extract(data,'\$.merged_into') IS NULL AND ("
      "(?1 <> '' AND (instr(?1, lower(json_extract(data,'\$.name'))) > 0 "
      "OR instr(lower(json_extract(data,'\$.name')), ?1) > 0)) "
      "OR (?2 <> '' AND $modelSql = ?2))",
      [raw, model],
    )) {
      if (r['id'] == excludeId) continue;
      final data = jsonDecode(r['data'] as String) as Map<String, Object?>;
      final hisModel = normalizeKey(data['model'] as String?);
      final hisBrand = normalizeKey(data['brand'] as String?);
      final brandsClash =
          brand.isNotEmpty && hisBrand.isNotEmpty && brand != hisBrand;
      final Similarity? level;
      if (model.isNotEmpty && model == hisModel) {
        level = brandsClash ? Similarity.possible : Similarity.same;
      } else if (model.isEmpty &&
          hisModel.isEmpty &&
          name == normalizeKey(data['name'] as String?) &&
          brand == hisBrand &&
          spec == normalizeKey(data['specification'] as String?)) {
        level = Similarity.same;
      } else if (!brandsClash &&
          _contains(name, normalizeKey(data['name'] as String?))) {
        level = Similarity.possible;
      } else {
        level = null;
      }
      if (level != null) {
        result.add(Duplicate(Hit(r['id'] as String, data, 1), level));
      }
    }
    return result..sort((a, b) => a.level.index.compareTo(b.level.index));
  }
}
