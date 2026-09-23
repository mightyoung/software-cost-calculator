import 'dart:io';
import 'package:drift/native.dart';
import 'package:supplier_core/supplier_core.dart';
import 'package:test/test.dart';
import 'support/test_rig.dart';

void main() {
  late SupplierDatabase database;
  late Directory directory;
  late TestWriteLock lock;
  late JobStore jobs;
  DatabaseVersion? activeOverride;
  Future<DatabaseVersion> active() async {
    expect(lock.held, isTrue);
    return activeOverride ?? await database.currentVersion();
  }

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('job-store-test-');
    database = SupplierDatabase(
      NativeDatabase(File('${directory.path}/db')),
      instanceId: 'instance',
    );
    lock = TestWriteLock();
    activeOverride = null;
    jobs = JobStore(
      database: database,
      writeLock: lock,
      readActiveVersion: active,
    );
  });
  tearDown(() async {
    await database.close();
    await directory.delete(recursive: true);
  });
  Future<ExchangeJob> bound(InputSource source, {required String jobId}) async {
    await jobs.create(source, jobId: jobId);
    return jobs.bindSource(jobId, source);
  }

  Future<PreviewToken> ready(String id) async {
    await bound(_Source([1, 2, 3]), jobId: id);
    await jobs.transition(
      id,
      expectedState: JobState.created,
      next: JobState.parsing,
    );
    await database.appendStaging(id, fixtureRevision(1));
    await jobs.transition(
      id,
      expectedState: JobState.parsing,
      next: JobState.validating,
    );
    return jobs.sealPreview(id, 'decisions');
  }

  test(
    'source hash and version persist across reopen with bounded reads',
    () async {
      final source = _Source(List.generate(140000, (i) => i % 256));
      final job = await bound(source, jobId: 'job');
      expect(source.maxRange, lessThanOrEqualTo(65536));
      expect(job.version.generation, 0);
      await database.close();
      database = SupplierDatabase(
        NativeDatabase(File('${directory.path}/db')),
        instanceId: 'ignored',
      );
      jobs = JobStore(
        database: database,
        writeLock: lock,
        readActiveVersion: active,
      );
      expect((await jobs.load('job')).sourceDigest, job.sourceDigest);
      await jobs.verifySource('job', _Source(source.bytes));
      final replacement = List<int>.of(source.bytes)..[10] = 9;
      await expectLater(
        jobs.verifySource('job', _Source(replacement)),
        throwsA(isA<DomainFailure>()),
      );
      await expectLater(
        jobs.verifySource('job', _Source([1])),
        throwsA(isA<DomainFailure>()),
      );
    },
  );
  test('creation returns observable ID before any source read', () async {
    final source = _Source([1, 2, 3]);
    final job = await jobs.create(source, jobId: 'job');
    expect(job.sourceBound, isFalse);
    expect(source.maxRange, 0);
    expect((await jobs.load('job')).state, JobState.created);
    await expectLater(
      jobs.transition(
        'job',
        expectedState: JobState.created,
        next: JobState.parsing,
      ),
      throwsA(isA<DomainFailure>()),
    );
    await expectLater(
      jobs.verifySource('job', source),
      throwsA(isA<DomainFailure>()),
    );
    expect((await jobs.bindSource('job', source)).sourceBound, isTrue);
  });
  test('hashing can be cancelled through its durable job ID', () async {
    final source = _Source(
      [1, 2, 3],
      onRange: () async {
        await jobs.transition(
          'job',
          expectedState: JobState.created,
          next: JobState.cancelled,
        );
      },
    );
    await jobs.create(source, jobId: 'job');
    await expectLater(
      jobs.bindSource('job', source),
      throwsA(isA<DomainFailure>()),
    );
    expect((await jobs.load('job')).state, JobState.cancelled);
    expect((await jobs.load('job')).sourceBound, isFalse);
  });
  test(
    'unbound source lost at reopen fails instead of guessing identity',
    () async {
      final source = _Source([1, 2, 3]);
      await jobs.create(source, jobId: 'job');
      await database.close();
      database = SupplierDatabase(
        NativeDatabase(File('${directory.path}/db')),
        instanceId: 'ignored',
      );
      jobs = JobStore(
        database: database,
        writeLock: lock,
        readActiveVersion: active,
      );
      await expectLater(
        jobs.bindSource('job', source),
        throwsA(isA<DomainFailure>()),
      );
      expect((await jobs.load('job')).state, JobState.failed);
    },
  );
  test('truncated source never acquires a valid source binding', () async {
    final source = _TruncatedSource([1, 2, 3]);
    await jobs.create(source, jobId: 'job');
    await expectLater(
      jobs.bindSource('job', source),
      throwsA(isA<DomainFailure>()),
    );
    expect((await jobs.load('job')).sourceBound, isFalse);
  });
  test('job receipt lookup has a bounded indexed access path', () async {
    final plan = await database.rows(
      "EXPLAIN QUERY PLAN SELECT event_id FROM confirmation_event WHERE job_id='job'",
    );
    expect(
      plan.map((row) => row.read<String>('detail')).join(' '),
      contains('confirmation_job (job_id=?)'),
    );
  });
  test('illegal edges and unproved success fail', () async {
    await bound(_Source([1]), jobId: 'job');
    for (final next in [
      JobState.validating,
      JobState.previewReady,
      JobState.committing,
      JobState.committed,
    ]) {
      await expectLater(
        jobs.transition('job', expectedState: JobState.created, next: next),
        throwsA(isA<DomainFailure>()),
      );
    }
    await database.customStatement(
      "UPDATE import_job SET state='committed' WHERE job_id='job'",
    );
    await expectLater(jobs.load('job'), throwsA(isA<DomainFailure>()));
  });
  test(
    'real coordinator receipt proves committed state after reopen',
    () async {
      final token = await ready('job');
      await database.registerConfirmation('event', token);
      await CommitCoordinator(
        database: database,
        writeLock: lock,
        readActiveVersion: active,
      ).commitStaged(
        jobId: 'job',
        expectedPreviewToken: token,
        confirmationEventId: 'event',
      );
      await database.close();
      database = SupplierDatabase(
        NativeDatabase(File('${directory.path}/db')),
        instanceId: 'ignored',
      );
      jobs = JobStore(
        database: database,
        writeLock: lock,
        readActiveVersion: active,
      );
      expect((await jobs.load('job')).state, JobState.committed);
      await expectLater(
        jobs.transition(
          'job',
          expectedState: JobState.committed,
          next: JobState.cancelled,
        ),
        throwsA(isA<DomainFailure>()),
      );
    },
  );
  test('receipt must match source attempt version binding', () async {
    final token = await ready('job');
    await database.registerConfirmation('event', token);
    await CommitCoordinator(
      database: database,
      writeLock: lock,
      readActiveVersion: active,
    ).commitStaged(
      jobId: 'job',
      expectedPreviewToken: token,
      confirmationEventId: 'event',
    );
    await database.customStatement('UPDATE job_input SET generation=99');
    await expectLater(jobs.load('job'), throwsA(isA<DomainFailure>()));
  });
  test(
    'stale seal restarts as empty linked attempt without mutating old seal',
    () async {
      final token = await ready('old');
      await expectLater(
        jobs.transition(
          'old',
          expectedState: JobState.previewReady,
          next: JobState.validating,
        ),
        throwsA(isA<DomainFailure>()),
      );
      await database.customStatement('UPDATE database_meta SET generation=1');
      final next = await jobs.restartValidation('old', newJobId: 'new');
      expect(next.replacesJobId, 'old');
      expect(next.version.generation, 1);
      expect(next.state, JobState.validating);
      expect((await jobs.load('old')).state, JobState.cancelled);
      expect(
        (await database.job('old')).read<String>('sealed_digest'),
        token.sealedStagingDigest,
      );
      expect((await database.stagingPage('new')).items, isEmpty);
      await expectLater(
        database.appendStaging('old', fixtureRevision(2)),
        throwsA(anything),
      );
    },
  );
  test(
    'version drift rejects preview and inactive identity rejects writes',
    () async {
      await bound(_Source([1]), jobId: 'job');
      await jobs.transition(
        'job',
        expectedState: JobState.created,
        next: JobState.parsing,
      );
      await jobs.transition(
        'job',
        expectedState: JobState.parsing,
        next: JobState.validating,
      );
      await database.customStatement('UPDATE database_meta SET generation=1');
      await expectLater(
        jobs.sealPreview('job', 'decisions'),
        throwsA(isA<DomainFailure>()),
      );
      activeOverride = const DatabaseVersion(
        instanceId: 'other',
        activeEpoch: 0,
        generation: 1,
      );
      await expectLater(
        jobs.restartValidation('job'),
        throwsA(isA<DomainFailure>()),
      );
    },
  );
  test('cancel and fail are terminal and state CAS rejects stale UI', () async {
    await bound(_Source([1]), jobId: 'job');
    await jobs.transition(
      'job',
      expectedState: JobState.created,
      next: JobState.parsing,
    );
    await expectLater(
      jobs.transition(
        'job',
        expectedState: JobState.created,
        next: JobState.cancelled,
      ),
      throwsA(isA<DomainFailure>()),
    );
    await jobs.transition(
      'job',
      expectedState: JobState.parsing,
      next: JobState.failed,
    );
    await expectLater(
      jobs.restartValidation('job'),
      throwsA(isA<DomainFailure>()),
    );
  });
}

class _Source implements InputSource {
  _Source(this.bytes, {this.onRange});
  final Future<void> Function()? onRange;
  final List<int> bytes;
  int maxRange = 0;
  @override
  String get displayName => 'source';
  @override
  Future<int> length() async => bytes.length;
  @override
  Stream<List<int>> openRange(int start, int endExclusive) async* {
    await onRange?.call();
    if (endExclusive - start > maxRange) maxRange = endExclusive - start;
    yield bytes.sublist(start, endExclusive);
  }
}

class _TruncatedSource extends _Source {
  _TruncatedSource(super.bytes);
  @override
  Stream<List<int>> openRange(int start, int endExclusive) async* {
    yield bytes.sublist(start, endExclusive - 1);
  }
}
