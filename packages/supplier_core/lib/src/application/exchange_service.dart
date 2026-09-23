import 'dart:convert';
import 'package:drift/drift.dart';
import '../contracts.dart';
import '../data/commit_coordinator.dart';
import '../data/database.dart';
import '../domain/revision.dart';
import '../domain/canonical.dart';
import '../domain/quotation.dart';
import '../exchange/backup_format.dart';
import '../exchange/business_import.dart';
import '../exchange/import_receipts.dart';
import '../exchange/job_store.dart';
import '../exchange/xlsx_reader.dart';
import '../exchange/xlsx_staging.dart';
import '../exchange/xlsx_writer.dart';
import 'backup_service.dart';

/// Explicit-decision business workbook workflow. Isolated XLSX staging is
/// supplied/reopened by the platform using the durable job ID as its locator.
final class ExchangeService {
  ExchangeService({
    required this.coordinator,
    required this.backups,
    required this.createBackupDestination,
  }) {
    if (!identical(coordinator.database, backups.database) ||
        !identical(coordinator.writeLock, backups.writeLock)) {
      throw ArgumentError('Backup and commit must use the same database/lock');
    }
  }
  final CommitCoordinator coordinator;
  final BackupService backups;
  final Future<BusinessBackupDestination> Function() createBackupDestination;
  JobStore get _jobs => JobStore(
    database: coordinator.database,
    writeLock: coordinator.writeLock,
    readActiveVersion: coordinator.readActiveVersion,
  );
  late final JobStore jobs = _jobs;
  ImportReceiptStore get receipts => ImportReceiptStore(coordinator.database);

  Future<ExchangeJob> beginBusiness(InputSource source) => jobs.create(source);

  /// Exports all active, single-head quotations to one bounded business volume.
  /// Deleted records are omitted. Any quotation conflict requires resolution
  /// first: this editable template cannot silently select a winning head.
  /// Both row and ZIP ceilings are explicit; this is not the large-table adapter.
  Future<BusinessExportSummary> exportBusiness(
    OutputTarget target, {
    required DatabaseVersion expectedVersion,
    required XlsxStaging validation,
    required BusinessWorkbookPolicy policy,
    int pageSize = 100,
  }) async {
    RangeError.checkValueInInterval(pageSize, 1, 200, 'pageSize');
    final db = coordinator.database;
    Future<void> check() async {
      if (!sameVersion(
            expectedVersion,
            await coordinator.readActiveVersion(),
          ) ||
          !sameVersion(expectedVersion, await db.currentVersion())) {
        throw const DomainFailure(
          'stale_business_export',
          'Database changed during business export',
        );
      }
    }

    Stream<List<String?>> rows() async* {
      var cursor = '';
      while (true) {
        final page = await coordinator.writeLock.run(() async {
          await check();
          return db.transaction(() async {
            if ((await db.rows(
              "SELECT 1 FROM quotation_projection WHERE relation_status='conflicted' LIMIT 1",
            )).isNotEmpty) {
              throw const DomainFailure(
                'business_export_conflict',
                'Resolve quotation conflicts before editable business export',
              );
            }
            return db.rows(
              '''SELECT q.entity_id,q.revision_id,q.payload,
              s.name supplier_name,p.name product_name,
              json_extract(p.payload,'\$.brand') product_brand,
              json_extract(p.payload,'\$.model') product_model,
              json_extract(p.payload,'\$.specification') product_specification
              FROM quotation_projection q
              LEFT JOIN supplier_projection s ON s.entity_id=COALESCE(q.canonical_supplier_id,q.supplier_id)
              LEFT JOIN product_projection p ON p.entity_id=COALESCE(q.canonical_product_id,q.product_id)
              WHERE q.relation_status='active' AND q.entity_id>?
              ORDER BY q.entity_id LIMIT ?''',
              [Variable(cursor), Variable(pageSize)],
            );
          });
        });
        if (page.isEmpty) return;
        for (final row in page) {
          final payload = (jsonDecode(row.read<String>('payload')) as Map)
              .cast<String, Object?>();
          final missing = Quotation.fromJson(payload).missingContext;
          final values = <String, Object?>{
            ...payload,
            'record_id': row.read<String>('entity_id'),
            'record_type': 'quotation',
            'export_revision_id': row.read<String>('revision_id'),
            'template_version': businessQuotationTemplateVersion,
            for (final key in [
              'supplier_name',
              'product_name',
              'product_brand',
              'product_model',
              'product_specification',
            ])
              key: row.readNullable<String>(key),
            'missing_context': missing.isEmpty ? null : missing.join(', '),
          };
          yield [
            for (final column in businessQuotationColumns)
              switch (values[column.key]) {
                null => null,
                String value => value,
                Map value => canonicalJson(value),
                final value => value.toString(),
              },
          ];
        }
        cursor = page.last.read<String>('entity_id');
      }
    }

    var publicationOwned = false;
    try {
      final volume = await const BoundedXlsxWriter().encodeVolume(
        rows: rows(),
        headers: [for (final c in businessQuotationColumns) c.heading],
        validation: validation,
        policy: XlsxExportPolicy.boundedBusiness(
          maxDataRows: policy.maxDataRows,
        ),
      );
      await coordinator.writeLock.run(() async {
        await check();
        publicationOwned = true;
        await volume.publishTo(target, checkpoint: check);
      });
      return BusinessExportSummary(
        version: expectedVersion,
        rows: volume.dataRows,
        byteLength: volume.byteLength,
        sha256: volume.sha256Hex,
      );
    } catch (primary, stack) {
      if (!publicationOwned) {
        try {
          await target.abort();
        } catch (cleanup) {
          throw DomainFailure(
            'business_export_cleanup',
            'Export and abort failed',
            cause: (primary: primary, cleanup: cleanup),
          );
        }
      }
      Error.throwWithStackTrace(primary, stack);
    }
  }

