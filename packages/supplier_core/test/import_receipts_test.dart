import 'package:drift/native.dart';
import 'package:supplier_core/supplier_core.dart';
import 'package:supplier_core/src/exchange/import_receipts.dart';
import 'package:test/test.dart';
import 'domain_test.dart' show quote;
import 'support/test_rig.dart';

const device = '00000000-0000-4000-8000-000000000071';
void main() {
  late SupplierDatabase db;
  late ImportReceiptStore store;
  late TestWriteLock lock;
  late SourceFingerprint source;
  late RevisionEnvelope supplier, product;
  RevisionEnvelope quotation(
    int i, {
    List<String> parents = const [],
    String? notes,
  }) => RevisionEnvelope.create(
    entityType: 'quotation',
    entityId:
        '00000000-0000-4000-8000-${(1000 + i).toString().padLeft(12, '0')}',
    parents: parents,
    kind: 'put',
    payload: {
      ...quote(),
      'supplier_id': supplier.entityId,
      'product_id': product.entityId,
      'capture_mode': 'standard',
      'notes': notes,
    },
    authoredAt: '2026-09-18T00:00:00.000Z',
    originDeviceId: device,
  );
  OperationFingerprint operation({
    int quantity = 1,
    ImportIntent intent = ImportIntent.newInquiry,
    String? note,
    SourceFingerprint? incoming,
  }) => OperationFingerprint.create(
    source: incoming ?? source,
    intent: intent,
    originalBindings: {'quotation_id': ''},
    operations: {
      'notes': note == null
          ? const FieldOperation.clear()
          : FieldOperation.set(note),
    },
    confirmedQuantity: quantity,
  );
  setUp(() async {
    db = SupplierDatabase(NativeDatabase.memory(), instanceId: device);
    store = ImportReceiptStore(db);
    lock = TestWriteLock();
    source = SourceFingerprint.create(
      fields: {
        'price': SourceCell.value('12.340001'),
        'notes': const SourceCell.blank(),
      },
      inputIdentity: {'record_id': 'incoming'},
      mappingSemantics: {'price': 'price'},
      batchDefaults: {},
      captureMode: 'standard',
    );
    supplier = fixtureRevision(1);
    product = RevisionEnvelope.create(
      entityType: 'product',
      entityId: '00000000-0000-4000-8000-000000000081',
      parents: [],
      kind: 'put',
      payload: {
        'name': 'Product',
        'unit': '件',
        'brand': null,
        'model': null,
        'specification': null,
        'category': null,
        'notes': null,
      },
      authoredAt: '2026-09-18T00:00:00.000Z',
      originDeviceId: device,
    );
    await db.createJob('job');
    for (final revision in [supplier, product]) {
      await db.appendStaging('job', revision);
    }
  });
  tearDown(() => db.close());
  Future<void> apply(
    String id,
    List<RevisionEnvelope> revisions, {
    OperationFingerprint? op,
  }) async {
    for (final revision in revisions) {
      await db.appendStaging('job', revision);
    }
    await store.stageDecision(
      jobId: 'job',
      decisionId: id,
      action: ImportDecisionAction.apply,
      source: source,
      operation: op ?? operation(quantity: revisions.length),
      originalTargetId: '',
      confirmationDetails: {'row': id, 'conversionsAcknowledged': true},
      resultRevisionIds: revisions.map((r) => r.revisionId),
    );
  }

  Future<void> commit() async {
    final token = await db.sealJob(
      'job',
      await store.computeDecisionDigest('job'),
    );
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
  }

  test(
    'empty synthetic jobs have explicit zero count and stable digest',
    () async {
      final result = await store.inspectDecisionDigest('job');
      expect(result.hasDecisions, isFalse);
      expect(result.resultCount, 0);
      expect(await store.computeDecisionDigest('job'), result.digest);
      await store.validateStaged('job');
    },
  );
  test(
    'more than one SQL page of main results keeps exact quantity and pages success',
    () async {
      await apply('decision', [for (var i = 0; i < 35; i++) quotation(i)]);
      final before = await store.inspectDecisionDigest('job');
      expect(before.resultCount, 35);
      expect(before.decisionCount, 1);
      await store.validateStaged('job');
      await commit();
      final operations = await store.readSourceReceipts(source);
      expect(operations.items, hasLength(1));
      expect(operations.items.single.legacyDetailsUnknown, isFalse);
      final op = operations.items.single.operationFingerprint;
      final a = await store.readReceiptResults(
        eventId: 'event',
        source: source,
        operationFingerprint: op,
        limit: 32,
      );
      final b = await store.readReceiptResults(
        eventId: 'event',
        source: source,
        operationFingerprint: op,
        limit: 32,
        after: a.nextCursor,
      );
      expect({...a.revisionIds, ...b.revisionIds}, hasLength(35));
      expect(b.nextCursor, isNull);
      expect(await store.computeDecisionDigest('job'), before.digest);
    },
  );
  test(
    'decision digest spans pages and includes exclusions acknowledgements and allocations',
    () async {
      for (var i = 0; i < 35; i++) {
        await store.stageDecision(
          jobId: 'job',
          decisionId: 'skip-$i',
          action: ImportDecisionAction.skip,
          source: source,
          originalTargetId: '',
          confirmationDetails: {'row': i},
        );
      }
      final before = await store.computeDecisionDigest('job');
      await store.stageDecision(
        jobId: 'job',
        decisionId: 'error',
        action: ImportDecisionAction.excludeError,
        originalTargetId: '',
        confirmationDetails: {'acknowledged': true},
        exclusionReason: 'Invalid price',
      );
      final after = await store.inspectDecisionDigest('job');
      expect(after.decisionCount, 36);
      expect(after.digest, isNot(before));
      await db.customStatement(
        "DELETE FROM staging_revision WHERE job_id='job'",
      );
      await store.validateStaged('job');
      await commit();
      expect((await store.readSourceReceipts(source)).items, isEmpty);
    },
  );
  test(
    'source-first operations page without selecting a winner and cursor binds version',
    () async {
      for (var i = 0; i < 35; i++) {
        await apply('apply-$i', [
          quotation(i, notes: 'operation-$i'),
        ], op: operation(note: 'operation-$i'));
      }
      await commit();
      final a = await store.readSourceReceipts(source, limit: 20);
      final b = await store.readSourceReceipts(
        source,
        limit: 20,
        after: a.nextCursor,
      );
      expect([...a.items, ...b.items], hasLength(35));
      expect(b.nextCursor, isNull);
      expect({
        ...a.items.map((r) => r.operationFingerprint),
        ...b.items.map((r) => r.operationFingerprint),
      }, hasLength(35));
      await db.customStatement(
        'UPDATE database_meta SET generation=generation+1',
      );
      await expectLater(
        store.readSourceReceipts(source, after: a.nextCursor),
        throwsA(
          isA<DomainFailure>().having((e) => e.code, 'code', 'STALE_CURSOR'),
        ),
      );
    },
  );
  test(
    'legacy canonical remains unknown and unsuccessful event never matches',
    () async {
      final q = quotation(1);
      await apply('apply', [q]);
      await commit();
      final legacyOp = canonicalSha256({'legacy': 1});
      // Explicit SQL fixture representing a restored v1 receipt without details.
      await db.customStatement(
        'INSERT INTO import_row_receipt VALUES(?,?,?,?,?,?)',
        ['event', 1, source.digest, legacyOp, 'original', q.revisionId],
      );
      await db.createJob('unfinished');
      final token = await db.sealJob('unfinished', 'old-digest');
      await db.registerConfirmation('unfinished-event', token);
      await db.customStatement(
        'INSERT INTO import_row_receipt VALUES(?,?,?,?,?,?)',
        [
          'unfinished-event',
          1,
          source.digest,
          legacyOp,
          'original',
          q.revisionId,
        ],
      );
      final page = await store.readSourceReceipts(source);
      expect(page.items, hasLength(2));
      expect(
        page.items
            .singleWhere((r) => r.operationFingerprint == legacyOp)
            .legacyDetailsUnknown,
        isTrue,
      );
      expect(
        (await store.readReceiptResults(
          eventId: 'unfinished-event',
          source: source,
          operationFingerprint: legacyOp,
        )).revisionIds,
        isEmpty,
      );
    },
  );
  test(
    'invalid apply rolls back decision and allocations atomically',
    () async {
      final q = quotation(1);
      await db.appendStaging('job', q);
      await expectLater(
        store.stageDecision(
          jobId: 'job',
          decisionId: 'bad',
          action: ImportDecisionAction.apply,
          source: source,
          operation: operation(quantity: 2),
          originalTargetId: '',
          confirmationDetails: {},
          resultRevisionIds: [q.revisionId],
        ),
        throwsA(isA<DomainFailure>()),
      );
      expect(await db.rows('SELECT * FROM staging_import_decision'), isEmpty);
      expect(await db.rows('SELECT * FROM staging_import_result'), isEmpty);
    },
  );
  test(
    'auxiliary and duplicate entity results cannot satisfy quantity',
    () async {
      await expectLater(
        store.stageDecision(
          jobId: 'job',
          decisionId: 'aux',
          action: ImportDecisionAction.apply,
          source: source,
          operation: operation(),
          originalTargetId: '',
          confirmationDetails: {},
          resultRevisionIds: [supplier.revisionId],
        ),
        throwsA(isA<DomainFailure>()),
      );
      final first = quotation(1),
          next = quotation(
            1,
            parents: [quotation(1).revisionId],
            notes: 'changed',
          );
      await expectLater(
        apply('duplicate', [first, next]),
        throwsA(isA<DomainFailure>()),
      );
      expect(await db.rows('SELECT * FROM staging_import_decision'), isEmpty);
    },
  );
  test(
    'modify quantity and operation source mismatch reject before persistence',
    () async {
      await expectLater(
        apply('modify', [
          quotation(1),
          quotation(2),
        ], op: operation(quantity: 2, intent: ImportIntent.modify)),
        throwsA(isA<DomainFailure>()),
      );
      final other = SourceFingerprint.create(
        fields: {},
        inputIdentity: {},
        mappingSemantics: {},
        batchDefaults: {},
        captureMode: 'standard',
      );
      await expectLater(
        apply('source', [quotation(3)], op: operation(incoming: other)),
        throwsA(isA<DomainFailure>()),
      );
    },
  );
  test(
    'same source operation duplicate is explicit error, not silent ignore',
    () async {
      await apply('one', [quotation(1)]);
      await expectLater(apply('two', [quotation(2)]), throwsA(anything));
      expect((await store.inspectDecisionDigest('job')).decisionCount, 1);
    },
  );
  test(
    'sealed changes refused and unsealed canonical tampering detected',
    () async {
      await apply('apply', [quotation(1)]);
      await db.customStatement(
        "UPDATE staging_import_decision SET original_target_id='tampered'",
      );
      await expectLater(
        store.validateStaged('job'),
        throwsA(isA<DomainFailure>()),
      );
      await db.customStatement(
        "UPDATE staging_import_decision SET original_target_id=''",
      );
      await db.sealJob('job', await store.computeDecisionDigest('job'));
      await expectLater(
        store.stageDecision(
          jobId: 'job',
          decisionId: 'skip',
          action: ImportDecisionAction.skip,
          source: source,
          originalTargetId: '',
          confirmationDetails: {},
        ),
        throwsA(anything),
      );
    },
  );
  test(
    'copy requires event-result membership; outer rollback removes earlier copies',
    () async {
      await apply('a', [quotation(1, notes: 'a')], op: operation(note: 'a'));
      await apply('b', [quotation(2, notes: 'b')], op: operation(note: 'b'));
      final token = await db.sealJob(
        'job',
        await store.computeDecisionDigest('job'),
      );
      await db.registerConfirmation('event', token);
      // Isolated structural transaction fixture: no business commit is claimed.
      await expectLater(
        db.transaction(() async {
          for (final row in await db.rows(
            "SELECT canonical FROM staging_revision WHERE job_id='job'",
          )) {
            final r = RevisionEnvelope.fromCanonicalJson(
              row.read<String>('canonical'),
            );
            await db.customStatement(
              'INSERT INTO entity_identity VALUES(?,?)',
              [r.entityType, r.entityId],
            );
            await db.customStatement('INSERT INTO revision VALUES(?,?,?,?)', [
              r.revisionId,
              r.entityType,
              r.entityId,
              r.canonical,
            ]);
          }
          await db.customStatement('INSERT INTO receipt_result VALUES(?,?)', [
            'event',
            quotation(1, notes: 'a').revisionId,
          ]);
          await store.copyAppliedToReceipt('job', 'event');
        }),
        throwsA(isA<DomainFailure>()),
      );
      expect(await db.rows('SELECT * FROM import_decision_receipt'), isEmpty);
      expect(await db.rows('SELECT * FROM import_row_receipt'), isEmpty);
      expect(await db.rows('SELECT * FROM revision'), isEmpty);
    },
  );
  test(
    'result cursor cannot be reused for another operation or source',
    () async {
      await apply('apply', [quotation(1), quotation(2)]);
      await commit();
      final op = (await store.readSourceReceipts(
        source,
      )).items.single.operationFingerprint;
      final first = await store.readReceiptResults(
        eventId: 'event',
        source: source,
        operationFingerprint: op,
        limit: 1,
      );
      await expectLater(
        store.readReceiptResults(
          eventId: 'other',
          source: source,
          operationFingerprint: op,
          after: first.nextCursor,
        ),
        throwsA(isA<DomainFailure>()),
      );
      await expectLater(
        store.readSourceReceipts(source, limit: 201),
        throwsRangeError,
      );
    },
  );
  test('two decisions cannot allocate the same main entity', () async {
    final q = quotation(1);
    await apply('a', [q]);
    await expectLater(
      store.stageDecision(
        jobId: 'job',
        decisionId: 'b',
        action: ImportDecisionAction.apply,
        source: source,
        operation: operation(note: ''),
        originalTargetId: '',
        confirmationDetails: {},
        resultRevisionIds: [q.revisionId],
      ),
      throwsA(isA<DomainFailure>()),
    );
    // Different canonical operation with the same null effect reaches ownership guard.
    final other = OperationFingerprint.create(
      source: source,
      intent: ImportIntent.newInquiry,
      originalBindings: {'copy': true},
      operations: {'notes': const FieldOperation.clear()},
      confirmedQuantity: 1,
    );
    await expectLater(
      store.stageDecision(
        jobId: 'job',
        decisionId: 'b',
        action: ImportDecisionAction.apply,
        source: source,
        operation: other,
        originalTargetId: '',
        confirmationDetails: {},
        resultRevisionIds: [q.revisionId],
      ),
      throwsA(isA<DomainFailure>()),
    );
    expect((await store.inspectDecisionDigest('job')).decisionCount, 1);
  });
  test(
    'excluded quotation and unrelated auxiliary cannot leak through staging',
    () async {
      await store.stageDecision(
        jobId: 'job',
        decisionId: 'skip',
        action: ImportDecisionAction.skip,
        source: source,
        originalTargetId: '',
        confirmationDetails: {},
      );
      await db.appendStaging('job', quotation(1));
      await expectLater(
        store.validateStaged('job'),
        throwsA(isA<DomainFailure>()),
      );
      await db.customStatement(
        "DELETE FROM staging_revision WHERE revision_id=?",
        [quotation(1).revisionId],
      );
      await expectLater(
        store.validateStaged('job'),
        throwsA(isA<DomainFailure>()),
      );
    },
  );
  test(
    'new inquiry rejects historical roots and existing root reuse',
    () async {
      final q = quotation(1);
      final historical = RevisionEnvelope.create(
        entityType: 'quotation',
        entityId: q.entityId,
        parents: [],
        kind: 'put',
        payload: {...q.payload, 'capture_mode': 'historical'},
        authoredAt: q.authoredAt,
        originDeviceId: q.originDeviceId,
      );
      await expectLater(
        apply('historical', [historical]),
        throwsA(isA<DomainFailure>()),
      );
      await db.customStatement(
        'DELETE FROM staging_revision WHERE revision_id=?',
        [historical.revisionId],
      );
      await apply('new', [q]);
      await commit();
      await db.createJob('reuse');
      await db.appendStaging('reuse', q);
      await expectLater(
        store.stageDecision(
          jobId: 'reuse',
          decisionId: 'reuse',
          action: ImportDecisionAction.apply,
          source: source,
          operation: operation(),
          originalTargetId: '',
          confirmationDetails: {},
          resultRevisionIds: [q.revisionId],
        ),
        throwsA(isA<DomainFailure>()),
      );
    },
  );
  test(
    'new inquiry rejects keep unknown fields and mismatched set or clear',
    () async {
      final q = quotation(1);
      await db.appendStaging('job', q);
      for (final fields in [
        {'notes': const FieldOperation.keep()},
        {'unknown': FieldOperation.set('x')},
        {'notes': FieldOperation.set('different')},
        {'price': const FieldOperation.clear()},
      ]) {
        final op = OperationFingerprint.create(
          source: source,
          intent: ImportIntent.newInquiry,
          originalBindings: {},
          operations: fields,
          confirmedQuantity: 1,
        );
        await expectLater(
          store.stageDecision(
            jobId: 'job',
            decisionId: 'bad',
            action: ImportDecisionAction.apply,
            source: source,
            operation: op,
            originalTargetId: '',
            confirmationDetails: {},
            resultRevisionIds: [q.revisionId],
          ),
          throwsA(isA<DomainFailure>()),
        );
      }
    },
  );
  test(
    'modify requires explicit head CAS and preserves every undeclared field',
    () async {
      final before = quotation(1);
      await apply('new', [before]);
      await commit();
      await db.createJob('edit');
      final next = quotation(1, parents: [before.revisionId], notes: 'edited');
      await db.appendStaging('edit', next);
      final op = operation(intent: ImportIntent.modify, note: 'edited');
      Future<void> stage() => store.stageDecision(
        jobId: 'edit',
        decisionId: 'edit',
        action: ImportDecisionAction.apply,
        source: source,
        operation: op,
        originalTargetId: before.entityId,
        confirmationDetails: {},
        resultRevisionIds: [next.revisionId],
      );
      await expectLater(stage(), throwsA(isA<DomainFailure>()));
      await db.customStatement(
        'INSERT INTO staging_expected_entity VALUES(?,?,?)',
        ['edit', 'quotation', before.entityId],
      );
      await db.customStatement(
        'INSERT INTO staging_expected_head VALUES(?,?,?,?)',
        ['edit', 'quotation', before.entityId, before.revisionId],
      );
      await stage();
      await store.validateStaged('edit');
      final token = await db.sealJob(
        'edit',
        await store.computeDecisionDigest('edit'),
      );
      await db.registerConfirmation('edit-event', token);
      await CommitCoordinator(
        database: db,
        writeLock: lock,
        readActiveVersion: db.currentVersion,
      ).commitStaged(
        jobId: 'edit',
        expectedPreviewToken: token,
        confirmationEventId: 'edit-event',
      );
      expect((await store.readSourceReceipts(source)).items, hasLength(2));
      expect(
        (await db.findRevision(next.revisionId))!.payload['notes'],
        'edited',
      );
      final unexpected = RevisionEnvelope.create(
        entityType: 'quotation',
        entityId: before.entityId,
        parents: [next.revisionId],
        kind: 'put',
        payload: {...next.payload, 'price': '99'},
        authoredAt: next.authoredAt,
        originDeviceId: next.originDeviceId,
      );
      expect(
        () => validateImportResultPayload(
          unexpected,
          {'intent': 'modify', 'operations': <String, Object?>{}},
          originalTargetId: before.entityId,
          baseline: next,
        ),
        throwsA(isA<DomainFailure>()),
      );
    },
  );
  test(
    'existing referenced auxiliary edits are not authorized by quotation decision',
    () async {
      final q = quotation(1);
      await apply('new', [q]);
      await commit();
      await db.createJob('another');
      final next = quotation(2);
      await db.appendStaging('another', next);
      await db.appendStaging('another', supplier);
      await store.stageDecision(
        jobId: 'another',
        decisionId: 'a',
        action: ImportDecisionAction.apply,
        source: source,
        operation: operation(),
        originalTargetId: '',
        confirmationDetails: {},
        resultRevisionIds: [next.revisionId],
      );
      await expectLater(
        store.validateStaged('another'),
        throwsA(isA<DomainFailure>()),
      );
    },
  );
}
