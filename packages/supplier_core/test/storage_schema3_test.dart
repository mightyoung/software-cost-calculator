import 'package:drift/native.dart';
import 'package:supplier_core/supplier_core.dart';
import 'package:test/test.dart';
import 'support/test_rig.dart';

void main() {
  late SupplierDatabase db;
  setUp(() async {
    db = SupplierDatabase(
      NativeDatabase.memory(),
      instanceId: '00000000-0000-4000-8000-000000000071',
    );
    await db.createJob('job');
    await db.createJob('other');
    await db.appendStaging('job', fixtureRevision(1));
  });
  tearDown(() => db.close());
  Future<void> decision(
    String id, {
    String action = 'apply',
    String? source = 'source',
    String? operation = 'operation',
  }) => db.customStatement(
    'INSERT INTO staging_import_decision VALUES(?,?,?,?,?,?,?,?,?,?,?)',
    [
      'job',
      id,
      action,
      1,
      source,
      source == null ? null : '{}',
      operation,
      operation == null ? null : '{}',
      '',
      '{}',
      null,
    ],
  );
  Future<void> result(String id) => db.customStatement(
    'INSERT INTO staging_import_result VALUES(?,?,?)',
    ['job', id, fixtureRevision(1).revisionId],
  );
  test(
    'applied source and operation unique; source-less excluded error legal',
    () async {
      await decision('apply');
      await expectLater(decision('duplicate'), throwsA(anything));
      await decision(
        'excluded',
        action: 'excludeError',
        source: null,
        operation: null,
      );
      await decision('skip', action: 'skip', operation: null);
      await expectLater(
        decision('bad-skip', action: 'skip', source: null, operation: null),
        throwsA(anything),
      );
      await expectLater(
        decision('bad-operation', action: 'skip'),
        throwsA(anything),
      );
      await expectLater(
        decision('bad-apply', operation: null),
        throwsA(anything),
      );
    },
  );
  test('results require apply and same-job staging revision', () async {
    await decision('apply');
    await result('apply');
    await decision('skip', action: 'skip', operation: null);
    await expectLater(result('skip'), throwsA(anything));
    await expectLater(
      db.customStatement(
        "UPDATE staging_import_decision SET action='skip',operation_fingerprint=NULL,operation_canonical=NULL WHERE decision_id='apply'",
      ),
      throwsA(anything),
    );
    await expectLater(
      db.customStatement(
        "INSERT INTO staging_import_result VALUES('job','apply','missing')",
      ),
      throwsA(anything),
    );
  });
  test(
    'sealed changes rejected and terminal cleanup removes dependents',
    () async {
      await decision('apply');
      await result('apply');
      await db.sealJob('job', 'digest');
      for (final sql in [
        "DELETE FROM staging_import_decision WHERE job_id='job'",
        "DELETE FROM staging_import_result WHERE job_id='job'",
        "UPDATE staging_import_decision SET job_id='other' WHERE job_id='job'",
        "UPDATE staging_import_result SET job_id='other' WHERE job_id='job'",
        "UPDATE staging_import_decision SET decision_canonical='tamper' WHERE job_id='job'",
      ]) {
        await expectLater(db.customStatement(sql), throwsA(anything));
      }
      await db.customStatement(
        "UPDATE import_job SET state='cancelled' WHERE job_id='job'",
      );
      await db.cleanupStaging('job');
      expect(await db.rows('SELECT * FROM staging_import_decision'), isEmpty);
      expect(await db.rows('SELECT * FROM staging_import_result'), isEmpty);
      expect((await db.job('job')).data['sealed_digest'], isNotNull);
    },
  );
}
