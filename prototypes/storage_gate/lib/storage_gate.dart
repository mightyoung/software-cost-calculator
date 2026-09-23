import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';

/// Deliberately isolated structural fixture. No production graph validation.
class GateDatabase extends GeneratedDatabase {
  GateDatabase(this.path) : super(NativeDatabase(File(path)));
  final String path;
  @override
  int get schemaVersion => 1;
  @override
  Iterable<TableInfo<Table, Object?>> get allTables => const [];
  @override
  MigrationStrategy get migration => MigrationStrategy(
    beforeOpen: (_) async {
      await customStatement('PRAGMA foreign_keys = ON');
      await customStatement('PRAGMA busy_timeout = 10000');
      await customStatement('PRAGMA synchronous = FULL');
    },
  );

  Future<void> createBusiness(String instance) async {
    await transaction(() async {
      await customStatement(
        'CREATE TABLE identity (id TEXT PRIMARY KEY, generation INTEGER NOT NULL)',
      );
      await customStatement('INSERT INTO identity VALUES (?, 0)', [instance]);
      await customStatement(
        'CREATE TABLE records (id INTEGER PRIMARY KEY CHECK(id >= 0), value TEXT NOT NULL)',
      );
      await customStatement(
        'CREATE TABLE edges (child INTEGER PRIMARY KEY REFERENCES records(id), parent INTEGER NOT NULL REFERENCES records(id))',
      );
    });
  }

  Future<(String, int)> identity() async {
    final row = await customSelect(
      'SELECT id, generation FROM identity',
    ).getSingle();
    return (row.read<String>('id'), row.read<int>('generation'));
  }

  Future<void> check() async {
    if ((await customSelect(
              'PRAGMA integrity_check',
            ).getSingle()).data.values.single !=
            'ok' ||
        (await customSelect('PRAGMA foreign_key_check').get()).isNotEmpty) {
      throw StateError('Integrity failure');
    }
    await identity();
  }
}

/// Supports one owning isolate per process. Local callers queue; independent
/// processes use an OS advisory file lock. Cross-isolate callers must route to
/// the owner: POSIX locks alone do not serialize same-process descriptors.
class ApplicationLock {
  ApplicationLock(this.path);
  final String path;
  static final Map<String, Future<void>> _tails = {};
  Future<T> run<T>(Future<T> Function() action) async {
    final key = File(path).absolute.path;
    final previous = _tails[key] ?? Future<void>.value();
    final done = Completer<void>();
    _tails[key] = done.future;
    await previous;
    RandomAccessFile? file;
    try {
      file = await File(key).open(mode: FileMode.append);
      await file.lock(FileLock.blockingExclusive);
      return await action();
    } finally {
      if (file != null) await file.close();
      done.complete();
      if (identical(_tails[key], done.future)) _tails.remove(key);
    }
  }
}

class ActiveVersion {
  const ActiveVersion(this.path, this.instance, this.epoch);
  final String path;
  final String instance;
  final int epoch;
  bool matches(ActiveVersion other) =>
      path == other.path && instance == other.instance && epoch == other.epoch;
}

class Snapshot {
  const Snapshot(
    this.path,
    this.instance,
    this.generation,
    this.digest,
    this.rows,
    this.maxPage,
  );
  final String path, instance, digest;
  final int generation, rows, maxPage;
}

typedef Fault = Future<void> Function(String stage);

/// Independent SQLite metadata store supplies an atomic durable active pointer.
/// Every permitted business writer holds the application lock before any SQL
/// transaction, then checks this pointer; raw SQL is only fixture setup.
class StorageGate {
  StorageGate(this.directory)
    : lock = ApplicationLock('$directory/application.lock'),
      metadata = GateDatabase('$directory/metadata.sqlite');
  final String directory;
  final ApplicationLock lock;
  final GateDatabase metadata;

  Future<void> initialize() => lock.run(() async {
    await metadata.customStatement(
      'CREATE TABLE IF NOT EXISTS active (singleton INTEGER PRIMARY KEY CHECK(singleton=1), path TEXT NOT NULL, instance TEXT NOT NULL, epoch INTEGER NOT NULL)',
    );
    if ((await metadata.customSelect('SELECT singleton FROM active').get())
        .isNotEmpty) {
      final current = await active();
      final db = GateDatabase(current.path);
      try {
        await db.check();
        if ((await db.identity()).$1 != current.instance)
          throw StateError('Active identity mismatch');
      } finally {
        await db.close();
      }
    }
  });

  Future<ActiveVersion> active() async {
    final row = await metadata
        .customSelect(
          'SELECT path, instance, epoch FROM active WHERE singleton=1',
        )
        .getSingle();
    return ActiveVersion(
      row.read<String>('path'),
      row.read<String>('instance'),
      row.read<int>('epoch'),
    );
  }

  Future<void> installInitial(String path) => lock.run(() async {
    final db = GateDatabase(path);
    try {
      await db.check();
      final identity = await db.identity();
      await metadata.customStatement('INSERT INTO active VALUES (1, ?, ?, 0)', [
        path,
        identity.$1,
      ]);
    } finally {
      await db.close();
    }
  });

  Future<void> _fence(ActiveVersion expected) async {
    if (!expected.matches(await active()))
      throw StateError('Stale active epoch');
  }

