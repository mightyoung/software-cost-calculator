import 'dart:convert';
import 'dart:js_interop';

import 'package:drift/wasm.dart';
import 'package:drift/drift.dart';
import 'package:supplier_core/supplier_core.dart';
import 'package:supplier_app/platform/web_database_host.dart';
import 'package:supplier_app/platform/web_file_ports.dart';
import 'package:supplier_app/platform/web_installation_store.dart';

@JS('migrationSmoke')
external set smoke(JSFunction value);
@JS('migrationErrorDetail')
external set errorDetail(JSString value);
@JS('migrationStage')
external set stage(JSString value);
@JS('probeReady')
external set ready(JSBoolean value);
@JS('setMigrationFault')
external void fault(JSString value);
@JS('migrationStats')
external JSString stats();
String get base => Uri.base.queryParameters['run']!;
void check(bool value, String message) {
  if (!value) throw StateError(message);
}

late WasmProbeResult probe;
late WasmStorageImplementation implementation;
Future<SupplierDatabase> raw(
  String ns,
  String id, {
  bool create = false,
  int storage = 2,
}) async => SupplierDatabase(
  await probe.open(
    implementation,
    'supplier-$ns-db-$id',
    enableMigrations: create,
  ),
  instanceId: id,
  storageVersion: storage,
  useDrift235WebLockSavepoints:
      implementation == WasmStorageImplementation.opfsLocks,
);
Future<String> seed(
  String ns, {
  bool bootstrap = false,
  bool empty = false,
}) async {
  final id = newWebInstanceId();
  final store = WebInstallationStore(ns);
  await store.compareAndSet(
    expected: {'installation': null},
    changes: {
      'installation': {'schema': 2, 'device_id': newWebInstanceId()},
      bootstrap ? 'bootstrap' : 'active': {
        'instance_id': id,
        if (!bootstrap) 'epoch': 0,
      },
    },
  );
  if (empty) {
    final exec = await probe.open(
      implementation,
      'supplier-$ns-db-$id',
      enableMigrations: false,
    );
    await exec.ensureOpen(const EmptyProbe());
    await exec.runSelect('PRAGMA user_version', const []);
    await exec.close();
  } else {
    final db = await raw(ns, id, create: true);
    await db.currentVersion();
    await db.customStatement('UPDATE database_meta SET generation=7');
    await db.customStatement('INSERT INTO local_settings VALUES(?,?)', [
      'theme',
      '"dark"',
    ]);
    await db.close();
  }
  return id;
}

