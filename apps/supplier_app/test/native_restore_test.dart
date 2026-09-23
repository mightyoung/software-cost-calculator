import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supplier_core/supplier_core.dart';
import 'package:supplier_app/platform/native_database_host.dart';
import 'package:supplier_app/platform/native_backup_artifact.dart';
import 'package:supplier_app/platform/native_file_ports.dart';

void main() {
  late Directory directory;
  late NativeDatabaseHost source, target;
  late File backup;
  Future<void> add(NativeDatabaseHost host, String name) => host.records
      .createEntity('supplier', {
        'name': name,
        'notes': null,
        'aliases': <String>[],
        'categories': <String>[],
        'address': null,
      })
      .then((_) {});
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('supplier-restore-');
    source = await NativeDatabaseHost.open(
      Directory('${directory.path}/source'),
    );
    target = await NativeDatabaseHost.open(
      Directory('${directory.path}/target'),
    );
    await add(source, '恢复数据');
    await add(target, '原有数据');
    backup = File('${directory.path}/source.logical');
    await BackupService(
      database: source.database,
      writeLock: source.lock,
      readActiveVersion: source.readActiveVersion,
      createArtifact: () =>
          NativeBackupArtifact.create(Directory('${directory.path}/work')),
    ).create(
      PrivateFileOutput(
        temporary: File('${backup.path}.pending'),
        destination: backup,
      ),
    );
  });
  tearDown(() async {
    await source.close();
    await target.close();
    await directory.delete(recursive: true);
  });
  Future<String> prepare() =>
      target.prepareRestore(NativeInputSource(backup, displayName: '备份'));

  for (final phase in [
    'armed',
    'armed_epoch',
    'switched',
    'rollback_pending',
    'rollback_epoch',
    'switched_corrupt',
    'armed_epoch_setting',
    'switched_projection',
  ]) {
    test('restart recovers persisted $phase boundary', () async {
      final old = await target.database.currentVersion();
      final id = await prepare();
      final beforeFile = File('${directory.path}/before.logical');
      await BackupService(
        database: target.database,
        writeLock: target.lock,
        readActiveVersion: target.readActiveVersion,
        createArtifact: () =>
            NativeBackupArtifact.create(Directory('${directory.path}/work')),
      ).create(
        PrivateFileOutput(
          temporary: File('${beforeFile.path}.pending'),
          destination: beforeFile,
        ),
      );
      await target.close();
      final metadata = _Metadata(
        File('${target.directory.path}/installation.sqlite'),
      );
      final rollback = phase.startsWith('rollback');
      await metadata.customStatement(
        'INSERT INTO restore_activation VALUES(1,?,?,?,?,?,?,?,NULL)',
        [
          id,
          old.instanceId,
          old.activeEpoch,
          old.generation,
          1,
          beforeFile.path,
          rollback
              ? 'rollback_pending'
              : phase.startsWith('switched')
              ? 'switched'
              : 'armed',
        ],
      );
      if (phase != 'armed') {
        final candidate = _Metadata(
          File('${target.directory.path}/db-$id.sqlite'),
        );
        await candidate.customStatement(
          'UPDATE database_meta SET active_epoch=1',
        );
        await candidate.close();
      }
      if (phase.startsWith('switched') || rollback) {
        await metadata.customStatement(
          'UPDATE active SET instance_id=?,epoch=1',
          [id],
        );
      }
      if (phase == 'rollback_epoch') {
        final retained = _Metadata(
          File('${target.directory.path}/db-${old.instanceId}.sqlite'),
        );
        await retained.customStatement(
          'UPDATE database_meta SET active_epoch=2',
        );
        await retained.close();
      }
      if (phase == 'switched_corrupt') {
        await File('${target.directory.path}/db-$id.sqlite')
            .writeAsBytes([1, 2, 3]);
      }
      if (phase == 'armed_epoch_setting' || phase == 'switched_projection') {
        final altered = _Metadata(
          File('${target.directory.path}/db-$id.sqlite'),
        );
        if (phase == 'armed_epoch_setting') {
          await altered.customStatement(
            'INSERT INTO local_settings VALUES(?,?)',
            ['ui.theme', '"changed"'],
          );
        } else {
          await altered.customStatement(
            "UPDATE supplier_projection SET name='changed'",
          );
        }
        await altered.close();
      }
      await metadata.close();
      target = await NativeDatabaseHost.open(target.directory);
      final version = await target.lock.run(target.readActiveVersion);
      final reverted =
          rollback ||
          phase == 'switched_corrupt' ||
          phase == 'armed_epoch_setting' ||
          phase == 'switched_projection';
      expect(version.instanceId, reverted ? old.instanceId : id);
      expect(version.activeEpoch, reverted ? 2 : 1);
      final rows = await target.database.rows(
        'SELECT name FROM supplier_projection',
      );
      expect(rows.single.read<String>('name'), reverted ? '原有数据' : '恢复数据');
    });
  }

  test('restores through fresh identity and retained backup, fencing old connections', () async {
    final device = target.deviceId;
    final old = await target.database.currentVersion();
    final id = await prepare();
    final activated = await target.activateRestore(id);
    expect(activated.instanceId, id);
    expect(activated.activeEpoch, old.activeEpoch + 1);
    await expectLater(add(target, '过期写入'), throwsA(isA<DomainFailure>()));
    final reopened = await NativeDatabaseHost.open(target.directory);
    try {
      expect(reopened.deviceId, device);
      final rows = await reopened.database.rows(
        'SELECT name FROM supplier_projection',
      );
      expect(rows.single.read<String>('name'), '恢复数据');
      await add(reopened, '恢复后新增');
      expect((await reopened.database.currentVersion()).generation, 2);
      final files = await Directory('${target.directory.path}/backups')
          .list()
          .toList();
      expect(files, hasLength(1));
      final before = await decodeBackup(
        NativeInputSource(File(files.single.path), displayName: '恢复前'),
      );
      expect(before.header.version.instanceId, old.instanceId);
      expect(
        await File('${target.directory.path}/db-${old.instanceId}.sqlite')
            .exists(),
        isTrue,
      );
    } finally {
      await reopened.close();
    }
  });

  test('ready candidate survives host restart', () async {
    final id = await prepare();
    await target.close();
    target = await NativeDatabaseHost.open(target.directory);
    expect((await target.activateRestore(id)).instanceId, id);
  });

  test('intervening business write invalidates candidate preview', () async {
    final id = await prepare();
    await add(target, '预览后更改');
    await expectLater(
      target.activateRestore(id),
      throwsA(
        isA<DomainFailure>().having((e) => e.code, 'code', 'stale_preview'),
      ),
    );
    expect((await target.database.currentVersion()).generation, 2);
  });

  test('changed candidate never switches active pointer', () async {
    final id = await prepare();
    final file = File('${target.directory.path}/db-$id.sqlite');
    await file.writeAsBytes([1, 2, 3]);
    await expectLater(
      target.activateRestore(id),
      throwsA(
        isA<DomainFailure>().having((e) => e.code, 'code', 'candidate_changed'),
      ),
    );
    expect((await target.lock.run(target.readActiveVersion)).generation, 1);
  });

  test(
    'accepted activation never rolls back after a new write or corrupt reopen',
    () async {
      final id = await prepare();
      await target.activateRestore(id);
      final reopened = await NativeDatabaseHost.open(target.directory);
      await add(reopened, '不得回退的新数据');
      await reopened.close();
      final file = File('${target.directory.path}/db-$id.sqlite');
      await file.writeAsBytes([1, 2, 3]);
      await expectLater(
        NativeDatabaseHost.open(target.directory),
        throwsA(anything),
      );
      final metadata = _Metadata(
        File('${target.directory.path}/installation.sqlite'),
      );
      try {
        expect(
          (await metadata
                  .customSelect('SELECT instance_id FROM active')
                  .getSingle())
              .read<String>('instance_id'),
          id,
        );
        expect(
          (await metadata
                  .customSelect('SELECT state FROM restore_activation')
                  .getSingle())
              .read<String>('state'),
          'accepted',
        );
      } finally {
        await metadata.close();
      }
    },
  );
}

class _Metadata extends GeneratedDatabase {
  _Metadata(File file) : super(NativeDatabase(file, enableMigrations: false));
  @override
  int get schemaVersion => 2;
  @override
  Iterable<TableInfo<Table, Object?>> get allTables => const [];
}
