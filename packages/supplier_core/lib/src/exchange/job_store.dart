import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';
import '../contracts.dart';
import '../data/database.dart';
import '../data/tables.dart';
import '../data/commit_coordinator.dart';
import 'import_receipts.dart';

final class ExchangeJob {
  const ExchangeJob({
    required this.id,
    required this.state,
    required this.sourceLength,
    required this.sourceDigest,
    required this.version,
    required this.schemaVersion,
    this.replacesJobId,
  });
  final String id;
  final JobState state;
  final int sourceLength;
  final String? sourceDigest;
  bool get sourceBound => sourceDigest != null;
  final DatabaseVersion version;
  final int schemaVersion;
  final String? replacesJobId;
}

/// Durable source-bound parse/preview attempts. Business success is owned solely
/// by CommitCoordinator. A stale sealed attempt is replaced, never unsealed.
final class JobStore {
  JobStore({
    required this.database,
    required this.writeLock,
    required this.readActiveVersion,
  });
  final SupplierDatabase database;
  final ApplicationWriteLock writeLock;
  final Future<DatabaseVersion> Function() readActiveVersion;

  final _initialSources = <String, InputSource>{};

  /// Persists the task before reading source contents, so it can be observed or
  /// cancelled while bindSource hashes. An unbound source cannot be reselected.
  Future<ExchangeJob> create(InputSource source, {String? jobId}) async {
    final length = await source.length();
    _checkLength(length);
    final created = await _write((version) async {
      final id = jobId ?? newStorageId();
      await database.createJob(id);
      await _input(id, (length: length, digest: null), version, null);
      return load(id);
    });
    _initialSources[created.id] = source;
    return created;
  }

  Future<ExchangeJob> load(String id) async {
    final rows = await database.rows(
      'SELECT j.state,i.* FROM import_job j JOIN job_input i ON i.job_id=j.job_id WHERE j.job_id=?',
      [Variable(id)],
    );
    if (rows.length != 1) {
      throw const DomainFailure('job_not_found', 'No source-bound job exists');
    }
    final row = rows.single;
    var state = JobState.values.byName(row.read<String>('state'));
    if (state == JobState.committing || state == JobState.committed) {
      final proof = await database.rows(
        'SELECT 1 FROM confirmation_event e JOIN commit_receipt r ON r.event_id=e.event_id JOIN import_job j ON j.job_id=e.job_id WHERE e.job_id=? AND e.instance_id=? AND e.active_epoch=? AND e.generation=? AND e.schema_version=? AND e.sealed_digest=j.sealed_digest AND e.decisions_digest=j.decisions_digest AND e.instance_id=r.instance_id AND e.active_epoch=r.active_epoch AND r.generation=e.generation+1 AND r.result_count=(SELECT COUNT(*) FROM receipt_result x WHERE x.event_id=e.event_id) LIMIT 1',
        [
          Variable(id),
          Variable(row.read<String>('instance_id')),
          Variable(row.read<int>('active_epoch')),
          Variable(row.read<int>('generation')),
          Variable(row.read<int>('schema_version')),
        ],
      );
      if (proof.isEmpty) {
        throw const DomainFailure(
          'unproven_job_success',
          'Commit state has no matching durable receipt',
        );
      }
      state = JobState.committed;
    }
    return ExchangeJob(
      id: id,
      state: state,
      sourceLength: row.read<int>('source_length'),
      sourceDigest: row.readNullable<String>('source_digest'),
      version: DatabaseVersion(
        instanceId: row.read<String>('instance_id'),
        activeEpoch: row.read<int>('active_epoch'),
        generation: row.read<int>('generation'),
      ),
      schemaVersion: row.read<int>('schema_version'),
      replacesJobId: row.readNullable<String>('replaces_job_id'),
    );
  }