  Future<void> _current(String id, {JobState? state}) async {
    final job = await jobs.load(id);
    final active = await coordinator.readActiveVersion();
    if (!sameVersion(job.version, active) ||
        !sameVersion(active, await coordinator.database.currentVersion())) {
      throw const DomainFailure(
        'stale_job_preview',
        'Database version changed',
      );
    }
    if (state != null && job.state != state) {
      throw const DomainFailure('stale_job_state', 'Task state changed');
    }
  }

  Future<XlsxProfile> prepareBusiness(
    String id,
    InputSource source,
    XlsxStaging staging, {
    required BusinessWorkbookPolicy policy,
    String? sheetName,
  }) async {
    await jobs.bindSource(id, source);
    await jobs.transition(
      id,
      expectedState: JobState.created,
      next: JobState.parsing,
    );
    try {
      final profile = await BoundedXlsxReader(maxDataRows: policy.maxDataRows)
          .readVolume(
            source,
            staging,
            sheetName: sheetName,
            checkpoint: () => coordinator.writeLock.run(
              () => _current(id, state: JobState.parsing),
            ),
          );
      final job = await jobs.load(id);
      if (profile.sourceDigest != job.sourceDigest) {
        throw const DomainFailure('source_mismatch', 'Parsed source differs');
      }
      await coordinator.writeLock.run(
        () => _current(id, state: JobState.parsing),
      );
      await jobs.transition(
        id,
        expectedState: JobState.parsing,
        next: JobState.validating,
      );
      return profile;
    } catch (_) {
      final job = await jobs.load(id);
      if (job.state == JobState.parsing) {
        await jobs.transition(
          id,
          expectedState: job.state,
          next: JobState.failed,
        );
      }
      rethrow;
    }
  }

  Future<void> _parsed(String id, XlsxStaging staging) async {
    await coordinator.writeLock.run(() => _current(id));
    final job = await jobs.load(id);
    if (![JobState.validating, JobState.previewReady].contains(job.state) ||
        (await staging.profile())['source_digest'] != job.sourceDigest) {
      throw const DomainFailure(
        'invalid_business_staging',
        'Wrong or incomplete parsed workbook',
      );
    }
  }

  Future<List<({int row, int cells})>> previewRows(
    String id,
    XlsxStaging staging, {
    int afterRow = 0,
    int limit = 50,
  }) async {
    await _parsed(id, staging);
    return staging.rowsPage(afterRow: afterRow, limit: limit);
  }

  Future<List<StagedXlsxCell>> previewCells(
    String id,
    XlsxStaging staging,
    int row, {
    int afterColumn = 0,
    int limit = 32,
  }) async {
    await _parsed(id, staging);
    return staging.cellsPage(row, afterColumn: afterColumn, limit: limit);
  }

  /// This lookup is the required first step before caller candidate matching.
  /// A nonempty page contains original successful operations, not current values.
  Future<ImportReceiptPage> lookupSource(
    String id,
    SourceFingerprint source, {
    ReceiptCursor? after,
    int limit = 50,
  }) => coordinator.writeLock.run(() async {
    await _current(id, state: JobState.validating);
    return receipts.readSourceReceipts(source, after: after, limit: limit);
  });

  /// Candidate matching is reached only after the successful-source lookup.
  /// The callback must be read-only and must not reacquire the application lock.
  Future<({ImportReceiptPage receipts, T? candidates})> sourceFirst<T>(
    String id,
    SourceFingerprint source,
    Future<T> Function() matchCandidates,
  ) => coordinator.writeLock.run(() async {
    await _current(id, state: JobState.validating);
    final previous = await receipts.readSourceReceipts(source);
    if (previous.items.isNotEmpty) {
      return (receipts: previous, candidates: null);
    }
    final candidates = await matchCandidates();
    await _current(id, state: JobState.validating);
    return (receipts: previous, candidates: candidates);
  });

