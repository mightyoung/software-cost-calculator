import 'dart:convert';

import 'package:unorm_dart/unorm_dart.dart' as unicode;

import 'budget.dart';
import 'search_index.dart';
import 'storage_codec.dart';
import 'store.dart';

export 'search_index.dart' show pinyinInitials;

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

/// Index columns matched by [Search.searchByName].
const _nameColumns = ['name', 'aliases', 'code'];

String _key(String s) => unicode.nfkc(s).toLowerCase().trim();

String _like(String s) =>
    '%${s.replaceAll(r'\', r'\\').replaceAll('%', r'\%').replaceAll('_', r'\_')}%';

bool _letters(String s) => RegExp(r'^[a-zA-Z]{2,}$').hasMatch(s);

class Hit {
  Hit(this.id, this.data, this.score);
  final String id;
  final Map<String, Object?> data;
  final int score;
}

/// Time-sensitive quotations and products whose last quotation needs review.
/// Each list is capped for display; the counts cover the whole database.
class QuoteAttention {
  QuoteAttention(
    this.expiringCount,
    this.expiring,
    this.staleProductCount,
    this.staleProducts,
  );
  final int expiringCount, staleProductCount;
  final List<Hit> expiring, staleProducts;
}

extension Search on Store {
  QuoteAttention quoteAttention({DateTime? asOf, int limit = 20}) {
    final now = asOf ?? clock();
    final calendarDay = DateTime.utc(now.year, now.month, now.day);
    final day = calendarDay.toIso8601String().substring(0, 10);
    final soon = calendarDay
        .add(const Duration(days: 30))
        .toIso8601String()
        .substring(0, 10);
    final staleBefore = calendarDay
        .subtract(const Duration(days: undatedValidityDays))
        .toIso8601String()
        .substring(0, 10);
    final cap = limit.clamp(1, 100);
    const due =
        "coalesce(json_extract(q.data,'\$.valid_until'), "
        "date(json_extract(q.data,'\$.quoted_on'), '+$undatedValidityDays days'))";
    const activeQuote =
        "q.deleted = 0 AND json_extract(q.data,'\$.quoted_on') IS NOT NULL "
        "AND json_extract(q.data,'\$.price_basis') IS NULL "
        "AND json_extract(q.data,'\$.tax_mode') != 'unknown'";
    const activeSupplier =
        "EXISTS (SELECT 1 FROM supplier s WHERE s.id = "
        "json_extract(q.data,'\$.supplier_id') AND s.deleted = 0)";
    final expiringFrom =
        'FROM quotation q WHERE $activeQuote '
        "AND json_extract(q.data,'\$.quoted_on') <= ? "
        'AND $due BETWEEN ? AND ? AND $activeSupplier';
    final expiringArgs = [day, day, soon];
    final expiringRows = db.select(
      'SELECT q.id, q.data, $due AS due, count(*) OVER () AS total '
      '$expiringFrom ORDER BY due, q.id LIMIT ?',
      [...expiringArgs, cap],
    );
    final expiringCount = expiringRows.isEmpty
        ? 0
        : expiringRows.first['total'] as int;
    final expiring = [
      for (final r in expiringRows)
        Hit(r['id'] as String, {
          ...decodeStoredPayload('quotation', r['data'] as String),
          'expires_on': r['due'] as String,
        }, 1),
    ];

    // A product enters this list only after it has been quoted at least once.
    const staleFrom =
        "FROM product p JOIN quotation q ON "
        "json_extract(q.data,'\$.product_id') = p.id "
        "WHERE p.deleted = 0 AND json_extract(p.data,'\$.merged_into') IS NULL "
        "AND $activeQuote AND json_extract(q.data,'\$.quoted_on') <= ? "
        'GROUP BY p.id '
        "HAVING max(json_extract(q.data,'\$.quoted_on')) < ?";
    final staleRows = db.select(
      "SELECT p.id, p.data, max(json_extract(q.data,'\$.quoted_on')) AS last_quoted_on, "
      'count(*) OVER () AS total '
      '$staleFrom ORDER BY last_quoted_on, p.id LIMIT ?',
      [day, staleBefore, cap],
    );
    final staleCount = staleRows.isEmpty ? 0 : staleRows.first['total'] as int;
    final staleProducts = [
      for (final r in staleRows)
        Hit(r['id'] as String, {
          ...jsonDecode(r['data'] as String) as Map<String, Object?>,
          'last_quoted_on': r['last_quoted_on'] as String,
        }, 1),
    ];
    return QuoteAttention(expiringCount, expiring, staleCount, staleProducts);
  }

