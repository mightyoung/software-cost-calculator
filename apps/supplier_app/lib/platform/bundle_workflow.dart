import 'dart:math';

import 'package:drift/drift.dart' show Variable;
import 'package:supplier_core/supplier_core.dart';

import 'import_cancellation.dart';

String newBundleInstanceId() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 15) | 64;
  bytes[8] = (bytes[8] & 63) | 128;
  final hex = bytes
      .map((value) => value.toRadixString(16).padLeft(2, '0'))
      .join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

/// A preview is deliberately separate from commit; showing it never writes
/// imported business records. The token remains bound to its original version.
final class BundleImportPreview {
  const BundleImportPreview({
    required this.confirmation,
    required this.sourceName,
    required this.sourceDigest,
    required this.revisionCount,
  });
  final BundleConfirmation confirmation;
  final String sourceName, sourceDigest;
  final int revisionCount;
  String get jobId => confirmation.token.jobId;
}

abstract interface class BundleWorkResources {
  Future<SupplierDatabase> database();
  Future<XlsxStaging> xlsx();
  Future<BackupArtifact> artifact();
  ApplicationWriteLock get lock;
  Future<void> dispose();
}

/// Platform adapters provide task-owned, disk-backed scratch databases. All
/// scratch resources live only through parsing/export, never through UI waits.
class BundleWorkflow {
  BundleWorkflow({
    required this.exchange,
    required this.backups,
    required this.budget,
    required this.createResources,
  }) {
    budget.validate();
  }
  final BundleExchangeService exchange;
  final BackupService backups;
  final BundleBudget budget;
  final Future<BundleWorkResources> Function() createResources;

  Future<BundleImportPreview> prepare(
    InputSource source, {
    ImportCancellation? cancellation,
  }) async {
    source = cancellation?.wrap(source) ?? source;
    final job = await exchange.beginBundle(source);
    BundleWorkResources? resources;
    Object? primary;
    StackTrace? primaryStack;
    final cleanup = <({String stage, Object error, StackTrace stack})>[];
    try {
      await cancellation?.attach(() async {
        await exchange.cancel(job.id);
      });
      resources = await createResources();
      final confirmation = await exchange.prepare(
        job.id,
        source,
        staging: DatabaseBundleStaging(
          database: await resources.database(),
          boundVersion: job.version,
        ),
        budget: budget,
        createXlsxStaging: resources.xlsx,
      );
      cancellation?.check();
      final count = (await exchange.coordinator.database.rows(
        'SELECT COUNT(*) n FROM staging_revision WHERE job_id=?',
        // Count the sealed revision set without loading its rows into the UI.
        [Variable(job.id)],
      ));
      return BundleImportPreview(
        confirmation: confirmation,
        sourceName: source.displayName,
        sourceDigest: (await exchange.jobs.load(job.id)).sourceDigest!,
        revisionCount: count.single.read<int>('n'),
      );
    } catch (error, stack) {
      primary = error;
      primaryStack = stack;
      try {
        await exchange.cancel(job.id);
      } catch (error, stack) {
        cleanup.add((stage: 'cancel', error: error, stack: stack));
      }
      rethrow;
    } finally {
      try {
        await resources?.dispose();
      } catch (error, stack) {
        cleanup.add((stage: 'resources.dispose', error: error, stack: stack));
      }
      if (cleanup.isNotEmpty) {
        throw DomainFailure(
          'BUNDLE_CLEANUP_FAILED',
          '同步预览清理失败',
          cause: (
            primary: primary,
            primaryStack: primaryStack,
            cleanup: cleanup,
          ),
        );
      }
    }
  }

  Future<CommitReceipt> commit(BundleImportPreview preview) =>
      exchange.commit(preview.confirmation);

