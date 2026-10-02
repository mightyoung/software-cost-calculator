// Run only through run_native_disk_full.py: the runner supplies a private RAM
// volume and nonce. Never point this harness at a user's data directory.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:supplier_core/supplier_core.dart';

import '../../../packages/supplier_core/test/support/test_rig.dart';

import 'package:supplier_app/platform/native_backup_artifact.dart';
import 'package:supplier_app/platform/native_file_ports.dart';

void require(bool value, String message) {
  if (!value) throw StateError(message);
}

String describe(Object? error) =>
    error is DomainFailure ? '$error; cause: ${error.cause}' : '$error';

Future<void> main(List<String> args) async {
  require(
    Platform.isMacOS && args.length == 3,
    'Use the macOS RAM disk runner',
  );
  final root = Directory(args[0]);
  require(
    await File('${root.path}/runner-nonce').readAsString() == args[1],
    'RAM disk nonce mismatch',
  );
  final report = File(args[2]);
  final evidence = <String, Object?>{
    'status': 'RUNNING',
    'scope': 'macOS HFS+ RAM volume, real ENOSPC, small native fixture',
  };
  final rig = StorageTestRig(File('${root.path}/database.sqlite'));
  const instanceId = '00000000-0000-4000-8000-000000000011';
  Future<void> reopen() async {
    await rig.database.close();
    rig.database = SupplierDatabase(
      NativeDatabase(rig.file),
      instanceId: instanceId,
    );
  }

  final filler = File('${root.path}/space-reservation');
  Future<void> fill() async {
    final handle = await filler.open(mode: FileMode.write);
    var bytes = 0;
    try {
      // Hard upper bound protects the host even if the runner is misconfigured.
      final block = Uint8List(4096)..fillRange(0, 4096, 113);
      while (bytes <= 64 * 1024 * 1024) {
        await handle.writeFrom(block);
        bytes += block.length;
      }
      throw StateError('RAM volume did not fill within 64 MiB');
    } on FileSystemException catch (error) {
      require(error.osError?.errorCode == 28, 'Expected actual ENOSPC: $error');
      evidence['filler_enospc_bytes'] = bytes;
    } finally {
      await handle.close();
    }
  }

  Future<void> release() async {
    if (await filler.exists()) await filler.delete();
  }

  Future<String> authority() async {
    final result = <String, Object?>{};
    for (final table in [
      'database_meta',
      'revision',
      'entity_identity',
      'entity_head',
      'supplier_projection',
      'commit_receipt',
      'receipt_result',
    ]) {
      result[table] = (await rig.database.rows(
        'SELECT * FROM $table',
      )).map((row) => jsonEncode(row.data)).toList()..sort();
    }
    return jsonEncode(result);
  }

  try {
    await reopen();
    await rig.database.currentVersion();
    await rig.database.customStatement('PRAGMA cache_size=1');
    await rig.database.createJob('disk-full');
    for (var i = 0; i < 200; i++) {
      final original = fixtureRevision(i);
      await rig.database.appendStaging(
        'disk-full',
        RevisionEnvelope.create(
          entityType: original.entityType,
          entityId: original.entityId,
          parents: original.parents,
          kind: original.kind,
          payload: {
            ...original.payload,
            'notes': List.filled(1800, 'x').join(),
          },
          authoredAt: original.authoredAt,
          originDeviceId: original.originDeviceId,
        ),
      );
    }
    final token = await rig.database.sealJob('disk-full', 'decisions');
    await rig.database.registerConfirmation('event-disk-full', token);
    final before = await authority();
    var reachedPage = false;
    Object? commitError;
    try {
      await rig
          .coordinator(
            fault: (point) async {
              if (point == 'page:2') {
                reachedPage = true;
                await fill();
              }
            },
          )
          .commitStaged(
            jobId: token.jobId,
            expectedPreviewToken: token,
            confirmationEventId: 'event-disk-full',
          );
    } catch (error) {
      commitError = error;
    } finally {
      await release();
    }
    require(
      reachedPage && commitError != null,
      'Commit must fail after writing first page',
    );
    require(
      describe(commitError).toLowerCase().contains('full') ||
          describe(commitError).contains('28'),
      'Commit must report disk exhaustion: $commitError',
    );
    await reopen();
    require(
      await authority() == before,
      'Authority changed after failed transaction',
    );
    require(
      (await rig.database.job('disk-full')).read<String>('state') ==
          'previewReady',
      'Failed commit changed job',
    );
    final receipt = await rig.coordinator().commitStaged(
      jobId: token.jobId,
      expectedPreviewToken: token,
      confirmationEventId: 'event-disk-full',
    );
    final retry = await rig.coordinator().commitStaged(
      jobId: token.jobId,
      expectedPreviewToken: token,
      confirmationEventId: 'event-disk-full',
    );
    require(
      receipt.resultCount == 200 && retry.resultCount == 200,
      'Retry results differ',
    );
    require(
      (await rig.database.rows('SELECT COUNT(*) n FROM commit_receipt')).single
              .read<int>('n') ==
          1,
      'Retry duplicated receipt',
    );
    evidence['commit'] = {
      'status': 'PASS',
      'error': describe(commitError),
      'rollback_after_reopen': true,
      'retry_single_receipt': true,
    };

    final snapshot = await authority();
    final work = Directory('${root.path}/backup-work');
    final targetFile = File('${root.path}/backup.logical');
    final pending = File('${root.path}/backup.pending');
    var backupFailed = false;
    try {
      await BackupService(
        database: rig.database,
        writeLock: rig.lock,
        readActiveVersion: rig.active,
        createArtifact: () async {
          final artifact = await NativeBackupArtifact.create(work);
          await fill();
          return artifact;
        },
      ).create(PrivateFileOutput(temporary: pending, destination: targetFile));
    } catch (error) {
      backupFailed = true;
      evidence['backup_error'] = '$error';
      require(
        error.toString().contains('28') ||
            error.toString().toLowerCase().contains('space'),
        'Backup must report ENOSPC: $error',
      );
    } finally {
      await release();
    }
    require(
      backupFailed && !await targetFile.exists() && !await pending.exists(),
      'Failed backup published or leaked target',
    );
    require(await work.list().isEmpty, 'Private backup artifact leaked');
    await reopen();
    require(await authority() == snapshot, 'Backup failure altered database');
    await BackupService(
      database: rig.database,
      writeLock: rig.lock,
      readActiveVersion: rig.active,
      createArtifact: () => NativeBackupArtifact.create(work),
    ).create(PrivateFileOutput(temporary: pending, destination: targetFile));
    await decodeBackup(NativeInputSource(targetFile, displayName: 'retry'));
    evidence['backup'] = {
      'status': 'PASS',
      'no_publication_on_failure': true,
      'private_cleanup': true,
      'retry_decoded': true,
    };
    evidence['status'] = 'PASS';
  } catch (error, stack) {
    evidence['status'] = 'FAIL';
    evidence['error'] = '$error';
    evidence['stack'] = '$stack';
    exitCode = 1;
  } finally {
    await release();
    await rig.database.close();
    await report.writeAsString(
      const JsonEncoder.withIndent('  ').convert(evidence),
    );
  }
}
