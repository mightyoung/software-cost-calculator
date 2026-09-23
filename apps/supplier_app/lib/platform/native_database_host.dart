import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:supplier_core/supplier_core.dart';

import 'native_file_ports.dart';
import 'native_backup_artifact.dart';

part 'native_restore.dart';
part 'native_storage_migration.dart';

/// Installation metadata is independent of business data and never restored
/// from an exchange or backup file. All access that changes it requires lock.
final class NativeDatabaseHost {
  NativeDatabaseHost._(this.directory, this.readCapacity)
    : lock = NativeApplicationWriteLock(
        File('${directory.path}/application.lock'),
      ),
      _metadata = _InstallationDatabase(
        File('${directory.path}/installation.sqlite'),
      );
  final Directory directory;
  final CapacityReader readCapacity;

  RestoreSpaceEstimate? lastRestoreEstimate;
  final NativeApplicationWriteLock lock;
  final _InstallationDatabase _metadata;
  late final SupplierDatabase database;
  late final String deviceId;
  late final DatabaseVersion _openedVersion;
  bool _closed = false;

  static Future<NativeDatabaseHost> open(
    Directory directory, {
    CapacityReader readCapacity = CapacitySample.nativeUnknown,
  }) async {
    await directory.create(recursive: true);
    final host = NativeDatabaseHost._(directory, readCapacity);
    SupplierDatabase? candidate;
    try {
      await withApplicationWriteContext(host.lock, (context) async {
        await host._metadata.ready();
        host.deviceId =
            (await host._metadata
                    .customSelect(
                      'SELECT device_id FROM installation WHERE singleton=1',
                    )
                    .getSingle())
                .read<String>('device_id');
        requireUuid(host.deviceId, 'device_id');
        await host._recoverActivation();
        var pointer = await host._readPointer();
        if (pointer == null) {
          var pending = await host._metadata
              .customSelect('SELECT instance_id FROM bootstrap')
              .get();
          if (pending.isEmpty) {
            // Missing metadata must not silently hide pre-existing business files.
            await for (final entry in directory.list()) {
              if (entry.path.endsWith('.sqlite') &&
                  entry.path != '${directory.path}/installation.sqlite') {
                throw const DomainFailure(
                  'orphan_database',
                  'Existing database requires explicit recovery',
                );
              }
            }
            await host._metadata.customStatement(
              'INSERT INTO bootstrap VALUES(1,?)',
              [_uuid()],
            );
            pending = await host._metadata
                .customSelect('SELECT instance_id FROM bootstrap')
                .get();
          }
          final instance = pending.single.read<String>('instance_id');
          final file = host._businessFile(instance);
          final bootstrapVersion =
              await _ExistingDatabaseProbe.bootstrapVersion(file, instance);
          candidate = SupplierDatabase(
            NativeDatabase(file, enableMigrations: bootstrapVersion == 0),
            instanceId: instance,
            storageVersion: bootstrapVersion == 0
                ? currentStorageSchemaVersion
                : bootstrapVersion,
          );
          await _check(candidate!, instance, 0);
          await host._metadata.transaction(() async {
            await host._metadata.customStatement(
              'INSERT INTO active VALUES(1,?,0)',
              [instance],
            );
            await host._metadata.customStatement('DELETE FROM bootstrap');
          });
          pointer = (instanceId: instance, epoch: 0);
        } else {
          final file = host._businessFile(pointer.instanceId);
          if (!await file.exists() || await file.length() == 0) {
            throw const DomainFailure(
              'missing_active_database',
              'Active database file is missing',
            );
          }
          final storageVersion = await _ExistingDatabaseProbe.verify(
            file,
            pointer.instanceId,
            pointer.epoch,
          );
          candidate = SupplierDatabase(
            NativeDatabase(file, enableMigrations: false),
            instanceId: pointer.instanceId,
            activeEpoch: pointer.epoch,
            storageVersion: storageVersion,
          );
          await _check(candidate!, pointer.instanceId, pointer.epoch);
        }
        if (candidate!.schemaVersion == 2) {
          await host._migrateActiveStorage(candidate!, context);
          await candidate!.close();
          candidate = SupplierDatabase(
            NativeDatabase(
              host._businessFile(pointer.instanceId),
              enableMigrations: false,
            ),
            instanceId: pointer.instanceId,
            activeEpoch: pointer.epoch,
          );
          await _check(candidate!, pointer.instanceId, pointer.epoch);
        }
        host.database = candidate!;
        host._openedVersion = await candidate!.currentVersion();
      });
      return host;
    } catch (primary, stack) {
      final cleanup = <Object>[];
      try {
        await candidate?.close();
      } catch (error) {
        cleanup.add(error);
      }
      try {
        await host._metadata.close();
      } catch (error) {
        cleanup.add(error);
      }
      if (cleanup.isNotEmpty) {
        throw FileOperationFailure(primary, stack, cleanup);
      }
      Error.throwWithStackTrace(primary, stack);
    }
  }

