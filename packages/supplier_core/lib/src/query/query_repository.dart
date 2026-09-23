import 'dart:convert';
import 'package:drift/drift.dart';
import '../contracts.dart';
import '../data/database.dart';
import '../domain/canonical.dart';
import '../domain/values.dart';
import 'comparison.dart';
import 'search_keys.dart';
import 'candidates.dart';

class QueryPage<T> {
  QueryPage(List<T> items, this.version, this.nextCursor)
    : items = List.unmodifiable(items);
  final List<T> items;
  final DatabaseVersion version;
  final String? nextCursor;
}

class QuotationRow {
  QuotationRow(Map<String, Object?> data, this.asOf)
    : values = Map.unmodifiable(data);
  final Map<String, Object?> values;
  final String asOf;
  String get id => values['entity_id']! as String;
  bool get conflicted => values['relation_status'] == 'conflicted';
  List<String> get comparisonExclusions =>
      List.unmodifiable(comparisonIssues(values, asOf));
  Map<String, Object?>? get payload => values['payload'] == null
      ? null
      : Map.unmodifiable(
          jsonDecode(values['payload']! as String) as Map<String, dynamic>,
        );
}

/// A bounded local-workspace row for supplier, product and contact screens.
/// Payload remains canonical JSON owned by the revision/projection layer; the
/// UI never edits projections directly.
class EntityRow {
  EntityRow(Map<String, Object?> data, this.version)
    : values = Map.unmodifiable(data);
  final Map<String, Object?> values;
  final DatabaseVersion version;
  String get type => values['entity_type']! as String;
  String get id => values['entity_id']! as String;
  String? get name => values['name'] as String?;
  String get relationStatus => values['relation_status']! as String;
  String? get revisionId => values['revision_id'] as String?;
  Map<String, Object?>? get payload => values['payload'] == null
      ? null
      : Map.unmodifiable(
          jsonDecode(values['payload']! as String) as Map<String, dynamic>,
        );
}

class QueryRepository {
  QueryRepository(this.database, {DateTime Function()? calendarClock})
    : calendarClock = calendarClock ?? DateTime.now;
  final SupplierDatabase database;

  /// Default as_of is this clock's local calendar date, never an inferred
  /// inquiry timestamp. Callers may pass explicit as_of for reproducibility.
  final DateTime Function() calendarClock;

  /// Keyset-paged records for the local workspace. Deleted and conflicted
  /// records stay visible through [relationStatus] instead of disappearing.
  Future<QueryPage<EntityRow>> entities(
    String type, {
    String? search,
    SearchMode searchMode = SearchMode.contains,
    String? supplierId,
    String? cursor,
    int limit = 50,
  }) => database.transaction(() async {
    queryLimit(limit);
    if (!const {'supplier', 'contact', 'product'}.contains(type)) {
      throw ArgumentError.value(type, 'type', 'Unsupported entity list');
    }
    if (supplierId != null && type != 'contact') {
      throw ArgumentError('supplierId is only supported for contacts');
    }
    final normalizedSearch = search == null ? null : searchKey(search);
    if (search != null && normalizedSearch!.isEmpty) {
      throw ArgumentError('Search text cannot normalize to empty');
    }
    final normalizedSupplierId = supplierId == null
        ? null
        : requireUuid(supplierId, 'supplier_id');
    final version = await database.currentVersion();
    final digest = canonicalSha256({
      'entity_list': type,
      'search': normalizedSearch,
      'search_mode': searchMode.name,
      'supplier_id': normalizedSupplierId,
    });
    final decoded = decodeQueryCursor(cursor, digest, 'entity-name');
    checkCursorVersion(decoded, version);
    final afterName = decoded?['key'] as String? ?? '';
    final afterId = decoded?['id'] as String? ?? '';
    final conditions = <String>["(COALESCE(name,''),entity_id)>(?,?)"];
    final variables = <Variable>[Variable(afterName), Variable(afterId)];
    if (normalizedSearch != null) {
      final predicate = searchPredicate(
        'name_key',
        normalizedSearch,
        searchMode,
      );
      conditions.add(predicate.$1);
      variables.addAll(predicate.$2);
    }
    if (normalizedSupplierId != null) {
      conditions.add(
        '(canonical_supplier_id=? OR (canonical_supplier_id IS NULL AND supplier_id=?))',
      );
      variables.addAll([
        Variable(normalizedSupplierId),
        Variable(normalizedSupplierId),
      ]);
    }
    variables.add(Variable(limit + 1));
    final rows = await database.rows(
      '''SELECT entity_type,entity_id,revision_id,payload,relation_status,name,
      canonical_supplier_id,brand,model FROM ${type}_projection
      WHERE ${conditions.join(' AND ')}
      ORDER BY COALESCE(name,''),entity_id LIMIT ?''',
      variables,
    );
    final items = rows
        .take(limit)
        .map((row) => EntityRow(row.data, version))
        .toList();
    final next = rows.length > limit
        ? encodeQueryCursor(
            version,
            digest,
            'entity-name',
            items.last.name ?? '',
            items.last.id,
          )
        : null;
    return QueryPage(items, version, next);
  });