  /// Hashes the original source in an awaited operation. After reopening an
  /// unbound attempt the original identity is unknown, so a new task is required.
  Future<ExchangeJob> bindSource(String id, InputSource source) async {
    final initial = await load(id);
    if (initial.sourceBound) {
      await verifySource(id, source);
      return load(id);
    }
    if (!identical(_initialSources[id], source)) {
      if (initial.state == JobState.created) {
        await transition(
          id,
          expectedState: JobState.created,
          next: JobState.failed,
        );
      }
      throw const DomainFailure(
        'unbound_source_lost',
        'Original source was not bound before loss; create a new task',
      );
    }
    Future<void> check() => writeLock.run(() async {
      final version = await _active();
      final job = await load(id);
      if (job.state != JobState.created || !sameVersion(job.version, version)) {
        throw const DomainFailure(
          'source_binding_interrupted',
          'Task cancelled or its database version changed',
        );
      }
    });
    final fingerprint = await _fingerprint(source, checkpoint: check);
    final result = await _write((version) async {
      final job = await load(id);
      if (job.state != JobState.created ||
          !sameVersion(job.version, version) ||
          job.sourceLength != fingerprint.length) {
        throw const DomainFailure(
          'source_binding_interrupted',
          'Task or source changed while hashing',
        );
      }
      if (job.sourceDigest != null && job.sourceDigest != fingerprint.digest) {
        throw const DomainFailure(
          'source_mismatch',
          'Source binding cannot be replaced',
        );
      }
      if (!job.sourceBound) {
        await database.customStatement(
          'UPDATE job_input SET source_digest=? WHERE job_id=?',
          [fingerprint.digest, id],
        );
      }
      return load(id);
    });
    _initialSources.remove(id);
    return result;
  }

  /// Verifies only this read. T7 parsing must hash the consumed input again
  /// before sealing; a file handle is not an immutable source guarantee.
  Future<void> verifySource(String id, InputSource source) async {
    final job = await load(id);
    if (!job.sourceBound) {
      throw const DomainFailure(
        'source_unbound',
        'Initial source digest is incomplete',
      );
    }
    final actual = await _fingerprint(source);
    if (job.sourceLength != actual.length ||
        job.sourceDigest != actual.digest) {
      throw const DomainFailure(
        'source_mismatch',
        'Reselected file differs from this job source',
      );
    }
  }

  Future<ExchangeJob> transition(
    String id, {
    required JobState expectedState,
    required JobState next,
  }) => _write((_) async {
    final job = await load(id);
    if (job.state != expectedState) {
      throw const DomainFailure('stale_job_state', 'Job state changed');
    }
    if (job.state == JobState.previewReady && next == JobState.validating) {
      throw const DomainFailure(
        'restart_validation_required',
        'Use restartValidation to create a fresh attempt; sealed previews cannot be rebound',
      );
    }
    if (next == JobState.parsing && !job.sourceBound) {
      throw const DomainFailure('source_unbound', 'Bind source before parsing');
    }
    final cancellable = [
      JobState.created,
      JobState.parsing,
      JobState.validating,
      JobState.previewReady,
    ].contains(job.state);
    final allowed =
        (cancellable && [JobState.cancelled, JobState.failed].contains(next)) ||
        (job.state == JobState.created && next == JobState.parsing) ||
        (job.state == JobState.parsing && next == JobState.validating);
    if (!allowed) {
      throw const DomainFailure(
        'invalid_job_transition',
        'Transition must follow parse/validate/seal or coordinator commit',
      );
    }
    await database.customStatement(
      'UPDATE import_job SET state=? WHERE job_id=?',
      [next.name, id],
    );
    if ([JobState.cancelled, JobState.failed].contains(next)) {
      _initialSources.remove(id);
    }
    return load(id);
  });

  Future<PreviewToken> sealPreview(String id, String decisionsDigest) =>
      _write((version) => _sealPreview(id, decisionsDigest, version));

  /// Seals only persisted business decisions, under the same version binding
  /// captured before parsing/matching. Callers cannot supply an opaque digest.
  Future<PreviewToken> sealBusinessPreview(String id) => _write((
    version,
  ) async {
    if (database.storageVersion < 3 ||
        (await database.rows(
          'SELECT 1 FROM staging_import_decision WHERE job_id=? LIMIT 1',
          [Variable(id)],
        )).isEmpty) {
      throw const DomainFailure(
        'missing_import_decisions',
        'No persisted business decisions to confirm',
      );
    }
    final receipts = ImportReceiptStore(database);
    await receipts.validateStaged(id);
    return _sealPreview(id, await receipts.computeDecisionDigest(id), version);
  });

  Future<PreviewToken> _sealPreview(
    String id,
    String decisionsDigest,
    DatabaseVersion version,
  ) async {
    final job = await load(id);
    if (!job.sourceBound ||
        job.state != JobState.validating ||
        !sameVersion(version, job.version) ||
        job.schemaVersion != businessSchemaVersion) {
      throw const DomainFailure(
        'stale_job_preview',
        'Reparse and revalidate against a fresh attempt',
      );
    }
    if ((await database.job(id)).readNullable<String>('sealed_digest') !=
        null) {
      throw const DomainFailure(
        'sealed_attempt',
        'Use a fresh validation attempt; this seal is immutable',
      );
    }
    return database.sealJob(id, decisionsDigest);
  }

