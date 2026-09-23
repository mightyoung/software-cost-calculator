import 'dart:convert';
import 'dart:js_interop';

import 'package:supplier_core/supplier_core.dart';
import 'package:supplier_app/platform/web_database_host.dart';
import 'package:supplier_app/platform/web_file_ports.dart';
import 'package:supplier_app/platform/web_installation_store.dart';
import 'package:supplier_app/platform/web_capacity.dart';

@JS('setInputChoice')
external void setInputChoice(JSString name);

@JS('setRestoreFault')
external void setRestoreFault(JSString name);
@JS('restoreFaultStats')
external JSString restoreFaultStats();

@JS('restoreFailureDetail')
external set failureDetail(JSString detail);

@JS('restoreSmoke')
external set restoreSmoke(JSFunction function);
@JS('probeReady')
external set ready(JSBoolean value);
@JS('smokeStage')
external set stage(JSString value);
void check(bool condition, String message) {
  if (!condition) throw StateError(message);
}

String get base => Uri.base.queryParameters['run']!;
WebDatabaseHost? held;
({WebDatabaseHost host, String candidate})? quotaFixture;
DatabaseVersion? quotaBaseline;
Future<void> add(WebDatabaseHost host, String name) => host.records
    .createEntity('supplier', {
      'name': name,
      'notes': null,
      'aliases': <String>[],
      'categories': <String>[],
      'address': null,
    })
    .then((_) {});
Future<int> count(WebDatabaseHost host) async =>
    (await host.database.rows('SELECT COUNT(*) n FROM supplier_projection'))
        .single
        .read<int>('n');
Future<BackupSummary> backup(WebDatabaseHost host, OutputTarget output) =>
    BackupService(
      database: host.database,
      writeLock: host.lock,
      readActiveVersion: host.readActiveVersion,
      createArtifact: () => WebBackupArtifact.create(host.namespace),
    ).create(output);
Future<({WebDatabaseHost host, String candidate})> fixture(
  String suffix, {
  CapacityReader? capacity,
}) async {
  stage = 'fixture $suffix'.toJS;
  final host = await WebDatabaseHost.open(
    namespace: '$base-$suffix',
    readCapacity: capacity ?? readWebCapacity,
  );
  final artifact = await WebBackupArtifact.create(host.namespace);
  try {
    await add(host, 'snapshot');
    await backup(host, artifact.output);
    await add(host, 'retained');
    final candidate = await host.prepareRestore(artifact.source);
    return (host: host, candidate: candidate);
  } finally {
    await artifact.dispose();
  }
}

Map<String, Object?> pointer(String id, int epoch) => {
  'instance_id': id,
  'epoch': epoch,
};

// Deliberate crash-boundary fixtures write only isolated test namespaces. Actual
// candidates and safety backups still use the product builder and backup service.
Future<void> arm(WebDatabaseHost host, String id, String boundary) async {
  final version = await host.lock.run(host.readActiveVersion);
  final safety = await WebDurableBackup.create(host.namespace);
  final summary = await backup(host, safety.output);
  final record = await host.installation.read('candidate:$id');
  final journal = <String, Object?>{
    'candidate_id': id,
    'old_instance': version.instanceId,
    'old_epoch': version.activeEpoch,
    'old_generation': version.generation,
    'new_epoch': version.activeEpoch + 1,
    'backup_locator': safety.locator,
    'backup_digest': summary.digest,
    'state': 'armed',
    'failure': null,
  };
  await host.lock.run(() async {
    await host.installation.compareAndSet(
      expected: {
        'active': pointer(version.instanceId, version.activeEpoch),
        'activation': null,
        'candidate:$id': record,
      },
      changes: {'activation': journal},
    );
    if (boundary != 'armed' && boundary != 'missing_backup') {
      final db = await host.openDatabase(id, 0);
      try {
        await db.rebindActivationEpoch(
          expectedVersion: await db.currentVersion(),
          newEpoch: version.activeEpoch + 1,
        );
        if (boundary == 'tampered' || boundary == 'armed_tampered') {
          await db.customStatement('INSERT INTO local_settings VALUES(?,?)', [
            'tamper',
            'true',
          ]);
        }
        if (boundary == 'projection_tampered') {
          await db.customStatement('UPDATE supplier_projection SET name=?', [
            'tampered',
          ]);
        }
      } finally {
        await db.close();
      }
    }
    if ([
      'switched',
      'tampered',
      'projection_tampered',
      'rollback_pending',
      'rollback_epoch',
    ].contains(boundary)) {
      final next = {
        ...journal,
        'state': boundary.startsWith('rollback')
            ? 'rollback_pending'
            : 'switched',
      };
      await host.installation.compareAndSet(
        expected: {'activation': journal},
        changes: {
          'activation': next,
          'active': pointer(id, version.activeEpoch + 1),
        },
      );
    }
    if (boundary == 'rollback_epoch') {
      await host.database.rebindActivationEpoch(
        expectedVersion: version,
        newEpoch: version.activeEpoch + 2,
      );
    }
    if (boundary == 'missing_backup') {
      await host.installation.compareAndSet(
        expected: {'activation': journal},
        changes: {
          'activation': {...journal, 'backup_locator': newWebInstanceId()},
        },
      );
    }
  });
}

