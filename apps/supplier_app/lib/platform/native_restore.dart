part of 'native_database_host.dart';

// Test harnesses install this private, zone-local boundary. It is deliberately
// absent from the host's public construction/restore API and normal application.
Future<void> _restoreBoundary(String point) async {
  final fault =
      Zone.current[#supplierNativeRestoreFault]
          as Future<void> Function(String)?;
  await fault?.call(point);
}

/// Durable IDs refer to candidates owned by this installation. A caller cannot
/// nominate an arbitrary database file for activation.
extension NativeRestore on NativeDatabaseHost {
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
    final id = _uuid();
    await lock.run(() async {
      final expected = await readActiveVersion();
      (await _estimateSpace(
        'prepare',
        sourceBytes: sourceBytes,
      )).requireAvailable();
      await _metadata.customStatement(
        'INSERT INTO restore_candidate(instance_id,state,expected_instance,expected_epoch,expected_generation) VALUES(?,?,?,?,?)',
        [
          id,
          'building',
          expected.instanceId,
          expected.activeEpoch,
          expected.generation,
        ],
      );
    });
    SupplierDatabase? candidate;
    try {
      candidate = SupplierDatabase(
        NativeDatabase(_businessFile(id)),
        instanceId: id,
      );
      final summary = await BackupCandidateBuilder(
        database: candidate,
        writeLock: NativeApplicationWriteLock(
          File('${directory.path}/candidate-$id.lock'),
        ),
      ).build(source);
      await NativeDatabaseHost._check(candidate, id, 0);
      final contentHash = await candidateContentDigest(candidate);
      await candidate.close();
      candidate = null;
      final hash = await inputSha256(
        NativeInputSource(_businessFile(id), displayName: '候选数据库'),
      );
      await lock.run(
        () => _metadata.customStatement(
          "UPDATE restore_candidate SET state='ready',source_digest=?,file_digest=?,content_digest=?,generation=? WHERE instance_id=? AND state='building'",
          [
            summary.digest,
            hash,
            contentHash,
            summary.header.version.generation,
            id,
          ],
        ),
      );
      onPrepared?.call(summary);
      return id;
    } catch (primary, stack) {
      final cleanup = <Object>[];
      try {
        await candidate?.close();
      } catch (error) {
        cleanup.add(error);
      }
      try {
        await lock.run(
          () => _metadata.customStatement(
            "UPDATE restore_candidate SET state='failed' WHERE instance_id=? AND state='building'",
            [id],
          ),
        );
      } catch (error) {
        cleanup.add(error);
      }
      // Preserve the quarantined file for diagnosis. It can never be activated.
      if (cleanup.isNotEmpty) {
        throw FileOperationFailure(primary, stack, cleanup);
      }
      Error.throwWithStackTrace(primary, stack);
    }
  }

  /// After success this host is fenced. Open a new host to use the new database;
  /// retained RecordService/CommitCoordinator instances cannot acquire its epoch.
  Future<DatabaseVersion> activateRestore(
    String candidateId,
  ) => withApplicationWriteContext(lock, (context) async {
    requireUuid(candidateId, 'candidate_id');
    final current = await readActiveVersion();
    final candidate = await _candidate(candidateId);
    if (candidate.read<String>('state') != 'ready' ||
        candidate.read<String>('expected_instance') != current.instanceId ||
        candidate.read<int>('expected_epoch') != current.activeEpoch ||
        candidate.read<int>('expected_generation') != current.generation) {
      throw const DomainFailure(
        'stale_preview',
        'Restore preview no longer matches the active database',
      );
    }
    await _verifyCandidateFile(candidate);
    // A new admission decision only: persisted recovery journals never use it.
    (await _estimateSpace(
      'activate',
      candidateBytes: await _businessFile(candidateId).length(),
    )).requireAvailable();
    final nextEpoch = current.activeEpoch + 1;
    await _restoreBoundary('restore_holds_lock');
    requireSafeInteger(nextEpoch + 1, 'rollback_epoch', min: 0);
    final backupDirectory = Directory('${directory.path}/backups');
    await backupDirectory.create(recursive: true);
    final backupPath =
        '${backupDirectory.path}/before-restore-${_uuid()}.logical';
    await BackupService(
      database: database,
      writeLock: lock,
      readActiveVersion: readActiveVersion,
      createArtifact: () =>
          NativeBackupArtifact.create(Directory('${directory.path}/work')),
    ).create(
      PrivateFileOutput(
        temporary: File('$backupPath.pending'),
        destination: File(backupPath),
      ),
      context: context,
    );
    // The published, self-verified current-library backup exists before arming.
    await _metadata.customStatement(
      '''INSERT OR REPLACE INTO restore_activation VALUES(1,?,?,?,?,?,?,?,NULL)''',
      [
        candidateId,
        current.instanceId,
        current.activeEpoch,
        current.generation,
        nextEpoch,
        backupPath,
        'armed',
      ],
    );
    await _finishActivation();
    return DatabaseVersion(
      instanceId: candidateId,
      activeEpoch: nextEpoch,
      generation: candidate.read<int>('generation'),
    );
  });

  Future<QueryRow> _candidate(String id) => _metadata
      .customSelect(
        'SELECT * FROM restore_candidate WHERE instance_id=?',
        variables: [Variable(id)],
      )
      .getSingle();

  Future<void> _verifyCandidateFile(QueryRow candidate) async {
    final id = candidate.read<String>('instance_id');
    final file = _businessFile(id);
    if (!await file.exists() ||
        await inputSha256(NativeInputSource(file, displayName: '候选数据库')) !=
            candidate.read<String>('file_digest')) {
      throw const DomainFailure(
        'candidate_changed',
        'Prepared candidate file changed',
      );
    }
    await _ExistingDatabaseProbe.verify(file, id, 0);
  }

  Future<void> _recoverActivation() async {
    final rows = await _metadata
        .customSelect('SELECT state FROM restore_activation')
        .get();
    if (rows.isEmpty) return;
    switch (rows.single.read<String>('state')) {
      case 'armed':
      case 'switched':
        try {
          await _finishActivation();
        } catch (_) {
          // _finishActivation permits reopening the old library only when its
          // durable rollback completed; otherwise startup remains blocked.
          final status = await _metadata
              .customSelect('SELECT state FROM restore_activation')
              .getSingle();
          if (status.read<String>('state') != 'rolled_back') rethrow;
        }
      case 'rollback_pending':
        await _rollbackActivation();
      case 'accepted':
      case 'rolled_back':
        return;
    }
  }

  Future<void> _finishActivation() async {
    SupplierDatabase? opened;
    try {
      final journal = await _metadata
          .customSelect('SELECT * FROM restore_activation')
          .getSingle();
      final id = journal.read<String>('candidate_id');
      final epoch = journal.read<int>('new_epoch');
      final candidate = await _candidate(id);
      final file = _businessFile(id);
      final backup = await decodeBackup(
        NativeInputSource(
          File(journal.read<String>('backup_path')),
          displayName: '恢复前备份',
        ),
      );
      final before = backup.header.version;
      if (before.instanceId != journal.read<String>('old_instance') ||
          before.activeEpoch != journal.read<int>('old_epoch') ||
          before.generation != journal.read<int>('old_generation')) {
        throw const DomainFailure(
          'restore_backup_mismatch',
          'Pre-restore backup has a different version',
        );
      }
      if (!await file.exists() || await file.length() == 0) {
        throw const DomainFailure(
          'candidate_changed',
          'Candidate database is missing',
        );
      }
      if (journal.read<String>('state') == 'armed') {
        // An interrupted epoch update is idempotently recognized by identity.
        final probe = _ExistingDatabaseProbe(file);
        late int actualEpoch;
        try {
          await probe.customStatement('PRAGMA query_only=ON');
          actualEpoch =
              (await probe
                      .customSelect(
                        'SELECT active_epoch FROM database_meta WHERE singleton=1',
                      )
                      .getSingle())
                  .read<int>('active_epoch');
        } finally {
          await probe.close();
        }
        if (actualEpoch == 0) {
          await _verifyCandidateFile(candidate);
        } else if (actualEpoch != epoch) {
          throw const DomainFailure(
            'candidate_changed',
            'Unexpected candidate epoch',
          );
        }
        final storageVersion = await _ExistingDatabaseProbe.verify(
          file,
          id,
          actualEpoch,
        );
        opened = SupplierDatabase(
          NativeDatabase(file, enableMigrations: false),
          instanceId: id,
          activeEpoch: actualEpoch,
          storageVersion: storageVersion,
        );
        await NativeDatabaseHost._check(opened, id, actualEpoch);
        final version = await opened.currentVersion();
        if (version.generation != candidate.read<int>('generation')) {
          throw const DomainFailure(
            'candidate_changed',
            'Candidate generation changed',
          );
        }
        if (actualEpoch == 0) {
          await opened.rebindActivationEpoch(
            expectedVersion: version,
            newEpoch: epoch,
          );
        }
        await opened.close();
        opened = null;
        await _restoreBoundary('before_switch');
        await _metadata.transaction(() async {
          final pointer = await _readPointer();
          if (pointer?.instanceId != journal.read<String>('old_instance') ||
              pointer?.epoch != journal.read<int>('old_epoch')) {
            throw const DomainFailure(
              'stale_active_database',
              'Active pointer changed during recovery',
            );
          }
          await _metadata.customStatement(
            'UPDATE active SET instance_id=?,epoch=? WHERE singleton=1',
            [id, epoch],
          );
          await _restoreBoundary('inside_switch');
          await _metadata.customStatement(
            "UPDATE restore_activation SET state='switched' WHERE singleton=1",
          );
        });
        await _restoreBoundary('after_switch');
      }
      // Reopen via a fresh connection before accepting any new business writes.
      final storageVersion = await _ExistingDatabaseProbe.verify(
        file,
        id,
        epoch,
      );
      opened = SupplierDatabase(
        NativeDatabase(file, enableMigrations: false),
        instanceId: id,
        activeEpoch: epoch,
        storageVersion: storageVersion,
      );
      await NativeDatabaseHost._check(opened, id, epoch);
      if (await candidateContentDigest(opened) !=
          candidate.read<String>('content_digest')) {
        throw const DomainFailure(
          'candidate_changed',
          'Candidate content or projections changed',
        );
      }
      if ((await opened.currentVersion()).generation !=
          candidate.read<int>('generation')) {
        throw const DomainFailure(
          'candidate_changed',
          'Candidate generation changed before acceptance',
        );
      }
      await opened.close();
      opened = null;
      await _metadata.transaction(() async {
        final pointer = await _readPointer();
        if (pointer?.instanceId != id || pointer?.epoch != epoch) {
          throw const DomainFailure(
            'stale_active_database',
            'New pointer does not match candidate',
          );
        }
        await _metadata.customStatement(
          "UPDATE restore_activation SET state='accepted' WHERE singleton=1",
        );
        await _metadata.customStatement(
          "UPDATE restore_candidate SET state='used' WHERE instance_id=?",
          [id],
        );
      });
      await _restoreBoundary('after_accept');
    } catch (primary, stack) {
      final cleanup = <Object>[];
      try {
        await opened?.close();
      } catch (error) {
        cleanup.add(error);
      }
      try {
        final state =
            (await _metadata
                    .customSelect('SELECT state FROM restore_activation')
                    .getSingle())
                .read<String>('state');
        if (state != 'accepted') {
          await _metadata.customStatement(
            "UPDATE restore_activation SET state='rollback_pending',failure=? WHERE singleton=1",
            [primary.toString()],
          );
          await _rollbackActivation();
        }
      } catch (error) {
        cleanup.add(error);
      }
      if (cleanup.isNotEmpty) {
        throw FileOperationFailure(primary, stack, cleanup);
      }
      Error.throwWithStackTrace(primary, stack);
    }
  }

  Future<void> _rollbackActivation() async {
    final journal = await _metadata
        .customSelect('SELECT * FROM restore_activation')
        .getSingle();
    if (journal.read<String>('state') != 'rollback_pending') {
      throw StateError('Only an unaccepted activation may roll back');
    }
    final id = journal.read<String>('old_instance');
    final oldEpoch = journal.read<int>('old_epoch');
    final epoch = journal.read<int>('new_epoch') + 1;
    final file = _businessFile(id);
    if (!await file.exists() || await file.length() == 0) {
      throw const DomainFailure(
        'missing_active_database',
        'Retained old database is missing',
      );
    }
    final probe = _ExistingDatabaseProbe(file);
    late int actualEpoch;
    try {
      await probe.customStatement('PRAGMA query_only=ON');
      actualEpoch =
          (await probe
                  .customSelect(
                    'SELECT active_epoch FROM database_meta WHERE singleton=1',
                  )
                  .getSingle())
              .read<int>('active_epoch');
    } finally {
      await probe.close();
    }
    if (actualEpoch != oldEpoch && actualEpoch != epoch) {
      throw const DomainFailure(
        'database_identity_mismatch',
        'Unexpected retained database epoch',
      );
    }
    final storageVersion = await _ExistingDatabaseProbe.verify(
      file,
      id,
      actualEpoch,
    );
    final retained = SupplierDatabase(
      NativeDatabase(file, enableMigrations: false),
      instanceId: id,
      activeEpoch: actualEpoch,
      storageVersion: storageVersion,
    );
    try {
      await NativeDatabaseHost._check(retained, id, actualEpoch);
      final version = await retained.currentVersion();
      if (version.generation != journal.read<int>('old_generation')) {
        throw const DomainFailure(
          'rollback_unsafe',
          'Retained database changed after activation',
        );
      }
      if (actualEpoch != epoch) {
        await retained.rebindActivationEpoch(
          expectedVersion: version,
          newEpoch: epoch,
        );
      }
    } finally {
      await retained.close();
    }
    await _metadata.transaction(() async {
      await _metadata.customStatement(
        'UPDATE active SET instance_id=?,epoch=? WHERE singleton=1',
        [id, epoch],
      );
      await _metadata.customStatement(
        "UPDATE restore_activation SET state='rolled_back' WHERE singleton=1",
      );
      await _metadata.customStatement(
        "UPDATE restore_candidate SET state='failed' WHERE instance_id=?",
        [journal.read<String>('candidate_id')],
      );
    });
  }
}
