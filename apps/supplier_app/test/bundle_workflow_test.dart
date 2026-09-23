import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter_test/flutter_test.dart';
import 'package:supplier_app/platform/native_backup_artifact.dart';
import 'package:supplier_app/platform/native_bundle_workflow.dart';
import 'package:supplier_app/platform/native_database_host.dart';
import 'package:supplier_app/platform/native_file_ports.dart';
import 'package:supplier_core/supplier_core.dart';
import 'package:supplier_app/platform/import_cancellation.dart';
import 'package:supplier_app/platform/bundle_workflow.dart';

import 'support/cancelling_source.dart';

const budget = BundleBudget(
  compressedBytes: 32 * 1024 * 1024,
  expandedBytes: 128 * 1024 * 1024,
  revisions: 10000,
  volumes: 100,
);

NativeBundleWorkflow workflow(NativeDatabaseHost host) {
  final backups = BackupService(
    database: host.database,
    writeLock: host.lock,
    readActiveVersion: host.readActiveVersion,
    createArtifact: () => NativeBackupArtifact.create(
      Directory('${host.directory.path}/backup-work'),
    ),
  );
  return NativeBundleWorkflow(
    exchange: BundleExchangeService(
      coordinator: host.coordinator,
      backups: backups,
      createBackupDestination: () async {
        final folder = await Directory('${host.directory.path}/backups')
            .create(recursive: true);
        final task = await folder.createTemp('before-bundle-');
        final file = File('${task.path}/library.backup');
        return BundleBackupDestination(
          PrivateFileOutput(
            temporary: File('${file.path}.pending'),
            destination: file,
          ),
          NativeInputSource(file, displayName: 'before bundle'),
        );
      },
    ),
    backups: backups,
    budget: budget,
    workDirectory: Directory('${host.directory.path}/bundle-work'),
  );
}

Map<String, Object?> supplier(String name) => {
  'name': name,
  'aliases': <String>[],
  'categories': <String>[],
  'address': null,
  'notes': null,
};

final class FailingOutput implements OutputTarget {
  bool aborted = false, published = false;
  @override
  Future<void> write(Stream<List<int>> bytes) async {
    throw const FileSystemException('simulated full destination');
  }

  @override
  Future<void> publish() async {
    published = true;
  }

  @override
  Future<void> abort() async {
    aborted = true;
  }
}

class CleanupResources implements BundleWorkResources {
  CleanupResources(this.inner, {this.failAllArtifacts = false});
  final BundleWorkResources inner;
  final bool failAllArtifacts;
  int artifacts = 0;
  @override
  ApplicationWriteLock get lock => inner.lock;
  @override
  Future<SupplierDatabase> database() => inner.database();

  @override
  Future<XlsxStaging> xlsx() => inner.xlsx();
  @override
  Future<BackupArtifact> artifact() async {
    final result = await inner.artifact();
    return artifacts++ == 0 || failAllArtifacts
        ? CleanupArtifact(result)
        : result;
  }

  @override
  Future<void> dispose() async {
    await inner.dispose();
    throw StateError('resources-dispose');
  }
}

class CleanupArtifact implements BackupArtifact {
  CleanupArtifact(this.inner);
  final BackupArtifact inner;
  @override
  InputSource get source => inner.source;
  @override
  OutputTarget get output => inner.output;
  @override
  Future<void> dispose() async {
    await inner.dispose();
    throw StateError('frozen-dispose');
  }
}

class CleanupOutput implements OutputTarget {
  CleanupOutput({this.failWrite = true});
  final bool failWrite;
  bool published = false;
  int aborts = 0;
  @override
  Future<void> write(Stream<List<int>> bytes) async {
    if (failWrite) throw StateError('primary-export');
    await bytes.drain<void>();
  }

  @override
  Future<void> publish() async {
    published = true;
  }

  @override
  Future<void> abort() async {
    aborts++;
    throw StateError('target-abort');
  }
}

