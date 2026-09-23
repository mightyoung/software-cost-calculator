import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supplier_app/platform/native_database_host.dart';
import 'package:supplier_core/supplier_core.dart';

void main() {
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('supplier-native-host-');
  });
  tearDown(() async => directory.delete(recursive: true));
  File business(String instance) =>
      File('${directory.path}/db-$instance.sqlite');
  test(
    'persistent business and installation identity survive reopening',
    () async {
      final first = await NativeDatabaseHost.open(directory);
      final device = first.deviceId;
      final instance = (await first.database.currentVersion()).instanceId;
      final id = await first.records.createEntity('supplier', {
        'name': '本地供应商',
        'notes': null,
        'aliases': <String>[],
        'categories': <String>[],
        'address': null,
      });
      await first.close();
      final next = await NativeDatabaseHost.open(directory);
      try {
        expect(next.deviceId, device);
        final version = await next.database.currentVersion();
        expect(version.instanceId, instance);
        expect(version.generation, 1);
        final rows = await next.database.rows(
          'SELECT entity_id FROM supplier_projection',
        );
        expect(rows.single.read<String>('entity_id'), id);
      } finally {
        await next.close();
      }
    },
  );
  test('epoch mismatch refuses startup without replacing data', () async {
    final host = await NativeDatabaseHost.open(directory);
    await host.lock.run(
      () => host.database.customStatement(
        'UPDATE database_meta SET active_epoch=7',
      ),
    );
    final file = business((await host.database.currentVersion()).instanceId);
    await host.close();
    final before = await file.readAsBytes();
    await expectLater(
      NativeDatabaseHost.open(directory),
      throwsA(isA<DomainFailure>()),
    );
    expect(await file.readAsBytes(), before);
  });
  test('installation metadata upgrade preserves device and active identity', () async {
    final first = await NativeDatabaseHost.open(directory);
    final device = first.deviceId;
    final version = await first.database.currentVersion();
    await first.close();
    final legacy = _MetadataFixture(File('${directory.path}/installation.sqlite'), migrations: false);
    await legacy.customStatement('DROP TABLE restore_activation');
    await legacy.customStatement('DROP TABLE restore_candidate');
    await legacy.customStatement('PRAGMA user_version=1');
    await legacy.close();
    final upgraded = await NativeDatabaseHost.open(directory);
    try {
      expect(upgraded.deviceId, device);
      final current = await upgraded.lock.run(upgraded.readActiveVersion);
      expect(current.instanceId, version.instanceId);
      expect(current.activeEpoch, version.activeEpoch);
    } finally { await upgraded.close(); }
  });
  test('reactivation never grants an old connection the new epoch', () async {
    final old = await NativeDatabaseHost.open(directory);
    final version = await old.database.currentVersion();
    final metadata = _MetadataFixture(
      File('${directory.path}/installation.sqlite'),
    );
    await old.lock.run(() async {
      await old.database.rebindActivationEpoch(
        expectedVersion: version,
        newEpoch: 1,
      );
      await metadata.customStatement('UPDATE active SET epoch=1');
    });
    await metadata.close();
    final fresh = await NativeDatabaseHost.open(directory);
    try {
      await expectLater(
        old.lock.run(old.readActiveVersion),
        throwsA(
          isA<DomainFailure>().having(
            (e) => e.code,
            'code',
            'stale_active_database',
          ),
        ),
      );
      expect((await fresh.lock.run(fresh.readActiveVersion)).activeEpoch, 1);
    } finally {
      await fresh.close();
      await old.close();
    }
  });
  for (final empty in [false, true]) {
    test(
      '${empty ? 'empty' : 'missing'} active file is never recreated silently',
      () async {
        final host = await NativeDatabaseHost.open(directory);
        final file = business(
          (await host.database.currentVersion()).instanceId,
        );
        await host.close();
        if (empty) {
          await file.writeAsBytes([]);
        } else {
          await file.delete();
        }
        await expectLater(
          NativeDatabaseHost.open(directory),
          throwsA(isA<DomainFailure>()),
        );
        if (empty) {
          expect(await file.length(), 0);
        } else {
          expect(await file.exists(), isFalse);
        }
      },
    );
  }
  test(
    'missing installation metadata does not hide an existing business file',
    () async {
      final host = await NativeDatabaseHost.open(directory);
      final file = business((await host.database.currentVersion()).instanceId);
      await host.close();
      final before = await file.readAsBytes();
      await File('${directory.path}/installation.sqlite').delete();
      await expectLater(
        NativeDatabaseHost.open(directory),
        throwsA(isA<DomainFailure>()),
      );
      expect(await file.readAsBytes(), before);
    },
  );
  test(
    'durable bootstrap resumes completed candidate before pointer publication',
    () async {
      final first = await NativeDatabaseHost.open(directory);
      final instance = (await first.database.currentVersion()).instanceId;
      final device = first.deviceId;
      await first.close();
      final metadata = _MetadataFixture(
        File('${directory.path}/installation.sqlite'),
      );
      await metadata.transaction(() async {
        await metadata.customStatement('INSERT INTO bootstrap VALUES(1,?)', [
          instance,
        ]);
        await metadata.customStatement('DELETE FROM active');
      });
      await metadata.close();
      final resumed = await NativeDatabaseHost.open(directory);
      try {
        expect(resumed.deviceId, device);
        expect((await resumed.database.currentVersion()).instanceId, instance);
      } finally {
        await resumed.close();
      }
    },
  );
  for (final unrelated in [false, true]) {
    test(
      'nonzero schema-zero SQLite${unrelated ? ' with unrelated data' : ''} is not initialized',
      () async {
        final host = await NativeDatabaseHost.open(directory);
        final file = business(
          (await host.database.currentVersion()).instanceId,
        );
        await host.close();
        await file.delete();
        final empty = _MetadataFixture(file, migrations: false);
        if (unrelated) {
          await empty.customStatement('CREATE TABLE unrelated(value TEXT)');
          await empty.customStatement("INSERT INTO unrelated VALUES('keep')");
        }
        await empty.customStatement('VACUUM');
        await empty.close();
        expect(await file.length(), greaterThan(0));
        final before = await file.readAsBytes();
        await expectLater(
          NativeDatabaseHost.open(directory),
          throwsA(isA<DomainFailure>()),
        );
        expect(await file.readAsBytes(), before);
      },
    );
  }
  test('corrupt active file is rejected without replacing bytes', () async {
    final host = await NativeDatabaseHost.open(directory);
    final file = business((await host.database.currentVersion()).instanceId);
    await host.close();
    final before = List<int>.filled(1024, 71);
    await file.writeAsBytes(before);
    await expectLater(NativeDatabaseHost.open(directory), throwsA(anything));
    expect(await file.readAsBytes(), before);
  });
  test(
    'missing required table rejects a schema-two database unchanged',
    () async {
      final host = await NativeDatabaseHost.open(directory);
      final file = business((await host.database.currentVersion()).instanceId);
      await host.close();
      final broken = _MetadataFixture(file, migrations: false);
      await broken.customStatement('DROP TABLE supplier_projection');
      await broken.close();
      final before = await file.readAsBytes();
      await expectLater(
        NativeDatabaseHost.open(directory),
        throwsA(isA<DomainFailure>()),
      );
      expect(await file.readAsBytes(), before);
    },
  );
}

class _MetadataFixture extends GeneratedDatabase {
  _MetadataFixture(File file, {bool migrations = true})
    : super(NativeDatabase(file, enableMigrations: migrations));
  @override
  int get schemaVersion => 2;
  @override
  Iterable<TableInfo<Table, Object?>> get allTables => const [];
}