  /// One sealed attempt represents one explicit confirmation. Automatic retries
  /// and reopened UI reuse its event; another intentional inquiry needs a fresh
  /// attempt. Registration is serialized with all application writers.
  Future<String> registerOrReuseConfirmation(PreviewToken token) => _write((
    _,
  ) async {
    final state = (await database.job(token.jobId)).read<String>('state');
    if (!['previewReady', 'committing', 'committed'].contains(state)) {
      throw const DomainFailure(
        'job_terminal',
        'This attempt cannot be confirmed',
      );
    }
    final existing = await database.rows(
      'SELECT event_id FROM confirmation_event WHERE job_id=? ORDER BY event_id LIMIT 2',
      [Variable(token.jobId)],
    );
    if (existing.length > 1) {
      throw const DomainFailure(
        'ambiguous_confirmation',
        'Attempt has multiple confirmation events',
      );
    }
    if (existing.isNotEmpty) {
      final id = existing.single.read<String>('event_id');
      await database.checkConfirmation(id, token);
      return id;
    }
    if (state == 'committed') {
      throw const DomainFailure(
        'missing_confirmation',
        'Committed attempt has no confirmation event',
      );
    }
    final id = newStorageId();
    await database.registerConfirmation(id, token);
    return id;
  });

  /// Caller reparses into the returned empty attempt before previewing again.
  Future<ExchangeJob> restartValidation(String id, {String? newJobId}) =>
      _write((version) async {
        final old = await load(id);
        if (!old.sourceBound ||
            ![JobState.validating, JobState.previewReady].contains(old.state)) {
          throw const DomainFailure(
            'invalid_job_transition',
            'Only validation/preview can restart',
          );
        }
        final next = newJobId ?? newStorageId();
        await database.customStatement(
          'UPDATE import_job SET state=? WHERE job_id=?',
          [JobState.cancelled.name, id],
        );
        await database.createJob(next);
        await _input(
          next,
          (length: old.sourceLength, digest: old.sourceDigest),
          version,
          id,
        );
        await database.customStatement(
          'UPDATE import_job SET state=? WHERE job_id=?',
          [JobState.validating.name, next],
        );
        return load(next);
      });

  Future<T> _write<T>(Future<T> Function(DatabaseVersion) action) =>
      writeLock.run(() async {
        final version = await _active();
        return database.transaction(() async {
          if (!sameVersion(version, await database.currentVersion())) {
            throw const DomainFailure(
              'stale_active_database',
              'Database changed before task transaction',
            );
          }
          return action(version);
        });
      });

  Future<DatabaseVersion> _active() async {
    final active = await readActiveVersion();
    final connected = await database.currentVersion();
    if (!sameVersion(active, connected)) {
      throw const DomainFailure(
        'stale_active_database',
        'Connected database is inactive or changed',
      );
    }
    return connected;
  }

  Future<void> _input(
    String id,
    ({int length, String? digest}) source,
    DatabaseVersion version,
    String? previous,
  ) => database
      .customStatement('INSERT INTO job_input VALUES(?,?,?,?,?,?,?,?)', [
        id,
        source.length,
        source.digest,
        version.instanceId,
        version.activeEpoch,
        version.generation,
        businessSchemaVersion,
        previous,
      ]);
}

Future<({int length, String digest})> _fingerprint(
  InputSource source, {
  Future<void> Function()? checkpoint,
}) async {
  final length = await source.length();
  _checkLength(length);
  await checkpoint?.call();
  Stream<List<int>> bytes() async* {
    for (var start = 0; start < length; start += 65536) {
      if (start > 0 && start % (1024 * 1024) == 0) await checkpoint?.call();
      final end = (start + 65536).clamp(0, length);
      var read = 0;
      await for (final chunk in source.openRange(start, end)) {
        read += chunk.length;
        if (read > end - start) {
          throw const DomainFailure(
            'source_changed',
            'Source range exceeds declared length',
          );
        }
        yield chunk;
      }
      if (read != end - start) {
        throw const DomainFailure('source_changed', 'Source was truncated');
      }
    }
  }

  final digest = (await sha256.bind(bytes()).single).toString();
  if (await source.length() != length) {
    throw const DomainFailure('source_changed', 'Source length changed');
  }
  await checkpoint?.call();
  return (length: length, digest: digest);
}

void _checkLength(int length) {
  if (length < 0 || length > 9007199254740991) {
    throw const DomainFailure('invalid_source_length', 'Invalid source length');
  }
}
