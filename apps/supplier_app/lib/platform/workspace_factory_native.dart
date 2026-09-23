import 'dart:io';

import 'package:drift/native.dart';
import 'package:path_provider/path_provider.dart';
import 'package:supplier_core/supplier_core.dart';

import '../app/core_supplier_workspace.dart';
import '../app/workspace.dart';
import 'native_backup_artifact.dart';
import 'native_business_import.dart';
import 'native_bundle_workflow.dart';
import 'native_database_host.dart';
import 'native_file_ports.dart';
import 'native_restore_workflow.dart';
import 'native_workspace_bundle_actions.dart';

const _bundleBudget = BundleBudget(
  compressedBytes: 512 * 1024 * 1024,
  expandedBytes: 2 * 1024 * 1024 * 1024,
  revisions: 600000,
  volumes: 1000,
);

/// A deployment can provide its application-owned directory explicitly. No
/// database is ever silently created in a temporary or current directory.
Future<SupplierWorkspace> openSupplierWorkspace() async {
  const configured = String.fromEnvironment('SUPPLIER_DATA_DIRECTORY');
  return openNativeSupplierWorkspace(
    await resolveNativeDataDirectory(configured: configured),
  );
}

/// Platform inputs are injectable so directory policy can be checked on hosts
/// other than Android, without substituting a temporary directory in production.
Future<Directory> resolveNativeDataDirectory({
  String configured = '',
  String? operatingSystem,
  Map<String, String>? environment,
  Future<Directory> Function()? applicationSupportDirectory,
}) async {
  final platform = operatingSystem ?? Platform.operatingSystem;
  final variables = environment ?? Platform.environment;
  final String path;
  if (configured.isNotEmpty) {
    path = configured;
  } else if (platform == 'android') {
    final directory =
        await (applicationSupportDirectory ?? getApplicationSupportDirectory)();
    if (!directory.isAbsolute) {
      throw const WorkspaceUnavailable('应用的持久存储目录无效。');
    }
    return directory;
  } else if (platform == 'macos' && variables['HOME'] != null) {
    path = '${variables['HOME']}/Library/Application Support/SupplierInquiry';
  } else if (platform == 'windows' && variables['LOCALAPPDATA'] != null) {
    path = '${variables['LOCALAPPDATA']}/SupplierInquiry';
  } else if (platform == 'linux' && variables['HOME'] != null) {
    path =
        '${variables['XDG_DATA_HOME'] ?? '${variables['HOME']}/.local/share'}/supplier-inquiry';
  } else {
    throw const WorkspaceUnavailable(
      '尚未取得应用的持久存储目录，请配置 SUPPLIER_DATA_DIRECTORY。',
    );
  }
  return Directory(path);
}

Future<CoreSupplierWorkspace> openNativeSupplierWorkspace(
  Directory directory,
) async {
  final host = await NativeDatabaseHost.open(directory);
  final backupService = BackupService(
    database: host.database,
    writeLock: host.lock,
    readActiveVersion: host.readActiveVersion,
    createArtifact: () =>
        NativeBackupArtifact.create(Directory('${directory.path}/backup-work')),
  );
  Future<BusinessBackupDestination> createImportBackup() async {
    final folder = await Directory('${directory.path}/backup-work/import')
        .create(recursive: true);
    final task = await folder.createTemp('before-import-');
    final file = File('${task.path}/library.backup');
    return BusinessBackupDestination(
      PrivateFileOutput(
        temporary: File('${file.path}.pending'),
        destination: file,
      ),
      NativeInputSource(file, displayName: '导入前备份'),
    );
  }

  final exchange = ExchangeService(
    coordinator: host.coordinator,
    backups: backupService,
    createBackupDestination: createImportBackup,
  );
  final bundleExchange = BundleExchangeService(
    coordinator: host.coordinator,
    backups: backupService,
    createBackupDestination: () async {
      final folder = await Directory('${directory.path}/backup-work/bundle')
          .create(recursive: true);
      final task = await folder.createTemp('before-bundle-');
      final file = File('${task.path}/library.backup');
      return BundleBackupDestination(
        PrivateFileOutput(
          temporary: File('${file.path}.pending'),
          destination: file,
        ),
        NativeInputSource(file, displayName: '完整同步前备份'),
      );
    },
  );
  final bundleWorkflow = NativeBundleWorkflow(
    exchange: bundleExchange,
    backups: backupService,
    budget: _bundleBudget,
    workDirectory: Directory('${directory.path}/bundle-work'),
  );
  late CoreSupplierWorkspace workspace;
  workspace = CoreSupplierWorkspace(
    coordinator: host.coordinator,
    records: host.records,
    close: host.close,
    restoreNeedsPath: true,
    createRestoreWorkflow: (sourcePath) =>
        nativeRestoreWorkflow<SupplierWorkspace>(
          host: host,
          sourcePath: sourcePath ?? '',
          closeCurrent: workspace.close,
          reopen: () => openNativeSupplierWorkspace(directory),
        ),
    bundleActions: NativeWorkspaceBundleActions(
      workflow: bundleWorkflow,
      exportDirectory: Directory('${directory.path}/exports'),
    ),
    businessImport: NativeBusinessImport(
      exchange: exchange,
      deviceId: host.records.deviceId,
      directory: Directory('${directory.path}/business-import'),
    ),
    runTask: (task) async {
      if (task == WorkspaceTask.createBackup) {
        final outputDirectory = await Directory('${directory.path}/backups')
            .create(recursive: true);
        final taskDirectory = await outputDirectory.createTemp('backup-');
        final destination = File('${taskDirectory.path}/supplier.backup');
        final summary = await backupService.create(
          PrivateFileOutput(
            temporary: File('${destination.path}.pending'),
            destination: destination,
          ),
        );
        return WorkspaceTaskResult(
          '完整备份已生成并校验：${destination.path}\n校验值：${summary.digest}',
        );
      }
      if (task == WorkspaceTask.exportWorkbook) {
        final outputDirectory = await Directory('${directory.path}/exports')
            .create(recursive: true);
        final taskDirectory = await outputDirectory.createTemp('business-');
        final destination = File('${taskDirectory.path}/业务报价.xlsx');
        final stagingFile = File('${taskDirectory.path}/validation.sqlite');
        final staging = XlsxStaging(NativeDatabase(stagingFile));
        try {
          final summary = await exchange.exportBusiness(
            PrivateFileOutput(
              temporary: File('${destination.path}.pending'),
              destination: destination,
            ),
            expectedVersion: await host.readActiveVersion(),
            validation: staging,
            policy: BusinessWorkbookPolicy(maxDataRows: 100000),
          );
          return WorkspaceTaskResult(
            '业务表已生成并回读校验：${destination.path}\n${summary.rows} 行 · ${summary.sha256}',
          );
        } finally {
          await staging.close();
          if (await stagingFile.exists()) await stagingFile.delete();
        }
      }
      throw const WorkspaceUnavailable('此文件操作尚未连接选择、预览和确认流程。');
    },
  );
  return workspace;
}
