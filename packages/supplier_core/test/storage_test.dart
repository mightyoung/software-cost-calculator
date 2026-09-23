import 'dart:io';
import 'dart:math';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:supplier_core/src/contracts.dart';
import 'package:supplier_core/src/data/database.dart';
import 'package:supplier_core/src/data/commit_coordinator.dart';
import 'package:supplier_core/src/data/migrations.dart';
import 'package:supplier_core/src/data/graph_workspace.dart';
import 'package:supplier_core/src/domain/revision_graph.dart';
import 'package:supplier_core/src/domain/revision.dart';
import 'package:test/test.dart';
import 'support/test_rig.dart';

void main() {
  late Directory directory;
  late StorageTestRig rig;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('supplier-storage-');
    rig = StorageTestRig(File('${directory.path}/business.sqlite'));
  });
  tearDown(() async {
    await rig.database.close();
    await directory.delete(recursive: true);
  });
  Future<int> count(String table) async => (await rig.database.rows(
    'SELECT COUNT(*) AS n FROM $table',
  )).single.read<int>('n');
  Future<CommitReceipt> commit(
    PreviewToken token, {
    String? fault,
    bool product = false,
  }) => rig
      .coordinator(
        product: product,
        fault: (point) async {
          if (point == fault) throw StateError('Injected $point');
        },
      )
      .commitStaged(
        jobId: token.jobId,
        expectedPreviewToken: token,
        confirmationEventId: 'event-${token.jobId}',
      );
  test('production validates and commits sealed canonical graph', () async {
    final token = await rig.stage();
    expect((await commit(token, product: true)).resultCount, 5);
    expect(await count('supplier_projection'), 5);
    expect((await rig.database.currentVersion()).generation, 1);
  });
  for (final fault in ['page:2', 'page:4', 'page:5', 'before_commit']) {
    test(
      '$fault rolls back every page, heads, generation and receipt',
      () async {
        final token = await rig.stage();
        await expectLater(commit(token, fault: fault), throwsStateError);
        await rig.reopen();
        for (final table in [
          'revision',
          'entity_identity',
          'entity_head',
          'receipt_result',
          'commit_receipt',
        ]) {
          expect(await count(table), 0, reason: table);
        }
        expect((await rig.database.currentVersion()).generation, 0);
        expect(
          (await rig.database.job('job')).read<String>('state'),
          'previewReady',
        );
        expect(await count('staging_revision'), 5);
        expect((await commit(token)).resultCount, 5);
      },
    );
  }
  test(
    'lost after-commit response retries same durable event after reopen',
    () async {
      final token = await rig.stage();
      await expectLater(commit(token, fault: 'after_commit'), throwsStateError);
      await rig.reopen();
      final receipt = await commit(token);
      expect(receipt.version.generation, 1);
      expect(receipt.resultCount, 5);
      expect(await count('revision'), 5);
      expect(await count('commit_receipt'), 1);
      final page = await CommitCoordinator(
        database: rig.database,
        writeLock: rig.lock,
        readActiveVersion: rig.active,
      ).receiptResults('event-job', limit: 2);
      expect(page.items.length, 2);
      expect(page.nextCursor, isNotNull);
      await checkStorageIntegrity(rig.database);
    },
  );
  test(
    'seal immutable against insert update delete and digest substitution',
    () async {
      await rig.stage();
      for (final sql in [
        "DELETE FROM staging_revision WHERE job_id='job'",
        "UPDATE staging_revision SET canonical='{}' WHERE job_id='job'",
        "UPDATE import_job SET sealed_digest='other' WHERE job_id='job'",
      ]) {
        await expectLater(rig.database.customStatement(sql), throwsA(anything));
      }
      await expectLater(
        rig.database.appendStaging('job', fixtureRevision(99)),
        throwsA(anything),
      );
      expect((await rig.database.currentVersion()).generation, 0);
    },
  );
  for (final field in ['instance', 'epoch', 'generation']) {
    test('reject stale $field token without writes', () async {
      final token = await rig.stage();
      if (field == 'generation') {
        await rig.database.customStatement(
          'UPDATE database_meta SET generation=1',
        );
      } else {
        rig.activeOverride = DatabaseVersion(
          instanceId: field == 'instance' ? 'other' : 'fixture-instance',
          activeEpoch: field == 'epoch' ? 1 : 0,
          generation: 0,
        );
      }
      await expectLater(commit(token), throwsA(isA<DomainFailure>()));
      expect(await count('revision'), 0);
    });
  }
  test('scan pages bound original version and close', () async {
    final token = await rig.stage();
    await commit(token);
    final scan = await rig.database.openScan();
    final first = await scan.readPage(limit: 2);
    final second = await scan.readPage(after: first.nextCursor, limit: 2);
    final last = await scan.readPage(after: second.nextCursor, limit: 2);
    expect({...first.items, ...second.items, ...last.items}.length, 5);
    expect(last.nextCursor, isNull);
    await rig.database.customStatement(
      'UPDATE database_meta SET generation=generation+1',
    );
    await expectLater(scan.readPage(), throwsA(isA<DomainFailure>()));
    await scan.close();
    await expectLater(scan.readPage(), throwsStateError);
  });
  test('missing parent fails deferred FK and rolls back', () async {
    await rig.database.createJob('job');
    await rig.database.appendStaging(
      'job',
      fixtureRevision(1, parents: [List.filled(64, 'a').join()]),
    );
    final token = await rig.database.sealJob('job', 'decisions');
    await rig.database.registerConfirmation('event-job', token);
    await expectLater(commit(token), throwsA(isA<DomainFailure>()));
    expect(await count('revision'), 0);
  });
  test('confirmation ID cannot be rebound to another seal', () async {
    await rig.stage();
    final other = await rig.stage(id: 'other', count: 1);
    await expectLater(
      rig.database.registerConfirmation('event-job', other),
      throwsA(isA<DomainFailure>()),
    );
    expect(await count('confirmation_event'), 2);
  });
  test(
    'duplicate parallel redirects share adjacency while preserving all heads',
    () async {
      final initial = await rig.stage(count: 2);
      await commit(initial);
      final first = fixtureRevision(0), target = fixtureRevision(1);
      await rig.database.createJob('redirects');
      for (final day in ['17', '18']) {
        await rig.database.appendStaging(
          'redirects',
          RevisionEnvelope.create(
            entityType: 'supplier',
            entityId: first.entityId,
            parents: [first.revisionId],
            kind: 'redirect',
            payload: {'target_id': target.entityId},
            authoredAt: '2026-09-${day}T00:00:00.000Z',
            originDeviceId: first.originDeviceId,
          ),
        );
      }
      final token = await rig.database.sealJob('redirects', 'decisions');
      await rig.database.registerConfirmation('event-redirects', token);
      await commit(token);
      expect(
        (await rig.database.rows(
          'SELECT relation_status FROM alias_projection WHERE entity_id=?',
          [Variable(first.entityId)],
        )).single.read<String>('relation_status'),
        'parallelRedirect',
      );
      expect(
        (await rig.database.rows(
          'SELECT COUNT(*) n FROM entity_head WHERE entity_id=?',
          [Variable(first.entityId)],
        )).single.read<int>('n'),
        2,
      );
    },
  );
  test(
    'wrong canonical revision hash cannot be hidden by staging seal',
    () async {
      await rig.database.createJob('job');
      final envelope = fixtureRevision(0);
      await rig.database.customStatement(
        'INSERT INTO staging_revision VALUES(?,?,?)',
        ['job', 'bad-hash', envelope.canonical],
      );
      final token = await rig.database.sealJob('job', 'decisions');
      await rig.database.registerConfirmation('event-job', token);
      await expectLater(
        commit(token),
        throwsA(
          isA<DomainFailure>().having(
            (e) => e.code,
            'code',
            'revision_hash_mismatch',
          ),
        ),
      );
      expect(await count('revision'), 0);
    },
  );
  test(
    'failed cleanup persistently quarantines reads and reset across reopen',
    () async {
      await rig.stage();
      final work = SqlGraphWorkspace(
        rig.database,
        jobId: 'job',
        runId: 'quarantine',
      );
      await rig.database.transaction(
        () => RevisionGraphValidator(pageSize: 2).validate(work),
      );
      await rig.database.customStatement(
        "CREATE TRIGGER prevent_cleanup BEFORE DELETE ON graph_revision BEGIN SELECT RAISE(ABORT,'injected cleanup failure'); END",
      );
      await expectLater(work.discardWork(), throwsA(anything));
      await rig.reopen();
      final reopened = SqlGraphWorkspace(
        rig.database,
        jobId: 'job',
        runId: 'quarantine',
      );
      expect(
        (await rig.database.rows('SELECT state FROM graph_run WHERE run_id=?', [
          Variable('quarantine'),
        ])).single.read<String>('state'),
        'quarantined',
      );
      await expectLater(
        reopened.readRevisions(limit: 2),
        throwsA(isA<DomainFailure>()),
      );
      await expectLater(
        reopened.resetWork(await reopened.currentBinding()),
        throwsA(anything),
      );
      await rig.database.customStatement('DROP TRIGGER prevent_cleanup');
      await reopened.discardWork();
    },
  );
  test('bounded SQL workspace validates deep entity history', () async {
    await rig.database.createJob('job');
    var previous = fixtureRevision(0);
    await rig.database.appendStaging('job', previous);
    for (var i = 1; i <= 200; i++) {
      previous = RevisionEnvelope.create(
        entityType: previous.entityType,
        entityId: previous.entityId,
        parents: [previous.revisionId],
        kind: 'put',
        payload: {...previous.payload, 'name': 'version $i'},
        authoredAt: previous.authoredAt,
        originDeviceId: previous.originDeviceId,
      );
      await rig.database.appendStaging('job', previous);
    }
    final token = await rig.database.sealJob('job', 'decisions');
    await rig.database.registerConfirmation('event-job', token);
    await commit(token);
    expect(await count('revision'), 201);
    expect(await count('entity_head'), 1);
    expect(
      (await rig.database.findRevision(previous.revisionId))!.payload['name'],
      'version 200',
    );
  });
  test(
    'SQL schema independently enforces authority FK and entity UUID uniqueness',
    () async {
      final token = await rig.stage(count: 1);
      await commit(token);
      await expectLater(
        rig.database.customStatement(
          'INSERT INTO entity_identity VALUES(?,?)',
          ['product', fixtureRevision(0).entityId],
        ),
        throwsA(anything),
      );
      await expectLater(
        rig.database.customStatement('INSERT INTO revision VALUES(?,?,?,?)', [
          'bad',
          'supplier',
          'absent',
          '{}',
        ]),
        throwsA(anything),
      );
    },
  );
  test(
    'confirmation cannot be reused at a different epoch with same content',
    () async {
      final token = await rig.stage();
      final altered = PreviewToken(
        version: DatabaseVersion(
          instanceId: token.version.instanceId,
          activeEpoch: 1,
          generation: 0,
        ),
        jobId: token.jobId,
        sealedStagingDigest: token.sealedStagingDigest,
        decisionsDigest: token.decisionsDigest,
        schemaVersion: 2,
      );
      await expectLater(
        rig.database.checkConfirmation('event-job', altered),
        throwsA(isA<DomainFailure>()),
      );
    },
  );
  for (final fault in [null, 'before_commit', 'after_commit']) {
    test(
      'cleanup failure retains original fault and committed receipt at $fault',
      () async {
        final token = await rig.stage(count: 1);
        await rig.database.customStatement(
          "CREATE TRIGGER block_cleanup BEFORE DELETE ON graph_revision BEGIN SELECT RAISE(ABORT,'cleanup'); END",
        );
        try {
          await commit(token, fault: fault);
          fail('Expected cleanup failure');
        } on DomainFailure catch (error) {
          expect(error.code, 'graph_cleanup_failed');
          final dynamic cause = error.cause;
          expect(cause.cleanup, isNotNull);
          if (fault != null) expect(cause.primary, isA<StateError>());
          if (fault == 'before_commit') {
            expect(cause.committedReceipt, isNull);
          } else {
            expect(cause.committedReceipt, isA<CommitReceipt>());
            expect((await commit(token)).resultCount, 1);
          }
        }
      },
    );
  }
  test(
    'restore epoch CAS preserves generation and invalidates old preview',
    () async {
      final token = await rig.stage();
      final rebound = await rig.lock.run(
        () => rig.database.rebindActivationEpoch(
          expectedVersion: token.version,
          newEpoch: 1,
        ),
      );
      expect(rebound.generation, 0);
      expect(rebound.activeEpoch, 1);
      await expectLater(
        rig.database.rebindActivationEpoch(
          expectedVersion: token.version,
          newEpoch: 2,
        ),
        throwsA(isA<DomainFailure>()),
      );
      await expectLater(commit(token), throwsA(isA<DomainFailure>()));
    },
  );
  test('entity keyset plan seeks tuple index', () async {
    await rig.stage();
    final plan = await rig.database.rows(
      'EXPLAIN QUERY PLAN SELECT entity_type,entity_id FROM graph_entity WHERE run_id=? AND (entity_type,entity_id)>(?,?) ORDER BY entity_type,entity_id LIMIT ?',
      [Variable('run'), Variable('supplier'), Variable('id'), Variable(2)],
    );
    final detail = plan.map((r) => r.read<String>('detail')).join('\n');
    expect(detail, contains('(entity_type,entity_id)>(?,?)'));
  });
  test(
    'redirect neighbor plans seek bounded ranges in both directions',
    () async {
      await rig.stage();
      final plan = await rig.database.rows(
        'EXPLAIN QUERY PLAN SELECT entity_type,target_id entity_id FROM graph_redirect WHERE run_id=? AND entity_type=? AND source_id=? AND target_id>? UNION SELECT entity_type,source_id entity_id FROM graph_redirect WHERE run_id=? AND entity_type=? AND target_id=? AND source_id>? ORDER BY entity_type,entity_id LIMIT ?',
        [
          Variable('run'),
          Variable('supplier'),
          Variable('id'),
          Variable('after'),
          Variable('run'),
          Variable('supplier'),
          Variable('id'),
          Variable('after'),
          Variable(2),
        ],
      );
      final detail = plan.map((r) => r.read<String>('detail')).join('\n');
      expect(detail, contains('source_id=? AND target_id>?'));
      expect(detail, contains('target_id=? AND source_id>?'));
    },
  );
  test('100 fixed seed DAGs agree with independent head-set oracle', () async {
    await rig.database.createJob('job');
    final expected = <String, Set<String>>{};
    for (var seed = 0; seed < 100; seed++) {
      final random = Random(seed), root = fixtureRevision(seed);
      final revisions = [root];
      final headIds = {root.revisionId};
      await rig.database.appendStaging('job', root);
      for (var index = 1; index < 6; index++) {
        final parents = <String>{
          revisions[random.nextInt(revisions.length)].revisionId,
        };
        if (random.nextBool()) {
          parents.add(revisions[random.nextInt(revisions.length)].revisionId);
        }
        final revision = RevisionEnvelope.create(
          entityType: root.entityType,
          entityId: root.entityId,
          parents: parents.toList(),
          kind: 'put',
          payload: {...root.payload, 'name': 'seed $seed version $index'},
          authoredAt: root.authoredAt,
          originDeviceId: root.originDeviceId,
        );
        revisions.add(revision);
        headIds.removeAll(parents);
        headIds.add(revision.revisionId);
        await rig.database.appendStaging('job', revision);
      }
      expected[root.entityId] = headIds;
    }
    final token = await rig.database.sealJob('job', 'decisions');
    await rig.database.registerConfirmation('event-job', token);
    await commit(token);
    for (final entry in expected.entries) {
      final actual = (await rig.database.rows(
        'SELECT revision_id FROM entity_head WHERE entity_id=?',
        [Variable(entry.key)],
      )).map((r) => r.read<String>('revision_id')).toSet();
      expect(actual, entry.value);
    }
  });
  test(
    'committed staging cleanup keeps durable event retry and seal',
    () async {
      final token = await rig.stage();
      await commit(token);
      await rig.lock.run(() => rig.database.cleanupStaging('job'));
      expect(await count('staging_revision'), 0);
      final result = await commit(token);
      expect(result.resultCount, 5);
      expect(result.version.generation, 1);
      expect(
        (await rig.database.job('job')).read<String>('sealed_digest'),
        token.sealedStagingDigest,
      );
      await expectLater(
        rig.database.appendStaging('job', fixtureRevision(99)),
        throwsA(anything),
      );
    },
  );
  test(
    'cancelled sealed staging can be reclaimed but never committed',
    () async {
      final token = await rig.stage();
      await expectLater(
        rig.lock.run(() => rig.database.cleanupStaging('job')),
        throwsA(isA<DomainFailure>()),
      );
      await rig.database.customStatement(
        'UPDATE import_job SET state=? WHERE job_id=?',
        ['cancelled', 'job'],
      );
      await rig.lock.run(() => rig.database.cleanupStaging('job'));
      expect(await count('staging_revision'), 0);
      await expectLater(
        commit(token),
        throwsA(
          isA<DomainFailure>().having((e) => e.code, 'code', 'job_terminal'),
        ),
      );
      expect(await count('revision'), 0);
    },
  );
  test('unsupported migration leaves old schema and data intact', () async {
    await rig.database.close();
    final file = File('${directory.path}/old.sqlite');
    final old = _LegacyDatabase(NativeDatabase(file));
    await old.customStatement('CREATE TABLE legacy(value TEXT NOT NULL)');
    await old.customStatement('INSERT INTO legacy VALUES(?)', ['original']);
    await old.close();
    final candidate = SupplierDatabase(
      NativeDatabase(file),
      instanceId: 'candidate',
    );
    await expectLater(candidate.currentVersion(), throwsStateError);
    await candidate.close();
    final reopened = _LegacyDatabase(NativeDatabase(file));
    expect(
      (await reopened.customSelect('SELECT value FROM legacy').getSingle())
          .read<String>('value'),
      'original',
    );
    expect(
      (await reopened.customSelect('PRAGMA user_version').getSingle())
          .read<int>('user_version'),
      1,
    );
    expect(
      await reopened
          .customSelect(
            "SELECT name FROM sqlite_master WHERE name='database_meta'",
          )
          .get(),
      isEmpty,
    );
    await reopened.close();
  });
}

class _LegacyDatabase extends GeneratedDatabase {
  _LegacyDatabase(super.executor);
  @override
  int get schemaVersion => 1;
  @override
  Iterable<TableInfo<Table, Object?>> get allTables => const [];
}
