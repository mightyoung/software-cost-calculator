import 'package:drift/native.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:supplier_core/supplier_core.dart';
import 'package:test/test.dart';
import 'support/test_rig.dart';
import 'domain_test.dart' show quote;

void main() {
  // Each instance below owns a distinct in-memory executor.
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late SupplierDatabase db;
  late ExchangeService exchange;
  late RecordService records;
  late String supplier, product, quotation;
  final stages = <XlsxStaging>[];
  const device = '00000000-0000-4000-8000-000000000001';
  setUp(() async {
    db = SupplierDatabase(
      NativeDatabase.memory(),
      instanceId: '00000000-0000-4000-8000-000000000099',
    );
    final lock = TestWriteLock();
    final coordinator = CommitCoordinator(
      database: db,
      writeLock: lock,
      readActiveVersion: db.currentVersion,
    );
    exchange = ExchangeService(
      coordinator: coordinator,
      backups: BackupService(
        database: db,
        writeLock: lock,
        readActiveVersion: db.currentVersion,
        createArtifact: () async => _Artifact(),
      ),
      createBackupDestination: () async {
        final buffer = _Buffer();
        return BusinessBackupDestination(buffer, buffer);
      },
    );
    records = RecordService(coordinator, deviceId: device);
    supplier = await records.createEntity(
      'supplier',
      fixtureRevision(1).payload,
    );
    product = await records.createEntity('product', {
      'name': '产品',
      'unit': '件',
      'brand': null,
      'model': null,
      'specification': null,
      'category': null,
      'notes': null,
    });
    quotation = await records.createQuotation({
      ...quote(),
      'supplier_id': supplier,
      'product_id': product,
      'notes': '保留备注',
    });
  });
  tearDown(() async {
    for (final stage in stages) {
      await stage.close();
    }
    stages.clear();
    await db.close();
  });
  BusinessMapping mapping({bool note = true}) => BusinessMapping(
    columns: {
      'record_id': const BusinessColumnMapping(1, BusinessConversion.text),
      'price': const BusinessColumnMapping(2, BusinessConversion.decimal),
      if (note)
        'notes': const BusinessColumnMapping(3, BusinessConversion.text),
    },
  );
  Future<BusinessImportWorkflow> workbook(
    List<List<String?>> rows, {
    BusinessMapping? withMapping,
  }) async {
    final check = XlsxStaging(NativeDatabase.memory());
    final input = await const BoundedXlsxWriter().encodeVolume(
      rows: Stream.fromIterable(rows),
      headers: ['ID', '价格', '备注'],
      validation: check,
    );
    await check.close();
    final stage = XlsxStaging(NativeDatabase.memory());
    stages.add(stage);
    final id = (await exchange.beginBusiness(input)).id;
    await exchange.prepareBusiness(
      id,
      input,
      stage,
      policy: BusinessWorkbookPolicy(maxDataRows: 100),
    );
    return BusinessImportWorkflow(
      exchange: exchange,
      jobId: id,
      staging: stage,
      mapping: withMapping ?? mapping(),
      deviceId: device,
    );
  }

  Future<RevisionEnvelope> current() async {
    final result = await QueryRepository(db).quotationHeads(quotation);
    return db
        .findRevision(result.items.single.values['revision_id']! as String)
        .then((value) => value!);
  }

  test(
    'real workbook modify preserves blank, commits receipts and recognizes reimport after local edit',
    () async {
      final first = await workbook([
        [quotation, '17.123456', null],
      ]);
      final preview = await first.previewRow(2);
      expect(preview.targetState, 'put');
      expect(preview.current!.payload['notes'], '保留备注');
      await first.decide(
        2,
        BusinessRowDecision(
          choice: BusinessRowChoice.modify,
          targetId: quotation,
        ),
      );
      expect((await first.summary()).applied, 1);
      final confirmation = await first.seal();
      final committed = await exchange.commit(confirmation);
      expect((await current()).payload['price'], '17.123456');
      expect((await current()).payload['notes'], '保留备注');
      expect(
        (await exchange.commit(confirmation)).confirmationEventId,
        committed.confirmationEventId,
      );
      final baseline = await current();
      await records.correctEntity(
        'quotation',
        quotation,
        {...baseline.payload, 'notes': '本地后来修改'},
        expectedHeads: {baseline.revisionId},
      );
      final second = await workbook([
        [quotation, '17.123456', null],
      ]);
      final again = await second.previewRow(2);
      expect(again.alreadyImported, isTrue);
      expect(again.candidates, isEmpty);
      await expectLater(
        second.decide(
          2,
          BusinessRowDecision(
            choice: BusinessRowChoice.modify,
            targetId: quotation,
          ),
        ),
        throwsA(
          isA<DomainFailure>().having(
            (e) => e.code,
            'code',
            'import_already_processed',
          ),
        ),
      );
      await second.decide(
        2,
        const BusinessRowDecision(choice: BusinessRowChoice.skip),
      );
      await exchange.commit(await second.seal());
      expect((await current()).payload['notes'], '本地后来修改');
    },
  );

  test(
    'all rows require decisions; invalid row is explicitly excluded atomically',
    () async {
      final workflow = await workbook([
        [quotation, '19', null],
        [quotation, '1.1234567', null],
      ]);
      await workflow.decide(
        2,
        BusinessRowDecision(
          choice: BusinessRowChoice.modify,
          targetId: quotation,
          clearFields: {'notes'},
        ),
      );
      await expectLater(
        workflow.seal(),
        throwsA(
          isA<DomainFailure>().having(
            (e) => e.code,
            'code',
            'import_undecided_rows',
          ),
        ),
      );
      expect((await workflow.previewRow(3)).mapped.issues, isNotEmpty);
      await expectLater(
        workflow.decide(
          3,
          const BusinessRowDecision(choice: BusinessRowChoice.skip),
        ),
        throwsA(isA<DomainFailure>()),
      );
      await workflow.decide(
        3,
        const BusinessRowDecision(
          choice: BusinessRowChoice.excludeError,
          exclusionReason: '金额超出六位小数',
        ),
      );
      final summary = await workflow.summary();
      expect([summary.applied, summary.excluded, summary.results], [1, 1, 1]);
      await exchange.commit(await workflow.seal());
      expect((await current()).payload['notes'], isNull);
      expect((await current()).payload['price'], '19');
    },
  );

  test(
    'new inquiry allocates explicit quantity; unknown incoming IDs are never targets',
    () async {
      final workflow = await workbook([
        ['unknown-record', '21', null],
      ]);
      expect((await workflow.previewRow(2)).targetState, 'unknown');
      final fields = Map<String, Object?>.from(quote())
        ..removeWhere(
          (key, value) =>
              value == null ||
              [
                'supplier_id',
                'product_id',
                'price',
                'capture_mode',
              ].contains(key),
        );
      await workflow.decide(
        2,
        BusinessRowDecision(
          choice: BusinessRowChoice.newInquiry,
          quantity: 2,
          bindings: {'supplier_id': supplier, 'product_id': product},
          setFields: fields,
        ),
      );
      expect((await workflow.summary()).results, 2);
      await exchange.commit(await workflow.seal());
      final rows = await QueryRepository(db).quotations({});
      expect(rows.items.length, 3);
    },
  );

  test('mapping changes cannot reuse saved decisions', () async {
    final workflow = await workbook([
      [quotation, '23', null],
    ]);
    await workflow.decide(
      2,
      const BusinessRowDecision(choice: BusinessRowChoice.skip),
    );
    final changed = BusinessImportWorkflow(
      exchange: exchange,
      jobId: workflow.jobId,
      staging: workflow.staging,
      mapping: mapping(note: false),
      deviceId: device,
    );
    await expectLater(
      changed.seal(),
      throwsA(
        isA<DomainFailure>().having(
          (e) => e.code,
          'code',
          'import_mapping_changed',
        ),
      ),
    );
  });

  test('explicit keep overrides a present incoming value', () async {
    final workflow = await workbook([
      [quotation, '49', '覆盖来件'],
    ]);
    await workflow.decide(
      2,
      BusinessRowDecision(
        choice: BusinessRowChoice.modify,
        targetId: quotation,
        keepFields: {'notes'},
      ),
    );
    await exchange.commit(await workflow.seal());
    expect((await current()).payload['price'], '49');
    expect((await current()).payload['notes'], '保留备注');
  });

  test(
    'explicit supplier and product creation commits with quotation and counts only the main result',
    () async {
      final workflow = await workbook(
        [
          [null, '31', null],
        ],
        withMapping: BusinessMapping(
          columns: mapping().columns,
          captureMode: CaptureMode.historical,
        ),
      );
      await workflow.decide(
        2,
        BusinessRowDecision(
          choice: BusinessRowChoice.importHistorical,
          createSupplier: {
            'name': '新供应商',
            'aliases': <String>[],
            'address': null,
            'categories': <String>[],
            'notes': null,
          },
          createProduct: {
            'name': '新产品',
            'unit': '套',
            'brand': null,
            'model': '0001',
            'specification': null,
            'category': null,
            'notes': null,
          },
          setFields: {'unit_snapshot': '套'},
        ),
      );
      expect((await workflow.summary()).results, 1);
      await exchange.commit(await workflow.seal());
      final query = QueryRepository(db);
      expect((await query.entities('supplier')).items.length, 2);
      expect((await query.entities('product')).items.length, 2);
      expect((await query.quotations({})).items.length, 2);
    },
  );

  test(
    'historical entry imports missing context, retries stably and backup roundtrips',
    () async {
      final workflow = await workbook(
        [
          [null, '25', null],
        ],
        withMapping: BusinessMapping(
          columns: mapping().columns,
          captureMode: CaptureMode.historical,
        ),
      );
      await workflow.decide(
        2,
        BusinessRowDecision(
          choice: BusinessRowChoice.importHistorical,
          bindings: {'supplier_id': supplier, 'product_id': product},
          setFields: {'unit_snapshot': '件'},
        ),
      );
      final confirmation = await workflow.seal();
      final first = await exchange.commit(confirmation);
      final retry = await exchange.commit(confirmation);
      expect(first.confirmationEventId, retry.confirmationEventId);
      final rows = await QueryRepository(db).quotations({});
      final history = rows.items.singleWhere(
        (r) => r.values['capture_mode'] == 'historical',
      );
      expect(history.values['quoted_on'], isNull);
      final output = _Buffer();
      await exchange.backups.create(output);
      final decoded = await decodeBackup(output);
      expect(decoded.header.backupVersion, 2);
      final candidate = SupplierDatabase(
        NativeDatabase.memory(),
        instanceId: '00000000-0000-4000-8000-000000000098',
      );
      try {
        final builder = BackupCandidateBuilder(
          database: candidate,
          writeLock: TestWriteLock(),
        );
        await builder.build(output);
        final restored = await QueryRepository(candidate).quotations({});
        expect(restored.items.length, 2);
        expect(
          restored.items.any((r) => r.values['capture_mode'] == 'historical'),
          isTrue,
        );
      } finally {
        await candidate.close();
      }
    },
  );

  test(
    'historical choice requires historical entry and never modifies existing target',
    () async {
      final standard = await workbook([
        [null, '26', null],
      ]);
      await expectLater(
        standard.decide(
          2,
          BusinessRowDecision(
            choice: BusinessRowChoice.importHistorical,
            bindings: {'supplier_id': supplier, 'product_id': product},
            setFields: {'unit_snapshot': '件'},
          ),
        ),
        throwsA(
          isA<DomainFailure>().having(
            (e) => e.code,
            'code',
            'import_historical_mode',
          ),
        ),
      );
      final historical = await workbook(
        [
          [quotation, '26', null],
        ],
        withMapping: BusinessMapping(
          columns: mapping().columns,
          captureMode: CaptureMode.historical,
        ),
      );
      await expectLater(
        historical.decide(
          2,
          BusinessRowDecision(
            choice: BusinessRowChoice.importHistorical,
            targetId: quotation,
            bindings: {'supplier_id': supplier, 'product_id': product},
            setFields: {'unit_snapshot': '件'},
          ),
        ),
        throwsA(
          isA<DomainFailure>().having(
            (e) => e.code,
            'code',
            'import_historical_mode',
          ),
        ),
      );
      await expectLater(
        historical.decide(
          2,
          BusinessRowDecision(
            choice: BusinessRowChoice.newInquiry,
            bindings: {'supplier_id': supplier, 'product_id': product},
            setFields: {'unit_snapshot': '件'},
          ),
        ),
        throwsFormatException,
      );
    },
  );

  test(
    'low-level receipt contract rejects historical intent with standard source or an original target',
    () async {
      final workflow = await workbook([
        [null, '26', null],
      ]);
      final standard = (await workflow.previewRow(2)).mapped.source!;
      final historical = SourceFingerprint.create(
        fields: {'price': SourceCell.value('26')},
        inputIdentity: {},
        mappingSemantics: {},
        batchDefaults: {},
        captureMode: 'historical',
      );
      for (final source in [standard, historical]) {
        final revision = RevisionEnvelope.create(
          entityType: 'quotation',
          entityId: '00000000-0000-4000-8000-000000000088',
          parents: [],
          kind: 'put',
          payload: {
            ...quote(),
            'supplier_id': supplier,
            'product_id': product,
            'capture_mode': 'historical',
          },
          authoredAt: '2026-09-21T00:00:00.000Z',
          originDeviceId: device,
        );
        await expectLater(
          exchange.stageDecision(
            workflow.jobId,
            BusinessImportDecision(
              id: 'forged-${source.digest}',
              action: ImportDecisionAction.apply,
              source: source,
              operation: OperationFingerprint.create(
                source: source,
                intent: ImportIntent.importHistorical,
                originalBindings: {},
                operations: {},
                confirmedQuantity: 1,
              ),
              originalTargetId: identical(source, historical) ? quotation : '',
              confirmationDetails: {},
              revisions: [revision],
              resultRevisionIds: [revision.revisionId],
            ),
          ),
          throwsA(isA<DomainFailure>()),
        );
      }
      expect(
        await db.rows(
          "SELECT * FROM staging_revision WHERE json_extract(canonical,'\$.entity_id')='00000000-0000-4000-8000-000000000088'",
        ),
        isEmpty,
      );
    },
  );

  test(
    'conversion confirmation is required and deleted modification targets remain deleted',
    () async {
      final workflow = await workbook([
        [quotation, '27.0000', null],
      ]);
      expect((await workflow.previewRow(2)).mapped.conversions, hasLength(1));
      await expectLater(
        workflow.decide(
          2,
          BusinessRowDecision(
            choice: BusinessRowChoice.modify,
            targetId: quotation,
          ),
        ),
        throwsA(
          isA<DomainFailure>().having(
            (e) => e.code,
            'code',
            'import_conversion_confirmation',
          ),
        ),
      );
      await workflow.decide(
        2,
        BusinessRowDecision(
          choice: BusinessRowChoice.modify,
          targetId: quotation,
          acknowledgeConversions: true,
        ),
      );
      await exchange.commit(await workflow.seal());
      final head = await current();
      await records.deleteEntity('quotation', quotation, {head.revisionId});
      final next = await workbook([
        [quotation, '28', null],
      ]);
      expect((await next.previewRow(2)).targetState, 'delete');
      await expectLater(
        next.decide(
          2,
          BusinessRowDecision(
            choice: BusinessRowChoice.modify,
            targetId: quotation,
          ),
        ),
        throwsA(
          isA<DomainFailure>().having(
            (e) => e.code,
            'code',
            'import_target_state',
          ),
        ),
      );
    },
  );

  test(
    'mapping keeps absent versus blank and previews exact dates and scientific numbers',
    () {
      RawBusinessCell cell(String text, BusinessCellKind kind) =>
          RawBusinessCell(coordinate: 'A2', kind: kind, lexical: text);
      final map = BusinessMapping(
        columns: {
          'price': const BusinessColumnMapping(1, BusinessConversion.decimal),
          'inquiry_time': const BusinessColumnMapping(
            2,
            BusinessConversion.inquiryTime,
          ),
          'notes': const BusinessColumnMapping(3, BusinessConversion.text),
        },
        utcOffsetMinutes: 480,
      );
      final result = map.convert(2, {
        1: cell('1.234567e2', BusinessCellKind.number),
        2: cell('2026-09-21T10:20', BusinessCellKind.text),
      }, date1904: false);
      expect(result.issues, isEmpty);
      expect(result.values['price'], '123.4567');
      expect(
        (result.values['inquiry_time'] as Map)['inquiry_utc_offset_minutes'],
        480,
      );
      expect(result.conversions.length, 2);
      expect(result.source!.canonical, contains('"notes":{"presence":"blank"'));
      expect(
        result.source!.canonical,
        contains('"quoted_on":{"presence":"missing"'),
      );
      final invalid = BusinessMapping(
        columns: {
          'quoted_on': const BusinessColumnMapping(1, BusinessConversion.date),
        },
      ).convert(2, {1: cell('60', BusinessCellKind.number)}, date1904: false);
      expect(invalid.issues, isNotEmpty);
      expect(invalid.source, isNull);
    },
  );
}

class _Buffer implements InputSource, OutputTarget {
  final bytes = <int>[];
  @override
  String get displayName => 'test buffer';
  @override
  Future<int> length() async => bytes.length;
  @override
  Stream<List<int>> openRange(int start, int endExclusive) async* {
    yield bytes.sublist(start, endExclusive);
  }

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

class _Artifact implements BackupArtifact {
  final buffer = _Buffer();
  @override
  InputSource get source => buffer;
  @override
  OutputTarget get output => buffer;
  @override
  Future<void> dispose() async {}
}
