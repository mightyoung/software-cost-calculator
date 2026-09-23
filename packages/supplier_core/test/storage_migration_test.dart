import 'dart:io';
import 'dart:async';
import 'package:drift/backends.dart';
import 'package:drift/native.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions, OpeningDetails;
import 'package:supplier_core/supplier_core.dart';
import 'package:test/test.dart';
import 'support/test_rig.dart';

const sourceId = '00000000-0000-4000-8000-000000000071';
const candidateId = '00000000-0000-4000-8000-000000000072';
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late Directory directory;
  late SupplierDatabase db;
  late TestWriteLock lock;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('schema-migration-');
    db = SupplierDatabase(
      NativeDatabase(File('${directory.path}/db')),
      instanceId: sourceId,
      storageVersion: 2,
    );
    lock = TestWriteLock();
  });
  tearDown(() async {
    await db.close();
    await directory.delete(recursive: true);
  });
  Future<DatabaseVersion> migrate(DatabaseVersion expected) =>
      withApplicationWriteContext(
        lock,
        (context) => migrateStorageV2ToV3(
          db,
          expectedVersion: expected,
          context: context,
          writeLock: lock,
        ),
      );
  for (final version in [2, 3]) {
    test(
      'bootstrap v$version marker survives framework version-write failure',
      () async {
        await db.close();
        final native = NativeDatabase(File('${directory.path}/db'));
        db = SupplierDatabase(
          DelegatedDatabase(FailVersionDelegate(native.delegate)),
          instanceId: sourceId,
          storageVersion: version,
        );
        await expectLater(db.currentVersion(), throwsStateError);
        await db.close();
        db = SupplierDatabase(
          NativeDatabase(File('${directory.path}/db')),
          instanceId: sourceId,
          storageVersion: version,
        );
        expect(
          (await db.rows('PRAGMA user_version')).single.data['user_version'],
          version,
        );
        expect((await db.currentVersion()).generation, 0);
        for (final table in SupplierDatabase.requiredTableNamesForVersion(
          version,
        )) {
          expect(await db.rows('PRAGMA table_info($table)'), isNotEmpty);
        }
      },
    );
  }
  test(
    'physical v2 service emits exact frozen v1 bytes, v3 emits v2',
    () async {
      await db.currentVersion();
      await db.customStatement('UPDATE database_meta SET generation=7');
      await db.customStatement('INSERT INTO local_settings VALUES(?,?)', [
        'theme',
        '"dark"',
      ]);
      Future<BufferOutput> backup() async {
        final target = BufferOutput();
        await BackupService(
          database: db,
          writeLock: lock,
          readActiveVersion: db.currentVersion,
          createArtifact: () async => MemoryArtifact(),
        ).create(target);
        return target;
      }

      expect(
        (await backup()).bytes,
        await File('test/fixtures/backup-v1.jsonl').readAsBytes(),
      );
      final before = await db.currentVersion();
      await migrate(before);
      await db.close();
      db = SupplierDatabase(
        NativeDatabase(File('${directory.path}/db')),
        instanceId: sourceId,
      );
      expect(
        (await decodeBackup(
          Bytes((await backup()).bytes),
        )).header.backupVersion,
        2,
      );
    },
  );
  test(
    'precommit failure rolls back DDL generation and physical version',
    () async {
      await db.close();
      final failing = CommitFailureDatabase(
        NativeDatabase(File('${directory.path}/db')),
      );
      db = failing;
      final before = await db.currentVersion();
      failing.failCommit = true;
      await expectLater(migrate(before), throwsStateError);
      failing.failCommit = false;
      expect(
        (await db.rows('PRAGMA user_version')).single.data['user_version'],
        2,
      );
      expect((await db.currentVersion()).generation, 0);
      expect(
        await db.rows(
          "SELECT 1 FROM sqlite_master WHERE name='staging_import_decision'",
        ),
        isEmpty,
      );
    },
  );
  test(
    'explicit migration preserves authority settings receipts and increments once after reopen',
    () async {
      await db.createJob('job');
      await db.appendStaging('job', fixtureRevision(1));
      final token = await db.sealJob('job', 'decisions');
      expect(token.schemaVersion, businessSchemaVersion);
      await db.registerConfirmation('event', token);
      await CommitCoordinator(
        database: db,
        writeLock: lock,
        readActiveVersion: db.currentVersion,
      ).commitStaged(
        jobId: 'job',
        expectedPreviewToken: token,
        confirmationEventId: 'event',
      );
      await db.customStatement('INSERT INTO local_settings VALUES(?,?)', [
        'theme',
        '"dark"',
      ]);
      final before = await db.currentVersion();
      final digest = await candidateContentDigest(db);
      final after = await migrate(before);
      expect(after.generation, before.generation + 1);
      expect((await migrate(before)).generation, after.generation);
      expect(
        (await db.rows(
          'SELECT schema_version FROM database_meta',
        )).single.data['schema_version'],
        2,
      );
      expect(
        (await db.rows('SELECT COUNT(*) n FROM revision')).single.data['n'],
        1,
      );
      expect(
        (await db.rows(
          'SELECT COUNT(*) n FROM commit_receipt',
        )).single.data['n'],
        1,
      );
      expect(
        (await db.rows(
          'SELECT value_json FROM local_settings',
        )).single.data['value_json'],
        '"dark"',
      );
      await db.close();
      db = SupplierDatabase(
        NativeDatabase(File('${directory.path}/db')),
        instanceId: sourceId,
      );
      expect(db.schemaVersion, 3);
      expect(await candidateContentDigest(db), isNot(digest));
      expect((await migrate(before)).generation, after.generation);
      for (final table in SupplierDatabase.requiredTableNamesForVersion(3)) {
        expect(await db.rows('PRAGMA table_info($table)'), isNotEmpty);
      }
    },
  );
  for (final fault in ['ddl', 'generation']) {
    test('$fault failure rolls back every migration statement', () async {
      final before = await db.currentVersion();
      if (fault == 'ddl') {
        await db.customStatement(
          'CREATE TABLE staging_import_result(id TEXT PRIMARY KEY)',
        );
      } else {
        await db.customStatement(
          "CREATE TRIGGER fail_generation BEFORE UPDATE OF generation ON database_meta BEGIN SELECT RAISE(ABORT,'injected'); END",
        );
      }
      final digest = await db.rows(
        'SELECT type,name,sql FROM sqlite_master ORDER BY type,name',
      );
      await expectLater(migrate(before), throwsA(anything));
      expect(
        (await db.rows('PRAGMA user_version')).single.data['user_version'],
        2,
      );
      expect((await db.currentVersion()).generation, before.generation);
      expect(
        (await db.rows(
          'SELECT type,name,sql FROM sqlite_master ORDER BY type,name',
        )).map((r) => r.data).toList(),
        digest.map((r) => r.data).toList(),
      );
      await db.close();
      db = SupplierDatabase(
        NativeDatabase(File('${directory.path}/db')),
        instanceId: sourceId,
        storageVersion: 2,
      );
      expect((await db.currentVersion()).generation, before.generation);
    });
  }
  test('physical3 marker alone and missing guards cannot pass retry', () async {
    final before = await db.currentVersion();
    await db.customStatement('PRAGMA user_version=3');
    await expectLater(migrate(before), throwsA(isA<DomainFailure>()));
    await db.customStatement('PRAGMA user_version=2');
    await migrate(before);
    await db.customStatement('DROP TRIGGER staging_import_decision_update');
    await expectLater(migrate(before), throwsA(isA<DomainFailure>()));
  });
  test('generation overflow fails before DDL', () async {
    await db.currentVersion();
    await db.customStatement(
      'UPDATE database_meta SET generation=9007199254740991',
    );
    await expectLater(migrate(await db.currentVersion()), throwsA(anything));
    expect(
      (await db.rows('PRAGMA user_version')).single.data['user_version'],
      2,
    );
    expect(
      await db.rows(
        "SELECT 1 FROM sqlite_master WHERE name='staging_import_decision'",
      ),
      isEmpty,
    );
  });
  test(
    'default open never automatically upgrades existing physical v2',
    () async {
      await db.currentVersion();
      await db.close();
      db = SupplierDatabase(
        NativeDatabase(File('${directory.path}/db')),
        instanceId: sourceId,
      );
      await expectLater(db.currentVersion(), throwsStateError);
    },
  );
  test('migration rejects another lock context and stale version', () async {
    final before = await db.currentVersion();
    await withApplicationWriteContext(TestWriteLock(), (context) async {
      await expectLater(
        migrateStorageV2ToV3(
          db,
          expectedVersion: before,
          context: context,
          writeLock: lock,
        ),
        throwsStateError,
      );
    });
    await db.customStatement('UPDATE database_meta SET generation=1');
    await expectLater(migrate(before), throwsA(isA<DomainFailure>()));
  });
  test(
    'frozen physical-v2 backup bytes restore without inventing decision details',
    () async {
      final bytes = await File('test/fixtures/backup-v1.jsonl').readAsBytes();
      final decoded = await decodeBackup(Bytes(bytes));
      expect(decoded.header.backupVersion, 1);
      expect(
        decoded.header.tableKeys.containsKey('import_decision_receipt'),
        isFalse,
      );
      final candidate = SupplierDatabase(
        NativeDatabase.memory(),
        instanceId: candidateId,
      );
      try {
        await BackupCandidateBuilder(
          database: candidate,
          writeLock: TestWriteLock(),
        ).build(Bytes(bytes));
        expect((await candidate.currentVersion()).generation, 7);
        expect(
          (await candidate.rows(
            'SELECT value_json FROM local_settings',
          )).single.data['value_json'],
          '"dark"',
        );
        expect(
          await candidate.rows('SELECT * FROM import_decision_receipt'),
          isEmpty,
        );
      } finally {
        await candidate.close();
      }
    },
  );
  test('v1 encoding rejects a new table', () async {
    final bytes = await File('test/fixtures/backup-v1.jsonl').readAsBytes();
    final header = await decodeBackup(Bytes(bytes));
    final fingerprint = SourceFingerprint.create(
      fields: {},
      inputIdentity: {},
      mappingSemantics: {},
      batchDefaults: {},
      captureMode: 'historical',
    );
    final operation = OperationFingerprint.create(
      source: fingerprint,
      intent: ImportIntent.newInquiry,
      originalBindings: {},
      operations: {},
      confirmedQuantity: 1,
    );
    await expectLater(
      encodeBackup(
        header.header,
        Stream.value(
          BackupEntry('import_decision_receipt', {
            'event_id': 'e',
            'fingerprint_version': 1,
            'source_fingerprint': fingerprint.digest,
            'source_canonical': fingerprint.canonical,
            'operation_fingerprint': operation.digest,
            'operation_canonical': operation.canonical,
            'original_target_id': '',
          }),
        ),
      ).drain<void>(),
      throwsA(isA<DomainFailure>()),
    );
  });
}

