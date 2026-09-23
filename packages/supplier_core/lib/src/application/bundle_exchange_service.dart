import '../contracts.dart';
import '../data/commit_coordinator.dart';
import '../data/database.dart';
import '../data/graph_workspace.dart';
import '../domain/canonical.dart';
import '../domain/revision_graph.dart';
import '../exchange/backup_format.dart';
import '../exchange/bundle_database.dart';
import '../exchange/bundle_import.dart';
import '../exchange/bundle_manifest.dart';
import '../exchange/job_store.dart';
import '../exchange/projection_digest.dart';
import '../exchange/xlsx_staging.dart';
import 'backup_service.dart';

final class BundleBackupDestination {
  const BundleBackupDestination(this.output, this.source, {this.onVerified});
  final OutputTarget output;
  final InputSource source;
  final Future<void> Function(String jobId)? onVerified;
}

final class BundleConfirmation {
  const BundleConfirmation(this.token, this.eventId);
  final PreviewToken token;
  final String eventId;
}

/// Full-set synchronization through the existing immutable revision coordinator.
/// File parsing and incoming-only graph validation use a separate database.
/// Only sealed revisions cross into active staging; no per-volume business
/// transaction exists. Every eventual commit revalidates the local union.
final class BundleExchangeService {
  BundleExchangeService({
    required this.coordinator,
    required this.backups,
    required this.createBackupDestination,
  }) {
    if (!identical(coordinator.database, backups.database) ||
        !identical(coordinator.writeLock, backups.writeLock)) {
      throw ArgumentError(
        'Bundle backup and commit require the same database/write lock',
      );
    }
  }
  final CommitCoordinator coordinator;
  final BackupService backups;
  final Future<BundleBackupDestination> Function() createBackupDestination;
  final Set<String> _cancellationRequested = {};
  late final JobStore jobs = JobStore(
    database: coordinator.database,
    writeLock: coordinator.writeLock,
    readActiveVersion: coordinator.readActiveVersion,
  );

  Future<ExchangeJob> beginBundle(InputSource source) => jobs.create(source);

  Future<void> _current(String id, {JobState? state}) async {
    if (_cancellationRequested.contains(id)) {
      throw const DomainFailure('CANCELLED', 'Bundle task cancelled');
    }
    final job = await jobs.load(id);
    if (job.state == JobState.cancelled || job.state == JobState.failed) {
      throw const DomainFailure('job_terminal', 'Bundle task is terminal');
    }
    if (state != null && state != job.state) {
      throw const DomainFailure('stale_job_state', 'Bundle task state changed');
    }
    if (!sameVersion(job.version, await coordinator.readActiveVersion()) ||
        !sameVersion(
          job.version,
          await coordinator.database.currentVersion(),
        )) {
      throw const DomainFailure(
        'stale_bundle_preview',
        'Reparse the bundle against a new validation attempt',
      );
    }
  }

  Future<BundleConfirmation> prepare(
    String id,
    InputSource source, {
    required DatabaseBundleStaging staging,
    required BundleBudget budget,
    required Future<XlsxStaging> Function() createXlsxStaging,
  }) async {
    try {
      var job = await jobs.load(id);
      budget.validate();
      if (job.sourceLength > budget.compressedBytes) {
        throw const DomainFailure(
          'BUNDLE_LIMIT',
          'Bundle exceeds the admission space budget',
        );
      }
      if (!sameVersion(job.version, staging.boundVersion) ||
          identical(staging.database, coordinator.database)) {
        throw const DomainFailure(
          'invalid_bundle_staging',
          'Use an independent staging database bound to this attempt',
        );
      }
      if (!job.sourceBound) job = await jobs.bindSource(id, source);
      await jobs.verifySource(id, source);
      await jobs.transition(
        id,
        expectedState: JobState.created,
        next: JobState.parsing,
      );
      Future<void> checkpoint() => coordinator.writeLock.run(
        () => _current(id, state: JobState.parsing),
      );
      await checkpoint();
      final prepared = await prepareBundle(
        source: source,
        budget: budget,
        columns: BundleColumns.schema2(),
        staging: staging,
        createXlsxStaging: createXlsxStaging,
        checkpoint: checkpoint,
      );
      if (prepared.sourceDigest != job.sourceDigest) {
        throw const DomainFailure(
          'source_changed',
          'Bundle source differs from bound input',
        );
      }
      await jobs.transition(
        id,
        expectedState: JobState.parsing,
        next: JobState.validating,
      );
      String? cursor;
      do {
        final page = await staging.revisionsPage(
          after: cursor,
          limit: 32,
          sourceDigest: prepared.sourceDigest,
        );
        await coordinator.writeLock.run(() async {
          await _current(id, state: JobState.validating);
          await coordinator.database.transaction(() async {
            await _current(id, state: JobState.validating);
            for (final revision in page.items) {
              await coordinator.database.appendStaging(id, revision);
            }
          });
        });
        cursor = page.nextCursor;
      } while (cursor != null);
      final decisions = canonicalSha256({
        'kind': 'bundle-full-set',
        'schema_version': 2,
        'source_digest': prepared.sourceDigest,
        'revisions_digest': prepared.manifest.revisionsDigest,
        'business_digest': prepared.manifest.businessDigest,
      });
      await jobs.sealPreview(id, decisions);
      return await confirmation(id);
    } catch (error, stack) {
      try {
        await _fail(id);
      } catch (cleanup, cleanupStack) {
        throw DomainFailure(
          'BUNDLE_CLEANUP_FAILED',
          'Bundle preparation failed and task cleanup also failed',
          cause: (
            primary: error,
            primaryStack: stack,
            cleanup: cleanup,
            cleanupStack: cleanupStack,
          ),
        );
      }
      Error.throwWithStackTrace(error, stack);
    }
  }

