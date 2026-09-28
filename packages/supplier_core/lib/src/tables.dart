import 'dart:convert';

import 'budget.dart';
import 'compare.dart';
import 'storage_codec.dart';
import 'store.dart';
import 'values.dart';

/// A supplier with what the list shows about it.
class SupplierRow {
  SupplierRow(
    this.id,
    this.data, {
    required this.contacts,
    required this.quotes,
    required this.awards,
    required this.projects,
    this.contactName,
    this.contactPhone,
    this.lastQuotedOn,
  });
  final String id;
  final Map<String, Object?> data;
  final int contacts, quotes, awards, projects;
  final String? contactName, contactPhone, lastQuotedOn;
}

/// A material with what the list shows about it.
class ProductRow {
  ProductRow(
    this.id,
    this.data, {
    required this.quotes,
    required this.suppliers,
    required this.projects,
    this.lastQuote,
  });
  final String id;
  final Map<String, Object?> data;
  final int quotes, suppliers, projects;

  /// The most recent quotation's payload.
  final Map<String, Object?>? lastQuote;
}

/// Which quotations a list shows.
enum QuoteFilter { all, usable, expired, informal, awarded }

enum QuoteSort { quotedOn, price, supplier, product }

class QuoteRow {
  QuoteRow(
    this.id,
    this.data, {
    required this.supplier,
    required this.product,
    required this.issues,
    this.model,
    this.project,
  });
  final String id;
  final Map<String, Object?> data;
  final String supplier, product;
  final String? model, project;

  /// Why it is not usable today; empty when it is.
  final List<QuoteIssue> issues;
  bool get awarded => data['awarded_on'] != null;
}

class QuotePage {
  QuotePage(this.total, this.rows);

  /// Matching quotations in all, of which [rows] is the first page.
  final int total;
  final List<QuoteRow> rows;
}

String _live(String t) =>
    "$t.deleted = 0 AND json_extract($t.data,'\$.merged_into') IS NULL";

extension Tables on Store {
  /// Live suppliers (all, or [only] these ids) with their counts. The
  /// aggregates are separate grouped queries joined here in Dart: SQLite
  /// nest-loops a join against grouped subqueries (quadratic at 10k rows).
  List<SupplierRow> supplierRows({Set<String>? only}) {
    final quotes = _byKey('''
      SELECT json_extract(data,'\$.supplier_id') AS k, count(*) AS n,
        max(json_extract(data,'\$.quoted_on')) AS last,
        sum(json_extract(data,'\$.awarded_on') IS NOT NULL) AS awards,
        count(DISTINCT json_extract(data,'\$.project_id')) AS projects
      FROM quotation WHERE deleted = 0 GROUP BY k''');
    // Bare-column rule: name and phone come from the row holding min().
    final contacts = _byKey('''
      SELECT json_extract(data,'\$.supplier_id') AS k, count(*) AS n,
        json_extract(data,'\$.name') AS name,
        coalesce(json_extract(data,'\$.phone'),
          json_extract(data,'\$.wechat'),
          json_extract(data,'\$.email')) AS phone,
        min(rowid) AS first
      FROM contact WHERE deleted = 0 GROUP BY k''');
    return [
      for (final r in db.select(
        'SELECT id, data FROM supplier s WHERE ${_live('s')} '
        'ORDER BY rowid DESC',
      ))
        if (only == null || only.contains(r['id']))
          _supplierRow(r, quotes[r['id']], contacts[r['id']]),
    ];
  }

  SupplierRow _supplierRow(
    Map<String, Object?> r,
    Map<String, Object?>? q,
    Map<String, Object?>? c,
  ) => SupplierRow(
    r['id']! as String,
    decodeStoredPayload('supplier', r['data']! as String),
    contacts: c?['n'] as int? ?? 0,
    quotes: q?['n'] as int? ?? 0,
    awards: q?['awards'] as int? ?? 0,
    projects: q?['projects'] as int? ?? 0,
    contactName: c?['name'] as String?,
    contactPhone: c?['phone'] as String?,
    lastQuotedOn: q?['last'] as String?,
  );

  /// Live materials (all, or [only] these ids) with their latest quotation.
  List<ProductRow> productRows({Set<String>? only}) {
    // Latest quotation per material via the bare-column rule (id from the
    // row holding max()); payloads are then read by key. Sorting the JSON
    // payloads themselves in a window takes minutes at 100k.
    final latest = _byKey('''
      SELECT json_extract(data,'\$.product_id') AS k, count(*) AS n,
        count(DISTINCT json_extract(data,'\$.supplier_id')) AS suppliers,
        id,
        max(coalesce(json_extract(data,'\$.quoted_on'), '') || '|' ||
          printf('%012d', rowid)) AS newest
      FROM quotation WHERE deleted = 0 GROUP BY k''');
    final payloads = {
      for (final r in db.select(
        'SELECT id, data FROM quotation WHERE id IN '
        '(SELECT value FROM json_each(?))',
        [
          jsonEncode([for (final q in latest.values) q['id']]),
        ],
      ))
        r['id']! as String: r['data']! as String,
    };
    final used = _byKey('''
      SELECT json_extract(data,'\$.product_id') AS k,
        count(DISTINCT json_extract(data,'\$.project_id')) AS n
      FROM project_item WHERE deleted = 0 GROUP BY k''');
    return [
      for (final r in db.select(
        'SELECT id, data FROM product p WHERE ${_live('p')} '
        'ORDER BY rowid DESC',
      ))
        if (only == null || only.contains(r['id']))
          ProductRow(
            r['id']! as String,
            decodeStoredPayload('product', r['data']! as String),
            quotes: latest[r['id']]?['n'] as int? ?? 0,
            suppliers: latest[r['id']]?['suppliers'] as int? ?? 0,
            projects: used[r['id']]?['n'] as int? ?? 0,
            lastQuote: switch (payloads[latest[r['id']]?['id']]) {
              final String json => decodeStoredPayload('quotation', json),
              null => null,
            },
          ),
    ];
  }

