/// Small native-host A17 matrix; no performance claims or platform certification.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:drift/native.dart';
import 'package:supplier_core/supplier_core.dart';
import '../test/support/test_rig.dart';

const budget = BundleBudget(
  compressedBytes: 32 * 1024 * 1024,
  expandedBytes: 128 * 1024 * 1024,
  revisions: 100,
  volumes: 100,
);

Future<void> main(List<String> args) async {
  if (args.first == '--child') {
    await child(Directory(args[1]), int.parse(args[2]), args[3]);
  } else {
    final out = Directory(args.single);
    if (await out.exists()) throw ArgumentError('Use a new output directory');
    await out.create(recursive: true);
    await runMatrix(out);
  }
}

Future<Map<String, Object?>> runMatrix(Directory out) async {
  final cases = <Map<String, Object?>>[];
  for (final volume in [1, 5, 9]) {
    for (final action in ['complete', 'cancel', 'terminate']) {
      final dir = Directory('${out.path}/$volume-$action');
      await dir.create(recursive: true);
      final process = await Process.start(Platform.resolvedExecutable, [
        'run',
        'tool/a17_concurrency.dart',
        '--child',
        dir.absolute.path,
        '$volume',
        action,
      ]);
      final errors = process.stderr.transform(utf8.decoder).join();
      var reached = false;
      final output = process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
            if (line == 'READY') {
              reached = true;
              if (action == 'terminate') process.kill(ProcessSignal.sigkill);
            }
          });
      final code = await process.exitCode.timeout(
        const Duration(seconds: 90),
        onTimeout: () {
          process.kill(ProcessSignal.sigkill);
          throw TimeoutException('A17 child');
        },
      );
      await output.cancel();
      final stderr = await errors;
      if (!reached ||
          (action != 'terminate' && code != 0) ||
          (action == 'terminate' && code == 0)) {
        throw StateError('A17 $volume $action failed: $code $stderr');
      }
      final target = File('${dir.path}/published.zip');
      if (await target.exists() != (action == 'complete')) {
        throw StateError('Unexpected publication at $volume/$action');
      }
      final reopened = StorageTestRig(File('${dir.path}/active.sqlite'));
      final revisions = (await reopened.database.rows(
        'SELECT COUNT(*) n FROM revision',
      )).single.read<int>('n');
      await reopened.database.close();
      if (revisions != 4) throw StateError('Concurrent edit not durable');
      Map<String, dynamic>? cancellation;
      if (action == 'cancel') {
        cancellation =
            jsonDecode(
                  await File(
                    '${dir.path}/cancel-checkpoint.json',
                  ).readAsString(),
                )
                as Map<String, dynamic>;
        if (cancellation['selected_volume_published'] != true ||
            cancellation['observed_by_exporter_checkpoint'] != true ||
            cancellation['requested_after_volume'] != volume) {
          throw StateError(
            'Cancellation did not traverse production checkpoint',
          );
        }
      }
      cases.add({
        'volume': volume,
        'action': action,
        'status': 'PASS',
        'child_exit': code,
        'concurrent_edit_survives_reopen': true,
        'published': await target.exists(),
        if (cancellation != null) 'cancellation': cancellation,
        'observation': jsonDecode(
          await File('${dir.path}/observation.json').readAsString(),
        ),
      });
    }
  }
  final report = <String, Object?>{
    'harness_version': 2,
    'supersedes': 'a17-concurrency-20260923-final/report.json',
    'cancellation_path':
        'request after selected volume publication, observed by exportBundle checkpoint',
    'status': 'PASS',
    'cases': cases,
    'scope':
        'Native SQLite separate connection edit, 9 real XLSX volumes, actual SIGKILL',
    'gaps': [
      'Small fixture; no timing/RSS or large WAL bound claim',
      'Frozen SQLite copy prepared after closing source; platform snapshot creation not exercised',
      'Host file target; system picker, browser worker and native UI not exercised',
      'SIGKILL can retain private temporary files; startup cleanup not exercised',
      'Android and Windows deferred by user',
    ],
  };
  await File(
    '${out.path}/report.json',
  ).writeAsString(const JsonEncoder.withIndent('  ').convert(report));
  return report;
}

