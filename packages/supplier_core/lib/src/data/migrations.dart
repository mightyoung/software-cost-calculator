import 'database.dart';
import '../contracts.dart';
import 'tables.dart';
import '../domain/values.dart';
import 'package:drift/drift.dart';

/// Caller has already verified a durable backup while holding this same lock.
/// After migration close this physical-v2 handle and reopen with storageVersion 3.
Future<DatabaseVersion> migrateStorageV2ToV3(
  SupplierDatabase database, {
  required DatabaseVersion expectedVersion,
  required ApplicationWriteContext context,
  required ApplicationWriteLock writeLock,
}) async {
  context.requireHeld(writeLock);
  return database.transaction(() async {
    context.requireHeld(writeLock);
    final current = await database.currentVersion();
    requireSafeInteger(current.generation, 'generation', min: 0);
    final physical = (await database.rows(
      'PRAGMA user_version',
    )).single.read<int>('user_version');
    if (physical == 3 &&
        current.instanceId == expectedVersion.instanceId &&
        current.activeEpoch == expectedVersion.activeEpoch &&
        (current.generation == expectedVersion.generation ||
            current.generation == expectedVersion.generation + 1)) {
      await _checkV3Structure(database);
      await checkStorageIntegrity(database);
      return current;
    }
    if (physical != 2 || !sameVersion(current, expectedVersion)) {
      throw const DomainFailure('STALE_PREVIEW', 'Migration version changed');
    }
    requireSafeInteger(current.generation + 1, 'generation', min: 0);
    for (final sql in storageV3Statements) {
      await database.customStatement(sql);
    }
    await database.customStatement(
      'UPDATE database_meta SET generation=generation+1 WHERE singleton=1',
    );
    await database.customStatement('PRAGMA user_version=3');
    await _checkV3Structure(database);
    await checkStorageIntegrity(database);
    return database.currentVersion();
  });
}

Future<void> _checkV3Structure(SupplierDatabase database) async {
  final pattern = RegExp(r'^CREATE (?:UNIQUE )?(TABLE|INDEX|TRIGGER) (\w+)');
  for (final sql in schemaStatementsForVersion(3)) {
    final match = pattern.firstMatch(sql)!;
    final rows = await database.rows(
      'SELECT sql FROM sqlite_master WHERE type=? AND name=?',
      [Variable(match.group(1)!.toLowerCase()), Variable(match.group(2)!)],
    );
    if (rows.length != 1 || rows.single.data['sql'] != sql) {
      throw const DomainFailure('CORRUPT_STORAGE', 'Migration schema differs');
    }
  }
}

/// Schema-1 import requires a separately verified migration specification.
/// SupplierDatabase rejects upgrades before touching existing authority rows.
/// This check can also be used before publishing a separately prepared database;
/// it is structural only and does not replace T4's complete graph validation.
Future<void> checkStorageIntegrity(SupplierDatabase database) async {
  final rows = await database.rows('PRAGMA integrity_check');
  if (rows.length != 1 ||
      rows.single.data.values.single != 'ok' ||
      (await database.rows('PRAGMA foreign_key_check')).isNotEmpty) {
    throw StateError('Database integrity failure');
  }
  await database.currentVersion();
}
