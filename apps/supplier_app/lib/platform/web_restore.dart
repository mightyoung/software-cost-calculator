part of 'web_database_host.dart';

/// Independent IDB journals coordinate isolated OPFS candidates. Device identity
/// never enters a candidate; published backups retain durable OPFS locators.
extension WebRestore on WebDatabaseHost {
  Future<RestoreSpaceEstimate> estimateRestore(InputSource source) async {
    final bytes = await source.length();
    return lock.run(() => _estimateSpace('prepare', sourceBytes: bytes));
  }

  Future<RestoreSpaceEstimate> _estimateSpace(
    String phase, {
    int sourceBytes = 0,
    int candidateBytes = 0,
  }) async {
    final estimate = RestoreSpaceEstimate(
      version: await readActiveVersion(),
      phase: phase,
      capacity: await readCapacity(),
      activeBytes: await databaseAllocatedBytes(database),
      sourceBytes: sourceBytes,
      candidateBytes: candidateBytes,
    );
    lastRestoreEstimate = estimate;
    return estimate;
  }

  Future<String> prepareRestore(
    InputSource source, {
    void Function(BackupSummary summary)? onPrepared,
  }) async {
    final sourceBytes = await source.length();
    final id = newWebInstanceId();
    late Map<String, Object?> record;
    await lock.run(() async {
      final version = await readActiveVersion();
      (await _estimateSpace(
        'prepare',
        sourceBytes: sourceBytes,
      )).requireAvailable();
      record = {
        'instance_id': id,
        'state': 'building',
        'expected_instance': version.instanceId,
        'expected_epoch': version.activeEpoch,
        'expected_generation': version.generation,
      };
      await installation.compareAndSet(
        expected: {'candidate:$id': null},
        changes: {'candidate:$id': record},
      );
    });
    SupplierDatabase? opened;
    try {
      if ((await _databaseExists(_name(id).toJS).toDart).toDart) {
        throw const DomainFailure(
          'candidate_exists',
          'Candidate ID already has stored data',
        );
      }
      opened = await _openDatabase(id, 0, create: true);
      final summary = await BackupCandidateBuilder(
        database: opened,
        writeLock: WebApplicationWriteLock('candidate-$id'),
      ).build(source);
      await WebDatabaseHost.verifyDatabase(opened, id, 0);
      final digest = await candidateContentDigest(opened);
      await opened.close();
      opened = null;
      await lock.run(
        () => installation.compareAndSet(
          expected: {'candidate:$id': record},
          changes: {
            'candidate:$id': {
              ...record,
              'state': 'ready',
              'source_digest': summary.digest,
              'content_digest': digest,
              'generation': summary.header.version.generation,
            },
          },
        ),
      );
      onPrepared?.call(summary);
      return id;
    } catch (primary, stack) {
      final cleanup = <({Object error, StackTrace stack})>[];
      try {
        await opened?.close();
      } catch (error, errorStack) {
        cleanup.add((error: error, stack: errorStack));
      }
      try {
        await lock.run(
          () => installation.compareAndSet(
            expected: {'candidate:$id': record},
            changes: {
              'candidate:$id': {...record, 'state': 'failed'},
            },
          ),
        );
      } catch (error, errorStack) {
        cleanup.add((error: error, stack: errorStack));
      }
      _restoreFailure(primary, stack, cleanup);
    }
  }

  /// Acceptance fences every previously opened host, including this instance.
  /// Open a fresh host before allowing business writes to the activated library.
  Future<DatabaseVersion> activateRestore(
    String candidateId,
  ) => withApplicationWriteContext(lock, (context) async {
    requireUuid(candidateId, 'candidate_id');
    final current = await readActiveVersion();
    final candidate = await _candidate(candidateId);
    if (candidate['state'] != 'ready' ||
        candidate['expected_instance'] != current.instanceId ||
        candidate['expected_epoch'] != current.activeEpoch ||
        candidate['expected_generation'] != current.generation) {
      throw const DomainFailure(
        'stale_preview',
        'Restore preview differs from the active library',
      );
    }
    final candidateBytes = await _verifyPrepared(candidate, 0);
    (await _estimateSpace(
      'activate',
      candidateBytes: candidateBytes,
    )).requireAvailable();
    final nextEpoch = current.activeEpoch + 1;
    requireSafeInteger(nextEpoch + 1, 'rollback_epoch', min: 0);
    final backup = await WebDurableBackup.create(namespace);
    late BackupSummary summary;
    try {
      summary = await BackupService(
        database: database,
        writeLock: lock,
        readActiveVersion: readActiveVersion,
        createArtifact: () => WebBackupArtifact.create(namespace),
      ).create(backup.output, context: context);
    } catch (primary, stack) {
      // This owner opened the durable target before BackupService creates its
      // private artifact. Close it even when that earlier creation fails.
      final cleanup = <({Object error, StackTrace stack})>[];
      try {
        await backup.output.abort();
      } catch (error, errorStack) {
        cleanup.add((error: error, stack: errorStack));
      }
      _restoreFailure(primary, stack, cleanup);
    }
    // Verify the published durable locator, not a still-live temporary handle.
    final persisted = await decodeBackup(
      await WebDurableBackup.read(namespace, backup.locator),
    );
    if (persisted.digest != summary.digest ||
        (persisted.header.version.instanceId != current.instanceId ||
            persisted.header.version.activeEpoch != current.activeEpoch ||
            persisted.header.version.generation != current.generation)) {
      throw const DomainFailure(
        'restore_backup_mismatch',
        'Published restore backup differs from its frozen snapshot',
      );
    }
    final previous = await installation.read('activation');
    final journal = <String, Object?>{
      'candidate_id': candidateId,
      'old_instance': current.instanceId,
      'old_epoch': current.activeEpoch,
      'old_generation': current.generation,
      'new_epoch': nextEpoch,
      'backup_locator': backup.locator,
      'backup_digest': persisted.digest,
      'state': 'armed',
      'failure': null,
    };
    await installation.compareAndSet(
      expected: {
        'active': _pointer(current.instanceId, current.activeEpoch),
        'activation': previous,
        'candidate:$candidateId': candidate,
      },
      changes: {'activation': journal},
    );
    await _finishActivation();
    return DatabaseVersion(
      instanceId: candidateId,
      activeEpoch: nextEpoch,
      generation: requireSafeInteger(
        candidate['generation'],
        'generation',
        min: 0,
      ),
    );
  });

