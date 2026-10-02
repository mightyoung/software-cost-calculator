import 'dart:convert';
import 'dart:math';
import 'package:drift/drift.dart';
import '../contracts.dart';
import '../domain/revision_graph.dart';
import '../domain/quotation.dart';
import 'database.dart';
import 'graph_workspace.dart';
import '../query/search_keys.dart';
import '../exchange/import_receipts.dart';
part 'projection_writer.dart';

typedef CommitFault = Future<void> Function(String point);
String newStorageId() => List.generate(
  24,
  (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
).join();

// Neither the public diagnostic report nor UI-created token can construct this
// proof. It is created only from this coordinator's own real validator run.
class _ValidatedStage {
  _ValidatedStage(this.token, this.report, this.validatorVersion);
  final PreviewToken token;
  final GraphValidationReport report;
  final int validatorVersion;
}

class CommitCoordinator implements TransactionPort {
  CommitCoordinator({
    required this.database,
    required this.writeLock,
    required this.readActiveVersion,
    this.pageSize = 500,
    this.installPageSize,
    this.fault,
    this.graphPhaseObserver,
  });
  final SupplierDatabase database;
  final ApplicationWriteLock writeLock;

  /// Must read the independent active pointer without nesting another business
  /// transaction. The lock prevents pointer activation for this entire operation.
  final Future<DatabaseVersion> Function() readActiveVersion;
  final int pageSize;

  /// Optional independent bound for installing validated staged revisions.
  /// Keeping this separate lets large imports reduce install round trips
  /// without changing graph-validation or projection page sizes.
  final int? installPageSize;

  final CommitFault? fault;
  final void Function(String phase)? graphPhaseObserver;

  @override
  Future<CommitReceipt> commitStaged({
    required String jobId,
    required PreviewToken expectedPreviewToken,
    required String confirmationEventId,
    ApplicationWriteContext? context,
  }) async {
    context?.requireHeld(writeLock);
    checkLimit(pageSize);
    if (installPageSize != null) checkLimit(installPageSize!);
    Future<CommitReceipt> commit() async {
      final active = await readActiveVersion();
      final expected = expectedPreviewToken;
      if (active.instanceId != expected.version.instanceId ||
          active.activeEpoch != expected.version.activeEpoch) {
        throw const DomainFailure(
          'stale_active_database',
          'Active database changed',
        );
      }
      final connected = await database.currentVersion();
      if (connected.instanceId != active.instanceId ||
          connected.activeEpoch != active.activeEpoch) {
        throw const DomainFailure(
          'stale_active_database',
          'Connected database is inactive',
        );
      }
      await database.checkConfirmation(confirmationEventId, expected);
      if (jobId != expected.jobId) {
        throw const DomainFailure('confirmation_mismatch', 'Wrong job');
      }
      final previous = await findCommittedEvent(confirmationEventId);
      if (previous != null) return previous;
      await _checkToken(expected);
      final work = SqlGraphWorkspace(
        database,
        jobId: jobId,
        runId: newStorageId(),
        phaseObserver: graphPhaseObserver,
      );
      late final _ValidatedStage proof;
      try {
        final report = await database.transaction(
          () => RevisionGraphValidator(
            pageSize: pageSize,
            onPhase: graphPhaseObserver,
          ).validate(work),
        );
        proof = _ValidatedStage(expected, report, 1);
      } catch (primary, primaryStack) {
        try {
          await work.discardWork();
        } catch (cleanup, cleanupStack) {
          throw DomainFailure(
            'graph_cleanup_failed',
            'Validation failed and workspace cleanup failed',
            cause: (
              primary: primary,
              primaryStack: primaryStack,
              cleanup: cleanup,
              cleanupStack: cleanupStack,
              committedReceipt: null,
            ),
          );
        }
        Error.throwWithStackTrace(primary, primaryStack);
      }
      CommitReceipt? committedReceipt;
      Object? primaryFailure;
      StackTrace? primaryFailureStack;
      try {
        final receipt = await database.transaction(() async {
          final version = await database.currentVersion();
          if (version.instanceId != active.instanceId ||
              version.activeEpoch != active.activeEpoch) {
            throw const DomainFailure(
              'stale_active_database',
              'Connection is no longer active',
            );
          }
          await database.checkConfirmation(confirmationEventId, expected);
          if (jobId != expected.jobId) {
            throw const DomainFailure(
              'confirmation_mismatch',
              'Job differs from confirmation',
            );
          }
          final existing = await findCommittedEvent(confirmationEventId);
          if (existing != null) return existing;
          final job = await database.job(jobId);
          if (!expected.matches(
            version: version,
            jobId: jobId,
            sealedStagingDigest:
                job.readNullable<String>('sealed_digest') ?? '',
            decisionsDigest: job.readNullable<String>('decisions_digest') ?? '',
          )) {
            throw const DomainFailure(
              'stale_preview',
              'Preview no longer matches database and seal',
            );
          }
          await _checkToken(proof.token);
          if (proof.validatorVersion != 1 ||
              !proof.report.binding.sameAs(await work.currentBinding())) {
            throw const DomainFailure(
              'stale_validation',
              'Validation binding changed',
            );
          }
          await _checkExpectedHeads(jobId);
          final hasImportDecisions =
              database.storageVersion >= 3 &&
              (await database.rows(
                'SELECT 1 FROM staging_import_decision WHERE job_id=? LIMIT 1',
                [Variable(jobId)],
              )).isNotEmpty;
          final importReceipts = ImportReceiptStore(database);
          if (hasImportDecisions) {
            await importReceipts.validateStaged(jobId);
            if (await importReceipts.computeDecisionDigest(jobId) !=
                expected.decisionsDigest) {
              throw const DomainFailure(
                'stale_import_decisions',
                'Persisted import decisions differ from the confirmed preview',
              );
            }
          }
          await database.customStatement(
            'UPDATE import_job SET state=? WHERE job_id=?',
            [JobState.committing.name, jobId],
          );
          var count = 0;
          String? cursor;
          Future<void> installEdgesAndResults(List<String> args) async {
            const range = 's.job_id=? AND s.revision_id>? AND s.revision_id<=?';
            await database.customStatement(
              'INSERT INTO revision_parent SELECT s.revision_id,p.value '
              "FROM staging_revision s,json_each(s.canonical,'\$.parents') p "
              'WHERE $range ORDER BY s.revision_id,p.key '
              'ON CONFLICT(child_id,parent_id) DO NOTHING',
              args,
            );
            await database.customStatement(
              'INSERT INTO receipt_result SELECT ?,s.revision_id '
              'FROM staging_revision s WHERE $range ORDER BY s.revision_id',
              [confirmationEventId, ...args],
            );
          }

          do {
            final page = await database.stagingPage(
              jobId,
              after: cursor,
              limit: installPageSize ?? pageSize,
            );
            if (page.items.isNotEmpty) {
              // stagingPage above parses every canonical envelope. Use the same
              // sealed, bounded range for all writes inside this transaction.
              const range =
                  's.job_id=? AND s.revision_id>? AND s.revision_id<=?';
              final args = [jobId, cursor ?? '', page.items.last.revisionId];
              final collision = await database.rows(
                'SELECT 1 FROM staging_revision s JOIN revision r '
                'ON r.revision_id=s.revision_id WHERE $range '
                'AND r.canonical<>s.canonical LIMIT 1',
                args.map(Variable.new).toList(),
              );
              if (collision.isNotEmpty) {
                throw const DomainFailure(
                  'revision_collision',
                  'Revision ID collision',
                );
              }
              await database.customStatement(
                'INSERT INTO entity_identity SELECT '
                "json_extract(s.canonical,'\$.entity_type'),"
                "json_extract(s.canonical,'\$.entity_id') "
                'FROM staging_revision s WHERE $range ORDER BY s.revision_id '
                'ON CONFLICT(entity_type,entity_id) DO NOTHING',
                args,
              );
              await database.customStatement(
                'INSERT INTO revision SELECT s.revision_id,'
                "json_extract(s.canonical,'\$.entity_type'),"
                "json_extract(s.canonical,'\$.entity_id'),s.canonical "
                'FROM staging_revision s WHERE $range ORDER BY s.revision_id '
                'ON CONFLICT(revision_id) DO NOTHING',
                args,
              );
              await installEdgesAndResults(args);
            }
            count += page.items.length;
            cursor = page.nextCursor;
            await fault?.call('page:$count');
          } while (cursor != null);
          if (hasImportDecisions) {
            await importReceipts.copyAppliedToReceipt(
              jobId,
              confirmationEventId,
            );
          }
          graphPhaseObserver?.call('projection_install_start');
          await _installGraphProjections(database, work, pageSize: pageSize);
          graphPhaseObserver?.call('projection_install_complete');
          // Explicit check handles deferred edges before metadata/receipt changes;
          // SQLite also rechecks deferred FKs at COMMIT.
          if ((await database.rows('PRAGMA foreign_key_check')).isNotEmpty) {
            throw const DomainFailure(
              'foreign_key_failure',
              'Revision closure is structurally incomplete',
            );
          }
          graphPhaseObserver?.call('foreign_key_check_complete');
          await database.customStatement(
            'UPDATE database_meta SET generation=generation+1 WHERE singleton=1',
          );
          final result = await database.currentVersion();
          await database
              .customStatement('INSERT INTO commit_receipt VALUES(?,?,?,?,?)', [
                confirmationEventId,
                result.instanceId,
                result.activeEpoch,
                result.generation,
                count,
              ]);
          await database.customStatement(
            'UPDATE import_job SET state=? WHERE job_id=?',
            [JobState.committed.name, jobId],
          );
          await fault?.call('before_commit');
          return CommitReceipt(
            confirmationEventId: confirmationEventId,
            version: result,
            resultCount: count,
            resultCursor: confirmationEventId,
          );
        });
        committedReceipt = receipt;
        await fault?.call('after_commit');
        return receipt;
      } catch (primary, stack) {
        primaryFailure = primary;
        primaryFailureStack = stack;
        rethrow;
      } finally {
        try {
          await work.discardWork();
        } catch (cleanup, cleanupStack) {
          throw DomainFailure(
            'graph_cleanup_failed',
            'Workspace cleanup failed; inspect committedReceipt before retry',
            cause: (
              primary: primaryFailure,
              primaryStack: primaryFailureStack,
              cleanup: cleanup,
              cleanupStack: cleanupStack,
              committedReceipt: committedReceipt,
            ),
          );
        }
      }
    }

    return context == null ? writeLock.run(commit) : commit();
  }

  Future<void> _checkToken(PreviewToken token) async {
    final row = await database.job(token.jobId);
    if (!['previewReady', 'committing'].contains(row.read<String>('state'))) {
      throw const DomainFailure(
        'job_terminal',
        'Job cannot be committed in its current state',
      );
    }
    if (!token.matches(
      version: await database.currentVersion(),
      jobId: token.jobId,
      sealedStagingDigest: row.readNullable<String>('sealed_digest') ?? '',
      decisionsDigest: row.readNullable<String>('decisions_digest') ?? '',
    )) {
      throw const DomainFailure('stale_preview', 'Preview changed');
    }
  }

  Future<void> _checkExpectedHeads(String jobId) async {
    final mismatch = await database.rows(
      "SELECT 1 FROM staging_expected_entity e WHERE e.job_id=? AND (EXISTS(SELECT revision_id FROM entity_head WHERE entity_type=e.entity_type AND entity_id=e.entity_id EXCEPT SELECT revision_id FROM staging_expected_head WHERE job_id=e.job_id AND entity_type=e.entity_type AND entity_id=e.entity_id) OR EXISTS(SELECT revision_id FROM staging_expected_head WHERE job_id=e.job_id AND entity_type=e.entity_type AND entity_id=e.entity_id EXCEPT SELECT revision_id FROM entity_head WHERE entity_type=e.entity_type AND entity_id=e.entity_id)) LIMIT 1",
      [Variable(jobId)],
    );
    if (mismatch.isNotEmpty) {
      throw const DomainFailure('stale_heads', 'Expected heads changed');
    }
  }

  @override
  Future<CommitReceipt?> findCommittedEvent(String confirmationEventId) async {
    final rows = await database.rows(
      'SELECT * FROM commit_receipt WHERE event_id=?',
      [Variable(confirmationEventId)],
    );
    if (rows.isEmpty) return null;
    final row = rows.single;
    return CommitReceipt(
      confirmationEventId: confirmationEventId,
      version: DatabaseVersion(
        instanceId: row.read<String>('instance_id'),
        activeEpoch: row.read<int>('active_epoch'),
        generation: row.read<int>('generation'),
      ),
      resultCount: row.read<int>('result_count'),
      resultCursor: confirmationEventId,
    );
  }

  Future<ScanPage<String>> receiptResults(
    String eventId, {
    String? after,
    int limit = 500,
  }) async {
    checkLimit(limit);
    final rows = await database.rows(
      'SELECT revision_id FROM receipt_result WHERE event_id=? AND revision_id>? ORDER BY revision_id LIMIT ?',
      [Variable(eventId), Variable(after ?? ''), Variable(limit + 1)],
    );
    final items = rows
        .take(limit)
        .map((r) => r.read<String>('revision_id'))
        .toList();
    return ScanPage(
      items,
      limit: limit,
      nextCursor: rows.length > limit ? items.last : null,
    );
  }
}
