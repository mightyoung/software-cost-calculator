import 'package:drift/native.dart';
import 'package:supplier_core/supplier_core.dart';
import 'package:test/test.dart';
import 'support/test_rig.dart';

void main() {
  late SupplierDatabase database;
  setUp(() async {
    database = SupplierDatabase(
      NativeDatabase.memory(),
      instanceId: 'candidate',
    );
    await database.createJob('job');
    await database.appendStaging('job', fixtureRevision(1));
    final token = await database.sealJob('job', 'decisions');
    await database.registerConfirmation('event', token);
    await CommitCoordinator(
      database: database,
      writeLock: TestWriteLock(),
      readActiveVersion: database.currentVersion,
    ).commitStaged(
      jobId: 'job',
      expectedPreviewToken: token,
      confirmationEventId: 'event',
    );
  });
  tearDown(() => database.close());
  test('only activation epoch is ignored', () async {
    final before = await candidateContentDigest(database);
    await database.customStatement('UPDATE database_meta SET active_epoch=20');
    expect(await candidateContentDigest(database), before);
    await database.customStatement('UPDATE database_meta SET generation=20');
    expect(await candidateContentDigest(database), isNot(before));
  });
  for (final mutation in <String, String>{
    'trigger': 'DROP TRIGGER staging_seal_insert',
    'index': 'DROP INDEX receipt_source',
    'setting': "INSERT INTO local_settings VALUES('theme','1')",
    'projection': "UPDATE supplier_projection SET name='changed'",
    'revision': "UPDATE revision SET canonical=canonical||' '",
    'receipt': 'UPDATE commit_receipt SET result_count=2',
    'work table': "INSERT INTO graph_run VALUES('work','job','quarantined')",
  }.entries) {
    test('${mutation.key} changes binding', () async {
      final before = await candidateContentDigest(database);
      await database.customStatement(mutation.value);
      expect(await candidateContentDigest(database), isNot(before));
    });
  }
  test('pages beyond32 and canonical order independent of insertion', () async {
    for (var i = 70; i >= 0; i--) {
      await database.customStatement('INSERT INTO local_settings VALUES(?,?)', [
        'key-$i',
        '$i',
      ]);
    }
    final before = await candidateContentDigest(database);
    await database.customStatement('DELETE FROM local_settings');
    for (var i = 0; i <= 70; i++) {
      await database.customStatement('INSERT INTO local_settings VALUES(?,?)', [
        'key-$i',
        '$i',
      ]);
    }
    expect(await candidateContentDigest(database), before);
    await database.customStatement(
      'UPDATE local_settings SET value_json=? WHERE key=?',
      ['99', 'key-69'],
    );
    expect(await candidateContentDigest(database), isNot(before));
  });
  test('unexpected user table refused rather than omitting its data', () async {
    await database.customStatement(
      'CREATE TABLE extra(id TEXT PRIMARY KEY,v TEXT)',
    );
    await database.customStatement("INSERT INTO extra VALUES('id','value')");
    await expectLater(
      candidateContentDigest(database),
      throwsA(isA<DomainFailure>()),
    );
  });
  test('SQLite schema version mutation is refused', () async {
    await database.customStatement('PRAGMA user_version=4');
    await expectLater(
      candidateContentDigest(database),
      throwsA(isA<DomainFailure>()),
    );
  });
  test('oversized row refused before reading payload', () async {
    await database.customStatement('INSERT INTO local_settings VALUES(?,?)', [
      'large',
      '"${'x' * (512 * 1024)}"',
    ]);
    await expectLater(
      candidateContentDigest(database),
      throwsA(isA<DomainFailure>()),
    );
  });
}
