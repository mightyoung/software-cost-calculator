import 'dart:io';
import 'package:drift/native.dart';
import 'package:supplier_core/src/contracts.dart';
import 'package:supplier_core/src/data/database.dart';
import 'package:supplier_core/src/data/commit_coordinator.dart';
import 'package:supplier_core/src/domain/canonical.dart';
import 'package:supplier_core/src/domain/revision.dart';
import 'package:supplier_core/src/exchange/bundle_database.dart';
import 'package:supplier_core/src/exchange/bundle_manifest.dart';
import 'package:supplier_core/src/exchange/projection_digest.dart';
import 'package:test/test.dart';
import 'support/test_rig.dart';
import 'bundle_test.dart' show testBudget, emptySha;

final columns = BundleColumns({
  for (final kind in bundleKinds.skip(1))
    kind: ['entity_id', 'revision_id', 'relation_status', 'payload'],
});
const binding = DatabaseVersion(
  instanceId: '11111111-1111-4111-8111-111111111111',
  activeEpoch: 2,
  generation: 7,
);
SupplierDatabase database() => SupplierDatabase(
  NativeDatabase.memory(),
  instanceId: '22222222-2222-4222-8222-222222222222',
);

({BundleManifest manifest, Map<String, List<BundleRow>> rows}) bundle(
  List<RevisionEnvelope> revisions, {
  Map<String, List<BundleRow>>? projections,
}) {
  final rows = {for (final kind in bundleKinds) kind: <BundleRow>[]};
  for (final revision in revisions) {
    rows['revisions']!.add(
      BundleRow(revision.revisionId, [
        revision.revisionId,
        revision.entityType,
        revision.entityId,
        revision.canonical,
      ]),
    );
    if (projections == null) {
      rows['${revision.entityType}s']!.add(
        BundleRow(revision.entityId, [
          revision.entityId,
          revision.revisionId,
          'active',
          canonicalJson(revision.payload),
        ]),
      );
    }
  }
  if (projections != null) {
    for (final entry in projections.entries) {
      rows[entry.key] = entry.value;
    }
  }
  final digests = BundleDigests(columns);
  for (final kind in bundleKinds) {
    rows[kind]!.sort((a, b) => a.key.compareTo(b.key));
    digests.beginKind(kind);
    for (final row in rows[kind]!) {
      digests.add(row);
    }
  }
  final result = digests.finish();
  return (
    manifest: BundleManifest(
      bundleId: '33333333-3333-4333-8333-333333333333',
      exportedAt: '2026-09-21T00:00:00.000Z',
      exporterVersion: 'test',
      revisionCount: revisions.length,
      entityCounts: {
        for (final kind in bundleKinds.skip(1)) kind: rows[kind]!.length,
      },
      revisionsDigest: result.revisions,
      businessDigest: result.business,
      volumes: [
        for (final kind in bundleKinds)
          BundleVolume(
            kind: kind,
            index: 1,
            rowCount: rows[kind]!.length,
            sha256: emptySha,
            compressedBytes: 22,
            expandedBytes: 1,
          ),
      ],
      budget: testBudget,
    ),
    rows: rows,
  );
}

Future<void> append(
  DatabaseBundleStaging staging,
  ({BundleManifest manifest, Map<String, List<BundleRow>> rows}) input,
) async {
  await staging.begin(input.manifest);
  for (final kind in bundleKinds) {
    var number = 2;
    for (final row in input.rows[kind]!) {
      await staging.append(
        kind,
        row,
        path: '$kind-000001.xlsx',
        rowNumber: number++,
      );
    }
  }
}