  File _businessFile(String instance) {
    requireUuid(instance, 'instance_id');
    return File('${directory.path}/db-$instance.sqlite');
  }

  Future<({String instanceId, int epoch})?> _readPointer() async {
    final rows = await _metadata
        .customSelect('SELECT instance_id,epoch FROM active WHERE singleton=1')
        .get();
    if (rows.isEmpty) return null;
    return (
      instanceId: rows.single.read<String>('instance_id'),
      epoch: rows.single.read<int>('epoch'),
    );
  }

  /// Called by the coordinator only after it acquires [lock]. Metadata queries
  /// finish before a business SQL transaction starts, avoiding cross-DB zones.
  Future<DatabaseVersion> readActiveVersion() async {
    if (_closed) throw StateError('Database host is closed');
    final pending = await _metadata
        .customSelect(
          "SELECT 1 FROM restore_activation WHERE state IN ('armed','switched','rollback_pending') LIMIT 1",
        )
        .get();
    if (pending.isNotEmpty) {
      throw const DomainFailure(
        'restore_pending',
        'Recovery must finish before writing',
      );
    }
    final pointer = await _readPointer();
    if (pointer == null) {
      throw const DomainFailure(
        'missing_active_database',
        'No active database',
      );
    }
    final physicalVersion = (await database.rows('PRAGMA user_version')).single
        .read<int>('user_version');
    if (physicalVersion != database.schemaVersion) {
      throw const DomainFailure(
        'stale_active_database',
        'Database storage changed; reopen this connection',
      );
    }
    final version = await database.currentVersion();
    if (pointer.instanceId != _openedVersion.instanceId ||
        pointer.epoch != _openedVersion.activeEpoch ||
        version.instanceId != _openedVersion.instanceId ||
        version.activeEpoch != _openedVersion.activeEpoch) {
      throw const DomainFailure(
        'stale_active_database',
        'This connection belongs to an earlier activation',
      );
    }
    return version;
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
    Object? primary;
    StackTrace? primaryStack;
    try {
      await database.close();
    } catch (error, stack) {
      primary = error;
      primaryStack = stack;
    }
    try {
      await _metadata.close();
    } catch (cleanup) {
      if (primary != null) {
        throw FileOperationFailure(primary, primaryStack!, [cleanup]);
      }
      rethrow;
    }
    if (primary != null) Error.throwWithStackTrace(primary, primaryStack!);
  });

  static Future<void> _check(
    SupplierDatabase db,
    String instance,
    int epoch,
  ) async {
    final storage = (await db.rows('PRAGMA user_version')).single
        .read<int>('user_version');
    if (storage != db.schemaVersion || ![2, 3].contains(storage)) {
      throw const DomainFailure(
        'database_schema',
        'Unsupported physical storage version',
      );
    }
    final version = await db.currentVersion();
    if (version.instanceId != instance || version.activeEpoch != epoch) {
      throw const DomainFailure(
        'database_identity_mismatch',
        'Active pointer and database differ',
      );
    }
    await db.customStatement('PRAGMA journal_mode=DELETE');
    await db.customStatement('PRAGMA synchronous=FULL');
    await db.customStatement('PRAGMA busy_timeout=10000');
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
}

/// No migration or onCreate is allowed when the pointer already names a file.
/// Checking file length alone would let a nonempty, empty SQLite file be silently
/// initialized by the normal business database constructor.
class _ExistingDatabaseProbe extends GeneratedDatabase {
  _ExistingDatabaseProbe(File file)
    : super(NativeDatabase(file, enableMigrations: false));
  @override
  int get schemaVersion => 2;
  @override
  Iterable<TableInfo<Table, Object?>> get allTables => const [];
  // A durable bootstrap record owns this path. Only a truly empty schema may
  // resume creation; any existing application schema must pass normal probing.
  static Future<int> bootstrapVersion(File file, String instance) async {
    if (!await file.exists() || await file.length() == 0) return 0;
    final probe = _ExistingDatabaseProbe(file);
    var empty = false;
    try {
      await probe.customStatement('PRAGMA query_only=ON');
      final version =
          (await probe.customSelect('PRAGMA user_version').getSingle())
              .read<int>('user_version');
      if (version == 0) {
        final objects = await probe
            .customSelect(
              "SELECT name FROM sqlite_master WHERE name NOT LIKE 'sqlite_%'",
            )
            .get();
        if (objects.isNotEmpty) {
          throw const DomainFailure(
            'database_schema',
            'Incomplete bootstrap contains an unknown schema',
          );
        }
        empty = true;
      }
    } finally {
      await probe.close();
    }
    return empty ? 0 : verify(file, instance, 0);
  }

