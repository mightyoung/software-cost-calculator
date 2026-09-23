import 'dart:js_interop';

import 'package:drift/wasm.dart';
import 'package:drift/drift.dart';
import 'package:supplier_core/supplier_core.dart';

import 'web_capacity.dart';

import 'web_file_ports.dart';
import 'web_installation_store.dart';

part 'web_restore.dart';
part 'web_storage_migration.dart';

@JS('supplierPlatform.databaseExists')
external JSPromise<JSBoolean> _databaseExists(JSString name);
@JS('supplierPlatform.hasDatabasePrefix')
external JSPromise<JSBoolean> _hasDatabasePrefix(JSString prefix);

/// One installation per origin/namespace. Opening holds the same Web Lock as
/// every business write; metadata is committed independently in IndexedDB.
final class WebDatabaseHost {
  WebDatabaseHost._(this.namespace, this.readCapacity)
    : lock = WebApplicationWriteLock(namespace),
      installation = WebInstallationStore(namespace);
  final String namespace;
  final CapacityReader readCapacity;
  RestoreSpaceEstimate? lastRestoreEstimate;
  final WebApplicationWriteLock lock;
  final WebInstallationStore installation;
  late final SupplierDatabase database;
  late final String deviceId;
  late final DatabaseVersion _openedVersion;
  bool _closed = false;
  // Drift's public probe has no dispose. One opener owns the worker set for
  // this page lifetime; existence checks remain fresh OPFS reads on every open.
  static Future<WasmProbeResult>? _sharedProbe;
  String _name(String id) => 'supplier-$namespace-db-$id';

  static Future<WebDatabaseHost> open({
    String namespace = 'inquiry-v2',
    CapacityReader readCapacity = readWebCapacity,
  }) async {
    final host = WebDatabaseHost._(namespace, readCapacity);
    SupplierDatabase? opened;
    try {
      await withApplicationWriteContext(host.lock, (context) async {
        var identity = await host.installation.read('installation');
        var active = await host.installation.read('active');
        var bootstrap = await host.installation.read('bootstrap');
        if (identity == null && (active != null || bootstrap != null)) {
          throw const DomainFailure(
            'orphan_database',
            'Installation identity is missing while database metadata remains',
          );
        }
        if (identity == null || (active == null && bootstrap == null)) {
          if ((await _hasDatabasePrefix(
            'supplier-$namespace-db-'.toJS,
          ).toDart).toDart) {
            throw const DomainFailure(
              'orphan_database',
              'Existing data requires explicit recovery',
            );
          }
        }
        if (identity == null) {
          identity = {'schema': 2, 'device_id': newWebInstanceId()};
          await host.installation.compareAndSet(
            expected: {'installation': null},
            changes: {'installation': identity},
          );
        }
        if (identity['schema'] != 2) {
          throw const DomainFailure(
            'installation_schema',
            'Unsupported installation schema',
          );
        }
        host.deviceId = requireUuid(identity['device_id'], 'device_id');
        await host._recoverActivation();
        active = await host.installation.read('active');
        if (active == null) {
          if (bootstrap == null) {
            bootstrap = {'instance_id': newWebInstanceId()};
            await host.installation.compareAndSet(
              expected: {'active': null, 'bootstrap': null},
              changes: {'bootstrap': bootstrap},
            );
          }
          final id = requireUuid(bootstrap['instance_id'], 'instance_id');
          opened = await host.openDatabase(id, 0, create: true);
          active = {'instance_id': id, 'epoch': 0};
          await host.installation.compareAndSet(
            expected: {'active': null, 'bootstrap': bootstrap},
            changes: {'active': active, 'bootstrap': null},
          );
        } else {
          opened = await host.openDatabase(
            requireUuid(active['instance_id'], 'instance_id'),
            requireSafeInteger(active['epoch'], 'epoch', min: 0),
          );
        }
        if (opened!.storageVersion == 2) {
          await host._migrateActiveStorage(opened!, context);
          await opened!.close();
          opened = null;
          opened = await host.openDatabase(
            requireUuid(active['instance_id'], 'instance_id'),
            requireSafeInteger(active['epoch'], 'epoch', min: 0),
          );
        }
        host.database = opened!;
        host._openedVersion = await opened!.currentVersion();
      });
      return host;
    } catch (primary, stack) {
      try {
        await opened?.close();
      } catch (cleanup, cleanupStack) {
        throw DomainFailure(
          'web_open_cleanup',
          'Database opening and cleanup failed',
          cause: (
            primary: primary,
            stack: stack,
            cleanup: cleanup,
            cleanupStack: cleanupStack,
          ),
        );
      }
      Error.throwWithStackTrace(primary, stack);
    }
  }

