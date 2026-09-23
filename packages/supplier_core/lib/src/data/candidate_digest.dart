import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';
import '../contracts.dart';
import 'database.dart';

/// Logical content binding for an isolated candidate. The only ignored value is
/// its activation epoch, which the host changes during pointer publication.
/// Includes authority, projections, settings, receipts and schema work tables.
Future<String> candidateContentDigest(SupplierDatabase database) =>
    database.transaction(
      () async => (await sha256.bind(_content(database)).single).toString(),
    );

Stream<List<int>> _content(SupplierDatabase database) async* {
  yield utf8.encode('supplier-candidate-content-v1\n');
  final userVersion = (await database.rows(
    'PRAGMA user_version',
  )).single.read<int>('user_version');
  if (userVersion != database.schemaVersion) {
    throw const DomainFailure(
      'CORRUPT_CANDIDATE',
      'Candidate schema version differs',
    );
  }
  yield utf8.encode('${jsonEncode(['user_version', userVersion])}\n');
  // Bind definitions too: data equality cannot excuse removed constraints,
  // changed triggers or indexes. Schema text is hashed, never executed.
  const schemaFilter = "substr(name,1,7)<>'sqlite_'";
  final schemaCount = (await database.rows(
    'SELECT COUNT(*) n FROM sqlite_master WHERE $schemaFilter',
  )).single.read<int>('n');
  if (schemaCount > 1024 ||
      (await database.rows(
        'SELECT 1 FROM sqlite_master WHERE $schemaFilter AND COALESCE(octet_length(sql),0)+octet_length(name)+octet_length(tbl_name)>? LIMIT 1',
        [Variable(512 * 1024)],
      )).isNotEmpty) {
    throw const DomainFailure(
      'CORRUPT_CANDIDATE',
      'Candidate schema exceeds limits',
    );
  }
  String? schemaType, schemaName;
  while (true) {
    final seek = schemaType == null ? '' : ' AND (type,name)>(?,?)';
    final definitions = await database.rows(
      'SELECT type,name,tbl_name,sql FROM sqlite_master WHERE $schemaFilter$seek ORDER BY type,name LIMIT 32',
      [
        if (schemaType != null) Variable(schemaType),
        if (schemaName != null) Variable(schemaName),
      ],
    );
    if (definitions.isEmpty) break;
    for (final row in definitions) {
      if (row.read<String>('type') == 'table' &&
          !SupplierDatabase.requiredTableNamesForVersion(
            database.storageVersion,
          ).contains(row.read<String>('name'))) {
        throw const DomainFailure(
          'CORRUPT_CANDIDATE',
          'Unexpected candidate table',
        );
      }
      yield utf8.encode(
        '${jsonEncode(['schema', row.data['type'], row.data['name'], row.data['tbl_name'], row.data['sql']])}\n',
      );
    }
    schemaType = definitions.last.read<String>('type');
    schemaName = definitions.last.read<String>('name');
  }
  final tables = SupplierDatabase.requiredTableNamesForVersion(
    database.storageVersion,
  ).toList()..sort();
  for (final table in tables) {
    final metadata = await database.rows(
      'PRAGMA table_info(${_identifier(table)})',
    );
    if (metadata.isEmpty) {
      throw const DomainFailure('CORRUPT_CANDIDATE', 'Missing candidate table');
    }
    final columns = metadata.map((row) => row.read<String>('name')).toList()
      ..sort();
    final primary = metadata.where((row) => row.read<int>('pk') > 0).toList()
      ..sort((a, b) => a.read<int>('pk').compareTo(b.read<int>('pk')));
    final keys = primary.map((row) => row.read<String>('name')).toList();
    if (keys.isEmpty) {
      throw const DomainFailure(
        'CORRUPT_CANDIDATE',
        'Candidate table needs a primary key',
      );
    }
    final size = columns
        .map((column) => 'COALESCE(octet_length(${_identifier(column)}),0)')
        .join('+');
    final nullKey = keys
        .map((key) => '${_identifier(key)} IS NULL')
        .join(' OR ');
    if ((await database.rows(
      'SELECT 1 FROM ${_identifier(table)} WHERE ($size)>? OR ($nullKey) LIMIT 1',
      [Variable(512 * 1024)],
    )).isNotEmpty) {
      throw const DomainFailure(
        'CORRUPT_CANDIDATE',
        'Candidate row is oversized or has a null primary key',
      );
    }
    yield utf8.encode('${jsonEncode([table, columns, keys])}\n');
    List<Object>? cursor;
    final keySql = keys.map(_identifier).join(',');
    while (true) {
      final seek = cursor == null
          ? ''
          : ' WHERE ($keySql)>(${List.filled(keys.length, '?').join(',')})';
      final rows = await database.rows(
        'SELECT ${columns.map(_identifier).join(',')} FROM ${_identifier(table)}$seek ORDER BY $keySql LIMIT 32',
        [
          if (cursor != null)
            for (final value in cursor)
              if (value is int) Variable(value) else Variable(value as String),
        ],
      );
      if (rows.isEmpty) break;
      for (final row in rows) {
        yield utf8.encode(
          '${jsonEncode([for (final column in columns)
            if (table == 'database_meta' && column == 'active_epoch') 0 else row.data[column]])}\n',
        );
      }
      cursor = keys.map((key) => rows.last.data[key]! as Object).toList();
    }
  }
}

String _identifier(String value) => '"${value.replaceAll('"', '""')}"';
