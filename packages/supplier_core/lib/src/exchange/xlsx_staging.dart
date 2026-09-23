import 'dart:convert';
import 'package:drift/drift.dart';
import '../contracts.dart';
import 'business_mapping.dart';

/// A separate, disposable database: never share its executor with business data.
/// A failed/incomplete read is quarantined; consumers can page only a ready run.
final class XlsxStaging extends GeneratedDatabase {
  XlsxStaging(super.executor);
  @override
  int get schemaVersion => 1;
  @override
  Iterable<TableInfo<Table, Object?>> get allTables => const [];
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => const [];
  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (_) async {
      for (final sql in [
        'CREATE TABLE parse_state(singleton INTEGER PRIMARY KEY CHECK(singleton=1),state TEXT NOT NULL,profile TEXT)',
        "INSERT INTO parse_state VALUES(1,'empty',NULL)",
        'CREATE TABLE shared_string(id INTEGER PRIMARY KEY,value TEXT NOT NULL)',
        'CREATE TABLE sheet_row(row_number INTEGER PRIMARY KEY,cell_count INTEGER NOT NULL)',
        'CREATE TABLE sheet_cell(row_number INTEGER NOT NULL,column_number INTEGER NOT NULL,coordinate TEXT NOT NULL,kind TEXT NOT NULL,lexical TEXT NOT NULL,raw_type TEXT NOT NULL,style INTEGER,formula TEXT,PRIMARY KEY(row_number,column_number))',
      ]) {
        await customStatement(sql);
      }
    },
  );
  Future<List<QueryRow>> _rows(String sql, [List<Object> values = const []]) =>
      customSelect(
        sql,
        variables: values.map((v) => Variable(v)).toList(),
      ).get();

  Future<void> begin() async {
    if ((await _rows(
          'SELECT state FROM parse_state',
        )).single.read<String>('state') !=
        'empty') {
      throw StateError(
        'Use a fresh isolated staging database for each attempt',
      );
    }
    await customStatement("UPDATE parse_state SET state='parsing'");
  }

  Future<void> fail() =>
      customStatement("UPDATE parse_state SET state='failed',profile=NULL");
  Future<void> finish(Map<String, Object?> profile) => customStatement(
    "UPDATE parse_state SET state='ready',profile=?",
    [jsonEncode(profile)],
  );
  Future<void> putString(int id, String value) =>
      customStatement('INSERT INTO shared_string VALUES(?,?)', [id, value]);
  Future<String> stringAt(int id) async {
    final rows = await _rows('SELECT value FROM shared_string WHERE id=?', [
      id,
    ]);
    if (rows.isEmpty) {
      throw DomainFailure('INVALID_XLSX', 'Unknown shared string $id');
    }
    return rows.single.read<String>('value');
  }

  Future<void> putRow(int row, int cells) =>
      customStatement('INSERT INTO sheet_row VALUES(?,?)', [row, cells]);
  Future<void> putCell(
    int row,
    int column,
    RawBusinessCell cell,
    String rawType,
    int? style,
  ) => customStatement('INSERT INTO sheet_cell VALUES(?,?,?,?,?,?,?,?)', [
    row,
    column,
    cell.coordinate,
    cell.kind.name,
    cell.lexical,
    rawType,
    style,
    cell.formula,
  ]);
  Future<void> _ready() async {
    if ((await _rows(
          'SELECT state FROM parse_state',
        )).single.read<String>('state') !=
        'ready') {
      throw StateError('Parsed volume has not passed all validation');
    }
  }

  Future<Map<String, Object?>> profile() async {
    await _ready();
    return (jsonDecode(
              (await _rows(
                'SELECT profile FROM parse_state',
              )).single.read<String>('profile'),
            )
            as Map)
        .cast<String, Object?>();
  }

  /// Row metadata is separate from cell pages; a wide row cannot inflate a page.
  Future<List<({int row, int cells})>> rowsPage({
    int afterRow = 0,
    int limit = 50,
  }) async {
    _limit(limit);
    await _ready();
    return (await _rows(
          'SELECT * FROM sheet_row WHERE row_number>? ORDER BY row_number LIMIT ?',
          [afterRow, limit],
        ))
        .map(
          (r) => (
            row: r.read<int>('row_number'),
            cells: r.read<int>('cell_count'),
          ),
        )
        .toList();
  }

  Future<List<StagedXlsxCell>> cellsPage(
    int row, {
    int afterColumn = 0,
    int limit = 32,
  }) async {
    _limit(limit);
    await _ready();
    return (await _rows(
          'SELECT * FROM sheet_cell WHERE row_number=? AND column_number>? ORDER BY column_number LIMIT ?',
          [row, afterColumn, limit],
        ))
        .map(
          (r) => StagedXlsxCell(
            r.read<int>('column_number'),
            RawBusinessCell(
              coordinate: r.read<String>('coordinate'),
              kind: BusinessCellKind.values.byName(r.read<String>('kind')),
              lexical: r.read<String>('lexical'),
              formula: r.readNullable<String>('formula'),
            ),
            r.read<String>('raw_type'),
            r.readNullable<int>('style'),
          ),
        )
        .toList();
  }
}

final class StagedXlsxCell {
  const StagedXlsxCell(this.column, this.cell, this.rawType, this.styleIndex);
  final int column;
  final RawBusinessCell cell;
  final String rawType;
  final int? styleIndex;
}

void _limit(int limit) {
  if (limit < 1 || limit > 200) throw RangeError.range(limit, 1, 200, 'limit');
}
