import 'package:drift/drift.dart';
import '../data/database.dart';
import '../domain/values.dart';
import 'query_repository.dart' show queryLimit;
import 'search_keys.dart';

enum SearchMode { exact, prefix, contains }

(String, List<Variable>) searchPredicate(
  String column,
  String key,
  SearchMode mode,
) {
  if (key.isEmpty) throw ArgumentError('Search text cannot normalize to empty');
  return switch (mode) {
    SearchMode.exact => ('$column=?', [Variable(key)]),
    SearchMode.prefix =>
      prefixEnd(key) == null
          ? ('$column>=?', [Variable(key)])
          : (
              '($column>=? AND $column<?)',
              [Variable(key), Variable(prefixEnd(key)!)],
            ),
    SearchMode.contains => ('instr($column,?)>0', [Variable(key)]),
  };
}

class Candidate {
  Candidate(this.id, this.displayName, this.state, List<String> reasons)
    : reasons = List.unmodifiable(reasons);
  final String id, state;
  final String? displayName;
  final List<String> reasons;
}

class CandidateRepository {
  CandidateRepository(this.database);
  final SupplierDatabase database;
  Future<List<Candidate>> find(
    String type,
    Map<String, String> terms, {
    SearchMode mode = SearchMode.exact,
    String? supplierId,
    int limit = 50,
  }) async {
    final compiled = _compile(type, terms, mode, supplierId, limit);
    final rows = await database.rows(compiled.$1, compiled.$2);
    return rows
        .map(
          (r) => Candidate(
            r.read<String>('entity_id'),
            r.readNullable<String>('name'),
            r.read<String>('relation_status'),
            (r.read<String>('fields').split(',')..sort())
                .map((field) => '$field:${mode.name}')
                .toList(),
          ),
        )
        .toList();
  }

  (String, List<Variable>) _compile(
    String type,
    Map<String, String> terms,
    SearchMode mode,
    String? supplierId,
    int limit,
  ) {
    queryLimit(limit);
    final supported = switch (type) {
      'supplier' => {'name', 'aliases'},
      'contact' => {'name', 'phone', 'wechat', 'email'},
      'product' => {'name', 'brand', 'model'},
      _ => throw ArgumentError('Unsupported candidate type'),
    };
    if (terms.isEmpty || terms.keys.any((k) => !supported.contains(k))) {
      throw ArgumentError('Unsupported candidate fields');
    }
    if (supplierId != null && type != 'contact') {
      throw ArgumentError('supplierId applies only to contact candidates');
    }
    final parts = <String>[], args = <Variable>[];
    for (final entry in terms.entries) {
      if (entry.value.length > 500) {
        throw ArgumentError('Candidate term too long');
      }
      final predicate = searchPredicate(
        't.search_key',
        searchKey(entry.value),
        mode,
      );
      parts.add('(t.field=? AND ${predicate.$1})');
      args.add(Variable(entry.key));
      args.addAll(predicate.$2);
    }
    final vars = <Variable>[Variable(type), ...args];
    var where = 't.entity_type=? AND (${parts.join(' OR ')})';
    if (supplierId != null) {
      where += ' AND (p.supplier_id=? OR p.canonical_supplier_id=?)';
      final id = requireUuid(supplierId, 'supplier_id');
      vars.addAll([Variable(id), Variable(id)]);
    }
    vars.add(Variable(limit));
    return (
      'SELECT t.entity_id,p.name,p.relation_status,GROUP_CONCAT(DISTINCT t.field) fields FROM candidate_term t JOIN ${type}_projection p ON p.entity_id=t.entity_id WHERE $where GROUP BY t.entity_id ORDER BY t.entity_id LIMIT ?',
      vars,
    );
  }

  Future<List<String>> explain(
    String type,
    String field,
    String text, {
    SearchMode mode = SearchMode.exact,
  }) async {
    final compiled = _compile(type, {field: text}, mode, null, 50);
    return (await database.rows(
      'EXPLAIN QUERY PLAN ${compiled.$1}',
      compiled.$2,
    )).map((r) => r.read<String>('detail')).toList();
  }
}
