import 'dart:convert';
import 'package:drift/drift.dart';
import 'model.dart';

class ProbeDatabase extends GeneratedDatabase {
  ProbeDatabase(super.executor, {this.persistent = true});
  final bool persistent;
  @override
  int get schemaVersion => 2;
  @override
  Iterable<TableInfo> get allTables => [];
  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) => transaction(() async {
      for (final table in columns.keys) {
        final definitions = columns[table]!.map((key) {
          var definition =
              '"$key" ${integerFields.contains(key) ? 'INTEGER' : 'TEXT'}';
          if (key == 'id') definition += ' PRIMARY KEY NOT NULL';
          if (key == 'supplier_id') {
            definition += ' NOT NULL REFERENCES suppliers(id)';
          }
          if (key == 'product_id') {
            definition += ' NOT NULL REFERENCES products(id)';
          }
          if (key == 'contact_id') definition += ' REFERENCES contacts(id)';
          return definition;
        }).toList();
        if (table == 'quotations') definitions.add('price_key TEXT NOT NULL');
        await customStatement('CREATE TABLE $table (${definitions.join(',')})');
      }
      await customStatement(
        'CREATE INDEX quotation_price ON quotations(currency,tax_mode,unit_snapshot,price_key)',
      );
      await customStatement('PRAGMA user_version = 2');
    }),
    onUpgrade: (m, from, to) => transaction(() async {
      if (from != 1 || to != 2) {
        throw StateError('Unsupported database migration $from → $to');
      }
      for (final key in contextFields) {
        await customStatement(
          'ALTER TABLE quotations ADD COLUMN "$key" ${integerFields.contains(key) ? 'INTEGER' : 'TEXT'}',
        );
      }
      await customStatement('PRAGMA user_version = 2');
    }),
    beforeOpen: (_) async {
      await customStatement('PRAGMA foreign_keys = ON');
      final enabled = await customSelect('PRAGMA foreign_keys').getSingle();
      if (enabled.read<int>('foreign_keys') != 1) {
        throw StateError('Foreign keys unavailable');
      }
    },
  );

  Future<Snapshot> snapshot() => transaction(() async {
    final result = <String, List<Row>>{};
    for (final table in columns.keys) {
      final rows = await customSelect(
        'SELECT ${columns[table]!.map((k) => '"$k"').join(',')} FROM $table ORDER BY id',
      ).get();
      result[table] = rows
          .map(
            (r) => {
              for (final key in columns[table]!)
                key: jsonFields.contains(key) && r.data[key] != null
                    ? jsonDecode(r.data[key] as String)
                    : r.data[key],
            },
          )
          .toList();
    }
    return normalizeSnapshot(result);
  });

  Future<void> restore(Snapshot data, {int? failAfterRows}) async {
    if (!persistent) {
      throw StateError('Memory fallback: business writes disabled');
    }
    final valid = normalizeSnapshot(data);
    await transaction(() async {
      for (final table in columns.keys) {
        final count = await customSelect(
          'SELECT COUNT(*) AS n FROM $table',
        ).getSingle();
        if (count.read<int>('n') != 0) {
          throw StateError('Restore requires an empty database');
        }
      }
      var written = 0;
      for (final table in columns.keys) {
        for (final row in valid[table]!) {
          final keys = [
            ...columns[table]!,
            if (table == 'quotations') 'price_key',
          ];
          final values = keys
              .map(
                (k) => k == 'price_key'
                    ? priceKey(row['price'] as String)
                    : jsonFields.contains(k) && row[k] != null
                    ? jsonEncode(row[k])
                    : row[k],
              )
              .toList();
          await customStatement(
            'INSERT INTO $table (${keys.map((k) => '"$k"').join(',')}) VALUES (${List.filled(keys.length, '?').join(',')})',
            values,
          );
          written++;
          if (written == failAfterRows) {
            throw StateError('Injected restore failure after $written rows');
          }
        }
      }
    });
  }
}
