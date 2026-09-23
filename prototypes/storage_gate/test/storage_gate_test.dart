import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:storage_gate/storage_gate.dart';
import 'package:test/test.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;

Future<GateDatabase> fixture(
  String path,
  String instance, {
  int count = 11,
}) async {
  final db = GateDatabase(path);
  await db.createBusiness(instance);
  await db.transaction(() async {
    for (var i = 0; i < count; i++) {
      await db.customStatement('INSERT INTO records VALUES (?, ?)', [
        i,
        'value-$i',
      ]);
      if (i > 0)
        await db.customStatement('INSERT INTO edges VALUES (?, ?)', [i, i - 1]);
    }
    await db.customStatement('UPDATE identity SET generation = 7');
  });
  return db;
}

Future<int> count(GateDatabase db) async =>
    (await db.customSelect('SELECT count(*) AS n FROM records').getSingle())
        .read<int>('n');

void main() {
  // This fixture deliberately uses independent executors for multiple files.
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late Directory directory;
  late StorageGate gate;
  late GateDatabase db;
  late ActiveVersion version;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('storage-gate-');
    gate = StorageGate(directory.path);
    await gate.initialize();
    db = await fixture('${directory.path}/old.sqlite', 'old-instance');
    await gate.installInitial('${directory.path}/old.sqlite');
    version = await gate.active();
  });
  tearDown(() async {
    await db.close();
    await gate.close();
    await directory.delete(recursive: true);
  });

  test('disk reopen, FK enforcement, and native runtime evidence', () async {
    print(runtimeDescription());
    print(
      'SQLite: ${(await db.customSelect('SELECT sqlite_version() AS v').getSingle()).read<String>('v')}',
    );
    print(
      'journal_mode: ${(await db.customSelect('PRAGMA journal_mode').getSingle()).data}',
    );
    expect(
      (await db.customSelect('PRAGMA foreign_keys').getSingle())
          .data
          .values
          .single,
      1,
    );
    await expectLater(
      db.customStatement('INSERT INTO edges VALUES (0, 999)'),
      throwsA(anything),
    );
    await db.close();
    db = GateDatabase(version.path);
    await db.check();
    expect(await count(db), 11);
    expect(await db.identity(), ('old-instance', 7));
  });

  for (final stage in ['after_record', 'before_commit']) {
    test('business failure $stage rolls back rows and generation', () async {
      await expectLater(
        gate.write(
          version,
          db,
          7,
          20,
          'pending',
          fault: (at) async {
            if (at == stage) throw StateError('Injected $stage');
          },
        ),
        throwsStateError,
      );
      expect(await count(db), 11);
      expect((await db.identity()).$2, 7);
    });
  }
  test('real SQLITE_FULL rolls back business row and generation', () async {
    final pages =
        (await db.customSelect('PRAGMA page_count').getSingle())
                .data
                .values
                .single
            as int;
    await db.customStatement('PRAGMA max_page_count = $pages');
    await expectLater(
      gate.write(version, db, 7, 99, 'x' * (1024 * 1024)),
      throwsA(
        predicate(
          (Object error) =>
              error.toString().contains('database or disk is full'),
        ),
      ),
    );
    expect(await count(db), 11);
    expect((await db.identity()).$2, 7);
    await db.check();
  });
  test(
    'after COMMIT response failure keeps complete durable transaction',
    () async {
      await expectLater(
        gate.write(
          version,
          db,
          7,
          20,
          'committed',
          fault: (at) async {
            if (at == 'after_commit') throw StateError('response lost');
          },
        ),
        throwsStateError,
      );
      await db.close();
      db = GateDatabase(version.path);
      expect(await count(db), 12);
      expect((await db.identity()).$2, 8);
    },
  );
  test(
    'same-process concurrent writers serialize and reject stale generation',
    () async {
      final outcomes = await Future.wait(
        List.generate(8, (i) async {
          try {
            await gate.write(version, db, 7, 20 + i, 'writer');
            return true;
          } on StateError {
            return false;
          }
        }),
      );
      expect(outcomes.where((value) => value).length, 1);
      expect(await count(db), 12);
    },
  );
  test('separate process holds application lock until released', () async {
    final child = await Process.start(Platform.resolvedExecutable, [
      'run',
      'bin/probe_child.dart',
      'lock',
      directory.path,
    ]);
    final lines = StreamIterator(
      child.stdout.transform(utf8.decoder).transform(const LineSplitter()),
    );
    expect(await lines.moveNext().timeout(const Duration(seconds: 30)), true);
    expect(lines.current, 'acquired');
    var entered = false;
    final waiting = gate.lock.run(() async {
      entered = true;
    });
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(entered, false);
    child.stdin.writeln('release');
    await child.stdin.flush();
    await waiting.timeout(const Duration(seconds: 10));
    expect(entered, true);
    expect(await child.exitCode, 0);
    await lines.cancel();
  });

  test(
    'snapshot pages are bounded; all reads remain on frozen generation',
    () async {
      final snapshot = await gate.snapshot(
        '${directory.path}/snapshot.sqlite',
        pageSize: 3,
      );
      expect(snapshot.rows, 11);
      expect(snapshot.maxPage, 3);
      expect(snapshot.generation, 7);
      expect(snapshot.digest, await fileDigest(snapshot.path));
      print('fixture snapshot SHA256: ${snapshot.digest}');
      await gate.write(version, db, 7, 21, 'later');
      final frozen = GateDatabase(snapshot.path);
      try {
        expect(await count(frozen), 11);
        expect((await frozen.identity()).$2, 7);
        expect(
          (await frozen
                  .customSelect('SELECT count(*) AS n FROM edges')
                  .getSingle())
              .read<int>('n'),
          10,
        );
        await frozen.check();
      } finally {
        await frozen.close();
      }
    },
  );
  for (final failPage in [1, 2, 4]) {
    test(
      'snapshot failure on page $failPage never affects active DB',
      () async {
        var page = 0;
        await expectLater(
          gate.snapshot(
            '${directory.path}/partial.sqlite',
            pageSize: 3,
            fault: (stage) async {
              if (stage == 'snapshot_page' && ++page == failPage)
                throw StateError('I/O failure');
            },
          ),
          throwsStateError,
        );
        expect((await gate.active()).matches(version), true);
        expect(await count(db), 11);
        final partial = GateDatabase('${directory.path}/partial.sqlite');
        try {
          expect(await count(partial), 0);
        } finally {
          await partial.close();
        }
      },
    );
  }
  test('snapshot write request waits and does not mix generations', () async {
    Future<void>? edit;
    final frozen = await gate.snapshot(
      '${directory.path}/frozen.sqlite',
      pageSize: 3,
      fault: (stage) async {
        if (stage == 'snapshot_page' && edit == null)
          edit = gate.write(version, db, 7, 99, 'queued');
      },
    );
    await edit;
    expect(frozen.generation, 7);
    expect(frozen.rows, 11);
    expect((await db.identity()).$2, 8);
  });
  test(
    'activation fences old connection, preserves backup, new writer works',
    () async {
      final candidatePath = '${directory.path}/candidate.sqlite';
      final candidate = await fixture(candidatePath, 'new-instance', count: 5);
      await candidate.close();
      final next = await gate.activate(
        version,
        candidatePath,
        await fileDigest(candidatePath),
        expectedGeneration: 7,
      );
      expect(next.epoch, 1);
      await expectLater(
        gate.write(version, db, 7, 98, 'stale'),
        throwsStateError,
      );
      final reopened = GateDatabase(next.path);
      try {
        await gate.write(next, reopened, 7, 99, 'new-write');
        expect(await count(reopened), 6);
      } finally {
        await reopened.close();
      }
      final backupFile = await directory.list().firstWhere(
        (entry) => entry.path.contains('/pre-activate-0-'),
      );
      final backup = GateDatabase(backupFile.path);
      try {
        expect(await count(backup), 11);
      } finally {
        await backup.close();
      }
      expect(await count(db), 11);
    },
  );
  test(
    'stale restore generation is rejected after an intervening edit',
    () async {
      final path = '${directory.path}/candidate.sqlite';
      final candidate = await fixture(path, 'new');
      await candidate.close();
      await gate.write(version, db, 7, 99, 'newer');
      await expectLater(
        gate.activate(
          version,
          path,
          await fileDigest(path),
          expectedGeneration: 7,
        ),
        throwsStateError,
      );
      expect((await gate.active()).matches(version), true);
      expect(await count(db), 12);
      final next = await gate.activate(
        version,
        path,
        await fileDigest(path),
        expectedGeneration: 8,
      );
      expect(next.epoch, 1);
    },
  );
  test(
    'same-instance snapshot connection cannot write as active file',
    () async {
      final snapshot = await gate.snapshot('${directory.path}/copy.sqlite');
      final copy = GateDatabase(snapshot.path);
      try {
        await expectLater(
          gate.write(version, copy, 7, 99, 'wrong-file'),
          throwsStateError,
        );
      } finally {
        await copy.close();
      }
    },
  );
  test(
    'snapshot failure immediately before COMMIT rolls back all copied pages',
    () async {
      final path = '${directory.path}/partial.sqlite';
      await expectLater(
        gate.snapshot(
          path,
          pageSize: 3,
          fault: (stage) async {
            if (stage == 'snapshot_before_commit') throw StateError('full');
          },
        ),
        throwsStateError,
      );
      final partial = GateDatabase(path);
      try {
        expect(await count(partial), 0);
      } finally {
        await partial.close();
      }
      expect(await count(db), 11);
    },
  );
  test('candidate tampering rejected before pointer publication', () async {
    final path = '${directory.path}/candidate.sqlite';
    final candidate = await fixture(path, 'new');
    await candidate.close();
    final digest = await fileDigest(path);
    final modified = GateDatabase(path);
    await modified.customStatement('INSERT INTO records VALUES (99, ?)', [
      'tampered',
    ]);
    await modified.close();
    await expectLater(
      gate.activate(version, path, digest, expectedGeneration: 7),
      throwsStateError,
    );
    expect((await gate.active()).matches(version), true);
  });
  test('reopen failure restores old pointer with a fresh epoch', () async {
    final path = '${directory.path}/candidate.sqlite';
    final candidate = await fixture(path, 'new');
    await candidate.close();
    await expectLater(
      gate.activate(
        version,
        path,
        await fileDigest(path),
        expectedGeneration: 7,
        fault: (stage) async {
          if (stage == 'reopen_check') throw StateError('reopen failed');
        },
      ),
      throwsStateError,
    );
    final current = await gate.active();
    expect(current.path, version.path);
    expect(current.epoch, 2);
    await expectLater(
      gate.write(version, db, 7, 99, 'old-token'),
      throwsStateError,
    );
    await gate.write(current, db, 7, 99, 'fresh-token');
  });
  for (final stage in ['before_pointer', 'inside_pointer', 'after_pointer']) {
    test(
      'process crash $stage reopens a complete old or new database',
      () async {
        final path = '${directory.path}/candidate.sqlite';
        final candidate = await fixture(path, 'new-instance', count: 5);
        await candidate.close();
        final child = await Process.run(Platform.resolvedExecutable, [
          'run',
          'bin/probe_child.dart',
          'crash',
          directory.path,
          path,
          stage,
        ]);
        expect(child.exitCode, 73, reason: '${child.stdout}\n${child.stderr}');
        await gate.close();
        gate = StorageGate(directory.path);
        await gate.initialize();
        final current = await gate.active();
        expect(current.path, stage == 'after_pointer' ? path : version.path);
        final reopened = GateDatabase(current.path);
        try {
          await reopened.check();
          expect(await count(reopened), stage == 'after_pointer' ? 5 : 11);
        } finally {
          await reopened.close();
        }
        if (stage == 'after_pointer') {
          await expectLater(
            gate.write(version, db, 7, 99, 'old'),
            throwsStateError,
          );
        }
      },
    );
  }
}