  /// Reopening a sealed task reuses the exact persisted event. It does not sign
  /// an old snapshot with today's generation or silently restart a partial parse.
  Future<BundleConfirmation> confirmation(String id) async {
    final job = await jobs.load(id),
        stored = await coordinator.database.job(id);
    if (![JobState.previewReady, JobState.committed].contains(job.state)) {
      throw const DomainFailure(
        'bundle_not_ready',
        'Bundle task has no sealed preview',
      );
    }
    final token = PreviewToken(
      version: job.version,
      jobId: id,
      sealedStagingDigest: stored.read<String>('sealed_digest'),
      decisionsDigest: stored.read<String>('decisions_digest'),
      schemaVersion: job.schemaVersion,
    );
    if (job.state != JobState.committed) await _validateUnion(id);
    return BundleConfirmation(
      token,
      await jobs.registerOrReuseConfirmation(token),
    );
  }

  Future<void> _validateUnion(String id) => coordinator.writeLock.run(() async {
    await _current(id, state: JobState.previewReady);
    final work = SqlGraphWorkspace(
      coordinator.database,
      jobId: id,
      runId: newStorageId(),
    );
    try {
      await coordinator.database.transaction(
        () => RevisionGraphValidator(pageSize: 32).validate(work),
      );
      await _current(id, state: JobState.previewReady);
    } finally {
      await work.discardWork();
    }
  });

  Future<CommitReceipt> commit(
    BundleConfirmation confirmation,
  ) => withApplicationWriteContext(coordinator.writeLock, (context) async {
    final token = confirmation.token;
    await coordinator.database.checkConfirmation(confirmation.eventId, token);
    if (await coordinator.findCommittedEvent(confirmation.eventId) != null) {
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
    final readback = await decodeBackup(destination.source);
    if (backup.digest != readback.digest ||
        !sameVersion(readback.header.version, token.version)) {
      throw const DomainFailure(
        'backup_mismatch',
        'Bundle pre-commit backup does not match its preview',
      );
    }
    await _current(token.jobId, state: JobState.previewReady);
    await destination.onVerified?.call(token.jobId);
    return coordinator.commitStaged(
      jobId: token.jobId,
      expectedPreviewToken: token,
      confirmationEventId: confirmation.eventId,
      context: context,
    );
  });

  Future<ExchangeJob> cancel(String id) async {
    _cancellationRequested.add(id);
    final job = await jobs.load(id);
    if ([
      JobState.committed,
      JobState.cancelled,
      JobState.failed,
    ].contains(job.state)) {
      return job;
    }
    final result = await jobs.transition(
      id,
      expectedState: job.state,
      next: JobState.cancelled,
    );
    await coordinator.writeLock.run(
      () => coordinator.database.cleanupStaging(id),
    );
    return result;
  }

  Future<void> _fail(String id) async {
    final job = await jobs.load(id);
    if ([
      JobState.created,
      JobState.parsing,
      JobState.validating,
      JobState.previewReady,
    ].contains(job.state)) {
      await jobs.transition(
        id,
        expectedState: job.state,
        next: _cancellationRequested.contains(id)
            ? JobState.cancelled
            : JobState.failed,
      );
      await coordinator.writeLock.run(
        () => coordinator.database.cleanupStaging(id),
      );
    }
  }

  Future<ExchangeJob> resume(String id, {InputSource? source}) async {
    if (source != null) await jobs.verifySource(id, source);
    return jobs.load(id);
  }

  /// A retry is a new source-bound task with empty staging. The old seal/event
  /// is retained for diagnosis; automatic commit retries use commit() instead.
  Future<ExchangeJob> reparse(String id, InputSource source) async {
    await jobs.verifySource(id, source);
    final job = await jobs.load(id);
    if (job.state == JobState.committed) {
      throw const DomainFailure(
        'already_committed',
        'Use the committed receipt instead of reparsing',
      );
    }
    await cancel(id);
    return beginBundle(source);
  }
}