class Bytes implements InputSource {
  Bytes(this.bytes);
  final List<int> bytes;
  @override
  String get displayName => 'fixture';
  @override
  Future<int> length() async => bytes.length;
  @override
  Stream<List<int>> openRange(int start, int endExclusive) async* {
    yield bytes.sublist(start, endExclusive);
  }
}

class BufferOutput implements OutputTarget {
  final bytes = <int>[];
  @override
  Future<void> write(Stream<List<int>> chunks) async {
    await for (final chunk in chunks) {
      bytes.addAll(chunk);
    }
  }

  @override
  Future<void> publish() async {}
  @override
  Future<void> abort() async {
    bytes.clear();
  }
}

class MemoryArtifact implements BackupArtifact {
  @override
  final BufferOutput output = BufferOutput();
  @override
  InputSource get source => Bytes(output.bytes);
  @override
  Future<void> dispose() async {}
}

class CommitFailureDatabase extends SupplierDatabase {
  CommitFailureDatabase(super.executor)
    : super(instanceId: sourceId, storageVersion: 2);
  bool failCommit = false;
  @override
  Future<T> transaction<T>(
    Future<T> Function() action, {
    bool requireNew = false,
  }) => super.transaction(() async {
    final result = await action();
    if (failCommit) {
      throw StateError('injected before SQL commit');
    }
    return result;
  }, requireNew: requireNew);
}

