import 'dart:async';
import 'dart:io';
import 'package:drift/native.dart';
import 'package:supplier_core/src/contracts.dart';
import 'package:supplier_core/src/data/database.dart';
import 'package:supplier_core/src/data/commit_coordinator.dart';
import 'package:supplier_core/src/domain/revision.dart';

class TestWriteLock implements ApplicationWriteLock {
  Future<void> _tail = Future.value();
  bool held = false;
  @override
  Future<T> run<T>(Future<T> Function() action) async {
    final previous = _tail;
    final done = Completer<void>();
    _tail = done.future;
    await previous;
    held = true;
    try {
      return await action();
    } finally {
      held = false;
      done.complete();
    }
  }
}

class StorageTestRig {
  StorageTestRig(this.file)
    : database = SupplierDatabase(
        NativeDatabase(file),
        instanceId: 'fixture-instance',
      );
  final File file;
  SupplierDatabase database;
  final lock = TestWriteLock();
  DatabaseVersion? activeOverride;
  Future<DatabaseVersion> active() async {
    if (!lock.held) throw StateError('Active pointer read before lock');
    return activeOverride ?? await database.currentVersion();
  }

  CommitCoordinator coordinator({CommitFault? fault, bool product = false}) =>
      CommitCoordinator(
        database: database,
        writeLock: lock,
        readActiveVersion: active,
        fault: fault,
        pageSize: 2,
      );
  Future<void> reopen() async {
    await database.close();
    database = SupplierDatabase(
      NativeDatabase(file),
      instanceId: 'fixture-instance',
    );
  }

  Future<PreviewToken> stage({String id = 'job', int count = 5}) async {
    await database.createJob(id);
    for (var i = 0; i < count; i++) {
      await database.appendStaging(id, fixtureRevision(i));
    }
    final token = await database.sealJob(id, 'decisions');
    await database.registerConfirmation('event-$id', token);
    return token;
  }
}

RevisionEnvelope fixtureRevision(int i, {List<String> parents = const []}) =>
    RevisionEnvelope.create(
      entityType: 'supplier',
      entityId: '00000000-0000-4000-8000-${i.toString().padLeft(12, '0')}',
      parents: parents,
      kind: 'put',
      payload: {
        'name': 'Supplier $i',
        'notes': null,
        'aliases': <String>[],
        'categories': <String>[],
        'address': null,
      },
      authoredAt: '2026-09-17T00:00:00.000Z',
      originDeviceId: '00000000-0000-4000-8000-999999999999',
    );
