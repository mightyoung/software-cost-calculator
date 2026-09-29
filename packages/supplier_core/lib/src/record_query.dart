import 'dart:convert';
import 'dart:math';

import 'ontology.dart';
import 'store.dart';
import 'values.dart';

/// Comparison operators of [RecordQuery.queryRecords].
const queryOps = [
  'eq',
  'ne',
  'contains',
  'gt',
  'gte',
  'lt',
  'lte',
  'is_null',
  'not_null',
  'in',
];

/// Fields every record has besides its payload.
const _envelope = {'id', 'updated_at', 'updated_by'};
final _queryConnections = Expando<String>();

class QueryResult {
  QueryResult(this.total, this.rows, {this.offset = 0, this.snapshot});
  final int total;
  final List<Map<String, Object?>> rows;
  final int offset;
  final String? snapshot;
}

extension RecordQuery on Store {
  /// Live records of [type] matching every condition of [where] (each
  /// `{field, op, value}`), newest change first unless [orderBy] is given.
  /// Fields must exist in the [ontology]; decimals compare numerically,
  /// list fields match when any element does. All values are bound as
  /// parameters.
  QueryResult queryRecords(
    String type, {
    List<Map<String, Object?>> where = const [],
    String? orderBy,
    bool descending = false,
    int limit = 20,
    int offset = 0,
    String? expectedSnapshot,
  }) {
    if (limit < 1) invalid('limit', 'must be positive');
    if (offset < 0) invalid('offset', 'must be non-negative');
    final spec = ontology[type] ?? invalid('type', 'unknown object type');
    // Keep the full decimal precision for both ordering and comparisons.
    // JSON decimals are canonical text; REAL would round adjacent large values.
    db.createCollation(
      name: 'exact_decimal',
      function: (a, b) {
        if (a == null) return b == null ? 0 : -1;
        if (b == null) return 1;
        return ExactDecimal.parse(a).compareTo(ExactDecimal.parse(b));
      },
    );
    final sql = <String>['deleted = 0'];
    final args = <Object?>[];
    if (spec.field('merged_into') != null) {
      sql.add("json_extract(data,'\$.merged_into') IS NULL");
    }
    for (final c in where) {
      final (clause, values) = _condition(spec, c);
      sql.add(clause);
      args.addAll(values);
    }
    final filter = sql.join(' AND ');
    final snapshot = _querySnapshot();
    if (expectedSnapshot != null && expectedSnapshot != snapshot) {
      invalid('snapshot', 'data changed; restart from offset 0');
    }
    final total =
        db
                .select('SELECT count(*) AS n FROM $type WHERE $filter', args)
                .first['n']
            as int;
    final order = orderBy == null
        ? 'updated_at DESC'
        : '${_column(spec, orderBy)} ${descending ? 'DESC' : 'ASC'}';
    final rows = db.select(
      'SELECT id, updated_at, updated_by, data FROM $type WHERE $filter '
      'ORDER BY $order, id ASC LIMIT ? OFFSET ?',
      [...args, limit, offset],
    );
    // No lock spans model turns. If a writer committed between count and rows,
    // reject this page rather than claiming it belongs to the earlier version.
    if (_querySnapshot() != snapshot) {
      invalid('snapshot', 'data changed during query; restart from offset 0');
    }
    return QueryResult(
      total,
      [for (final r in rows) recordJson(r)],
      offset: offset,
      snapshot: snapshot,
    );
  }

  /// Records of the link's source type that point at [id] through [link]
  /// ("quotation.supplier_id": quotations of a supplier).
  QueryResult relatedRecords(
    String link,
    String id, {
    int limit = 20,
    int offset = 0,
    String? expectedSnapshot,
  }) {
    final l =
        links.where((l) => l.name == link).firstOrNull ??
        invalid('link', 'unknown link');
    return queryRecords(
      l.from,
      where: [
        {'field': l.field, 'op': 'eq', 'value': id},
      ],
      limit: limit,
      offset: offset,
      expectedSnapshot: expectedSnapshot,
    );
  }

