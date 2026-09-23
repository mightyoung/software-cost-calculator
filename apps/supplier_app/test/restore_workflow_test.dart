import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:supplier_app/platform/native_backup_artifact.dart';
import 'package:supplier_app/platform/native_database_host.dart';
import 'package:supplier_app/platform/native_file_ports.dart';
import 'package:supplier_app/platform/native_restore_workflow.dart';
import 'package:supplier_app/platform/restore_workflow.dart';
import 'package:supplier_core/supplier_core.dart';

void main() {
  const version = DatabaseVersion(
    instanceId: '11111111-1111-4111-8111-111111111111',
    activeEpoch: 1,
    generation: 1,
  );
  RestorePreview preview() => RestorePreview(
    candidateId: '22222222-2222-4222-8222-222222222222',
    sourceName: 'backup',
    summary: BackupSummary(
      BackupHeader(
        version: version,
        counts: {for (final key in backupV1TableKeys.keys) key: 0},
        backupVersion: 1,
      ),
      'digest',
      123,
    ),
  );

  test(
    'preview and explicit confirmation precede activation, close and reopen',
    () async {
      final calls = <String>[];
      final flow = RestoreWorkflow<String>(
        prepare: () async {
          calls.add('prepare');
          return preview();
        },
        activate: (_) async {
          calls.add('activate');
          return version;
        },
        closeCurrent: () async {
          calls.add('close');
        },
        reopen: () async {
          calls.add('reopen');
          return 'new workspace';
        },
      );
      final prepared = await flow.prepare();
      expect(calls, ['prepare']);
      await expectLater(flow.confirmAndActivate(preview()), throwsStateError);
      expect(await flow.confirmAndActivate(prepared), 'new workspace');
      expect(calls, ['prepare', 'activate', 'close', 'reopen']);
      expect(flow.state, RestoreWorkflowState.completed);
      await expectLater(flow.confirmAndActivate(prepared), throwsStateError);
    },
  );

  test('cancel does not activate or close existing workspace', () async {
    final flow = RestoreWorkflow<String>(
      prepare: () async => preview(),
      activate: (_) async => throw StateError('must not activate'),
      closeCurrent: () async => throw StateError('must not close'),
      reopen: () async => 'new',
    );
    final prepared = await flow.prepare();
    flow.cancel();
    await expectLater(flow.confirmAndActivate(prepared), throwsStateError);
    expect(flow.state, RestoreWorkflowState.cancelled);
  });

  test('failed activation reports failure and returns recovered host for replacement', () async {
    final primary = StateError('activation rolled back');
    final flow = RestoreWorkflow<String>(
      prepare: () async => preview(),
      activate: (_) async => throw primary,
      closeCurrent: () async {},
      reopen: () async => 'retained library',
    );
    final prepared = await flow.prepare();
    await expectLater(
      flow.confirmAndActivate(prepared),
      throwsA(
        isA<RestoreActivationFailure<String>>()
            .having((e) => e.cause, 'primary', same(primary))
            .having((e) => e.activationCompleted, 'activationCompleted', false)
            .having(
              (e) => e.recoveredWorkspace,
              'recovered',
              'retained library',
            ),
      ),
    );
    expect(flow.state, RestoreWorkflowState.failed);
  });

  test(
    'reopen failure after activation is never successful completion',
    () async {
      final flow = RestoreWorkflow<String>(
        prepare: () async => preview(),
        activate: (_) async => version,
        closeCurrent: () async {},
        reopen: () async => throw StateError('reopen failed'),
      );
      final prepared = await flow.prepare();
      await expectLater(
        flow.confirmAndActivate(prepared),
        throwsA(
          isA<RestoreActivationFailure<String>>().having(
            (e) => e.activationCompleted,
            'activationCompleted',
            true,
          ),
        ),
      );
      expect(flow.state, RestoreWorkflowState.failed);
    },
  );

  test('native adapter restores real backup only after confirmation and keeps safety backup', () async {
    final directory = await Directory.systemTemp.createTemp(
      'restore-workflow-',
    );
    final source = await NativeDatabaseHost.open(
      Directory('${directory.path}/source'),
    );
    final targetDirectory = Directory('${directory.path}/target');
    var target = await NativeDatabaseHost.open(targetDirectory);
    try {
      await source.records.createEntity('supplier', {
        'name': '恢复供应商',
        'notes': null,
        'aliases': <String>[],
        'categories': <String>[],
        'address': null,
      });
      final backupFile = File('${directory.path}/source.logical');
      final summary =
          await BackupService(
            database: source.database,
            writeLock: source.lock,
            readActiveVersion: source.readActiveVersion,
            createArtifact: () => NativeBackupArtifact.create(
              Directory('${directory.path}/work'),
            ),
          ).create(
            PrivateFileOutput(
              temporary: File('${backupFile.path}.pending'),
              destination: backupFile,
            ),
          );
      final original = await target.readActiveVersion();
      final flow = nativeRestoreWorkflow<NativeDatabaseHost>(
        host: target,
        sourcePath: backupFile.path,
        closeCurrent: target.close,
        reopen: () => NativeDatabaseHost.open(targetDirectory),
      );
      final prepared = await flow.prepare();
      expect(prepared.summary.digest, summary.digest);
      expect(prepared.summary.header.counts['revision'], 1);
      expect(
        (await target.readActiveVersion()).instanceId,
        original.instanceId,
      );
      target = await flow.confirmAndActivate(prepared);
      expect(
        (await target.readActiveVersion()).instanceId,
        prepared.candidateId,
      );
      expect(
        await target.database.customSelect('SELECT * FROM revision').get(),
        hasLength(1),
      );
      final backups = await Directory('${targetDirectory.path}/backups')
          .list()
          .where((file) => file.path.endsWith('.logical'))
          .toList();
      expect(backups, hasLength(1));
      final safety = await decodeBackup(
        NativeInputSource(File(backups.single.path), displayName: 'safety'),
      );
      expect(safety.header.version.instanceId, original.instanceId);
      expect(
        await File('${targetDirectory.path}/db-${original.instanceId}.sqlite')
            .exists(),
        true,
      );
    } finally {
      await source.close();
      await target.close();
      await directory.delete(recursive: true);
    }
  });
}