  Future<WasmProbeResult> _probe() => _sharedProbe ??= WasmDatabase.probe(
    sqlite3Uri: Uri.base.resolve('sqlite3.wasm'),
    driftWorkerUri: Uri.base.resolve('drift_worker.js'),
  );

  /// Caller owns the installation lock, or a distinct isolated candidate lock.
  Future<SupplierDatabase> openDatabase(
    String id,
    int epoch, {
    bool create = false,
  }) => _openDatabase(id, epoch, create: create);

  Future<SupplierDatabase> _openDatabase(
    String id,
    int? epoch, {
    bool create = false,
  }) async {
    requireUuid(id, 'instance_id');
    final name = _name(id);
    final probe = await _probe();
    if (!create && !(await _databaseExists(name.toJS).toDart).toDart) {
      throw const DomainFailure(
        'missing_active_database',
        'Persistent database is missing',
      );
    }
    final implementations =
        probe.availableStorages
            .where((value) => value.storageApi == WebStorageApi.opfs)
            .toList()
          ..sort((a, b) => a.index.compareTo(b.index));
    if (implementations.isEmpty) {
      throw const DomainFailure(
        'persistent_storage_unavailable',
        'Reliable OPFS storage is unavailable',
      );
    }
    final implementation = implementations.first;
    final executor = await probe.open(
      implementation,
      name,
      enableMigrations: false,
    );
    late int storageVersion;
    var initializeEmpty = false;
    try {
      await executor.ensureOpen(const _PhysicalVersionProbe());
      storageVersion =
          (await executor.runSelect(
                'PRAGMA user_version',
                const [],
              )).single['user_version']
              as int;
      if (storageVersion == 0 && create) {
        final tables = await executor.runSelect(
          "SELECT name FROM sqlite_master WHERE name NOT LIKE 'sqlite_%'",
          const [],
        );
        if (tables.isNotEmpty) {
          throw const DomainFailure(
            'database_schema',
            'Unversioned database is not empty',
          );
        }
        // Only a new or interrupted, entirely empty bootstrap may initialize.
        initializeEmpty = true;
        storageVersion = 3;
      } else if (![2, 3].contains(storageVersion)) {
        throw const DomainFailure(
          'database_schema',
          'Unsupported physical storage version',
        );
      }
    } catch (primary, stack) {
      try {
        await executor.close();
      } catch (cleanup) {
        throw DomainFailure(
          'web_open_cleanup',
          'Physical version probe and cleanup failed',
          cause: (primary: primary, stack: stack, cleanup: cleanup),
        );
      }
      Error.throwWithStackTrace(primary, stack);
    }
    final db = SupplierDatabase(
      executor,
      instanceId: id,
      activeEpoch: epoch ?? 0,
      storageVersion: storageVersion,
      useDrift235WebLockSavepoints:
          implementation == WasmStorageImplementation.opfsLocks,
    );
    try {
      if (initializeEmpty) {
        // The OPFS shared worker can retain the already-open executor after
        // close/reopen. Explicitly initialize only the proven empty bootstrap;
        // onCreate writes DDL and user_version in the same core transaction.
        await db.migration.onCreate(Migrator(db));
      }
      await verifyDatabase(db, id, epoch);
      return db;
    } catch (primary, stack) {
      try {
        await db.close();
      } catch (cleanup, cleanupStack) {
        throw DomainFailure(
          'web_open_cleanup',
          'Database validation and cleanup failed',
          cause: (
            primary: primary,
            stack: stack,
            cleanup: cleanup,
            cleanupStack: cleanupStack,
          ),
        );
      }
      Error.throwWithStackTrace(primary, stack);
    }
  }