  Future<Map<String, Object?>> _candidate(String id) async {
    requireUuid(id, 'candidate_id');
    final record = await installation.read('candidate:$id');
    if (record == null || record['instance_id'] != id) {
      throw const DomainFailure(
        'missing_candidate',
        'Prepared candidate is missing',
      );
    }
    return record;
  }

  Future<int> _verifyPrepared(Map<String, Object?> record, int epoch) async {
    final id = requireUuid(record['instance_id'], 'candidate_id');
    final opened = await _openDatabase(id, epoch);
    late int allocated;
    try {
      await _matchContent(opened, record);
      allocated = await databaseAllocatedBytes(opened);
    } catch (primary, stack) {
      await _closeAfterRestoreFailure(opened, primary, stack);
    }
    await opened.close();
    return allocated;
  }

  Future<void> _matchContent(
    SupplierDatabase db,
    Map<String, Object?> record,
  ) async {
    if ((await db.currentVersion()).generation != record['generation'] ||
        await candidateContentDigest(db) != record['content_digest']) {
      throw const DomainFailure(
        'candidate_changed',
        'Candidate contents differ from the prepared snapshot',
      );
    }
  }

  Future<void> _recoverActivation() async {
    final journal = await installation.read('activation');
    if (journal == null) return;
    switch (journal['state']) {
      case 'armed':
      case 'switched':
        try {
          await _finishActivation();
        } catch (_) {
          if ((await installation.read('activation'))?['state'] !=
              'rolled_back') {
            rethrow;
          }
        }
      case 'rollback_pending':
        await _rollbackActivation();
      case 'accepted':
      case 'rolled_back':
        return;
      default:
        throw const DomainFailure(
          'restore_journal',
          'Unknown activation journal state',
        );
    }
  }

