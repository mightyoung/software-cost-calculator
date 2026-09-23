import 'dart:async';

import 'package:drift/native.dart';
import 'package:supplier_core/supplier_core.dart';
import 'package:test/test.dart';

import 'support/test_rig.dart' show fixtureRevision;

const _instance = '00000000-0000-4000-8000-000000000001';
const _deadline = Duration(seconds: 10);

void main() {
  for (final phase in ['snapshot', 'publication']) {
    test('$phase concurrency preserves the frozen backup generation', () async {
      final database = SupplierDatabase(
        NativeDatabase.memory(),
        instanceId: _instance,
      );
      final lock = _ObservedLock();
      final paused = Completer<void>();
      final resume = Completer<void>();
      final artifact = _Artifact(
        _Output(
          beforeWrite: phase == 'snapshot'
              ? () async {
                  paused.complete();
                  await resume.future.timeout(_deadline);
                }
              : null,
        ),
      );
      final output = _Output(
        beforePublish: phase == 'publication'
            ? () async {
                paused.complete();
                await resume.future.timeout(_deadline);
              }
            : null,
      );
      try {
        await RecordService(
          CommitCoordinator(
            database: database,
            writeLock: lock,
            readActiveVersion: database.currentVersion,
          ),
          deviceId: _instance,
        ).createEntity('supplier', {
          'name': 'frozen supplier',
          'notes': null,
          'aliases': <String>[],
          'categories': <String>[],
          'address': null,
        });
        await database.createJob('writer');
        await database.appendStaging('writer', fixtureRevision(2));
        final token = await database.sealJob('writer', 'decisions');
        await database.registerConfirmation('writer-event', token);
        final backups = BackupService(
          database: database,
          writeLock: lock,
          readActiveVersion: database.currentVersion,
          createArtifact: () async => artifact,
        );
        final backup = backups.create(output).timeout(_deadline);
        await paused.future.timeout(_deadline);
        final requested = Completer<void>();
        lock.onRequest = () => requested.complete();
        var writerReadActive = false;
        final writer =
            CommitCoordinator(
                  database: database,
                  writeLock: lock,
                  readActiveVersion: () async {
                    writerReadActive = true;
                    return database.currentVersion();
                  },
                )
                .commitStaged(
                  jobId: 'writer',
                  expectedPreviewToken: token,
                  confirmationEventId: 'writer-event',
                )
                .timeout(_deadline);
        await requested.future.timeout(_deadline);
        if (phase == 'snapshot') {
          // Arrival at the same application lock is observed, not inferred
          // from a timing window or a writer Future which may not have started.
          expect(lock.held, isTrue);
          expect(writerReadActive, isFalse);
          resume.complete();
          await writer;
        } else {
          expect(lock.held, isFalse);
          await writer;
          expect((await database.currentVersion()).generation, 2);
          expect(output.published, isFalse);
          resume.complete();
        }
        final summary = await backup;
        final entries = <BackupEntry>[];
        final decoded = await decodeBackup(
          _Bytes(output.bytes),
          onEntry: (entry) async => entries.add(entry),
        );
        expect(summary.header.version.generation, 1);
        expect(decoded.digest, summary.digest);
        expect(
          entries.where((entry) => entry.table == 'revision'),
          hasLength(1),
        );
        expect(
          entries.where((entry) => entry.table == 'commit_receipt'),
          hasLength(1),
        );
        expect((await database.currentVersion()).generation, 2);
        expect((await database.rows('SELECT * FROM revision')).length, 2);
        expect(output.published, isTrue);
        expect(artifact.disposed, isTrue);
      } finally {
        if (!resume.isCompleted) resume.complete();
        await database.close();
      }
    });
  }
}

class _ObservedLock implements ApplicationWriteLock {
  Future<void> _tail = Future.value();
  bool held = false;
  void Function()? onRequest;
  @override
  Future<T> run<T>(Future<T> Function() action) async {
    final previous = _tail;
    final done = Completer<void>();
    _tail = done.future;
    onRequest?.call();
    await previous;
    held = true;
    try {
      return await action();
    } finally {
      held = false;
      done.complete();
    }
  }
}

class _Bytes implements InputSource {
  _Bytes(this.bytes);
  final List<int> bytes;
  @override
  String get displayName => 'finite-concurrency-fixture';
  @override
  Future<int> length() async => bytes.length;
  @override
  Stream<List<int>> openRange(int start, int endExclusive) async* {
    yield bytes.sublist(start, endExclusive);
  }
}

class _Output implements OutputTarget {
  _Output({this.beforeWrite, this.beforePublish});
  final Future<void> Function()? beforeWrite, beforePublish;
  final bytes = <int>[];
  bool published = false;
  @override
  Future<void> write(Stream<List<int>> stream) async {
    await beforeWrite?.call();
    await for (final chunk in stream) {
      bytes.addAll(chunk);
    }
  }

  @override
  Future<void> publish() async {
    await beforePublish?.call();
    published = true;
  }

  @override
  Future<void> abort() async {}
}

class _Artifact implements BackupArtifact {
  _Artifact(this.output);
  @override
  final _Output output;
  @override
  InputSource get source => _Bytes(output.bytes);
  bool disposed = false;
  @override
  Future<void> dispose() async {
    disposed = true;
  }
}