Future<Map<String, Object?>> run(String op) async {
  probe = await WasmDatabase.probe(
    sqlite3Uri: Uri.base.resolve('sqlite3.wasm'),
    driftWorkerUri: Uri.base.resolve('drift_worker.js'),
  );
  implementation = probe.availableStorages.firstWhere(
    (v) => v.storageApi == WebStorageApi.opfs,
  );
  if (op == 'reopen') {
    final host = await WebDatabaseHost.open(namespace: '$base-normal');
    check(
      (await host.readActiveVersion()).generation == 8,
      'retry incremented twice',
    );
    await host.close();
    return {'restart_generation': 8};
  }
  final results = <String, Object?>{};
  for (final mode in [
    'normal',
    'private-create',
    'metadata',
    'corrupt-read',
    'bootstrap',
    'empty',
  ]) {
    stage = mode.toJS;
    final ns = '$base-$mode';
    final id = await seed(
      ns,
      bootstrap: mode == 'bootstrap' || mode == 'empty',
      empty: mode == 'empty',
    );
    if (['private-create', 'metadata', 'corrupt-read'].contains(mode)) {
      fault(mode.toJS);
      var failed = false;
      try {
        final host = await WebDatabaseHost.open(namespace: ns);
        await host.close();
      } catch (_) {
        failed = true;
      }
      check(failed, 'injected failure accepted');
      final db = await raw(ns, id);
      check(
        (await db.rows('PRAGMA user_version')).single
                .read<int>('user_version') ==
            2,
        'failure migrated',
      );
      check(
        (await db.currentVersion()).generation == 7,
        'failure changed generation',
      );
      await db.close();
      final counters = jsonDecode(stats().toDart) as Map;
      check(counters['injected'] == true, 'failure not injected');
      if (mode == 'private-create') {
        check((counters['aborts'] as num) > 0, 'durable owner leaked');
      }
      results['$mode-failure'] = counters;
      fault(''.toJS);
    }
    final host = await WebDatabaseHost.open(namespace: ns);
    check(host.database.storageVersion == 3, 'not reopened as3');
    check(
      (await host.readActiveVersion()).generation == (mode == 'empty' ? 0 : 8),
      'wrong generation',
    );
    if (mode != 'empty') {
      check(
        (await host.database.rows('SELECT value_json FROM local_settings'))
                .single
                .data
                .values
                .single ==
            '"dark"',
        'settings lost',
      );
    }
    await host.close();
    results[mode] = 'PASS';
  }
  for (final nonempty in [false, true]) {
    final ns = '$base-reject-zero-$nonempty';
    final id = await seed(ns, bootstrap: nonempty, empty: true);
    if (nonempty) {
      final executor = await probe.open(
        implementation,
        'supplier-$ns-db-$id',
        enableMigrations: false,
      );
      await executor.ensureOpen(const EmptyProbe());
      await executor.runCustom('CREATE TABLE unrelated(value TEXT)', const []);
      await executor.close();
    }
    var rejected = false;
    try {
      final host = await WebDatabaseHost.open(namespace: ns);
      await host.close();
    } on DomainFailure catch (e) {
      rejected = e.code == 'database_schema';
    }
    check(rejected, 'unsafe schema0 initialized');
    results['reject-zero-$nonempty'] = 'PASS';
  }
  // Ready candidate stays physically v2 and retains its old digest.
  final ns = '$base-candidate',
      id = await seed(ns),
      candidate = newWebInstanceId();
  final old = await raw(ns, id), db = await raw(ns, candidate, create: true);
  await db.currentVersion();
  await db.customStatement('UPDATE database_meta SET generation=7');
  final digest = await candidateContentDigest(db);
  await db.close();
  await old.close();
  final store = WebInstallationStore(ns);
  final record = {
    'instance_id': candidate,
    'state': 'ready',
    'expected_instance': id,
    'expected_epoch': 0,
    'expected_generation': 7,
    'generation': 7,
    'content_digest': digest,
  };
  await store.compareAndSet(
    expected: {'candidate:$candidate': null},
    changes: {'candidate:$candidate': record},
  );
  final host = await WebDatabaseHost.open(namespace: ns);
  final untouched = await host.openDatabase(candidate, 0);
  check(
    untouched.storageVersion == 2 &&
        await candidateContentDigest(untouched) == digest,
    'sealed candidate changed',
  );
  await untouched.close();
  var stale = false;
  try {
    await host.activateRestore(candidate);
  } on DomainFailure catch (e) {
    stale = e.code == 'stale_preview';
  }
  check(stale, 'old candidate accepted after migration');
  await host.close();
  results['sealed-candidate'] = 'PASS';
  // Armed v2 journal must validate its original digest before migrating chosen active.
  for (final boundary in ['armed', 'switched', 'rollback_pending']) {
    stage = 'pending-$boundary'.toJS;
    final pending = '$base-pending-$boundary',
        previous = await seed(pending),
        next = newWebInstanceId();
    final candidateDb = await raw(pending, next, create: true);
    await candidateDb.currentVersion();
    final oldDigest = await candidateContentDigest(candidateDb);
    if (boundary == 'switched') {
      await candidateDb.rebindActivationEpoch(
        expectedVersion: await candidateDb.currentVersion(),
        newEpoch: 1,
      );
    }
    await candidateDb.close();
    final previousDb = await raw(pending, previous);
    final safety = await WebDurableBackup.create(pending);
    final lock = WebApplicationWriteLock(pending);
    final summary = await BackupService(
      database: previousDb,
      writeLock: lock,
      readActiveVersion: previousDb.currentVersion,
      createArtifact: () => WebBackupArtifact.create(pending),
    ).create(safety.output);
    await previousDb.close();
    final metadata = WebInstallationStore(pending);
    await metadata.compareAndSet(
      expected: {'activation': null},
      changes: {
        if (boundary == 'switched') 'active': {'instance_id': next, 'epoch': 1},
        'candidate:$next': {
          'instance_id': next,
          'state': 'ready',
          'expected_instance': previous,
          'expected_epoch': 0,
          'expected_generation': 7,
          'generation': 0,
          'content_digest': oldDigest,
        },
        'activation': {
          'candidate_id': next,
          'old_instance': previous,
          'old_epoch': 0,
          'old_generation': 7,
          'new_epoch': 1,
          'state': boundary,
          'failure': null,
          'backup_locator': safety.locator,
          'backup_digest': summary.digest,
        },
      },
    );
    final recovered = await WebDatabaseHost.open(namespace: pending);
    final version = await recovered.readActiveVersion();
    check(
      version.instanceId ==
              (boundary == 'rollback_pending' ? previous : next) &&
          version.activeEpoch == (boundary == 'rollback_pending' ? 2 : 1) &&
          version.generation == (boundary == 'rollback_pending' ? 8 : 1),
      'pending restore not recovered before migration',
    );
    check(
      (await metadata.read('candidate:$next'))?['content_digest'] == oldDigest,
      'candidate was resigned',
    );
    await recovered.close();
    results['old-pending-$boundary'] = 'PASS';
  }
  return results;
}

void main() {
  smoke =
      ((JSString op) => run(op.toDart)
              .then(
                (v) => jsonEncode(v).toJS,
                onError: (Object e, StackTrace st) {
                  errorDetail = '$e\n$st'.toJS;
                  throw e;
                },
              )
              .toJS)
          .toJS;
  ready = true.toJS;
}

class EmptyProbe implements QueryExecutorUser {
  const EmptyProbe();
  @override
  int get schemaVersion => 3;
  @override
  Future<void> beforeOpen(
    QueryExecutor executor,
    OpeningDetails details,
  ) async {}
}