  Future<EntityRow?> entity(
    String type,
    String id,
  ) => database.transaction(() async {
    if (!const {'supplier', 'contact', 'product'}.contains(type)) {
      throw ArgumentError.value(type, 'type', 'Unsupported entity detail');
    }
    requireUuid(id, 'entity_id');
    final version = await database.currentVersion();
    final rows = await database.rows(
      '''SELECT entity_type,entity_id,revision_id,payload,relation_status,name,
          canonical_supplier_id,brand,model FROM ${type}_projection
          WHERE entity_id=?''',
      [Variable(id)],
    );
    return rows.isEmpty ? null : EntityRow(rows.single.data, version);
  });

  /// Number of active projected references shown before destructive actions.
  Future<int> referenceImpact(String type, String id) async {
    if (!const {'supplier', 'contact', 'product'}.contains(type)) {
      throw ArgumentError.value(type, 'type', 'Unsupported impact type');
    }
    requireUuid(id, 'entity_id');
    return (await database.rows(
      '''SELECT COUNT(DISTINCT source_type||char(0)||source_id) n
      FROM reference_projection WHERE target_type=? AND target_id=?''',
      [Variable(type), Variable(id)],
    )).single.read<int>('n');
  }

  Future<QueryPage<QuotationRow>> quotations(
    Map<String, Object?> filters, {
    String? cursor,
    int limit = 50,
  }) => database.transaction(() async {
    queryLimit(limit);
    final query = _compile(filters, cursor, limit);
    final version = await database.currentVersion();
    query.checkVersion(version);
    final rows = await database.rows(query.sql, query.variables);
    final items = rows
        .take(limit)
        .map((row) => QuotationRow(row.data, query.asOf))
        .toList();
    final last = items.isEmpty ? null : items.last.values;
    final next = rows.length > limit
        ? encodeQueryCursor(
            version,
            query.digest,
            query.sort,
            last!['_sort_key']! as String,
            last['entity_id']! as String,
          )
        : null;
    return QueryPage(items, version, next);
  });
  Future<List<String>> explain(
    Map<String, Object?> filters, {
    String? cursor,
    int limit = 50,
  }) async {
    final query = _compile(filters, cursor, limit);
    return (await database.rows(
      'EXPLAIN QUERY PLAN ${query.sql}',
      query.variables,
    )).map((r) => r.read<String>('detail')).toList();
  }

