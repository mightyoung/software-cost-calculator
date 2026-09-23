import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:supplier_core/supplier_core.dart';
import 'package:test/test.dart';

void main() {
  late SupplierDatabase database;
  late _TransactionProbe probe;
  Future<void> open({bool workaround = true}) async {
    probe = _TransactionProbe();
    database = SupplierDatabase(
      NativeDatabase.memory().interceptWith(probe),
      instanceId: 'nested-test',
      useDrift235WebLockSavepoints: workaround,
    );
    await database.currentVersion();
    probe.starts = 0;
    probe.commits = 0;
  }

  Future<void> put(String key) => database.customStatement(
    'INSERT INTO local_settings VALUES(?,?)',
    [key, '1'],
  );
  Future<List<String>> keys() async => (await database.rows(
    'SELECT key FROM local_settings ORDER BY key',
  )).map((row) => row.read<String>('key')).toList();
  tearDown(() => database.close());

  test(
    'enabled compatibility uses one executor for multiple nested commits',
    () async {
      await open();
      await database.transaction(() async {
        await database.transaction(() => put('a'), requireNew: true);
        await database.transaction(() => put('b'));
      });
      expect(await keys(), ['a', 'b']);
      expect(probe.starts, 1);
      expect(probe.commits, 1);
    },
  );
  test('default native path retains Drift nested executors', () async {
    await open(workaround: false);
    await database.transaction(() => database.transaction(() => put('a')));
    expect(await keys(), ['a']);
    expect(probe.starts, 2);
    expect(probe.commits, 2);
  });
  test(
    'caught inner failure rolls back inner writes and outer can continue',
    () async {
      await open();
      final error = StateError('inner');
      await database.transaction(() async {
        await put('before');
        try {
          await database.transaction(() async {
            await put('inner');
            throw error;
          });
        } catch (actual) {
          expect(actual, same(error));
        }
        await put('after');
      });
      expect(await keys(), ['after', 'before']);
    },
  );
  test('outer failure rolls back successful nested writes', () async {
    await open();
    await expectLater(
      database.transaction(() async {
        await put('outer');
        await database.transaction(() => put('inner'));
        throw StateError('outer');
      }),
      throwsStateError,
    );
    expect(await keys(), isEmpty);
  });
  test(
    'recursive nesting and concurrent sibling units keep distinct boundaries',
    () async {
      await open();
      final order = <String>[];
      await database.transaction(() async {
        await Future.wait([
          database.transaction(() async {
            order.add('a-start');
            await put('a');
            await database.transaction(() => put('deep'));
            await Future<void>.delayed(Duration.zero);
            order.add('a-end');
          }),
          database.transaction(() async {
            order.add('b-start');
            await put('b');
            order.add('b-end');
          }),
        ]);
      });
      expect(order, ['a-start', 'a-end', 'b-start', 'b-end']);
      expect(await keys(), ['a', 'b', 'deep']);
      expect(probe.starts, 1);
    },
  );
  test(
    'cleanup failure preserves primary and forces outer rollback even if caught',
    () async {
      await open();
      probe.failRollback = true;
      final primary = StateError('primary');
      Object? observed;
      await expectLater(
        database.transaction(() async {
          await put('outer');
          try {
            await database.transaction(() async {
              await put('inner');
              throw primary;
            });
          } catch (error) {
            observed = error;
          }
          await put('after');
        }),
        throwsA(
          isA<DomainFailure>().having(
            (error) => error.code,
            'code',
            'nested_transaction_cleanup_failed',
          ),
        ),
      );
      final cause = (observed! as DomainFailure).cause as dynamic;
      expect(cause.primary, same(primary));
      expect(cause.cleanup.length, 1);
      expect(await keys(), isEmpty);
    },
  );
}

class _TransactionProbe extends QueryInterceptor {
  int starts = 0, commits = 0;
  bool failRollback = false;
  @override
  TransactionExecutor beginTransaction(QueryExecutor parent) {
    starts++;
    return super.beginTransaction(parent);
  }

  @override
  Future<void> commitTransaction(TransactionExecutor inner) {
    commits++;
    return super.commitTransaction(inner);
  }

  @override
  Future<void> runCustom(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    if (failRollback && statement.startsWith('ROLLBACK TO SAVEPOINT')) {
      failRollback = false;
      throw StateError('injected cleanup failure');
    }
    return super.runCustom(executor, statement, args);
  }
}