final class BadSource implements InputSource {
  @override
  String get displayName => 'invalid-backup';
  @override
  Future<int> length() async => 3;
  @override
  Stream<List<int>> openRange(int start, int endExclusive) async* {
    yield [1, 2, 3].sublist(start, endExclusive);
  }
}

Future<Map<String, Object?>> run(String operation) async {
  if (operation == 'quota_prepare') {
    quotaFixture = await fixture(
      'actual-quota',
      capacity: () async => CapacitySample(
        status: 'estimated',
        scope: 'deliberately-stale-test-estimate',
        availableBytes: 1024 * 1024 * 1024,
      ),
    );
    quotaBaseline = await quotaFixture!.host.database.currentVersion();
    return {'prepared': true};
  }
  if (operation == 'quota_activate') {
    final f = quotaFixture!;
    Object? failure;
    try {
      await f.host.activateRestore(f.candidate);
    } catch (error) {
      failure = error;
    }
    check(failure != null, 'Actual quota did not reject restore');
    check(
      f.host.lastRestoreEstimate?.budget.fits == true,
      'Preflight, not actual quota, rejected',
    );
    check(
      f.host.lastRestoreEstimate?.phase == 'activate',
      'Activation preflight was not reached',
    );
    return {
      'failed': true,
      'estimate_allowed': true,
      'error': failure.toString(),
    };
  }
  if (operation == 'quota_verify') {
    final f = quotaFixture!;
    final namespace = f.host.namespace;
    final old = quotaBaseline!;
    await f.host.close();
    quotaFixture = null;
    final reopened = await WebDatabaseHost.open(namespace: namespace);
    try {
      final current = await reopened.database.currentVersion();
      check(
        old.instanceId == current.instanceId &&
            old.activeEpoch == current.activeEpoch &&
            old.generation == current.generation,
        'Quota changed active identity/version',
      );
      final names = (await reopened.database.rows(
        'SELECT name FROM supplier_projection ORDER BY name',
      )).map((row) => row.read<String>('name')).toList();
      check(
        names.join(',') == 'retained,snapshot',
        'Quota changed business data',
      );
      check(
        (await reopened.database.rows('SELECT count(*) n FROM commit_receipt'))
                .single
                .read<int>('n') ==
            2,
        'Quota changed success receipts',
      );
      check(
        await reopened.installation.read('activation') == null,
        'Quota armed activation',
      );
      return {
        'original_preserved': true,
        'receipts_preserved': true,
        'unarmed': true,
      };
    } finally {
      await reopened.close();
    }
  }
  if (operation == 'capacity') {
    final actual = await readWebCapacity();
    check(actual.status == 'estimated', 'Chrome capacity API unavailable');
    int? free = 0;
    final namespace = '$base-capacity';
    final host = await WebDatabaseHost.open(
      namespace: namespace,
      readCapacity: () async => CapacitySample(
        status: free == null ? 'unsupported' : 'estimated',
        scope: 'test',
        availableBytes: free,
      ),
    );
    final artifact = await WebBackupArtifact.create(namespace);
    late String id;
    try {
      await add(host, 'capacity-snapshot');
      await backup(host, artifact.output);
      Future<void> rejected(Future<Object?> operation) async {
        Object? failure;
        try {
          await operation;
        } catch (error) {
          failure = error;
        }
        check(
          failure is DomainFailure && failure.code == 'SPACE_REQUIRED',
          'Expected space rejection',
        );
      }

      await rejected(host.prepareRestore(artifact.source));
      check(
        await host.installation.read('activation') == null,
        'Prepare armed journal',
      );
      free = null;
      id = await host.prepareRestore(artifact.source);
      free = 0;
      await rejected(host.activateRestore(id));
      check(
        (await host.installation.read('candidate:$id'))?['state'] == 'ready',
        'Lost ready candidate',
      );
      check(
        await host.installation.read('activation') == null,
        'Rejected activation armed journal',
      );
      // Replay is not a new admission: persisted work must recover even when a
      // subsequent capacity sampler is unavailable or would reject all writes.
      await arm(host, id, 'armed');
    } finally {
      await artifact.dispose();
      await host.close();
    }
    var samples = 0;
    final reopened = await WebDatabaseHost.open(
      namespace: namespace,
      readCapacity: () async {
        samples++;
        throw StateError('Recovery must not request admission');
      },
    );
    try {
      check(samples == 0, 'Replay sampled capacity');
      check(
        (await reopened.database.currentVersion()).instanceId == id,
        'Replay failed',
      );
      check(
        (await reopened.installation.read('activation'))?['state'] ==
            'accepted',
        'Replay unaccepted',
      );
      return {
        'actual_sample': actual.toJson(),
        'prepare_rejected': true,
        'activate_resampled': true,
        'candidate_preserved': true,
        'recovery_not_gated': true,
      };
    } finally {
      await reopened.close();
    }
  }
  if (operation == 'source_reselection') {
    final host = await WebDatabaseHost.open(namespace: '$base-source');
    try {
      final jobs = JobStore(
        database: host.database,
        writeLock: host.lock,
        readActiveVersion: host.readActiveVersion,
      );
      setInputChoice('original'.toJS);
      final source = await WebInputSource.pick();
      final job = await jobs.create(source);
      await jobs.bindSource(job.id, source);
      final bound = await jobs.load(job.id);
      setInputChoice('lost'.toJS);
      var lost = false;
      try {
        await jobs.verifySource(job.id, await WebInputSource.pick());
      } catch (_) {
        lost = true;
      }
      setInputChoice('renamed'.toJS);
      await jobs.verifySource(job.id, await WebInputSource.pick());
      setInputChoice('different'.toJS);
      var mismatch = false;
      try {
        await jobs.verifySource(job.id, await WebInputSource.pick());
      } on DomainFailure catch (error) {
        mismatch = error.code == 'source_mismatch';
      }
      final after = await jobs.load(job.id);
      check(
        lost && mismatch && after.sourceDigest == bound.sourceDigest,
        'Source loss/reselection changed durable identity',
      );
      await jobs.transition(
        job.id,
        expectedState: JobState.created,
        next: JobState.cancelled,
      );
      final version = await host.lock.run(host.readActiveVersion);
      check(
        version.generation == 0 && await count(host) == 0,
        'Source preparation changed business records',
      );
      return {
        'lost_read_rejected': lost,
        'renamed_same_bytes_accepted': true,
        'changed_bytes_rejected': mismatch,
        'binding_preserved': true,
        'cancelled': (await jobs.load(job.id)).state == JobState.cancelled,
      };
    } finally {
      await host.close();
    }
  }
  if (operation == 'io_faults') {
    final result = <String, Object?>{};
    for (final fault in [
      'private-create',
      'durable-write',
      'durable-publish',
      'idb-arm',
      'idb-switch',
      'idb-accept',
      'ack-after-accept',
    ]) {
      final f = await fixture('fault-$fault');
      final before = await f.host.lock.run(f.host.readActiveVersion);
      Object? failure;
      try {
        setRestoreFault(fault.toJS);
        try {
          await f.host.activateRestore(f.candidate);
        } catch (error) {
          failure = error;
        }
        final stats =
            jsonDecode(restoreFaultStats().toDart) as Map<String, dynamic>;
        setRestoreFault(''.toJS);
        check(
          failure != null && stats['injected'] == true,
          '$fault was not exercised',
        );
        if (fault.startsWith('durable-') || fault == 'private-create') {
          check(
            stats['aborts'] == 1,
            '$fault did not close its pending output',
          );
          check(
            stats['publishes'] == 0,
            '$fault published an incomplete backup',
          );
        }
        await f.host.close();
        final recovered = await WebDatabaseHost.open(
          namespace: f.host.namespace,
        );
        try {
          final version = await recovered.lock.run(recovered.readActiveVersion);
          final names = (await recovered.database.rows(
            'SELECT name FROM supplier_projection ORDER BY name',
          )).map((row) => row.read<String>('name')).toList();
          check(
            version.instanceId ==
                    (fault == 'ack-after-accept'
                        ? f.candidate
                        : before.instanceId) &&
                version.generation ==
                    (fault == 'ack-after-accept' ? 1 : before.generation) &&
                names.join(',') ==
                    (fault == 'ack-after-accept'
                        ? 'snapshot'
                        : 'retained,snapshot'),
            '$fault changed active contents',
          );
          final journal = await recovered.installation.read('activation');
          check(
            fault == 'ack-after-accept'
                ? (journal?['state'] == 'accepted')
                : ['idb-switch', 'idb-accept'].contains(fault)
                ? (journal?['state'] == 'rolled_back')
                : journal == null,
            '$fault left an unsafe activation journal',
          );
          result[fault] = {
            'failed_safely': true,
            'stats': stats,
            'epoch': version.activeEpoch,
            'journal': journal?['state'],
          };
        } finally {
          await recovered.close();
        }
      } finally {
        setRestoreFault(''.toJS);
        await f.host.close();
      }
    }
    return result;
  }
  if (operation == 'hold') {
    held = await WebDatabaseHost.open(namespace: '$base-normal');
    return {'held': true};
  }
  if (operation == 'fenced') {
    var rejected = false;
    try {
      await add(held!, 'must-not-write');
    } on DomainFailure {
      rejected = true;
    }
    await held!.close();
    held = null;
    check(rejected, 'Peer retained connection wrote after activation');
    return {'fenced': rejected};
  }
  if (operation == 'normal_prepare') {
    final f = await fixture('normal');
    held = f.host;
    return {'candidate': f.candidate, 'device': f.host.deviceId};
  }
  if (operation.startsWith('activate:')) {
    final id = operation.substring(9);
    final host = held!;
    final version = await host.activateRestore(id);
    var rejected = false;
    try {
      await add(host, 'must-not-write');
    } on DomainFailure {
      rejected = true;
    }
    check(rejected, 'Original connection wrote after activation');
    final device = host.deviceId;
    final journal = (await host.installation.read('activation'))!;
    final safety = await decodeBackup(
      await WebDurableBackup.read(
        host.namespace,
        journal['backup_locator']! as String,
      ),
    );
    check(safety.header.counts['revision'] == 2, 'Safety backup incomplete');
    await host.close();
    held = null;
    final fresh = await WebDatabaseHost.open(namespace: '$base-normal');
    try {
      check(
        await count(fresh) == 1 && fresh.deviceId == device,
        'Restore contents/device wrong',
      );
      check(
        (await fresh.lock.run(fresh.readActiveVersion)).instanceId ==
            version.instanceId,
        'Active identity differs',
      );
      await add(fresh, 'after-accepted');
      return {
        'accepted': true,
        'old_fenced': rejected,
        'backup_revisions': 2,
        'device': device,
        'instance': version.instanceId,
      };
    } finally {
      await fresh.close();
    }
  }
  if (operation == 'reopen_accepted') {
    final host = await WebDatabaseHost.open(namespace: '$base-normal');
    try {
      final names = (await host.database.rows(
        'SELECT name FROM supplier_projection ORDER BY name',
      )).map((row) => row.read<String>('name')).toList();
      check(
        names.join(',') == 'after-accepted,snapshot',
        'Accepted later write reverted or retained library was restored',
      );
      final version = await host.lock.run(host.readActiveVersion);
      check(
        (await host.installation.read('activation'))!['state'] == 'accepted',
        'Accepted journal changed',
      );
      return {
        'accepted_no_rollback': true,
        'device': host.deviceId,
        'instance': version.instanceId,
        'names': names,
      };
    } finally {
      await host.close();
    }
  }
  if (operation == 'boundaries') {
    final result = <String, Object?>{};
    for (final boundary in [
      'armed',
      'armed_epoch',
      'switched',
      'rollback_pending',
      'rollback_epoch',
      'tampered',
      'armed_tampered',
      'projection_tampered',
      'missing_backup',
    ]) {
      final f = await fixture(boundary);
      final old = await f.host.lock.run(f.host.readActiveVersion);
      await arm(f.host, f.candidate, boundary);
      await f.host.close();
      stage = 'replay $boundary'.toJS;
      final recovered = await WebDatabaseHost.open(
        namespace: '$base-$boundary',
      );
      try {
        final version = await recovered.lock.run(recovered.readActiveVersion);
        final rollback = [
          'rollback_pending',
          'rollback_epoch',
          'tampered',
          'armed_tampered',
          'projection_tampered',
          'missing_backup',
        ].contains(boundary);
        check(
          version.instanceId == (rollback ? old.instanceId : f.candidate),
          '$boundary wrong instance',
        );
        check(
          version.activeEpoch ==
              (rollback ? old.activeEpoch + 2 : old.activeEpoch + 1),
          '$boundary wrong epoch',
        );
        check(
          await count(recovered) == (rollback ? 2 : 1),
          '$boundary wrong contents',
        );
        result[boundary] = (await recovered.installation.read(
          'activation',
        ))!['state'];
      } finally {
        await recovered.close();
      }
    }
    return result;
  }
  if (operation == 'invalid') {
    final host = await WebDatabaseHost.open(namespace: '$base-invalid');
    try {
      await add(host, 'kept');
      final before = await host.lock.run(host.readActiveVersion);
      var rejected = false;
      try {
        await host.prepareRestore(BadSource());
      } catch (_) {
        rejected = true;
      }
      final after = await host.lock.run(host.readActiveVersion);
      check(
        rejected &&
            before.instanceId == after.instanceId &&
            before.generation == after.generation &&
            await count(host) == 1,
        'Invalid preparation changed active library',
      );
      check(
        await host.installation.read('activation') == null,
        'Invalid preparation armed journal',
      );
      return {'invalid_prepare_isolated': true};
    } finally {
      await host.close();
    }
  }
  if (operation == 'stale') {
    final f = await fixture('stale');
    try {
      await add(f.host, 'newer');
      var rejected = false;
      try {
        await f.host.activateRestore(f.candidate);
      } on DomainFailure catch (e) {
        rejected = e.code == 'stale_preview';
      }
      check(
        rejected && await count(f.host) == 3,
        'Stale candidate altered active data',
      );
      check(
        await f.host.installation.read('activation') == null,
        'Stale candidate armed journal',
      );
      return {'stale_rejected': true};
    } finally {
      await f.host.close();
    }
  }
  if (operation == 'crash_prepare') {
    final f = await fixture('process');
    await arm(f.host, f.candidate, 'armed_epoch');
    await f.host.close();
    return {'candidate': f.candidate};
  }
  if (operation == 'crash_recover') {
    final host = await WebDatabaseHost.open(namespace: '$base-process');
    try {
      check(await count(host) == 1, 'Process replay lost candidate');
      final journal = (await host.installation.read('activation'))!;
      check(journal['state'] == 'accepted', 'Process replay not accepted');
      final safety = await decodeBackup(
        await WebDurableBackup.read(
          host.namespace,
          journal['backup_locator']! as String,
        ),
      );
      check(
        safety.header.counts['revision'] == 2,
        'Durable safety backup missing after process exit',
      );
      return {'process_replay': true, 'durable_backup': true};
    } finally {
      await host.close();
    }
  }
  throw ArgumentError(operation);
}

void main() {
  restoreSmoke =
      ((JSString operation) => run(operation.toDart)
              .then(
                (r) => jsonEncode(r).toJS,
                onError: (Object error, StackTrace stack) {
                  failureDetail = '$error\n$stack'.toJS;
                  Error.throwWithStackTrace(error, stack);
                },
              )
              .toJS)
          .toJS;
  ready = true.toJS;
}