  /// Explicit paged head details for a conflict summary; no selected winner.
  Future<QueryPage<QuotationRow>> quotationHeads(
    String entityId, {
    String? cursor,
    int limit = 50,
  }) => database.transaction(() async {
    queryLimit(limit);
    requireUuid(entityId, 'entity_id');
    final version = await database.currentVersion();
    final asOf = _today();
    final digest = canonicalSha256({'heads': entityId, 'as_of': asOf});
    final decoded = decodeQueryCursor(cursor, digest, 'heads');
    checkCursorVersion(decoded, version);
    final rows = await database.rows(
      "SELECT q.*,q.revision_id _sort_key,s.name supplier_name,p.name product_name,c.name contact_name,sa.relation_status supplier_status,pa.relation_status product_status FROM quotation_head_projection q LEFT JOIN supplier_projection s ON s.entity_id=COALESCE(q.canonical_supplier_id,q.supplier_id) LEFT JOIN product_projection p ON p.entity_id=COALESCE(q.canonical_product_id,q.product_id) LEFT JOIN contact_projection c ON c.entity_id=COALESCE(q.canonical_contact_id,q.contact_id) LEFT JOIN alias_projection sa ON sa.entity_type='supplier' AND sa.entity_id=q.supplier_id LEFT JOIN alias_projection pa ON pa.entity_type='product' AND pa.entity_id=q.product_id WHERE q.entity_id=? AND q.revision_id>? ORDER BY q.revision_id LIMIT ?",
      [
        Variable(entityId),
        Variable(decoded?['id'] as String? ?? ''),
        Variable(limit + 1),
      ],
    );
    final items = rows
        .take(limit)
        .map((r) => QuotationRow(r.data, asOf))
        .toList();
    return QueryPage(
      items,
      version,
      rows.length > limit
          ? encodeQueryCursor(
              version,
              digest,
              'heads',
              items.last.values['revision_id']! as String,
              items.last.values['revision_id']! as String,
            )
          : null,
    );
  });
  Future<List<Candidate>> candidates(
    String type,
    Map<String, String> terms, {
    SearchMode mode = SearchMode.exact,
    String? supplierId,
    int limit = 50,
  }) => CandidateRepository(
    database,
  ).find(type, terms, mode: mode, supplierId: supplierId, limit: limit);
  String _today() => calendarClock().toIso8601String().substring(0, 10);
  _CompiledQuery _compile(
    Map<String, Object?> input,
    String? cursor,
    int limit,
  ) {
    queryLimit(limit);
    const allowed = {
      'supplier_id',
      'contact_id',
      'product_id',
      'product_name',
      'supplier_name',
      'contact_name',
      'brand',
      'model',
      'project_name',
      'project_number',
      'inquirer_name',
      'inquiry_from',
      'inquiry_to',
      'inquiry_precision',
      'inquiry_missing',
      'quoted_from',
      'quoted_to',
      'price_min',
      'price_max',
      'missing_context',
      'currency',
      'unit_snapshot',
      'tax_mode',
      'min_qty',
      'tax_rate',
      'view',
      'as_of',
      'sort',
      'text_mode',
    };
    if (input.keys.any((key) => !allowed.contains(key))) {
      throw const DomainFailure(
        'unknown_filter',
        'Query filter is not supported',
      );
    }
    final filters = Map<String, Object?>.from(input);
    for (final entry in filters.entries) {
      if (entry.value == null && entry.key != 'tax_rate') {
        throw ArgumentError('Filter ${entry.key} cannot be null');
      }
    }
    for (final entry in {
      'tax_mode': {'included', 'excluded', 'unknown'},
      'inquiry_precision': {'date', 'instant', 'unknown'},
    }.entries) {
      if (filters.containsKey(entry.key) &&
          !entry.value.contains(filters[entry.key])) {
        throw ArgumentError('Invalid ${entry.key}');
      }
    }
    if (filters.containsKey('currency') &&
        (filters['currency'] is! String ||
            !RegExp(r'^[A-Z]{3}$').hasMatch(filters['currency']! as String))) {
      throw ArgumentError('Invalid currency');
    }
    final view = filters['view'] ?? 'history';
    if (!['history', 'latest', 'confirmed_lowest'].contains(view)) {
      throw ArgumentError('Unknown view');
    }
    final sort = filters['sort'] ?? 'inquiry_date_desc';
    if (!['inquiry_date_desc', 'quoted_on_desc', 'price_asc'].contains(sort)) {
      throw ArgumentError('Unknown sort');
    }
    final mode = SearchMode.values.byName(
      filters['text_mode'] as String? ?? 'exact',
    );
    final asOf = requireDate(filters['as_of'] ?? _today(), 'as_of');
    filters['as_of'] = asOf;
    filters['view'] = view;
    filters['sort'] = sort;
    filters['text_mode'] = mode.name;
    final digest = canonicalSha256(filters);
    final decoded = decodeQueryCursor(cursor, digest, sort as String);
    final direct = _filter(filters, 'q', mode),
        conflicts = _filter(filters, 'h', mode);
    final vars = <Variable>[];
    String where = '1';
    var prefix = '';
    var table = 'quotation_projection';
    final filtered = direct.$1.isNotEmpty;
    final scoped = filtered
        ? "SELECT q.* FROM quotation_projection q WHERE q.relation_status<>'conflicted' AND ${direct.$1.join(' AND ')} UNION ALL SELECT q.* FROM quotation_projection q WHERE q.relation_status='conflicted' AND EXISTS(SELECT 1 FROM quotation_head_projection h WHERE h.entity_id=q.entity_id AND ${conflicts.$1.join(' AND ')})"
        : 'SELECT * FROM quotation_projection';
    if (filtered) {
      vars.addAll(direct.$2);
      vars.addAll(conflicts.$2);
      prefix = 'WITH scoped AS ($scoped) ';
      table = 'scoped';
    }
    if (view == 'confirmed_lowest' || view == 'latest') {
      final confirmed = view == 'confirmed_lowest';
      final validity = confirmed
          ? " AND q.tax_mode IN ('included','excluded') AND q.valid_until IS NOT NULL AND q.valid_until>=?"
          : '';
      prefix =
          """WITH scoped AS ($scoped),
        eligible AS (SELECT q.* FROM scoped q LEFT JOIN alias_projection sa ON sa.entity_type='supplier' AND sa.entity_id=q.supplier_id LEFT JOIN alias_projection pa ON pa.entity_type='product' AND pa.entity_id=q.product_id WHERE q.relation_status='active' AND q.payload IS NOT NULL AND sa.relation_status='active' AND pa.relation_status='active' AND q.quoted_on IS NOT NULL AND q.quoted_on<=?$validity),
        latest AS (SELECT *,DENSE_RANK() OVER(PARTITION BY $comparisonPartition,canonical_supplier_id ORDER BY quoted_on DESC) latest_rank FROM eligible),
        minima AS (SELECT *,MIN(price_key) OVER(PARTITION BY $comparisonPartition) minimum_price FROM latest WHERE latest_rank=1) """;
      vars.addAll([Variable(asOf), if (confirmed) Variable(asOf)]);
      table = 'minima';
      where = view == 'latest' ? '1' : 'q.price_key=q.minimum_price';
    }
    final expression = switch (sort) {
      'price_asc' => "COALESCE(q.price_key,'~')",
      'quoted_on_desc' => "COALESCE(q.quoted_on,'')",
      _ => "COALESCE(q.inquiry_date,'')",
    };
    final descending = sort != 'price_asc';
    if (decoded != null) {
      final key = decoded['key']! as String;
      where +=
          ' AND ($expression ${descending ? '<=' : '>='} ? AND ($expression ${descending ? '<' : '>'} ? OR q.entity_id>?))';
      vars.addAll([
        Variable(key),
        Variable(key),
        Variable(decoded['id']! as String),
      ]);
    }
    vars.add(Variable(limit + 1));
    var sql =
        '''${prefix}SELECT q.*,$expression _sort_key,s.name supplier_name,p.name product_name,c.name contact_name,sa.relation_status supplier_status,pa.relation_status product_status
      FROM $table q
      LEFT JOIN supplier_projection s ON s.entity_id=COALESCE(q.canonical_supplier_id,q.supplier_id)
      LEFT JOIN product_projection p ON p.entity_id=COALESCE(q.canonical_product_id,q.product_id)
      LEFT JOIN contact_projection c ON c.entity_id=COALESCE(q.canonical_contact_id,q.contact_id)
      LEFT JOIN alias_projection sa ON sa.entity_type='supplier' AND sa.entity_id=q.supplier_id
      LEFT JOIN alias_projection pa ON pa.entity_type='product' AND pa.entity_id=q.product_id
      WHERE $where ORDER BY $expression ${descending ? 'DESC' : 'ASC'},q.entity_id ASC LIMIT ?''';
    if (view == 'history') {
      // Page narrow indexed keys before fetching payloads and display relations.
      // Otherwise broad text matches join/sort thousands of wide rows for 50.
      final pagePrefix = prefix.isEmpty ? 'WITH ' : '${prefix.trimRight()}, ';
      sql =
          '''${pagePrefix}page AS MATERIALIZED (
        SELECT q.entity_id,$expression _sort_key FROM $table q
        WHERE $where ORDER BY $expression ${descending ? 'DESC' : 'ASC'},q.entity_id ASC LIMIT ?)
        SELECT q.*,page._sort_key,s.name supplier_name,p.name product_name,c.name contact_name,sa.relation_status supplier_status,pa.relation_status product_status
        FROM page JOIN quotation_projection q ON q.entity_id=page.entity_id
        LEFT JOIN supplier_projection s ON s.entity_id=COALESCE(q.canonical_supplier_id,q.supplier_id)
        LEFT JOIN product_projection p ON p.entity_id=COALESCE(q.canonical_product_id,q.product_id)
        LEFT JOIN contact_projection c ON c.entity_id=COALESCE(q.canonical_contact_id,q.contact_id)
        LEFT JOIN alias_projection sa ON sa.entity_type='supplier' AND sa.entity_id=q.supplier_id
        LEFT JOIN alias_projection pa ON pa.entity_type='product' AND pa.entity_id=q.product_id
        ORDER BY page._sort_key ${descending ? 'DESC' : 'ASC'},page.entity_id ASC''';
    }
    return _CompiledQuery(sql, vars, digest, sort, asOf, decoded);
  }