  Future<void> _finishActivation() async {
    SupplierDatabase? opened;
    try {
      var journal = (await installation.read('activation'))!;
      final id = requireUuid(journal['candidate_id'], 'candidate_id');
      final epoch = requireSafeInteger(
        journal['new_epoch'],
        'new_epoch',
        min: 1,
      );
      final candidate = await _candidate(id);
      if (candidate['state'] != 'ready' ||
          !['armed', 'switched'].contains(journal['state'])) {
        throw const DomainFailure(
          'restore_journal',
          'Candidate is not pending activation',
        );
      }
      final backup = await decodeBackup(
        await WebDurableBackup.read(
          namespace,
          requireUuid(journal['backup_locator'], 'backup_locator'),
        ),
      );
      if (backup.digest != journal['backup_digest'] ||
          backup.header.version.instanceId != journal['old_instance'] ||
          backup.header.version.activeEpoch != journal['old_epoch'] ||
          backup.header.version.generation != journal['old_generation']) {
        throw const DomainFailure(
          'restore_backup_mismatch',
          'Pre-restore backup does not match the journal',
        );
      }
      if (journal['state'] == 'armed') {
        opened = await _openDatabase(id, null);
        final version = await opened.currentVersion();
        if (version.activeEpoch != 0 && version.activeEpoch != epoch) {
          throw const DomainFailure(
            'candidate_changed',
            'Unexpected candidate epoch',
          );
        }
        await _matchContent(opened, candidate);
        if (version.activeEpoch == 0) {
          await opened.rebindActivationEpoch(
            expectedVersion: version,
            newEpoch: epoch,
          );
        }
        await opened.close();
        opened = null;
        final switched = {...journal, 'state': 'switched'};
        await installation.compareAndSet(
          expected: {
            'active': _pointer(
              requireUuid(journal['old_instance'], 'old_instance'),
              requireSafeInteger(journal['old_epoch'], 'old_epoch', min: 0),
            ),
            'activation': journal,
            'candidate:$id': candidate,
          },
          changes: {'active': _pointer(id, epoch), 'activation': switched},
        );
        journal = switched;
      }
      // A fresh connection validates all content after pointer publication, prior
      // to accepted. Digest normalizes only epoch, including replay after rebind.
      opened = await _openDatabase(id, epoch);
      await _matchContent(opened, candidate);
      await opened.close();
      opened = null;
      await installation.compareAndSet(
        expected: {
          'active': _pointer(id, epoch),
          'activation': journal,
          'candidate:$id': candidate,
        },
        changes: {
          'activation': {...journal, 'state': 'accepted'},
          'candidate:$id': {...candidate, 'state': 'used'},
        },
      );
    } catch (primary, stack) {
      final cleanup = <({Object error, StackTrace stack})>[];
      try {
        await opened?.close();
      } catch (error, errorStack) {
        cleanup.add((error: error, stack: errorStack));
      }
      try {
        final journal = await installation.read('activation');
        if (journal != null && journal['state'] != 'accepted') {
          if (journal['state'] != 'rollback_pending') {
            await installation.compareAndSet(
              expected: {'activation': journal},
              changes: {
                'activation': {
                  ...journal,
                  'state': 'rollback_pending',
                  'failure': primary.toString(),
                },
              },
            );
          }
          await _rollbackActivation();
        }
      } catch (error, errorStack) {
        cleanup.add((error: error, stack: errorStack));
      }
      _restoreFailure(primary, stack, cleanup);
    }
  }

  Future<void> _rollbackActivation() async {
    final journal = (await installation.read('activation'))!;
    if (journal['state'] != 'rollback_pending') {
      throw StateError('Accepted activation must not roll back');
    }
    final id = requireUuid(journal['old_instance'], 'old_instance');
    final oldEpoch = requireSafeInteger(
      journal['old_epoch'],
      'old_epoch',
      min: 0,
    );
    final newEpoch = requireSafeInteger(
      journal['new_epoch'],
      'new_epoch',
      min: 1,
    );
    final rollbackEpoch = requireSafeInteger(
      newEpoch + 1,
      'rollback_epoch',
      min: 0,
    );
    final candidateId = requireUuid(journal['candidate_id'], 'candidate_id');
    final candidate = await _candidate(candidateId);
    final active = await installation.read('active');
    final oldPointer =
        active?['instance_id'] == id && active?['epoch'] == oldEpoch;
    final candidatePointer =
        active?['instance_id'] == candidateId && active?['epoch'] == newEpoch;
    if (!oldPointer && !candidatePointer) {
      throw const DomainFailure(
        'rollback_unsafe',
        'Unexpected active pointer during rollback',
      );
    }
    final retained = await _openDatabase(id, null);
    try {
      final version = await retained.currentVersion();
      if (![oldEpoch, rollbackEpoch].contains(version.activeEpoch) ||
          version.generation != journal['old_generation']) {
        throw const DomainFailure(
          'rollback_unsafe',
          'Retained library changed after activation',
        );
      }
      if (version.activeEpoch != rollbackEpoch) {
        await retained.rebindActivationEpoch(
          expectedVersion: version,
          newEpoch: rollbackEpoch,
        );
      }
    } catch (primary, stack) {
      await _closeAfterRestoreFailure(retained, primary, stack);
    }
    await retained.close();
    await installation.compareAndSet(
      expected: {
        'active': active,
        'activation': journal,
        'candidate:$candidateId': candidate,
      },
      changes: {
        'active': _pointer(id, rollbackEpoch),
        'activation': {...journal, 'state': 'rolled_back'},
        'candidate:$candidateId': {...candidate, 'state': 'failed'},
      },
    );
  }
}

Map<String, Object?> _pointer(String id, int epoch) => {
  'instance_id': id,
  'epoch': epoch,
};
Never _restoreFailure(
  Object primary,
  StackTrace stack,
  List<({Object error, StackTrace stack})> cleanup,
) {
  if (cleanup.isNotEmpty) {
    throw DomainFailure(
      'web_restore_cleanup',
      'Restore and cleanup failed; startup remains fenced',
      cause: (
        primary: primary,
        stack: stack,
        cleanup: List.unmodifiable(cleanup),
      ),
    );
  }
  Error.throwWithStackTrace(primary, stack);
}

Future<Never> _closeAfterRestoreFailure(
  SupplierDatabase db,
  Object primary,
  StackTrace stack,
) async {
  final cleanup = <({Object error, StackTrace stack})>[];
  try {
    await db.close();
  } catch (error, errorStack) {
    cleanup.add((error: error, stack: errorStack));
  }
  _restoreFailure(primary, stack, cleanup);
}
