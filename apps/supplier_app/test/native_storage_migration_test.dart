import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supplier_app/platform/native_database_host.dart';
import 'package:supplier_app/platform/native_file_ports.dart';
import 'package:supplier_app/platform/native_backup_artifact.dart';
import 'package:supplier_core/supplier_core.dart';

void main() {
  late Directory directory;
  late String instance, device;
  late File file;
  late DatabaseVersion before;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('supplier-migration-');
    final host = await NativeDatabaseHost.open(directory);
    instance = (await host.database.currentVersion()).instanceId;
    device = host.deviceId;
    await host.close();
    file = File('${directory.path}/db-$instance.sqlite');
    await file.delete();
    final legacy = SupplierDatabase(
      NativeDatabase(file),
      instanceId: instance,
      storageVersion: 2,
    );
    final lock = NativeApplicationWriteLock(
      File('${directory.path}/application.lock'),
    );
    final records = RecordService(
      CommitCoordinator(
        database: legacy,
        writeLock: lock,
        readActiveVersion: legacy.currentVersion,
      ),
      deviceId: device,
    );
    await records.createEntity('supplier', {
      'name': '旧库供应商',
      'notes': null,
      'aliases': <String>[],
      'categories': <String>[],
      'address': null,
    });
    before = await legacy.currentVersion();
    await legacy.close();
  });
  tearDown(() => directory.delete(recursive: true));

  for (final bootstrap in [false, true]) {
    test(
      'backs up and upgrades legacy ${bootstrap ? 'bootstrap' : 'active'} once',
      () async {
        if (bootstrap) {
          final metadata = _Raw(File('${directory.path}/installation.sqlite'));
          await metadata.customStatement('INSERT INTO bootstrap VALUES(1,?)', [
            instance,
          ]);
          await metadata.customStatement('DELETE FROM active');
          await metadata.close();
        }
        var host = await NativeDatabaseHost.open(directory);
        try {
          final after = await host.database.currentVersion();
          expect(after.instanceId, instance);
          expect(after.activeEpoch, before.activeEpoch);
          expect(after.generation, before.generation + 1);
          expect(host.deviceId, device);
          expect(
            (await host.database.rows('PRAGMA user_version'))
                .single
                .data
                .values
                .single,
            3,
          );
          expect(
            (await host.database.rows(
              'SELECT schema_version FROM database_meta',
            )).single.data.values.single,
            2,
          );
          expect(
            await host.database.rows('SELECT * FROM import_decision_receipt'),
            isEmpty,
          );
          expect(
            (await host.database.rows('SELECT COUNT(*) AS n FROM revision'))
                .single
                .read<int>('n'),
            1,
          );
          final backups = await Directory('${directory.path}/backups')
              .list()
              .where((entry) => entry.path.endsWith('.logical'))
              .toList();
          expect(backups, hasLength(1));
          final snapshot = await decodeBackup(
            NativeInputSource(File(backups.single.path), displayName: '迁移备份'),
          );
          expect(snapshot.header.backupVersion, 1);
          expect(snapshot.header.version.generation, before.generation);
          await host.close();
          host = await NativeDatabaseHost.open(directory);
          expect(
            (await host.database.currentVersion()).generation,
            after.generation,
          );
          expect(
            await Directory('${directory.path}/backups').list().toList(),
            hasLength(1),
          );
        } finally {
          await host.close();
        }
      },
    );
  }

  for (final phase in [
    'armed',
    'armed_epoch',
    'switched',
    'rollback_pending',
  ]) {
    test('replays legacy $phase before migrating final active storage', () async {
      final legacy = SupplierDatabase(
        NativeDatabase(file, enableMigrations: false),
        instanceId: instance,
        storageVersion: 2,
      );
      final lock = NativeApplicationWriteLock(
        File('${directory.path}/application.lock'),
      );
      final backup = File('${directory.path}/old.logical');
      final summary =
          await BackupService(
            database: legacy,
            writeLock: lock,
            readActiveVersion: legacy.currentVersion,
            createArtifact: () => NativeBackupArtifact.create(
              Directory('${directory.path}/work'),
            ),
          ).create(
            PrivateFileOutput(
              temporary: File('${backup.path}.pending'),
              destination: backup,
            ),
          );
      await legacy.close();
      const candidateId = '12345678-1234-4234-8234-123456789abc';
      final candidateFile = File('${directory.path}/db-$candidateId.sqlite');
      final candidate = SupplierDatabase(
        NativeDatabase(candidateFile),
        instanceId: candidateId,
        storageVersion: 2,
      );
      await BackupCandidateBuilder(
        database: candidate,
        writeLock: NativeApplicationWriteLock(
          File('${directory.path}/candidate.lock'),
        ),
      ).build(NativeInputSource(backup, displayName: '旧备份'));
      final digest = await candidateContentDigest(candidate);
      await candidate.close();
      final fileDigest = await inputSha256(
        NativeInputSource(candidateFile, displayName: '旧候选'),
      );
      final metadata = _Raw(File('${directory.path}/installation.sqlite'));
      await metadata.customStatement(
        'INSERT INTO restore_candidate VALUES(?,?,?,?,?,?,?,?,?)',
        [
          candidateId,
          'ready',
          instance,
          before.activeEpoch,
          before.generation,
          summary.digest,
          fileDigest,
          digest,
          before.generation,
        ],
      );
      await metadata.customStatement(
        'INSERT INTO restore_activation VALUES(1,?,?,?,?,?,?,?,NULL)',
        [
          candidateId,
          instance,
          before.activeEpoch,
          before.generation,
          1,
          backup.path,
          phase == 'armed_epoch' ? 'armed' : phase,
        ],
      );
      if (phase != 'armed') {
        final raw = _Raw(candidateFile);
        await raw.customStatement('UPDATE database_meta SET active_epoch=1');
        await raw.close();
        if (phase != 'armed_epoch') {
          await metadata.customStatement(
            'UPDATE active SET instance_id=?,epoch=1',
            [candidateId],
          );
        }
      }
      await metadata.close();
      final host = await NativeDatabaseHost.open(directory);
      try {
        final after = await host.database.currentVersion();
        expect(
          after.instanceId,
          phase == 'rollback_pending' ? instance : candidateId,
        );
        expect(after.activeEpoch, phase == 'rollback_pending' ? 2 : 1);
        expect(after.generation, before.generation + 1);
        expect(host.database.storageVersion, 3);
        final retained = _Raw(
          File(
            '${directory.path}/db-${phase == 'rollback_pending' ? candidateId : instance}.sqlite',
          ),
        );
        expect(
          (await retained.customSelect('PRAGMA user_version').getSingle())
              .data
              .values
              .single,
          2,
        );
        await retained.close();
        final journal = _Raw(File('${directory.path}/installation.sqlite'));
        expect(
          (await journal
                  .customSelect('SELECT content_digest FROM restore_candidate')
                  .getSingle())
              .read<String>('content_digest'),
          digest,
        );
        expect(
          (await journal
                  .customSelect('SELECT state FROM restore_activation')
                  .getSingle())
              .read<String>('state'),
          phase == 'rollback_pending' ? 'rolled_back' : 'accepted',
        );
        await journal.close();
      } finally {
        await host.close();
      }
    });
  }

  test(
    'backup failure leaves physical schema and generation unchanged',
    () async {
      await File('${directory.path}/backups').writeAsString('occupied');
      await expectLater(
        NativeDatabaseHost.open(directory),
        throwsA(isA<FileSystemException>()),
      );
      final legacy = SupplierDatabase(
        NativeDatabase(file, enableMigrations: false),
        instanceId: instance,
        storageVersion: 2,
      );
      try {
        expect(
          (await legacy.rows('PRAGMA user_version')).single.data.values.single,
          2,
        );
        expect((await legacy.currentVersion()).generation, before.generation);
        expect(
          (await legacy.rows('SELECT COUNT(*) AS n FROM revision')).single
              .read<int>('n'),
          1,
        );
      } finally {
        await legacy.close();
      }
    },
  );

  for (final foreign in [false, true]) {
    test('owned bootstrap handles empty schema, foreign=$foreign', () async {
      final metadata = _Raw(File('${directory.path}/installation.sqlite'));
      await metadata.customStatement('INSERT INTO bootstrap VALUES(1,?)', [
        instance,
      ]);
      await metadata.customStatement('DELETE FROM active');
      await metadata.close();
      await file.delete();
      final raw = _Raw(file);
      if (foreign) {
        await raw.customStatement('CREATE TABLE unrelated(value TEXT)');
      }
      await raw.customStatement('VACUUM');
      await raw.close();
      if (foreign) {
        final bytes = await file.readAsBytes();
        await expectLater(
          NativeDatabaseHost.open(directory),
          throwsA(isA<DomainFailure>()),
        );
        expect(await file.readAsBytes(), bytes);
        return;
      }
      final host = await NativeDatabaseHost.open(directory);
      expect((await host.database.currentVersion()).generation, 0);
      await host.close();
    });
  }
}

class _Raw extends GeneratedDatabase {
  _Raw(File file) : super(NativeDatabase(file, enableMigrations: false));
  @override
  int get schemaVersion => 3;
  @override
  Iterable<TableInfo<Table, Object?>> get allTables => const [];
}
