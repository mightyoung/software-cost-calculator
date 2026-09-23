import 'dart:io';
import 'dart:convert';
import 'package:drift/native.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:supplier_core/supplier_core.dart';
import 'package:test/test.dart';
import 'support/test_rig.dart';
import 'domain_test.dart' show quote;

const sourceId = '00000000-0000-4000-8000-000000000099';
const candidateId = '00000000-0000-4000-8000-000000000098';
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late SupplierDatabase original, candidate;
  late List<BackupEntry> entries;
  setUp(() async {
    original = SupplierDatabase(NativeDatabase.memory(), instanceId: sourceId);
    candidate = SupplierDatabase(
      NativeDatabase.memory(),
      instanceId: candidateId,
    );
    final lock = TestWriteLock();
    await original.createJob('original-job');
    await original.appendStaging('original-job', fixtureRevision(1));
    final token = await original.sealJob('original-job', 'decisions');
    await original.registerConfirmation('original-event', token);
    await CommitCoordinator(
      database: original,
      writeLock: lock,
      readActiveVersion: original.currentVersion,
    ).commitStaged(
      jobId: 'original-job',
      expectedPreviewToken: token,
      confirmationEventId: 'original-event',
    );
    await original.customStatement('INSERT INTO local_settings VALUES(?,?)', [
      'theme',
      '"dark"',
    ]);
    await original
        .customStatement('INSERT INTO import_row_receipt VALUES(?,?,?,?,?,?)', [
          'original-event',
          1,
          'source-fingerprint',
          'operation-fingerprint',
          fixtureRevision(1).entityId,
          fixtureRevision(1).revisionId,
        ]);
    entries = [];
    for (final table in backupTableKeys.keys) {
      for (final row in await original.rows(
        'SELECT ${backupTableColumns[table]!.join(',')} FROM $table',
      )) {
        entries.add(BackupEntry(table, row.data));
      }
    }
  });
  tearDown(() async {
    await original.close();
    await candidate.close();
  });
  Future<_Source> source([List<BackupEntry>? replacement]) async {
    final rows = replacement ?? entries;
    final header = BackupHeader(
      version: await original.currentVersion(),
      counts: {
        for (final table in backupTableKeys.keys)
          table: rows.where((entry) => entry.table == table).length,
      },
    );
    return _Source(
      await encodeBackup(
        header,
        Stream.fromIterable(rows),
      ).expand((chunk) => chunk).toList(),
    );
  }

  Future<BackupSummary> build(InputSource input) => BackupCandidateBuilder(
    database: candidate,
    writeLock: TestWriteLock(),
  ).build(input);
  test(
    'v1 successful legacy receipt restores without invented operation details',
    () async {
      final legacyEntries = entries
          .where((entry) => backupV1TableKeys.containsKey(entry.table))
          .toList();
      final header = BackupHeader(
        version: await original.currentVersion(),
        backupVersion: 1,
        counts: {
          for (final table in backupV1TableKeys.keys)
            table: legacyEntries.where((entry) => entry.table == table).length,
        },
      );
      final bytes = await encodeBackup(
        header,
        Stream.fromIterable(legacyEntries),
      ).expand((chunk) => chunk).toList();
      final summary = await build(_Source(bytes));
      expect(summary.header.backupVersion, 1);
      expect(
        (await candidate.rows(
          'SELECT source_fingerprint FROM import_row_receipt',
        )).single.data['source_fingerprint'],
        'source-fingerprint',
      );
      expect(
        await candidate.rows('SELECT * FROM import_decision_receipt'),
        isEmpty,
      );
    },
  );
  List<BackupEntry> withDecision({
    int quantity = 1,
    String? target,
    bool auxiliaryResult = false,
    bool duplicateEntity = false,
  }) {
    final fingerprint = SourceFingerprint.create(
      fields: {'notes': const SourceCell.blank()},
      inputIdentity: {},
      mappingSemantics: {},
      batchDefaults: {},
      captureMode: 'historical',
    );
    final operation = OperationFingerprint.create(
      source: fingerprint,
      intent: ImportIntent.newInquiry,
      originalBindings: {},
      operations: {'notes': const FieldOperation.clear()},
      confirmedQuantity: quantity,
    );
    final product = RevisionEnvelope.create(
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
      authoredAt: '2026-09-17T00:00:00.000Z',
      originDeviceId: sourceId,
    );
    final quotation = RevisionEnvelope.create(
      entityType: 'quotation',
      entityId: '00000000-0000-4000-8000-000000000082',
      parents: [],
      kind: 'put',
      payload: {
        ...quote(),
        'supplier_id': fixtureRevision(1).entityId,
        'product_id': product.entityId,
        'capture_mode': 'standard',
      },
      authoredAt: '2026-09-17T00:00:00.000Z',
      originDeviceId: sourceId,
    );
    final duplicate = RevisionEnvelope.create(
      entityType: 'quotation',
      entityId: quotation.entityId,
      parents: [quotation.revisionId],
      kind: 'put',
      payload: {...quotation.payload, 'notes': 'changed'},
      authoredAt: '2026-09-18T00:00:00.000Z',
      originDeviceId: sourceId,
    );
    final extra = [product, quotation, if (duplicateEntity) duplicate];
    return [
      for (final entry in entries)
        if (entry.table == 'import_row_receipt')
          BackupEntry(entry.table, {
            ...entry.row,
            'source_fingerprint': fingerprint.digest,
            'operation_fingerprint': operation.digest,
            'result_revision_id': auxiliaryResult
                ? fixtureRevision(1).revisionId
                : quotation.revisionId,
          })
        else if (entry.table == 'commit_receipt')
          BackupEntry(entry.table, {
            ...entry.row,
            'result_count': 1 + extra.length,
          })
        else
          entry,
      for (final revision in extra) ...[
        BackupEntry('revision', {
          'revision_id': revision.revisionId,
          'entity_type': revision.entityType,
          'entity_id': revision.entityId,
          'canonical': revision.canonical,
        }),
        BackupEntry('receipt_result', {
          'event_id': 'original-event',
          'revision_id': revision.revisionId,
        }),
      ],
      if (duplicateEntity)
        BackupEntry('import_row_receipt', {
          'event_id': 'original-event',
          'fingerprint_version': 1,
          'source_fingerprint': fingerprint.digest,
          'operation_fingerprint': operation.digest,
          'original_target_id': fixtureRevision(1).entityId,
          'result_revision_id': duplicate.revisionId,
        }),
      BackupEntry('import_decision_receipt', {
        'event_id': 'original-event',
        'fingerprint_version': 1,
        'source_fingerprint': fingerprint.digest,
        'operation_fingerprint': operation.digest,
        'source_canonical': fingerprint.canonical,
        'operation_canonical': operation.canonical,
        'original_target_id': target ?? fixtureRevision(1).entityId,
      }),
    ];
  }

  test(
    'v2 restores canonical decisions and keeps original result relation',
    () async {
      await build(await source(withDecision()));
      expect(
        await candidate.rows('SELECT * FROM import_decision_receipt'),
        hasLength(1),
      );
    },
  );
  test(
    'v2 rejects auxiliary main results and repeated quotation entities',
    () async {
      await expectLater(
        build(await source(withDecision(auxiliaryResult: true))),
        throwsA(isA<DomainFailure>()),
      );
    },
  );
  test(
    'v2 quantity cannot count two revisions of the same quotation',
    () async {
      await expectLater(
        build(await source(withDecision(quantity: 2, duplicateEntity: true))),
        throwsA(isA<DomainFailure>()),
      );
    },
  );
  test('v2 detailed decisions cannot share a main quotation', () async {
    final rows = withDecision();
    final details = rows.last.row;
    final canonical = canonicalJson({
      ...jsonDecode(details['operation_canonical']! as String)
          as Map<String, Object?>,
      'original_bindings': {'different': true},
    });
    final digest = canonicalSha256(jsonDecode(canonical));
    rows.add(
      BackupEntry('import_decision_receipt', {
        ...details,
        'operation_fingerprint': digest,
        'operation_canonical': canonical,
      }),
    );
    final result = rows.firstWhere((r) => r.table == 'import_row_receipt');
    rows.add(
      BackupEntry('import_row_receipt', {
        ...result.row,
        'operation_fingerprint': digest,
      }),
    );
    await expectLater(build(await source(rows)), throwsA(isA<DomainFailure>()));
  });
  test(
    'v2 intent and field operations must agree with actual results',
    () async {
      final rows = withDecision();
      final details = rows.last.row;
      final canonical = canonicalJson({
        ...jsonDecode(details['operation_canonical']! as String)
            as Map<String, Object?>,
        'operations': {
          'notes': {'kind': 'set', 'value': 'not-the-result'},
        },
      });
      final digest = canonicalSha256(jsonDecode(canonical));
      final modified = [
        for (final row in rows)
          if (row.table == 'import_decision_receipt')
            BackupEntry(row.table, {
              ...row.row,
              'operation_canonical': canonical,
              'operation_fingerprint': digest,
            })
          else if (row.table == 'import_row_receipt')
            BackupEntry(row.table, {
              ...row.row,
              'operation_fingerprint': digest,
            })
          else
            row,
      ];
      await expectLater(
        build(await source(modified)),
        throwsA(isA<DomainFailure>()),
      );
    },
  );
  test('v2 decision original target must match result receipt', () async {
    await expectLater(
      build(await source(withDecision(target: ''))),
      throwsA(isA<DomainFailure>()),
    );
  });
  test('v2 confirmed quantity must match result set', () async {
    await expectLater(
      build(await source(withDecision(quantity: 2))),
      throwsA(isA<DomainFailure>()),
    );
  });
  test('v2 canonical mismatch is rejected before accepting a row', () async {
    final row = withDecision().last.row;
    expect(
      () => BackupEntry('import_decision_receipt', {
        ...row,
        'operation_canonical': '{}',
      }),
      throwsA(isA<DomainFailure>()),
    );
  });
  test(
    'restores graph projections settings and original receipts with new identity',
    () async {
      final summary = await build(await source());
      expect(summary.header.version.instanceId, sourceId);
      final version = await candidate.currentVersion();
      expect(version.instanceId, candidateId);
      expect(version.activeEpoch, 0);
      expect(version.generation, 1);
      expect(
        (await candidate.rows(
          'SELECT name FROM supplier_projection',
        )).single.read<String>('name'),
        'Supplier 1',
      );
      for (final table in backupTableKeys.keys) {
        expect(
          (await candidate.rows(
            'SELECT COUNT(*) n FROM $table',
          )).single.read<int>('n'),
          summary.header.counts[table],
        );
      }
      expect(
        (await candidate.rows(
          'SELECT event_id FROM commit_receipt',
        )).single.read<String>('event_id'),
        'original-event',
      );
      expect(
        await candidate.rows('SELECT 1 FROM pragma_foreign_key_check'),
        isEmpty,
      );
    },
  );
  test(
    'duplicate revision refuses candidate before authority install',
    () async {
      await expectLater(
        build(
          await source([
            ...entries,
            entries.firstWhere((e) => e.table == 'revision'),
          ]),
        ),
        throwsA(anything),
      );
      expect(await candidate.rows('SELECT 1 FROM revision'), isEmpty);
    },
  );
  test('bad hash refuses candidate before authority install', () async {
    final input = await source();
    input.bytes[input.bytes.length - 5] = 120;
    await expectLater(build(input), throwsA(anything));
    expect(await candidate.rows('SELECT 1 FROM revision'), isEmpty);
  });
  test('bad receipt count rejects after graph validation', () async {
    final rows = entries
        .map(
          (e) => e.table == 'commit_receipt'
              ? BackupEntry(e.table, {...e.row, 'result_count': 99})
              : e,
        )
        .toList();
    await expectLater(build(await source(rows)), throwsA(isA<DomainFailure>()));
  });
  test('bad receipt FK rejects and leaves original untouched', () async {
    final rows = entries
        .map(
          (e) => e.table == 'receipt_result'
              ? BackupEntry(e.table, {...e.row, 'revision_id': 'missing'})
              : e,
        )
        .toList();
    await expectLater(build(await source(rows)), throwsA(anything));
    expect((await original.currentVersion()).generation, 1);
  });
  test('dangling graph parent rejected by real graph validator', () async {
    final revision = fixtureRevision(2, parents: ['a' * 64]);
    final rows = entries.where((e) => e.table != 'revision').toList()
      ..add(
        BackupEntry('revision', {
          'revision_id': revision.revisionId,
          'entity_type': revision.entityType,
          'entity_id': revision.entityId,
          'canonical': revision.canonical,
        }),
      );
    await expectLater(build(await source(rows)), throwsA(anything));
    expect(await candidate.rows('SELECT 1 FROM revision'), isEmpty);
  });
  test(
    'duplicate auxiliary identity rejected before authority install',
    () async {
      final duplicate = entries.firstWhere(
        (entry) => entry.table == 'local_settings',
      );
      await expectLater(
        build(await source([...entries, duplicate])),
        throwsA(anything),
      );
      expect(await candidate.rows('SELECT 1 FROM revision'), isEmpty);
    },
  );
  test(
    'empty backup restores source generation without synthetic receipts',
    () async {
      final summary = await build(await source([]));
      expect(summary.header.counts.values.every((count) => count == 0), isTrue);
      expect(await candidate.rows('SELECT 1 FROM commit_receipt'), isEmpty);
      expect((await candidate.currentVersion()).generation, 1);
    },
  );
  test('row receipt must belong to the same event result set', () async {
    final rows = entries
        .where((entry) => entry.table != 'receipt_result')
        .map(
          (entry) => entry.table == 'commit_receipt'
              ? BackupEntry(entry.table, {...entry.row, 'result_count': 0})
              : entry,
        )
        .toList();
    await expectLater(build(await source(rows)), throwsA(isA<DomainFailure>()));
  });
  test('paged auxiliary restoration survives native file reopen', () async {
    final directory = await Directory.systemTemp.createTemp(
      'backup-candidate-test-',
    );
    addTearDown(() async => directory.delete(recursive: true));
    await candidate.close();
    final file = File('${directory.path}/candidate.sqlite');
    candidate = SupplierDatabase(NativeDatabase(file), instanceId: candidateId);
    final rows = [
      ...entries,
      for (var i = 0; i < 70; i++)
        BackupEntry('local_settings', {
          'key': 'setting-$i',
          'value_json': '$i',
        }),
    ];
    await build(await source(rows));
    await candidate.close();
    candidate = SupplierDatabase(
      NativeDatabase(file),
      instanceId: 'constructor-value-is-not-authority',
    );
    expect((await candidate.currentVersion()).instanceId, candidateId);
    expect(
      (await candidate.rows(
        'SELECT COUNT(*) n FROM local_settings',
      )).single.read<int>('n'),
      71,
    );
    expect(
      (await candidate.rows(
        'SELECT COUNT(*) n FROM import_row_receipt',
      )).single.read<int>('n'),
      1,
    );
    expect(
      await candidate.rows(
        "SELECT 1 FROM sqlite_master WHERE name='backup_candidate_work'",
      ),
      isEmpty,
    );
  });
  test(
    'same-source receipt cannot be newer than snapshot generation',
    () async {
      await original.customStatement('UPDATE database_meta SET generation=0');
      await expectLater(build(await source()), throwsA(isA<DomainFailure>()));
    },
  );
  test('nonempty candidate rejected', () async {
    await candidate.createJob('existing');
    await expectLater(build(await source()), throwsA(isA<DomainFailure>()));
  });
  test('actual SQLITE_FULL quarantines candidate across reopen', () async {
    final directory = await Directory.systemTemp.createTemp('candidate-full-');
    addTearDown(() => directory.delete(recursive: true));
    await candidate.close();
    final file = File('${directory.path}/candidate.sqlite');
    candidate = SupplierDatabase(NativeDatabase(file), instanceId: candidateId);
    await candidate.currentVersion();
    final pages = (await candidate.rows(
      'PRAGMA page_count',
    )).single.read<int>('page_count');
    // Leave room for the work table, but not the valid 200 KiB setting below.
    // This exercises SQLite's pager limit, not a mocked write exception.
    await candidate.customStatement('PRAGMA max_page_count=${pages + 8}');
    final input = await source([
      ...entries,
      BackupEntry('local_settings', {
        'key': 'large-setting',
        'value_json': '"${'x' * (200 * 1024)}"',
      }),
    ]);
    // A plausible platform estimate can still be wrong for the actual SQLite
    // allocation limit. Admission must never replace transactional isolation.
    RestoreSpaceEstimate(
      version: await original.currentVersion(),
      phase: 'prepare',
      capacity: CapacitySample(
        status: 'estimated',
        scope: 'test',
        availableBytes: 1024 * 1024 * 1024,
      ),
      activeBytes: await databaseAllocatedBytes(original),
      sourceBytes: await input.length(),
    ).requireAvailable();
    await expectLater(
      build(input),
      throwsA(
        predicate<Object>(
          (error) => error.toString().contains('database or disk is full'),
        ),
      ),
    );
    await candidate.close();
    candidate = SupplierDatabase(NativeDatabase(file), instanceId: candidateId);
    expect((await candidate.currentVersion()).generation, 0);
    for (final table in ['revision', 'commit_receipt', 'local_settings']) {
      expect(await candidate.rows('SELECT 1 FROM $table'), isEmpty);
    }
    expect(
      (await candidate.rows('PRAGMA integrity_check')).single.data.values,
      ['ok'],
    );
    // An interrupted candidate remains marked by its work table and cannot be
    // silently retried as a fresh restore, even after capacity becomes available.
    expect(
      await candidate.rows(
        "SELECT 1 FROM sqlite_master WHERE name='backup_candidate_work'",
      ),
      hasLength(1),
    );
    await expectLater(build(input), throwsA(anything));
    expect((await original.currentVersion()).generation, 1);
    expect(await original.rows('SELECT 1 FROM revision'), hasLength(1));
    expect(await original.rows('SELECT 1 FROM commit_receipt'), hasLength(1));
  });
}

class _Source implements InputSource {
  _Source(this.bytes);
  final List<int> bytes;
  @override
  String get displayName => 'candidate.backup';
  @override
  Future<int> length() async => bytes.length;
  @override
  Stream<List<int>> openRange(int start, int endExclusive) async* {
    yield bytes.sublist(start, endExclusive);
  }
}
