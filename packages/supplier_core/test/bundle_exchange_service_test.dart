import 'dart:convert';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:supplier_core/src/application/backup_service.dart';
import 'package:supplier_core/src/application/bundle_exchange_service.dart';
import 'package:supplier_core/src/contracts.dart';
import 'package:supplier_core/src/data/commit_coordinator.dart';
import 'package:supplier_core/src/data/database.dart';
import 'package:supplier_core/src/domain/revision.dart';
import 'package:supplier_core/src/exchange/bundle_database.dart';
import 'package:supplier_core/src/exchange/bundle_export.dart';
import 'package:supplier_core/src/exchange/bundle_import.dart';
import 'package:supplier_core/src/exchange/projection_digest.dart';
import 'package:supplier_core/src/exchange/xlsx_staging.dart';
import 'package:test/test.dart';
import 'bundle_test.dart' show TestBuffer, testBudget;
import 'support/test_rig.dart';

SupplierDatabase _database() => SupplierDatabase(
  NativeDatabase.memory(),
  instanceId: '11111111-1111-4111-8111-111111111111',
);

class _Artifact implements BackupArtifact {
  final buffer = TestBuffer();
  @override
  InputSource get source => buffer;
  @override
  OutputTarget get output => buffer;
  @override
  Future<void> dispose() async {
    buffer.bytes = [];
  }
}

Future<void> _seed(
  SupplierDatabase db,
  TestWriteLock lock,
  RevisionEnvelope revision,
) async {
  final id = newStorageId();
  await db.createJob(id);
  await db.appendStaging(id, revision);
  final token = await db.sealJob(id, 'seed');
  await db.registerConfirmation(id, token);
  await CommitCoordinator(
    database: db,
    writeLock: lock,
    readActiveVersion: db.currentVersion,
  ).commitStaged(
    jobId: id,
    expectedPreviewToken: token,
    confirmationEventId: id,
  );
}

class _Rig {
  final db = _database(), lock = TestWriteLock();
  String? faultAt;
  bool failBackup = false;
  bool failAssociation = false;
  final associatedJobs = <String>[];
  int backups = 0;
  late final coordinator = CommitCoordinator(
    database: db,
    writeLock: lock,
    readActiveVersion: db.currentVersion,
    pageSize: 1,
    fault: (point) async {
      if (point == faultAt) {
        faultAt = null;
        throw StateError('injected $point');
      }
    },
  );
  BundleExchangeService service() => BundleExchangeService(
    coordinator: coordinator,
    backups: BackupService(
      database: db,
      writeLock: lock,
      readActiveVersion: db.currentVersion,
      createArtifact: () async => _Artifact(),
    ),
    createBackupDestination: () async {
      backups++;
      if (failBackup) throw StateError('backup unavailable');
      final target = TestBuffer();
      return BundleBackupDestination(
        target,
        target,
        onVerified: (id) async {
          if (failAssociation) throw StateError('backup locator unavailable');
          associatedJobs.add(id);
        },
      );
    },
  );
  late final exchange = service();
  Future<BundleConfirmation> prepare(InputSource input, {String? jobId}) async {
    final job = jobId == null
        ? await exchange.beginBundle(input)
        : await exchange.jobs.load(jobId);
    final private = _database();
    addTearDown(private.close);
    return exchange.prepare(
      job.id,
      input,
      staging: DatabaseBundleStaging(
        database: private,
        boundVersion: job.version,
      ),
      budget: testBudget,
      createXlsxStaging: () async => XlsxStaging(NativeDatabase.memory()),
    );
  }

  Future<int> count() async =>
      (await db.rows('SELECT COUNT(*) n FROM revision')).single.read<int>('n');
}

