part of 'native_database_host.dart';

extension _NativeStorageMigration on NativeDatabaseHost {
  Future<void> _migrateActiveStorage(
    SupplierDatabase legacy,
    ApplicationWriteContext context,
  ) async {
    context.requireHeld(lock);
    final before = await legacy.currentVersion();
    Future<DatabaseVersion> active() async {
      final pointer = await _readPointer();
      if (pointer?.instanceId != before.instanceId ||
          pointer?.epoch != before.activeEpoch) {
        throw const DomainFailure(
          'stale_active_database',
          'Active pointer changed before migration',
        );
      }
      return legacy.currentVersion();
    }

    final backups = Directory('${directory.path}/backups');
    await backups.create(recursive: true);
    final file = File('${backups.path}/before-storage-v3-${_uuid()}.logical');
    final summary =
        await BackupService(
          database: legacy,
          writeLock: lock,
          readActiveVersion: active,
          createArtifact: () =>
              NativeBackupArtifact.create(Directory('${directory.path}/work')),
        ).create(
          PrivateFileOutput(
            temporary: File('${file.path}.pending'),
            destination: file,
          ),
          context: context,
        );
    final verified = await decodeBackup(
      NativeInputSource(file, displayName: '迁移前备份'),
    );
    if (verified.digest != summary.digest ||
        verified.header.version.instanceId != before.instanceId ||
        verified.header.version.activeEpoch != before.activeEpoch ||
        verified.header.version.generation != before.generation) {
      throw const DomainFailure(
        'migration_backup_mismatch',
        'Published migration backup differs from current library',
      );
    }
    await migrateStorageV2ToV3(
      legacy,
      expectedVersion: before,
      context: context,
      writeLock: lock,
    );
  }
}