  (List<String>, List<Variable>) _filter(
    Map<String, Object?> f,
    String alias,
    SearchMode mode,
  ) {
    final conditions = <String>[], variables = <Variable>[];
    void condition(String sql, Object value) {
      conditions.add(sql);
      variables.add(value is int ? Variable(value) : Variable(value as String));
    }

    for (final field in ['supplier_id', 'product_id', 'contact_id']) {
      if (f[field] != null) {
        final id = requireUuid(f[field], field);
        conditions.add('($alias.$field=? OR $alias.canonical_$field=?)');
        variables.addAll([Variable(id), Variable(id)]);
      }
    }
    for (final field in [
      'currency',
      'unit_snapshot',
      'tax_mode',
      'inquiry_precision',
    ]) {
      if (f[field] != null) {
        condition('$alias.$field=?', _text(f[field], field));
      }
    }
    if (f.containsKey('tax_rate') && f['tax_rate'] == null) {
      conditions.add('$alias.tax_rate IS NULL');
    }
    for (final field in ['min_qty', 'tax_rate']) {
      if (f[field] != null) {
        condition(
          '$alias.$field=?',
          ExactDecimal.parse(
            _text(f[field], field),
            positive: field == 'min_qty',
            maxIntegerDigits: field == 'tax_rate' ? 3 : 12,
            maxFractionDigits: field == 'tax_rate' ? 4 : 6,
          ).canonical,
        );
      }
    }
    for (final entry in {
      'inquiry_from': ('inquiry_date', '>='),
      'inquiry_to': ('inquiry_date', '<='),
      'quoted_from': ('quoted_on', '>='),
      'quoted_to': ('quoted_on', '<='),
    }.entries) {
      if (f[entry.key] != null) {
        condition(
          '$alias.${entry.value.$1}${entry.value.$2}?',
          requireDate(f[entry.key], entry.key),
        );
      }
    }
    for (final entry in {'price_min': '>=', 'price_max': '<='}.entries) {
      if (f[entry.key] != null) {
        condition(
          '$alias.price_key${entry.value}?',
          ExactDecimal.parse(_text(f[entry.key], entry.key)).sortKey,
        );
      }
    }
    if (f['inquiry_missing'] != null) {
      if (f['inquiry_missing'] is! bool) {
        throw ArgumentError('inquiry_missing must be bool');
      }
      conditions.add(
        '$alias.inquiry_date IS ${f['inquiry_missing'] == true ? '' : 'NOT '}NULL',
      );
    }
    if (f['missing_context'] != null) {
      if (f['missing_context'] is! bool) {
        throw ArgumentError('missing_context must be bool');
      }
      conditions.add(
        '$alias.missing_context_count${f['missing_context'] == true ? '>0' : '=0'}',
      );
    }
    for (final field in ['project_name', 'project_number', 'inquirer_name']) {
      if (f[field] != null) {
        final test = searchPredicate(
          '$alias.${field}_key',
          searchKey(_text(f[field], field)),
          mode,
        );
        conditions.add(test.$1);
        variables.addAll(test.$2);
      }
    }
    for (final type in ['supplier', 'contact']) {
      final field = '${type}_name';
      if (f[field] == null) continue;
      final test = searchPredicate(
        't.search_key',
        searchKey(_text(f[field], field)),
        mode,
      );
      final matches =
          "SELECT t.entity_id FROM candidate_term t WHERE t.entity_type='$type' AND t.field='name' AND ${test.$1}";
      conditions.add(
        '($alias.canonical_${type}_id IN ($matches) OR $alias.${type}_id IN ($matches))',
      );
      variables.addAll([...test.$2, ...test.$2]);
    }
    for (final entry in {
      'product_name': 'name',
      'brand': 'brand',
      'model': 'model',
    }.entries) {
      if (f[entry.key] != null) {
        final test = searchPredicate(
          't.search_key',
          searchKey(_text(f[entry.key], entry.key)),
          mode,
        );
        final matches =
            "SELECT t.entity_id FROM candidate_term t WHERE t.entity_type='product' AND t.field=? AND ${test.$1}";
        conditions.add(
          '($alias.canonical_product_id IN ($matches) OR $alias.product_id IN ($matches))',
        );
        for (var branch = 0; branch < 2; branch++) {
          variables.add(Variable(entry.value));
          variables.addAll(test.$2);
        }
      }
    }
    return (conditions, variables);
  }

