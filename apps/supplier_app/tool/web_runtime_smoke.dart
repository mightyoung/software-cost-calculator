import 'dart:convert';
import 'dart:js_interop';

import 'package:supplier_core/supplier_core.dart';
import 'package:supplier_app/platform/web_database_host.dart';
import 'package:supplier_app/platform/web_file_ports.dart';

@JS('runSmoke')
external set runSmoke(JSFunction function);
@JS('probeReady')
external set ready(JSBoolean value);
@JS('reopenSmoke')
external set reopenSmoke(JSFunction function);
@JS('smokeStage')
external set stage(JSString value);
void check(bool value, String message) {
  if (!value) throw StateError(message);
}

Future<JSString> smoke() async {
  final namespace = Uri.base.queryParameters['run']!;
  stage = 'open'.toJS;
  var host = await WebDatabaseHost.open(namespace: namespace);
  final device = host.deviceId;
  WebBackupArtifact? output;
  try {
    stage = 'outside version read'.toJS;
    await host.database.currentVersion();
    stage = 'outside read transaction'.toJS;
    await host.database.transaction(() async {
      await host.database.rows('SELECT 1');
    });
    stage = 'locked version read'.toJS;
    await host.lock.run(() async {
      await host.readActiveVersion();
    });
    final pragmas = {
      'sync': (await host.database.rows('PRAGMA synchronous')).single.data,
      'journal': (await host.database.rows('PRAGMA journal_mode')).single.data,
    };
    stage = 'simple write $pragmas'.toJS;
    await host.lock.run(
      () => host.database.transaction(() async {
        await host.database.customStatement(
          'INSERT INTO local_settings VALUES(?,?)',
          ['smoke', 'true'],
        );
      }),
    );
    stage = 'nested transaction rollback'.toJS;
    await host.lock.run(
      () => host.database.transaction(() async {
        await host.database.transaction(() async {
          await host.database.customStatement(
            'INSERT INTO local_settings VALUES(?,?)',
            ['nested-kept', 'true'],
          );
        });
        try {
          await host.database.transaction(() async {
            await host.database.customStatement(
              'INSERT INTO local_settings VALUES(?,?)',
              ['nested-rolled-back', 'true'],
            );
            throw StateError('Expected inner failure');
          });
        } on StateError {
          // The outer transaction must remain usable after inner rollback.
        }
        await host.database.transaction(() async {
          await host.database.customStatement(
            'INSERT INTO local_settings VALUES(?,?)',
            ['nested-after', 'true'],
          );
        });
      }),
    );
    final nested = await host.database.rows(
      "SELECT key FROM local_settings WHERE key LIKE 'nested-%' ORDER BY key",
    );
    check(
      nested.map((row) => row.read<String>('key')).join(',') ==
          'nested-after,nested-kept',
      'Nested rollback isolation failed',
    );
    stage = 'create record'.toJS;
    await host.records.createEntity('supplier', {
      'name': '浏览器持久供应商',
      'notes': null,
      'aliases': <String>[],
      'categories': <String>[],
      'address': null,
    });
    final before = await host.lock.run(host.readActiveVersion);
    stage = 'create output'.toJS;
    output = await WebBackupArtifact.create(namespace);
    stage = 'backup'.toJS;
    final summary = await BackupService(
      database: host.database,
      writeLock: host.lock,
      readActiveVersion: host.readActiveVersion,
      createArtifact: () => WebBackupArtifact.create(namespace),
    ).create(output.output);
    final verified = await decodeBackup(output.source);
    stage = 'nested lock'.toJS;
    check(
      verified.digest == summary.digest &&
          verified.header.counts['revision'] == 1,
      'Bounded file backup failed',
    );
    var nestedRejected = false;
    await host.lock.run(() async {
      try {
        await host.lock.run(() async {});
      } on StateError {
        nestedRejected = true;
      }
    });
    check(nestedRejected, 'Nested application lock was not rejected');
    stage = 'metadata CAS'.toJS;
    final active = await host.installation.read('active');
    var staleRejected = false;
    try {
      await host.installation.compareAndSet(
        expected: {'active': null},
        changes: {
          'active': {'instance_id': 'bad', 'epoch': 99},
        },
      );
    } catch (_) {
      staleRejected = true;
    }
    check(
      staleRejected &&
          jsonEncode(await host.installation.read('active')) ==
              jsonEncode(active),
      'Metadata failed CAS changed pointer',
    );
    await host.close();
    stage = 'reopen'.toJS;
    host = await WebDatabaseHost.open(namespace: namespace);
    check(host.deviceId == device, 'Device identity changed');
    final after = await host.lock.run(host.readActiveVersion);
    check(
      before.instanceId == after.instanceId &&
          before.activeEpoch == after.activeEpoch &&
          before.generation == after.generation,
      'Database version changed on reopen',
    );
    final rows = await host.database.rows(
      'SELECT name FROM supplier_projection',
    );
    check(
      rows.single.read<String>('name') == '浏览器持久供应商',
      'Business data did not persist',
    );
    return jsonEncode({
      'status': 'PASS',
      'generation': after.generation,
      'instance': after.instanceId,
      'device': device,
      'backup_digest': summary.digest,
      'backup_revisions': summary.header.counts['revision'],
      'nested_lock_rejected': nestedRejected,
      'metadata_cas_rejected': staleRejected,
    }).toJS;
  } finally {
    await output?.dispose();
    await host.close();
  }
}

void main() {
  runSmoke = (() => smoke().toJS).toJS;
  reopenSmoke = (() => (() async {
    final host = await WebDatabaseHost.open(
      namespace: Uri.base.queryParameters['run']!,
    );
    try {
      final version = await host.lock.run(host.readActiveVersion);
      final rows = await host.database.rows(
        'SELECT name FROM supplier_projection',
      );
      check(
        version.generation == 1 &&
            rows.length == 1 &&
            rows.single.read<String>('name') == '浏览器持久供应商',
        'Browser process reopen lost data',
      );
      return jsonEncode({
        'status': 'PASS',
        'instance': version.instanceId,
        'generation': version.generation,
        'device': host.deviceId,
      }).toJS;
    } finally {
      await host.close();
    }
  })().toJS).toJS;
  ready = true.toJS;
}
