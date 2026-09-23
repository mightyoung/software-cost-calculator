import 'package:drift/native.dart';
import 'package:supplier_core/supplier_core.dart';
import 'package:test/test.dart';
import 'support/test_rig.dart';
import 'domain_test.dart' show quote;

void main() {
  late SupplierDatabase db;
  late ExchangeService service;
  late XlsxStaging staging;
  late InputSource input;
  late _Buffer destination;
  late String id;
  var backupCount = 0;
  var failAssociation = false;
  final associatedJobs = <String>[];
  setUp(() async {
    db = SupplierDatabase(
      NativeDatabase.memory(),
      instanceId: '00000000-0000-4000-8000-000000000099',
    );
    final lock = TestWriteLock();
    destination = _Buffer();
    backupCount = 0;
    failAssociation = false;
    associatedJobs.clear();
    service = ExchangeService(
      coordinator: CommitCoordinator(
        database: db,
        writeLock: lock,
        readActiveVersion: db.currentVersion,
      ),
      backups: BackupService(
        database: db,
        writeLock: lock,
        readActiveVersion: db.currentVersion,
        createArtifact: () async => _Artifact(),
      ),
      createBackupDestination: () async {
        backupCount++;
        return BusinessBackupDestination(
          destination,
          destination,
          onVerified: (jobId) async {
            if (failAssociation) throw StateError('backup locator unavailable');
            associatedJobs.add(jobId);
          },
        );
      },
    );
    final validation = XlsxStaging(NativeDatabase.memory());
    input = await const BoundedXlsxWriter().encodeVolume(
      rows: Stream.fromIterable([
        ['a'],
        ['b'],
        ['c'],
      ]),
      headers: ['value'],
      validation: validation,
    );
    await validation.close();
    staging = XlsxStaging(NativeDatabase.memory());
    id = (await service.beginBusiness(input)).id;
    await service.prepareBusiness(
      id,
      input,
      staging,
      policy: BusinessWorkbookPolicy(maxDataRows: 10000),
    );
  });
  tearDown(() async {
    await staging.close();
    await db.close();
  });
  Future<BusinessConfirmation> excluded() async {
    await service.stageDecision(
      id,
      const BusinessImportDecision(
        id: 'excluded',
        action: ImportDecisionAction.excludeError,
        originalTargetId: '',
        confirmationDetails: {
          'rows': [2, 3, 4],
        },
        exclusionReason: 'Explicitly excluded invalid inputs',
      ),
    );
    return service.sealBusiness(id);
  }

  Future<void> seedExport() async {
    final records = RecordService(
      service.coordinator,
      deviceId: '00000000-0000-4000-8000-000000000001',
    );
    final supplier = await records.createEntity(
      'supplier',
      fixtureRevision(1).payload,
    );
    final product = await records.createEntity('product', {
      'name': '产品 A',
      'unit': '件',
      'brand': '品牌',
      'model': '0002',
      'specification': '规格',
      'category': null,
      'notes': null,
    });
    for (var i = 0; i < 2; i++) {
      await records.createQuotation({
        ...quote(),
        'supplier_id': supplier,
        'product_id': product,
        'project_number': '000123-A',
        'notes': '=SUM(A1:A2)',
      });
    }
  }

  test(
    'backup locator association failure retains confirmation for retry',
    () async {
      final confirmation = await excluded();
      failAssociation = true;
      await expectLater(service.commit(confirmation), throwsStateError);
      expect((await service.jobs.load(id)).state, JobState.previewReady);
      expect(
        await service.coordinator.findCommittedEvent(confirmation.eventId),
        isNull,
      );
    failAssociation = false;
    destination = _Buffer();
    await service.commit(confirmation);
      expect(associatedJobs, [id]);
    },
  );
  test('preview is keyset paged and reopening retains task state', () async {
    final first = await service.previewRows(id, staging, limit: 2);
    final next = await service.previewRows(
      id,
      staging,
      afterRow: first.last.row,
      limit: 2,
    );
    expect(first.map((r) => r.row), [1, 2]);
    expect(next.map((r) => r.row), [3, 4]);
    expect(
      (await service.resume(id, source: input)).state,
      JobState.validating,
    );
    expect(
      (await service.previewCells(id, staging, 2)).single.cell.lexical,
      'a',
    );
  });
  test(
    'backup failure never installs authority or a success receipt',
    () async {
      final confirmation = await excluded();
      destination.fail = true;
      await expectLater(service.commit(confirmation), throwsStateError);
      expect((await db.currentVersion()).generation, 0);
      expect(await db.rows('SELECT * FROM commit_receipt'), isEmpty);
      expect((await service.resume(id)).state, JobState.previewReady);
    },
  );
  test(
    'excluded subset creates no source success; same event retry reuses receipt',
    () async {
      final confirmation = await excluded();
      final receipt = await service.commit(confirmation);
      final retry = await service.commit(confirmation);
      expect(retry.confirmationEventId, receipt.confirmationEventId);
      expect((await db.currentVersion()).generation, 1);
      expect(backupCount, 1);
      expect(await db.rows('SELECT * FROM import_row_receipt'), isEmpty);
      expect((await service.watchJob(id).single).state, JobState.committed);
    },
  );
  test('version drift rejects decision and commit before backup', () async {
    final confirmation = await excluded();
    await db.customStatement(
      'UPDATE database_meta SET generation=generation+1',
    );
    await expectLater(
      service.commit(confirmation),
      throwsA(isA<DomainFailure>()),
    );
    expect(backupCount, 0);
  });
  test('applied subset is source-first on the next attempt', () async {
    final supplier = fixtureRevision(1);
    final product = RevisionEnvelope.create(
      entityType: 'product',
      entityId: '22222222-2222-4222-8222-222222222222',
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
      authoredAt: supplier.authoredAt,
      originDeviceId: supplier.originDeviceId,
    );
    final payload = {...quote(), 'supplier_id': supplier.entityId};
    final result = RevisionEnvelope.create(
      entityType: 'quotation',
      entityId: '33333333-3333-4333-8333-333333333333',
      parents: [],
      kind: 'put',
      payload: payload,
      authoredAt: supplier.authoredAt,
      originDeviceId: supplier.originDeviceId,
    );
    final source = SourceFingerprint.create(
      fields: {},
      inputIdentity: {},
      mappingSemantics: {},
      batchDefaults: {},
      captureMode: 'standard',
    );
    final operation = OperationFingerprint.create(
      source: source,
      intent: ImportIntent.newInquiry,
      originalBindings: {'quotation_id': ''},
      operations: payload.map(
        (key, value) => MapEntry(
          key,
          value == null
              ? const FieldOperation.clear()
              : FieldOperation.set(value),
        ),
      ),
      confirmedQuantity: 1,
    );
    await service.stageDecision(
      id,
      BusinessImportDecision(
        id: 'apply',
        action: ImportDecisionAction.apply,
        originalTargetId: '',
        confirmationDetails: {'row': 2},
        source: source,
        operation: operation,
        revisions: [supplier, product, result],
        resultRevisionIds: [result.revisionId],
      ),
    );
    final confirmation = await excluded();
    await service.commit(confirmation);
    final next = (await service.beginBusiness(input)).id;
    final nextStaging = XlsxStaging(NativeDatabase.memory());
    try {
      await service.prepareBusiness(
        next,
        input,
        nextStaging,
        policy: BusinessWorkbookPolicy(maxDataRows: 10000),
      );
      var matched = false;
      final lookup = await service.sourceFirst(next, source, () async {
        matched = true;
        return ['candidate'];
      });
      expect(matched, isFalse);
      expect(lookup.candidates, isNull);
      expect(
        lookup.receipts.items.single.operationCanonical,
        operation.canonical,
      );
      expect(await db.rows('SELECT * FROM import_row_receipt'), hasLength(1));
    } finally {
      await nextStaging.close();
    }
  });
  test(
    'source lookup checks bound version before returning receipt page',
    () async {
      final source = SourceFingerprint.create(
        fields: {},
        inputIdentity: {},
        mappingSemantics: {},
        batchDefaults: {},
        captureMode: 'standard',
      );
      expect((await service.lookupSource(id, source)).items, isEmpty);
      await db.customStatement(
        'UPDATE database_meta SET generation=generation+1',
      );
      await expectLater(
        service.lookupSource(id, source),
        throwsA(isA<DomainFailure>()),
      );
    },
  );
  test('cancel persists and watcher terminates', () async {
    await service.cancel(id);
    expect((await service.resume(id)).state, JobState.cancelled);
    expect((await service.watchJob(id).single).state, JobState.cancelled);
    await expectLater(excluded(), throwsA(isA<DomainFailure>()));
  });
  test(
    'bounded business export pages fixed columns and roundtrips exact text',
    () async {
      await seedExport();
      final output = _Buffer();
      final validation = XlsxStaging(NativeDatabase.memory());
      final readback = XlsxStaging(NativeDatabase.memory());
      try {
        final result = await service.exportBusiness(
          output,
          expectedVersion: await db.currentVersion(),
          validation: validation,
          policy: BusinessWorkbookPolicy(maxDataRows: 10000),
          pageSize: 1,
        );
        expect(result.rows, 2);
        expect(output.published, isTrue);
        await const BoundedXlsxReader(
          maxDataRows: 10000,
        ).readVolume(output, readback);
        final headers = await readback.cellsPage(1, limit: 100);
        expect(
          headers.map((c) => c.cell.lexical),
          businessQuotationColumns.map((c) => c.heading),
        );
        final cells = await readback.cellsPage(2, limit: 100);
        final values = {
          for (var i = 0; i < cells.length; i++)
            businessQuotationColumns[i].key: cells[i].cell.lexical,
        };
        expect(values['price'], '12.340001');
        expect(values['project_number'], '000123-A');
        expect(values['product_model'], '0002');
        expect(values['notes'], '=SUM(A1:A2)');
        expect(cells.every((c) => c.cell.formula == null), isTrue);
        expect(values['record_type'], 'quotation');
        expect(values['template_version'], businessQuotationTemplateVersion);
        expect(
          values['export_revision_id'],
          matches(RegExp(r'^[0-9a-f]{64}$')),
        );
      } finally {
        await validation.close();
        await readback.close();
      }
    },
  );
  test(
    'export detects version drift after writing and aborts before publication',
    () async {
      final output = _Buffer()
        ..afterWrite = () => db.customStatement(
          'UPDATE database_meta SET generation=generation+1',
        );
      final validation = XlsxStaging(NativeDatabase.memory());
      try {
        await expectLater(
          service.exportBusiness(
            output,
            expectedVersion: await db.currentVersion(),
            validation: validation,
            policy: BusinessWorkbookPolicy(maxDataRows: 10000),
          ),
          throwsA(
            isA<DomainFailure>().having(
              (e) => e.code,
              'code',
              'stale_business_export',
            ),
          ),
        );
        expect(output.published, isFalse);
        expect(output.aborted, isTrue);
      } finally {
        await validation.close();
      }
    },
  );
  test('export output failure aborts without changing business data', () async {
    await seedExport();
    final version = await db.currentVersion();
    final output = _Buffer()..fail = true;
    final validation = XlsxStaging(NativeDatabase.memory());
    try {
      await expectLater(
        service.exportBusiness(
          output,
          expectedVersion: version,
          validation: validation,
          policy: BusinessWorkbookPolicy(maxDataRows: 10000),
        ),
        throwsStateError,
      );
      expect(output.aborted, isTrue);
      expect(output.published, isFalse);
      expect((await db.currentVersion()).generation, version.generation);
    } finally {
      await validation.close();
    }
  });
}

class _Buffer implements InputSource, OutputTarget {
  final bytes = <int>[];
  bool fail = false;
  bool published = false, aborted = false;
  Future<void> Function()? afterWrite;
  @override
  String get displayName => 'test-memory-only';
  @override
  Future<int> length() async => bytes.length;
  @override
  Stream<List<int>> openRange(int start, int endExclusive) async* {
    yield bytes.sublist(start, endExclusive);
  }

  @override
  Future<void> write(Stream<List<int>> chunks) async {
    if (fail) throw StateError('backup target failed');
    await for (final chunk in chunks) {
      bytes.addAll(chunk);
    }
    await afterWrite?.call();
  }

  @override
  Future<void> publish() async {
    published = true;
  }

  @override
  Future<void> abort() async {
    aborted = true;
    bytes.clear();
  }
}

class _Artifact implements BackupArtifact {
  final buffer = _Buffer();
  @override
  InputSource get source => buffer;
  @override
  OutputTarget get output => buffer;
  @override
  Future<void> dispose() async {}
}
