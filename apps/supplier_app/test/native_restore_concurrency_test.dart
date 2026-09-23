import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:supplier_core/supplier_core.dart';
import 'package:supplier_app/platform/native_backup_artifact.dart';
import 'package:supplier_app/platform/native_database_host.dart';
import 'package:supplier_app/platform/native_file_ports.dart';

import 'support/native_restore_fault.dart';

void main() {
  test(
    'restore holding native lock fences a concurrent staged commit',
    () async {
      const deadline = Duration(seconds: 15);
      final directory = await Directory.systemTemp.createTemp('restore-first-');
      final entered = Completer<void>(), release = Completer<void>();
      final host = await NativeDatabaseHost.open(directory);
      try {
        final snapshot = File('${directory.path}/snapshot.logical');
        await BackupService(
          database: host.database,
          writeLock: host.lock,
          readActiveVersion: host.readActiveVersion,
          createArtifact: () =>
              NativeBackupArtifact.create(Directory('${directory.path}/work')),
        ).create(
          PrivateFileOutput(
            temporary: File('${snapshot.path}.pending'),
            destination: snapshot,
          ),
        );
        final candidate = await host.prepareRestore(
          NativeInputSource(snapshot, displayName: 'snapshot'),
        );
        await host.database.createJob('waiting-writer');
        await host.database.appendStaging(
          'waiting-writer',
          RevisionEnvelope.create(
            entityType: 'supplier',
            entityId: '00000000-0000-4000-8000-000000000003',
            parents: [],
            kind: 'put',
            payload: {
              'name': 'must not commit',
              'notes': null,
              'aliases': <String>[],
              'categories': <String>[],
              'address': null,
            },
            authoredAt: '2026-09-18T00:00:00.000Z',
            originDeviceId: host.deviceId,
          ),
        );
        final token = await host.database.sealJob(
          'waiting-writer',
          'decisions',
        );
        await host.database.registerConfirmation('waiting-event', token);
        final restore = withNativeRestoreFault(
          () => host.activateRestore(candidate),
          (point) async {
            if (point == 'restore_holds_lock') {
              entered.complete();
              await release.future.timeout(deadline);
            }
          },
        ).timeout(deadline);
        await entered.future.timeout(deadline);
        var readActive = false;
        final commit = expectLater(
          CommitCoordinator(
                database: host.database,
                writeLock: host.lock,
                readActiveVersion: () async {
                  readActive = true;
                  return host.readActiveVersion();
                },
              )
              .commitStaged(
                jobId: 'waiting-writer',
                expectedPreviewToken: token,
                confirmationEventId: 'waiting-event',
              )
              .timeout(deadline),
          throwsA(
            isA<DomainFailure>().having(
              (e) => e.code,
              'code',
              'stale_active_database',
            ),
          ),
        );
        expect(readActive, isFalse);
        release.complete();
        expect((await restore).instanceId, candidate);
        await commit;
        expect(readActive, isTrue);
        expect(
          await host.database.rows('SELECT 1 FROM commit_receipt'),
          isEmpty,
        );
        final reopened = await NativeDatabaseHost.open(directory);
        try {
          expect(
            (await reopened.database.currentVersion()).instanceId,
            candidate,
          );
          expect(
            await reopened.database.rows('SELECT 1 FROM revision'),
            isEmpty,
          );
        } finally {
          await reopened.close();
        }
      } finally {
        if (!release.isCompleted) release.complete();
        await host.close();
        await directory.delete(recursive: true);
      }
    },
  );
  test(
    'commit holding the native lock invalidates a concurrent restore preview',
    () async {
      const deadline = Duration(seconds: 15);
      final directory = await Directory.systemTemp.createTemp(
        'restore-concurrency-',
      );
      final host = await NativeDatabaseHost.open(directory);
      final entered = Completer<void>();
      final resume = Completer<void>();
      try {
        final snapshot = File('${directory.path}/snapshot.logical');
        await BackupService(
          database: host.database,
          writeLock: host.lock,
          readActiveVersion: host.readActiveVersion,
          createArtifact: () =>
              NativeBackupArtifact.create(Directory('${directory.path}/work')),
        ).create(
          PrivateFileOutput(
            temporary: File('${snapshot.path}.pending'),
            destination: snapshot,
          ),
        );
        final candidate = await host.prepareRestore(
          NativeInputSource(snapshot, displayName: 'snapshot'),
        );
        final before = await host.database.currentVersion();
        await host.database.createJob('concurrent-writer');
        await host.database.appendStaging(
          'concurrent-writer',
          RevisionEnvelope.create(
            entityType: 'supplier',
            entityId: '00000000-0000-4000-8000-000000000002',
            parents: [],
            kind: 'put',
            payload: {
              'name': 'committed before restore',
              'notes': null,
              'aliases': <String>[],
              'categories': <String>[],
              'address': null,
            },
            authoredAt: '2026-09-18T00:00:00.000Z',
            originDeviceId: host.deviceId,
          ),
        );
        final token = await host.database.sealJob(
          'concurrent-writer',
          'decisions',
        );
        await host.database.registerConfirmation('writer-event', token);
        final commit =
            CommitCoordinator(
                  database: host.database,
                  writeLock: host.lock,
                  readActiveVersion: () async {
                    entered.complete();
                    await resume.future.timeout(deadline);
                    return host.readActiveVersion();
                  },
                )
                .commitStaged(
                  jobId: 'concurrent-writer',
                  expectedPreviewToken: token,
                  confirmationEventId: 'writer-event',
                )
                .timeout(deadline);
        await entered.future.timeout(deadline);
        // The actual native application lock is already held by the writer.
        // Start restoration before letting that writer commit and release it.
        final restore = expectLater(
          host.activateRestore(candidate).timeout(deadline),
          throwsA(
            isA<DomainFailure>().having((e) => e.code, 'code', 'stale_preview'),
          ),
        );
        resume.complete();
        await commit;
        await restore;
        final active = await host.lock.run(host.readActiveVersion);
        expect(active.instanceId, before.instanceId);
        expect(active.activeEpoch, before.activeEpoch);
        expect(active.generation, before.generation + 1);
        expect(
          (await host.database.rows('SELECT name FROM supplier_projection'))
              .single
              .read<String>('name'),
          'committed before restore',
        );
        expect(
          (await host.database.rows('SELECT * FROM commit_receipt')).length,
          1,
        );
        expect(await Directory('${directory.path}/backups').exists(), isFalse);
      } finally {
        if (!resume.isCompleted) resume.complete();
        await host.close();
        await directory.delete(recursive: true);
      }
    },
  );
}
