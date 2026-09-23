import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';
import '../contracts.dart';
import '../domain/revision.dart';
import 'tables.dart';

/// Platform-neutral engine. The platform owns executor and application lock.
class SupplierDatabase extends GeneratedDatabase
    implements RevisionReadStore<RevisionEnvelope> {
  /// Mandatory table presence for opening an existing database without running
  /// migrations. This does not imply schema or business-graph equivalence.
  static Set<String> get requiredTableNames =>
      requiredTableNamesForVersion(currentStorageSchemaVersion);

  static Set<String> requiredTableNamesForVersion(int version) {
    final pattern = RegExp(r'^CREATE TABLE (\w+)');
    return Set.unmodifiable(
      schemaStatementsForVersion(version)
          .map(pattern.firstMatch)
          .whereType<RegExpMatch>()
          .map((match) => match.group(1)!),
    );
  }

  SupplierDatabase(
    super.executor, {
    required this.instanceId,
    this.activeEpoch = 0,
    this.storageVersion = currentStorageSchemaVersion,
    this.useDrift235WebLockSavepoints = false,
  });
  final int storageVersion;
  final String instanceId;
  final int activeEpoch;

  /// Pinned Drift 2.35 opfsLocks workaround. Enable only for that Web adapter.
  /// Current core uses awaited SQL units, not nested Drift child streams. This
  /// compatibility path does not implement child-stream lifecycle semantics.
  final bool useDrift235WebLockSavepoints;
  final Object _savepointZoneKey = Object();
  var _savepointSequence = 0;

  @override
  Future<T> transaction<T>(
    Future<T> Function() action, {
    bool requireNew = false,
  }) {
    if (!useDrift235WebLockSavepoints) {
      return super.transaction(action, requireNew: requireNew);
    }
    final parent = Zone.current[_savepointZoneKey] as _SavepointScope?;
    if (parent == null) {
      final scope = _SavepointScope(_SavepointRoot());
      return super.transaction(() async {
        try {
          final result = await runZoned(
            action,
            zoneValues: {_savepointZoneKey: scope},
          );
          if (scope.root.failure != null) {
            Error.throwWithStackTrace(scope.root.failure!, scope.root.stack!);
          }
          return result;
        } finally {
          scope.closed = true;
        }
      }, requireNew: requireNew);
    }
    return parent.serialized(() async {
      final name = 'supplier_nested_${++_savepointSequence}';
      final child = _SavepointScope(parent.root);
      await customStatement('SAVEPOINT $name');
      try {
        final result = await runZoned(
          action,
          zoneValues: {_savepointZoneKey: child},
        );
        await customStatement('RELEASE SAVEPOINT $name');
        return result;
      } catch (primary, primaryStack) {
        final cleanup = <({Object error, StackTrace stack})>[];
        for (final sql in [
          'ROLLBACK TO SAVEPOINT $name',
          'RELEASE SAVEPOINT $name',
        ]) {
          try {
            await customStatement(sql);
          } catch (error, stack) {
            cleanup.add((error: error, stack: stack));
          }
        }
        if (cleanup.isNotEmpty) {
          final combined = DomainFailure(
            'nested_transaction_cleanup_failed',
            'Nested rollback/release failed; outer transaction must roll back',
            cause: (
              primary: primary,
              primaryStack: primaryStack,
              cleanup: List.unmodifiable(cleanup),
            ),
          );
          parent.root.failure = combined;
          parent.root.stack = StackTrace.current;
          Error.throwWithStackTrace(combined, parent.root.stack!);
        }
        Error.throwWithStackTrace(primary, primaryStack);
      } finally {
        child.closed = true;
      }
    });
  }

  @override
  int get schemaVersion => storageVersion;
  @override
  Iterable<TableInfo<Table, Object?>> get allTables => const [];
  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (_) => transaction(() async {
      for (final sql in schemaStatementsForVersion(storageVersion)) {
        await customStatement(sql);
      }
      await customStatement('INSERT INTO database_meta VALUES(1,?,?,0,2)', [
        instanceId,
        activeEpoch,
      ]);
      // Bootstrap DDL and its physical marker must survive or roll back together.
      // Drift may repeat this assignment after onCreate; that write is idempotent.
      await customStatement('PRAGMA user_version=$storageVersion');
    }),
    onUpgrade: (_, from, to) async {
      // No published schema-1 history exists; never invent a conversion.
      throw StateError('Unsupported business migration $from -> $to');
    },
    beforeOpen: (_) async {
      await customStatement('PRAGMA foreign_keys=ON');
      final enabled = await customSelect('PRAGMA foreign_keys').getSingle();
      if (enabled.read<int>('foreign_keys') != 1) {
        throw StateError('Foreign keys unavailable');
      }
    },
  );
  Future<List<QueryRow>> rows(String sql, [List<Variable> args = const []]) =>
      customSelect(sql, variables: args).get();
  @override
  Future<DatabaseVersion> currentVersion() async {
    final row = await customSelect(
      'SELECT * FROM database_meta WHERE singleton=1',
    ).getSingle();
    return DatabaseVersion(
      instanceId: row.read<String>('instance_id'),
      activeEpoch: row.read<int>('active_epoch'),
      generation: row.read<int>('generation'),
    );
  }

  /// Restore activation primitive. Caller MUST already hold the installation
  /// application lock. Use only on a prepared candidate closed for business,
  /// or the retained old database before rollback/reopening. Pointer publication
  /// and crash recovery remain the platform owner's responsibility. This method
  /// never reacquires the lock, changes business generation, or copies device ID.
  Future<DatabaseVersion> rebindActivationEpoch({
    required DatabaseVersion expectedVersion,
    required int newEpoch,
  }) async {
    if (newEpoch <= expectedVersion.activeEpoch) {
      throw ArgumentError('Activation epoch must increase');
    }
    return transaction(() async {
      final changed = await customUpdate(
        'UPDATE database_meta SET active_epoch=? WHERE singleton=1 AND instance_id=? AND active_epoch=? AND generation=?',
        variables: [
          Variable(newEpoch),
          Variable(expectedVersion.instanceId),
          Variable(expectedVersion.activeEpoch),
          Variable(expectedVersion.generation),
        ],
      );
      if (changed != 1) {
        throw const DomainFailure(
          'stale_activation',
          'Candidate database changed before activation',
        );
      }
      return currentVersion();
    });
  }

  @override
  Future<RevisionEnvelope?> findRevision(String revisionId) async {
    final result = await rows(
      'SELECT canonical FROM revision WHERE revision_id=?',
      [Variable(revisionId)],
    );
    return result.isEmpty
        ? null
        : RevisionEnvelope.fromCanonicalJson(
            result.single.read<String>('canonical'),
          );
  }

  @override
  Future<RevisionScan<RevisionEnvelope>> openScan() async =>
      _RevisionScan(this, await currentVersion());

  /// Terminal job space reclamation. Caller holds the installation app lock.
  /// Immutable seals, confirmation events and durable receipts remain intact.
  Future<void> cleanupStaging(String jobId) => transaction(() async {
    final state = (await job(jobId)).read<String>('state');
    if (!['committed', 'cancelled', 'failed'].contains(state)) {
      throw const DomainFailure(
        'job_not_terminal',
        'Only terminal staging can be removed',
      );
    }
    if (state == 'committed' &&
        (await rows(
          'SELECT 1 FROM confirmation_event e JOIN commit_receipt r ON r.event_id=e.event_id WHERE e.job_id=? LIMIT 1',
          [Variable(jobId)],
        )).isEmpty) {
      throw const DomainFailure(
        'missing_commit_receipt',
        'Committed cleanup requires a durable receipt',
      );
    }
    for (final table in [
      if (storageVersion >= 3) ...[
        'staging_import_result',
        'staging_import_decision',
      ],
      'staging_revision',
      'staging_expected_head',
      'staging_expected_entity',
    ]) {
      await customStatement('DELETE FROM $table WHERE job_id=?', [jobId]);
    }
  });
  Future<void> createJob(String jobId) => customStatement(
    'INSERT INTO import_job(job_id,state) VALUES(?,?)',
    [jobId, JobState.created.name],
  );
  Future<void> appendStaging(String jobId, RevisionEnvelope envelope) =>
      customStatement('INSERT INTO staging_revision VALUES(?,?,?)', [
        jobId,
        envelope.revisionId,
        envelope.canonical,
      ]);
  Future<ScanPage<RevisionEnvelope>> stagingPage(
    String jobId, {
    String? after,
    int limit = 500,
  }) async {
    checkLimit(limit);
    final result = await rows(
      'SELECT canonical FROM staging_revision WHERE job_id=? AND revision_id>? ORDER BY revision_id LIMIT ?',
      [Variable(jobId), Variable(after ?? ''), Variable(limit + 1)],
    );
    return envelopePage(result, limit);
  }

  Future<PreviewToken> sealJob(
    String jobId,
    String decisionsDigest,
  ) => transaction(() async {
    final existing = await job(jobId);
    if (existing.readNullable<String>('sealed_digest') != null) {
      throw StateError('Already sealed');
    }
    final output = _DigestSink();
    final sink = sha256.startChunkedConversion(output);
    String? cursor;
    do {
      final page = await stagingPage(jobId, after: cursor);
      for (final row in page.items) {
        sink.add(utf8.encode('${row.revisionId}\t${row.canonical}\n'));
      }
      cursor = page.nextCursor;
    } while (cursor != null);
    sink.close();
    await customStatement(
      'UPDATE import_job SET state=?,sealed_digest=?,decisions_digest=? WHERE job_id=?',
      [
        JobState.previewReady.name,
        output.value.toString(),
        decisionsDigest,
        jobId,
      ],
    );
    return PreviewToken(
      version: await currentVersion(),
      jobId: jobId,
      sealedStagingDigest: output.value.toString(),
      decisionsDigest: decisionsDigest,
      schemaVersion: businessSchemaVersion,
    );
  });
  Future<QueryRow> job(String id) async => (await rows(
    'SELECT * FROM import_job WHERE job_id=?',
    [Variable(id)],
  )).single;
  Future<void> registerConfirmation(
    String eventId,
    PreviewToken token,
  ) => transaction(() async {
    final row = await job(token.jobId);
    if (!token.matches(
      version: await currentVersion(),
      jobId: token.jobId,
      sealedStagingDigest: row.readNullable<String>('sealed_digest') ?? '',
      decisionsDigest: row.readNullable<String>('decisions_digest') ?? '',
    )) {
      throw const DomainFailure('stale_preview', 'Preview is stale');
    }
    await customStatement(
      'INSERT INTO confirmation_event VALUES(?,?,?,?,?,?,?,?) ON CONFLICT(event_id) DO NOTHING',
      [
        eventId,
        token.jobId,
        token.sealedStagingDigest,
        token.decisionsDigest,
        token.version.instanceId,
        token.version.activeEpoch,
        token.version.generation,
        token.schemaVersion,
      ],
    );
    await checkConfirmation(eventId, token);
  });
  Future<void> checkConfirmation(String id, PreviewToken token) async {
    final result = await rows(
      'SELECT * FROM confirmation_event WHERE event_id=?',
      [Variable(id)],
    );
    if (result.isEmpty ||
        result.single.read<String>('job_id') != token.jobId ||
        result.single.read<String>('sealed_digest') !=
            token.sealedStagingDigest ||
        result.single.read<String>('decisions_digest') !=
            token.decisionsDigest ||
        result.single.read<String>('instance_id') != token.version.instanceId ||
        result.single.read<int>('active_epoch') != token.version.activeEpoch ||
        result.single.read<int>('generation') != token.version.generation ||
        result.single.read<int>('schema_version') != token.schemaVersion) {
      throw const DomainFailure(
        'confirmation_mismatch',
        'Confirmation identity is not registered for this seal',
      );
    }
  }
}

