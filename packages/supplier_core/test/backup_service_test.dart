import 'dart:convert';
import 'package:drift/native.dart';
import 'package:supplier_core/supplier_core.dart';
import 'package:test/test.dart';
import 'support/test_rig.dart' show TestWriteLock;

const instance = '00000000-0000-4000-8000-000000000001';
void main() {
  late SupplierDatabase database;
  late TestWriteLock lock;
  late _Artifact artifact;
  late BackupService backups;
  late RecordService records;
  setUp(() async {
    database = SupplierDatabase(NativeDatabase.memory(), instanceId: instance);
    lock = TestWriteLock();
    Future<DatabaseVersion> active() async {
      if (!lock.held) throw StateError('Snapshot read before application lock');
      return database.currentVersion();
    }

    records = RecordService(
      CommitCoordinator(
        database: database,
        writeLock: lock,
        readActiveVersion: active,
      ),
      deviceId: instance,
    );
    await records.createEntity('supplier', {
      'name': '备份测试',
      'notes': null,
      'aliases': <String>[],
      'categories': <String>[],
      'address': null,
    });
    await database.customStatement('INSERT INTO local_settings VALUES(?,?)', [
      'ui.theme',
      '"dark"',
    ]);
    artifact = _Artifact();
    backups = BackupService(
      database: database,
      writeLock: lock,
      readActiveVersion: active,
      createArtifact: () async => artifact,
    );
  });
  tearDown(() async => database.close());
  test(
    'same snapshot includes all authority settings and successful receipts',
    () async {
      final output = _BufferOutput();
      final result = await backups.create(output);
      expect(output.published, isTrue);
      expect(artifact.disposed, isTrue);
      expect(result.header.version.generation, 1);
      expect(result.header.counts, {
        'revision': 1,
        'local_settings': 1,
        'import_job': 1,
        'confirmation_event': 1,
        'commit_receipt': 1,
        'receipt_result': 1,
        'import_row_receipt': 0,
        'import_decision_receipt': 0,
      });
      final restored = <BackupEntry>[];
      final verified = await decodeBackup(
        _Bytes(output.bytes),
        onEntry: (row) async => restored.add(row),
      );
      expect(verified.digest, result.digest);
      expect(
        restored
            .firstWhere((r) => r.table == 'local_settings')
            .row['value_json'],
        '"dark"',
      );
      expect((await database.currentVersion()).generation, 1);
    },
  );
  test(
    'unfinished jobs and their confirmations stay outside logical backup',
    () async {
      await database.createJob('pending');
      final token = await database.sealJob('pending', 'pending-decisions');
      await database.registerConfirmation('pending-event', token);
      final output = _BufferOutput();
      final result = await backups.create(output);
      expect(result.header.counts['import_job'], 1);
      expect(result.header.counts['confirmation_event'], 1);
      expect(utf8.decode(output.bytes), isNot(contains('pending-event')));
    },
  );
  test('stale active identity fails before snapshot or publication', () async {
    final stale = BackupService(
      database: database,
      writeLock: lock,
      readActiveVersion: () async => const DatabaseVersion(
        instanceId: instance,
        activeEpoch: 1,
        generation: 1,
      ),
      createArtifact: () async => artifact,
    );
    final output = _BufferOutput();
    await expectLater(stale.create(output), throwsA(isA<DomainFailure>()));
    expect(output.started, isFalse);
    expect(artifact.disposed, isTrue);
  });
  test('failed output aborts without changing business state', () async {
    final failure = StateError('destination failed');
    final output = _BufferOutput(failure: failure);
    await expectLater(backups.create(output), throwsA(same(failure)));
    expect(output.aborted, isTrue);
    expect(output.published, isFalse);
    expect(artifact.disposed, isTrue);
    expect((await database.currentVersion()).generation, 1);
  });
  test(
    'backup composes under the existing lock and expires its context',
    () async {
      late ApplicationWriteContext held;
      await withApplicationWriteContext(lock, (context) async {
        held = context;
        final result = await backups.create(_BufferOutput(), context: context);
        expect(result.header.version.generation, 1);
        expect(lock.held, isTrue);
        expect(() => context.requireHeld(TestWriteLock()), throwsStateError);
      });
      await expectLater(
        backups.create(_BufferOutput(), context: held),
        throwsStateError,
      );
    },
  );
  test('both cleanup failures retain the original output failure', () async {
    final original = StateError('write failed');
    final abort = StateError('abort failed');
    final disposal = StateError('dispose failed');
    artifact.disposeFailure = disposal;
    final output = _BufferOutput(failure: original, abortFailure: abort);
    try {
      await backups.create(output);
      fail('Expected cleanup failure');
    } on DomainFailure catch (error) {
      final dynamic outer = error.cause;
      expect(outer.cleanup, same(disposal));
      final dynamic inner = (outer.primary as DomainFailure).cause;
      expect(inner.primary, same(original));
      expect(inner.cleanup, same(abort));
      expect(outer.published, isFalse);
    }
  });
  test('private readback corruption prevents external publication', () async {
    artifact.corrupt = true;
    final output = _BufferOutput();
    await expectLater(backups.create(output), throwsA(isA<DomainFailure>()));
    expect(output.started, isFalse);
    expect(output.aborted, isTrue);
    expect(artifact.disposed, isTrue);
  });
  test(
    'artifact creation failure aborts the already opened destination',
    () async {
      final failure = StateError('artifact unavailable');
      final service = BackupService(
        database: backups.database,
        writeLock: backups.writeLock,
        readActiveVersion: backups.readActiveVersion,
        createArtifact: () async => throw failure,
      );
      final output = _BufferOutput();
      await expectLater(service.create(output), throwsA(same(failure)));
      expect(output.aborted, isTrue);
    },
  );
  test('snapshot failure aborts the already opened destination', () async {
    final failure = StateError('snapshot unavailable');
    final service = BackupService(
      database: backups.database,
      writeLock: backups.writeLock,
      readActiveVersion: () async => throw failure,
      createArtifact: () async => artifact,
    );
    final output = _BufferOutput();
    await expectLater(service.create(output), throwsA(same(failure)));
    expect(output.aborted, isTrue);
    expect(artifact.disposed, isTrue);
  });
  test(
    'oversized SQLite preference is rejected before fetching its payload',
    () async {
      await database.customStatement('UPDATE local_settings SET value_json=?', [
        jsonEncode(List.filled(maxBackupLineBytes + 1, 'x').join()),
      ]);
      final output = _BufferOutput();
      await expectLater(
        backups.create(output),
        throwsA(
          isA<DomainFailure>().having(
            (e) => e.code,
            'code',
            'BACKUP_ROW_LIMIT',
          ),
        ),
      );
      expect(output.started, isFalse);
      expect(artifact.output.bytes.length, lessThan(8192));
      expect(artifact.disposed, isTrue);
    },
  );
}

