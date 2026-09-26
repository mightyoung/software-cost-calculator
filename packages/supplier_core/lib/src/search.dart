import 'dart:convert';

import 'package:unorm_dart/unorm_dart.dart' as unicode;

import 'store.dart';

/// Weight of a keyword hit per product field; model numbers are the most
/// specific evidence, free-text specification the least.
const _productFields = {
  'model': 3,
  'name': 2,
  'brand': 2,
  'specification': 1,
  'category': 1,
};

String _key(String s) => unicode.nfkc(s).toLowerCase().trim();

String _like(String s) =>
    '%${s.replaceAll(r'\', r'\\').replaceAll('%', r'\%').replaceAll('_', r'\_')}%';

class Hit {
  Hit(this.id, this.data, this.score);
  final String id;
  final Map<String, Object?> data;
  final int score;
}

extension Search on Store {
  /// Products ranked by weighted keyword hits. Substring matching works for
  /// Chinese names without a word segmenter.
  // ponytail: LIKE scan over all products (~10 ms at 20k); add FTS5 trigram
  // index if the catalogue grows past ~200k products.
  List<Hit> searchProducts(List<String> keywords, {int limit = 8}) {
    final terms = {
      for (final k in keywords)
        if (_key(k).isNotEmpty) _key(k),
    }.take(10);
    final scores = <String, int>{};
    final data = <String, Map<String, Object?>>{};
    for (final term in terms) {
      for (final MapEntry(key: field, value: weight)
          in _productFields.entries) {
        for (final r in db.select(
          "SELECT id, data FROM product WHERE deleted = 0 AND "
          "json_extract(data,'\$.merged_into') IS NULL AND "
          "lower(json_extract(data,'\$.$field')) LIKE ? ESCAPE '\\'",
          [_like(term)],
        )) {
          final id = r['id'] as String;
          scores[id] = (scores[id] ?? 0) + weight;
          data[id] ??= jsonDecode(r['data'] as String) as Map<String, Object?>;
        }
      }
    }
    final hits = [
      for (final e in scores.entries) Hit(e.key, data[e.key]!, e.value),
    ]..sort((a, b) => b.score.compareTo(a.score));
    return hits.take(limit).toList();
  }

  /// Name/alias substring search for suppliers, or name/code for projects.
  List<Hit> searchByName(String type, String keyword, {int limit = 20}) {
    final key = _like(_key(keyword));
    return [
      for (final r in db.select(
        "SELECT id, data FROM $type WHERE deleted = 0 "
        "AND json_extract(data,'\$.merged_into') IS NULL AND ("
        "lower(json_extract(data,'\$.name')) LIKE ?1 ESCAPE '\\' OR "
        "lower(coalesce(json_extract(data,'\$.aliases'),'')) LIKE ?1 ESCAPE '\\' OR "
        "lower(coalesce(json_extract(data,'\$.code'),'')) LIKE ?1 ESCAPE '\\') "
        'ORDER BY rowid DESC LIMIT ?2',
        [key, limit],
      ))
        Hit(
          r['id'] as String,
          jsonDecode(r['data'] as String) as Map<String, Object?>,
          1,
        ),
    ];
  }

  /// Quotations filtered by any of product, supplier or project, newest first.
  List<Hit> listQuotations({
    String? productId,
    String? supplierId,
    String? projectId,
    int limit = 50,
  }) {
    final where = <String>['deleted = 0'];
    final args = <Object?>[];
    for (final (field, value) in [
      ('product_id', productId),
      ('supplier_id', supplierId),
      ('project_id', projectId),
    ]) {
      if (value == null) continue;
      where.add("json_extract(data,'\$.$field') = ?");
      args.add(value);
    }
    return [
      for (final r in db.select(
        'SELECT id, data FROM quotation WHERE ${where.join(' AND ')} '
        "ORDER BY json_extract(data,'\$.quoted_on') DESC, rowid DESC LIMIT ?",
        [...args, limit],
      ))
        Hit(
          r['id'] as String,
          jsonDecode(r['data'] as String) as Map<String, Object?>,
          1,
        ),
    ];
  }

  /// Active contacts of one supplier, by name.
  List<Hit> contactsOf(String supplierId) => [
    for (final r in db.select(
      "SELECT id, data FROM contact WHERE deleted = 0 AND "
      "json_extract(data,'\$.supplier_id') = ? "
      "ORDER BY json_extract(data,'\$.name')",
      [supplierId],
    ))
      Hit(
        r['id'] as String,
        jsonDecode(r['data'] as String) as Map<String, Object?>,
        1,
      ),
  ];
}
