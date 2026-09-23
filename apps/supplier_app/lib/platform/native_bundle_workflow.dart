import 'dart:io';

import 'package:drift/native.dart';
import 'package:supplier_core/supplier_core.dart';

import 'bundle_workflow.dart';
import 'native_backup_artifact.dart';
import 'native_file_ports.dart';
import 'import_cancellation.dart';

final class NativeBundleWorkflow extends BundleWorkflow {
  NativeBundleWorkflow({
    required super.exchange,
    required super.backups,
    required super.budget,
    required Directory workDirectory,
  }) : super(createResources: () => _NativeResources.create(workDirectory));

  Future<BundleImportPreview> preparePath(
    String path, {
    ImportCancellation? cancellation,
  }) {
    if (path.trim().isEmpty || !File(path).isAbsolute) {
      throw ArgumentError('请选择完整的分卷文件路径');
    }
    return prepare(
      NativeInputSource(File(path), displayName: path),
      cancellation: cancellation,
    );
  }

  /// Publishes into a unique application-owned directory and returns its path.
  Future<({String path, BundleManifest manifest})> exportTo(
    Directory exportDirectory,
  ) async {
    await exportDirectory.create(recursive: true);
    final folder = await exportDirectory.createTemp('bundle-');
    final file = File('${folder.path}/supplier.bundle.zip');
    try {
      final manifest = await export(
        PrivateFileOutput(
          temporary: File('${file.path}.pending'),
          destination: file,
        ),
      );
      return (path: file.path, manifest: manifest);
    } catch (_) {
      // A cleanup failure after successful publication leaves the valid output
      // available for diagnosis, while an unpublished directory is disposable.
      if (!await file.exists()) await folder.delete(recursive: true);
      rethrow;
    }
  }
}

final class _NativeResources implements BundleWorkResources {
  _NativeResources(this.directory)
    : lock = NativeApplicationWriteLock(
        File('${directory.path}/candidate.lock'),
      );
  final Directory directory;
  final _databases = <SupplierDatabase>[];
  int _sequence = 0;
  @override
  final ApplicationWriteLock lock;
  static Future<_NativeResources> create(Directory parent) async {
    await parent.create(recursive: true);
    return _NativeResources(await parent.createTemp('bundle-work-'));
  }

  @override
  Future<SupplierDatabase> database() async {
    final result = SupplierDatabase(
      NativeDatabase(File('${directory.path}/db-${_sequence++}.sqlite')),
      instanceId: newBundleInstanceId(),
    );
    _databases.add(result);
    return result;
  }

  @override
  Future<XlsxStaging> xlsx() async => XlsxStaging(
    NativeDatabase(File('${directory.path}/xlsx-${_sequence++}.sqlite')),
  );

  @override
  Future<BackupArtifact> artifact() => NativeBackupArtifact.create(directory);

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
      await directory.delete(recursive: true);
    } else {
      throw DomainFailure('BUNDLE_CLEANUP_FAILED', '临时数据库关闭失败', cause: errors);
    }
  }
}