void main() {
  // Independent file-backed source, target and scratch executors are intentional.
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);
  tearDownAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = false);
  late Directory directory;
  late NativeDatabaseHost source, target;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('bundle-workflow-');
    source = await NativeDatabaseHost.open(
      Directory('${directory.path}/source'),
    );
    target = await NativeDatabaseHost.open(
      Directory('${directory.path}/target'),
    );
  });
  tearDown(() async {
    await source.close();
    await target.close();
    await directory.delete(recursive: true);
  });

  Future<String> exportSource() async {
    final result = await workflow(source)
        .exportTo(Directory('${directory.path}/exports'));
    expect(await File(result.path).exists(), isTrue);
    expect(
      await Directory('${source.directory.path}/bundle-work').list().toList(),
      isEmpty,
    );
    return result.path;
  }

  BundleWorkflow failingCleanup(
    NativeDatabaseHost host, {
    bool failAllArtifacts = false,
  }) {
    final native = workflow(host);
    return BundleWorkflow(
      exchange: native.exchange,
      backups: native.backups,
      budget: budget,
      createResources: () async => CleanupResources(
        await native.createResources(),
        failAllArtifacts: failAllArtifacts,
      ),
    );
  }

  test(
    'prepare keeps primary stack and cancel plus disposal failures',
    () async {
      final file = File('${directory.path}/input.zip');
      await file.writeAsString('invalid');
      await target.database.customStatement('''
      CREATE TRIGGER fail_cancel BEFORE UPDATE OF state ON import_job
      WHEN NEW.state IN ('cancelled', 'failed')
      BEGIN SELECT RAISE(ABORT, 'cancel-failure'); END
    ''');
      try {
        await failingCleanup(target)
            .prepare(NativeInputSource(file, displayName: 'input.zip'));
        fail('must fail');
      } on DomainFailure catch (error) {
        final dynamic cause = error.cause;
        final dynamic preparation = (cause.primary as DomainFailure).cause;
        expect(preparation.primary, isA<DomainFailure>());
        expect(preparation.primaryStack, isA<StackTrace>());
        expect(cause.primaryStack, isA<StackTrace>());
        expect(cause.cleanup.toString(), contains('cancel-failure'));
        expect(cause.cleanup.toString(), contains('resources-dispose'));
      }
    },
  );

  test('export keeps primary and abort plus both disposal failures', () async {
    final output = CleanupOutput();
    try {
      await failingCleanup(source, failAllArtifacts: true).export(output);
      fail('must fail');
    } on DomainFailure catch (error) {
      final dynamic cause = error.cause;
      final dynamic exporter = (cause.primary as DomainFailure).cause;
      expect(exporter.primary.toString(), contains('primary-export'));
      expect(exporter.primaryStack, isA<StackTrace>());
      expect(exporter.cleanup.toString(), contains('target-abort'));
      expect(exporter.cleanup.toString(), contains('artifact.dispose'));
      expect(cause.cleanup.toString(), contains('frozen-dispose'));
      expect(cause.cleanup.toString(), contains('resources-dispose'));
      expect(cause.primaryStack, isA<StackTrace>());
    }
    expect(output.aborts, 1);
    expect(output.published, isFalse);
  });

  test(
    'published export reports cleanup failures without aborting output',
    () async {
      final output = CleanupOutput(failWrite: false);
      try {
        await failingCleanup(source).export(output);
        fail('must fail');
      } on DomainFailure catch (error) {
        final dynamic cause = error.cause;
        expect(cause.primary, isNull);
        expect(cause.published, isTrue);
        expect(cause.cleanup.toString(), contains('frozen-dispose'));
        expect(cause.cleanup.toString(), contains('resources-dispose'));
      }
      expect(output.published, isTrue);
      expect(output.aborts, 0);
    },
  );

  test(
    'exporter cleanup after publication preserves published state',
    () async {
      final output = CleanupOutput(failWrite: false);
      try {
        await failingCleanup(source, failAllArtifacts: true).export(output);
        fail('must fail');
      } on DomainFailure catch (error) {
        final dynamic cause = error.cause;
        final dynamic exporter = (cause.primary as DomainFailure).cause;
        expect(cause.published, isTrue);
        expect(exporter.published, isTrue);
        expect(exporter.primary, isNull);
        expect(exporter.cleanup.toString(), contains('artifact.dispose'));
        expect(cause.cleanup.toString(), contains('resources-dispose'));
      }
      expect(output.published, isTrue);
      expect(output.aborts, 0);
    },
  );

  test('cancel during source fingerprint leaves no imported records or sealed preview', () async {
    await source.records.createEntity('supplier', supplier('取消解析'));
    final input = NativeInputSource(
      File(await exportSource()),
      displayName: 'cancel.zip',
    );
    final cancellation = ImportCancellation();
    final flow = workflow(target);
    await expectLater(
      flow.prepare(
        CancellingSource(input, cancellation),
        cancellation: cancellation,
      ),
      throwsA(isA<DomainFailure>()),
    );
    expect(await target.database.rows('SELECT * FROM revision'), isEmpty);
    final jobs = await target.database.rows('SELECT state FROM import_job');
    expect(jobs.single.read<String>('state'), 'cancelled');
  });
  test(
    'frozen export, explicit preview, commit retry and scratch cleanup',
    () async {
      final id = await source.records.createEntity(
        'supplier',
        supplier('同步供应商'),
      );
      final path = await exportSource();
      final flow = workflow(target);
      final preview = await flow.preparePath(path);
      expect(preview.revisionCount, 1);
      expect(preview.sourceDigest, hasLength(64));
      expect(await target.database.rows('SELECT * FROM revision'), isEmpty);
      expect(
        await Directory('${target.directory.path}/bundle-work').list().toList(),
        isEmpty,
      );
      await flow.commit(preview);
      final version = await target.readActiveVersion();
      await flow.commit(preview);
      expect((await target.readActiveVersion()).generation, version.generation);
      final rows = await target.database.rows('SELECT entity_id FROM revision');
      expect(rows.single.read<String>('entity_id'), id);
      final backups = await Directory('${target.directory.path}/backups')
          .list(recursive: true)
          .where((file) => file.path.endsWith('.backup'))
          .toList();
      expect(backups, hasLength(1));
    },
  );

  test(
    'cancelled preview cannot commit and leaves business data untouched',
    () async {
      await source.records.createEntity('supplier', supplier('取消导入'));
      final flow = workflow(target);
      final preview = await flow.preparePath(await exportSource());
      await flow.cancel(preview);
      await expectLater(flow.commit(preview), throwsA(isA<DomainFailure>()));
      expect(await target.database.rows('SELECT * FROM revision'), isEmpty);
      expect(
        await target.database.rows('SELECT * FROM staging_revision'),
        isEmpty,
      );
    },
  );

  test(
    'sealed preview resumes by durable job id after workflow recreation',
    () async {
      await source.records.createEntity('supplier', supplier('恢复同步'));
      final preview = await workflow(target).preparePath(await exportSource());
      final resumed = await workflow(target).resume(preview.jobId);
      expect(resumed.sourceDigest, preview.sourceDigest);
      expect(resumed.revisionCount, preview.revisionCount);
      await workflow(target).commit(resumed);
      expect(
        await target.database.rows('SELECT * FROM revision'),
        hasLength(1),
      );
    },
  );

  test(
    'corrupt input fails, cleans scratch, and never produces a preview',
    () async {
      final file = File('${directory.path}/broken.zip');
      await file.writeAsString('not a ZIP');
      await expectLater(
        workflow(target).preparePath(file.path),
        throwsA(isA<DomainFailure>()),
      );
      expect(await target.database.rows('SELECT * FROM revision'), isEmpty);
      expect(
        await Directory('${target.directory.path}/bundle-work').list().toList(),
        isEmpty,
      );
    },
  );

  test('local edit makes prepared import stale', () async {
    await source.records.createEntity('supplier', supplier('待导入'));
    final flow = workflow(target);
    final preview = await flow.preparePath(await exportSource());
    await target.records.createEntity('supplier', supplier('本地修改'));
    await expectLater(flow.commit(preview), throwsA(isA<DomainFailure>()));
    expect(await target.database.rows('SELECT * FROM revision'), hasLength(1));
  });

  test(
    'failed publication aborts output and removes frozen scratch databases',
    () async {
      await source.records.createEntity('supplier', supplier('导出失败'));
      final output = FailingOutput();
      await expectLater(
        workflow(source).export(output),
        throwsA(isA<FileSystemException>()),
      );
      expect(output.aborted, isTrue);
      expect(output.published, isFalse);
      expect(
        await Directory('${source.directory.path}/bundle-work').list().toList(),
        isEmpty,
      );
      expect(
        await source.database.rows('SELECT * FROM revision'),
        hasLength(1),
      );
    },
  );
}
