import 'dart:io';
import 'package:drift/drift.dart' show Variable;
import 'package:supplier_core/supplier_core.dart';
import 'package:supplier_core/src/exchange/import_receipts.dart';
import 'package:test/test.dart';
import 'domain_test.dart' show quote, sid, pid;
import 'support/test_rig.dart';

void main() {
  late Directory directory;
  late StorageTestRig rig;
  late JobStore jobs;
  late ImportReceiptStore receipts;
  final source = SourceFingerprint.create(
    fields: {'price': SourceCell.value('12.340001')},
    inputIdentity: {},
    mappingSemantics: {},
    batchDefaults: {},
    captureMode: 'standard',
  );
  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'supplier-business-commit-',
    );
    rig = StorageTestRig(File('${directory.path}/database'));
    jobs = JobStore(
      database: rig.database,
      writeLock: rig.lock,
      readActiveVersion: rig.active,
    );
    receipts = ImportReceiptStore(rig.database);
  });
  tearDown(() async {
    await rig.database.close();
    await directory.delete(recursive: true);
  });
  RevisionEnvelope revision(
    String type,
    String id,
    Map<String, Object?> payload,
  ) => RevisionEnvelope.create(
    entityType: type,
    entityId: id,
    parents: [],
    kind: 'put',
    payload: payload,
    authoredAt: '2026-09-18T00:00:00.000Z',
    originDeviceId: '00000000-0000-4000-8000-999999999999',
  );
  Future<void> stage({int quantity = 2, bool excluded = false}) async {
    final input = _Source();
    await jobs.create(input, jobId: 'business');
    await jobs.bindSource('business', input);
    await jobs.transition(
      'business',
      expectedState: JobState.created,
      next: JobState.parsing,
    );
    final results = <String>[];
    if (!excluded) {
      await rig.database.appendStaging(
        'business',
        revision('supplier', sid, {
          'name': '供应商',
          'notes': null,
          'aliases': [],
          'categories': [],
          'address': null,
        }),
      );
      await rig.database.appendStaging(
        'business',
        revision('product', pid, {
          'name': '材料',
          'unit': '件',
          'brand': null,
          'model': null,
          'specification': null,
          'category': null,
          'notes': null,
        }),
      );
      for (var i = 0; i < quantity; i++) {
        final row = revision(
          'quotation',
          '33333333-3333-4333-8333-${i.toString().padLeft(12, '0')}',
          quote(),
        );
        await rig.database.appendStaging('business', row);
        results.add(row.revisionId);
      }
    }
    await receipts.stageDecision(
      jobId: 'business',
      decisionId: 'row-1',
      action: excluded
          ? ImportDecisionAction.excludeError
          : ImportDecisionAction.apply,
      source: excluded ? null : source,
      operation: excluded
          ? null
          : OperationFingerprint.create(
              source: source,
              intent: ImportIntent.newInquiry,
              originalBindings: {},
              operations: {'price': FieldOperation.set('12.340001')},
              confirmedQuantity: quantity,
            ),
      originalTargetId: '',
      confirmationDetails: {'row': 2, 'rounding_acknowledged': true},
      exclusionReason: excluded ? '价格格式错误' : null,
      resultRevisionIds: results,
    );
    await jobs.transition(
      'business',
      expectedState: JobState.parsing,
      next: JobState.validating,
    );
  }

  Future<CommitReceipt> commit(PreviewToken token, {String? fault}) async {
    await rig.database.registerConfirmation('business-event', token);
    return rig
        .coordinator(
          fault: (point) async {
            if (point == fault) throw StateError(point);
          },
        )
        .commitStaged(
          jobId: 'business',
          expectedPreviewToken: token,
          confirmationEventId: 'business-event',
        );
  }

  Future<int> count(String table) async => (await rig.database.rows(
    'SELECT COUNT(*) n FROM $table',
  )).single.read<int>('n');

  test('double confirmation and reopen reuse one persisted event', () async {
    await stage();
    final token = await jobs.sealBusinessPreview('business');
    final events = await Future.wait([
      jobs.registerOrReuseConfirmation(token),
      jobs.registerOrReuseConfirmation(token),
    ]);
    expect(events[0], events[1]);
    await rig.coordinator().commitStaged(
      jobId: token.jobId,
      expectedPreviewToken: token,
      confirmationEventId: events.first,
    );
    await rig.reopen();
    jobs = JobStore(
      database: rig.database,
      writeLock: rig.lock,
      readActiveVersion: rig.active,
    );
    expect(await jobs.registerOrReuseConfirmation(token), events.first);
    expect(await count('confirmation_event'), 1);
    expect((await rig.database.currentVersion()).generation, 1);
  });

  test(
    'canonical and main results commit atomically; retry reuses event',
    () async {
      await stage();
      final token = await jobs.sealBusinessPreview('business');
      final result = await commit(token);
      expect(result.resultCount, 4);
      expect(await count('import_row_receipt'), 2);
      expect(await count('import_decision_receipt'), 1);
      expect(
        (await receipts.readSourceReceipts(
          source,
        )).items.single.legacyDetailsUnknown,
        isFalse,
      );
      final retry = await rig.coordinator().commitStaged(
        jobId: 'business',
        expectedPreviewToken: token,
        confirmationEventId: 'business-event',
      );
      expect(retry.version.generation, result.version.generation);
      expect(await count('revision'), 4);
    },
  );
  test(
    'lost response and reopened retry preserve durable business receipts',
    () async {
      await stage();
      final token = await jobs.sealBusinessPreview('business');
      await expectLater(commit(token, fault: 'after_commit'), throwsStateError);
      await rig.reopen();
      receipts = ImportReceiptStore(rig.database);
      final receipt = await rig.coordinator().commitStaged(
        jobId: 'business',
        expectedPreviewToken: token,
        confirmationEventId: 'business-event',
      );
      expect(receipt.version.generation, 1);
      await rig.database.cleanupStaging('business');
      expect(
        (await receipts.readSourceReceipts(source)).items.single.eventId,
        'business-event',
      );
      expect(await count('import_row_receipt'), 2);
      expect(await count('revision'), 4);
    },
  );

  test('failure after receipt insertion rolls back entire batch', () async {
    await stage();
    final token = await jobs.sealBusinessPreview('business');
    await expectLater(commit(token, fault: 'before_commit'), throwsStateError);
    for (final table in [
      'revision',
      'quotation_projection',
      'import_row_receipt',
      'import_decision_receipt',
      'commit_receipt',
    ]) {
      expect(await count(table), 0, reason: table);
    }
    expect((await rig.database.currentVersion()).generation, 0);
    expect((await commit(token)).resultCount, 4);
  });
  test(
    'opaque decision digest cannot bypass persisted import validation',
    () async {
      await stage();
      final token = await jobs.sealPreview('business', 'opaque');
      await expectLater(
        commit(token),
        throwsA(
          isA<DomainFailure>().having(
            (e) => e.code,
            'code',
            'stale_import_decisions',
          ),
        ),
      );
      expect(await count('revision'), 0);
    },
  );
  test('excluded error never becomes successful source receipt', () async {
    await stage(excluded: true);
    await commit(await jobs.sealBusinessPreview('business'));
    expect(await count('import_row_receipt'), 0);
    expect(await count('import_decision_receipt'), 0);
  });
  test(
    'matching version cannot be rebound when sealing business preview',
    () async {
      await stage();
      await rig.database.customStatement(
        'UPDATE database_meta SET generation=generation+1',
      );
      await expectLater(
        jobs.sealBusinessPreview('business'),
        throwsA(
          isA<DomainFailure>().having(
            (e) => e.code,
            'code',
            'stale_job_preview',
          ),
        ),
      );
      expect(
        (await rig.database.job(
          'business',
        )).readNullable<String>('sealed_digest'),
        isNull,
      );
    },
  );
  test('sealed decision and result mapping cannot be changed', () async {
    await stage();
    await jobs.sealBusinessPreview('business');
    await expectLater(
      rig.database.customStatement(
        'UPDATE staging_import_decision SET exclusion_reason=? WHERE job_id=?',
        ['changed', 'business'],
      ),
      throwsA(anything),
    );
    await expectLater(
      rig.database.customStatement(
        'DELETE FROM staging_import_result WHERE job_id=?',
        ['business'],
      ),
      throwsA(anything),
    );
    expect(
      await rig.database.rows(
        'SELECT 1 FROM staging_import_result WHERE job_id=?',
        [Variable('business')],
      ),
      hasLength(2),
    );
  });
}

class _Source implements InputSource {
  @override
  String get displayName => 'business.xlsx';
  @override
  Future<int> length() async => 3;
  @override
  Stream<List<int>> openRange(int start, int endExclusive) async* {
    yield [1, 2, 3].sublist(start, endExclusive);
  }
}