  /// Rows of a grouped query by their `k` column.
  Map<String, Map<String, Object?>> _byKey(String sql) => {
    for (final r in db.select(sql))
      if (r['k'] case final String k) k: r,
  };

  /// One page of quotations, filtered and sorted in the database so it
  /// stays quick with a hundred thousand of them. [productIds] and
  /// [supplierIds] come from a keyword search and match either.
  QuotePage quoteRows({
    QuoteFilter filter = QuoteFilter.all,
    Set<String>? productIds,
    Set<String>? supplierIds,
    String? projectId,
    QuoteSort sort = QuoteSort.quotedOn,
    bool descending = true,
    int limit = 200,
    DateTime? asOf,
  }) {
    final now = asOf ?? clock();
    final today = localDay(now);
    final staleBefore = localDay(
      now.subtract(const Duration(days: undatedValidityDays)),
    );
    String f(String field) => "json_extract(q.data,'\$.$field')";
    // Each clause with its parameters, in the order they appear.
    // coalesce: an empty date must read as "not expired", not as NULL,
    // which NOT would keep NULL and silently drop the row.
    final expired = (
      "coalesce((${f('valid_until')} < ? OR "
          "(${f('valid_until')} IS NULL AND ${f('quoted_on')} < ?)), 0)",
      [today, staleBefore],
    );
    final clauses = <(String, List<Object?>)>[
      ('q.deleted = 0', const []),
      switch (filter) {
        QuoteFilter.all => ('1', const []),
        QuoteFilter.expired => expired,
        QuoteFilter.informal => ("${f('price_basis')} IS NOT NULL", const []),
        QuoteFilter.awarded => ("${f('awarded_on')} IS NOT NULL", const []),
        QuoteFilter.usable => (
          "NOT ${expired.$1} AND ${f('quoted_on')} <= ? AND "
              "${f('price_basis')} IS NULL AND ${f('tax_mode')} <> 'unknown' "
              'AND coalesce(s.deleted, 1) = 0 '
              "AND coalesce(json_extract(s.data,'\$.rating'), '') <> 'disabled'",
          [...expired.$2, today],
        ),
      },
      if (projectId != null) ("${f('project_id')} = ?", [projectId]),
      if (productIds != null || supplierIds != null)
        (
          "(${f('product_id')} IN (SELECT value FROM json_each(?)) OR "
              "${f('supplier_id')} IN (SELECT value FROM json_each(?)))",
          [
            jsonEncode([...?productIds]),
            jsonEncode([...?supplierIds]),
          ],
        ),
    ];
    final order = switch (sort) {
      QuoteSort.quotedOn => f('quoted_on'),
      QuoteSort.price =>
        "CAST(coalesce(${f('deal_price')}, ${f('price')}) AS REAL)",
      // ponytail: code-point order for names; sort by pinyin in Dart if
      // users ask for 拼音顺序.
      QuoteSort.supplier => "json_extract(s.data,'\$.name')",
      QuoteSort.product => "json_extract(p.data,'\$.name')",
    };
    final rows = db.select(
      '''
      SELECT q.id, q.data, coalesce(s.deleted, 1) AS supplier_deleted,
        json_extract(s.data,'\$.rating') AS rating,
        json_extract(s.data,'\$.name') AS supplier,
        json_extract(p.data,'\$.name') AS product,
        json_extract(p.data,'\$.model') AS model,
        json_extract(pr.data,'\$.name') AS project,
        count(*) OVER () AS total
      FROM quotation q
        LEFT JOIN supplier s ON s.id = ${f('supplier_id')}
        LEFT JOIN product p ON p.id = ${f('product_id')}
        LEFT JOIN project pr ON pr.id = ${f('project_id')}
      WHERE ${clauses.map((c) => c.$1).join(' AND ')}
      ORDER BY $order ${descending ? 'DESC' : 'ASC'}, q.rowid DESC
      LIMIT ?
      ''',
      [for (final c in clauses) ...c.$2, limit],
    );
    return QuotePage(rows.isEmpty ? 0 : rows.first['total'] as int, [
      for (final r in rows)
        () {
          final d = decodeStoredPayload('quotation', r['data'] as String);
          return QuoteRow(
            r['id'] as String,
            d,
            supplier: r['supplier'] as String? ?? '未知供应商',
            product: r['product'] as String? ?? '未知物料',
            model: r['model'] as String?,
            project: r['project'] as String?,
            issues: quoteIssues(
              d,
              today: today,
              staleBefore: staleBefore,
              supplierDeleted: r['supplier_deleted'] == 1,
              supplierDisabled: r['rating'] == 'disabled',
            ),
          );
        }(),
    ]);
  }
}