  Future<void> write(
    ActiveVersion expected,
    GateDatabase connection,
    int expectedGeneration,
    int id,
    String value, {
    Fault? fault,
  }) => lock.run(() async {
    await _fence(expected);
    await connection.transaction(() async {
      await _fence(expected);
      final current = await connection.identity();
      if (File(connection.path).absolute.path !=
              File(expected.path).absolute.path ||
          current.$1 != expected.instance ||
          current.$2 != expectedGeneration) {
        throw StateError('Stale generation or wrong connection');
      }
      await connection.customStatement('INSERT INTO records VALUES (?, ?)', [
        id,
        value,
      ]);
      await fault?.call('after_record');
      await connection.customStatement(
        'UPDATE identity SET generation = generation + 1',
      );
      await fault?.call('before_commit');
    });
    await fault?.call('after_commit');
  });

  Future<Snapshot> snapshot(
    String output, {
    int pageSize = 128,
    Fault? fault,
  }) => lock.run(
    () async => _snapshotHeld(await active(), output, pageSize, fault),
  );

  /// Internal held-lock path: activation backup must not reacquire the lock.
  Future<Snapshot> _snapshotHeld(
    ActiveVersion expected,
    String output,
    int pageSize,
    Fault? fault,
  ) async {
    if (pageSize < 1 || await File(output).exists())
      throw ArgumentError('Invalid snapshot target/page size');
    await _fence(expected);
    final source = GateDatabase(expected.path);
    final target = GateDatabase(output);
    var rows = 0, maxPage = 0;
    late (String, int) version;
    try {
      await source.customStatement('BEGIN DEFERRED TRANSACTION');
      try {
        version = await source.identity(); // Bind the actual read snapshot.
        if (version.$1 != expected.instance)
          throw StateError('Snapshot instance mismatch');
        await target.createBusiness(version.$1);
        await target.transaction(() async {
          var cursor = -1;
          while (true) {
            final page = await source
                .customSelect(
                  'SELECT id, value FROM records WHERE id > ? ORDER BY id LIMIT ?',
                  variables: [
                    Variable.withInt(cursor),
                    Variable.withInt(pageSize),
                  ],
                )
                .get();
            if (page.isEmpty) break;
            if (page.length > maxPage) maxPage = page.length;
            for (final row in page) {
              cursor = row.read<int>('id');
              await target.customStatement(
                'INSERT INTO records VALUES (?, ?)',
                [cursor, row.read<String>('value')],
              );
              rows++;
            }
            await fault?.call('snapshot_page');
          }
          cursor = -1;
          while (true) {
            final page = await source
                .customSelect(
                  'SELECT child, parent FROM edges WHERE child > ? ORDER BY child LIMIT ?',
                  variables: [
                    Variable.withInt(cursor),
                    Variable.withInt(pageSize),
                  ],
                )
                .get();
            if (page.isEmpty) break;
            for (final row in page) {
              cursor = row.read<int>('child');
              await target.customStatement('INSERT INTO edges VALUES (?, ?)', [
                cursor,
                row.read<int>('parent'),
              ]);
            }
          }
          await target.customStatement('UPDATE identity SET generation = ?', [
            version.$2,
          ]);
          await fault?.call('snapshot_before_commit');
        });
        await source.customStatement('COMMIT');
      } catch (_) {
        await source.customStatement('ROLLBACK');
        rethrow;
      }
      await _fence(expected);
      await target.check();
      final actual = await target.identity();
      if (actual != version) throw StateError('Snapshot identity mismatch');
    } finally {
      await source.close();
      await target.close();
    }
    final digest = (await sha256.bind(File(output).openRead()).first)
        .toString();
    return Snapshot(output, version.$1, version.$2, digest, rows, maxPage);
  }

  /// Candidate already committed; metadata transaction never spans business DBs.
  /// Reopen failure rolls pointer back while writes remain locked. Once this
  /// method returns, no automatic rollback is possible.
  Future<ActiveVersion> activate(
    ActiveVersion expected,
    String candidatePath,
    String expectedDigest, {
    required int expectedGeneration,
    Fault? fault,
  }) => lock.run(() async {
    await _fence(expected);
    final digest = (await sha256.bind(File(candidatePath).openRead()).first)
        .toString();
    if (digest != expectedDigest) throw StateError('Candidate digest mismatch');
    final candidate = GateDatabase(candidatePath);
    late (String, int) identity;
    try {
      await candidate.check();
      identity = await candidate.identity();
    } finally {
      await candidate.close();
    }
    final backup = await _snapshotHeld(
      expected,
      '$directory/pre-activate-${expected.epoch}-${DateTime.now().microsecondsSinceEpoch}.sqlite',
      128,
      null,
    );
    if (backup.generation != expectedGeneration)
      throw StateError('Stale restore generation');
    await fault?.call('before_pointer');
    final next = ActiveVersion(candidatePath, identity.$1, expected.epoch + 1);
    await metadata.transaction(() async {
      await _fence(expected);
      await metadata.customStatement(
        'UPDATE active SET path=?, instance=?, epoch=? WHERE singleton=1',
        [next.path, next.instance, next.epoch],
      );
      await fault?.call('inside_pointer');
    });
    try {
      await fault?.call('after_pointer');
      final reopened = GateDatabase(next.path);
      try {
        await reopened.check();
        await fault?.call('reopen_check');
      } finally {
        await reopened.close();
      }
    } catch (_) {
      // Advance epoch even on rollback: both old and failed-new tokens expire.
      await metadata.transaction(() async {
        await metadata.customStatement(
          'UPDATE active SET path=?, instance=?, epoch=? WHERE singleton=1',
          [expected.path, expected.instance, next.epoch + 1],
        );
      });
      rethrow;
    }
    return next;
  });
  Future<void> close() => metadata.close();
}

Future<String> fileDigest(String path) async =>
    (await sha256.bind(File(path).openRead()).first).toString();
String runtimeDescription() => jsonEncode({
  'os': Platform.operatingSystem,
  'osVersion': Platform.operatingSystemVersion,
  'dart': Platform.version,
});