  static Future<void> verifyDatabase(
    SupplierDatabase db,
    String id,
    int? epoch,
  ) async {
    await db.customStatement('PRAGMA foreign_keys=ON');
    await db.customStatement('PRAGMA synchronous=FULL');
    final schema = (await db.rows('PRAGMA user_version')).single
        .read<int>('user_version');
    final foreignKeys = (await db.rows('PRAGMA foreign_keys')).single
        .read<int>('foreign_keys');
    if (![2, 3].contains(schema) ||
        schema != db.storageVersion ||
        foreignKeys != 1) {
      throw DomainFailure(
        'database_schema',
        'Unsupported physical version $schema (expected ${db.storageVersion}) or foreign keys $foreignKeys',
      );
    }
    final tables = (await db.rows(
      "SELECT name FROM sqlite_master WHERE type='table'",
    )).map((row) => row.read<String>('name')).toSet();
    if (!tables.containsAll(
      SupplierDatabase.requiredTableNamesForVersion(schema),
    )) {
      throw const DomainFailure(
        'database_schema',
        'Required database table is missing',
      );
    }
    final version = await db.currentVersion();
    if (version.instanceId != id ||
        (epoch != null && version.activeEpoch != epoch)) {
      throw const DomainFailure(
        'database_identity_mismatch',
        'Database and active pointer differ',
      );
    }
    final integrity = await db.rows('PRAGMA integrity_check');
    if (integrity.length != 1 ||
        integrity.single.data.values.single != 'ok' ||
        (await db.rows('PRAGMA foreign_key_check')).isNotEmpty) {
      throw const DomainFailure(
        'database_integrity',
        'Database integrity check failed',
      );
    }
  }

  Future<DatabaseVersion> readActiveVersion() async {
    if (_closed) throw StateError('Database host is closed');
    final journal = await installation.read('activation');
    if (journal != null &&
        !['accepted', 'rolled_back'].contains(journal['state'])) {
      throw const DomainFailure('restore_pending', 'Recovery is incomplete');
    }
    final active = await installation.read('active');
    final physical = (await database.rows('PRAGMA user_version')).single
        .read<int>('user_version');
    if (physical != database.storageVersion) {
      throw const DomainFailure(
        'stale_storage_connection',
        'Reopen after physical storage migration',
      );
    }
    final current = await database.currentVersion();
    if (active?['instance_id'] != _openedVersion.instanceId ||
        active?['epoch'] != _openedVersion.activeEpoch ||
        current.instanceId != _openedVersion.instanceId ||
        current.activeEpoch != _openedVersion.activeEpoch) {
      throw const DomainFailure(
        'stale_active_database',
        'This connection belongs to an earlier activation',
      );
    }
    return current;
  }

  CommitCoordinator get coordinator => CommitCoordinator(
    database: database,
    writeLock: lock,
    readActiveVersion: readActiveVersion,
  );
  RecordService get records => RecordService(coordinator, deviceId: deviceId);
  Future<void> close() => lock.run(() async {
    if (_closed) return;
    _closed = true;
    await database.close();
  });
}

/// Read physical version without allowing Drift to initialize or upgrade it.
final class _PhysicalVersionProbe implements QueryExecutorUser {
  const _PhysicalVersionProbe();
  @override
  int get schemaVersion => 3;
  @override
  Future<void> beforeOpen(
    QueryExecutor executor,
    OpeningDetails details,
  ) async {}
}