void checkLimit(int limit) {
  if (limit < 1 || limit > 5000) throw ArgumentError.value(limit, 'limit');
}

bool sameVersion(DatabaseVersion a, DatabaseVersion b) =>
    a.instanceId == b.instanceId &&
    a.activeEpoch == b.activeEpoch &&
    a.generation == b.generation;
ScanPage<RevisionEnvelope> envelopePage(List<QueryRow> rows, int limit) {
  final items = rows
      .take(limit)
      .map(
        (r) => RevisionEnvelope.fromCanonicalJson(r.read<String>('canonical')),
      )
      .toList();
  return ScanPage(
    items,
    limit: limit,
    nextCursor: rows.length > limit ? items.last.revisionId : null,
  );
}

class _RevisionScan implements RevisionScan<RevisionEnvelope> {
  _RevisionScan(this.db, this.version);
  final SupplierDatabase db;
  @override
  final DatabaseVersion version;
  bool closed = false;
  @override
  Future<ScanPage<RevisionEnvelope>> readPage({
    String? after,
    int limit = 500,
  }) async {
    checkLimit(limit);
    if (closed) throw StateError('Scan closed');
    return db.transaction(() async {
      if (!sameVersion(version, await db.currentVersion())) {
        throw const DomainFailure('stale_scan', 'Database changed during scan');
      }
      final result = await db.rows(
        'SELECT canonical FROM revision WHERE revision_id>? ORDER BY revision_id LIMIT ?',
        [Variable(after ?? ''), Variable(limit + 1)],
      );
      return envelopePage(result, limit);
    });
  }

  @override
  Future<void> close() async {
    closed = true;
  }
}

class _DigestSink implements Sink<Digest> {
  late Digest value;
  @override
  void add(Digest data) {
    value = data;
  }

  @override
  void close() {}
}

class _SavepointRoot {
  Object? failure;
  StackTrace? stack;
}

class _SavepointScope {
  _SavepointScope(this.root);
  final _SavepointRoot root;
  var closed = false;
  Future<void> _tail = Future.value();
  Future<T> serialized<T>(Future<T> Function() action) async {
    final previous = _tail;
    final finished = Completer<void>();
    _tail = finished.future;
    await previous;
    try {
      if (closed) throw StateError('Transaction scope already completed');
      return await action();
    } finally {
      finished.complete();
    }
  }
}