void main() {
  test(
    'dangling contact supplier reference rejects a closed parent graph',
    () async {
      final db = database();
      addTearDown(db.close);
      final root = fixtureRevision(1);
      final contact = RevisionEnvelope.create(
        entityType: 'contact',
        entityId: fixtureRevision(2).entityId,
        parents: [],
        kind: 'put',
        payload: {
          'supplier_id': root.entityId,
          'name': 'Contact',
          'phone': '00123',
          'wechat': null,
          'email': null,
          'notes': null,
        },
        authoredAt: root.authoredAt,
        originDeviceId: root.originDeviceId,
      );
      final input = bundle([contact]);
      final staging = DatabaseBundleStaging(
        database: db,
        boundVersion: binding,
      );
      await append(staging, input);
      await expectLater(
        staging.verifyClosureAndProjection(input.manifest, columns),
        throwsA(isA<DomainFailure>()),
      );
    },
  );
  test(
    'two distinct roots for one entity reject the entire incoming graph',
    () async {
      final db = database();
      addTearDown(db.close);
      final root = fixtureRevision(1);
      final collision = RevisionEnvelope.create(
        entityType: 'supplier',
        entityId: root.entityId,
        parents: [],
        kind: 'put',
        payload: {...root.payload, 'name': 'Different root'},
        authoredAt: root.authoredAt,
        originDeviceId: root.originDeviceId,
      );
      final input = bundle(
        [root, collision],
        projections: {
          'suppliers': [
            BundleRow(root.entityId, [
              root.entityId,
              root.revisionId,
              'active',
              canonicalJson(root.payload),
            ]),
          ],
        },
      );
      final staging = DatabaseBundleStaging(
        database: db,
        boundVersion: binding,
      );
      await append(staging, input);
      await expectLater(
        staging.verifyClosureAndProjection(input.manifest, columns),
        throwsA(isA<DomainFailure>()),
      );
    },
  );
  test(
    'parallel heads retain conflicted projection without selecting a clock winner',
    () async {
      final db = database();
      addTearDown(db.close);
      final root = fixtureRevision(1);
      RevisionEnvelope branch(String name) => RevisionEnvelope.create(
        entityType: 'supplier',
        entityId: root.entityId,
        parents: [root.revisionId],
        kind: 'put',
        payload: {...root.payload, 'name': name},
        authoredAt: root.authoredAt,
        originDeviceId: root.originDeviceId,
      );
      final input = bundle(
        [root, branch('Left'), branch('Right')],
        projections: {
          'suppliers': [
            BundleRow(root.entityId, [root.entityId, null, 'conflicted', null]),
          ],
        },
      );
      final staging = DatabaseBundleStaging(
        database: db,
        boundVersion: binding,
      );
      await append(staging, input);
      await staging.verifyClosureAndProjection(input.manifest, columns);
      await staging.seal(emptySha);
      expect(
        (await db.rows(
          "SELECT COUNT(*) n FROM graph_head WHERE run_id='bundle-incoming-graph'",
        )).single.read<int>('n'),
        2,
      );
    },
  );
  test(
    'private graph validation seals durable input without publishing revisions or a confirmation',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'bundle-staging-test-',
      );
      final file = File('${directory.path}/staging.sqlite');
      SupplierDatabase open() => SupplierDatabase(
        NativeDatabase(file),
        instanceId: '22222222-2222-4222-8222-222222222222',
      );
      var db = open();
      addTearDown(() async {
        await db.close();
        await directory.delete(recursive: true);
      });
      final staging = DatabaseBundleStaging(
            database: db,
            boundVersion: binding,
          ),
          input = bundle([fixtureRevision(1), fixtureRevision(2)]);
      await append(staging, input);
      await staging.verifyClosureAndProjection(input.manifest, columns);
      await db.close();
      db = open();
      await DatabaseBundleStaging(
        database: db,
        boundVersion: binding,
      ).seal(emptySha);
      expect(
        (await db.rows(
          'SELECT state FROM bundle_state',
        )).single.read<String>('state'),
        'sealed',
      );
      await expectLater(
        db.customStatement('DELETE FROM bundle_row'),
        throwsA(isA<Exception>()),
      );
      expect(await db.rows('SELECT * FROM revision'), isEmpty);
      expect(await db.rows('SELECT * FROM confirmation_event'), isEmpty);
      expect((await db.currentVersion()).generation, 0);
    },
  );
  test(
    'duplicate incoming identity reports source location and quarantines staging',
    () async {
      final db = database();
      addTearDown(db.close);
      final staging = DatabaseBundleStaging(
            database: db,
            boundVersion: binding,
          ),
          input = bundle([fixtureRevision(1)]);
      await append(staging, input);
      await expectLater(
        staging.append(
          'revisions',
          input.rows['revisions']!.single,
          path: 'revisions-000002.xlsx',
          rowNumber: 17,
        ),
        throwsA(
          isA<DomainFailure>().having(
            (e) => e.field,
            'location',
            'revisions-000002.xlsx:17',
          ),
        ),
      );
      expect(
        (await db.rows(
          'SELECT COUNT(*) n FROM staging_revision',
        )).single.read<int>('n'),
        0,
      );
    },
  );
  test('missing parent is rejected by persisted graph validation', () async {
    final db = database();
    addTearDown(db.close);
    final child = fixtureRevision(1, parents: [emptySha]),
        input = bundle([child]);
    final staging = DatabaseBundleStaging(database: db, boundVersion: binding);
    await append(staging, input);
    await expectLater(
      staging.verifyClosureAndProjection(input.manifest, columns),
      throwsA(isA<DomainFailure>()),
    );
    expect(
      (await db.rows(
        'SELECT state FROM bundle_state',
      )).single.read<String>('state'),
      'failed',
    );
    expect(await db.rows('SELECT * FROM staging_revision'), isEmpty);
    await expectLater(staging.seal(emptySha), throwsA(isA<DomainFailure>()));
  });
  test('cross-entity parent is rejected', () async {
    final db = database();
    addTearDown(db.close);
    final root = fixtureRevision(1),
        child = fixtureRevision(2, parents: [fixtureRevision(1).revisionId]);
    final input = bundle([root, child]),
        staging = DatabaseBundleStaging(database: db, boundVersion: binding);
    await append(staging, input);
    await expectLater(
      staging.verifyClosureAndProjection(input.manifest, columns),
      throwsA(isA<DomainFailure>()),
    );
  });
  test(
    'projection tampering fails even when manifest business digest matches tampered cells',
    () async {
      final db = database();
      addTearDown(db.close);
      final root = fixtureRevision(1);
      final input = bundle(
        [root],
        projections: {
          'suppliers': [
            BundleRow(root.entityId, [
              root.entityId,
              root.revisionId,
              'deleted',
              null,
            ]),
          ],
        },
      );
      final staging = DatabaseBundleStaging(
        database: db,
        boundVersion: binding,
      );
      await append(staging, input);
      await expectLater(
        staging.verifyClosureAndProjection(input.manifest, columns),
        throwsA(
          isA<DomainFailure>().having(
            (e) => e.code,
            'code',
            'BUNDLE_PROJECTION_MISMATCH',
          ),
        ),
      );
    },
  );
  test('seal rechecks staged content after validation', () async {
    final db = database();
    addTearDown(db.close);
    final input = bundle([fixtureRevision(1)]);
    final staging = DatabaseBundleStaging(database: db, boundVersion: binding);
    await append(staging, input);
    await staging.verifyClosureAndProjection(input.manifest, columns);
    await db.customStatement("DELETE FROM bundle_row WHERE kind='suppliers'");
    await expectLater(staging.seal(emptySha), throwsA(isA<DomainFailure>()));
  });
  test(
    'incoming tombstone projection uses the deleted head and blank payload',
    () async {
      final db = database();
      addTearDown(db.close);
      final root = fixtureRevision(1);
      final deleted = RevisionEnvelope.create(
        entityType: 'supplier',
        entityId: root.entityId,
        parents: [root.revisionId],
        kind: 'delete',
        payload: {},
        authoredAt: '2026-09-21T00:00:00Z',
        originDeviceId: root.originDeviceId,
      );
      final input = bundle(
        [root, deleted],
        projections: {
          'suppliers': [
            BundleRow(root.entityId, [
              root.entityId,
              deleted.revisionId,
              'deleted',
              null,
            ]),
          ],
        },
      );
      final staging = DatabaseBundleStaging(
        database: db,
        boundVersion: binding,
      );
      await append(staging, input);
      await staging.verifyClosureAndProjection(input.manifest, columns);
      await staging.seal(emptySha);
    },
  );
  test(
    'snapshot matches persisted heads/projections and refuses a changed generation',
    () async {
      final db = database();
      addTearDown(db.close);
      await db.createJob('seed');
      await db.appendStaging('seed', fixtureRevision(1));
      await db.appendStaging('seed', fixtureRevision(2));
      final token = await db.sealJob('seed', 'test');
      await db.registerConfirmation('seed-event', token);
      await CommitCoordinator(
        database: db,
        writeLock: TestWriteLock(),
        readActiveVersion: db.currentVersion,
      ).commitStaged(
        jobId: 'seed',
        expectedPreviewToken: token,
        confirmationEventId: 'seed-event',
      );
      final snapshot = DatabaseBundleSnapshot(
        database: db,
        version: await db.currentVersion(),
        columns: columns,
      );
      final revisions = await snapshot.page('revisions', limit: 1).toList();
      expect(revisions.length, 1);
      final next = await snapshot
          .page('revisions', afterKey: revisions.single.key, limit: 1)
          .toList();
      expect(next.length, 1);
      expect(next.single.key.compareTo(revisions.single.key), greaterThan(0));
      final suppliers = await snapshot.page('suppliers', limit: 5).toList();
      expect(suppliers.length, 2);
      expect(suppliers.first.cells[2], 'active');
      await db.customStatement(
        'UPDATE database_meta SET generation=generation+1',
      );
      await expectLater(
        snapshot.page('suppliers', limit: 1).toList(),
        throwsA(isA<DomainFailure>()),
      );
      await expectLater(
        DatabaseBundleStaging(
          database: db,
          boundVersion: binding,
        ).begin(bundle([]).manifest),
        throwsA(
          isA<DomainFailure>().having(
            (e) => e.code,
            'code',
            'BUNDLE_STAGING_NOT_EMPTY',
          ),
        ),
      );
    },
  );
}