void main() {
  // Every source, destination and verifier has its own NativeDatabase executor.
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late TestBuffer input;
  setUpAll(() async {
    final db = _database(), private = <SupplierDatabase>[];
    await _seed(db, TestWriteLock(), fixtureRevision(1));
    input = TestBuffer();
    try {
      await exportBundle(
        snapshot: DatabaseBundleSnapshot(
          database: db,
          version: await db.currentVersion(),
          columns: BundleColumns.schema2(),
        ),
        columns: BundleColumns.schema2(),
        budget: testBudget,
        bundleId: '33333333-3333-4333-8333-333333333333',
        exportedAt: '2026-09-21T00:00:00Z',
        exporterVersion: 'test',
        createArtifact: () async => _Artifact(),
        createXlsxStaging: () async => XlsxStaging(NativeDatabase.memory()),
        createBundleStaging: (version) async {
          final staged = _database();
          private.add(staged);
          return DatabaseBundleStaging(database: staged, boundVersion: version);
        },
        target: input,
      );
    } finally {
      await db.close();
      for (final stage in private) {
        await stage.close();
      }
    }
  });
  late _Rig rig;
  setUp(() {
    rig = _Rig();
    addTearDown(rig.db.close);
  });
  for (final action in ['edit', 'cancel']) {
    test(
      '$action during parsing prevents partial business publication',
      () async {
        var id = '', fired = false;
        final source = _ObservedSource(input, () async {
          if (id.isEmpty ||
              fired ||
              (await rig.exchange.jobs.load(id)).state != JobState.parsing) {
            return;
          }
          fired = true;
          if (action == 'edit') {
            await _seed(rig.db, rig.lock, fixtureRevision(2));
          } else {
            await rig.exchange.cancel(id);
          }
        });
        id = (await rig.exchange.beginBundle(source)).id;
        await expectLater(
          rig.prepare(source, jobId: id),
          throwsA(isA<DomainFailure>()),
        );
        expect(fired, true);
        expect(await rig.count(), action == 'edit' ? 1 : 0);
        expect(rig.backups, 0);
        expect(
          (await rig.service().resume(id)).state,
          action == 'edit' ? JobState.failed : JobState.cancelled,
        );
      },
    );
  }

  test(
    'full bundle confirmation commits once and reimport deduplicates the revision set',
    () async {
      final confirmed = await rig.prepare(input);
      expect(await rig.count(), 0);
      expect((await rig.db.currentVersion()).generation, 0);
      final receipt = await rig.exchange.commit(confirmed);
      expect(await rig.count(), 1);
      expect(rig.backups, 1);
      expect(receipt.version.generation, 1);
      final reopened = await rig.service().confirmation(confirmed.token.jobId);
      expect(reopened.eventId, confirmed.eventId);
      await rig.exchange.commit(reopened);
      expect(rig.backups, 1);
      expect(await rig.count(), 1);
      final repeated = await rig.prepare(input);
      await rig.exchange.commit(repeated);
      expect(await rig.count(), 1);
    },
  );
  for (final broken in ['missing', 'damaged', 'future']) {
    test('$broken bundle is rejected with no business rows visible', () async {
      final archive = await BundleArchive.open(input, testBudget);
      late InputSource source;
      if (broken == 'damaged') {
        final copy = TestBuffer(List.of(input.bytes));
        copy.bytes[archive.entries['revisions-000001.xlsx']!.start] ^= 1;
        source = copy;
      } else {
        final entries = <({String path, InputSource source})>[];
        for (final entry in archive.entries.entries) {
          if (broken == 'missing' && entry.key == 'quotations-000001.xlsx') {
            continue;
          }
          InputSource value = entry.value;
          if (broken == 'future' && entry.key == 'manifest.json') {
            final manifest =
                jsonDecode(
                      utf8.decode(
                        await bundleRange(value, 0, await value.length()),
                      ),
                    )
                    as Map<String, Object?>;
            manifest['schema_version'] = 3;
            value = TestBuffer(utf8.encode(jsonEncode(manifest)));
          }
          entries.add((path: entry.key, source: value));
        }
        final copy = TestBuffer();
        await copy.write(encodeBundleStore(entries, testBudget));
        source = copy;
      }
      await expectLater(rig.prepare(source), throwsA(isA<DomainFailure>()));
      expect(await rig.count(), 0);
      expect(rig.backups, 0);
      expect((await rig.db.currentVersion()).generation, 0);
    });
  }
  test(
    'editing after preview refuses old confirmation and requires a fresh task',
    () async {
      final confirmed = await rig.prepare(input);
      await _seed(rig.db, rig.lock, fixtureRevision(2));
      await expectLater(
        rig.exchange.commit(confirmed),
        throwsA(isA<DomainFailure>()),
      );
      expect(await rig.count(), 1);
      expect(rig.backups, 0);
      final retry = await rig.exchange.reparse(confirmed.token.jobId, input);
      final fresh = await rig.prepare(input, jobId: retry.id);
      await rig.exchange.commit(fresh);
      expect(await rig.count(), 2);
    },
  );
  test(
    'local root collision rejects incoming union before preview confirmation',
    () async {
      final root = fixtureRevision(1);
      final collision = RevisionEnvelope.create(
        entityType: root.entityType,
        entityId: root.entityId,
        parents: [],
        kind: 'put',
        payload: {...root.payload, 'name': 'Independent root'},
        authoredAt: root.authoredAt,
        originDeviceId: root.originDeviceId,
      );
      await _seed(rig.db, rig.lock, collision);
      await expectLater(rig.prepare(input), throwsA(isA<DomainFailure>()));
      expect(await rig.count(), 1);
      expect(rig.backups, 0);
    },
  );
  for (final point in ['page:1', 'before_commit']) {
    test(
      '$point fault rolls back the whole batch and the same event can retry',
      () async {
        final confirmed = await rig.prepare(input);
        rig.faultAt = point;
        await expectLater(
          rig.exchange.commit(confirmed),
          throwsA(isA<StateError>()),
        );
        expect(await rig.count(), 0);
        expect((await rig.db.currentVersion()).generation, 0);
        expect(
          (await rig.exchange.resume(confirmed.token.jobId)).state,
          JobState.previewReady,
        );
        await rig.exchange.commit(confirmed);
        expect(await rig.count(), 1);
        expect((await rig.db.currentVersion()).generation, 1);
      },
    );
  }
  test(
    'lost commit response reopens committed receipt and retries without another backup',
    () async {
      final confirmed = await rig.prepare(input);
      rig.faultAt = 'after_commit';
      await expectLater(
        rig.exchange.commit(confirmed),
        throwsA(isA<StateError>()),
      );
      expect(
        (await rig.service().resume(confirmed.token.jobId)).state,
        JobState.committed,
      );
      final reopened = await rig.service().confirmation(confirmed.token.jobId);
      await rig.service().commit(reopened);
      expect(await rig.count(), 1);
      expect((await rig.db.currentVersion()).generation, 1);
      expect(rig.backups, 1);
    },
  );
  test(
    'cancelled preview remains cancelled after reopen and cannot commit',
    () async {
      final confirmed = await rig.prepare(input);
      await rig.exchange.cancel(confirmed.token.jobId);
      expect(
        (await rig.service().resume(confirmed.token.jobId)).state,
        JobState.cancelled,
      );
      await expectLater(
        rig.service().commit(confirmed),
        throwsA(isA<DomainFailure>()),
      );
      expect(await rig.count(), 0);
      expect(rig.backups, 0);
    },
  );
  test(
    'backup failure leaves the active database and preview retryable',
    () async {
      final confirmed = await rig.prepare(input);
      rig.failBackup = true;
      await expectLater(
        rig.exchange.commit(confirmed),
        throwsA(isA<StateError>()),
      );
      expect(await rig.count(), 0);
      rig.failBackup = false;
      await rig.exchange.commit(confirmed);
      expect(await rig.count(), 1);
    },
  );
  test(
    'backup locator must be associated before commit and failure stays retryable',
    () async {
      final confirmed = await rig.prepare(input);
      rig.failAssociation = true;
      await expectLater(rig.exchange.commit(confirmed), throwsStateError);
      expect(await rig.count(), 0);
      expect(
        (await rig.exchange.jobs.load(confirmed.token.jobId)).state,
        JobState.previewReady,
      );
      rig.failAssociation = false;
      await rig.exchange.commit(confirmed);
      expect(rig.associatedJobs, [confirmed.token.jobId]);
    },
  );
}

class _ObservedSource implements InputSource {
  _ObservedSource(this.source, this.observe);
  final InputSource source;
  final Future<void> Function() observe;
  @override
  String get displayName => source.displayName;
  @override
  Future<int> length() => source.length();
  @override
  Stream<List<int>> openRange(int start, int endExclusive) async* {
    await observe();
    yield* source.openRange(start, endExclusive);
  }
}