// Fault is precisely Drift's post-onCreate DynamicVersionDelegate assignment.
// SQL execution and onCreate's own transactional PRAGMA remain real SQLite.
class FailVersionDelegate extends DatabaseDelegate {
  FailVersionDelegate(this.inner);
  final DatabaseDelegate inner;
  @override
  DbVersionDelegate get versionDelegate =>
      FailVersion(inner.versionDelegate as DynamicVersionDelegate);
  @override
  TransactionDelegate get transactionDelegate => inner.transactionDelegate;
  @override
  FutureOr<bool> get isOpen => inner.isOpen;
  @override
  Future<void> open(QueryExecutorUser user) => inner.open(user);
  @override
  Future<void> close() => inner.close();
  @override
  void notifyDatabaseOpened(OpeningDetails details) =>
      inner.notifyDatabaseOpened(details);
  @override
  Future<QueryResult> runSelect(String sql, List<Object?> args) =>
      inner.runSelect(sql, args);
  @override
  Future<int> runUpdate(String sql, List<Object?> args) =>
      inner.runUpdate(sql, args);
  @override
  Future<int> runInsert(String sql, List<Object?> args) =>
      inner.runInsert(sql, args);
  @override
  Future<void> runCustom(String sql, List<Object?> args) =>
      inner.runCustom(sql, args);
}

class FailVersion extends DynamicVersionDelegate {
  FailVersion(this.inner);
  final DynamicVersionDelegate inner;
  @override
  Future<int> get schemaVersion => inner.schemaVersion;
  @override
  Future<void> setSchemaVersion(int version) async =>
      throw StateError('injected framework version write failure');
}
