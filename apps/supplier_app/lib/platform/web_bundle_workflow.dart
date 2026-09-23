import 'package:drift/wasm.dart';
import 'package:supplier_core/supplier_core.dart';

import 'bundle_workflow.dart';
import 'web_file_ports.dart';
import 'import_cancellation.dart';

final class WebBundleWorkflow extends BundleWorkflow {
  WebBundleWorkflow({
    required super.exchange,
    required super.backups,
    required super.budget,
    required String namespace,
  }) : super(createResources: () => _WebResources.create(namespace));

  /// Invoke directly from a user gesture, before any asynchronous database work.
  Future<BundleImportPreview> pickAndPrepare({
    ImportCancellation? cancellation,
  }) async => prepare(await WebInputSource.pick(), cancellation: cancellation);

  /// The save picker runs before snapshot generation can consume user activation.
  Future<BundleManifest> pickAndExport() async {
    final handle = await WebSaveHandle.pick('supplier.bundle.zip');
    return export(await handle.open());
  }
}

final class _WebResources implements BundleWorkResources {
  _WebResources(this.namespace, this.probe, this.implementation)
    : lock = WebApplicationWriteLock(namespace);
  final String namespace;
  final WasmProbeResult probe;
  final WasmStorageImplementation implementation;
  final _databases = <SupplierDatabase>[];
  final _names = <String>[];
  @override
  final ApplicationWriteLock lock;
  // Reuse the opener: Drift probes own workers and expose no dispose method.
  static Future<WasmProbeResult>? _probe;

  static Future<_WebResources> create(String namespace) async {
    final probe = await (_probe ??= WasmDatabase.probe(
      sqlite3Uri: Uri.base.resolve('sqlite3.wasm'),
      driftWorkerUri: Uri.base.resolve('drift_worker.js'),
    ));
    final persistent =
        probe.availableStorages
            .where((value) => value.storageApi == WebStorageApi.opfs)
            .toList()
          ..sort((a, b) => a.index.compareTo(b.index));
    if (persistent.isEmpty) {
      throw const DomainFailure(
        'persistent_storage_unavailable',
        '分卷操作需要 OPFS 临时存储',
      );
    }
    return _WebResources(
      '$namespace-bundle-${newBundleInstanceId()}',
      probe,
      persistent.first,
    );
  }

  String _reserve() {
    final name = '$namespace-${_names.length}';
    _names.add(name);
    return name;
  }

  @override
  Future<SupplierDatabase> database() async {
    final database = SupplierDatabase(
      await probe.open(implementation, _reserve()),
      instanceId: newBundleInstanceId(),
      useDrift235WebLockSavepoints:
          implementation == WasmStorageImplementation.opfsLocks,
    );
    _databases.add(database);
    return database;
  }

  @override
  Future<XlsxStaging> xlsx() async =>
      XlsxStaging(await probe.open(implementation, _reserve()));

  @override
  Future<BackupArtifact> artifact() => WebBackupArtifact.create(namespace);

  @override
  Future<void> dispose() async {
    final errors = <Object>[];
    for (final database in _databases.reversed) {
      try {
        await database.close();
      } catch (error) {
        errors.add(error);
      }
    }
    if (errors.isEmpty) {
      for (final name in _names.reversed) {
        try {
          await probe.deleteDatabase((WebStorageApi.opfs, name));
        } catch (error) {
          errors.add(error);
        }
      }
    }
    if (errors.isNotEmpty) {
      throw DomainFailure('BUNDLE_CLEANUP_FAILED', '分卷临时存储清理失败', cause: errors);
    }
  }
}
