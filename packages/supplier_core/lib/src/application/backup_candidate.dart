import 'dart:convert';
import 'package:drift/drift.dart';
import '../contracts.dart';
import '../data/commit_coordinator.dart';
import '../data/database.dart';
import '../domain/revision.dart';
import '../exchange/backup_format.dart';
import '../exchange/import_receipts.dart' show validateImportResultPayload;

/// Builds an exclusively owned, isolated empty database. Never activates it.
/// On any failure the caller must discard the candidate, including its file.
/// The supplied lock belongs to this candidate, not the active installation.
final class BackupCandidateBuilder {
  BackupCandidateBuilder({required this.database, required this.writeLock});
  final SupplierDatabase database;
  final ApplicationWriteLock writeLock;

  Future<BackupSummary> build(InputSource source) async {
    final initial = await database.currentVersion();
    if (initial.activeEpoch != 0 || initial.generation != 0) {
      throw const DomainFailure(
        'CANDIDATE_NOT_EMPTY',
        'Expected a fresh candidate',
      );
    }
    for (final table in SupplierDatabase.requiredTableNamesForVersion(
      database.storageVersion,
    )) {
      if (table == 'database_meta') continue;
      if ((await database.rows('SELECT 1 FROM $table LIMIT 1')).isNotEmpty) {
        throw const DomainFailure(
          'CANDIDATE_NOT_EMPTY',
          'Expected an empty candidate',
        );
      }
    }
    // Persisted work prevents accidentally treating an interrupted build as new.
    await database.customStatement(
      'CREATE TABLE backup_candidate_work(table_name TEXT NOT NULL,row_key TEXT NOT NULL,row_json TEXT NOT NULL,PRIMARY KEY(table_name,row_key))',
    );
    final jobId = newStorageId(), eventId = newStorageId();
    late BackupSummary summary;
    await writeLock.run(
      () => database.transaction(() async {
        await database.createJob(jobId);
        summary = await decodeBackup(
          source,
          onHeader: (header) async {
            if (database.storageVersion == 2 && header.backupVersion != 1) {
              throw const DomainFailure(
                'UNSUPPORTED_FORMAT',
                'Physical v2 candidate only accepts backup v1',
              );
            }
            if (header.version.instanceId == initial.instanceId) {
              throw const DomainFailure(
                'CANDIDATE_IDENTITY',
                'Candidate must have a new instance identity',
              );
            }
          },
          onEntry: (entry) async {
            if (entry.table == 'revision') {
              await database.appendStaging(
                jobId,
                RevisionEnvelope.fromCanonicalJson(
                  entry.row['canonical']! as String,
                ),
              );
            } else {
              await database.customStatement(
                'INSERT INTO backup_candidate_work VALUES(?,?,?)',
                [
                  entry.table,
                  jsonEncode(
                    backupTableKeys[entry.table]!
                        .map((key) => entry.row[key])
                        .toList(),
                  ),
                  jsonEncode(entry.row),
                ],
              );
            }
          },
        );
      }),
    );
    final token = await database.sealJob(jobId, summary.digest);
    await database.registerConfirmation(eventId, token);
    await CommitCoordinator(
      database: database,
      writeLock: writeLock,
      readActiveVersion: database.currentVersion,
    ).commitStaged(
      jobId: jobId,
      expectedPreviewToken: token,
      confirmationEventId: eventId,
    );
    await writeLock.run(
      () => database.transaction(() async {
        await database.cleanupStaging(jobId);
        for (final table in [
          'receipt_result',
          'commit_receipt',
          'confirmation_event',
        ]) {
          await database.customStatement(
            'DELETE FROM $table WHERE event_id=?',
            [eventId],
          );
        }
        await database.customStatement(
          'DELETE FROM import_job WHERE job_id=?',
          [jobId],
        );
        for (final table in summary.header.tableKeys.keys.where(
          (key) => key != 'revision',
        )) {
          String after = '';
          while (true) {
            final rows = await database.rows(
              'SELECT row_key,row_json FROM backup_candidate_work WHERE table_name=? AND row_key>? ORDER BY row_key LIMIT 32',
              [Variable(table), Variable(after)],
            );
            if (rows.isEmpty) break;
            final columns = summary.header.tableColumns[table]!;
            for (final row in rows) {
              final values =
                  jsonDecode(row.read<String>('row_json'))
                      as Map<String, dynamic>;
              await database.customStatement(
                'INSERT INTO $table(${columns.join(',')}) VALUES(${List.filled(columns.length, '?').join(',')})',
                columns.map((key) => values[key]).toList(),
              );
            }
            after = rows.last.read<String>('row_key');
          }
        }
        for (final table in summary.header.tableKeys.keys) {
          final count = (await database.rows(
            'SELECT COUNT(*) n FROM $table',
          )).single.read<int>('n');
          if (count != summary.header.counts[table]) {
            throw const DomainFailure(
              'CORRUPT_BACKUP',
              'Restored row count differs',
            );
          }
        }
        final invalid = await database.rows(
          '''SELECT 1 FROM commit_receipt r JOIN confirmation_event e ON e.event_id=r.event_id
WHERE r.result_count<>(SELECT COUNT(*) FROM receipt_result x WHERE x.event_id=r.event_id)
OR r.instance_id<>e.instance_id OR r.active_epoch<>e.active_epoch OR r.generation<>e.generation+1
UNION ALL SELECT 1 FROM confirmation_event e WHERE NOT EXISTS(SELECT 1 FROM commit_receipt r WHERE r.event_id=e.event_id)
UNION ALL SELECT 1 FROM import_job j WHERE NOT EXISTS(SELECT 1 FROM confirmation_event e WHERE e.job_id=j.job_id)
UNION ALL SELECT 1 FROM confirmation_event e JOIN import_job j ON j.job_id=e.job_id WHERE e.sealed_digest<>j.sealed_digest OR e.decisions_digest<>j.decisions_digest
UNION ALL SELECT 1 FROM import_row_receipt x WHERE NOT EXISTS(SELECT 1 FROM receipt_result r WHERE r.event_id=x.event_id AND r.revision_id=x.result_revision_id) LIMIT 1''',
        );
        if (summary.header.backupVersion == 2 &&
            (await database.rows(
              "SELECT 1 FROM import_decision_receipt d WHERE NOT EXISTS(SELECT 1 FROM commit_receipt c WHERE c.event_id=d.event_id) OR json_extract(d.operation_canonical,'\$.confirmed_quantity')<>(SELECT COUNT(*) FROM import_row_receipt r WHERE r.event_id=d.event_id AND r.source_fingerprint=d.source_fingerprint AND r.operation_fingerprint=d.operation_fingerprint) OR json_extract(d.operation_canonical,'\$.confirmed_quantity')<>(SELECT COUNT(DISTINCT v.entity_id) FROM import_row_receipt r JOIN revision v ON v.revision_id=r.result_revision_id WHERE v.entity_type='quotation' AND r.event_id=d.event_id AND r.source_fingerprint=d.source_fingerprint AND r.operation_fingerprint=d.operation_fingerprint AND r.fingerprint_version=d.fingerprint_version AND r.original_target_id=d.original_target_id) UNION ALL SELECT 1 FROM import_row_receipt r JOIN import_decision_receipt d ON d.event_id=r.event_id AND d.source_fingerprint=r.source_fingerprint AND d.operation_fingerprint=r.operation_fingerprint WHERE d.original_target_id<>r.original_target_id OR d.fingerprint_version<>r.fingerprint_version LIMIT 1",
            )).isNotEmpty) {
          throw const DomainFailure(
            'CORRUPT_BACKUP',
            'Decision receipt result mismatch',
          );
        }
        if (summary.header.backupVersion == 2) {
          final incompatible = await database.rows(
            "SELECT 1 FROM import_decision_receipt d JOIN import_row_receipt r ON r.event_id=d.event_id AND r.source_fingerprint=d.source_fingerprint AND r.operation_fingerprint=d.operation_fingerprint JOIN revision v ON v.revision_id=r.result_revision_id WHERE (json_extract(d.operation_canonical,'\$.intent')='newInquiry' AND (json_extract(v.canonical,'\$.payload.capture_mode')<>'standard' OR json_array_length(v.canonical,'\$.parents')<>0)) OR (json_extract(d.operation_canonical,'\$.intent')='modify' AND (json_array_length(v.canonical,'\$.parents')=0 OR v.entity_id<>d.original_target_id)) LIMIT 1",
          );
          final reused = await database.rows(
            "SELECT 1 FROM import_decision_receipt d JOIN import_row_receipt r ON r.event_id=d.event_id AND r.source_fingerprint=d.source_fingerprint AND r.operation_fingerprint=d.operation_fingerprint JOIN revision v ON v.revision_id=r.result_revision_id GROUP BY d.event_id,v.entity_id HAVING COUNT(*)>1 LIMIT 1",
          );
          if (incompatible.isNotEmpty || reused.isNotEmpty) {
            throw const DomainFailure(
              'CORRUPT_BACKUP',
              'Decision intent or main result ownership differs',
            );
          }
        }
        if (summary.header.backupVersion == 2) {
          List<String>? cursor;
          while (true) {
            final rows = await database.rows(
              "SELECT d.event_id,d.source_fingerprint,d.operation_fingerprint,d.operation_canonical,d.original_target_id,r.result_revision_id,v.canonical FROM import_decision_receipt d JOIN import_row_receipt r ON r.event_id=d.event_id AND r.source_fingerprint=d.source_fingerprint AND r.operation_fingerprint=d.operation_fingerprint JOIN revision v ON v.revision_id=r.result_revision_id ${cursor == null ? '' : 'WHERE (d.event_id,d.source_fingerprint,d.operation_fingerprint,r.result_revision_id)>(?,?,?,?)'} ORDER BY d.event_id,d.source_fingerprint,d.operation_fingerprint,r.result_revision_id LIMIT 32",
              [
                if (cursor != null)
                  for (final value in cursor) Variable(value),
              ],
            );
            if (rows.isEmpty) {
              break;
            }
            for (final row in rows) {
              final revision = RevisionEnvelope.fromCanonicalJson(
                row.read<String>('canonical'),
              );
              final operation =
                  jsonDecode(row.read<String>('operation_canonical'))
                      as Map<String, Object?>;
              final baseline =
                  operation['intent'] == 'modify' &&
                      revision.parents.length == 1
                  ? await database.findRevision(revision.parents.single)
                  : null;
              validateImportResultPayload(
                revision,
                operation,
                originalTargetId: row.read<String>('original_target_id'),
                baseline: baseline,
              );
            }
            cursor = [
              for (final key in [
                'event_id',
                'source_fingerprint',
                'operation_fingerprint',
                'result_revision_id',
              ])
                rows.last.read<String>(key),
            ];
          }
        }
        final futureReceipt = await database.rows(
          'SELECT 1 FROM commit_receipt WHERE instance_id=? AND generation>? LIMIT 1',
          [
            Variable(summary.header.version.instanceId),
            Variable(summary.header.version.generation),
          ],
        );
        if (futureReceipt.isNotEmpty ||
            invalid.isNotEmpty ||
            (await database.rows(
              'SELECT 1 FROM pragma_foreign_key_check LIMIT 1',
            )).isNotEmpty) {
          throw const DomainFailure(
            'CORRUPT_BACKUP',
            'Restored receipt or foreign key mismatch',
          );
        }
        await database.customStatement(
          'UPDATE database_meta SET generation=? WHERE singleton=1',
          [summary.header.version.generation],
        );
        await database.customStatement('DROP TABLE backup_candidate_work');
      }),
    );
    return summary;
  }
}
