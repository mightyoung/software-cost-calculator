import 'package:drift/drift.dart';
import '../contracts.dart';
import '../data/database.dart';
import '../exchange/backup_format.dart';

/// Private temporary file with repeatable range input after output publication.
/// Implementations own their paths/handles and dispose only their own artifacts.
abstract interface class BackupArtifact {
  InputSource get source;
  OutputTarget get output;
  Future<void> dispose();
}

/// Freezes edits for a read transaction while generating a private logical
/// snapshot. Validation and external publication then read that frozen file,
/// never the live database. Restoration is provided by the candidate coordinator.
final class BackupService {
  BackupService({
    required this.database,
    required this.writeLock,
    required this.readActiveVersion,
    required this.createArtifact,
  });
  final SupplierDatabase database;
  final ApplicationWriteLock writeLock;
  final Future<DatabaseVersion> Function() readActiveVersion;
  final Future<BackupArtifact> Function() createArtifact;

  Future<BackupSummary> create(
    OutputTarget target, {
    ApplicationWriteContext? context,
  }) async {
    context?.requireHeld(writeLock);
    BackupArtifact? artifact;
    Object? primary;
    StackTrace? primaryStack;
    BackupSummary? result;
    var published = false;
    try {
      artifact = await createArtifact();
      final snapshotArtifact = artifact;
      Future<void> snapshot() async {
        context?.requireHeld(writeLock);
        final active = await readActiveVersion();
        final current = await database.currentVersion();
        if (!sameVersion(active, current)) {
          throw const DomainFailure(
            'STALE_PREVIEW',
            'Active database changed before backup',
          );
        }
        await database.transaction(() async {
          final version = await database.currentVersion();
          if (!sameVersion(current, version)) {
            throw const DomainFailure(
              'STALE_PREVIEW',
              'Database changed before snapshot',
            );
          }
          final counts = <String, int>{};
          for (final table in backupTableKeysForVersion(
            database.storageVersion == 2 ? 1 : 2,
          ).keys) {
            counts[table] = (await database.rows(
              'SELECT COUNT(*) n FROM $table WHERE ${_filter(table)}',
            )).single.read<int>('n');
          }
          final header = BackupHeader(
            version: version,
            counts: counts,
            backupVersion: database.storageVersion == 2 ? 1 : 2,
          );
          await snapshotArtifact.output.write(encodeBackup(header, _entries()));
          if (!sameVersion(version, await database.currentVersion())) {
            throw const DomainFailure(
              'BACKUP_CHANGED',
              'Snapshot version changed',
            );
          }
        });
      }

      if (context == null) {
        await writeLock.run(snapshot);
      } else {
        await snapshot();
      }
      await artifact.output.publish();
      result = await decodeBackup(artifact.source);
      await target.write(_copy(artifact.source));
      await target.publish();
      published = true;
      return result;
    } catch (error, stack) {
      primary = error;
      primaryStack = stack;
      if (!published) {
        try {
          await target.abort();
        } catch (cleanup, cleanupStack) {
          final combined = DomainFailure(
            'backup_cleanup_failed',
            'Backup failed and output cleanup also failed',
            cause: (
              primary: error,
              primaryStack: stack,
              cleanup: cleanup,
              cleanupStack: cleanupStack,
            ),
          );
          primary = combined;
          primaryStack = StackTrace.current;
          Error.throwWithStackTrace(combined, primaryStack);
        }
      }
      rethrow;
    } finally {
      try {
        await artifact?.dispose();
      } catch (cleanup, cleanupStack) {
        throw DomainFailure(
          'backup_cleanup_failed',
          'Private backup cleanup failed',
          cause: (
            primary: primary,
            primaryStack: primaryStack,
            cleanup: cleanup,
            cleanupStack: cleanupStack,
            published: published,
            summary: result,
          ),
        );
      }
    }
  }

  Stream<BackupEntry> _entries() async* {
    for (final table in backupTableKeysForVersion(
      database.storageVersion == 2 ? 1 : 2,
    ).keys) {
      final keys = backupTableKeysForVersion(
        database.storageVersion == 2 ? 1 : 2,
      )[table]!;
      final columns = backupTableColumnsForVersion(
        database.storageVersion == 2 ? 1 : 2,
      )[table]!;
      final filter = _filter(table);
      // octet_length(column) reads the length from SQLite metadata, avoiding
      // materialization of a maliciously large preference value before rejection.
      // https://www.sqlite.org/lang_corefunc.html#octet_length
      final size = columns.map((c) => 'COALESCE(octet_length($c),0)').join('+');
      if ((await database.rows(
        'SELECT 1 FROM $table WHERE ($filter) AND ($size)>? LIMIT 1',
        [Variable(maxBackupLineBytes)],
      )).isNotEmpty) {
        throw const DomainFailure(
          'BACKUP_ROW_LIMIT',
          'Stored backup row exceeds the format limit',
        );
      }
      List<String>? cursor;
      while (true) {
        final seek = cursor == null
            ? ''
            : ' AND (${keys.join(',')})>(${List.filled(keys.length, '?').join(',')})';
        final rows = await database.rows(
          'SELECT ${columns.join(',')} FROM $table WHERE ($filter)$seek ORDER BY ${keys.join(',')} LIMIT 32',
          [
            if (cursor != null)
              for (final value in cursor) Variable(value),
          ],
        );
        if (rows.isEmpty) break;
        for (final row in rows) {
          yield BackupEntry(
            table,
            row.data,
            backupVersion: database.storageVersion == 2 ? 1 : 2,
          );
        }
        cursor = keys.map((key) => rows.last.read<String>(key)).toList();
        if (rows.length < 32) break;
      }
    }
  }
}

String _filter(String table) => switch (table) {
  'import_job' =>
    "state='committed' AND EXISTS(SELECT 1 FROM confirmation_event e JOIN commit_receipt r ON r.event_id=e.event_id WHERE e.job_id=import_job.job_id)",
  'confirmation_event' =>
    'EXISTS(SELECT 1 FROM commit_receipt r WHERE r.event_id=confirmation_event.event_id)',
  'receipt_result' =>
    'EXISTS(SELECT 1 FROM commit_receipt r WHERE r.event_id=receipt_result.event_id)',
  'import_decision_receipt' =>
    'EXISTS(SELECT 1 FROM commit_receipt r WHERE r.event_id=import_decision_receipt.event_id)',
  'import_row_receipt' =>
    'EXISTS(SELECT 1 FROM commit_receipt r WHERE r.event_id=import_row_receipt.event_id)',
  _ => '1=1',
};

Stream<List<int>> _copy(InputSource source) async* {
  final length = await source.length();
  for (var start = 0; start < length; start += 65536) {
    final end = (start + 65536).clamp(0, length);
    var read = 0;
    await for (final chunk in source.openRange(start, end)) {
      read += chunk.length;
      if (read > end - start) {
        throw const DomainFailure('IO_FAILURE', 'Backup source exceeded range');
      }
      yield chunk;
    }
    if (read != end - start) {
      throw const DomainFailure('IO_FAILURE', 'Backup source truncated');
    }
  }
}