  String _querySnapshot() {
    final connection = _queryConnections[db] ??= base64UrlEncode(
      List.generate(16, (_) => Random.secure().nextInt(256)),
    );
    // total_changes covers this connection, data_version covers other writers.
    // A random connection identity also rejects tokens from a reopened store.
    final version = db
        .select(
          'SELECT total_changes() AS local_changes, data_version FROM pragma_data_version',
        )
        .single;
    return '$connection:${version['local_changes']}:${version['data_version']}';
  }
}

/// A stored row as an agent sees it: id, change stamp and the payload, with
/// empty fields left out.
Map<String, Object?> recordJson(Map<String, Object?> row) => {
  'id': row['id'],
  for (final MapEntry(:key, :value)
      in (jsonDecode(row['data']! as String) as Map<String, Object?>).entries)
    if (value != null) key: value,
  'updated_at': row['updated_at'],
  'updated_by': row['updated_by'],
};

FieldSpec? _spec(ObjectType type, String field) => _envelope.contains(field)
    ? FieldSpec(field, field, Kind.text, '')
    : type.field(field);

/// SQL expression of [field]; decimals as numbers so they sort and compare
/// by value.
String _column(ObjectType type, String field) {
  final f = _spec(type, field) ?? invalid('field', 'unknown field $field');
  if (_envelope.contains(field)) return field;
  final raw = "json_extract(data,'\$.${f.name}')";
  return f.kind == Kind.decimal ? '$raw COLLATE exact_decimal' : raw;
}

(String, List<Object?>) _condition(ObjectType type, Map<String, Object?> c) {
  final field = c['field'];
  final op = c['op'];
  final value = c['value'];
  if (field is! String) invalid('field', 'required');
  if (!queryOps.contains(op)) invalid('op', 'use one of ${queryOps.join('/')}');
  final f = _spec(type, field) ?? invalid('field', 'unknown field $field');
  final column = _column(type, field);
  if (op == 'is_null') return ('$column IS NULL', const []);
  if (op == 'not_null') return ('$column IS NOT NULL', const []);
  Object? bind(Object? v) {
    if (v == null) invalid('value', 'required for $op');
    if (f.kind == Kind.boolean) {
      if (v is! bool) invalid('value', 'expected a boolean');
      return v ? 1 : 0;
    }
    if (f.kind == Kind.decimal) {
      return ExactDecimal.parse('$v').canonical;
    }
    if (f.kind == Kind.integer) {
      return num.tryParse('$v') ?? invalid('value', 'expected a number');
    }
    return '$v';
  }

  final list = f.kind == Kind.textList || f.kind == Kind.refList;
  // Lists match when any element does.
  String each(String test) =>
      "EXISTS (SELECT 1 FROM json_each(data,'\$.${f.name}') WHERE $test)";
  final target = list ? 'value' : column;
  final String test;
  final List<Object?> args;
  switch (op) {
    case 'contains':
      test = "$target LIKE ? ESCAPE '\\'";
      args = [
        '%${'${value ?? invalid('value', 'required')}'.replaceAll(r'\', r'\\').replaceAll('%', r'\%').replaceAll('_', r'\_')}%',
      ];
    case 'in':
      if (value is! List || value.isEmpty || value.length > 100) {
        invalid('value', 'expected a list of 1-100 values');
      }
      test = '$target IN (${List.filled(value.length, '?').join(',')})';
      args = [for (final v in value) bind(v)];
    case 'ne':
      // "Not equal" includes records where the field is empty.
      return list
          ? ('NOT ${each('value = ?')}', [bind(value)])
          : ('($column IS NULL OR $column <> ?)', [bind(value)]);
    default:
      final sqlOp = const {
        'eq': '=',
        'gt': '>',
        'gte': '>=',
        'lt': '<',
        'lte': '<=',
      }[op]!;
      test = '$target $sqlOp ?';
      args = [bind(value)];
  }
  return (list ? each(test) : test, args);
}