  String _text(Object? value, String field) {
    if (value is! String || value.isEmpty || value.length > 500) {
      throw ArgumentError('Invalid $field');
    }
    return value;
  }
}

void queryLimit(int limit) {
  if (limit < 1 || limit > 200) {
    throw ArgumentError.value(limit, 'limit', 'Expected 1..200');
  }
}

String encodeQueryCursor(
  DatabaseVersion v,
  String digest,
  String sort,
  String key,
  String id,
) => base64UrlEncode(
  utf8.encode(
    jsonEncode({
      'instance': v.instanceId,
      'epoch': v.activeEpoch,
      'generation': v.generation,
      'digest': digest,
      'sort': sort,
      'key': key,
      'id': id,
    }),
  ),
);
Map<String, dynamic>? decodeQueryCursor(
  String? cursor,
  String digest,
  String sort,
) {
  if (cursor == null) return null;
  if (cursor.length > 4096) {
    throw const DomainFailure(
      'invalid_cursor',
      'Cursor exceeds bounded token length',
    );
  }
  try {
    final value =
        jsonDecode(utf8.decode(base64Url.decode(cursor)))
            as Map<String, dynamic>;
    if (value['digest'] != digest ||
        value['sort'] != sort ||
        value['instance'] is! String ||
        value['epoch'] is! int ||
        value['generation'] is! int ||
        value['key'] is! String ||
        value['id'] is! String) {
      throw const FormatException();
    }
    return value;
  } catch (_) {
    throw const DomainFailure(
      'invalid_cursor',
      'Cursor does not belong to this query',
    );
  }
}

void checkCursorVersion(Map<String, dynamic>? cursor, DatabaseVersion v) {
  if (cursor != null &&
      (cursor['instance'] != v.instanceId ||
          cursor['epoch'] != v.activeEpoch ||
          cursor['generation'] != v.generation)) {
    throw const DomainFailure(
      'stale_cursor',
      'Database changed since previous page',
    );
  }
}

class _CompiledQuery {
  _CompiledQuery(
    this.sql,
    this.variables,
    this.digest,
    this.sort,
    this.asOf,
    this.cursor,
  );
  final String sql, digest, sort, asOf;
  final List<Variable> variables;
  final Map<String, dynamic>? cursor;
  void checkVersion(DatabaseVersion v) => checkCursorVersion(cursor, v);
}