Future<void> child(
  Directory dir,
  int triggerVolume,
  String action, {
  bool enableCheckpoint = true,
}) async {
  final file = File('${dir.path}/active.sqlite');
  final rig = StorageTestRig(file);
  final token = await rig.stage(count: 3);
  await rig.coordinator().commitStaged(
    jobId: 'job',
    expectedPreviewToken: token,
    confirmationEventId: 'event-job',
  );
  await rig.database.close();
  final copy = await file.copy('${dir.path}/snapshot.sqlite');
  final frozen = SupplierDatabase(
    NativeDatabase(copy),
    instanceId: 'fixture-instance',
  );
  final version = await frozen.currentVersion();
  final writer = StorageTestRig(file);
  final verifier = SupplierDatabase(
    NativeDatabase.memory(),
    instanceId: 'verify',
  );
  var artifactCount = 0;
  var cancellationRequested = false;
  Future<void> onVolumePublished() async {
    await writer.database.createJob('concurrent');
    final previous = fixtureRevision(0);
    final edit = RevisionEnvelope.create(
      entityType: previous.entityType,
      entityId: previous.entityId,
      parents: [previous.revisionId],
      kind: 'put',
      payload: {...previous.payload, 'name': 'Concurrent change'},
      authoredAt: '2026-09-23T00:00:00.000Z',
      originDeviceId: previous.originDeviceId,
    );
    await writer.database.appendStaging('concurrent', edit);
    final t = await writer.database.sealJob('concurrent', 'edit');
    await writer.database.registerConfirmation('event-concurrent', t);
    await writer.coordinator().commitStaged(
      jobId: 'concurrent',
      expectedPreviewToken: t,
      confirmationEventId: 'event-concurrent',
    );
    final activeVersion = await writer.database.currentVersion();
    await File('${dir.path}/observation.json').writeAsString(
      jsonEncode({
        'frozen_generation': version.generation,
        'active_generation': activeVersion.generation,
        'snapshot_bytes': await copy.length(),
        'active_bytes': await file.length(),
        'wal_bytes': await File('${file.path}-wal').exists()
            ? await File('${file.path}-wal').length()
            : 0,
      }),
    );
    stdout.writeln('READY');
    await stdout.flush();
    if (action == 'cancel') cancellationRequested = true;
    if (action == 'terminate') await Completer<void>().future;
  }

  Future<BackupArtifact> artifact() async {
    artifactCount++;
    return FileArtifact(
      File('${dir.path}/private-$artifactCount'),
      onPublished: artifactCount == triggerVolume ? onVolumePublished : null,
    );
  }

  Future<void> checkpoint() async {
    if (!cancellationRequested) return;
    await File('${dir.path}/cancel-checkpoint.json').writeAsString(
      jsonEncode({
        'requested_after_volume': triggerVolume,
        'selected_volume_published': await File(
          '${dir.path}/private-$triggerVolume',
        ).exists(),
        'observed_by_exporter_checkpoint': true,
      }),
    );
    throw const DomainFailure('CANCELLED', 'A17 checkpoint');
  }

  try {
    final manifest = await exportBundle(
      snapshot: DatabaseBundleSnapshot(
        database: frozen,
        version: version,
        columns: BundleColumns.schema2(),
      ),
      columns: BundleColumns.schema2(),
      budget: budget,
      bundleId: '90000000-0000-4000-8000-000000000001',
      exportedAt: '2026-09-23T00:00:00.000Z',
      exporterVersion: 'a17-test',
      createArtifact: artifact,
      createXlsxStaging: () async => XlsxStaging(NativeDatabase.memory()),
      createBundleStaging: (v) async =>
          DatabaseBundleStaging(database: verifier, boundVersion: v),
      target: FileArtifact(File('${dir.path}/published.zip')),
      rowsPerVolume: 1,
      checkpoint: enableCheckpoint ? checkpoint : null,
    );
    if (action != 'complete' ||
        manifest.volumes.length != 9 ||
        manifest.revisionCount != 3) {
      throw StateError('Unexpected snapshot contents');
    }
    // Mandatory exporter self-verification parsed every volume against this
    // frozen snapshot. Compare full digests to a fresh live snapshot as well.
    Future<({String revisions, String business})> digest(
      SupplierDatabase db,
    ) async {
      final snap = DatabaseBundleSnapshot(
        database: db,
        version: await db.currentVersion(),
        columns: BundleColumns.schema2(),
      );
      final d = BundleDigests(BundleColumns.schema2());
      for (final kind in bundleKinds) {
        d.beginKind(kind);
        await for (final row in snap.page(kind, limit: 100)) {
          d.add(row);
        }
      }
      return d.finish();
    }

    final before = await digest(frozen), after = await digest(writer.database);
    if (manifest.revisionsDigest != before.revisions ||
        manifest.businessDigest != before.business ||
        before.revisions == after.revisions ||
        before.business == after.business) {
      throw StateError('Snapshot mixing or lost concurrent edit');
    }
    await File('${dir.path}/manifest.json').writeAsString(manifest.encode());
    final nextVerifier = SupplierDatabase(
      NativeDatabase.memory(),
      instanceId: 'next-verify',
    );
    try {
      final next = await exportBundle(
        snapshot: DatabaseBundleSnapshot(
          database: writer.database,
          version: await writer.database.currentVersion(),
          columns: BundleColumns.schema2(),
        ),
        columns: BundleColumns.schema2(),
        budget: budget,
        bundleId: '90000000-0000-4000-8000-000000000002',
        exportedAt: '2026-09-23T00:00:00.000Z',
        exporterVersion: 'a17-next',
        createArtifact: artifact,
        createXlsxStaging: () async => XlsxStaging(NativeDatabase.memory()),
        createBundleStaging: (v) async =>
            DatabaseBundleStaging(database: nextVerifier, boundVersion: v),
        target: FileArtifact(File('${dir.path}/next.zip')),
        rowsPerVolume: 1,
      );
      if (next.revisionCount != 4 ||
          next.revisionsDigest != after.revisions ||
          next.businessDigest != after.business) {
        throw StateError('Next export lost concurrent edit');
      }
      await File('${dir.path}/next-manifest.json').writeAsString(next.encode());
    } finally {
      await nextVerifier.close();
    }
  } on DomainFailure catch (e) {
    if (action != 'cancel' || e.code != 'CANCELLED') rethrow;
    if (!await File('${dir.path}/cancel-checkpoint.json').exists()) {
      throw StateError('Cancellation bypassed production checkpoint');
    }
  } finally {
    await frozen.close();
    await writer.database.close();
    await verifier.close();
  }
}

class FileArtifact implements BackupArtifact, InputSource, OutputTarget {
  FileArtifact(this.file, {this.onPublished});
  final File file;
  final Future<void> Function()? onPublished;
  File get pending => File('${file.path}.pending');
  @override
  InputSource get source => this;
  @override
  OutputTarget get output => this;
  @override
  String get displayName => file.path;
  @override
  Future<int> length() => file.length();
  @override
  Stream<List<int>> openRange(int start, int endExclusive) =>
      file.openRead(start, endExclusive);
  @override
  Future<void> write(Stream<List<int>> source) async {
    final handle = await pending.open(mode: FileMode.write);
    try {
      await for (final chunk in source) {
        await handle.writeFrom(chunk);
      }
      await handle.flush();
    } finally {
      await handle.close();
    }
  }

  @override
  Future<void> publish() async {
    await pending.rename(file.path);
    await onPublished?.call();
  }

  @override
  Future<void> abort() async {
    if (await pending.exists()) await pending.delete();
  }

  @override
  Future<void> dispose() async {
    await abort();
    if (await file.exists()) await file.delete();
  }
}
