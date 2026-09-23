part of 'web_database_host.dart';

extension _WebStorageMigration on WebDatabaseHost {
  Future<void> _migrateActiveStorage(
    SupplierDatabase legacy,
    ApplicationWriteContext context,
  ) async {
    context.requireHeld(lock);
    final before = await legacy.currentVersion();
    final pointer = {
      'instance_id': before.instanceId,
      'epoch': before.activeEpoch,
    };
    Future<DatabaseVersion> active() async {
      final current = await installation.read('active');
      if (current?['instance_id'] != before.instanceId ||
          current?['epoch'] != before.activeEpoch) {
        throw const DomainFailure(
          'stale_active_database',
          'Active pointer changed before migration',
        );
      }
      return legacy.currentVersion();
    }

    final backup = await WebDurableBackup.create(namespace);
    late BackupSummary summary;
    try {
      summary = await BackupService(
        database: legacy,
        writeLock: lock,
        readActiveVersion: active,
        createArtifact: () => WebBackupArtifact.create(namespace),
      ).create(backup.output, context: context);
    } catch (primary, stack) {
      // This owner opened the output before the private artifact existed.
      final cleanup = <({Object error, StackTrace stack})>[];
      try {
        await backup.output.abort();
      } catch (error, errorStack) {
        cleanup.add((error: error, stack: errorStack));
      }
      _restoreFailure(primary, stack, cleanup);
    }
    final persisted = await decodeBackup(
      await WebDurableBackup.read(namespace, backup.locator),
    );
    if (persisted.digest != summary.digest ||
        (persisted.header.version.instanceId != before.instanceId ||
            persisted.header.version.activeEpoch != before.activeEpoch ||
            persisted.header.version.generation != before.generation)) {
      throw const DomainFailure(
        'migration_backup_mismatch',
        'Published migration backup differs from active library',
      );
    }
    // Each attempt retains its own verified backup locator before any DDL.
    // A crash here safely retries; SQL commits version and generation together.
    final key = 'storage-migration:${backup.locator}';
    await installation.compareAndSet(
      expected: {'active': pointer, key: null},
      changes: {
        key: {
          'from': 2,
          'to': 3,
          'instance_id': before.instanceId,
          'epoch': before.activeEpoch,
          'generation': before.generation,
          'backup_locator': backup.locator,
          'backup_digest': persisted.digest,
        },
      },
    );
    await migrateStorageV2ToV3(
      legacy,
      expectedVersion: before,
      context: context,
      writeLock: lock,
    );
  }
}