  Future<void> stageDecision(
    String id,
    BusinessImportDecision decision,
  ) => coordinator.writeLock.run(() async {
    await _current(id, state: JobState.validating);
    await coordinator.database.transaction(() async {
      for (final revision in decision.revisions) {
        final expected = await coordinator.database.rows(
          'SELECT 1 FROM staging_expected_entity WHERE job_id=? AND entity_type=? AND entity_id=?',
          [
            Variable(id),
            Variable(revision.entityType),
            Variable(revision.entityId),
          ],
        );
        if (expected.isEmpty) {
          await coordinator.database.customStatement(
            'INSERT INTO staging_expected_entity VALUES(?,?,?)',
            [id, revision.entityType, revision.entityId],
          );
          for (final parent in revision.parents) {
            await coordinator.database.customStatement(
              'INSERT INTO staging_expected_head VALUES(?,?,?,?)',
              [id, revision.entityType, revision.entityId, parent],
            );
          }
        }
        await coordinator.database.appendStaging(id, revision);
      }
      await receipts.stageDecision(
        jobId: id,
        decisionId: decision.id,
        action: decision.action,
        source: decision.source,
        operation: decision.operation,
        originalTargetId: decision.originalTargetId,
        confirmationDetails: decision.confirmationDetails,
        exclusionReason: decision.exclusionReason,
        resultRevisionIds: decision.resultRevisionIds,
      );
    });
  });

  Future<BusinessConfirmation> sealBusiness(String id) async {
    final token = await jobs.sealBusinessPreview(id);
    return BusinessConfirmation(
      token,
      await jobs.registerOrReuseConfirmation(token),
    );
  }

  /// Reloads a persisted seal/event; the UI never synthesizes a trusted token.
  Future<BusinessConfirmation> resumeBusinessConfirmation(String id) async {
    final job = await jobs.load(id);
    if (![
      JobState.previewReady,
      JobState.committing,
      JobState.committed,
    ].contains(job.state)) {
      throw const DomainFailure(
        'job_not_confirmable',
        'Task has no sealed confirmation',
      );
    }
    final row = await coordinator.database.job(id);
    final token = PreviewToken(
      version: job.version,
      jobId: id,
      sealedStagingDigest: row.read<String>('sealed_digest'),
      decisionsDigest: row.read<String>('decisions_digest'),
      schemaVersion: job.schemaVersion,
    );
    return BusinessConfirmation(
      token,
      await jobs.registerOrReuseConfirmation(token),
    );
  }

  /// Always backs up, including an empty library. Retry of an already committed
  /// event returns its existing receipt without another backup or generation.
  Future<CommitReceipt> commit(
    BusinessConfirmation confirmation,
  ) => withApplicationWriteContext(coordinator.writeLock, (context) async {
    final token = confirmation.token;
    await coordinator.database.checkConfirmation(confirmation.eventId, token);
    final existing = await coordinator.findCommittedEvent(confirmation.eventId);
    if (existing != null) {
      return coordinator.commitStaged(
        jobId: token.jobId,
        expectedPreviewToken: token,
        confirmationEventId: confirmation.eventId,
        context: context,
      );
    }
    await _current(token.jobId, state: JobState.previewReady);
    final destination = await createBackupDestination();
    final backup = await backups.create(destination.output, context: context);
    final verified = await decodeBackup(destination.source);
    if (backup.digest != verified.digest ||
        !sameVersion(verified.header.version, token.version)) {
      throw const DomainFailure(
        'backup_mismatch',
        'Published backup differs from preview version',
      );
    }
    await destination.onVerified?.call(token.jobId);
    return coordinator.commitStaged(
      jobId: token.jobId,
      expectedPreviewToken: token,
      confirmationEventId: confirmation.eventId,
      context: context,
    );
  });

  Future<ExchangeJob> cancel(String id) async {
    final job = await jobs.load(id);
    return jobs.transition(
      id,
      expectedState: job.state,
      next: JobState.cancelled,
    );
  }

  /// Reopening never restarts a partial parse into its existing staging DB.
  /// A parsing/created state is reported for caller-directed fresh retry.
  Future<ExchangeJob> resume(String id, {InputSource? source}) async {
    if (source != null) await jobs.verifySource(id, source);
    return jobs.load(id);
  }

  Stream<ExchangeJob> watchJob(
    String id, {
    Duration interval = const Duration(milliseconds: 250),
  }) async* {
    if (interval <= Duration.zero) throw ArgumentError.value(interval);
    while (true) {
      final job = await jobs.load(id);
      yield job;
      if ([
        JobState.committed,
        JobState.cancelled,
        JobState.failed,
      ].contains(job.state)) {
        return;
      }
      await Future<void>.delayed(interval);
    }
  }
}