  static Future<int> verify(File file, String instance, int epoch) async {
    final probe = _ExistingDatabaseProbe(file);
    Object? primary;
    StackTrace? primaryStack;
    try {
      await probe.customStatement('PRAGMA query_only=ON');
      final version = await probe
          .customSelect('PRAGMA user_version')
          .getSingle();
      final storageVersion = version.read<int>('user_version');
      if (![2, 3].contains(storageVersion)) {
        throw const DomainFailure(
          'database_schema',
          'Active file has no supported business schema',
        );
      }
      final meta = await probe
          .customSelect(
            'SELECT instance_id,active_epoch,schema_version FROM database_meta WHERE singleton=1',
          )
          .getSingle();
      if (meta.read<String>('instance_id') != instance ||
          meta.read<int>('active_epoch') != epoch ||
          meta.read<int>('schema_version') != 2) {
        throw const DomainFailure(
          'database_identity_mismatch',
          'Active pointer and database differ',
        );
      }
      final existing =
          (await probe
                  .customSelect(
                    "SELECT name FROM sqlite_master WHERE type='table'",
                  )
                  .get())
              .map((row) => row.read<String>('name'))
              .toSet();
      // This set is bounded by application schema, not by business row count.
      for (final table in SupplierDatabase.requiredTableNamesForVersion(
        storageVersion,
      )) {
        if (!existing.contains(table)) {
          throw const DomainFailure(
            'database_schema',
            'Active database is missing a required table',
          );
        }
      }
      return storageVersion;
    } catch (error, stack) {
      primary = error;
      primaryStack = stack;
      rethrow;
    } finally {
      try {
        await probe.close();
      } catch (cleanup) {
        if (primary != null) {
          throw FileOperationFailure(primary, primaryStack!, [cleanup]);
        }
        rethrow;
      }
    }
  }
}

class _InstallationDatabase extends GeneratedDatabase {
  _InstallationDatabase(File file) : super(NativeDatabase(file));
  @override
  int get schemaVersion => 2;
  @override
  Iterable<TableInfo<Table, Object?>> get allTables => const [];
  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (_) => transaction(() async {
      await customStatement(
        'CREATE TABLE installation(singleton INTEGER PRIMARY KEY CHECK(singleton=1),device_id TEXT NOT NULL)',
      );
      await customStatement(
        'CREATE TABLE active(singleton INTEGER PRIMARY KEY CHECK(singleton=1),instance_id TEXT NOT NULL,epoch INTEGER NOT NULL CHECK(epoch>=0))',
      );
      await customStatement(
        'CREATE TABLE bootstrap(singleton INTEGER PRIMARY KEY CHECK(singleton=1),instance_id TEXT NOT NULL)',
      );
      await customStatement('INSERT INTO installation VALUES(1,?)', [_uuid()]);
      await _restoreTables();
    }),
    onUpgrade: (_, from, to) async {
      if (from == 1 && to == 2) {
        await transaction(_restoreTables);
      } else {
        throw StateError(
          'Unsupported installation metadata migration $from->$to',
        );
      }
    },
    beforeOpen: (_) async {
      await customStatement('PRAGMA journal_mode=DELETE');
      await customStatement('PRAGMA synchronous=FULL');
      await customStatement('PRAGMA busy_timeout=10000');
    },
  );
  Future<void> _restoreTables() async {
    await customStatement(
      '''CREATE TABLE restore_candidate(
      instance_id TEXT PRIMARY KEY,state TEXT NOT NULL CHECK(state IN ('building','ready','used','failed')),
      expected_instance TEXT NOT NULL,expected_epoch INTEGER NOT NULL,expected_generation INTEGER NOT NULL,
      source_digest TEXT,file_digest TEXT,content_digest TEXT,generation INTEGER)''',
    );
    await customStatement('''CREATE TABLE restore_activation(
      singleton INTEGER PRIMARY KEY CHECK(singleton=1),candidate_id TEXT NOT NULL,
      old_instance TEXT NOT NULL,old_epoch INTEGER NOT NULL,old_generation INTEGER NOT NULL,
      new_epoch INTEGER NOT NULL,backup_path TEXT NOT NULL,
      state TEXT NOT NULL CHECK(state IN ('armed','switched','accepted','rollback_pending','rolled_back')),
      failure TEXT)''');
  }

  Future<void> ready() async {
    final result = await customSelect('PRAGMA integrity_check').getSingle();
    if (result.data.values.single != 'ok') {
      throw StateError('Installation metadata is corrupt');
    }
  }
}

String _uuid() {
  final random = Random.secure();
  final bytes = List.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 15) | 64;
  bytes[8] = (bytes[8] & 63) | 128;
  final hex = bytes.map((v) => v.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}