  /// Ids of [type] whose index columns (the keys of [weights]) contain
  /// [term] (plain substring, ASCII case-insensitive), newest first, with
  /// the weights of the matching columns summed. Data is loaded later, only
  /// for the hits kept.
  List<(String, int)> _scored(
    String type,
    Map<String, int> weights,
    String term, {
    int? limit,
  }) {
    final t = searchTable(type);
    final score = [
      for (final MapEntry(key: c, value: w) in weights.entries)
        "(coalesce(f.$c,'') LIKE ?1 ESCAPE '\\')*$w",
    ].join(' + ');
    final fts = ftsQuery(weights.keys.toList(), term);
    return [
      for (final r in db.select(
        'SELECT e.id, $score AS score FROM $t f '
        'JOIN $type e ON e.rowid = f.rowid WHERE score > 0 '
        '${fts == null ? '' : 'AND $t MATCH ?2 '}'
        'ORDER BY e.rowid DESC${limit == null ? '' : ' LIMIT $limit'}',
        [_like(term), ?fts],
      ))
        (r['id'] as String, r['score'] as int),
    ];
  }

  Hit _hit(String type, String id, int score) =>
      Hit(id, get(type, id)!.data, score);

  /// Products ranked by weighted keyword hits. Substring matching works for
  /// Chinese names without a word segmenter; the trigram index serves terms
  /// of three or more characters.
  List<Hit> searchProducts(List<String> keywords, {int limit = 8}) {
    // NFKC turns "m³" into "m3", so the plain lower-case form is searched too.
    final terms = {
      for (final k in keywords) ...[
        if (_key(k).isNotEmpty) _key(k),
        if (k.trim().isNotEmpty) k.trim().toLowerCase(),
      ],
    }.take(20);
    final scores = <String, int>{};
    void add((String, int) hit) =>
        scores[hit.$1] = (scores[hit.$1] ?? 0) + hit.$2;
    for (final term in terms) {
      _scored('product', _productFields, term).forEach(add);
    }
    for (final k in keywords) {
      if (!_letters(k.trim())) continue;
      _scored('product', {
        'initials': _productFields['name']!,
      }, k.trim().toLowerCase()).forEach(add);
    }
    final ranked = scores.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return [
      for (final e in ranked.take(limit)) _hit('product', e.key, e.value),
    ];
  }

  /// Name/alias substring search for suppliers, name/code for projects, name
  /// for products; newest first. Letters alone also match pinyin initials.
  List<Hit> searchByName(String type, String keyword, {int limit = 20}) {
    final columns = {
      for (final c in searchColumns[type]!)
        if (_nameColumns.contains(c)) c: 1,
    };
    final ids = {
      for (final (id, _) in _scored(type, columns, _key(keyword), limit: limit))
        id,
    };
    if (_letters(keyword.trim()) && ids.length < limit) {
      for (final (id, _) in _scored(
        type,
        {'initials': 1},
        keyword.trim().toLowerCase(),
        limit: limit,
      )) {
        ids.add(id);
      }
    }
    return [for (final id in ids.take(limit)) _hit(type, id, 1)];
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
          decodeStoredPayload('quotation', r['data'] as String),
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