  /// Restores an already sealed preview after application restart. Partial
  /// parsing attempts require a fresh source-bound task instead of guessing.
  Future<BundleImportPreview> resume(String jobId) async {
    if (!RegExp(r'^[a-zA-Z0-9_-]{1,200}$').hasMatch(jobId)) {
      throw ArgumentError('无效任务编号');
    }
    final job = await exchange.resume(jobId);
    if (![JobState.previewReady, JobState.committed].contains(job.state)) {
      throw const DomainFailure(
        'bundle_not_resumable',
        '只有已完成验证的同步预览可以恢复；解析中断需重新选择源文件',
      );
    }
    final confirmation = await exchange.confirmation(jobId);
    final count = await exchange.coordinator.database.rows(
      'SELECT COUNT(*) n FROM staging_revision WHERE job_id=?',
      [Variable(jobId)],
    );
    return BundleImportPreview(
      confirmation: confirmation,
      sourceName: '已恢复任务 $jobId',
      sourceDigest: job.sourceDigest!,
      revisionCount: count.single.read<int>('n'),
    );
  }

  Future<void> cancel(BundleImportPreview preview) async {
    await exchange.cancel(preview.jobId);
  }

  Future<BundleManifest> export(OutputTarget target) async {
    BundleWorkResources? resources;
    BackupArtifact? frozen;
    var handedToExporter = false;
    final output = _PublicationTarget(target);
    Object? primary;
    StackTrace? primaryStack;
    final cleanup = <({String stage, Object error, StackTrace stack})>[];
    try {
      resources = await createResources();
      frozen = await resources.artifact();
      await backups.create(frozen.output);
      final snapshot = await resources.database();
      await BackupCandidateBuilder(
        database: snapshot,
        writeLock: resources.lock,
      ).build(frozen.source);
      final version = await snapshot.currentVersion();
      final columns = BundleColumns.schema2();
      handedToExporter = true;
      final manifest = await exportBundle(
        snapshot: DatabaseBundleSnapshot(
          database: snapshot,
          version: version,
          columns: columns,
        ),
        columns: columns,
        budget: budget,
        bundleId: newBundleInstanceId(),
        exportedAt: DateTime.fromMillisecondsSinceEpoch(
          DateTime.now().millisecondsSinceEpoch,
          isUtc: true,
        ).toIso8601String(),
        exporterVersion: '0.1.0',
        createArtifact: resources.artifact,
        createXlsxStaging: resources.xlsx,
        createBundleStaging: (version) async => DatabaseBundleStaging(
          database: await resources!.database(),
          boundVersion: version,
        ),
        target: output,
      );
      return manifest;
    } catch (error, stack) {
      primary = error;
      primaryStack = stack;
      if (!handedToExporter) {
        try {
          await output.abort();
        } catch (error, stack) {
          cleanup.add((stage: 'abort', error: error, stack: stack));
        }
      }
      rethrow;
    } finally {
      try {
        await frozen?.dispose();
      } catch (error, stack) {
        cleanup.add((stage: 'frozen.dispose', error: error, stack: stack));
      }
      try {
        await resources?.dispose();
      } catch (error, stack) {
        cleanup.add((stage: 'resources.dispose', error: error, stack: stack));
      }
      if (cleanup.isNotEmpty) {
        throw DomainFailure(
          'BUNDLE_CLEANUP_FAILED',
          '同步导出清理失败；已发布的输出予以保留',
          cause: (
            primary: primary,
            primaryStack: primaryStack,
            cleanup: cleanup,
            published: output.published,
          ),
        );
      }
    }
  }
}

/// Tracks publication even when exporter-owned cleanup subsequently fails.
final class _PublicationTarget implements OutputTarget {
  _PublicationTarget(this.inner);
  final OutputTarget inner;
  bool published = false;
  @override
  Future<void> write(Stream<List<int>> bytes) => inner.write(bytes);
  @override
  Future<void> publish() async {
    await inner.publish();
    published = true;
  }

  @override
  Future<void> abort() => inner.abort();
}
