import 'package:drift/wasm.dart';
import 'package:supplier_core/supplier_core.dart';

import '../app/core_supplier_workspace.dart';
import '../app/workspace.dart';
import 'web_database_host.dart';
import 'web_business_import.dart';
import 'web_bundle_workflow.dart';
import 'web_file_ports.dart';
import 'web_restore_workflow.dart';
import 'web_workspace_bundle_actions.dart';

const _bundleBudget = BundleBudget(
  compressedBytes: 512 * 1024 * 1024,
  expandedBytes: 2 * 1024 * 1024 * 1024,
  revisions: 600000,
  volumes: 1000,
);

Future<SupplierWorkspace> openSupplierWorkspace() async {
  final host = await WebDatabaseHost.open();
  final backupService = BackupService(
    database: host.database,
    writeLock: host.lock,
    readActiveVersion: host.readActiveVersion,
    createArtifact: () => WebBackupArtifact.create(host.namespace),
  );
  final exchange = ExchangeService(
    coordinator: host.coordinator,
    backups: backupService,
    createBackupDestination: () async {
      final artifact = await WebDurableBackup.create(host.namespace);
      return BusinessBackupDestination(
        artifact.output,
        artifact.source,
        onVerified: artifact.associateWithJob,
      );
    },
  );
  final bundleExchange = BundleExchangeService(
    coordinator: host.coordinator,
    backups: backupService,
    createBackupDestination: () async {
      final artifact = await WebDurableBackup.create(host.namespace);
      return BundleBackupDestination(
        artifact.output,
        artifact.source,
        onVerified: artifact.associateWithJob,
      );
    },
  );
  final bundleWorkflow = WebBundleWorkflow(
    exchange: bundleExchange,
    backups: backupService,
    budget: _bundleBudget,
    namespace: host.namespace,
  );
  late CoreSupplierWorkspace workspace;
  workspace = CoreSupplierWorkspace(
    coordinator: host.coordinator,
    records: host.records,
    close: host.close,
    restoreNeedsPath: false,
    createRestoreWorkflow: (_) => webRestoreWorkflow<SupplierWorkspace>(
      host: host,
      closeCurrent: workspace.close,
      reopen: openSupplierWorkspace,
    ),
    bundleActions: WebWorkspaceBundleActions(bundleWorkflow),
    businessImport: WebBusinessImport(
      exchange: exchange,
      deviceId: host.records.deviceId,
      namespace: host.namespace,
    ),
    runTask: (task) async {
      if (task == WorkspaceTask.createBackup) {
        final handle = await WebSaveHandle.pick('supplier-backup.logical');
        final target = await handle.open();
        final summary = await backupService.create(target);
        return WorkspaceTaskResult('完整备份已校验并写入所选文件。校验值：${summary.digest}');
      }
      if (task == WorkspaceTask.exportWorkbook) {
        // Acquire the handle in the click gesture before generating the file.
        final handle = await WebSaveHandle.pick('业务报价.xlsx');
        final target = await handle.open();
        final probe = await WasmDatabase.probe(
          sqlite3Uri: Uri.base.resolve('sqlite3.wasm'),
          driftWorkerUri: Uri.base.resolve('drift_worker.js'),
        );
        final memory = probe.availableStorages.firstWhere(
          (implementation) => implementation.storageApi == null,
        );
        final staging = XlsxStaging(
          await probe.open(memory, 'business-export-validation'),
        );
        try {
          final summary = await exchange.exportBusiness(
            target,
            expectedVersion: await host.readActiveVersion(),
            validation: staging,
            policy: BusinessWorkbookPolicy(maxDataRows: 100000),
          );
          return WorkspaceTaskResult(
            '业务表已校验并写入所选文件。${summary.rows} 行 · ${summary.sha256}',
          );
        } finally {
          await staging.close();
        }
      }
      throw const WorkspaceUnavailable('此文件操作尚未连接选择、预览和确认流程。');
    },
  );
  return workspace;
}
