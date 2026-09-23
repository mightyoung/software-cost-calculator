import 'dart:convert';
import 'dart:js_interop';
import 'package:drift/wasm.dart';
import 'main.dart' show Probe;

@JS('restoreReadPointer')
external JSPromise<JSString> readPointer();
@JS('restoreSeedOld')
external set seed(JSFunction value);
@JS('restorePrepareCandidate')
external set prepare(JSFunction value);
@JS('restoreInspectCandidate')
external set inspect(JSFunction value);
@JS('restoreShiftCandidateIds')
external set shiftCandidateIds(JSFunction value);
@JS('restoreClose')
external set close(JSFunction value);
@JS('restoreReopen')
external set reopen(JSFunction value);
@JS('restoreFacts')
external set facts(JSFunction value);
@JS('restoreSqlWrite')
external set write(JSFunction value);
@JS('restoreValidationError')
external set validationError(JSString value);
@JS('restoreWriteEnabled')
external set writeEnabled(JSBoolean value);
@JS('restorePointerExists')
external JSBoolean get pointerExists;
@JS('probeReady')
external set ready(JSBoolean value);
@JS('probeInfo')
external set info(JSString value);

Future<Probe> openFixture(String instance) async {
  final run = Uri.base.queryParameters['run']!;
  final opened = await WasmDatabase.open(
    databaseName: 'nonproduct-t1-restore-$run-$instance',
    sqlite3Uri: Uri.parse('sqlite3.wasm'),
    driftWorkerUri: Uri.parse('drift_worker.js'),
  );
  if (opened.chosenImplementation == WasmStorageImplementation.inMemory ||
      opened.chosenImplementation ==
          WasmStorageImplementation.unsafeIndexedDb) {
    throw StateError('Persistent reliable backend required');
  }
  info = jsonEncode({'backend': opened.chosenImplementation.name}).toJS;
  return Probe(opened.resolvedExecutor);
}

Future<Map<String, Object?>> fixtureFacts(Probe db) => db.transaction(() async {
  final m = await db.customSelect('SELECT * FROM metadata').getSingle();
  final generation = m.read<int>('generation');
  final old = m.read<String>('instance') == 'old';
  final predicate = old
      ? "payload=printf('%0256d',id)"
      : generation == 42
      ? "payload='restored'"
      : "payload='changed'";
  final counts = await db
      .customSelect(
        'SELECT count(*) rows, min(id) minId, max(id) maxId, coalesce(sum(CASE WHEN $predicate THEN 1 ELSE 0 END),0) validRows FROM rows',
      )
      .getSingle();
  final integrity = await db.customSelect('PRAGMA integrity_check').getSingle();
  return {...m.data, ...counts.data, 'integrity': integrity.data.values.single};
});
Future<void> main() async {
  var activeInstance = '';
  Future<Probe> openActive() async {
    final pointer =
        jsonDecode((await readPointer().toDart).toDart) as Map<String, dynamic>;
    final instance = pointer['instance'] as String;
    if (instance != 'old' && instance != 'candidate')
      throw StateError('Unknown fixture instance');
    activeInstance = instance;
    return openFixture(instance);
  }

  var db = await openActive();
  Future<bool> validateActive({bool allowBootstrap = false}) async {
    final count = await db
        .customSelect('SELECT count(*) n FROM metadata')
        .getSingle();
    if (allowBootstrap && count.read<int>('n') == 0 && !pointerExists.toDart)
      return false;
    if (count.read<int>('n') != 1)
      throw StateError('Reopen validation failed: metadata count');
    final current = await fixtureFacts(db);
    final expected = activeInstance == 'old' ? 1025 : 17;
    final generation = current['generation'] as int;
    if (current['instance'] != activeInstance ||
        (activeInstance == 'old' ? generation != 1 : generation < 42) ||
        current['integrity'] != 'ok' ||
        current['rows'] != expected ||
        current['validRows'] != expected ||
        current['minId'] != 1 ||
        current['maxId'] != expected) {
      throw StateError('Reopen validation failed');
    }
    return true;
  }

  seed = (() => db.transaction(() async {
    await db.customStatement('DELETE FROM metadata');
    await db.customStatement('DELETE FROM rows');
    await db.customStatement("INSERT INTO metadata VALUES(1,'old',1)");
    await db.customStatement(
      "WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<1025) INSERT INTO rows SELECT x,printf('%0256d',x) FROM n",
    );
    return true.toJS;
  }).toJS).toJS;
  prepare = (() => (() async {
    final candidate = await openFixture('candidate');
    try {
      await candidate.transaction(() async {
        await candidate.customStatement('DELETE FROM metadata');
        await candidate.customStatement('DELETE FROM rows');
        await candidate.customStatement(
          "INSERT INTO metadata VALUES(1,'candidate',42)",
        );
        await candidate.customStatement(
          "WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<17) INSERT INTO rows SELECT x,'restored' FROM n",
        );
      });
      return jsonEncode(await fixtureFacts(candidate)).toJS;
    } finally {
      await candidate.close();
    }
  })().toJS).toJS;
  inspect = (() => (() async {
    final candidate = await openFixture('candidate');
    try {
      return jsonEncode(await fixtureFacts(candidate)).toJS;
    } finally {
      await candidate.close();
    }
  })().toJS).toJS;
  shiftCandidateIds = (() => (() async {
    final candidate = await openFixture('candidate');
    try {
      await candidate.transaction(() async {
        await candidate.customStatement('UPDATE rows SET id=-id');
        await candidate.customStatement('UPDATE rows SET id=1-id');
      });
      return true.toJS;
    } finally {
      await candidate.close();
    }
  })().toJS).toJS;
  close = (() {
    writeEnabled = false.toJS;
    return db.close().then((_) => true.toJS).toJS;
  }).toJS;
  reopen = (() => (() async {
    writeEnabled = false.toJS;
    db = await openActive();
    await validateActive();
    validationError = ''.toJS;
    return true.toJS;
  })().toJS).toJS;
  facts = (() => fixtureFacts(db).then((f) => jsonEncode(f).toJS).toJS).toJS;
  write = (() => db.transaction(() async {
    await db.customStatement("UPDATE rows SET payload='changed'");
    await db.customStatement('UPDATE metadata SET generation=generation+1');
    return true.toJS;
  }).toJS).toJS;
  // Initial empty old DB is allowed only to bootstrap this nonproduct fixture.
  writeEnabled = false.toJS;
  validationError = ''.toJS;
  try {
    final populated = await validateActive(allowBootstrap: true);
    writeEnabled = populated.toJS;
  } catch (error) {
    // A failed candidate remains inspectable by this nonproduct diagnostic harness.
    // probeReady indicates diagnostics loaded; restoreWriteEnabled remains false.
    validationError = error.toString().toJS;
  }
  ready = true.toJS;
}