// Deliberately finite in-memory fixtures, not production file adapters.
class _Bytes implements InputSource {
  _Bytes(this.bytes);
  final List<int> bytes;
  @override
  String get displayName => 'test.backup';
  @override
  Future<int> length() async => bytes.length;
  @override
  Stream<List<int>> openRange(int start, int endExclusive) async* {
    yield bytes.sublist(start, endExclusive);
  }
}

class _BufferOutput implements OutputTarget {
  _BufferOutput({this.failure, this.afterPublish, this.abortFailure});
  final Object? failure;
  final Object? abortFailure;
  final void Function()? afterPublish;
  final bytes = <int>[];
  bool started = false, published = false, aborted = false;
  @override
  Future<void> write(Stream<List<int>> stream) async {
    started = true;
    await for (final chunk in stream) {
      bytes.addAll(chunk);
      if (failure != null) throw failure!;
    }
  }

  @override
  Future<void> publish() async {
    published = true;
    afterPublish?.call();
  }

  @override
  Future<void> abort() async {
    aborted = true;
    if (abortFailure != null) throw abortFailure!;
  }
}

class _Artifact implements BackupArtifact {
  _Artifact() {
    output = _BufferOutput(
      afterPublish: () {
        if (corrupt) output.bytes[0] = 255;
      },
    );
  }
  @override
  late final _BufferOutput output;
  @override
  InputSource get source => _Bytes(output.bytes);
  bool disposed = false, corrupt = false;
  Object? disposeFailure;
  @override
  Future<void> dispose() async {
    disposed = true;
    if (disposeFailure != null) throw disposeFailure!;
  }
}
