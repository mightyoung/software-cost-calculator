import 'dart:convert';

import 'package:lpinyin/lpinyin.dart';
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
  'attributes': 1,
};

String _key(String s) => unicode.nfkc(s).toLowerCase().trim();

String _like(String s) =>
    '%${s.replaceAll(r'\', r'\\').replaceAll('%', r'\%').replaceAll('_', r'\_')}%';

/// Pinyin initials in lower case, other characters kept: "离心泵" -> "lxb".
String pinyinInitials(String s) =>
    PinyinHelper.getShortPinyin(s).toLowerCase().replaceAll(RegExp(r'\s'), '');

bool _letters(String s) => RegExp(r'^[a-zA-Z]{2,}$').hasMatch(s);

/// Per-store cache: type|id -> (text, initials); recomputed when the text
/// changes, so renames are picked up without invalidation hooks.
final _initialsCache = Expando<Map<String, (String, String)>>();

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
    // NFKC turns "m³" into "m3", so the plain lower-case form is searched too.
    final terms = {
      for (final k in keywords) ...[
        if (_key(k).isNotEmpty) _key(k),
        if (k.trim().isNotEmpty) k.trim().toLowerCase(),
      ],
    }.take(20);
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
    for (final k in keywords) {
      if (!_letters(k.trim())) continue;
      for (final id in _pinyinMatches('product', k.trim().toLowerCase())) {
        scores[id] = (scores[id] ?? 0) + _productFields['name']!;
        data[id] ??= get('product', id)!.data;
      }
    }
    final hits = [
      for (final e in scores.entries) Hit(e.key, data[e.key]!, e.value),
    ]..sort((a, b) => b.score.compareTo(a.score));
    return hits.take(limit).toList();
  }

  /// Ids whose name (or alias) pinyin initials contain [letters].
  // ponytail: scans names each query (fast for tens of thousands with the
  // cache); store initials in a column if catalogues grow far larger.
  List<String> _pinyinMatches(String type, String letters) {
    final cache = _initialsCache[this] ??= {};
    return [
      for (final r in db.select(
        "SELECT id, json_extract(data,'\$.name') AS n, "
        "json_extract(data,'\$.aliases') AS a FROM $type WHERE deleted = 0 "
        "AND json_extract(data,'\$.merged_into') IS NULL",
      ))
        if (() {
          final text = [
            r['n'] as String? ?? '',
            if (r['a'] != null)
              ...(jsonDecode(r['a'] as String) as List).cast<String>(),
          ].join('|');
          final key = '$type|${r['id']}';
          var cached = cache[key];
          if (cached == null || cached.$1 != text) {
            cached = (text, text.split('|').map(pinyinInitials).join('|'));
            cache[key] = cached;
          }
          return cached.$2.contains(letters);
        }())
          r['id'] as String,
    ];
  }

  /// Name/alias substring search for suppliers, or name/code for projects.
  List<Hit> searchByName(String type, String keyword, {int limit = 20}) {
    final key = _like(_key(keyword));
    final byText = _byText(type, key, limit);
    if (!_letters(keyword.trim()) || byText.length >= limit) return byText;
    final seen = {for (final h in byText) h.id};
    return [
      ...byText,
      for (final id in _pinyinMatches(type, keyword.trim().toLowerCase()))
        if (!seen.contains(id)) Hit(id, get(type, id)!.data, 1),
    ].take(limit).toList();
  }

  List<Hit> _byText(String type, String key, int limit) {
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

  /// Categories in use, most common first.
  List<String> productCategories() => [
    for (final r in db.select(
      "SELECT json_extract(data,'\$.category') AS c, count(*) AS n "
      "FROM product WHERE deleted = 0 AND c IS NOT NULL "
      'GROUP BY c ORDER BY n DESC, c',
    ))
      r['c'] as String,
  ];

  /// Attribute names used by materials of [category], most common first:
  /// the suggested key attributes for that category.
  List<String> categoryAttributes(String category) {
    final counts = <String, int>{};
    for (final r in db.select(
      "SELECT json_extract(data,'\$.attributes') AS a FROM product "
      "WHERE deleted = 0 AND json_extract(data,'\$.category') = ? "
      'ORDER BY rowid',
      [category],
    )) {
      if (r['a'] == null) continue;
      for (final k in (jsonDecode(r['a'] as String) as Map).keys) {
        counts[k as String] = (counts[k] ?? 0) + 1;
      }
    }
    final names = counts.keys.toList();
    // Stable: equal counts keep first-seen order.
    return [
      for (final (_, n)
          in [for (var i = 0; i < names.length; i++) (i, names[i])]
            ..sort((a, b) {
              final c = counts[b.$2]!.compareTo(counts[a.$2]!);
              return c != 0 ? c : a.$1.compareTo(b.$1);
            }))
        n,
    ];
  }
}
