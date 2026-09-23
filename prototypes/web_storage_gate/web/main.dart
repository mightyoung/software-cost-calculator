import 'dart:convert';
import 'dart:js_interop';
import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';
import 'package:drift/wasm.dart';

@JS('probeSeed')
external set seed(JSFunction f);
@JS('probeCommit')
external set commit(JSFunction f);
@JS('probeHoldCommit')
external set holdCommit(JSFunction f);
@JS('probeIntegrity')
external set integrity(JSFunction f);
@JS('probeCrashBarrier')
external JSPromise<JSAny?> crashBarrier();
@JS('probeSnapshot')
external set snapshot(JSFunction f);
@JS('probeState')
external set state(JSFunction f);
@JS('probeReady')
external set ready(JSBoolean b);
@JS('probeInfo')
external set info(JSString s);
@JS('probeInterleave')
external JSPromise<JSAny?> interleave();
@JS('probePage')
external JSPromise<JSAny?> page(JSString s);

class DigestSink implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}

class Probe extends GeneratedDatabase {
  Probe(super.e);
  @override
  int get schemaVersion => 1;
  @override
  Iterable<TableInfo> get allTables => [];
  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) async {
      await customStatement(
        'CREATE TABLE metadata(id INTEGER PRIMARY KEY, instance TEXT NOT NULL, generation INTEGER NOT NULL)',
      );
      await customStatement(
        'CREATE TABLE rows(id INTEGER PRIMARY KEY, payload TEXT NOT NULL)',
      );
    },
  );
  Future<Map<String, Object?>> current() async {
    final m = await customSelect('SELECT * FROM metadata').getSingle();
    final count = await customSelect(
      "SELECT count(*) n FROM rows WHERE payload = 'changed'",
    ).getSingle();
    return {...m.data, 'changed': count.read<int>('n')};
  }
}

Future<void> main() async {
  final run = Uri.base.queryParameters['run'] ?? 'manual';
  final opened = await WasmDatabase.open(
    databaseName: 'nonproduct-t1-db-$run',
    sqlite3Uri: Uri.parse('sqlite3.wasm'),
    driftWorkerUri: Uri.parse('drift_worker.js'),
  );
  if (opened.chosenImplementation == WasmStorageImplementation.inMemory ||
      opened.chosenImplementation ==
          WasmStorageImplementation.unsafeIndexedDb) {
    throw StateError(
      'Reliable persistent backend unavailable: ${opened.chosenImplementation}',
    );
  }
  final db = Probe(opened.resolvedExecutor);
  final version = await db
      .customSelect('SELECT sqlite_version() AS version')
      .getSingle();
  final journal = await db.customSelect('PRAGMA journal_mode').getSingle();
  info = jsonEncode({
    'backend': opened.chosenImplementation.name,
    'sqlite': version.data,
    'journal': journal.data,
    'missing': opened.missingFeatures.map((f) => f.name).toList(),
  }).toJS;
  seed = (() => db.transaction(() async {
    await db.customStatement('DELETE FROM rows');
    await db.customStatement('DELETE FROM metadata');
    await db.customStatement("INSERT INTO metadata VALUES(1,'old',1)");
    await db.customStatement(
      "WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<1025) INSERT INTO rows SELECT x, printf('%0256d',x) FROM n",
    );
    return 'seeded'.toJS;
  }).toJS).toJS;
  commit = (() => db.transaction(() async {
    await db.customStatement("UPDATE rows SET payload='changed'");
    await db.customStatement('UPDATE metadata SET generation=generation+1');
    return 'committed'.toJS;
  }).toJS).toJS;
  holdCommit = (() => db.transaction(() async {
    await db.customStatement(
      "UPDATE rows SET payload='UNCOMMITTED_CRASH_WRITE'",
    );
    await db.customStatement('UPDATE metadata SET generation=generation+1');
    // The test kills the isolated browser group only after both SQL statements complete.
    await crashBarrier().toDart;
    return 'unexpectedly committed'.toJS;
  }).toJS).toJS;
  integrity =
      (() => db
              .customSelect('PRAGMA integrity_check')
              .getSingle()
              .then((r) => jsonEncode(r.data).toJS)
              .toJS)
          .toJS;
  state = (() => db.current().then((v) => jsonEncode(v).toJS).toJS).toJS;
  snapshot = (() => db.transaction(() async {
    // First SELECT pins the generation and all subsequent keyset pages to this transaction.
    final metadata = await db
        .customSelect('SELECT instance,generation FROM metadata')
        .getSingle();
    await interleave().toDart;
    final digest = DigestSink();
    final hash = sha256.startChunkedConversion(digest);
    var cursor = 0, count = 0, maxPage = 0;
    var allOriginal = true;
    while (true) {
      final rows = await db
          .customSelect(
            'SELECT id,payload FROM rows WHERE id > ? ORDER BY id LIMIT 64',
            variables: [Variable.withInt(cursor)],
          )
          .get();
      if (rows.isEmpty) break;
      if (rows.length > maxPage) maxPage = rows.length;
      final data = '${jsonEncode(rows.map((r) => r.data).toList())}\n';
      hash.add(utf8.encode(data));
      await page(data.toJS).toDart;
      for (final row in rows) {
        allOriginal &=
            row.read<String>('payload') ==
            row.read<int>('id').toString().padLeft(256, '0');
      }
      count += rows.length;
      cursor = rows.last.read<int>('id');
    }
    hash.close();
    final end = await db
        .customSelect('SELECT generation FROM metadata')
        .getSingle();
    if (end.read<int>('generation') != metadata.read<int>('generation'))
      throw StateError('Snapshot generation changed');
    return jsonEncode({
      ...metadata.data,
      'rows': count,
      'maxPage': maxPage,
      'allOriginal': allOriginal,
      'sha256': digest.value.toString(),
    }).toJS;
  }).toJS).toJS;
  ready = true.toJS;
}
